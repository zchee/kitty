#!/usr/bin/env python3.14
"""Wave-26 M2 energy-measurement harness (two-arm KITTY_PAUSE_SNAPSHOT_SHARE
default-ON energy pass; zero product code). Adapts p2b_energy.py's
--drive/--analyze split + segment-ledger t0/t1 join pattern
(.omc/verify/wave19/p2b_energy.py) to a two-arm env A/B on ONE kitty binary,
per ralplan-wave26-share-default-on.md Section 4-M2/M4 + Section 5.

Every kitty launches ONLY via scripts/_kitty_harness_common.spawn_kitty()
(sanitized env, MonoLisaCode pin), one at a time. This module never invokes
sudo and never builds kitty -- powermetrics is started/stopped by the
OPERATOR in their own shell (`.omc/verify/wave26/M1-SUDO-CHECKPOINT.md`
pinned invocation); `drive` only watches/joins the file it is told about via
--powermetrics-file.

Subcommands
-----------
drive    For each cell in --cells, for each rep in 1..--reps, spawn a fresh
         kitty per (cell, arm) segment: arm order alternates WITHIN the cell
         per rep (R16: rep1 OFF,ON / rep2 ON,OFF / rep3 OFF,ON -- restarting
         at each cell). Both arms are explicit
         (KITTY_PAUSE_SNAPSHOT_SHARE=0 / =1) on the SAME binary --
         no .so swap between arms (unlike Wave-25's cross-binary arms).
         KITTY_FRAME_TRACE=1 on every segment, every arm (R5). Records a
         segment ledger row per (cell, arm, rep) with t0/t1 epoch, live .so
         sha256, arm_state (COW/SHARE/FRAME_TRACE), loadavg, clean_exit, and
         the summed ftrace share_*/pause_* counters for that segment.

         --pilot runs ONLY C-idle x both arms x 1 rep, rows marked
         binding:false (R4); a normal (non-pilot) invocation marks every row
         binding:true. Capture-liveness guard (R8) stats the powermetrics
         file before the first rep and between cells; no growth within 10s
         aborts the drive immediately with a classified record (E2-class
         before the first binding rep starts, S2-class from then on --
         C-R2-1). caffeinate -dis is spawned at drive start and killed at
         exit (R9); its pid is recorded in the header row.

analyze  Parses `Combined Power (CPU + GPU + ANE): N mW` samples out of a
         powermetrics text log (regex verbatim from p2b_energy.py:121), joins
         each ledger segment on [t0+2s, t1-2s] (2s edge trim), requires
         >=50 trimmed samples per rep (else that rep is INVALID -- E3),
         computes per-rep means, per-(cell,arm) medians of up to 3 rep
         means, and per-cell ratio_on_over_off against the 1.03 bar
         (informational only here -- gate adjudication is M5/M6's job, not
         this driver's). Also runs the E2 discrimination check on the pause
         cell (share_rows_total == pause_on_total * 30 on the ON arm, 0 on
         the OFF arm -- the ynum=30 comes from spawn_kitty's fixed
         initial_window_height=30c). Emits a gnuplot PNG of the per-cell
         ratio bars (pngcairo, .omc/verify/wave25/_w25_plot.py pattern).

         --flush-settle implements C-R2-2 (the pilot flush-settle rule):
         before analyzing, block until the powermetrics file has grown past
         the LAST ledger segment's t1, or >=15s have elapsed past t1,
         whichever comes first; if any binding:false (pilot) rep is still
         under the 50-sample floor after that, wait one further settle
         period and re-analyze that rep exactly ONCE. Omit --flush-settle
         when analyzing a closed/finished session file (the real M4/confirm
         analysis) -- there is nothing left to settle for.

Usage:
  w26_energy.py drive --powermetrics-file <path> [--cells idle,typing,flood,pause]
                       [--reps 3] [--pilot] [--output <jsonl>]
  w26_energy.py analyze --powermetrics-file <path> --ledger <jsonl>
                         [--output <jsonl>] [--flush-settle]
"""
from __future__ import annotations

import argparse
import json
import os
import re
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path

REPO = Path('/Users/zchee/src/github.com/kovidgoyal/kitty-worktrees/metal-fable-5')
sys.path.insert(0, str(REPO / '.omc/verify/wave25'))
sys.path.insert(0, str(REPO / '.omc/verify/wave17'))
sys.path.insert(0, str(REPO / 'scripts'))

import _w25_common as W  # noqa: E402
import _w17_common as C  # noqa: E402
from _kitty_harness_common import KITTY_BINARY, spawn_kitty, terminate_kitty  # noqa: E402

HERE = REPO / '.omc/verify/wave26'
RESULTS = HERE / 'results'
LOGS = HERE / 'logs'

CELLS = ('idle', 'typing', 'flood', 'pause')
ARMS = ('off', 'on')
ARM_ENV = {
    'off': {'KITTY_PAUSE_SNAPSHOT_SHARE': '0'},
    'on': {'KITTY_PAUSE_SNAPSHOT_SHARE': '1'},
}
ARM_SHARE_INT = {'off': 0, 'on': 1}

SEGMENT_SECS = 60
EDGE_TRIM_S = 2.0
MIN_TRIMMED_SAMPLES = 50
ENERGY_GATE = 1.03
# spawn_kitty() pins initial_window_height=30c -- the G4/E2 identity
# (share_rows_total == pause_on * ynum) uses THIS geometry's row count.
YNUM = 30
LIVELINESS_TIMEOUT_S = 10.0
FLUSH_SETTLE_TIMEOUT_S = 15.0
TYPING_RATE_CPS = 8.0

GNUPLOT = '/opt/homebrew/bin/gnuplot'
TERMINAL = 'pngcairo size 1600,1000 font ",18" background rgb "white" linewidth 2'

# ---- powermetrics parse, verbatim regex from .omc/verify/wave19/p2b_energy.py:117-121 ----
SAMPLE_RE = re.compile(r'\*\*\* Sampled system activity \((.+?)\) \(([\d.]+)ms elapsed\)')
POWER_RES = {
    'cpu_mw': re.compile(r'^CPU Power:\s+([\d.]+)\s*mW', re.M),
    'gpu_mw': re.compile(r'^GPU Power:\s+([\d.]+)\s*mW', re.M),
    'combined_mw': re.compile(r'^Combined Power \(CPU \+ GPU \+ ANE\):\s+([\d.]+)\s*mW', re.M),
}


def parse_powermetrics(path: Path) -> list[dict]:
    """One record per powermetrics sample block: epoch timestamp + power
    readings. The header timestamp carries a tz token powermetrics formats
    like `Tue Jul  8 13:05:00 2026 +0900`; strptime the datetime part and
    ignore the offset (segments and samples share the machine's clock) --
    identical approach to p2b_energy.py:125-147."""
    if not path.exists():
        return []
    text = path.read_text(errors='replace')
    records = []
    blocks = SAMPLE_RE.split(text)
    for i in range(1, len(blocks) - 2, 3):
        ts_raw, body = blocks[i], blocks[i + 2]
        ts_clean = re.sub(r'\s+[+-]\d{4}$', '', ts_raw.strip())
        try:
            epoch = time.mktime(time.strptime(ts_clean, '%a %b %d %H:%M:%S %Y'))
        except ValueError:
            continue
        rec = {'epoch': epoch}
        for key, rx in POWER_RES.items():
            m = rx.search(body)
            if m:
                rec[key] = float(m.group(1))
        records.append(rec)
    return records


# --------------------------------------------------------------------------
# R16 arm alternation
# --------------------------------------------------------------------------

def arm_order_for_rep(rep: int) -> tuple[str, str]:
    """rep1 OFF,ON / rep2 ON,OFF / rep3 OFF,ON -- restarts at each cell
    (callers re-enter this per-cell with rep starting back at 1)."""
    return ('off', 'on') if rep % 2 == 1 else ('on', 'off')


# --------------------------------------------------------------------------
# caffeinate -dis (R9): mandatory co-run for the DURATION of every drive.
# --------------------------------------------------------------------------

def start_caffeinate() -> subprocess.Popen:
    return subprocess.Popen(['/usr/bin/caffeinate', '-dis'],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def stop_caffeinate(proc: subprocess.Popen | None) -> None:
    if proc is None or proc.poll() is not None:
        return
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=5)


# --------------------------------------------------------------------------
# Capture-liveness guard (R8) + pilot flush-settle (C-R2-2)
# --------------------------------------------------------------------------

def wait_capture_alive(pm_path: Path, timeout_s: float = LIVELINESS_TIMEOUT_S,
                       poll_s: float = 1.0) -> tuple[bool, dict]:
    """Block for up to timeout_s polling pm_path's size; return (alive,
    evidence) as soon as growth is observed, or (False, evidence) once
    timeout_s has elapsed with zero growth. A silently-dead capture must not
    burn the battery undetected (R8) -- this is the checkpoint called before
    the first rep and between cells."""
    if not pm_path.exists():
        return False, {'reason': 'powermetrics file does not exist', 'path': str(pm_path)}
    size0 = pm_path.stat().st_size
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        time.sleep(poll_s)
        size1 = pm_path.stat().st_size
        if size1 > size0:
            return True, {'size_before': size0, 'size_after': size1}
    return False, {'size_before': size0, 'size_after': pm_path.stat().st_size, 'timeout_s': timeout_s}


def wait_flush_settle(pm_path: Path, t1: float, timeout_s: float = FLUSH_SETTLE_TIMEOUT_S,
                      poll_s: float = 1.0) -> dict:
    """C-R2-2: block until pm_path contains a sample timestamped past t1
    (the capture has flushed data covering the segment), OR timeout_s has
    elapsed past t1 -- whichever comes first. Never raises; always returns
    evidence. A no-op in practice when pm_path is a closed/finished session
    file that already has data well past t1 (first poll returns True)."""
    deadline_wall = t1 + timeout_s
    while True:
        samples = parse_powermetrics(pm_path)
        max_epoch = max((s['epoch'] for s in samples), default=None)
        grown_past_t1 = max_epoch is not None and max_epoch > t1
        now = time.time()
        if grown_past_t1 or now >= deadline_wall:
            return {'grown_past_t1': grown_past_t1, 'max_epoch': max_epoch, 't1': t1,
                    'elapsed_past_t1_s': round(now - t1, 2)}
        time.sleep(poll_s)


# --------------------------------------------------------------------------
# Cell workload drivers
# --------------------------------------------------------------------------

def _cell_shell_cmd(cell: str, dat: Path | None) -> str:
    if cell == 'idle':
        return f'sleep {SEGMENT_SECS}'
    if cell == 'flood':
        return C.vtebench_cmd('scrolling', dat, max_secs=SEGMENT_SECS, warmup=1)
    if cell == 'pause':
        return C.vtebench_cmd('sync_medium_cells', dat, max_secs=SEGMENT_SECS, warmup=1)
    raise ValueError(f'no shell-command workload for cell {cell!r}')


def run_idle_flood_pause_segment(cell: str, extra_env: dict, stderr_path: Path) -> dict:
    """idle/flood/pause all share one shape: spawn kitty running a bounded
    shell command (sleep or a max-secs-bounded vtebench invocation --
    vtebench's own --max-secs already fills the 60s, no external looping
    needed), capture stderr (ftrace lines land there under
    KITTY_FRAME_TRACE=1), wait for natural exit."""
    td = Path(tempfile.mkdtemp(prefix=f'w26-{cell}-'))
    dat = None if cell == 'idle' else td / 'out.dat'
    cmd = _cell_shell_cmd(cell, dat)
    stderr_path.parent.mkdir(parents=True, exist_ok=True)
    t0 = time.time()
    with open(stderr_path, 'wb') as fh:
        proc = spawn_kitty(['/bin/sh', '-c', cmd], take_focus=False, extra_env=extra_env, stderr=fh)
        clean = True
        try:
            proc.wait(timeout=SEGMENT_SECS + 45)
        except subprocess.TimeoutExpired:
            clean = False
            terminate_kitty(proc)
    t1 = time.time()
    text = stderr_path.read_text(errors='replace') if stderr_path.exists() else ''
    return {'t0': t0, 't1': t1, 'clean_exit': clean, 'ftrace_text': text}


def run_typing_segment(extra_env: dict, stderr_path: Path) -> dict:
    """C-typing (R7): paced ~8 chars/s for 60s via `kitty @ send-text` over a
    remote-control socket (this codebase's remote-control entry point is
    `kitty @ ...` throughout -- see wave22/wave23 precedent; there is no
    separate `kitten` executable built in this tree). spawn_kitty's config
    gains allow_remote_control=yes + listen_on=unix:<sock> for this cell
    only. The spawned window runs kitty's default interactive shell (no
    argv_command) so send-text delivers into a live PTY; the segment length
    is controlled by us (terminate_kitty after 60s), not by the child
    exiting on its own -- clean_exit here means "SIGTERM alone was
    sufficient" (terminate_kitty's own kill-safety contract), not "exited
    unprompted"."""
    sock = f'/tmp/w26-typing-{os.getpid()}.sock'
    stderr_path.parent.mkdir(parents=True, exist_ok=True)
    t0 = time.time()
    chars_sent = 0
    send_errors = 0
    term_clean = True
    with open(stderr_path, 'wb') as fh:
        proc = spawn_kitty(
            extra_env=extra_env,
            extra_kitty_opts=['allow_remote_control=yes', f'listen_on=unix:{sock}'],
            stderr=fh,
        )
        actual = f'unix:{sock}-{proc.pid}'

        def kat(*args: str, timeout: float = 15) -> subprocess.CompletedProcess:
            return subprocess.run([str(KITTY_BINARY), '@', '--to', actual, *args],
                                  capture_output=True, text=True, timeout=timeout)

        try:
            up = False
            for _ in range(50):
                if kat('ls').returncode == 0:
                    up = True
                    break
                time.sleep(0.2)
            if not up:
                raise RuntimeError(f'remote-control socket never came up at {actual}')
            pool = 'abcdefghijklmnopqrstuvwxyz'
            start_mono = time.monotonic()
            deadline = start_mono + SEGMENT_SECS
            tick_s = 0.25
            while time.monotonic() < deadline:
                time.sleep(tick_s)
                elapsed = time.monotonic() - start_mono
                target_chars = int(elapsed * TYPING_RATE_CPS)
                shortfall = target_chars - chars_sent
                if shortfall > 0:
                    text = ''.join(pool[i % len(pool)] for i in range(chars_sent, chars_sent + shortfall))
                    r = kat('send-text', '--match', 'state:focused', text)
                    if r.returncode != 0:
                        send_errors += 1
                    else:
                        chars_sent += shortfall
        finally:
            term_clean = terminate_kitty(proc)
    t1 = time.time()
    text_log = stderr_path.read_text(errors='replace') if stderr_path.exists() else ''
    return {
        't0': t0, 't1': t1, 'clean_exit': term_clean, 'ftrace_text': text_log,
        'chars_sent': chars_sent, 'send_errors': send_errors,
        'observed_cps': round(chars_sent / (t1 - t0), 3) if t1 > t0 else None,
    }


def run_segment(cell: str, arm: str, rep: int, ts: str, binding: bool) -> dict:
    extra_env = {'KITTY_FRAME_TRACE': '1', **ARM_ENV[arm]}
    stderr_path = LOGS / f'w26-{cell}-{arm}-r{rep}-{ts}.stderr.log'
    la0 = C.loadavg1()
    if cell == 'typing':
        res = run_typing_segment(extra_env, stderr_path)
    else:
        res = run_idle_flood_pause_segment(cell, extra_env, stderr_path)
    la1 = C.loadavg1()
    counters = W.sum_ftrace_counters(res['ftrace_text'])
    row = {
        'kind': 'segment', 'cell': cell, 'arm': arm, 'rep': rep, 'binding': binding,
        't0_epoch': round(res['t0'], 3), 't1_epoch': round(res['t1'], 3),
        'wall_s': round(res['t1'] - res['t0'], 2),
        'clean_exit': res['clean_exit'],
        'live_so_sha256_16': W.sha256_16(W.LIVE_SO) if W.LIVE_SO.exists() else None,
        'arm_state': W.arm_state(cow=0, share=ARM_SHARE_INT[arm], frame_trace=1),
        'loadavg_before': la0, 'loadavg_after': la1,
        'pause_on_total': counters['pause_on'], 'pause_off_total': counters['pause_off'],
        'share_rows_total': counters['share_rows_total'],
        'share_rows_ref': counters['share_rows_ref'],
        'share_cow_retires': counters['share_cow_retires'],
        'share_fields_present': (counters['share_rows_total_present']
                                 or counters['share_rows_ref_present']
                                 or counters['share_cow_retires_present']),
        'stderr_log': str(stderr_path.relative_to(REPO)),
    }
    if cell == 'typing':
        row['typing_chars_sent'] = res['chars_sent']
        row['typing_send_errors'] = res['send_errors']
        row['typing_observed_cps'] = res['observed_cps']
    return row


# --------------------------------------------------------------------------
# drive
# --------------------------------------------------------------------------

def _abort(out: Path, reason: str, evidence: dict, first_binding_rep_started: bool) -> dict:
    classification = 'S2' if first_binding_rep_started else 'E2'
    row = {'kind': 'abort', 'reason': reason, 'classification': classification, **evidence}
    W.append_jsonl(out, row)
    print(f'ABORT ({classification}): {reason} :: {evidence}', file=sys.stderr)
    return row


def cmd_drive(args: argparse.Namespace) -> int:
    RESULTS.mkdir(parents=True, exist_ok=True)  # R12
    LOGS.mkdir(parents=True, exist_ok=True)
    pm_path = Path(args.powermetrics_file)

    cells = [c.strip() for c in args.cells.split(',') if c.strip()]
    bad = [c for c in cells if c not in CELLS]
    if bad:
        print(f'ERROR: unknown cell(s) {bad}; valid: {CELLS}', file=sys.stderr)
        return 2

    if args.pilot:
        if cells != ['idle'] or args.reps != 1:
            print(f'NOTE: --pilot forces cells=[idle] reps=1 (ignoring --cells={args.cells!r} '
                 f'--reps={args.reps})', file=sys.stderr)
        cells = ['idle']
        reps_eff = 1
    else:
        reps_eff = args.reps

    ts = time.strftime('%H%M%S')
    default_name = f'w26-pilot-{ts}.jsonl' if args.pilot else f'w26-energy-{ts}.jsonl'
    out = Path(args.output) if args.output else (RESULTS / default_name)

    caff = start_caffeinate()
    print(f'caffeinate -dis started pid={caff.pid}', flush=True)

    header = {
        'kind': 'header', 'pilot': bool(args.pilot), 'cells': cells, 'reps': reps_eff,
        'segment_secs': SEGMENT_SECS, 'powermetrics_file': str(pm_path),
        'caffeinate_pid': caff.pid,
        'live_so_sha256_16': W.sha256_16(W.LIVE_SO) if W.LIVE_SO.exists() else None,
        'edge_trim_s': EDGE_TRIM_S, 'energy_gate': ENERGY_GATE, 'ynum': YNUM,
        'typing_rate_cps': TYPING_RATE_CPS,
    }
    W.append_jsonl(out, header)

    rows: list[dict] = []
    first_binding_rep_started = False
    try:
        alive, evidence = wait_capture_alive(pm_path)
        W.append_jsonl(out, {'kind': 'liveness_check', 'when': 'before_first_rep', 'alive': alive, **evidence})
        if not alive:
            _abort(out, 'capture not growing before first rep', evidence, first_binding_rep_started)
            return 3

        for ci, cell in enumerate(cells):
            if ci > 0:
                alive, evidence = wait_capture_alive(pm_path)
                W.append_jsonl(out, {'kind': 'liveness_check', 'when': f'between_cells_before_{cell}',
                                     'alive': alive, **evidence})
                if not alive:
                    _abort(out, f'capture not growing before cell {cell}', evidence, first_binding_rep_started)
                    return 3
            for rep in range(1, reps_eff + 1):
                for arm in arm_order_for_rep(rep):
                    if not args.pilot:
                        first_binding_rep_started = True
                    W.wait_for_quiet()  # quiet gate: loadavg<8 immediately before (R2-NOTE-3 exempts the harness itself)
                    row = run_segment(cell, arm, rep, ts, binding=not args.pilot)
                    rows.append(row)
                    W.append_jsonl(out, row)
                    print(json.dumps({k: row[k] for k in
                                      ('cell', 'arm', 'rep', 'binding', 'clean_exit', 'wall_s')}), flush=True)
    finally:
        stop_caffeinate(caff)
        print(f'caffeinate -dis (pid={caff.pid}) stopped', flush=True)

    summary = {'kind': 'summary', 'n_segments': len(rows), 'pilot': bool(args.pilot)}
    W.append_jsonl(out, summary)
    print(str(out))
    return 0


# --------------------------------------------------------------------------
# analyze
# --------------------------------------------------------------------------

def _e2_discrimination(seg_rows: list[dict]) -> dict:
    """C-pause ON reps: share_rows_total == pause_on_total * YNUM (EXACT,
    the G4 identity) and > 0; OFF reps: share_rows_total == 0. Absence of
    any pause-cell rows in this ledger is 'not applicable', not a failure
    (e.g. analyzing a single-cell pilot or a typing-only dry-run)."""
    pause_rows = [r for r in seg_rows if r['cell'] == 'pause']
    if not pause_rows:
        return {'kind': 'e2_discrimination', 'applicable': False,
                'note': 'no pause-cell rows in this ledger'}
    problems = []
    for r in pause_rows:
        total = r.get('share_rows_total', 0)
        pause_on = r.get('pause_on_total', 0)
        if r['arm'] == 'on':
            expected = pause_on * YNUM
            if not (total == expected and total > 0):
                problems.append({'rep': r['rep'], 'arm': 'on', 'share_rows_total': total,
                                 'pause_on_total': pause_on, 'expected': expected})
        else:
            if total != 0:
                problems.append({'rep': r['rep'], 'arm': 'off', 'share_rows_total': total, 'expected': 0})
    return {'kind': 'e2_discrimination', 'applicable': True, 'valid': not problems,
            'problems': problems, 'identity': f'share_rows_total == pause_on_total * {YNUM}',
            'n_pause_rows': len(pause_rows)}


def render_cell_ratio_png(out_path: Path, cell_summaries: list[dict]) -> None:
    bars = []
    for i, cs in enumerate(cell_summaries):
        ratio = cs['ratio_on_over_off']
        bars.append(f'{i} "{cs["cell"]}" {ratio if ratio is not None else 0}')
    script = f'''
set terminal {TERMINAL}
set output '{out_path.with_suffix(".png")}'
set title "W26 energy ratio ON/OFF per cell (Combined Power, median of rep means)"
$DATA << EOD
{chr(10).join(bars)}
EOD
set style data histograms
set style fill solid 0.8 border -1
set boxwidth 0.6
set key off
set ylabel "ratio_on_over_off"
set xlabel "cell"
set yrange [0:*]
set label 1 "gate: ratio <= {ENERGY_GATE}x per cell (informational -- adjudicated at M5/M6)" \
at graph 0.02, graph 0.95 font ",14"
plot $DATA using 3:xtic(2) lc rgb "#4477aa"
unset label 1
'''
    try:
        subprocess.run([GNUPLOT], input=script, text=True, check=True)
        png = out_path.with_suffix('.png')
        assert png.exists() and png.stat().st_size > 0, f'gnuplot produced no output for {out_path}'
        print(f'wrote {png}')
    except Exception as exc:
        print(f'WARNING: PNG render failed: {exc}', file=sys.stderr)


# vtebench-class cells only (§4-M4 deliverables: "a gnuplot PNG per
# vtebench-class cell (C-flood, C-pause)") -- idle/typing are not vtebench
# workloads and get no raw-trace PNG.
VTEBENCH_CLASS_CELLS = ('flood', 'pause')


def render_cell_trace_png(out_path: Path, cell: str, seg_rows: list[dict], samples: list[dict]) -> None:
    """One PNG per vtebench-class cell: raw Combined Power samples across
    each of that cell's segments, x-axis = seconds since that segment's t0
    (so OFF/ON/rep series overlay on a comparable clock), NOT the
    edge-trimmed/averaged reading -- this is the raw-trace companion to the
    ratio-bar summary PNG, adapted from the wave21/wave25 pngcairo pattern."""
    cell_rows = [r for r in seg_rows if r['cell'] == cell]
    if not cell_rows:
        return
    blocks, plots = [], []
    for i, r in enumerate(cell_rows):
        t0, t1 = r['t0_epoch'], r['t1_epoch']
        pts = sorted((round(s['epoch'] - t0, 2), s['combined_mw']) for s in samples
                    if t0 <= s['epoch'] <= t1 and 'combined_mw' in s)
        if not pts:
            continue
        blocks.append(f'$S{i} << EOD\n' + '\n'.join(f'{x} {y}' for x, y in pts) + '\nEOD')
        plots.append(f'$S{i} using 1:2 title "{r["arm"]}/r{r["rep"]}" lw 2 pt {5 + i}')
    if not plots:
        return
    png_path = out_path.parent / f'{out_path.stem}-{cell}-trace.png'
    script = f'''
set terminal {TERMINAL}
set output '{png_path}'
set title "W26 {cell} cell -- raw Combined Power trace per segment (unaveraged, no edge trim)"
{chr(10).join(blocks)}
set style data linespoints
set xlabel "seconds since segment t0"
set ylabel "combined_mw"
set key outside right
plot {', '.join(plots)}
'''
    try:
        subprocess.run([GNUPLOT], input=script, text=True, check=True)
        assert png_path.exists() and png_path.stat().st_size > 0, f'gnuplot produced no output for {cell} trace'
        print(f'wrote {png_path}')
    except Exception as exc:
        print(f'WARNING: {cell} trace PNG render failed: {exc}', file=sys.stderr)


def cmd_analyze(args: argparse.Namespace) -> int:
    pm_path = Path(args.powermetrics_file)
    ledger_path = Path(args.ledger)
    out = Path(args.output) if args.output else (RESULTS / f'{ledger_path.stem}-analyzed.jsonl')

    ledger_rows = [json.loads(l) for l in ledger_path.read_text().splitlines() if l.strip()]
    seg_rows = [r for r in ledger_rows if r.get('kind') == 'segment']
    if not seg_rows:
        print(f'ERROR: no segment rows in {ledger_path}', file=sys.stderr)
        return 2

    W.append_jsonl(out, {
        'kind': 'header', 'powermetrics_file': str(pm_path), 'ledger_file': str(ledger_path),
        'edge_trim_s': EDGE_TRIM_S, 'min_trimmed_samples': MIN_TRIMMED_SAMPLES,
        'energy_gate': ENERGY_GATE, 'flush_settle': bool(args.flush_settle),
    })

    if args.flush_settle:
        last_t1 = max(r['t1_epoch'] for r in seg_rows)
        settle = wait_flush_settle(pm_path, last_t1)
        W.append_jsonl(out, {'kind': 'flush_settle', 'when': 'pre_analyze', **settle})
        print(f'flush-settle: {settle}', flush=True)

    samples = parse_powermetrics(pm_path)
    if not samples:
        print(f'ERROR: no powermetrics samples parsed from {pm_path}', file=sys.stderr)
        return 1

    def trimmed_vals(seg: dict) -> list[float]:
        lo, hi = seg['t0_epoch'] + EDGE_TRIM_S, seg['t1_epoch'] - EDGE_TRIM_S
        return [s['combined_mw'] for s in samples if lo <= s['epoch'] <= hi and 'combined_mw' in s]

    rep_rows: list[dict] = []
    for seg in seg_rows:
        vals = trimmed_vals(seg)
        entry = {
            'kind': 'rep', 'cell': seg['cell'], 'arm': seg['arm'], 'rep': seg['rep'],
            'binding': seg.get('binding', True),
            'n_trimmed_samples': len(vals),
            'mean_combined_mw': round(statistics.fmean(vals), 3) if vals else None,
            'valid': len(vals) >= MIN_TRIMMED_SAMPLES,
            't0_epoch': seg['t0_epoch'], 't1_epoch': seg['t1_epoch'],
        }
        rep_rows.append(entry)

    # C-R2-2: ONE re-analyze retry, pilot (binding:false) rows only, after a
    # further settle -- never a loop, never applied to binding rows (those
    # are governed by E3's plain re-run-once rule at the driver/session
    # level, not by this analyzer).
    if args.flush_settle:
        under = [r for r in rep_rows if r['binding'] is False and not r['valid']]
        if under:
            print(f'flush-settle: {len(under)} pilot rep(s) under {MIN_TRIMMED_SAMPLES} samples; '
                 f'waiting {FLUSH_SETTLE_TIMEOUT_S}s further and re-analyzing ONCE', flush=True)
            time.sleep(FLUSH_SETTLE_TIMEOUT_S)
            samples = parse_powermetrics(pm_path)
            for r in under:
                seg = next(s for s in seg_rows
                          if s['cell'] == r['cell'] and s['arm'] == r['arm'] and s['rep'] == r['rep'])
                vals = trimmed_vals(seg)
                r['n_trimmed_samples'] = len(vals)
                r['mean_combined_mw'] = round(statistics.fmean(vals), 3) if vals else None
                r['valid'] = len(vals) >= MIN_TRIMMED_SAMPLES
                r['reanalyzed'] = True

    for r in rep_rows:
        W.append_jsonl(out, r)

    grouped: dict[tuple[str, str], list[float]] = {}
    for r in rep_rows:
        if r['binding'] and r['valid'] and r['mean_combined_mw'] is not None:
            grouped.setdefault((r['cell'], r['arm']), []).append(r['mean_combined_mw'])

    cell_summaries = []
    for cell in CELLS:
        off_means = grouped.get((cell, 'off'), [])
        on_means = grouped.get((cell, 'on'), [])
        if not off_means and not on_means:
            continue
        med_off = statistics.median(off_means) if off_means else None
        med_on = statistics.median(on_means) if on_means else None
        ratio = round(med_on / med_off, 4) if (med_on is not None and med_off) else None
        cell_summaries.append({
            'kind': 'cell_summary', 'cell': cell,
            'median_off_mw': round(med_off, 3) if med_off is not None else None,
            'median_on_mw': round(med_on, 3) if med_on is not None else None,
            'n_reps_off': len(off_means), 'n_reps_on': len(on_means),
            'ratio_on_over_off': ratio, 'gate_threshold': ENERGY_GATE,
            'gate_pass_informational': (ratio <= ENERGY_GATE) if ratio is not None else None,
        })
    for cs in cell_summaries:
        W.append_jsonl(out, cs)

    e2 = _e2_discrimination(seg_rows)
    W.append_jsonl(out, e2)

    summary = {
        'kind': 'summary', 'n_reps': len(rep_rows),
        'n_reps_valid': sum(1 for r in rep_rows if r['valid']),
        'n_reps_binding': sum(1 for r in rep_rows if r['binding']),
        'cells': [cs['cell'] for cs in cell_summaries], 'e2_valid': e2.get('valid'),
    }
    W.append_jsonl(out, summary)

    if cell_summaries:
        render_cell_ratio_png(out, cell_summaries)
    for cell in VTEBENCH_CLASS_CELLS:
        render_cell_trace_png(out, cell, seg_rows, samples)

    print(json.dumps({'cell_summaries': cell_summaries, 'e2': e2, 'summary': summary}, default=str))
    print(str(out))
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)

    p_drive = sub.add_parser('drive')
    p_drive.add_argument('--cells', default=','.join(CELLS))
    p_drive.add_argument('--reps', type=int, default=3)
    p_drive.add_argument('--output', default=None)
    p_drive.add_argument('--pilot', action='store_true')
    p_drive.add_argument('--powermetrics-file', required=True)
    p_drive.set_defaults(func=cmd_drive)

    p_analyze = sub.add_parser('analyze')
    p_analyze.add_argument('--powermetrics-file', required=True)
    p_analyze.add_argument('--ledger', required=True)
    p_analyze.add_argument('--output', default=None)
    p_analyze.add_argument('--flush-settle', action='store_true',
                           help='C-R2-2 mid-session pilot settle + one re-analyze retry; '
                                'omit when analyzing a closed/finished powermetrics file.')
    p_analyze.set_defaults(func=cmd_analyze)

    args = ap.parse_args(argv)
    return args.func(args)


if __name__ == '__main__':
    raise SystemExit(main())
