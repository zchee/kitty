#!/usr/bin/env python3.14
"""Wave-25 M4 gate-block driver (Lane H; zero product code). Re-implements
the W21 L4.2 / W24 D1 l42_cheapkill methodology since no driver survives it
at HEAD (plan M4, referents ralplan-wave24-slotcow-cheapkill-design.md
Lane D1 "Method" l.81 + .omc/verify/wave21/L4-COW.md Method l.68-73).

Three subcommands:

  rhat            same-block R-hat FIRST (M4(i)): arm COW=1 SHARE=0
                  FRAME_TRACE=1, sync_medium_cells, >=3 rounds x 5s
                  (defaults; --rounds/--secs override for smoke). Binding
                  figure = Sigma cow_skip_eligible / Sigma cow_copied ACROSS
                  rounds; per-round 4-digit stability reported (never
                  gates); sanity floor R^ < 0.14 and STOP-and-investigate
                  R^ < 0.53 flagged record-only (never re-derive bands after
                  measurement). Discrimination floor = 0.8 x Sigma-R^ is
                  computed and recorded for M4 to consume, per-registered
                  from THIS wave's own block, never the W24 0.6781 ceiling.

  ratio           interleaved medium_cells (no-pause) vs sync_medium_cells
                  (pause) arms, BOTH arms SHARE=1 COW unset FRAME_TRACE=1,
                  >=3 rounds/arm; true_ms_per_MiB medians + ratio vs the
                  1.25x primary gate; realized R parsed defensively from
                  share_rows_total/share_rows_ref/share_cow_retires (absent
                  at this pre-M3 HEAD -> recorded 0 with a loud note, never
                  silently reported as a real zero reading); baseline-must-
                  hold sub-row times the no-pause arm on the M0 reference
                  .so too (FRAME_TRACE=1 on BOTH binaries -- cross-binary
                  symmetric per the arm-state matrix), gate <= 1.02x.

  smoke-composed  ONE run, COW=1 SHARE=1 FRAME_TRACE=1: asserts no crash
                  always; on an M3 binary (guard note present in stderr)
                  additionally asserts cow_* counters are zero; on this
                  pre-M3 binary (guard note necessarily absent) records
                  "pre-M3: composed guard not present yet" without failing.

Every subcommand: jsonl (first row 'kind':'header' carrying the pre-
registered formulas + counter sources for BOTH switch families, per AC-4)
+ a sidecar '<stem>.header.md', + a gnuplot PNG; arm-state column on every
row; quiet gate loadavg<8 per row; one kitty at a time via spawn_kitty().
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


HEADER_MD = '''\
# W25 M4 Gate -- Artifact Header ({block})

Pre-registered arithmetic, quoted verbatim from
`.omc/plans/ralplan-wave25-slotcow-impl.md` Section "Pre-registered gate /
kill criteria" -- this file's STRUCTURE is fixed at M2; a real M4 run fills
in the measured jsonl body rows without needing any manual header edit.

## Counter sources (BOTH switch families)

- **COW-family instrument** (existing Wave-21 trace, `KITTY_PAUSE_SNAPSHOT_COW`):
  `cow_copied` / `cow_skip_eligible` are PER-TICK DIFFS (child-monitor.c
  `ft_cow_copied`/`ft_cow_skip_eligible`, reset every tick in
  `process_global_state`, fed from Screen's cumulative counters diffed in
  `vt-parser.c:1574-1618`); summed across the whole stream, never read from
  the last line alone. Same-block R̂ (M4(i)) = Sigma cow_skip_eligible /
  Sigma cow_copied across >=3 rounds (arm COW=1 SHARE=0).
- **SHARE-family counters** (Lane S "Realized-R counters", NOT YET EMITTED
  at this HEAD -- `share_*` is absent from every child-monitor.c ftrace
  line pre-M3): `share_rows_total` / `share_rows_ref` / `share_cow_retires`,
  SHARE-gated (zero unset cost), egress via the same `KITTY_FRAME_TRACE`
  per-tick emitter pattern (the `child-monitor.c` emitter-extension hunks
  are Lane S product code inside the AC-1 revert-unit scope). Realized R
  (M4(ii)) = (Sigma share_rows_ref - Sigma share_cow_retires) / Sigma
  share_rows_total (ratio block, BOTH arms SHARE=1 COW=0).

## Formulas (pinned, verbatim -- no re-pinning after measurement)

- Same-block R̂ (M4(i)): Sigma cow_skip_eligible / Sigma cow_copied, >=3 rounds.
- Discrimination floor: 0.8 x same-block R̂ (never the W24 0.6781 ceiling).
- Realized R (M4(ii)): (Sigma share_rows_ref - Sigma share_cow_retires) / Sigma share_rows_total.
- Primary gate: same-block true_ms_per_MiB pause-arm / no-pause-arm <= 1.25x.
- Baseline-must-hold: no-pause arm <= 1.02x of the M0 reference binary.
- OFF-cost: unset arm <= 1.02x interleaved parse_ms_per_MiB (see w25_offcost.py).
- Sanity floor: R̂ < 0.14 => STOP, instrument/model fault investigation.
- STOP-and-investigate: R̂ < 0.53 => record-only dated note BEFORE the ratio
  block; the ratio block still runs; the pre-registered bands decide on
  realized numbers -- the investigation is never a band input.
- Single re-run rule: arithmetic re-derivation from the recorded jsonl is
  always permitted; re-RUNNING any M4 block requires a NAMED instrument/
  procedural fault recorded in a dated note BEFORE the re-run, at most
  ONCE; otherwise the FIRST completed block binds.

## Expected-reading annotation (ARCH NOTE-4, load-bearing)

**Realized R > same-block R̂ is an EXPECTED reading** (between-window
writes cost sharing nothing but still count against eligibility) -- never,
by itself, an integrity-investigation trigger.

## This run

{body}
'''


def write_header(jsonl: Path, block: str, extra: dict) -> None:
    row = {
        'kind': 'header', 'block': block,
        'counter_sources': {
            'cow_family': 'cow_copied/cow_skip_eligible per-tick diffs (child-monitor.c, existing W21 instrument)',
            'share_family': 'share_rows_total/share_rows_ref/share_cow_retires, Lane S SHARE-gated (absent pre-M3)',
        },
        'formulas': {
            'same_block_rhat': 'Sigma cow_skip_eligible / Sigma cow_copied across rounds',
            'discrimination_floor': '0.8 * same_block_rhat',
            'realized_R': '(Sigma share_rows_ref - Sigma share_cow_retires) / Sigma share_rows_total',
            'primary_gate': 'same-block true_ms_per_MiB pause/no-pause <= 1.25x',
            'baseline_must_hold': 'no-pause arm <= 1.02x of M0 reference binary',
            'sanity_floor': 'rhat < 0.14 => STOP',
            'stop_and_investigate': 'rhat < 0.53 => record-only note, ratio block still runs',
        },
        'expected_reading_annotation': 'realized R > same-block rhat is EXPECTED, not an integrity fault',
        **extra,
    }
    W.append_jsonl(jsonl, row)
    md = HEADER_MD.format(block=block, body=json.dumps(extra, indent=1))
    jsonl.with_suffix('.header.md').write_text(md)


def render_png(jsonl: Path, plot_fn, rows: list[dict], summary: dict | None) -> None:
    try:
        script = plot_fn(jsonl, rows, summary)
        subprocess.run([P.GNUPLOT], input=script, text=True, check=True)
        png = jsonl.with_suffix('.png')
        assert png.exists() and png.stat().st_size > 0, f'gnuplot produced no output for {jsonl}'
        print(f'wrote {png}')
    except Exception as exc:
        print(f'WARNING: PNG render failed: {exc}', file=sys.stderr)


# --------------------------------------------------------------------------
# rhat
# --------------------------------------------------------------------------

def cmd_rhat(args) -> int:
    current_sha = W.snapshot_current_so()
    W.install_arm(W.CURRENT_SO, current_sha)
    ts = time.strftime('%H%M%S')
    out = W.RESULTS / f'w25-gate-rhat-{ts}.jsonl'
    write_header(out, 'rhat', {
        'binary': 'current-repo (Lane S implementation binary at M3; pre-Lane-S today)',
        'live_so_sha256_16': current_sha, 'rounds': args.rounds, 'secs_per_round': args.secs,
        'workload': 'sync_medium_cells', 'arm_state': W.arm_state(cow=1, share=0, frame_trace=1),
    })
    rows: list[dict] = []
    sigma_copied = sigma_eligible = 0
    for rnd in range(1, args.rounds + 1):
        la0 = W.wait_for_quiet()
        stderr_path = W.LOGS / f'gate-rhat-r{rnd}-{ts}.stderr.log'
        clean, text, samples = W.run_vtebench_row(
            bench='sync_medium_cells', max_secs=args.secs, warmup=1,
            extra_env={'KITTY_PAUSE_SNAPSHOT_COW': '1', 'KITTY_FRAME_TRACE': '1'},
            stderr_path=stderr_path)
        la1 = W.C.loadavg1()
        counters = W.sum_ftrace_counters(text)
        ticks = W.parse_ftrace(text)
        copied, eligible = counters['cow_copied'], counters['cow_skip_eligible']
        sigma_copied += copied
        sigma_eligible += eligible
        r_hat = round(eligible / copied, 5) if copied else -1.0
        row = {
            'kind': 'rhat', 'round': rnd, 'clean_exit': clean,
            'live_so_sha256': W.sha256_16(W.LIVE_SO),
            'arm_state': W.arm_state(cow=1, share=0, frame_trace=1),
            'cow_copied': copied, 'cow_skip_eligible': eligible, 'r_hat': r_hat,
            'pause_on_total': counters['pause_on'], 'pause_off_total': counters['pause_off'],
            'true_ms_per_MiB_informational': W.true_ms_per_mib(ticks),
            'n_samples': len(samples), 'sample_ms_median': W.C.median(samples),
            'loadavg_before': la0, 'loadavg_after': la1,
        }
        rows.append(row)
        W.append_jsonl(out, row)

    sigma_r_hat = round(sigma_eligible / sigma_copied, 5) if sigma_copied else -1.0
    # per-round 4-digit stability: report only, never gate (Critic IMPORTANT-2)
    per_round_4digit = [round(r['r_hat'], 4) for r in rows]
    stability_note = ('stable' if len(set(per_round_4digit)) == 1
                      else f'disagreement across rounds: {per_round_4digit}')
    summary = {
        'kind': 'summary', 'rounds': args.rounds,
        'sigma_cow_copied': sigma_copied, 'sigma_cow_skip_eligible': sigma_eligible,
        'r_hat_sigma_across_rounds': sigma_r_hat,
        'per_round_4digit_stability': per_round_4digit, 'stability_note': stability_note,
        'discrimination_floor_0_8x': round(0.8 * sigma_r_hat, 5) if sigma_r_hat >= 0 else None,
        'sanity_floor_0_14_flag': sigma_r_hat < 0.14 if sigma_r_hat >= 0 else None,
        'stop_and_investigate_0_53_flag': sigma_r_hat < 0.53 if sigma_r_hat >= 0 else None,
        'note': 'STOP flags are record-only per the plan; bands are applied at M5 adjudication, not by this driver',
    }
    W.append_jsonl(out, summary)
    W.install_arm(W.CURRENT_SO, current_sha)
    render_png(out, P.plot_rhat, rows, summary)
    print(json.dumps(summary))
    print(str(out))
    return 0


# --------------------------------------------------------------------------
# ratio
# --------------------------------------------------------------------------

def _timed_row(kind: str, arm: str, bench: str, rnd: int, secs: int, arm_state: dict,
               extra_env: dict, ts: str) -> dict:
    la0 = W.wait_for_quiet()
    stderr_path = W.LOGS / f'gate-{kind}-{arm}-{bench}-r{rnd}-{ts}.stderr.log'
    clean, text, samples = W.run_vtebench_row(
        bench=bench, max_secs=secs, warmup=1, extra_env=extra_env, stderr_path=stderr_path)
    la1 = W.C.loadavg1()
    ticks = W.parse_ftrace(text)
    counters = W.sum_ftrace_counters(text)
    return {
        'kind': kind, 'arm': arm, 'bench': bench, 'round': rnd, 'clean_exit': clean,
        'live_so_sha256': W.sha256_16(W.LIVE_SO), 'arm_state': arm_state,
        'true_ms_per_MiB': W.true_ms_per_mib(ticks),
        'share_rows_total': counters['share_rows_total'],
        'share_rows_ref': counters['share_rows_ref'],
        'share_cow_retires': counters['share_cow_retires'],
        'share_fields_present': (counters['share_rows_total_present']
                                 or counters['share_rows_ref_present']
                                 or counters['share_cow_retires_present']),
        'n_samples': len(samples), 'sample_ms_median': W.C.median(samples),
        'loadavg_before': la0, 'loadavg_after': la1,
    }


def cmd_ratio(args) -> int:
    current_sha = W.snapshot_current_so()
    if not W.M0_SO.exists():
        print(f'ERROR: {W.M0_SO} missing', file=sys.stderr)
        return 2
    m0_sha = W.sha256_16(W.M0_SO)
    ts = time.strftime('%H%M%S')
    out = W.RESULTS / f'w25-gate-ratio-{ts}.jsonl'
    write_header(out, 'ratio', {
        'current_so_sha256_16': current_sha, 'm0_so_sha256_16': m0_sha,
        'rounds': args.rounds, 'secs_per_round': args.secs,
        'workloads': {'nopause': 'medium_cells', 'pause': 'sync_medium_cells'},
        'note': ('share_* fields are parsed defensively: absent on this pre-M3 binary '
                 'means the fields never appear in the ftrace stream at all, recorded '
                 'as share_fields_present=false, NOT as a real zero reading'),
    })
    W.install_arm(W.CURRENT_SO, current_sha)
    rows: list[dict] = []
    share_ever_present = False
    for rnd in range(1, args.rounds + 1):
        order = (('nopause', 'medium_cells'), ('pause', 'sync_medium_cells')) if rnd % 2 else \
                (('pause', 'sync_medium_cells'), ('nopause', 'medium_cells'))
        for arm, bench in order:
            row = _timed_row('ratio', arm, bench, rnd, args.secs,
                             W.arm_state(cow=0, share=1, frame_trace=1),
                             {'KITTY_PAUSE_SNAPSHOT_SHARE': '1', 'KITTY_FRAME_TRACE': '1'}, ts)
            share_ever_present = share_ever_present or row['share_fields_present']
            rows.append(row)
            W.append_jsonl(out, row)

    # Baseline-must-hold (arm-state matrix: "= the ratio block's no-pause
    # arm vs M0" -- the "=" is literal identity, not a description: the
    # current-binary side is the SAME measurement as the 'nopause' rounds
    # just taken above, reused rather than re-spawning an identical kitty
    # run under FRAME_TRACE=1 SHARE=1 a second time). Only the M0-reference
    # side is genuinely new data.
    baseline_rows: list[dict] = [
        {**r, 'kind': 'baseline', 'arm': 'current',
         'note': "reused from this run's own ratio-block 'nopause' round (arm-state matrix identity, not a re-measurement)"}
        for r in rows if r['arm'] == 'nopause'
    ]
    for r in baseline_rows:
        W.append_jsonl(out, r)
    W.install_arm(W.M0_SO, m0_sha)
    for rnd in range(1, args.rounds + 1):
        row = _timed_row('baseline', 'M0', 'medium_cells', rnd, args.secs,
                         W.arm_state(cow=0, share=0, frame_trace=1),
                         {'KITTY_FRAME_TRACE': '1'}, ts)
        baseline_rows.append(row)
        W.append_jsonl(out, row)
    W.install_arm(W.CURRENT_SO, current_sha)

    med_nopause = W.median_precise([r['true_ms_per_MiB'] for r in rows
                                    if r['arm'] == 'nopause' and r['true_ms_per_MiB'] is not None])
    med_pause = W.median_precise([r['true_ms_per_MiB'] for r in rows
                                  if r['arm'] == 'pause' and r['true_ms_per_MiB'] is not None])
    ratio = round(med_pause / med_nopause, 4) if (med_pause and med_nopause) else None
    med_baseline_current = med_nopause  # identical by construction (reused measurement)
    med_baseline_m0 = W.median_precise([r['true_ms_per_MiB'] for r in baseline_rows
                                        if r['arm'] == 'M0' and r['true_ms_per_MiB'] is not None])
    baseline_ratio = round(med_baseline_current / med_baseline_m0, 4) \
        if (med_baseline_current and med_baseline_m0) else None

    sigma_total = sum(r['share_rows_total'] for r in rows)
    sigma_ref = sum(r['share_rows_ref'] for r in rows)
    sigma_retires = sum(r['share_cow_retires'] for r in rows)
    realized_R = round((sigma_ref - sigma_retires) / sigma_total, 5) if sigma_total else None

    all_rows = rows + baseline_rows
    summary = {
        'kind': 'summary', 'rounds': args.rounds,
        'true_ms_per_MiB_median': {'nopause': med_nopause, 'pause': med_pause},
        'ratio_pause_over_nopause': ratio, 'primary_gate_threshold': 1.25,
        'primary_gate_pass_informational': (ratio <= 1.25) if ratio is not None else None,
        'baseline_true_ms_per_MiB_median': {'current': med_baseline_current, 'M0': med_baseline_m0},
        'baseline_ratio_current_over_m0': baseline_ratio, 'baseline_gate_threshold': 1.02,
        'baseline_gate_pass': (baseline_ratio <= 1.02) if baseline_ratio is not None else None,
        'share_fields_present_anywhere': share_ever_present,
        'sigma_share_rows_total': sigma_total, 'sigma_share_rows_ref': sigma_ref,
        'sigma_share_cow_retires': sigma_retires, 'realized_R': realized_R,
        'note': (None if share_ever_present else
                 'share_* fields absent (pre-M3 binary): realized_R/primary-gate readings '
                 'above are informational only, not a real M4(ii) measurement'),
    }
    W.append_jsonl(out, summary)
    # arm already restored to 'current' at line ~290, right after the M0
    # baseline sub-loop -- no second restore needed here.
    render_png(out, P.plot_ratio, all_rows, summary)
    print(json.dumps(summary))
    print(str(out))
    return 0


# --------------------------------------------------------------------------
# smoke-composed
# --------------------------------------------------------------------------

def cmd_smoke_composed(args) -> int:
    current_sha = W.snapshot_current_so()
    W.install_arm(W.CURRENT_SO, current_sha)
    ts = time.strftime('%H%M%S')
    out = W.RESULTS / f'w25-gate-composed-{ts}.jsonl'
    write_header(out, 'smoke-composed', {
        'live_so_sha256_16': current_sha,
        'arm_state': W.arm_state(cow=1, share=1, frame_trace=1),
        'note': ('exactly ONE composed-world row per the plan; on an M3 binary the '
                 'guard note presence proves the SHARE-wins guard fired (counters-zero '
                 'alone cannot distinguish a designed guard from an unaudited-dead '
                 'instrument, ARCH R2-MINOR-3); the guard-note regex is PROVISIONAL '
                 '(see M2-HARNESS-NOTES.md) since Lane S has not landed its message text'),
    })
    la0 = W.wait_for_quiet()
    stderr_path = W.LOGS / f'gate-composed-{ts}.stderr.log'
    clean, text, samples = W.run_vtebench_row(
        bench='sync_medium_cells', max_secs=args.secs, warmup=1,
        extra_env={'KITTY_PAUSE_SNAPSHOT_COW': '1', 'KITTY_PAUSE_SNAPSHOT_SHARE': '1',
                   'KITTY_FRAME_TRACE': '1'},
        stderr_path=stderr_path)
    la1 = W.C.loadavg1()
    counters = W.sum_ftrace_counters(text)
    guard_present = bool(W.GUARD_NOTE_RE.search(text))
    counters_zero = counters['cow_copied'] == 0 and counters['cow_skip_eligible'] == 0
    if guard_present:
        # M3 composed-world assertion: guard fired => instrument counters must be zero.
        counters_zero_pass = counters_zero
        note = ('M3 composed world: guard note PRESENT' if counters_zero_pass else
                'FAIL: guard note present but cow_* counters are nonzero')
    else:
        counters_zero_pass = True  # not a failure pre-M3; nothing to assert yet
        note = 'pre-M3: composed guard not present yet'
    row = {
        'kind': 'composed', 'clean_exit': clean,
        'live_so_sha256': W.sha256_16(W.LIVE_SO),
        'arm_state': W.arm_state(cow=1, share=1, frame_trace=1),
        'cow_copied': counters['cow_copied'], 'cow_skip_eligible': counters['cow_skip_eligible'],
        'guard_note_present': guard_present, 'counters_zero_pass': counters_zero_pass,
        'note': note, 'n_samples': len(samples), 'sample_ms_median': W.C.median(samples),
        'loadavg_before': la0, 'loadavg_after': la1,
    }
    W.append_jsonl(out, row)
    passed = clean and counters_zero_pass  # never fails on the pre-M3 absent-guard branch
    summary = {'kind': 'summary', 'pass': passed, 'guard_note_present': guard_present, 'note': note}
    W.append_jsonl(out, summary)
    W.install_arm(W.CURRENT_SO, current_sha)
    render_png(out, P.plot_composed, [row], summary)
    print(json.dumps(summary))
    print(str(out))
    return 0 if passed else 1


def main() -> int:
    import argparse
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest='cmd', required=True)

    p_rhat = sub.add_parser('rhat')
    p_rhat.add_argument('--rounds', type=int, default=3)
    p_rhat.add_argument('--secs', type=int, default=5)
    p_rhat.set_defaults(func=cmd_rhat)

    p_ratio = sub.add_parser('ratio')
    p_ratio.add_argument('--rounds', type=int, default=3)
    p_ratio.add_argument('--secs', type=int, default=5)
    p_ratio.set_defaults(func=cmd_ratio)

    p_composed = sub.add_parser('smoke-composed')
    p_composed.add_argument('--secs', type=int, default=5)
    p_composed.set_defaults(func=cmd_smoke_composed)

    args = ap.parse_args()
    return args.func(args)


if __name__ == '__main__':
    raise SystemExit(main())
