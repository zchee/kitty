#!/usr/bin/env python3.14
"""Wave-25 M2/M4 OFF-cost annotation (Lane H; zero product code).

Adapted from .omc/verify/wave24/r24_offcost_battery.py for the W25 arm pair:

  M0      -> .omc/verify/wave25/m0-reference-fast_data_types.so (pre-
             implementation binary, sha256[:16]=6079ef6e5be0d9a6)
  current -> .omc/verify/wave25/current-repo-fast_data_types.so, a fresh
             snapshot of whatever is presently built at
             kitty/fast_data_types.so, taken at driver start. At M3 this
             will be the Lane S implementation binary; today (pre-Lane-S)
             it is byte-identical to M0 -- fine for harness validation
             (team-lead brief), and the live-sha check below proves it
             rather than assuming it.

Interleaved two-bench block, BOTH arms with KITTY_PAUSE_SNAPSHOT_COW and
KITTY_PAUSE_SNAPSHOT_SHARE UNSET (arm-state matrix "OFF-cost" row) and
KITTY_FRAME_TRACE=1 on BOTH arms (ARCH R2-MINOR-1: the emitter is
measurement-affecting, so its state must be pinned and symmetric).

Benches: dense_cells (campaign precedent) AND sync_medium_cells. Per the W24
recorded-condition-2 precedent (r24_offcost_battery.py's own docstring),
sync_medium_cells's 50 DECSTBM+IL/DL region-rotate pairs + 415 LF scrolls
already exercise every region-rotate/normalize path the retire map touches
-- this bench pair IS the DECSTBM region-rotate coverage obligation; W25
does not need (and r24 never had) a third synthetic bench.

Pinned statistic: parse_ms_per_MiB medians (sum of per-tick parse_ms over
total MiB), PASS iff median(current)/median(M0) <= 1.02. Live per-row
sha256 of the loaded .so; the unset-arm cow_copied movement is asserted
zero (same identity check r24 used to catch the W23 reversion).

Usage: w25_offcost.py [--rounds N] [--secs S]   (defaults: 3 rounds, 5s)
"""
from __future__ import annotations

import json
import subprocess
import sys
import time
from pathlib import Path

REPO = Path('/Users/zchee/src/github.com/kovidgoyal/kitty-worktrees/metal-fable-5')
sys.path.insert(0, str(REPO / '.omc/verify/wave25'))
import _w25_common as W  # noqa: E402
import _w25_plot as P  # noqa: E402

BENCHES = ('dense_cells', 'sync_medium_cells')
THRESHOLD = 1.02


def run_row(arm: str, arm_so, expect_sha: str, bench: str, rnd: int, secs: int, jsonl: Path) -> dict:
    live_sha = W.install_arm(arm_so, expect_sha)
    la0 = W.wait_for_quiet()
    stderr_path = W.LOGS / f'offcost-{bench}-{arm}-r{rnd}.stderr.log'
    clean, text, samples = W.run_vtebench_row(
        bench=bench, max_secs=secs, warmup=1,
        extra_env={'KITTY_FRAME_TRACE': '1'}, stderr_path=stderr_path)
    la1 = W.C.loadavg1()
    ticks = W.parse_ftrace(text)
    counters = W.sum_ftrace_counters(text)
    n = len(samples)
    smed = W.C.median(samples)
    total_mib = sum(t['bytes'] for t in ticks) / W.MIB
    mib_per_sample = round(total_mib / n, 5) if (n and total_mib) else None
    mbps = round(mib_per_sample / (smed / 1000.0), 2) if (smed and mib_per_sample) else None
    row = {
        'kind': 'offcost', 'bench': bench, 'arm': arm, 'round': rnd,
        'live_so_sha256': live_sha, 'clean_exit': clean,
        'arm_state': W.arm_state(cow=0, share=0, frame_trace=1),
        'cow_copied_total': counters['cow_copied'],
        'loadavg_before': la0, 'loadavg_after': la1,
        'n_samples': n, 'sample_ms_median': smed, 'mb_per_s': mbps,
        'ftrace': {'n_ticks': len(ticks), 'total_MiB': round(total_mib, 3),
                   'parse_ms_per_MiB': W.parse_ms_per_mib(ticks)},
    }
    if counters['cow_copied'] != 0:
        raise RuntimeError(f'unset arm shows cow movement: {arm} {bench} r{rnd} '
                            f"cow_copied={counters['cow_copied']}")
    W.append_jsonl(jsonl, row)
    return row


def main() -> int:
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument('--rounds', type=int, default=3)
    ap.add_argument('--secs', type=int, default=5)
    args = ap.parse_args()

    current_sha = W.snapshot_current_so()
    arm_so = {'M0': (W.M0_SO, W.M0_EXPECT_SHA), 'current': (W.CURRENT_SO, current_sha)}
    if not W.M0_SO.exists():
        print(f'ERROR: {W.M0_SO} missing', file=sys.stderr)
        return 2
    m0_sha = W.sha256_16(W.M0_SO)
    if m0_sha != W.M0_EXPECT_SHA:
        print(f'ERROR: M0 reference .so sha mismatch: {m0_sha} != {W.M0_EXPECT_SHA}', file=sys.stderr)
        return 2

    ts = time.strftime('%H%M%S')
    out = W.RESULTS / f'w25-offcost-{ts}.jsonl'
    rows: list[dict] = []
    try:
        W.append_jsonl(out, {
            'kind': 'header', 'block': 'offcost',
            'note': ('unset arm (both KITTY_PAUSE_SNAPSHOT_COW and _SHARE unset), '
                     'KITTY_FRAME_TRACE=1 on both arms; gate <= 1.02x interleaved '
                     'parse_ms_per_MiB on dense_cells AND sync_medium_cells; the '
                     "sync_medium_cells bench IS the DECSTBM region-rotate coverage "
                     '(W24 recorded-condition-2 precedent)'),
            'm0_so_sha256_16': m0_sha, 'current_so_sha256_16': current_sha,
            'threshold': THRESHOLD, 'rounds': args.rounds, 'secs_per_row': args.secs,
        })
        for rnd in range(1, args.rounds + 1):
            for bench in BENCHES:
                order = ('M0', 'current') if rnd % 2 else ('current', 'M0')
                for arm in order:
                    so_path, expect_sha = arm_so[arm]
                    rows.append(run_row(arm, so_path, expect_sha, bench, rnd, args.secs, out))
        summary = {'kind': 'summary', 'rounds': args.rounds, 'benches': {}, 'threshold': THRESHOLD}
        allpass = True
        for bench in BENCHES:
            med = {a: W.median_precise([r['ftrace']['parse_ms_per_MiB'] for r in rows
                                        if r['arm'] == a and r['bench'] == bench
                                        and r['ftrace']['parse_ms_per_MiB'] is not None])
                   for a in arm_so}
            mbps = {a: W.median_precise([r['mb_per_s'] for r in rows
                                         if r['arm'] == a and r['bench'] == bench and r['mb_per_s']], 2)
                    for a in arm_so}
            ratio = round(med['current'] / med['M0'], 4) if all(med.values()) else None
            ok = ratio is not None and ratio <= THRESHOLD
            allpass = allpass and ok
            summary['benches'][bench] = {'parse_ms_per_MiB_median': med,
                                         'mb_per_s_median_corroboration': mbps,
                                         'ratio_current_over_M0': ratio, 'pass': ok}
        summary['pass'] = allpass
        W.append_jsonl(out, summary)
    finally:
        W.install_arm(W.CURRENT_SO, current_sha)  # always restore the repo's own binary

    try:
        plotted = P.load_rows(out)
        script = P.plot_offcost(out, plotted, summary)
        subprocess.run([P.GNUPLOT], input=script, text=True, check=True)
        png = out.with_suffix('.png')
        assert png.exists() and png.stat().st_size > 0, f'gnuplot produced no output for {out}'
        print(f'wrote {png}')
    except Exception as exc:
        print(f'WARNING: PNG render failed: {exc}', file=sys.stderr)

    print(json.dumps(summary))
    print(str(out))
    return 0 if summary['pass'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
