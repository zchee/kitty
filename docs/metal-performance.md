# kitty Metal-backend performance harness

Developer-facing notes for the measurement tooling built for
`.omc/plans/2026-07-02-metal-worlds-fastest-optimization.md`. This is a plain
Markdown dev doc (not part of the Sphinx-built `docs/*.rst` site) that lives
next to the harness scripts under `scripts/`.

Python prerequisite: every script here is written against **python3.14**
specifically (shebang `#!/usr/bin/env python3.14`, and the Makefile target
below pins it via `PYTHON3`). Do not run them with a bare `python3` on a dev
machine where that may resolve to a different/beta interpreter -- check with
`python3 --version` first if unsure.

Two optional third-party packages, both installed the same way (`python3.14
-m pip install --user <pkg>`; a user-level dev-tool install, not a system
change):

- **`pyobjc-framework-Quartz`** -- needed by `metal-latency.py` for
  `CGEventPost` key injection and `CACurrentMediaTime()`. Without it, the
  script falls back to a coarser AppleScript (`osascript`) injection path
  (see below) and a pure-stdlib `ctypes` timestamp source; both fallbacks
  work, just with more jitter.
- **`Pillow`** -- needed by `metal-golden.py compare` for PNG decoding and
  pixel diffing. Same optional-dependency convention `kitty_tests/graphics.py`
  already uses (`from PIL import Image`, gracefully skipped if absent).
  Without it, `compare` reports `"pass": null` with an explanatory error per
  config rather than crashing.

All three scripts (`metal-baseline.py`, `metal-latency.py`,
`metal-golden.py`) share process-lifecycle and detection code via
`scripts/_kitty_harness_common.py` (backend/`default.metallib` detection,
build-lock check, and the exact-PID SIGTERM-then-SIGKILL safety rule) -- see
"Operational rules" below.

## Building

This harness never builds kitty itself -- build first, then benchmark the
resulting `kitty/launcher/kitty`.

```sh
# Metal backend (the only macOS backend as of W27; KITTY_USE_METAL is no
# longer a build input -- =1 is tolerated, anything else fails fast)
PKG_CONFIG_PATH=/opt/homebrew/lib/pkgconfig:/opt/homebrew/opt/libpng/lib/pkgconfig:/opt/homebrew/opt/freetype/lib/pkgconfig \
  python3.14 setup.py build
```

The built binary is always `kitty/launcher/kitty` (a symlink into
`kitty/launcher/kitty.app/Contents/MacOS/kitty`); the bundled `kitten` lives
alongside it at `kitty/launcher/kitty.app/Contents/MacOS/kitten`.

## Running baselines

```sh
make metal-baseline          # Metal-build JSON -> .omc/baselines/
```

There is intentionally only **one** Makefile target. No GL build exists on
darwin as of W27, so GL baselines can no longer be produced on macOS; the
script's backend auto-detection (presence of `Contents/Resources/default.metallib`
in the built `.app` bundle) remains for cross-platform and archived runs, so
the label in the output JSON is always truthful:

```sh
python3.14 scripts/metal-baseline.py --label metal-run1
```

Useful flags (`python3.14 scripts/metal-baseline.py --help` for the full
list): `--backend {auto,metal,gl}`, `--scenarios ascii unicode csi ...`,
`--repetitions N`, `--skip-throughput`, `--skip-devlog006`, `--display-hz HZ`
(override auto-detection), `--output-dir DIR`, `--label LABEL`.

The script refuses to run while `.omc/build.lock` is held (polls up to 30s,
then aborts loudly) so it never benchmarks a binary that's mid-write by a
concurrent build.

### What it measures

1. **Throughput**: `kitten __benchmark__ --render <scenarios>` (MB/s per
   scenario: ascii, unicode, csi, images, long_escape_codes). `--render` is
   required -- the kitten suppresses rendering by default via synchronized-
   update escapes and only exercises the parser otherwise
   (`tools/cmd/benchmark/main.go`).
2. **devlog-006 replication**: a deterministic ~5.4 MB pseudo-Japanese UTF-8
   text fixture (`scripts/gen_japanese_fixture.py`, seeded, not committed --
   regenerated on demand), `cat` x10 inside a live kitty window, wall-clock
   mean/stddev ms, flagged if variance exceeds 2% (replicates
   mitchellh.com/writing/ghostty-devlog-006's methodology). The timed `cat`
   (`scripts/_cat_timing_helper.py`) explicitly writes to `/dev/tty`, not
   its own (possibly-redirected) stdout -- `run_in_kitty()` redirects the
   *wrapper* command's stdout to a capture file for other callers (the
   kitten benchmark's printed results table), and naively inheriting that
   for `cat` measures file I/O, not terminal ingestion. **Physics-checked**
   against the same run's `ascii` scenario: devlog006's implied MB/s
   (`fixture_bytes / ms_mean`) cannot legitimately exceed the ascii
   scenario's measured ceiling by more than 1.5x (same pty, same parser) --
   a `devlog006_cat_ja.physics_check` failure sets `invalid: true,
   invalid_reason: "physics_check_failed"` rather than reporting an
   impossible number as real. Caught exactly this way on 2026-07-02: the
   pre-fix bug measured 5.4 MB in ~5.2ms (implied ~1 GB/s, ~10x the ascii
   ceiling in the same JSON -- impossible); post-fix it measures ~70ms
   (implied ~73 MB/s, sane relative to a ~111 MB/s ascii ceiling and the
   extra per-byte cost of multi-byte UTF-8 parsing).
3. **vtebench**, only if present on `PATH` (graceful skip otherwise --
   vtebench's CLI/output format has not been driven end-to-end by this
   harness yet).
4. **RSS**: peak resident set size sampled via `ps` while kitty is running.
5. **powermetrics** package power: only when the script itself is run as
   root (`sudo make metal-baseline` / `sudo python3.14 scripts/metal-baseline.py`);
   graceful skip otherwise.
6. **Frame stats** from `KITTY_METAL_STATS=1` output (see below): CPU
   (`encode_ms`) and GPU ms p50/p99, passes/frame.

Nothing here is ever fabricated: a piece that cannot run (missing tool, no
root, pre-instrumentation build, forcibly-terminated timeout) is recorded
with an explicit `skipped`/`error` note, never a made-up number. A kitty
process that has to be forcibly terminated after exceeding its timeout
(SIGTERM, then SIGKILL after a 5s grace period -- never killed by name or
pattern, always the exact tracked PID) invalidates that scenario's run
entirely rather than reporting partial output as a real measurement.

### Output JSON schema

Written to `.omc/baselines/<UTC-timestamp>-<backend>[-<label>].json`:

```jsonc
{
  "backend": "metal" | "gl" | "unknown",
  "backend_detection_note": "...",
  "machine": {"model": "...", "chip": "...", "os": "..."},
  "display": {"hz": 120.0, "note": null},
  "kitty_version": "0.47.4",
  "timestamp": "2026-07-02T12:34:56Z",
  "config": { /* run parameters: repetitions, fixture seed/size, ... */ },
  "scenarios": {
    "ascii": {"desc": "Only ASCII chars", "duration_ms": 45.2, "mbps": 123.4},
    "unicode": { /* ... */ }, "csi": { /* ... */ },
    "images": { /* ... */ }, "long_escape_codes": { /* ... */ },
    "devlog006_cat_ja": {
      "ms_mean": 70.7, "ms_stddev": 16.3, "variance_pct": 23.1,
      "flagged_high_variance": true, "samples_ms": [...],
      "fixture_bytes": 5400000, "fixture_sha256": "...",
      "physics_check": {
        "performed": true, "implied_mbps": 72.9,
        "ascii_mbps": 111.2, "limit_mbps": 166.8, "passed": true
      }
      // "invalid": true, "invalid_reason": "physics_check_failed" only if
      // physics_check.passed is false -- see "What it measures" above.
    },
    "vtebench": {"skipped": true, "reason": "..."}
  },
  "frames": {
    "available": true,
    "cpu_ms_p50": 1.2, "cpu_ms_p99": 3.4,
    "gpu_ms_p50": 0.8, "gpu_ms_p99": 2.1,
    "passes_per_frame": 1.0,
    "presented_frame_count": 480,
    "presented_frame_count_dropped_zero": 1
  },
  "rss_mb": 42.3,
  "power_w": null,
  "power_details": {"skipped": true, "reason": "powermetrics requires root"}
}
```

## KITTY_METAL_* environment variables (dev/harness contract)

Defined by `kitty/metal.m`'s Phase-0 instrumentation:

| Variable | Effect |
|---|---|
| `KITTY_METAL_LOG` | Path to a file for `METAL_TRACE` dev/debug tracing. Takes a **file path**, not `1` -- `KITTY_METAL_LOG=1` creates a file literally named `1` in the CWD. |
| `KITTY_METAL_SIGNPOST` | Any value other than unset/empty/`0` enables `os_signpost` spans (subsystem `net.kovidgoyal.kitty`, category `metal`) and `metal_present` line emission. Inspect with Instruments. |
| `KITTY_METAL_STATS` | Any value other than unset/empty/`0` enables `metal_stats` + `metal_present` line emission (see format below). |
| `KITTY_METAL_STATS_FILE` | Path to append `metal_stats`/`metal_present` lines to. Takes a **file path** (same `=1` footgun as `KITTY_METAL_LOG`). If unset, lines go to kitty's own stderr. |
| `KITTY_METAL_DUMP_FRAME` | Path to write one offscreen-rendered frame as a PNG (golden-image harness; renders without acquiring a real drawable, so it works headless/sandboxed). |
| `KITTY_METAL_DUMP_ATLAS`, `KITTY_METAL_DUMP_FBO` | Additional one-shot dev dumps (glyph atlas layer 0, layered-mode intermediate FBO) after frame 5. |

### Stats line format

One line per event, to stderr or the `KITTY_METAL_STATS_FILE` path (append):

```
metal_present frame=<uint64> presented_time=<float seconds, 9 decimals>
metal_stats   frame=<uint64> encode_ms=<float, 3 decimals> gpu_ms=<float, 3 decimals> passes=<int>
```

- `metal_present` is emitted when `KITTY_METAL_STATS=1` OR
  `KITTY_METAL_SIGNPOST=1`; `metal_stats` only when `KITTY_METAL_STATS=1`.
  Correlate the two via the shared `frame=` id.
- `presented_time` is `MTLDrawable.presentedTime` -- host time in seconds,
  same timebase as `CACurrentMediaTime()`/`mach_absolute_time`.
- **`presented_time == 0.000000000` rows must be dropped** -- a known
  first-drawable quirk (`addPresentedHandler` fires with a zero timestamp
  for the very first drawable of a session; not a real photon-present time).
  `scripts/metal-baseline.py`'s parser does this and reports the dropped
  count separately (`frames.presented_frame_count_dropped_zero`).
- `encode_ms` is the CPU-side encode span (command-buffer creation through
  `metal_end_frame`); it is what the baseline JSON's `frames.cpu_ms_p50/p99`
  reports. `gpu_ms` is `cb.GPUEndTime - cb.GPUStartTime`.

## Keypress-to-presented latency harness

```sh
python3.14 scripts/metal-latency.py                 # 100 injections, JSON -> .omc/baselines/
python3.14 scripts/metal-latency.py --count 200 --seed 1 --label soak
```

Pairs synthetic key injection with real `metal_present` timestamps to
measure keypress-to-photon latency (plan SS6 Phase 0 step 2, SS12: no
published harness does this -- precedent is thume.ca's `kdebug_signpost`
technique). Flags (`--help` for the full list): `--count`,
`--min-interval-ms`/`--max-interval-ms` (randomized gap, default 80-200ms,
avoids vsync aliasing per Dan Luu's methodology), `--seed` (reproducible
intervals), `--output-dir`, `--label`.

### How it works

1. Launches `kitty/launcher/kitty` running its **default interactive
   shell** (not a fixed command) with `KITTY_METAL_STATS=1`,
   `KITTY_METAL_SIGNPOST=1`, and `cursor_blink_interval=0` -- blink is
   disabled because it is the only source of frame production with zero
   input, and left enabled a coincidental blink frame could produce a false
   positive when checking whether an injection actually reached the window.
2. Injects the Space key (`CGEventPost` via pyobjc's `Quartz`, or an
   `osascript System Events keystroke` fallback) -- deliberately inert at
   any shell prompt since Enter is never sent, so injected keys never
   execute anything.
3. **Accessibility permission gate**: `CGEventPost`/`osascript` both need
   Accessibility access for the calling process. This is checked two ways:
   `CGPreflightPostEventAccess()` (informative, non-prompting) and,
   authoritatively, an **empirical canary injection** verified against real
   `metal_present` output before the real run starts. The canary first
   waits for the frame stream to go quiet for `--quiescence-s` (default
   0.5s, up to `--quiescence-max-wait-s`) -- without this, a freshly
   launched window's own trailing startup rendering can produce a "new
   frame" that has nothing to do with the injection, giving a false
   positive (observed empirically while writing this script). If the
   canary's own injection produces no new frame within `--canary-timeout-s`,
   the run is reported `"blocked"` with concrete remediation instructions
   (which path to add to System Settings > Privacy & Security >
   Accessibility) -- **never a hang, never fabricated numbers.**
4. On success: injects `--count` keys at randomized intervals, timing each
   with `current_media_time()` -- prefers `Quartz.CACurrentMediaTime()`
   (the literal Apple function) when available, else a pure-stdlib `ctypes`
   `mach_absolute_time()` + `mach_timebase_info()` computation (both were
   empirically cross-checked to agree to ~4us while writing this script --
   they are the same timebase as `MTLDrawable.presentedTime`, per Apple's
   docs for both APIs: "current absolute time, in seconds" /
   "host time, in seconds, when the drawable was displayed onscreen").
5. Pairs each injection with the **next** `metal_present` line at or after
   its timestamp (greedy forward match, each frame claimed by at most one
   injection, so a burst of idle frames between two injections is correctly
   skipped rather than double-counted) and emits a p50/p90/p99 histogram.

### Output JSON schema

Written to `.omc/baselines/latency-<UTC-timestamp>[-<label>].json`:

```jsonc
{
  "timestamp": "...", "kitty_version": "...", "machine": {...}, "display": {...},
  "power_source": {"source": "AC" | "battery" | null, "raw": "..."},
  "window_state": "normal (harness always launches a non-fullscreen window; ...)",
  "injection_method": "quartz-cgeventpost" | "coarse-osascript",
  "injection_timing": "precise-cgeventpost" | "coarse-osascript",
  "accessibility_preflight": {"available": false, "reason": "..."},
  "pre_canary_quiescent": true,
  "blocked": null,  // or {"reason": "...", "clean_shutdown": true} if injection never reached the window
  "config": {"count": 100, "min_interval_ms": 80.0, "max_interval_ms": 200.0, "seed": null},
  "pairs": [
    {"index": 0, "injected_time": 12345.678, "post_call_overhead_ms": 0.05,
     "frame": 42, "presented_time": 12345.686, "latency_ms": 8.1}
    // or {"frame": null, "latency_ms": null, "note": "no presented frame found ..."} if unpaired
  ],
  "histogram_ms": {
    "p50": 8.1, "p90": 12.4, "p99": 16.9, "min": 4.2, "max": 20.1,
    "count_paired": 98, "count_unpaired": 2, "presented_frame_count_dropped_zero": 1
  },
  "clean_shutdown": true
}
```

Window/power-source state is logged alongside every run because both are
documented confounds for terminal latency measurement
(danluu.com/term-latency).

## Golden-image capture + compare

```sh
python3.14 scripts/metal-golden.py capture                              # -> .omc/golden/<config>.png + manifest.json
python3.14 scripts/metal-golden.py capture --output-dir .omc/golden/gl-baseline --configs default-opaque bgimage
python3.14 scripts/metal-golden.py compare .omc/golden/gl-baseline .omc/golden/metal-run1
```

The Phase-0 pixel-correctness gate every later phase's regression check
builds on (plan SS6: "Golden-image gate = all configs diff <=1 LSB vs GL
reference via `KITTY_METAL_DUMP_FRAME`").

`capture` renders a fixed config matrix -- `default-opaque`,
`background_opacity_0.85`, `cursor_trail` (`cursor_trail=20`, enabling the
layered-render code path; the trail *animation* itself isn't specifically
exercised by the static content, only the "option is on" render path),
`bgimage` (`background_image=logo/kitty-128.png`) -- against one shared
deterministic content script (`scripts/_golden_content_helper.py`: 16/256/
truecolor SGR text, common ligature-trigger sequences, emoji, a fixed
cursor position, then a settle sleep). `cursor_blink_interval=0` is forced
for every config (same false-positive-avoidance reasoning as the latency
harness -- verified empirically: two captures of the same config differed
by a few bytes before this fix, byte-identical after it). Each config's
`-o` overrides and success/failure are recorded in `manifest.json`
alongside the PNGs; a capture that has to be forcibly terminated is
discarded (its PNG deleted), never left around masquerading as valid data.

`compare` matches PNGs by filename between two directories, decodes with
Pillow, and computes the max absolute per-channel difference
(`PIL.ImageChops.difference(...).getextrema()`). Default pass threshold is
1 (an 8-bit LSB); configs present in only one directory are reported as
failures, not silently skipped. Exit code is 0 iff every compared config
passes and none are missing -- suitable as a CI/regression gate.

Verified while writing this tool: two fully independent `capture` runs of
the same machine/build produced **byte-identical** PNGs for all four
configs (`compare` reported `max_diff: 0` on every channel) -- the
offscreen `KITTY_METAL_DUMP_FRAME` path is reproducible run-to-run, which
is what makes it usable as a regression gate at all.

## Operational rules baked into these scripts

(See the team handoff for full context; summarized here since they're
load-bearing for anyone extending this harness. Implemented once in
`scripts/_kitty_harness_common.py` and shared by all three tools.)

- Every kitty launch uses `kitty/launcher/kitty` (the worktree binary,
  asserted to exist) with `--config NONE` **and**
  `-o macos_quit_when_last_window_closed=yes` -- without the latter the app
  stays resident after its child process exits.
- Processes are tracked by exact PID (the `subprocess.Popen` handle) --
  never killed by name or pattern. A hung run gets `SIGTERM`, a 5s grace
  period, then `SIGKILL` as a last resort (`terminate_kitty()`); that run's
  measurements are discarded, not reported.
- `.omc/build.lock`, if present, blocks any benchmark run (30s poll, then a
  loud abort) -- never benchmark a binary that might be mid-write.
