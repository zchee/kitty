#!/usr/bin/env python3.14
"""R5 Q-echo probe: idle DSR RTT, KITTY_THREAD_QOS armed vs unset.

The value hypothesis under test is ADR-0012 finding 2: a lone DSR on a
quiet pty pays the idle-wake chain (+0.45 ms p50 at gentle rates). R5
promotes the io/oob/reader thread heads to QOS_CLASS_USER_INITIATED
behind the opt-in KITTY_THREAD_QOS; this probe measures whether that
moves the idle echo path.

Two modes:
  --pilot        unset arm only, 3 fresh-spawn reps. Binds hw_echo =
                 median of the per-rep bootstrap CI95 half-widths
                 (spread recorded). Runs BEFORE the M0a freeze on the
                 unassigned binary (plan v2 D1: single freeze).
  --ab           alternating unset/armed rep pairs (default 3 pairs).
                 With --hw-echo (the frozen pilot constant) the probe
                 classifies WIN / NEUTRAL / HARM from the frozen
                 formulas; without it, numbers only.

Per rep: one fresh spawn_kitty() window whose child is
oob_flood_client.py --arm pty --ping --idle --duration-s N (DSR every
20 ms on the tty, no flood). Warmup 20 RTTs dropped; a rep with fewer
than 500 post-warmup RTTs is INVALID and retried once (never relax n —
twice invalid is reported for UNADJUDICATED handling, plan section 3).

A1 (Architect fix, frozen): the probe itself emits, per arm, p50 +
bootstrap CI95 (4000 resamples with replacement, random.seed(4), CI95 =
[2.5th, 97.5th] percentiles of bootstrap medians, half-width =
(hi-lo)/2 — verbatim the R4 M0-FREEZE method) into its result JSON, so
Q-echo is re-derivable from one named (tool, input) pair.

Instrument-env parity (plan section 2): KITTY_QOS_DEBUG=1 rides in BOTH
arms; the armed arm differs only by KITTY_THREAD_QOS=1.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import random
import statistics
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _kitty_harness_common as h

VERIFY_DIR = h.REPO_ROOT / ".omc" / "verify" / "r5" / "results"
CLIENT = str(h.REPO_ROOT / "scripts" / "oob_flood_client.py")
WARMUP_DROP = 20
N_FLOOR = 500
BOOT_RESAMPLES = 4000
BOOT_SEED = 4


def sha256_file(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()[:16]


def binary_shas() -> dict[str, str]:
    so = h.REPO_ROOT / "kitty" / "fast_data_types.so"
    return {
        "launcher_sha": sha256_file(h.KITTY_BINARY),
        "so_sha": sha256_file(so) if so.exists() else "missing",
    }


def _pct_idx(n: int, frac: float) -> int:
    return max(0, min(n - 1, round(frac * (n - 1))))


def bootstrap_ci95(vals_ms: list[float]) -> dict[str, float]:
    rnd = random.Random(BOOT_SEED)
    n = len(vals_ms)
    meds = sorted(statistics.median(rnd.choices(vals_ms, k=n))
                  for _ in range(BOOT_RESAMPLES))
    lo = meds[_pct_idx(len(meds), 0.025)]
    hi = meds[_pct_idx(len(meds), 0.975)]
    return {"ci95_lo_ms": lo, "ci95_hi_ms": hi, "half_width_ms": (hi - lo) / 2.0}


def run_rep(arm: str, rep_no: int, duration_s: float, tag: str) -> dict:
    h.wait_for_build_lock_clear()
    VERIFY_DIR.mkdir(parents=True, exist_ok=True)
    result_file = VERIFY_DIR / f"echo-{tag}-{arm}-r{rep_no}.client.json"
    stderr_file = VERIFY_DIR / f"echo-{tag}-{arm}-r{rep_no}.stderr.log"
    result_file.unlink(missing_ok=True)
    env = {"KITTY_OOB_RESULT_FILE": str(result_file), "KITTY_QOS_DEBUG": "1"}
    if arm == "armed":
        env["KITTY_THREAD_QOS"] = "1"
    argv = ["python3.14", CLIENT, "--arm", "pty", "--ping", "--idle",
            "--duration-s", str(duration_s)]
    row: dict = {"arm": arm, "rep": rep_no, "load_before": os.getloadavg()[0],
                 "wave26_default_inherited": True, **binary_shas()}
    with open(stderr_file, "wb") as ef:
        proc = h.spawn_kitty(argv, extra_env=env, stderr=ef)
        try:
            proc.wait(timeout=duration_s + 60)
        except subprocess.TimeoutExpired:
            h.terminate_kitty(proc)
            row["error"] = "timeout"
            return row
    if not result_file.exists():
        row["error"] = "no client result"
        return row
    res = json.loads(result_file.read_text())
    if res.get("error"):
        row["error"] = res["error"]
        return row
    if res.get("ping_timeouts", 1) != 0:
        row["error"] = f"{res.get('ping_timeouts')} ping timeouts"
        return row
    rtts_ms = [x / 1e6 for x in res.get("rtt_ns", [])[WARMUP_DROP:]]
    row["n_post_warmup"] = len(rtts_ms)
    if len(rtts_ms) < N_FLOOR:
        row["error"] = f"n={len(rtts_ms)} < {N_FLOOR}"
        return row
    row["p50_ms"] = h.percentile(rtts_ms, 50)
    row["p90_ms"] = h.percentile(rtts_ms, 90)
    row["p99_ms"] = h.percentile(rtts_ms, 99)
    row["mean_ms"] = statistics.fmean(rtts_ms)
    row.update(bootstrap_ci95(rtts_ms))
    row["rtts_ms"] = rtts_ms
    return row


def run_valid_rep(arm: str, rep_no: int, duration_s: float, tag: str) -> dict:
    """One retry on an invalid rep; a second failure is surfaced as-is
    (UNADJUDICATED handling is the adjudicator's job, never silent)."""
    row = run_rep(arm, rep_no, duration_s, tag)
    if row.get("error"):
        print(f"  rep invalid ({row['error']}), retrying once", file=sys.stderr)
        retry = run_rep(arm, rep_no, duration_s, tag)
        retry["retried"] = True
        if retry.get("error"):
            retry["invalid_twice"] = True
        return retry
    return row


def arm_pooled(reps: list[dict]) -> dict:
    pooled = [x for r in reps if not r.get("error") for x in r["rtts_ms"]]
    if not pooled:
        return {"n": 0}
    out = {"n": len(pooled), "p50_ms": h.percentile(pooled, 50),
           "p90_ms": h.percentile(pooled, 90), "p99_ms": h.percentile(pooled, 99),
           "mean_ms": statistics.fmean(pooled)}
    out.update(bootstrap_ci95(pooled))
    return out


def classify(unset: dict, armed: dict, hw_echo: float) -> dict:
    delta_p50 = armed["p50_ms"] - unset["p50_ms"]
    no_harm_band = max(0.10, hw_echo)
    no_harm = delta_p50 <= no_harm_band
    ci_disjoint = (armed["ci95_hi_ms"] < unset["ci95_lo_ms"]
                   or unset["ci95_hi_ms"] < armed["ci95_lo_ms"])
    win = (-delta_p50 >= hw_echo) and ci_disjoint
    label = "WIN" if win else ("NEUTRAL" if no_harm else "HARM")
    return {"delta_p50_ms": delta_p50, "no_harm_band_ms": no_harm_band,
            "hw_echo_ms": hw_echo, "ci_disjoint": ci_disjoint,
            "classification": label}


def main() -> int:
    ap = argparse.ArgumentParser()
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--pilot", action="store_true")
    mode.add_argument("--ab", action="store_true")
    ap.add_argument("--reps", type=int, default=3,
                    help="pilot: reps of unset; ab: rep PAIRS per arm")
    ap.add_argument("--duration-s", type=float, default=15.0)
    ap.add_argument("--hw-echo", type=float, default=None,
                    help="frozen pilot constant (ms); enables classification")
    ap.add_argument("--tag", default="run")
    args = ap.parse_args()

    out: dict = {"mode": "pilot" if args.pilot else "ab",
                 "duration_s": args.duration_s, "warmup_drop": WARMUP_DROP,
                 "n_floor": N_FLOOR, "bootstrap": {"resamples": BOOT_RESAMPLES,
                 "seed": BOOT_SEED, "ci": [2.5, 97.5]}, "reps": []}

    if args.pilot:
        for i in range(args.reps):
            print(f"pilot rep {i + 1}/{args.reps} (unset)", file=sys.stderr)
            out["reps"].append(run_valid_rep("unset", i + 1, args.duration_s,
                                             args.tag))
        hws = [r["half_width_ms"] for r in out["reps"] if not r.get("error")]
        if len(hws) == args.reps:
            out["hw_echo_ms"] = statistics.median(hws)
            out["hw_spread_ms"] = max(hws) - min(hws)
            out["hw_per_rep_ms"] = hws
        else:
            out["error"] = "pilot has invalid reps; hw_echo not bindable"
    else:
        for i in range(args.reps):
            for arm in ("unset", "armed"):  # alternate inside each pair
                print(f"ab pair {i + 1}/{args.reps} arm={arm}", file=sys.stderr)
                out["reps"].append(run_valid_rep(arm, i + 1, args.duration_s,
                                                 args.tag))
        out["arms"] = {a: arm_pooled([r for r in out["reps"] if r["arm"] == a])
                       for a in ("unset", "armed")}
        invalid = [r for r in out["reps"] if r.get("error")]
        if invalid:
            out["error"] = f"{len(invalid)} invalid reps"
        elif args.hw_echo is not None:
            out["verdict"] = classify(out["arms"]["unset"], out["arms"]["armed"],
                                      args.hw_echo)

    slim = json.loads(json.dumps(out))  # deep copy
    for r in slim["reps"]:
        r.pop("rtts_ms", None)
    dest = VERIFY_DIR / f"echo-{args.tag}-summary.json"
    dest.write_text(json.dumps(slim, indent=1))
    raw_dest = VERIFY_DIR / f"echo-{args.tag}-raw.json"
    raw_dest.write_text(json.dumps(out))
    print(json.dumps(slim, indent=1))
    print(f"wrote {dest}", file=sys.stderr)
    return 1 if out.get("error") else 0


if __name__ == "__main__":
    raise SystemExit(main())
