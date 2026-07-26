#!/usr/bin/env python3.14
"""R5 Q-paint runner: N fresh-spawn r4_image_cell reps per arm (frozen N=50).

Per rep parse (frozen section 3): dpaint = presented_time(first
metal_present line ordered AFTER the 'qos_probe: thread=disk-cache' head
line in the same stderr stream) - presented_time(first metal_present).
Rep without a disk-cache head line is INVALID (writer never engaged) and
is rerun once. Cold first-paint (observational) = first presented_time -
spawn timestamp taken on CLOCK_UPTIME_RAW (the mach_absolute_time /
CACurrentMediaTime timebase metal.m stamps presented_time with).
"""
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

REPO = Path('/Users/zchee/src/github.com/kovidgoyal/kitty-worktrees/metal-fable-5')
R = REPO / '.omc/verify/r5/results'
CELL = str(REPO / 'scripts/r4_image_cell.py')
PRESENT = re.compile(r'^metal_present\s+frame=(\d+)\s+presented_time=([\d.]+)')
HEAD = 'qos_probe: thread=disk-cache '
SECONDS = 4.0


def parse(log: Path) -> dict:
    first = None
    post = None
    seen_head = False
    for line in log.read_text(errors='replace').splitlines():
        m = PRESENT.match(line)
        if m:
            t = float(m.group(2))
            if t == 0.0:
                continue  # known first-drawable zero-timestamp quirk
            if first is None:
                first = t
            if seen_head and post is None:
                post = t
        elif line.startswith(HEAD):
            seen_head = True
    if not seen_head:
        return {'error': 'no disk-cache head (writer never engaged)'}
    if first is None or post is None:
        return {'error': 'missing metal_present before/after head'}
    return {'first_present': first, 'post_head_present': post,
            'dpaint_s': post - first}


def run_rep(arm: str, rep: int) -> dict:
    log = R / f'qpaint-{arm}-r{rep}.stderr.log'
    argv = ['python3.14', CELL, '--seconds', str(SECONDS), '--log', str(log),
            '--env', 'KITTY_QOS_DEBUG=1', '--env', 'KITTY_METAL_STATS=1']
    if arm == 'armed':
        argv += ['--env', 'KITTY_THREAD_QOS=1']
    row = {'arm': arm, 'rep': rep, 'load_before': os.getloadavg()[0],
           'wave26_default_inherited': True}
    t_spawn = time.clock_gettime(time.CLOCK_UPTIME_RAW)
    try:
        subprocess.run(argv, cwd=REPO, timeout=SECONDS + 30, check=True,
                       capture_output=True)
    except subprocess.SubprocessError as e:
        row['error'] = f'cell failed: {e}'
        return row
    row.update(parse(log))
    if 'first_present' in row:
        row['cold_first_paint_s'] = row['first_present'] - t_spawn
    return row


def main() -> int:
    lo, hi = int(sys.argv[1]), int(sys.argv[2])
    out = []
    for rep in range(lo, hi + 1):
        for arm in ('unset', 'armed'):
            row = run_rep(arm, rep)
            if row.get('error'):
                retry = run_rep(arm, rep)
                retry['retried'] = True
                if retry.get('error'):
                    retry['invalid_twice'] = True
                row = retry
            out.append(row)
            print(f"rep {rep} {arm}: {row.get('dpaint_s', row.get('error'))}",
                  file=sys.stderr)
    dest = R / f'qpaint-rows-{lo}-{hi}.json'
    dest.write_text(json.dumps(out, indent=1))
    print(f'wrote {dest}', file=sys.stderr)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
