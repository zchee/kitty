#!/usr/bin/env python3.14
"""W28.0c: read out the S5 (gate->present) partition from a stats capture.

WALLS v1.2 pins S5 at 6.99 ms p50 quiet, of which encode and gpu together
account for well under a millisecond -- a ~6.2-6.7 ms near-constant that no
existing record attributes. kitty/metal.m now emits the three stamps that
split it, and this script joins them:

    gate->commit         commit_time - the tick's gate stamp
    commit->gpu-done     gpu_end     - commit_time
    gpu-done->presented  presented_time - gpu_end

Sources, all joined on the frame index:

  metal_commit  frame= commit_time= prev_present_frame= prev_present_mono_ms= pace=
                the post-commit CPU stamp (main thread, kitty/metal.m).
  metal_stats   ... gpu_end=<host seconds>
                cb.GPUEndTime, captured in the completion handler.
  metal_present frame= presented_time=
                MTLDrawable.presentedTime, captured in the presented handler.

commit_time, gpu_end and presented_time are all "host time, in seconds ...
relative to system mach time" (Apple's wording for gpuEndTime/presentedTime),
i.e. the CACurrentMediaTime timebase, so those two terms subtract directly.

The gate stamp is the only value on kitty's own clock: the `ktrace:` line's
gate_ms is process-relative monotonic. The `ktrace_epoch:` line reads both
clocks in one instant (mono_ms + mach_ms), which is exactly the shift needed
to put the gate on the mach timebase. Pass the kitty stderr log holding those
lines as --ktrace to get the {gate->commit} term; without it the script still
reports the two GPU-side terms and their sum.

Usage:
    w28_s5_partition.py STATS_FILE [--ktrace LOG] [--json OUT.json]

STATS_FILE is whatever KITTY_METAL_STATS_FILE was pointed at (or a captured
stderr, if it was unset). --ktrace may be the same file when both streams
landed together.
"""

from __future__ import annotations

import argparse
import bisect
import json
import re
import sys
from pathlib import Path
from typing import Any

# Tail-tolerant, never $-anchored: kitty/metal.m grows these records tail-first
# by design, so every pattern here matches a prefix and ignores what follows.
_COMMIT_RE = re.compile(
    r"^metal_commit\s+frame=(?P<frame>\d+)\s+commit_time=(?P<commit>[\d.]+)"
    r"\s+prev_present_frame=(?P<prev_frame>-?\d+)"
    r"\s+prev_present_mono_ms=(?P<prev_ms>-?[\d.]+)"
    r"\s+pace=(?P<pace>\S+)",
    re.MULTILINE,
)
# Paces that represent a normal presented frame. resize (presentsWithTransaction)
# is excluded by default: it commits, waits until scheduled and presents inside a
# CA transaction, so its stage boundaries are not comparable with the steady-state
# paces and mixing it silently skews every percentile.
DEFAULT_PACES = ("immediate", "link", "unsynced")
# gpu_end= is a tail field on the metal_stats line; matched independently of the
# fields before it so this keeps working as that line grows further.
_GPU_END_RE = re.compile(
    r"^metal_stats\s+frame=(?P<frame>\d+)\b.*?\sgpu_end=(?P<gpu_end>[\d.]+)",
    re.MULTILINE,
)
_PRESENT_RE = re.compile(
    r"^metal_present\s+frame=(?P<frame>\d+)\s+presented_time=(?P<presented>[\d.]+)",
    re.MULTILINE,
)
_KTRACE_EPOCH_RE = re.compile(
    r"^ktrace_epoch:\s+mono_ms=(?P<mono>[\d.]+)\s+mach_ms=(?P<mach>[\d.]+)",
    re.MULTILINE,
)
_KTRACE_GATE_RE = re.compile(r"^ktrace:\s+.*?\sgate_ms=(?P<gate>[\d.]+)", re.MULTILINE)


def percentile(values: list[float], pct: float) -> float | None:
    """Nearest-rank percentile, matching _kitty_harness_common.percentile()."""
    if not values:
        return None
    ordered = sorted(values)
    idx = max(0, min(len(ordered) - 1, round(pct / 100.0 * (len(ordered) - 1))))
    return ordered[idx]


def summarize(name: str, values: list[float]) -> dict[str, Any]:
    return {
        "stage": name,
        "n": len(values),
        "p50": percentile(values, 50),
        "p90": percentile(values, 90),
        "p99": percentile(values, 99),
        "min": min(values) if values else None,
        "max": max(values) if values else None,
    }


def parse_frames(stats_text: str) -> dict[int, dict[str, Any]]:
    """Join the three per-frame records by frame index.

    A frame is kept only once all three stamps are present: the completion and
    presented handlers are asynchronous, so the tail of any capture holds frames
    whose stamps had not all arrived when the process was torn down. Dropping
    them is correct -- an incomplete frame cannot contribute a partition -- and
    the count is reported so a large drop is visible rather than silent.
    """
    frames: dict[int, dict[str, Any]] = {}
    for m in _COMMIT_RE.finditer(stats_text):
        e = frames.setdefault(int(m.group("frame")), {})
        e.update(
            commit_time=float(m.group("commit")),
            prev_present_frame=float(m.group("prev_frame")),
            prev_present_mono_ms=float(m.group("prev_ms")),
        )
        e["pace"] = m.group("pace")
    for m in _GPU_END_RE.finditer(stats_text):
        frames.setdefault(int(m.group("frame")), {})["gpu_end"] = float(m.group("gpu_end"))
    for m in _PRESENT_RE.finditer(stats_text):
        presented = float(m.group("presented"))
        # presented_time == 0 is the documented no-op (never presented, or the
        # frame was dropped) -- not a photon, so it is not a partition sample.
        if presented != 0.0:
            frames.setdefault(int(m.group("frame")), {})["presented_time"] = presented
    return frames


def check_present_pair_integrity(frames: dict[int, dict[str, Any]], tol_ms: float = 0.01) -> dict[str, Any]:
    """Permanent torn-pair assertion on the published (frame, presentedTime) pair.

    metal_commit reports prev_present_frame P and prev_present_mono_ms T. If the
    pair is published atomically, T must be the present time OF FRAME P -- so
    T minus that frame's own presented_time is the fixed CACurrentMediaTime ->
    monotonic offset, identical for every record. A torn read pairs frame P's
    index with some other frame's time, which shows up as an outlier delta.

    That makes the offset itself unnecessary: the invariant is that all deltas
    agree. Any record off the median by more than float-rounding is a violation,
    and violations must be ZERO. `checked` is reported alongside, because zero
    violations out of zero records checked proves nothing.
    """
    deltas: list[tuple[int, float]] = []
    for f, v in frames.items():
        prev = v.get("prev_present_frame", -1.0)
        if prev is None or prev < 0:
            continue
        src = frames.get(int(prev))
        if not src or "presented_time" not in src:
            continue  # that frame's present record was not in this capture
        deltas.append((f, v["prev_present_mono_ms"] - src["presented_time"] * 1000.0))
    if not deltas:
        return {"checked": 0, "violations": 0, "note": "no commit record referenced a present in this capture"}
    median = sorted(d for _, d in deltas)[len(deltas) // 2]
    bad = [(f, d) for f, d in deltas if abs(d - median) > tol_ms]
    return {
        "checked": len(deltas),
        "violations": len(bad),
        "offset_median_ms": median,
        "worst_deviation_ms": max((abs(d - median) for _, d in deltas), default=0.0),
        "examples": [{"frame": f, "delta_ms": d} for f, d in bad[:5]],
    }


def gate_stamps_mach_ms(ktrace_text: str) -> tuple[list[float], str | None]:
    """ktrace gate stamps shifted onto the mach host timebase.

    Returns (sorted stamps in ms, error) -- the error is non-None when the
    epoch anchor is missing, in which case no shift is possible and the
    {gate->commit} term must be reported as unavailable rather than guessed.
    """
    epoch = _KTRACE_EPOCH_RE.search(ktrace_text)
    if not epoch:
        return [], "no ktrace_epoch line found; cannot shift gate_ms onto the mach timebase"
    shift = float(epoch.group("mach")) - float(epoch.group("mono"))
    gates = sorted(float(m.group("gate")) + shift for m in _KTRACE_GATE_RE.finditer(ktrace_text))
    if not gates:
        return [], "ktrace_epoch found but no ktrace: gate_ms lines"
    return gates, None


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("stats_file", type=Path, help="KITTY_METAL_STATS_FILE capture (or captured stderr)")
    ap.add_argument("--ktrace", type=Path, default=None,
                    help="log holding ktrace_epoch:/ktrace: lines; enables the {gate->commit} term")
    ap.add_argument("--json", type=Path, default=None, help="also write the full report as JSON")
    ap.add_argument("--paces", default=",".join(DEFAULT_PACES),
                    help=f"comma-separated pace= values to include (default {','.join(DEFAULT_PACES)}); "
                         "'all' keeps every pace including resize")
    ap.add_argument("--per-pace", action="store_true", help="also break every stage down by pace")
    args = ap.parse_args()

    if not args.stats_file.exists():
        print(f"ERROR: {args.stats_file} does not exist", file=sys.stderr)
        return 2
    stats_text = args.stats_file.read_text(errors="replace")
    frames = parse_frames(stats_text)
    # Integrity runs over EVERY frame, before any pace filter -- a torn pair is a
    # correctness violation regardless of which pace produced it.
    integrity = check_present_pair_integrity(frames)
    keep_paces = None if args.paces.strip() == "all" else {p.strip() for p in args.paces.split(",") if p.strip()}
    complete = {
        f: v for f, v in frames.items()
        if {"commit_time", "gpu_end", "presented_time"} <= v.keys()
        and (keep_paces is None or v.get("pace") in keep_paces)
    }
    dropped_pace = sum(
        1 for v in frames.values()
        if {"commit_time", "gpu_end", "presented_time"} <= v.keys()
        and keep_paces is not None and v.get("pace") not in keep_paces
    )
    if not complete:
        print("ERROR: no frame had all three of commit_time/gpu_end/presented_time.", file=sys.stderr)
        print("       Requires a build with the W28.0c records and KITTY_METAL_STATS=1.", file=sys.stderr)
        return 1

    commit_to_gpu = []
    gpu_to_present = []
    present_lag_frames = []
    for f in sorted(complete):
        v = complete[f]
        commit_to_gpu.append((v["gpu_end"] - v["commit_time"]) * 1000.0)
        gpu_to_present.append((v["presented_time"] - v["gpu_end"]) * 1000.0)
        prev = v.get("prev_present_frame", -1.0)
        # How many frames behind the committing frame the newest stamped present
        # was. The frame index is process-global across ALL windows, so with W
        # windows rendering the minimum achievable lag is W, not 1: each of the
        # other windows consumes an index between this window's consecutive
        # frames. A lag of 1 therefore means effectively one window was
        # rendering, which is what makes it a usable concurrency check.
        if prev >= 0:
            present_lag_frames.append(float(f) - prev)

    report: dict[str, Any] = {
        "stats_file": str(args.stats_file),
        "frames_seen": len(frames),
        "frames_complete": len(complete),
        "frames_dropped_pace_filtered": dropped_pace,
        "paces_included": sorted(keep_paces) if keep_paces else "all",
        "present_pair_integrity": integrity,
        "stages": [
            summarize("commit->gpu-done", commit_to_gpu),
            summarize("gpu-done->presented", gpu_to_present),
        ],
        "present_stamp_lag_frames": summarize("commit - prev_present_frame", present_lag_frames),
    }
    if args.per_pace:
        by_pace: dict[str, dict[str, Any]] = {}
        for f in sorted(complete):
            v = complete[f]
            p = str(v.get("pace", "?"))
            b = by_pace.setdefault(p, {"commit->gpu-done": [], "gpu-done->presented": []})
            b["commit->gpu-done"].append((v["gpu_end"] - v["commit_time"]) * 1000.0)
            b["gpu-done->presented"].append((v["presented_time"] - v["gpu_end"]) * 1000.0)
        report["per_pace"] = {
            p: [summarize(name, vals) for name, vals in stages.items()] for p, stages in by_pace.items()
        }

    gate_to_commit: list[float] = []
    if args.ktrace is not None:
        if not args.ktrace.exists():
            print(f"ERROR: {args.ktrace} does not exist", file=sys.stderr)
            return 2
        gates, err = gate_stamps_mach_ms(args.ktrace.read_text(errors="replace"))
        if err:
            report["gate_term_unavailable"] = err
        else:
            for f in sorted(complete):
                commit_ms = complete[f]["commit_time"] * 1000.0
                # The tick that produced this frame is the newest gate at or
                # before its commit. Same next-event pairing metal-latency.py
                # uses for presents, run backwards.
                i = bisect.bisect_right(gates, commit_ms)
                if i:
                    gate_to_commit.append(commit_ms - gates[i - 1])
            report["stages"].insert(0, summarize("gate->commit", gate_to_commit))

    # S5 as the partition reconstructs it, per frame, so the three terms can be
    # checked against the end-to-end span rather than assumed to tile it.
    if gate_to_commit and len(gate_to_commit) == len(commit_to_gpu):
        s5 = [a + b + c for a, b, c in zip(gate_to_commit, commit_to_gpu, gpu_to_present)]
        report["stages"].append(summarize("S5 gate->present (sum of terms)", s5))

    # A negative term means the stamps did not order as the model assumes
    # (e.g. presented_time before gpu_end). Reported, never silently absorbed
    # into a percentile.
    negatives = {
        "gate->commit": sum(1 for v in gate_to_commit if v < 0),
        "commit->gpu-done": sum(1 for v in commit_to_gpu if v < 0),
        "gpu-done->presented": sum(1 for v in gpu_to_present if v < 0),
    }
    report["negative_terms"] = negatives

    for stage in report["stages"]:
        p50, p90, p99 = stage["p50"], stage["p90"], stage["p99"]
        fmt = lambda v: "    n/a" if v is None else f"{v:7.3f}"  # noqa: E731
        print(f"{stage['stage']:<34} n={stage['n']:<5} p50={fmt(p50)} p90={fmt(p90)} p99={fmt(p99)}")
    if args.per_pace:
        for p, stages in sorted(report.get("per_pace", {}).items()):
            print(f"\n  pace={p}")
            for st in stages:
                print(f"    {st['stage']:<30} n={st['n']:<5} p50={st['p50']}")
    lag = report["present_stamp_lag_frames"]
    print(f"\npresent stamp visible at commit: {lag['n']} frames, "
          f"p50 {lag['p50']} frames behind, min {lag['min']}, max {lag['max']}")
    print(f"frames: {report['frames_complete']} complete, "
          f"{report['frames_dropped_pace_filtered']} pace-filtered out "
          f"(kept: {report['paces_included']})")
    print(f"negative terms: {negatives}")
    ig = report["present_pair_integrity"]
    verdict = "PASS" if ig["violations"] == 0 and ig["checked"] > 0 else (
        "NO DATA" if ig["checked"] == 0 else "FAIL")
    print(f"present-pair integrity: {verdict} -- {ig['violations']} torn of {ig['checked']} checked"
          + (f", worst deviation {ig['worst_deviation_ms']:.6f} ms" if ig["checked"] else ""))
    for ex in ig.get("examples", []):
        print(f"   TORN frame={ex['frame']} delta_ms={ex['delta_ms']}")
    if "gate_term_unavailable" in report:
        print(f"gate->commit unavailable: {report['gate_term_unavailable']}", file=sys.stderr)

    if args.json:
        args.json.write_text(json.dumps(report, indent=2) + "\n")
        print(f"wrote {args.json}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
