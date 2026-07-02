#!/usr/bin/env python3.14
"""Phase-0 baseline runner for kitty's Metal-backend optimization project.

Drives the already-built kitty binary (kitty/launcher/kitty) through the
Phase-0 measurement matrix and emits a single JSON baseline artifact under
.omc/baselines/. See .omc/plans/2026-07-02-metal-worlds-fastest-optimization.md
SS6 Phase 0 step 3 and SS7 criterion 1, and docs/metal-performance.md.

What it measures:
  1. Throughput: `kitten __benchmark__ --render <scenarios>` (MB/s per
     scenario). NOTE: --render is required -- tools/cmd/benchmark/main.go
     suppresses rendering by default via synchronized-update escape codes
     and only exercises the parser, not the renderer.
  2. devlog-006 replication: a deterministic ~5.4 MB pseudo-Japanese text
     fixture, `cat` x10 inside a live kitty window, mean/stddev ms, flagged
     if variance exceeds 2%.
  3. vtebench, if present on PATH (graceful skip otherwise).
  4. RSS (peak, sampled while kitty is running).
  5. powermetrics package power, only when running as root (graceful skip
     otherwise).
  6. KITTY_METAL_STATS output (frame CPU/GPU ms percentiles, passes/frame),
     parsed against task #1's final metal.m instrumentation line format
     (metal_stats/metal_present); reports "available": false with a note
     rather than fabricating numbers if a build predates that instrumentation.

This script never builds kitty and never fabricates a measurement it could
not actually take: unavailable pieces are recorded with an explicit
"skipped"/"error" note, never a made-up number.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from _kitty_harness_common import (
    REPO_ROOT,
    detect_backend,
    get_display_hz,
    get_kitty_version,
    get_machine_info,
    get_peak_rss_mb,
    parse_presented_lines,
    percentile,
    require_kitty_binary,
    run_in_kitty,
    wait_for_build_lock_clear,
)

KITTEN_BINARY = REPO_ROOT / "kitty" / "launcher" / "kitty.app" / "Contents" / "MacOS" / "kitten"
DEFAULT_BASELINE_DIR = REPO_ROOT / ".omc" / "baselines"
FIXTURE_GENERATOR = Path(__file__).resolve().parent / "gen_japanese_fixture.py"
CAT_TIMING_HELPER = Path(__file__).resolve().parent / "_cat_timing_helper.py"

ALL_THROUGHPUT_SCENARIOS = ["ascii", "unicode", "csi", "images", "long_escape_codes"]
# Exact `desc` strings from tools/cmd/benchmark/main.go -> our JSON keys.
SCENARIO_DESC_TO_KEY = {
    "Only ASCII chars": "ascii",
    "Unicode chars": "unicode",
    "CSI codes with few chars": "csi",
    "Images": "images",
    "Long escape codes": "long_escape_codes",
}

_ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")
_RESULT_LINE_RE = re.compile(r"^\s*(.+?)\s*:\s*(\S+)\s*@\s*([\d.]+)\s*MB/s\s*$")
# Order matters: "ms" must be tried before "m" (a prefix of it).
_DUR_TOKEN_RE = re.compile(r"(\d+(?:\.\d+)?)(h|ms|µs|μs|us|ns|s|m)")
_DUR_UNIT_TO_MS = {
    "h": 3_600_000.0, "m": 60_000.0, "s": 1000.0, "ms": 1.0,
    "µs": 0.001, "μs": 0.001, "us": 0.001, "ns": 0.000_001,
}
# metal_stats line format (kitty/metal.m; Wave-2 final):
#   metal_stats frame=<uint64> encode_ms=<float.3> gpu_ms=<float.3>
#     passes=<int> allocs=<int> bytes=<uint64> drawable_wait_ms=<float.3>
# The trailing three fields are optional here so pre-Wave-2 builds still
# parse. encode_ms was REDEFINED in Wave 2: it now spans drawable-acquired ->
# commit (encoding only); the drawable-pool wait that used to pollute it is
# reported separately as drawable_wait_ms. Never anchor new fields with $ --
# the format grows tail-first by design. (The companion metal_present line is
# parsed by the shared parse_presented_lines() in _kitty_harness_common.)
_STATS_LINE_RE = re.compile(
    r"^metal_stats\s+frame=(?P<frame>\d+)\s+encode_ms=(?P<encode>[\d.]+)\s+gpu_ms=(?P<gpu>[\d.]+)"
    r"\s+passes=(?P<passes>\d+)(?:\s+allocs=(?P<allocs>\d+))?(?:\s+bytes=(?P<bytes>\d+))?"
    r"(?:\s+drawable_wait_ms=(?P<wait>[\d.]+))?\s*$",
    re.MULTILINE,
)


def strip_ansi(text: str) -> str:
    return _ANSI_RE.sub("", text)


def parse_go_duration_ms(text: str) -> float | None:
    """Parse a Go time.Duration.String() value (e.g. "45.23ms", "1.5s") to ms."""
    text = text.strip()
    if not text:
        return None
    if text in ("0", "0s"):
        return 0.0
    total_ms = 0.0
    matched_any = False
    for m in _DUR_TOKEN_RE.finditer(text):
        value, unit = m.groups()
        total_ms += float(value) * _DUR_UNIT_TO_MS[unit]
        matched_any = True
    return total_ms if matched_any else None


def run_throughput_scenarios(
    scenarios: list[str], repetitions: int, timeout: float,
    metal_stats_env: dict[str, str], stats_stderr_path: Path,
) -> dict[str, Any]:
    require_kitty_binary()
    if not KITTEN_BINARY.exists():
        return {"scenarios": {"_error": {"message": f"kitten binary not found at {KITTEN_BINARY}"}}, "peak_rss_kb": None}

    cmd = [str(KITTEN_BINARY), "__benchmark__", "--render", "--repetitions", str(repetitions)] + scenarios
    result = run_in_kitty(cmd, timeout=timeout, extra_env=metal_stats_env, capture_stderr_to=stats_stderr_path)
    if result["timed_out"]:
        # The kitty process had to be forcibly terminated (SIGTERM/SIGKILL)
        # after exceeding the timeout -- whatever partial output it produced
        # is not a trustworthy measurement. Discard it entirely rather than
        # parsing and reporting fragments as real numbers.
        return {
            "scenarios": {"_error": {
                "message": (
                    "kitty process exceeded the timeout and was forcibly terminated "
                    "(SIGTERM, then SIGKILL after 5s) -- run INVALID, no throughput "
                    "numbers reported"
                ),
                "returncode": result["returncode"],
                "timed_out": True,
            }},
            "peak_rss_kb": result["peak_rss_kb"],
        }
    text = strip_ansi(result["child_output"])

    parsed: dict[str, Any] = {}
    for line in text.splitlines():
        m = _RESULT_LINE_RE.match(line)
        if not m:
            continue
        desc, dur_str, rate_str = m.groups()
        key = SCENARIO_DESC_TO_KEY.get(desc.strip(), desc.strip())
        parsed[key] = {"desc": desc.strip(), "duration_ms": parse_go_duration_ms(dur_str), "mbps": float(rate_str)}

    if not parsed:
        parsed["_error"] = {
            "message": "no scenario result lines parsed from `kitten __benchmark__` output",
            "returncode": result["returncode"],
            "timed_out": result["timed_out"],
            "raw_output_excerpt": text[:2000],
        }
    return {"scenarios": parsed, "peak_rss_kb": result["peak_rss_kb"]}


def run_devlog006(fixture_path: Path, reps: int, timeout: float) -> dict[str, Any]:
    require_kitty_binary()
    with tempfile.TemporaryDirectory(prefix="kitty-bench-cat-") as td:
        out_json = Path(td) / "cat_timing.json"
        cmd = [sys.executable, str(CAT_TIMING_HELPER), str(fixture_path), str(reps), str(out_json)]
        result = run_in_kitty(cmd, timeout=timeout)
        if result["timed_out"]:
            # Forcibly terminated after the timeout -- any partial timing
            # samples the helper may have buffered were never flushed (it
            # only writes JSON after all reps complete), but be explicit
            # and loud about the invalidation regardless of what's on disk.
            return {
                "error": (
                    "kitty process exceeded the timeout and was forcibly terminated "
                    "(SIGTERM, then SIGKILL after 5s) -- run INVALID, no devlog006 "
                    "timing reported"
                ),
                "returncode": result["returncode"],
                "timed_out": True,
                "peak_rss_kb": result["peak_rss_kb"],
            }
        if not out_json.exists():
            return {
                "error": "cat timing helper produced no output file",
                "returncode": result["returncode"],
                "timed_out": result["timed_out"],
                "raw_child_output_excerpt": result["child_output"][:2000],
                "peak_rss_kb": result["peak_rss_kb"],
            }
        data = json.loads(out_json.read_text())

    samples = data.get("samples_ms", [])
    errors = data.get("errors", [])
    if not samples:
        return {"error": "no successful `cat` runs completed", "errors": errors, "peak_rss_kb": result["peak_rss_kb"]}

    mean = statistics.fmean(samples)
    stddev = statistics.stdev(samples) if len(samples) > 1 else 0.0
    variance_pct = (stddev / mean * 100.0) if mean else 0.0
    return {
        "ms_mean": mean,
        "ms_stddev": stddev,
        "variance_pct": variance_pct,
        "flagged_high_variance": variance_pct > 2.0,
        "samples_ms": samples,
        "reps_completed": len(samples),
        "reps_requested": reps,
        "errors": errors,
        "fixture_bytes": fixture_path.stat().st_size,
        "fixture_sha256": hashlib.sha256(fixture_path.read_bytes()).hexdigest(),
        "peak_rss_kb": result["peak_rss_kb"],
        "note": (
            "Wall-clock time for `cat` to write the file to the pty, matching the "
            "ghostty devlog-006 methodology exactly. Terminal parsing/rendering is "
            "typically asynchronous with the writing process, so this is a "
            "faithful replication of that benchmark's number, not a guarantee the "
            "screen has finished repainting when `cat` returns."
        ),
    }


def physics_check_devlog006(dv: dict[str, Any], ascii_mbps: float | None) -> dict[str, Any]:
    """Sanity-gate the devlog006 `cat` timing against the ascii throughput
    scenario measured in the SAME run: both exercise the SAME pty/parser, so
    devlog006's implied ingestion rate cannot legitimately exceed the ascii
    scenario's measured ceiling by more than a modest margin (1.5x, for
    unicode-vs-ascii parsing-cost differences). If it does, that is proof the
    measurement bypassed the pty rather than a real result.

    Caught exactly this way on 2026-07-02: a stdout-redirection bug in
    _cat_timing_helper.py (cat inherited this process's own redirected fd 1
    instead of writing to /dev/tty) made devlog006 measure file I/O, not
    terminal ingestion -- 5.4 MB in ~5.2 ms implied ~1 GB/s, ~10x the ascii
    scenario's 101.5 MB/s ceiling in the same baseline JSON. Fixed in
    _cat_timing_helper.py (explicit /dev/tty write); this check stays as a
    permanent regression gate against that class of bug recurring silently.
    """
    if "ms_mean" not in dv or "fixture_bytes" not in dv or dv["ms_mean"] <= 0:
        return dv  # nothing to check (error/skipped result)
    implied_mbps = (dv["fixture_bytes"] / (1024.0 * 1024.0)) / (dv["ms_mean"] / 1000.0)
    if ascii_mbps is None:
        dv["physics_check"] = {
            "performed": False, "implied_mbps": implied_mbps,
            "reason": "ascii scenario mbps not available to compare against (--skip-throughput or ascii scenario failed)",
        }
        return dv
    limit_mbps = ascii_mbps * 1.5
    passed = implied_mbps <= limit_mbps
    dv["physics_check"] = {
        "performed": True, "implied_mbps": implied_mbps,
        "ascii_mbps": ascii_mbps, "limit_mbps": limit_mbps, "passed": passed,
    }
    if not passed:
        dv["invalid"] = True
        dv["invalid_reason"] = "physics_check_failed"
    return dv


def run_vtebench() -> dict[str, Any]:
    exe = shutil.which("vtebench")
    if not exe:
        return {"skipped": True, "reason": "vtebench not found on PATH"}
    try:
        proc = subprocess.run([exe, "--help"], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return {"skipped": True, "reason": f"vtebench found on PATH but failed to invoke: {exc}"}
    return {
        "skipped": True,
        "reason": (
            "vtebench is present on PATH but this harness does not drive it "
            "end-to-end yet (its CLI/output format was unverified -- no vtebench "
            "binary was available to test against while writing this script). "
            "Run it manually; see docs/metal-performance.md."
        ),
        "help_excerpt": (proc.stdout or proc.stderr)[:500],
    }


def run_powermetrics(duration_s: float) -> dict[str, Any]:
    if os.geteuid() != 0:
        return {"skipped": True, "reason": "powermetrics requires root; re-run this script with sudo to include package power"}
    try:
        proc = subprocess.run(
            ["powermetrics", "--samplers", "cpu_power", "-i", "1000", "-n", str(max(1, int(duration_s)))],
            capture_output=True, text=True, timeout=duration_s + 15,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return {"skipped": True, "reason": f"powermetrics invocation failed: {exc}"}

    watts = [float(m.group(1)) / 1000.0 for m in re.finditer(r"Combined Power \(CPU \+ GPU \+ ANE\):\s*([\d.]+)\s*mW", proc.stdout)]
    if not watts:
        watts = [float(m.group(1)) / 1000.0 for m in re.finditer(r"Package Power:\s*([\d.]+)\s*mW", proc.stdout)]
    if not watts:
        return {"skipped": True, "reason": "powermetrics ran but no recognizable power line was found in its output", "raw_excerpt": proc.stdout[:1000]}
    return {"mean_w": statistics.fmean(watts), "samples_w": watts}


def parse_metal_stats(text: str) -> dict[str, Any]:
    """Parse KITTY_METAL_STATS output for frame CPU/GPU ms and passes/frame.

    Line formats are fixed by task #1's metal.m instrumentation (see
    _STATS_LINE_RE above and the shared parse_presented_lines() docstring in
    _kitty_harness_common, which also drops presented_time==0.000000000
    rows -- a known first-drawable quirk).
    """
    cpu_ms: list[float] = []
    gpu_ms: list[float] = []
    passes: list[float] = []
    wait_ms: list[float] = []
    for m in _STATS_LINE_RE.finditer(text):
        cpu_ms.append(float(m.group("encode")))
        gpu_ms.append(float(m.group("gpu")))
        passes.append(float(m.group("passes")))
        if m.group("wait") is not None:
            wait_ms.append(float(m.group("wait")))
    presented, dropped_zero = parse_presented_lines(text)

    available = bool(cpu_ms or gpu_ms or passes or presented)
    return {
        "available": available,
        "cpu_ms_p50": percentile(cpu_ms, 50), "cpu_ms_p99": percentile(cpu_ms, 99),
        "gpu_ms_p50": percentile(gpu_ms, 50), "gpu_ms_p99": percentile(gpu_ms, 99),
        "drawable_wait_ms_p50": percentile(wait_ms, 50),
        "drawable_wait_ms_p99": percentile(wait_ms, 99),
        "passes_per_frame": (sum(passes) / len(passes)) if passes else None,
        "presented_frame_count": len(presented),
        "presented_frame_count_dropped_zero": dropped_zero,
        "note": None if available else (
            "no metal_stats/metal_present lines observed -- requires the build to "
            "include task #1's metal.m instrumentation, run with KITTY_METAL_STATS=1 "
            "(and/or KITTY_METAL_STATS_FILE=<path>). Expected line formats: "
            "'metal_stats frame=<uint64> encode_ms=<float> gpu_ms=<float> passes=<int>' "
            "and 'metal_present frame=<uint64> presented_time=<float seconds>'."
        ),
    }


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--backend", choices=["auto", "metal", "gl"], default="auto", help="label for the output JSON (default: auto-detect)")
    parser.add_argument("--scenarios", nargs="+", default=ALL_THROUGHPUT_SCENARIOS, choices=ALL_THROUGHPUT_SCENARIOS, help="kitten __benchmark__ scenarios to run")
    parser.add_argument("--repetitions", type=int, default=100, help="kitten __benchmark__ --repetitions (default: 100)")
    parser.add_argument("--render-timeout", type=float, default=180.0, help="seconds to wait for the throughput scenario window (default: 180)")
    parser.add_argument("--devlog006-reps", type=int, default=10, help="number of `cat` repetitions for the devlog-006 replication (default: 10)")
    parser.add_argument("--cat-timeout", type=float, default=120.0, help="seconds to wait for the devlog-006 window (default: 120)")
    parser.add_argument("--fixture-seed", type=int, default=5361, help="seed for the Japanese fixture generator")
    parser.add_argument("--fixture-size-bytes", type=int, default=5_400_000, help="target fixture size in bytes (default: 5,400,000)")
    parser.add_argument("--display-hz", type=float, default=None, help="override auto-detected main display refresh rate")
    parser.add_argument("--powermetrics-duration", type=float, default=5.0, help="seconds of powermetrics sampling when run as root (default: 5)")
    parser.add_argument("--skip-throughput", action="store_true", help="skip the kitten __benchmark__ scenarios")
    parser.add_argument("--skip-devlog006", action="store_true", help="skip the devlog-006 cat replication")
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_BASELINE_DIR, help="directory to write the JSON baseline into")
    parser.add_argument("--label", default=None, help="extra label appended to the output filename")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_arg_parser().parse_args(argv)
    require_kitty_binary()
    wait_for_build_lock_clear()

    backend, backend_note = detect_backend(None if args.backend == "auto" else args.backend)
    print(f"[metal-baseline] backend={backend} ({backend_note})", file=sys.stderr)

    hz, hz_note = get_display_hz(args.display_hz)

    report: dict[str, Any] = {
        "backend": backend,
        "backend_detection_note": backend_note,
        "machine": get_machine_info(),
        "display": {"hz": hz, "note": hz_note},
        "kitty_version": get_kitty_version(),
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "config": {
            "config_file": "NONE",
            "overrides": ["macos_quit_when_last_window_closed=yes", "update_check_interval=0"],
            "repetitions": args.repetitions,
            "scenarios_requested": args.scenarios,
            "fixture_seed": args.fixture_seed,
            "fixture_size_bytes": args.fixture_size_bytes,
            "devlog006_reps": args.devlog006_reps,
        },
        "scenarios": {},
        "frames": None,
        "rss_mb": None,
        "power_w": None,
        "power_details": None,
    }

    peak_rss_kb: list[int] = []

    with tempfile.TemporaryDirectory(prefix="kitty-metal-stats-") as stats_td:
        stats_stderr_path = Path(stats_td) / "kitty_stderr.txt"
        stats_file_path = Path(stats_td) / "kitty_metal_stats.txt"
        metal_stats_env = {"KITTY_METAL_STATS": "1", "KITTY_METAL_STATS_FILE": str(stats_file_path)}

        if not args.skip_throughput:
            print(f"[metal-baseline] running kitten __benchmark__ --render {' '.join(args.scenarios)} ...", file=sys.stderr)
            tp = run_throughput_scenarios(args.scenarios, args.repetitions, args.render_timeout, metal_stats_env, stats_stderr_path)
            report["scenarios"].update(tp["scenarios"])
            if tp.get("peak_rss_kb"):
                peak_rss_kb.append(tp["peak_rss_kb"])
        else:
            report["scenarios"]["_throughput"] = {"skipped": True, "reason": "--skip-throughput"}

        stats_text = ""
        if stats_file_path.exists() and stats_file_path.stat().st_size > 0:
            stats_text += stats_file_path.read_text(errors="replace")
        if stats_stderr_path.exists() and stats_stderr_path.stat().st_size > 0:
            stats_text += "\n" + stats_stderr_path.read_text(errors="replace")
        report["frames"] = parse_metal_stats(stats_text)
        # Empirical override: metal_stats/metal_present lines can only be
        # emitted by code compiled under #ifdef KITTY_USE_METAL (kitty/metal.m)
        # -- if we captured real frame stats, this is unambiguously a Metal
        # build and run, regardless of what the filesystem-based
        # default.metallib search above guessed (that search can miss dev
        # layouts where the metallib was never copied into the .app bundle).
        # One-directional: absence of frame stats does NOT imply "gl" (could
        # just be --skip-throughput), so no correction is made the other way.
        if report["backend"] != "metal" and report["frames"]["available"]:
            report["backend_detection_note"] = (
                f"filesystem search said backend={report['backend']} ({report['backend_detection_note']}), "
                "but real metal_stats/metal_present lines were captured -- that code path only exists in "
                "Metal builds, so backend is corrected to 'metal'"
            )
            report["backend"] = "metal"

    if not args.skip_devlog006:
        print("[metal-baseline] generating Japanese fixture + running devlog-006 `cat` replication ...", file=sys.stderr)
        with tempfile.TemporaryDirectory(prefix="kitty-fixture-") as fx_td:
            fixture_path = Path(fx_td) / "japanese_fixture.txt"
            gen = subprocess.run(
                [sys.executable, str(FIXTURE_GENERATOR), "--seed", str(args.fixture_seed),
                 "--size-bytes", str(args.fixture_size_bytes), "--output", str(fixture_path)],
                capture_output=True, text=True, timeout=60,
            )
            if gen.returncode != 0 or not fixture_path.exists():
                report["scenarios"]["devlog006_cat_ja"] = {"error": "fixture generation failed", "stderr": gen.stderr[-2000:]}
            else:
                dv = run_devlog006(fixture_path, args.devlog006_reps, args.cat_timeout)
                ascii_result = report["scenarios"].get("ascii")
                ascii_mbps = ascii_result.get("mbps") if isinstance(ascii_result, dict) else None
                dv = physics_check_devlog006(dv, ascii_mbps)
                if dv.get("invalid"):
                    print(f"[metal-baseline] WARNING: devlog006 failed its physics check ({dv['physics_check']}) -- marked invalid", file=sys.stderr)
                report["scenarios"]["devlog006_cat_ja"] = dv
                if dv.get("peak_rss_kb"):
                    peak_rss_kb.append(dv["peak_rss_kb"])
    else:
        report["scenarios"]["devlog006_cat_ja"] = {"skipped": True, "reason": "--skip-devlog006"}

    print("[metal-baseline] checking for vtebench ...", file=sys.stderr)
    report["scenarios"]["vtebench"] = run_vtebench()

    print("[metal-baseline] checking for powermetrics (root only) ...", file=sys.stderr)
    pm = run_powermetrics(args.powermetrics_duration)
    report["power_details"] = pm
    report["power_w"] = pm.get("mean_w")

    report["rss_mb"] = get_peak_rss_mb(peak_rss_kb)

    args.output_dir.mkdir(parents=True, exist_ok=True)
    ts_compact = report["timestamp"].replace(":", "").replace("-", "")
    label = f"-{args.label}" if args.label else ""
    out_path = args.output_dir / f"{ts_compact}-{backend}{label}.json"
    payload = json.dumps(report, indent=2, sort_keys=True)
    out_path.write_text(payload + "\n")
    print(f"[metal-baseline] wrote {out_path}", file=sys.stderr)
    print(payload)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
