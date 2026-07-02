#!/usr/bin/env python3.14
"""Keypress-to-presented latency harness for kitty's Metal-backend
optimization project. See
.omc/plans/2026-07-02-metal-worlds-fastest-optimization.md SS6 Phase 0 step 2
and SS12 methodology, and docs/metal-performance.md.

No published harness pairs synthetic key-event injection with real
present/photon timestamps (precedent: thume.ca's kdebug_signpost technique;
WWDC18-405 Points of Interest). This one does:

  1. Launches the built kitty (kitty/launcher/kitty) running its default
     interactive shell, with KITTY_METAL_STATS=1 and KITTY_METAL_SIGNPOST=1
     directed to a file.
  2. Injects N single-key events (default: Space, which is inert at any
     shell prompt without Enter -- never actually executes anything) via
     CGEventPost (pyobjc's Quartz) at randomized 80-200ms intervals --
     randomization avoids vsync aliasing (Dan Luu's terminal-latency
     methodology, danluu.com/term-latency). Falls back to an AppleScript
     `System Events keystroke` if Quartz/pyobjc is unavailable, flagged
     with injection_timing="coarse-osascript" since that path has much
     higher and less predictable dispatch jitter.
  3. Times each injection with a CACurrentMediaTime()-equivalent timestamp
     (same timebase as MTLDrawable.presentedTime -- see current_media_time()
     below) and pairs it with the NEXT metal_present line emitted after it.
  4. Emits a p50/p90/p99 latency histogram to
     .omc/baselines/latency-<timestamp>.json, alongside window/power-source
     state (confounds per danluu.com/term-latency).

CGEventPost requires Accessibility permission for whatever process is
calling it. This is detected two ways: CGPreflightPostEventAccess() (an
informative, non-prompting preflight check) and, authoritatively, an
empirical canary injection verified against real stats output before the
full run starts. If injection isn't actually working, this script prints
clear remediation instructions and exits without fabricating any numbers --
it never silently hangs or reports fake data.
"""

from __future__ import annotations

import argparse
import ctypes
import json
import random
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from _kitty_harness_common import (
    REPO_ROOT,
    get_display_hz,
    get_kitty_version,
    get_machine_info,
    get_power_source,
    parse_presented_lines,
    percentile,
    require_kitty_binary,
    spawn_kitty,
    terminate_kitty,
    wait_for_build_lock_clear,
)

DEFAULT_OUTPUT_DIR = REPO_ROOT / ".omc" / "baselines"

# macOS virtual keycode for the Space key (Carbon/HIToolbox kVK_Space =
# 0x31). Space is used as the default injected key because it is completely
# inert when typed at any shell prompt without a following Enter/Return --
# this script never sends Enter, so injected keys never execute anything.
KVK_SPACE = 0x31


# --- Timestamp source: same timebase as MTLDrawable.presentedTime --------
#
# Apple docs confirm CACurrentMediaTime() "returns the current absolute
# time, in seconds" derived from the Mach absolute time clock, and
# MTLDrawable.presentedTime is documented as "host time, in seconds, when
# the drawable was displayed onscreen" -- the same timebase. Empirically
# verified while writing this script: Quartz.CACurrentMediaTime() and an
# independent ctypes mach_absolute_time()*timebase.numer/denom/1e9
# computation agreed to within ~4 microseconds on the dev machine.
class _MachTimebaseInfo(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


def _make_mach_time_fn():
    lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    lib.mach_absolute_time.restype = ctypes.c_uint64
    info = _MachTimebaseInfo()
    rc = lib.mach_timebase_info(ctypes.byref(info))
    if rc != 0 or info.denom == 0:
        raise OSError(f"mach_timebase_info failed (rc={rc})")
    scale = info.numer / info.denom / 1e9

    def _now() -> float:
        return lib.mach_absolute_time() * scale

    return _now


try:
    import Quartz  # pyobjc
    _HAVE_QUARTZ = True
except ImportError:
    Quartz = None  # type: ignore[assignment]
    _HAVE_QUARTZ = False

_mach_time_fallback = _make_mach_time_fn()


def current_media_time() -> float:
    """CACurrentMediaTime()-equivalent host time in seconds -- the same
    timebase as MTLDrawable.presentedTime. Prefers the literal Apple
    function (via pyobjc) when available; falls back to a pure-stdlib
    ctypes mach_absolute_time computation otherwise (see module docstring).
    """
    if _HAVE_QUARTZ:
        return Quartz.CACurrentMediaTime()
    return _mach_time_fallback()


# --- Key injection ---------------------------------------------------------

class InjectionUnavailable(Exception):
    pass


def check_quartz_preflight() -> dict[str, Any]:
    if not _HAVE_QUARTZ:
        return {"available": False, "reason": "Quartz (pyobjc-framework-Quartz) not importable"}
    try:
        preflight = bool(Quartz.CGPreflightPostEventAccess())
    except AttributeError:
        # Older pyobjc/macOS without this preflight API -- not fatal, the
        # empirical canary check is the authoritative gate regardless.
        return {"available": None, "reason": "CGPreflightPostEventAccess not available in this pyobjc/macOS version"}
    return {"available": preflight, "reason": None if preflight else "CGPreflightPostEventAccess() returned False (Accessibility permission not granted)"}


def inject_key_quartz(keycode: int = KVK_SPACE) -> None:
    down = Quartz.CGEventCreateKeyboardEvent(None, keycode, True)
    up = Quartz.CGEventCreateKeyboardEvent(None, keycode, False)
    Quartz.CGEventPost(Quartz.kCGSessionEventTap, down)
    Quartz.CGEventPost(Quartz.kCGSessionEventTap, up)


def inject_key_osascript() -> None:
    # `keystroke " "` synthesizes a single inert space keypress via System
    # Events, which requires its own Accessibility/Automation grant. Coarser
    # than CGEventPost: each call spawns a whole osascript process, adding
    # unpredictable dispatch jitter to the injection timestamp -- see
    # injection_timing="coarse-osascript" in the output JSON.
    subprocess.run(
        ["osascript", "-e", 'tell application "System Events" to keystroke " "'],
        capture_output=True, text=True, timeout=5, check=True,
    )


def remediation_instructions() -> str:
    return (
        f"Key injection did not reach the target window. Grant Accessibility access to the "
        f"process running this script ({sys.executable}) in System Settings > Privacy & Security "
        f"> Accessibility, then re-run. If that specific path doesn't appear or doesn't fix it, "
        f"the enclosing terminal/orchestrating application (whatever launched {sys.executable}) "
        f"may need the grant instead -- macOS attributes Accessibility/TCC permission to the "
        f"top-level responsible application for deeply nested subprocess trees."
    )


# --- Pairing + stats ---------------------------------------------------------

def pair_injections_to_presents(
    injections: list[dict[str, Any]], presents: list[tuple[int, float]],
) -> list[dict[str, Any]]:
    """For each injection (in time order), find the NEXT not-yet-claimed
    metal_present event at or after its timestamp (task spec: "pairs each
    injection timestamp with the NEXT presented-time line"). Greedy
    forward two-pointer match: O(n+m), each present consumed at most once so
    two injections never claim the same frame; frames not immediately
    following any injection (e.g. idle cursor-blink presents) are correctly
    left unpaired.
    """
    pairs: list[dict[str, Any]] = []
    pi = 0
    n = len(presents)
    for inj in injections:
        t_inject = inj["injected_time"]
        while pi < n and presents[pi][1] < t_inject:
            pi += 1
        if pi < n:
            frame, t_present = presents[pi]
            pi += 1
            pairs.append({
                **inj, "frame": frame, "presented_time": t_present,
                "latency_ms": (t_present - t_inject) * 1000.0,
            })
        else:
            pairs.append({**inj, "frame": None, "presented_time": None, "latency_ms": None,
                           "note": "no presented frame found after this injection (end of capture window)"})
    return pairs


def wait_for_quiescence(read_stats_fn, quiet_for_s: float, max_wait_s: float) -> bool:
    """Poll until no NEW metal_present line has appeared for quiet_for_s
    seconds (bounded by max_wait_s total).

    Without this, a canary injection's "new frame appeared" check can be a
    false positive from trailing startup/deferred rendering (observed
    empirically while writing this script: a fresh window kept emitting a
    small burst of frames for a few hundred ms after its first paint, with
    no input at all) -- attributing that burst to the canary's own
    injection would make the whole permission gate untrustworthy. Waiting
    for the frame stream to go quiet first means a frame appearing shortly
    after the canary injection is actually attributable to it.

    Returns True if quiescence was reached, False if max_wait_s elapsed
    first (the caller still proceeds, but the canary result is a weaker
    signal -- recorded in the report either way).
    """
    deadline = time.monotonic() + max_wait_s
    last_count = -1
    quiet_since = time.monotonic()
    while time.monotonic() < deadline:
        presented, _ = parse_presented_lines(read_stats_fn())
        count = len(presented)
        if count != last_count:
            last_count = count
            quiet_since = time.monotonic()
        elif time.monotonic() - quiet_since >= quiet_for_s:
            return True
        time.sleep(0.05)
    return False


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--count", type=int, default=100, help="number of key injections (default: 100)")
    parser.add_argument("--min-interval-ms", type=float, default=80.0, help="minimum randomized inter-injection gap (default: 80)")
    parser.add_argument("--max-interval-ms", type=float, default=200.0, help="maximum randomized inter-injection gap (default: 200)")
    parser.add_argument("--settle-s", type=float, default=1.0, help="settle time after window launch before injecting (default: 1.0)")
    parser.add_argument("--quiescence-s", type=float, default=0.5, help="required quiet period (no new frames) before the canary counts (default: 0.5)")
    parser.add_argument("--quiescence-max-wait-s", type=float, default=5.0, help="max time to wait for quiescence before proceeding anyway (default: 5.0)")
    parser.add_argument("--canary-timeout-s", type=float, default=2.0, help="seconds to wait for the canary injection's frame (default: 2.0)")
    parser.add_argument("--overall-timeout-s", type=float, default=180.0, help="hard cap on total run time (default: 180)")
    parser.add_argument("--seed", type=int, default=None, help="seed for the randomized intervals (default: unseeded/nondeterministic)")
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT_DIR, help="directory to write the JSON into")
    parser.add_argument("--label", default=None, help="extra label appended to the output filename")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_arg_parser().parse_args(argv)
    require_kitty_binary()
    wait_for_build_lock_clear()

    rng = random.Random(args.seed)
    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    ts_compact = timestamp.replace(":", "").replace("-", "")
    label = f"-{args.label}" if args.label else ""
    args.output_dir.mkdir(parents=True, exist_ok=True)
    out_path = args.output_dir / f"latency-{ts_compact}{label}.json"

    injection_method = "quartz-cgeventpost" if _HAVE_QUARTZ else "coarse-osascript"
    inject_fn = inject_key_quartz if _HAVE_QUARTZ else (lambda: inject_key_osascript())
    preflight = check_quartz_preflight() if _HAVE_QUARTZ else {"available": None, "reason": "Quartz unavailable, using osascript fallback"}

    report: dict[str, Any] = {
        "timestamp": timestamp,
        "kitty_version": get_kitty_version(),
        "machine": get_machine_info(),
        "display": dict(zip(("hz", "note"), get_display_hz(None))),
        "power_source": get_power_source(),
        "window_state": "normal (harness always launches a non-fullscreen window; no window-state confound applies)",
        "injection_method": injection_method,
        "injection_timing": "precise-cgeventpost" if _HAVE_QUARTZ else "coarse-osascript",
        "accessibility_preflight": preflight,
        "config": {
            "count": args.count, "min_interval_ms": args.min_interval_ms,
            "max_interval_ms": args.max_interval_ms, "seed": args.seed,
        },
        "blocked": None,
        "histogram_ms": None,
        "pairs": None,
    }

    print(f"[metal-latency] injection_method={injection_method} preflight={preflight}", file=sys.stderr)

    stats_dir = Path(tempfile.mkdtemp(prefix="kitty-latency-"))
    stats_file_path = stats_dir / "kitty_metal_stats.txt"
    proc = spawn_kitty(
        extra_env={
            "KITTY_METAL_STATS": "1", "KITTY_METAL_SIGNPOST": "1", "KITTY_METAL_STATS_FILE": str(stats_file_path),
        },
        # Disable cursor blink: it is the only source of idle (non-input-
        # driven) frame production at a bare shell prompt, and left enabled
        # it would let a coincidental blink frame during the canary/settle
        # windows falsely "confirm" injection -- see cursor_blink_interval=0
        # "Set to zero to disable blinking" (kitty/options/definition.py).
        # With it off, every post-injection frame is unambiguously
        # input-driven, which the canary check and the injection<->present
        # pairing both depend on.
        extra_kitty_opts=["cursor_blink_interval=0"],
    )
    print(f"[metal-latency] launched kitty pid={proc.pid}, settling {args.settle_s}s ...", file=sys.stderr)

    def read_stats() -> str:
        return stats_file_path.read_text(errors="replace") if stats_file_path.exists() else ""

    def close_and_report_blocked(reason: str) -> int:
        clean = terminate_kitty(proc)
        report["blocked"] = {"reason": reason, "clean_shutdown": clean}
        payload = json.dumps(report, indent=2, sort_keys=True)
        out_path.write_text(payload + "\n")
        print(f"[metal-latency] BLOCKED: {reason}", file=sys.stderr)
        print(f"[metal-latency] wrote {out_path} (blocked, no fabricated numbers)", file=sys.stderr)
        print(payload)
        return 1

    try:
        overall_deadline = time.monotonic() + args.overall_timeout_s
        time.sleep(args.settle_s)

        if proc.poll() is not None:
            return close_and_report_blocked(f"kitty exited immediately (returncode={proc.returncode}) before any injection")

        # Empirical canary: the authoritative check for "is injection
        # actually working", per-task requirement to detect the failure
        # (event not delivered) rather than trust a permission bit alone.
        # Wait for the frame stream to go quiet first so a subsequent "new
        # frame" is actually attributable to the canary's own injection,
        # not trailing startup rendering (see wait_for_quiescence()).
        print(f"[metal-latency] waiting for pre-canary quiescence ({args.quiescence_s}s quiet, up to {args.quiescence_max_wait_s}s) ...", file=sys.stderr)
        quiescent = wait_for_quiescence(read_stats, args.quiescence_s, args.quiescence_max_wait_s)
        report["pre_canary_quiescent"] = quiescent
        print(f"[metal-latency] quiescence reached={quiescent}; injecting canary key ...", file=sys.stderr)
        baseline_presented, _ = parse_presented_lines(read_stats())
        baseline_max_frame = max((f for f, _ in baseline_presented), default=-1)
        try:
            t_canary = current_media_time()
            inject_fn()
        except Exception as exc:  # noqa: BLE001 -- surfacing any injection backend failure as a clean block, not a crash
            return close_and_report_blocked(f"canary injection raised {type(exc).__name__}: {exc}. {remediation_instructions()}")

        canary_ok = False
        canary_deadline = time.monotonic() + args.canary_timeout_s
        while time.monotonic() < canary_deadline:
            presented, _ = parse_presented_lines(read_stats())
            if any(f > baseline_max_frame and t >= t_canary for f, t in presented):
                canary_ok = True
                break
            time.sleep(0.05)

        if not canary_ok:
            return close_and_report_blocked(
                f"canary key injection produced no new presented frame within {args.canary_timeout_s}s "
                f"(event not delivered -- {injection_method}). {remediation_instructions()}"
            )
        print("[metal-latency] canary confirmed -- injection is reaching the window", file=sys.stderr)

        injections: list[dict[str, Any]] = []
        for i in range(args.count):
            if time.monotonic() > overall_deadline:
                print(f"[metal-latency] overall timeout hit after {i}/{args.count} injections, stopping early", file=sys.stderr)
                break
            gap_s = rng.uniform(args.min_interval_ms, args.max_interval_ms) / 1000.0
            time.sleep(gap_s)
            t_before = current_media_time()
            inject_fn()
            t_after = current_media_time()
            injections.append({
                "index": i, "injected_time": t_before, "post_call_overhead_ms": (t_after - t_before) * 1000.0,
            })

        # Let the last frame(s) actually present before reading final stats.
        time.sleep(0.5)
        stats_text = read_stats()
    finally:
        clean_shutdown = terminate_kitty(proc)
        shutil.rmtree(stats_dir, ignore_errors=True)

    presented, dropped_zero = parse_presented_lines(stats_text)
    pairs = pair_injections_to_presents(injections, presented)
    latencies = [p["latency_ms"] for p in pairs if p["latency_ms"] is not None]
    unpaired = len(pairs) - len(latencies)

    report["pairs"] = pairs
    report["histogram_ms"] = {
        "p50": percentile(latencies, 50), "p90": percentile(latencies, 90), "p99": percentile(latencies, 99),
        "min": min(latencies) if latencies else None, "max": max(latencies) if latencies else None,
        "count_paired": len(latencies), "count_unpaired": unpaired,
        "presented_frame_count_dropped_zero": dropped_zero,
    }
    report["clean_shutdown"] = clean_shutdown
    if not clean_shutdown:
        report["blocked"] = {"reason": "kitty required SIGKILL at shutdown -- the trailing tail of this run's data may be incomplete"}

    payload = json.dumps(report, indent=2, sort_keys=True)
    out_path.write_text(payload + "\n")
    print(f"[metal-latency] wrote {out_path}", file=sys.stderr)
    print(payload)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
