#!/usr/bin/env python3.14
"""R4 ftrace analyzer (plan-2026-07-25-main-thread-visibility-qos-r4.md v4.5.1).

Two explicit input modes, each gate bound to one (tool, input) pair:

  mode (i)  — ftrace log:      --ftrace LOG [--cell NAME] [--epsilon MS]
              reproduces the I3 closure arithmetic, the I5 nested-subset
              identity, the offline regime derivation (gap_ms − prev_tick_ms
              < ε), the per-line emit correction (outside_cpu − emit_cpu,
              sentinel-aware), per-cell tables (segments, maint per-site
              occurrences, link/oos counter diffs, corrected out-of-tick
              rate over the adjudicated lines with the same-lines Σgap
              denominator, emit share vs the dominance threshold) and an
              optional gnuplot PNG (--png OUT).
  mode (ii) — latency JSONL:   --latency PRE.json POST.json
              Δp50 + CI95 half-widths via the M0a-pinned bootstrap
              (median, 4000 resamples, seed 4) — metal-latency.py itself
              has no CI code (plan Provenance #12).

  --selfcheck runs the synthetic hand-built-log verification (sentinel
  lines, negative gap, ft_nested>0, nonzero EMIT-window counters, a
  dominance-exceeding cell) twice and exits nonzero on any mismatch.

Constants (M0a/M0b): thr_tick and the dominance threshold are passed in
(--thr-tick, --dominance) so the frozen values live in M0-FREEZE.md, not
here. Sentinel lines (outside_cpu_ms/emit_cpu_ms == -1) are excluded from
every numerator and denominator (M0a(i)).
"""
from __future__ import annotations

import argparse
import json
import math
import random
import re
import statistics
import subprocess
import sys
import tempfile
from pathlib import Path

FTRACE_RE = re.compile(r"ftrace: (.*)")
EXCLUSIVE = ("resize_ms", "parse_ms", "render_ms", "cocoa_ms", "close_ms", "other_ms")
NESTED = ("peer_ms", "death_ms", "maint_ms")
CUMULATIVE = (
    "maint_tc", "maint_hl", "maint_img", "maint_cfg", "maint_outside_parse",
    "ft_nested", "timer_ms", "timer_calls", "link_ms", "link_frames",
    "link_norender", "lit_resize_ms", "lit_parse_ms", "lit_render_ms",
    "lit_cocoa_ms", "lit_close_ms", "lit_other_ms", "link_it_frames",
    "link_emit_ms", "oos_ms", "oos_frames", "oos_it_ms", "oos_emit_ms",
)


def parse_ftrace(lines):
    rows = []
    for line in lines:
        m = FTRACE_RE.search(line)
        if not m:
            continue
        row = {}
        for kv in m.group(1).split():
            if "=" not in kv:
                continue
            k, v = kv.split("=", 1)
            try:
                row[k] = float(v) if ("." in v or v == "-1.000") else int(v)
            except ValueError:
                row[k] = v
        rows.append(row)
    return rows


def closure_check(rows, tol=0.05, tol_max=0.20):
    """I3: |tick − Σ(exclusive)| per row; returns (ok, max_err, violations).

    Sentinel lines are still closure-checked (the identity is wall-clock
    only); the quit tick is excluded upstream by the caller when known.
    """
    max_err = 0.0
    viol = []
    for i, r in enumerate(rows):
        s = sum(r[k] for k in EXCLUSIVE)
        err = abs(r["tick_ms"] - s)
        max_err = max(max_err, err)
        if err > tol:
            viol.append((i, err))
    hard = [v for v in viol if v[1] > tol_max]
    return (not hard, max_err, viol)


def nested_check(rows):
    """I5: peer+death+maint ≤ parse on every row (small float slack) and the
    maint_outside_parse counter must not advance."""
    bad = [i for i, r in enumerate(rows)
           if sum(r[k] for k in NESTED) > r["parse_ms"] + 0.001]
    moved = rows[-1].get("maint_outside_parse", 0) - rows[0].get("maint_outside_parse", 0) if rows else 0
    return (not bad and moved == 0, bad, moved)


def invariant_check(rows, tol_cpu=0.05):
    """M1b reported invariant (not a gate): tick_cpu ≤ tick + tol_cpu."""
    return [i for i, r in enumerate(rows) if r["tick_cpu_ms"] > r["tick_ms"] + tol_cpu]


def derive_regime(rows, epsilon_ms):
    """Offline wait0/slept split: gap_ms(N) − tick_ms(N−1) < ε ⇒ wait0.

    The first row (no N−1) is 'unknown' and excluded from adjudication.
    """
    out = []
    for i, r in enumerate(rows):
        if i == 0 or epsilon_ms is None:
            out.append("unknown" if epsilon_ms is not None else "unfiltered")
            continue
        out.append("wait0" if (r["gap_ms"] - rows[i - 1]["tick_ms"]) < epsilon_ms else "slept")
    return out


def corrected_rows(rows):
    """Per-line emit correction; sentinel lines dropped (M0a(i))."""
    out = []
    for i, r in enumerate(rows):
        oc, ec = r["outside_cpu_ms"], r["emit_cpu_ms"]
        if oc < 0 or ec < 0:
            continue
        out.append((i, oc - ec, ec, r["gap_ms"]))
    return out


def cell_report(rows, cell, epsilon_ms, thr_tick, dominance, adjudicate_regime="slept"):
    regime = derive_regime(rows, epsilon_ms)
    ok3, max_err, viol = closure_check(rows)
    ok5, bad5, moved5 = nested_check(rows)
    inv = invariant_check(rows)
    corr = corrected_rows(rows)
    if epsilon_ms is None:
        adj = [c for c in corr]
    else:
        adj = [c for c in corr if regime[c[0]] == adjudicate_regime]
    sum_gap = sum(c[3] for c in adj)
    sum_out = sum(c[1] for c in adj)
    sum_emit = sum(c[2] for c in adj)
    rate = (sum_out / sum_gap) if sum_gap > 0 else float("nan")
    emit_share = (sum_emit / sum_gap) if sum_gap > 0 else float("nan")
    dominated = (not math.isnan(emit_share)) and emit_share > dominance
    # counter diffs (cumulative fields)
    diffs = {}
    if rows:
        for k in CUMULATIVE:
            diffs[k] = rows[-1].get(k, 0) - rows[0].get(k, 0)
    maint_pos = [r["maint_ms"] for r in rows if r["maint_ms"] > 0]
    seg_stats = {}
    for k in EXCLUSIVE + ("tick_ms", "tick_cpu_ms"):
        vals = sorted(r[k] for r in rows)
        if vals:
            seg_stats[k] = {
                "p50": statistics.median(vals),
                "p99": vals[min(len(vals) - 1, int(len(vals) * 0.99))],
                "max": vals[-1], "sum": sum(vals),
            }
    emit_window_ns = diffs.get("link_emit_ms", 0) + diffs.get("oos_emit_ms", 0)
    out_of_tick_render = (diffs.get("link_ms", 0) - sum(diffs.get(k, 0) for k in (
        "lit_resize_ms", "lit_parse_ms", "lit_render_ms", "lit_cocoa_ms",
        "lit_close_ms", "lit_other_ms"))) + (diffs.get("oos_ms", 0) - diffs.get("oos_it_ms", 0))
    return {
        "cell": cell, "n_rows": len(rows),
        "I3": {"pass": ok3, "max_err_ms": round(max_err, 4), "n_over_tol": len(viol)},
        "I5": {"pass": ok5, "bad_rows": bad5[:5], "maint_outside_parse_moved": moved5},
        "cpu_le_wall_invariant_violations": len(inv),
        "regime_counts": {k: regime.count(k) for k in set(regime)},
        "adjudicated_lines": len(adj), "sentinel_lines": len(rows) - len(corr),
        "corrected_outside_rate": None if math.isnan(rate) else round(rate, 6),
        "emit_share": None if math.isnan(emit_share) else round(emit_share, 6),
        "dominance_threshold": dominance,
        "rate_status": ("UNADJUDICATED(dominated)" if dominated else
                        ("UNADJUDICATED(no-lines)" if not adj else "adjudicated")),
        "emit_window_ms_total": round(emit_window_ns, 6),
        "emit_window_zero": emit_window_ns == 0,
        "out_of_tick_render_ms": round(out_of_tick_render, 3),
        "tick_render_ms_sum": round(seg_stats.get("render_ms", {}).get("sum", 0.0), 3),
        "maint": {"occ_tc": diffs.get("maint_tc", 0), "occ_hl": diffs.get("maint_hl", 0),
                  "occ_img": diffs.get("maint_img", 0), "occ_cfg": diffs.get("maint_cfg", 0),
                  "n_nonzero_ticks": len(maint_pos),
                  "max_ms": max(maint_pos) if maint_pos else 0.0,
                  "conditional_p50": statistics.median(maint_pos) if maint_pos else None,
                  "g_leg": ("UNADJUDICATED(zero-occurrences)"
                            if not maint_pos else
                            ("pass" if max(maint_pos) < thr_tick else "fail"))},
        "segments": {k: {kk: round(vv, 4) for kk, vv in v.items()} for k, v in seg_stats.items()},
        "counter_diffs": {k: round(v, 3) if isinstance(v, float) else v for k, v in diffs.items()},
    }


def bootstrap_ci_median(vals, reps=4000, seed=4):
    vals = sorted(vals)
    random.seed(seed)
    boots = sorted(statistics.median(random.choices(vals, k=len(vals))) for _ in range(reps))
    lo, hi = boots[int(0.025 * reps)], boots[int(0.975 * reps)]
    return statistics.median(vals), lo, hi, (hi - lo) / 2


def latency_mode(pre_path, post_path):
    def load(p):
        d = json.load(open(p))
        return [s["latency_ms"] for s in d["pairs"] if s.get("latency_ms") is not None]
    pre, post = load(pre_path), load(post_path)
    p50_pre, lo1, hi1, hw1 = bootstrap_ci_median(pre)
    p50_post, lo2, hi2, hw2 = bootstrap_ci_median(post)
    return {
        "n_pre": len(pre), "n_post": len(post),
        "p50_pre": round(p50_pre, 3), "p50_post": round(p50_post, 3),
        "delta_p50": round(p50_post - p50_pre, 4),
        "ci95_pre": [round(lo1, 3), round(hi1, 3)], "half_width_pre": round(hw1, 4),
        "ci95_post": [round(lo2, 3), round(hi2, 3)], "half_width_post": round(hw2, 4),
        "ci_overlap": not (lo2 > hi1 or lo1 > hi2),
    }


def emit_png(rows, cell, out_png):
    """One gnuplot (pngcairo) PNG per vtebench-class cell: per-tick stacked
    view of the exclusive segments plus tick_cpu."""
    with tempfile.NamedTemporaryFile("w", suffix=".dat", delete=False) as df:
        for i, r in enumerate(rows):
            df.write(f"{i} " + " ".join(str(r[k]) for k in EXCLUSIVE) +
                     f" {r['tick_ms']} {r['tick_cpu_ms']}\n")
        dat = df.name
    gp = f"""
set terminal pngcairo size 1400,700 enhanced
set output '{out_png}'
set title 'R4 tick partition — {cell}'
set xlabel 'tick #'
set ylabel 'ms'
set key outside
set style data histograms
set style histogram rowstacked
set style fill solid 0.85 border -1
plot '{dat}' using 2 title 'resize', '' using 3 title 'parse', \\
     '' using 4 title 'render', '' using 5 title 'cocoa', \\
     '' using 6 title 'close', '' using 7 title 'other', \\
     '' using 0:9 with lines lw 2 title 'tick_cpu' axes x1y1
"""
    subprocess.run(["gnuplot"], input=gp, text=True, check=True)


def synthetic_log():
    """Hand-built log covering every special line shape the plan invents
    (§5): first-line sentinels, negative gap, ft_nested>0, a nonzero
    EMIT-window counter, and (as a second cell) dominance excess."""
    base = ("bytes=0 parse_ms={parse} render_ms={render} input_read=0 gate=none present=0 "
            "resize_ms={resize} cocoa_ms={cocoa} close_ms={close} other_ms={other} "
            "peer_ms={peer} death_ms={death} maint_ms={maint} tick_ms={tick} "
            "tick_cpu_ms={cpu} outside_cpu_ms={oc} emit_cpu_ms={ec} "
            "maint_tc={tc} maint_hl=0 maint_img=0 maint_cfg=0 maint_outside_parse=0 "
            "ft_nested={nested} timer_ms=0.000 timer_calls=0 link_ms={link} link_frames=1 "
            "link_norender=0 lit_resize_ms=0 lit_parse_ms=0 lit_render_ms=0 lit_cocoa_ms=0 "
            "lit_close_ms=0 lit_other_ms=0 link_it_frames=0 link_emit_ms={lemit} "
            "oos_ms=0 oos_frames=0 oos_it_ms=0 oos_emit_ms=0")

    def line(seq, ts, gap, **kw):
        d = dict(parse="1.000", render="0.500", resize="0.100", cocoa="0.050",
                 close="0.050", other="0.300", peer="0.200", death="0.100",
                 maint="0.400", tick="2.000", cpu="1.900", oc="0.500", ec="0.050",
                 tc=0, nested=0, link="0.000", lemit="0.000")
        d.update(kw)
        return f"[0.0] ftrace: seq={seq} ts_ms={ts} gap_ms={gap} " + base.format(**d)

    healthy = [
        line(1, 100.0, 0.0, oc="-1.000", ec="-1.000"),          # first-line sentinels
        line(2, 120.0, "20.000"),
        line(3, 118.0, "-2.000"),                                  # negative gap (clock anomaly shape)
        line(4, 140.0, "22.000", nested=1),                        # ft_nested moved
        line(5, 160.0, "20.000", lemit="0.030", tc=1, nested=1, maint="0.400"),  # EMIT-window nonzero + maint occ (cumulative fields stay monotone)
    ]
    dominated = [
        line(1, 100.0, 0.0, oc="-1.000", ec="-1.000"),
        line(2, 101.0, "1.000", oc="0.400", ec="0.350"),           # emit share 0.35 > 0.25
        line(3, 102.0, "1.000", oc="0.400", ec="0.350"),
    ]
    return healthy, dominated


def selfcheck():
    healthy, dominated = synthetic_log()
    ok = True

    def expect(cond, msg):
        nonlocal ok
        print(("PASS " if cond else "FAIL ") + msg)
        ok = ok and cond

    r1 = cell_report(parse_ftrace(healthy), "synthetic-healthy", epsilon_ms=None,
                     thr_tick=0.20, dominance=0.25)
    expect(r1["I3"]["pass"], "I3 closure on synthetic-healthy")
    expect(r1["I5"]["pass"], "I5 nested subset on synthetic-healthy")
    expect(r1["sentinel_lines"] == 1, "first-line sentinel excluded")
    expect(r1["counter_diffs"]["ft_nested"] == 1, "ft_nested diff visible")
    expect(not r1["emit_window_zero"], "nonzero EMIT-window counter detected")
    expect(r1["maint"]["occ_tc"] == 1 and r1["maint"]["n_nonzero_ticks"] == 5,
           "maint occurrence + conditional distribution")
    expect(r1["maint"]["g_leg"] == "fail", "G leg conditional max 0.400 >= thr_tick 0.20 flagged")
    r2 = cell_report(parse_ftrace(dominated), "synthetic-dominated", epsilon_ms=None,
                     thr_tick=0.20, dominance=0.25)
    expect(r2["rate_status"] == "UNADJUDICATED(dominated)",
           "dominance-exceeding cell marked UNADJUDICATED")
    # regime derivation: gap−prev_tick 20−2=18 >= eps 5 ⇒ slept; 1−2=−1 < 5 ⇒ wait0
    reg = derive_regime(parse_ftrace(healthy), 5.0)
    expect(reg[1] == "slept" and reg[0] == "unknown", "regime derivation slept/unknown")
    reg2 = derive_regime(parse_ftrace(dominated), 5.0)
    expect(reg2[1] == "wait0", "regime derivation wait0")
    return ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ftrace", type=Path)
    ap.add_argument("--cell", default="cell")
    ap.add_argument("--epsilon", type=float, default=None, help="ε_regime ms (M0b-1); omit = unfiltered")
    ap.add_argument("--thr-tick", type=float, default=0.20)
    ap.add_argument("--dominance", type=float, default=0.25)
    ap.add_argument("--drop-last", action="store_true", help="exclude the quit tick (M0a(c))")
    ap.add_argument("--png", type=Path)
    ap.add_argument("--latency", nargs=2, type=Path, metavar=("PRE", "POST"))
    ap.add_argument("--selfcheck", action="store_true")
    args = ap.parse_args()
    if args.selfcheck:
        ok1 = selfcheck()
        print("--- second run (must be deterministic) ---")
        ok2 = selfcheck()
        sys.exit(0 if (ok1 and ok2) else 1)
    if args.latency:
        print(json.dumps(latency_mode(*args.latency), indent=1))
        return
    if args.ftrace:
        rows = parse_ftrace(open(args.ftrace, errors="replace"))
        if args.drop_last and rows:
            rows = rows[:-1]
        rep = cell_report(rows, args.cell, args.epsilon, args.thr_tick, args.dominance)
        print(json.dumps(rep, indent=1))
        if args.png and rows:
            emit_png(rows, args.cell, args.png)
        return
    ap.print_help()


if __name__ == "__main__":
    main()
