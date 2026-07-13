#!/usr/bin/env python3.14
"""COW-integrity battery driver for kitty's Wave 25 slot-anchored
refcounted-line COW pause-snapshot design. See
`.omc/plans/ralplan-wave25-slotcow-impl.md` Sec. "Lane H" and "Battery
write classes", and `.omc/verify/wave25/W25-THREAD-AUDIT.md`.

Entirely in-process: builds a single `kitty.fast_data_types.Screen` via the
`kitty_tests` machinery (no kitty binary is launched -- no secrets-hygiene
exposure). Runs N pause/write-storm/unpause cycles on it, each cycle:

  1. BSU (`Screen.pause_rendering(True, ...)`).
  2. Take a shadow deep copy of the LIVE grid's visible rows, read via
     existing bindings (kitty_tests.slot_cow.capture_shadow) -- taken
     BEFORE the first storm write, so it represents what a real snapshot
     would hold at this instant.
  3. Run a write storm composing all 9 pinned write classes
     (kitty_tests.slot_cow.compose_write_storm; shared with the unit
     tests in kitty_tests/slot_cow.py so unit-level and battery-level
     coverage never drift apart).
  4. Draw a deterministic sentinel as the storm's last write, then ESU
     (`Screen.pause_rendering(False)`).
  5. Assert screen sanity: no crash, and the sentinel row reads back
     exactly what the storm should have produced.

The snapshot-byte compare clause (paused snapshot content == shadow) is
STUBBED by default (--snapshot-reader stubbed): the read path for
snapshot bytes does not exist in kitty's Python bindings today (verified
-- only render paths and current_selections() read `paused_rendering`
state; see W25-THREAD-AUDIT.md Part (a).1 and
.omc/verify/wave25/M2-SCOPING.md). This is an M2 scoping decision, not a
silent skip: every run prints a loud banner recording it, and every
per-cycle jsonl row records `snapshot_compare.reader`. --snapshot-reader
available is wired for when the Lane-S debug accessor lands at M3 (name
TBD) -- kitty_tests.slot_cow.compare_snapshot_to_shadow is written as a
one-function swap for that day.

ARCH NOTE-1 (plan M2 milestone): M2 "green" here is harness-EXECUTION
green only -- it does not, and cannot yet, prove snapshot-sharing
correctness (Lane S has not landed). The M3 ON-arm battery is the actual
correctness proof.

Usage:
    python3.14 scripts/w25_cow_battery.py [--cycles 50] [--output PATH]
        [--snapshot-reader stubbed|available]
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUTPUT = REPO_ROOT / '.omc' / 'verify' / 'wave25' / 'results' / 'w25-cow-battery.jsonl'

STUBBED_BANNER = (
    'SNAPSHOT COMPARE STUBBED pending Lane S debug accessor '
    '(M2 scoping decision) -- see .omc/verify/wave25/M2-SCOPING.md'
)

# Importing kitty_tests requires the built kitty.fast_data_types extension
# (kitty/fast_data_types.so), so this stays deferred behind a function
# (called only from run_battery, after argparse has already validated the
# CLI) rather than at module import time -- `--help` keeps working even
# against an unbuilt checkout.


def _make_harness():
    """Return a BaseTest instance usable as a create_screen() factory."""
    sys.path.insert(0, str(REPO_ROOT))
    from kitty_tests import BaseTest

    class _Harness(BaseTest):
        def runTest(self) -> None:  # required by unittest.TestCase.__init__
            pass

    return _Harness()


def run_battery(cycles: int, output_path: Path, snapshot_reader: str, expect_arm: str = 'env') -> bool:
    harness = _make_harness()
    from kitty_tests.slot_cow import (
        COLS,
        LINES,
        SCROLLBACK,
        capture_shadow,
        compare_snapshot_to_shadow,
        compose_write_storm_frozen,
        compose_write_storm_resetting,
        compose_write_storm,
        feed,
        setup_screen_with_history,
    )

    s = harness.create_screen(cols=COLS, lines=LINES, scrollback=SCROLLBACK)
    setup_screen_with_history(s)

    # R25-COMPLETION-REVIEW BLOCKING-1: the artifact must certify WHICH arm
    # ran -- record the resolved switch state, the imported .so identity,
    # and per-cycle slot_share_stats deltas whose values are IMPOSSIBLE on
    # the wrong arm (held == lines after BSU and retires >= 1 across the
    # frozen storm cannot happen under SHARE=0; both are exactly 0 there).
    # W26: the build DEFAULT decides what an unset env resolves to, so the
    # env can no longer classify the arm by itself. --expect-arm pins the
    # expectation ('on'/'off'); 'env' keeps the pre-W26 unset==off reading.
    if expect_arm == 'env':
        share_on = os.environ.get('KITTY_PAUSE_SNAPSHOT_SHARE', '') not in ('', '0')
    else:
        share_on = expect_arm == 'on'
    arm_state = {'COW': 1 if os.environ.get('KITTY_PAUSE_SNAPSHOT_COW', '') not in ('', '0') else 0,
                 'SHARE': 1 if share_on else 0, 'FRAME_TRACE': 0,
                 'SHARE_env': os.environ.get('KITTY_PAUSE_SNAPSHOT_SHARE', '<unset>'),
                 'expect_arm': expect_arm}
    so_path = REPO_ROOT / 'kitty' / 'fast_data_types.so'
    so_sha16 = hashlib.sha256(so_path.read_bytes()).hexdigest()[:16]
    have_stats = hasattr(s, 'slot_share_stats')

    output_path.parent.mkdir(parents=True, exist_ok=True)
    all_green = True
    rows_written = 0
    t_start = time.monotonic()

    with output_path.open('w') as out:
        for cycle in range(cycles):
            cycle_ok = True
            error = None
            try:
                if not s.pause_rendering(True, 5000):
                    raise AssertionError('BSU (pause_rendering(True)) unexpectedly returned False at cycle start')
                st_bsu = s.slot_share_stats() if have_stats else None
                shadow = capture_shadow(s, reader=snapshot_reader)
                # storm first (pause-keeping classes), THEN the frozen-byte
                # compare -- comparing right after capture would be vacuous.
                classes = compose_write_storm_frozen(s, cycle)
                st_poststorm = s.slot_share_stats() if have_stats else None
                cmp_result = compare_snapshot_to_shadow(s, shadow, reader=snapshot_reader)
                if cmp_result['mismatches']:
                    raise AssertionError(f'snapshot diverged from BSU shadow under the storm: rows {cmp_result["mismatches"]}')
                if have_stats and st_bsu is not None and st_poststorm is not None:
                    retire_delta = st_poststorm['cow_retires'] - st_bsu['cow_retires']
                    if share_on:
                        if st_bsu['held'] != LINES:
                            raise AssertionError(f'ON arm: held after BSU = {st_bsu["held"]}, expected {LINES}')
                        if retire_delta < 1:
                            raise AssertionError(f'ON arm: frozen storm produced {retire_delta} retires, expected >= 1')
                    else:
                        if st_bsu['held'] != 0 or retire_delta != 0:
                            raise AssertionError(f'UNSET arm saw share movement: held={st_bsu["held"]} retires={retire_delta}')
                # the pause-resetting classes (resize/rewrap auto-unpause + re-BSU)
                classes += compose_write_storm_resetting(s, cycle)
                sentinel = f'END{cycle:04d}'
                feed(s, f'\x1b[1;1H\x1b[K{sentinel}')
                s.pause_rendering(False)  # harmless no-op if a resize/rewrap class already ended it
                actual = str(s.line(0))
                sentinel_ok = actual == sentinel
                if not sentinel_ok:
                    cycle_ok = False
                    error = f'sentinel mismatch: expected {sentinel!r}, got {actual!r}'
            except Exception as exc:  # noqa: BLE001 -- record, never swallow silently
                st_bsu = st_poststorm = None
                cycle_ok = False
                classes = []
                cmp_result = {'reader': snapshot_reader, 'rows_checked': 0, 'mismatches': None}
                error = f'{type(exc).__name__}: {exc}'

            record = {
                'cycle': cycle,
                'arm_state': arm_state,
                'live_so_sha256': so_sha16,
                'held_after_bsu': None if st_bsu is None else st_bsu['held'],
                'cow_retires_delta_storm': None if (st_bsu is None or st_poststorm is None) else st_poststorm['cow_retires'] - st_bsu['cow_retires'],
                'classes_exercised': classes,
                'snapshot_compare': cmp_result,
                'assertions_passed': cycle_ok,
                'error': error,
            }
            out.write(json.dumps(record) + '\n')
            rows_written += 1
            all_green = all_green and cycle_ok
            if not cycle_ok:
                print(f'cycle {cycle}: RED -- {error}', file=sys.stderr)

    elapsed = time.monotonic() - t_start
    if snapshot_reader != 'available': print(STUBBED_BANNER)
    print(f'{rows_written}/{cycles} cycles green' if all_green else f'{rows_written} cycles run, FAILURES present (see stderr)')
    print(f'elapsed: {elapsed:.2f}s -- jsonl: {output_path}')
    if snapshot_reader != 'available': print(STUBBED_BANNER)
    return all_green


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--cycles', type=int, default=50, help='number of pause/write-storm/unpause cycles (default: 50)')
    parser.add_argument('--output', type=Path, default=DEFAULT_OUTPUT, help=f'jsonl output path (default: {DEFAULT_OUTPUT})')
    parser.add_argument('--expect-arm', choices=('env', 'on', 'off'), default='env',
                        help="arm expectation for the impossible-on-wrong-arm assertions; 'env' derives it from KITTY_PAUSE_SNAPSHOT_SHARE (pre-W26 reading), 'on'/'off' pin it explicitly (needed on default-ON builds where unset resolves on)")
    parser.add_argument('--snapshot-reader', choices=('stubbed', 'available'), default='stubbed',
                         help='stubbed (M2 default): record the comparator as unimplemented, never fabricate a pass. '
                              'available: use the Lane-S debug accessor once it lands (M3).')
    args = parser.parse_args()

    ok = run_battery(args.cycles, args.output, args.snapshot_reader, args.expect_arm)
    raise SystemExit(0 if ok else 1)


if __name__ == '__main__':
    main()
