#!/usr/bin/env python3.14
"""W26b CPU-side state-cost driver (plan v5 §1-M0/M1/M2; frozen §3 shapes).

Self-contained (imports only tracked modules — plan §0.6-15): measures
`parse_ms_per_MiB` (ftrace totals) and the rusage cycles/instructions axis
per fresh-spawn kitty row running a vtebench workload, across the wave's
block shapes:

  pilot-same   M0 same-binary A/A     -> aa_hw, aa_hw_cyc
  pilot-xbin   M0 cross-binary A/A    -> aa_hw_xbin, aa_hw_cyc_xbin
  ab           M1-R1 SHARE=1 vs =0 on one binary (P1) / context benches
  threebin     M1-R2 attribution {B_base, B_hint, B_flag_probe}, SHARE=1
  fourarm      M2 {B_base,B_flag} x {SHARE=0,1} (r_fix/T1/T2/T3/T5')
  engaged      T4 engaged cell (sync_medium_cells) per binary

W26c (plan §1-M0 C-harness) extends the same file behind `--wave w26c`,
which only re-points VERIFY/RESULTS/BINDIR and swaps the flood arm map to
{B_baseprime, B_flip}; every subcommand keeps its w26b behavior by default:

  energy         generalized drive: cells pilot/flood/idle/typing/pause
                 against an operator-started powermetrics capture, with the
                 capture-liveness guard and a ledger rewritten per row
  energy-analyze the tracked trim-join analyzer + its two self-checks
  xab            two-arm BINARY:ENV block (G2 lever cost / CPU sanity)
  rss            G6 peak-RSS driver over the pause shape

Constants (bootstrap CI95 half-width of the ratio of medians, 4000
resamples, seed 4) use the gates' own estimator. Binary arms swap by
FRESH-INODE install from saved `.so.bin` artifacts, serialized between
rows (no kitty running at swap time). Discipline per row: loadavg < 8
wait, >= 10 s pacing, FT=1 every arm, lever env explicit, live so sha,
`share_rows_total == 0` asserted on non-engaged rows.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import random
import re
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _kitty_harness_common as h
import _r3_rusage as rusage

WAVE = "w26b"
WAVE_DIR = {"w26b": "wave26b", "w26c": "wave26c"}

VERIFY = h.REPO_ROOT / ".omc" / "verify" / WAVE_DIR[WAVE]
RESULTS = VERIFY / "results"
BINDIR = VERIFY / "binaries"
SO_PATH = h.REPO_ROOT / "kitty" / "fast_data_types.so"

# Per-wave flood arm map. `arm[:-1]`/`arm[-1]` still splits binary/lever for
# both spellings (base0/basep0). `flip` names the lever-carrying binary --
# the one every non-flood cell and `--flood-arms flip` runs on.
WAVE_ARMS = {
    "w26b": {"four": ["base0", "base1", "flag0", "flag1"],
             "binmap": {"base": "B_base", "flag": "B_flag"},
             "flip": "flag", "default_bin": "B_base", "restore": "B_flag",
             "engaged": ["B_base", "B_flag"]},
    "w26c": {"four": ["basep0", "basep1", "flip0", "flip1"],
             "binmap": {"basep": "B_baseprime", "flip": "B_flip"},
             "flip": "flip", "default_bin": "B_baseprime", "restore": "B_flip",
             "engaged": ["B_baseprime", "B_flip"]},
}


def set_wave(wave: str) -> None:
    """Re-point the artifact roots; every consumer reads them at call time."""
    global WAVE, VERIFY, RESULTS, BINDIR
    WAVE = wave
    VERIFY = h.REPO_ROOT / ".omc" / "verify" / WAVE_DIR[wave]
    RESULTS = VERIFY / "results"
    BINDIR = VERIFY / "binaries"

VTEBENCH = Path("/Users/zchee/src/github.com/alacritty/vtebench/target/release/vtebench")
VB_BENCH = Path("/Users/zchee/src/github.com/alacritty/vtebench/benchmarks")

SEGMENT_SECS = 60
PACING_S = 10.0
LOAD_THRESHOLD = 8.0
BOOT_RESAMPLES = 4000
BOOT_SEED = 4
YNUM = 30  # spawn_kitty geometry row count: the engaged identity multiplier

# Energy machinery (W26-era constants, unchanged so W26b/W26c ledgers and the
# retained W26 confirm analysis share one estimator).
EDGE_TRIM_S = 2.0
MIN_TRIMMED_SAMPLES = 50
ENERGY_GATE = 1.03
LIVELINESS_TIMEOUT_S = 10.0
FLUSH_SETTLE_TIMEOUT_S = 15.0
TYPING_RATE_CPS = 8.0
ENERGY_CELLS = ("pilot", "flood", "idle", "typing", "pause")

GNUPLOT = "/opt/homebrew/bin/gnuplot"
TERMINAL = ('pngcairo size 1600,1000 font ",18" background rgb "white" '
            'linewidth 2')

FTRACE_RE = re.compile(r"ftrace: seq=\d+ .*")
KV_RE = re.compile(r"(\w+)=([-\d.]+)")


def bench_dir(bench: str) -> Path:
    """Per-benchmark dir holding a single symlink, so `vtebench -b <dir>`
    sees exactly one benchmark (the w17 shape -- a shared links dir makes
    vtebench run every accumulated bench sequentially per row)."""
    d = VERIFY / "bench-links" / bench
    d.mkdir(parents=True, exist_ok=True)
    link = d / bench
    if not link.exists():
        link.symlink_to(VB_BENCH / bench)
    return d


def vtebench_cmd(bench: str, dat: Path) -> str:
    return (f'"{VTEBENCH}" -b "{bench_dir(bench)}" --max-secs {SEGMENT_SECS} '
            f'--warmup 1 --silent --dat "{dat}"; echo VTEDONE >> "{dat}"')


def live_so_sha() -> str:
    return hashlib.sha256(SO_PATH.read_bytes()).hexdigest()[:16]


def install_binary(name: str) -> str:
    """FRESH-INODE install of a saved arm (`<name>.so.bin`); returns sha."""
    src = BINDIR / f"{name}.so.bin"
    tmp = SO_PATH.parent / f".w26b-install-{os.getpid()}.tmp"
    tmp.write_bytes(src.read_bytes())
    tmp.chmod(0o755)
    os.replace(tmp, SO_PATH)
    return live_so_sha()


def wait_for_quiet(threshold: float = LOAD_THRESHOLD, timeout_s: float = 900.0) -> float:
    deadline = time.monotonic() + timeout_s
    while True:
        load = os.getloadavg()[0]
        if load < threshold:
            return load
        if time.monotonic() > deadline:
            raise RuntimeError(f"loadavg never dropped below {threshold} (last {load})")
        time.sleep(10.0)


def ftrace_totals(text: str) -> dict:
    tot: dict[str, float] = {}
    ticks = 0
    for line in text.splitlines():
        m = FTRACE_RE.search(line)
        if not m:
            continue
        ticks += 1
        for k, v in KV_RE.findall(m.group(0)):
            if k in ("bytes", "parse_ms", "render_ms", "present", "parsed",
                     "share_rows_total", "share_rows_ref", "share_cow_retires",
                     "pause_on", "pause_off", "tick_cpu_ms"):
                tot[k] = tot.get(k, 0.0) + float(v)
    tot["ticks"] = ticks
    return tot


def row_env(env_arm: str) -> dict:
    """FT=1 plus the lever arm. `u` means KITTY_PAUSE_SNAPSHOT_SHARE UNSET
    (the shipped-default arm the G2/G4 legs need) -- distinct from `0`."""
    env = {"KITTY_FRAME_TRACE": "1"}
    if env_arm != "u":
        env["KITTY_PAUSE_SNAPSHOT_SHARE"] = env_arm
    return env


def finish_row(row: dict, stderr_path: Path, snap: dict | None, *,
               engaged: bool = False, expect_bytes: bool = True) -> dict:
    """Row epilogue shared by every producer: ftrace totals, the per-MiB
    axes, the rusage snap fields, and the engaged identity / non-engaged
    `share_rows_total == 0` assertion. `expect_bytes=False` for the idle
    cell, where zero ftrace bytes is the expected outcome, not an error."""
    row["load_after"] = os.getloadavg()[0]
    text = stderr_path.read_text(errors="replace")
    tot = ftrace_totals(text)
    row["ftrace"] = tot
    mib = tot.get("bytes", 0.0) / (1024 * 1024)
    row["mib"] = round(mib, 3)
    if mib > 0:
        row["parse_ms_per_mib"] = tot.get("parse_ms", 0.0) / mib
    elif expect_bytes:
        row["error"] = "zero bytes in ftrace"
    if snap is not None:
        row["cycles"] = snap["cycles"]
        row["instructions"] = snap["instructions"]
        row["billed_energy_nj"] = snap["billed_energy_nj"]
        row["wakeups"] = snap["wakeups"]
        if mib > 0 and snap["cycles"] > 0:
            row["cycles_per_mib"] = snap["cycles"] / mib
            row["instructions_per_mib"] = snap["instructions"] / mib
    if engaged:
        ident = tot.get("pause_on", 0.0) * YNUM
        row["identity_expected"] = ident
        row["identity_exact"] = tot.get("share_rows_total", -1.0) == ident
        row["cow_retires_positive"] = tot.get("share_cow_retires", 0.0) > 0
    elif tot.get("share_rows_total", 0.0) != 0.0:
        row["error"] = (row.get("error", "") +
                        " non-engaged row saw share_rows_total != 0").strip()
    return row


def row_prologue(bench: str, env_arm: str, tag: str, seq: int) -> tuple[dict, Path]:
    """Pre-spawn discipline shared by every producer: build lock, wake pulse,
    quiet gate, stderr sink, and the row identity fields."""
    h.wait_for_build_lock_clear()
    RESULTS.mkdir(parents=True, exist_ok=True)
    # Wake pulse: the -dis co-run prevents future display sleep but does not
    # wake an already-dark display, and zero-present rows still appeared at
    # block starts. -u declares user activity, which wakes the display.
    subprocess.run(["caffeinate", "-u", "-t", "2"], check=False)
    load = wait_for_quiet()
    row: dict = {"tag": tag, "seq": seq, "bench": bench, "env_arm": env_arm,
                 "load_before": load, "so_sha": live_so_sha(),
                 "t0": time.time()}
    return row, RESULTS / f"{tag}-s{seq}.stderr.log"


def run_row(bench: str, env_arm: str, tag: str, seq: int, engaged: bool = False) -> dict:
    """One fresh-spawn 60 s vtebench row on the CURRENTLY INSTALLED binary."""
    row, stderr_path = row_prologue(bench, env_arm, tag, seq)
    td = Path(tempfile.mkdtemp(prefix=f"w26b-{tag}-"))
    dat = td / "out.dat"
    snap = None
    with open(stderr_path, "wb") as fh:
        proc = h.spawn_kitty(["/bin/sh", "-c", vtebench_cmd(bench, dat)],
                             take_focus=False, extra_env=row_env(env_arm), stderr=fh)
        deadline = time.monotonic() + SEGMENT_SECS + 60
        while proc.poll() is None and time.monotonic() < deadline:
            try:
                snap = rusage.snap(proc.pid)
            except OSError:
                break
            time.sleep(0.5)
        row["clean_exit"] = proc.poll() is not None
        if not row["clean_exit"]:
            h.terminate_kitty(proc)
    row["t1"] = time.time()
    finish_row(row, stderr_path, snap, engaged=engaged)
    time.sleep(PACING_S)
    return row


def run_idle_row(env_arm: str, tag: str, seq: int) -> dict:
    """Idle cell: a bare 60 s sleep under FT=1 -- no vtebench, no dat file.
    Zero ftrace bytes is the expected outcome here, so the zero-bytes error
    is suppressed; the non-engaged share_rows_total == 0 assertion stays."""
    row, stderr_path = row_prologue("idle", env_arm, tag, seq)
    snap = None
    with open(stderr_path, "wb") as fh:
        proc = h.spawn_kitty(["/bin/sh", "-c", f"sleep {SEGMENT_SECS}"],
                             take_focus=False, extra_env=row_env(env_arm), stderr=fh)
        deadline = time.monotonic() + SEGMENT_SECS + 45
        while proc.poll() is None and time.monotonic() < deadline:
            try:
                snap = rusage.snap(proc.pid)
            except OSError:
                break
            time.sleep(0.5)
        row["clean_exit"] = proc.poll() is not None
        if not row["clean_exit"]:
            h.terminate_kitty(proc)
    row["t1"] = time.time()
    finish_row(row, stderr_path, snap, expect_bytes=False)
    time.sleep(PACING_S)
    return row


def run_typing_row(env_arm: str, tag: str, seq: int) -> dict:
    """Typing cell: paced ~8 chars/s for 60 s into kitty's default shell over
    a remote-control socket (`kitty @ send-text` -- this tree builds no
    separate `kitten` executable). The segment length is ours (terminate at
    the deadline), not the child's, so clean_exit means SIGTERM sufficed."""
    row, stderr_path = row_prologue("typing", env_arm, tag, seq)
    sock = f"/tmp/w26c-typing-{os.getpid()}.sock"
    snap = None
    chars_sent = 0
    send_errors = 0
    with open(stderr_path, "wb") as fh:
        proc = h.spawn_kitty(take_focus=False, extra_env=row_env(env_arm),
                             extra_kitty_opts=["allow_remote_control=yes",
                                               f"listen_on=unix:{sock}"],
                             stderr=fh)
        actual = f"unix:{sock}-{proc.pid}"

        def kat(*a: str, timeout: float = 15) -> subprocess.CompletedProcess:
            return subprocess.run([str(h.KITTY_BINARY), "@", "--to", actual, *a],
                                  capture_output=True, text=True, timeout=timeout)

        try:
            up = False
            for _ in range(50):
                if kat("ls").returncode == 0:
                    up = True
                    break
                time.sleep(0.2)
            if not up:
                row["error"] = f"remote-control socket never came up at {actual}"
            else:
                pool = "abcdefghijklmnopqrstuvwxyz"
                start = time.monotonic()
                while time.monotonic() < start + SEGMENT_SECS:
                    time.sleep(0.25)
                    elapsed = time.monotonic() - start
                    shortfall = int(elapsed * TYPING_RATE_CPS) - chars_sent
                    if shortfall > 0:
                        text = "".join(pool[i % len(pool)] for i in
                                       range(chars_sent, chars_sent + shortfall))
                        if kat("send-text", "--match", "state:focused", text).returncode:
                            send_errors += 1
                        else:
                            chars_sent += shortfall
                    try:
                        snap = rusage.snap(proc.pid)
                    except OSError:
                        break
        finally:
            row["clean_exit"] = h.terminate_kitty(proc)
    row["t1"] = time.time()
    row["chars_sent"] = chars_sent
    row["send_errors"] = send_errors
    row["observed_cps"] = (round(chars_sent / (row["t1"] - row["t0"]), 3)
                           if row["t1"] > row["t0"] else None)
    finish_row(row, stderr_path, snap)
    time.sleep(PACING_S)
    return row


def run_rss_row(env_arm: str, tag: str, seq: int) -> dict:
    """G6 row: the pause shape under a 0.5 s `ps -o rss=` poll of the kitty
    pid; records peak KB. engaged whenever the lever is not explicitly 0, so
    a shared-snapshot binary's identity fields land on the row instead of
    tripping the non-engaged assertion."""
    row, stderr_path = row_prologue("sync_medium_cells", env_arm, tag, seq)
    td = Path(tempfile.mkdtemp(prefix=f"w26-rss-{tag}-"))
    dat = td / "out.dat"
    rss_kb: list[int] = []
    snap = None
    with open(stderr_path, "wb") as fh:
        proc = h.spawn_kitty(["/bin/sh", "-c", vtebench_cmd("sync_medium_cells", dat)],
                             take_focus=False, extra_env=row_env(env_arm), stderr=fh)
        deadline = time.monotonic() + SEGMENT_SECS + 60
        while proc.poll() is None and time.monotonic() < deadline:
            out = subprocess.run(["ps", "-o", "rss=", "-p", str(proc.pid)],
                                 capture_output=True, text=True).stdout.strip()
            if out.isdigit():
                rss_kb.append(int(out))
            try:
                snap = rusage.snap(proc.pid)
            except OSError:
                break
            time.sleep(0.5)
        row["clean_exit"] = proc.poll() is not None
        if not row["clean_exit"]:
            h.terminate_kitty(proc)
    row["t1"] = time.time()
    row["rss_samples"] = len(rss_kb)
    row["peak_rss_kb"] = max(rss_kb) if rss_kb else None
    row["peak_rss_mb"] = h.get_peak_rss_mb(rss_kb)
    finish_row(row, stderr_path, snap, engaged=env_arm != "0")
    time.sleep(PACING_S)
    return row


def bootstrap_ci95_halfwidth(a: list[float], b: list[float]) -> dict:
    """CI95 half-width of med(a)/med(b) under paired-side resampling."""
    rng = random.Random(BOOT_SEED)
    ratios = []
    for _ in range(BOOT_RESAMPLES):
        ra = [a[rng.randrange(len(a))] for _ in a]
        rb = [b[rng.randrange(len(b))] for _ in b]
        mb = statistics.median(rb)
        if mb > 0:
            ratios.append(statistics.median(ra) / mb)
    ratios.sort()
    lo = ratios[int(0.025 * len(ratios))]
    hi = ratios[int(0.975 * len(ratios)) - 1]
    point = statistics.median(a) / statistics.median(b)
    return {"point": point, "ci95_lo": lo, "ci95_hi": hi,
            "half_width": (hi - lo) / 2.0}


def latin_order(arms: list[str], rounds: int) -> list[str]:
    """Cyclic Latin-square rotation: round r starts at offset r % len."""
    order = []
    n = len(arms)
    for r in range(rounds):
        order.extend(arms[(r + i) % n] for i in range(n))
    return order


def series(rows: list[dict], key: str, field: str = "parse_ms_per_mib") -> list[float]:
    return [r[field] for r in rows if r.get("arm_label") == key
            and not r.get("error") and field in r]


def write_rows(tag: str, payload: dict) -> Path:
    dest = RESULTS / f"{tag}.json"
    dest.write_text(json.dumps(payload, indent=1))
    print(f"wrote {dest}", file=sys.stderr)
    return dest


def render_png(tag: str, rows: list[dict]) -> None:
    """Per-row parse_ms_per_mib scatter by arm label (pngcairo)."""
    labels = sorted({r.get("arm_label", "?") for r in rows if not r.get("error")})
    datp = RESULTS / f"{tag}.dat"
    with open(datp, "w") as f:
        for i, lab in enumerate(labels):
            for r in rows:
                if r.get("arm_label") == lab and not r.get("error"):
                    f.write(f"{i} {r['parse_ms_per_mib']}\n")
    plt = RESULTS / f"{tag}.plt"
    png = RESULTS / f"{tag}.png"
    xt = ", ".join(f'"{lab}" {i}' for i, lab in enumerate(labels))
    plt.write_text(
        f'set terminal pngcairo size 1600,1000 font ",18" background rgb "white" linewidth 2\n'
        f'set output "{png}"\nset title "W26b {tag}: parse\\\\_ms per MiB"\n'
        f'set xtics ({xt})\nset xrange [-0.5:{len(labels) - 0.5}]\n'
        f'set ylabel "parse\\\\_ms / MiB"\nunset key\n'
        f'plot "{datp}" using ($1+0.06*rand(0)-0.03):2 with points pt 7 ps 1.6\n')
    subprocess.run(["/opt/homebrew/bin/gnuplot", str(plt)], check=False,
                   capture_output=True)
    print(f"wrote {png}", file=sys.stderr)


def cmd_pilot(args: argparse.Namespace) -> int:
    """A/A pilot: 16 rows, two pseudo-arms A/B alternating. `--xbin` makes
    A = B_base and B = B_pad (FRESH-INODE swap per transition)."""
    tag = "pilot-xbin" if args.xbin else "pilot-same"
    rows = []
    for seq in range(16):
        side = "A" if seq % 2 == 0 else "B"
        if args.xbin:
            sha = install_binary("B_base" if side == "A" else "B_pad")
            print(f"{tag} seq={seq} side={side} so={sha}", file=sys.stderr)
        row = run_row("scrolling", "0", tag, seq)
        row["arm_label"] = side
        rows.append(row)
        print(f"{tag} row {seq}: {row.get('parse_ms_per_mib', row.get('error'))}",
              file=sys.stderr)
    if args.xbin:
        install_binary("B_base")
    a, b = series(rows, "A"), series(rows, "B")
    out: dict = {"tag": tag, "rows": rows, "n_a": len(a), "n_b": len(b)}
    if len(a) == 8 and len(b) == 8:
        out["parse_axis"] = bootstrap_ci95_halfwidth(a, b)
        ac = series(rows, "A", "cycles_per_mib")
        bc = series(rows, "B", "cycles_per_mib")
        if len(ac) == 8 and len(bc) == 8:
            out["cycles_axis"] = bootstrap_ci95_halfwidth(ac, bc)
    else:
        out["error"] = "n-floor breach: a pseudo-arm has < 8 valid rows"
    write_rows(tag, out)
    render_png(tag, rows)
    print(json.dumps({k: out.get(k) for k in ("parse_axis", "cycles_axis", "error")},
                     indent=1))
    return 1 if out.get("error") else 0


def cmd_ab(args: argparse.Namespace) -> int:
    """M1-R1 (and context benches): SHARE=1 vs SHARE=0 on the installed
    binary, alternating, n rounds/arm."""
    tag = f"ab-{args.bench}-{args.tag}"
    rows = []
    for rnd in range(args.rounds):
        for env_arm in ("1", "0") if rnd % 2 else ("0", "1"):
            seq = len(rows)
            row = run_row(args.bench, env_arm, tag, seq)
            row["arm_label"] = f"SHARE={env_arm}"
            rows.append(row)
            print(f"{tag} round {rnd} arm {env_arm}: "
                  f"{row.get('parse_ms_per_mib', row.get('error'))}", file=sys.stderr)
    on, off = series(rows, "SHARE=1"), series(rows, "SHARE=0")
    out: dict = {"tag": tag, "bench": args.bench, "rows": rows,
                 "n_on": len(on), "n_off": len(off)}
    if on and off and len(on) == len(off) == args.rounds:
        out["med_on"] = statistics.median(on)
        out["med_off"] = statistics.median(off)
        out["r_base"] = out["med_on"] / out["med_off"]
        onc = series(rows, "SHARE=1", "cycles_per_mib")
        offc = series(rows, "SHARE=0", "cycles_per_mib")
        if len(onc) == len(offc) == args.rounds:
            out["r_base_cycles"] = statistics.median(onc) / statistics.median(offc)
    else:
        out["error"] = "n-floor breach"
    write_rows(tag, out)
    render_png(tag, rows)
    print(json.dumps({k: out.get(k) for k in ("med_on", "med_off", "r_base",
                                              "r_base_cycles", "error")}, indent=1))
    return 1 if out.get("error") else 0


def cmd_threebin(args: argparse.Namespace) -> int:
    """M1-R2 attribution: {B_base, B_hint, B_flag_probe} on SHARE=1."""
    arms = ["B_base", "B_hint", "B_flag_probe"]
    tag = "threebin"
    rows = []
    for seq, name in enumerate(latin_order(arms, args.rounds)):
        sha = install_binary(name)
        row = run_row("scrolling", "1", tag, seq)
        row["arm_label"] = name
        row["installed_sha"] = sha
        rows.append(row)
        print(f"{tag} seq={seq} {name}: "
              f"{row.get('parse_ms_per_mib', row.get('error'))}", file=sys.stderr)
    install_binary("B_base")
    out: dict = {"tag": tag, "rows": rows}
    med = {name: statistics.median(series(rows, name)) for name in arms
           if len(series(rows, name)) == args.rounds}
    out["medians"] = med
    if len(med) == 3:
        out["r_hint_rel"] = med["B_hint"] / med["B_base"]
        out["r_flagprobe_rel"] = med["B_flag_probe"] / med["B_base"]
    else:
        out["error"] = "n-floor breach"
    write_rows(tag, out)
    render_png(tag, rows)
    print(json.dumps({k: out.get(k) for k in ("medians", "r_hint_rel",
                                              "r_flagprobe_rel", "error")}, indent=1))
    return 1 if out.get("error") else 0


def cmd_fourarm(args: argparse.Namespace) -> int:
    """M2: {B_base,B_flag} x {SHARE=0,1}, Latin square, n rounds/arm.
    --share0-only restricts to the two SHARE=0 arms: on an engaging bench
    (sync_medium_cells) the SHARE=1 arms would be engaged-class rows that
    feed no gate -- T3 is the only context-bench consumer."""
    arms = (["base0", "flag0"] if args.share0_only
            else ["base0", "base1", "flag0", "flag1"])
    binmap = {"base": "B_base", "flag": "B_flag"}
    tag = f"fourarm-{args.bench}" + ("-share0" if args.share0_only else "")
    rows = []
    for seq, arm in enumerate(latin_order(arms, args.rounds)):
        binary, env_arm = arm[:-1], arm[-1]
        sha = install_binary(binmap[binary])
        row = run_row(args.bench, env_arm, tag, seq)
        row["arm_label"] = arm
        row["installed_sha"] = sha
        rows.append(row)
        print(f"{tag} seq={seq} {arm}: "
              f"{row.get('parse_ms_per_mib', row.get('error'))}", file=sys.stderr)
    install_binary("B_base")
    out: dict = {"tag": tag, "bench": args.bench, "rows": rows}
    med = {a: statistics.median(series(rows, a)) for a in arms
           if len(series(rows, a)) == args.rounds}
    out["medians"] = med
    if args.share0_only:
        if len(med) == 2:
            out["t3_context"] = med["flag0"] / med["base0"]
        else:
            out["error"] = "n-floor breach"
    elif len(med) == 4:
        out["r_fix"] = med["flag1"] / med["base0"]
        out["t1_obs"] = med["flag1"] / med["flag0"]
        out["r_base_inblock"] = med["base1"] / med["base0"]
        out["t3_scrolling"] = med["flag0"] / med["base0"]
        denom = out["r_base_inblock"] - 1.0
        if abs(denom) > 1e-12:
            out["t2_elimination_fraction"] = (out["r_base_inblock"] - out["r_fix"]) / denom
        cyc = {a: statistics.median(series(rows, a, "cycles_per_mib")) for a in arms
               if len(series(rows, a, "cycles_per_mib")) == args.rounds}
        if len(cyc) == 4:
            out["t5_cycles_ratio"] = cyc["flag1"] / cyc["base0"]
            ins = {a: statistics.median(series(rows, a, "instructions_per_mib"))
                   for a in arms}
            out["instructions_ratio"] = ins["flag1"] / ins["base0"]
    else:
        out["error"] = "n-floor breach"
    write_rows(tag, out)
    render_png(tag, rows)
    print(json.dumps({k: out.get(k) for k in
                      ("medians", "r_fix", "t1_obs", "r_base_inblock",
                       "t3_scrolling", "t3_context", "t2_elimination_fraction",
                       "t5_cycles_ratio", "instructions_ratio", "error")}, indent=1))
    return 1 if out.get("error") else 0


def cmd_engaged(args: argparse.Namespace) -> int:
    """T4: engaged cell (sync_medium_cells) per binary, alternating.
    `--binary NAME` collapses to that single binary (no with-flag pairing) so
    the G4 legs can run one arm at a time -- e.g. B_flip with the lever UNSET
    (`--env u`), which is the shipped-default engaged identity check."""
    wa = WAVE_ARMS[WAVE]
    arms = ([args.binary] if args.binary
            else (wa["engaged"] if args.with_flag else wa["engaged"][:1]))
    tag = "engaged"
    rows = []
    for rnd in range(args.rounds):
        order = arms if rnd % 2 == 0 else list(reversed(arms))
        for name in order:
            sha = install_binary(name)
            seq = len(rows)
            row = run_row("sync_medium_cells", args.env, tag, seq, engaged=True)
            row["arm_label"] = name
            row["installed_sha"] = sha
            rows.append(row)
            print(f"{tag} round {rnd} {name}: parse/mib="
                  f"{row.get('parse_ms_per_mib')} identity={row.get('identity_exact')} "
                  f"cow+={row.get('cow_retires_positive')}", file=sys.stderr)
    install_binary(wa["default_bin"])
    valid = [r for r in rows if not r.get("error") and r.get("identity_exact")
             and r.get("cow_retires_positive")]
    out: dict = {"tag": tag, "env_arm": args.env, "rows": rows, "n_valid": len(valid)}
    for name in arms:
        vals = [r["parse_ms_per_mib"] for r in valid if r["arm_label"] == name]
        out[f"med_{name}"] = statistics.median(vals) if vals else None
        out[f"n_{name}"] = len(vals)
    if len(arms) == 2 and out.get(f"med_{arms[0]}") and out.get(f"med_{arms[1]}"):
        out["t4_ratio"] = out[f"med_{arms[1]}"] / out[f"med_{arms[0]}"]
    write_rows(tag, out)
    render_png(tag, rows)
    print(json.dumps({k: out.get(k) for k in
                      [f"med_{n}" for n in arms] + ["t4_ratio", "n_valid"]}, indent=1))
    return 0


# ===========================================================================
# Energy: powermetrics parse / capture guards (ported from w26_energy.py)
# ===========================================================================

# Verbatim from w26_energy.py:114-119 (itself verbatim from wave19's
# p2b_energy.py:117-121) -- the estimator must not drift between waves.
SAMPLE_RE = re.compile(r"\*\*\* Sampled system activity \((.+?)\) \(([\d.]+)ms elapsed\)")
POWER_RES = {
    "cpu_mw": re.compile(r"^CPU Power:\s+([\d.]+)\s*mW", re.M),
    "gpu_mw": re.compile(r"^GPU Power:\s+([\d.]+)\s*mW", re.M),
    "combined_mw": re.compile(r"^Combined Power \(CPU \+ GPU \+ ANE\):\s+([\d.]+)\s*mW", re.M),
}
TASKS_HDR_RE = re.compile(r"^\s*Name\s{2,}.*Energy Impact.*$", re.M)
KITTY_TASK_RE = re.compile(r"^kitty\s+[\d.]", re.M)


def kitty_energy_impact(body: str) -> float | None:
    """Best-effort `kitty` Energy Impact from a block's tasks-sampler table.
    The retained W26b capture carries no tasks section at all, so every
    failure mode here returns None rather than raising."""
    hdr = TASKS_HDR_RE.search(body)
    task = KITTY_TASK_RE.search(body)
    if not (hdr and task):
        return None
    labels = re.split(r"\s{2,}", hdr.group(0).strip())
    idx = next((i for i, lab in enumerate(labels)
                if lab.startswith("Energy Impact")), None)
    if idx is None:
        return None
    line = body[task.start():].split("\n", 1)[0]
    for fields in (line.split(), re.split(r"\s{2,}", line.strip())):
        if len(fields) == len(labels):
            try:
                return float(fields[idx])
            except ValueError:
                return None
    return None


def parse_powermetrics(path: Path) -> list[dict]:
    """One record per sample block: epoch + power readings (+ the tasks
    sampler's kitty Energy Impact where the capture has one). The header
    timestamp carries a tz token powermetrics formats like
    `Tue Jul  8 13:05:00 2026 +0900`; strptime the datetime part and ignore
    the offset -- ledger and capture share the machine's clock."""
    if not path.exists():
        return []
    text = path.read_text(errors="replace")
    records = []
    blocks = SAMPLE_RE.split(text)
    for i in range(1, len(blocks) - 2, 3):
        ts_raw, elapsed, body = blocks[i], blocks[i + 1], blocks[i + 2]
        ts_clean = re.sub(r"\s+[+-]\d{4}$", "", ts_raw.strip())
        try:
            epoch = time.mktime(time.strptime(ts_clean, "%a %b %d %H:%M:%S %Y"))
        except ValueError:
            continue
        rec = {"epoch": epoch, "elapsed_ms": float(elapsed)}
        for key, rx in POWER_RES.items():
            m = rx.search(body)
            if m:
                rec[key] = float(m.group(1))
        ei = kitty_energy_impact(body)
        if ei is not None:
            rec["kitty_energy_impact"] = ei
        records.append(rec)
    return records


def wait_capture_alive(pm_path: Path, timeout_s: float = LIVELINESS_TIMEOUT_S,
                       poll_s: float = 1.0) -> tuple[bool, dict]:
    """Poll pm_path's size for up to timeout_s; growth => alive. A silently
    dead capture must not burn the battery undetected -- this is the
    checkpoint before the first binding rep and between cells."""
    if not pm_path.exists():
        return False, {"reason": "powermetrics file does not exist",
                       "path": str(pm_path)}
    size0 = pm_path.stat().st_size
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        time.sleep(poll_s)
        size1 = pm_path.stat().st_size
        if size1 > size0:
            return True, {"size_before": size0, "size_after": size1}
    return False, {"size_before": size0, "size_after": pm_path.stat().st_size,
                   "timeout_s": timeout_s}


def wait_flush_settle(pm_path: Path, t1: float,
                      timeout_s: float = FLUSH_SETTLE_TIMEOUT_S,
                      poll_s: float = 1.0) -> dict:
    """Block until pm_path holds a sample past t1 (the capture has flushed
    data covering the last row) or timeout_s has elapsed past t1, whichever
    comes first. Never raises; a no-op on a closed session file."""
    deadline_wall = t1 + timeout_s
    while True:
        samples = parse_powermetrics(pm_path)
        max_epoch = max((s["epoch"] for s in samples), default=None)
        grown = max_epoch is not None and max_epoch > t1
        now = time.time()
        if grown or now >= deadline_wall:
            return {"grown_past_t1": grown, "max_epoch": max_epoch, "t1": t1,
                    "elapsed_past_t1_s": round(now - t1, 2)}
        time.sleep(poll_s)


# ===========================================================================
# Energy: the trim-join analyzer
# ===========================================================================

def join_rep(row: dict, samples: list[dict]) -> dict:
    """THE reproduced W26b join rule: every capture sample whose epoch lies
    in the CLOSED interval [t0 + 2 s, t1 - 2 s] and carries a Combined Power
    reading; mean rounded to 3 dp; >= 50 samples for validity. Verified to
    reproduce `.omc/verify/wave26b/results/e1-analysis.json` exactly on all
    26 retained reps (`energy-analyze --selfcheck-retained`); no other
    variant is kept in this file."""
    lo, hi = row["t0"] + EDGE_TRIM_S, row["t1"] - EDGE_TRIM_S
    win = [s for s in samples if lo <= s["epoch"] <= hi]
    vals = [s["combined_mw"] for s in win if "combined_mw" in s]
    rep = {"seq": row["seq"], "arm": row["arm_label"]}
    if "cell" in row:
        rep["cell"] = row["cell"]
    rep["binding"] = bool(row.get("binding", True))
    rep["present"] = int(row.get("ftrace", {}).get("present", 0))
    rep["n_samples"] = len(vals)
    rep["valid_samples"] = len(vals) >= MIN_TRIMMED_SAMPLES
    rep["mean_mw"] = round(statistics.fmean(vals), 3) if vals else None
    ei = [s["kitty_energy_impact"] for s in win if "kitty_energy_impact" in s]
    if ei:
        rep["mean_kitty_energy_impact"] = round(statistics.fmean(ei), 3)
    return rep


def infer_arm_map(arms: set[str]) -> dict | None:
    """Role -> flood arm label. Keyed off the FLOOD arm labels only: cell
    rows reuse the wave's flip labels, so a mixed ledger would otherwise
    present several spellings at once. Cells are looked up by (cell, arm)."""
    if {"basep0", "basep1", "flip0", "flip1"} <= arms:
        return {"wave": "w26c", "b0": "basep0", "b1": "basep1",
                "f0": "flip0", "f1": "flip1"}
    if {"base0", "base1", "flag0", "flag1"} <= arms:
        return {"wave": "w26b", "b0": "base0", "b1": "base1",
                "f0": "flag0", "f1": "flag1"}
    return None


def rel_mad(means: list[float], med: float | None) -> float | None:
    """Robust within-arm relative dispersion: MAD * 1.4826 / median."""
    if not means or not med:
        return None
    return statistics.median([abs(m - med) for m in means]) * 1.4826 / med


def _ratio(num: float | None, den: float | None) -> float | None:
    return round(num / den, 4) if (num is not None and den) else None


def analyze_ledger(ledger: dict, samples: list[dict]) -> dict:
    """Join every ledger row to the capture, then aggregate: per-arm medians
    over BINDING VALID reps (this is what selects base0 4-of-6 in the
    retained W26b ledger, whose four zero-present rows are binding:false),
    the wave's ratio set, the pooled within-arm dispersion, the med3
    variants, the per-cell ON/OFF ratios, and the two regime splits
    (published beside the headline estimator, never substituted for it)."""
    rows = ledger.get("rows", [])
    reps = [join_rep(r, samples) for r in rows]
    flood_reps = [r for r in reps if r.get("cell", "flood") == "flood"]
    am = infer_arm_map({r["arm"] for r in flood_reps})

    def binding_means(arm: str, pool: list[dict] | None = None) -> list[float]:
        return [r["mean_mw"] for r in (pool if pool is not None else flood_reps)
                if r["arm"] == arm and r["binding"] and r["valid_samples"]
                and r["mean_mw"] is not None]

    arms = [am[k] for k in ("b0", "b1", "f0", "f1")] if am else []
    medians: dict[str, dict] = {}
    for arm in arms:
        means = binding_means(arm)
        if means:
            medians[arm] = {"n": len(means),
                            "median": round(statistics.median(means), 3),
                            "means": means}

    def med(arm: str) -> float | None:
        return medians.get(arm, {}).get("median")

    out: dict = {"kind": "e1_analysis", "reps": reps, "medians": medians}
    if am and am["wave"] == "w26b":
        out["r_E_base_n4"] = _ratio(med(am["b1"]), med(am["b0"]))
        out["r_post_n4"] = _ratio(med(am["f1"]), med(am["b0"]))
        out["r_E_flag"] = _ratio(med(am["f1"]), med(am["f0"]))
    elif am:
        r_e_base = _ratio(med(am["b1"]), med(am["b0"]))
        r_post = _ratio(med(am["f1"]), med(am["b0"]))
        out["r_E_base"] = r_e_base
        out["r_post"] = r_post
        out["flood_row_med6"] = _ratio(med(am["f1"]), med(am["f0"]))
        if (r_e_base is not None and r_post is not None
                and abs(r_e_base - 1.0) > 1e-12):
            out["c_prime"] = round((r_e_base - r_post) / (r_e_base - 1.0), 4)

    pooled = None
    if medians:
        rms = [rel_mad(m["means"], m["median"]) for m in medians.values()]
        rms = [x for x in rms if x is not None]
        if rms:
            pooled = round(statistics.median(rms), 4)
    out["pooled_within_arm_rel_mad"] = pooled

    if am and am["wave"] == "w26c":
        med3 = {arm: round(statistics.median(binding_means(arm)[:3]), 3)
                for arm in arms if len(binding_means(arm)) >= 3}
        out["medians_med3"] = med3
        out["r_E_base_med3"] = _ratio(med3.get(am["b1"]), med3.get(am["b0"]))
        out["r_post_med3"] = _ratio(med3.get(am["f1"]), med3.get(am["b0"]))
        out["flood_row_med3"] = _ratio(med3.get(am["f1"]), med3.get(am["f0"]))
        out.update(a_gates(out.get("r_E_base"), out.get("r_post"),
                           out.get("c_prime"), pooled))

    # A flip-only flood block (--flood-arms flip) has no four-arm map, so its
    # ON/OFF ratio is only reachable through the two-arm cell collapse; when
    # the four-arm map IS present that collapse would be misleading and the
    # four-arm ratios above are the flood answer.
    cells = cell_summaries(reps, rows, with_flood=am is None)
    if cells:
        out["cells"] = cells
    out["regime"] = {"paired": paired_regime(flood_reps, am),
                     "present_pos": present_pos_regime(flood_reps, am)}
    out["constants"] = {"edge_trim_s": EDGE_TRIM_S,
                        "min_samples": MIN_TRIMMED_SAMPLES, "bar": ENERGY_GATE}
    return out


def a_gates(r_e_base: float | None, r_post: float | None,
            c_prime: float | None, pooled: float | None) -> dict:
    """W26c A-gate adjudication. A1 valid iff the substitute control really
    reproduced the effect (>= the bar); A2 unresolved iff the arms are
    separated by less than the pooled within-arm dispersion; A3 pass iff the
    post-fix ratio is at or under the bar. Label priority: invalid A1 first,
    then UNRESOLVED, then the r_post-based verdicts."""
    if r_e_base is None or r_post is None:
        return {"substitution_label": "INCOMPLETE"}
    a1 = r_e_base >= ENERGY_GATE
    a3 = r_post <= ENERGY_GATE
    a2 = pooled is not None and (r_e_base - r_post) < pooled
    if not a1:
        label = "A1-INVALID"
    elif a2:
        label = "UNRESOLVED"
    elif a3:
        label = "ROOT-CAUSE-CONFIRMED"
    elif c_prime is not None and c_prime >= 0.5:
        label = "PARTIAL"
    else:
        label = "NOT-CLOSED"
    return {"a1_valid": a1, "a2_unresolved": a2, "a3_pass": a3,
            "substitution_label": label}


def cell_summaries(reps: list[dict], rows: list[dict],
                   with_flood: bool = False) -> dict:
    """Per cell: ON/OFF ratio over that cell's binding valid reps (arms are
    the wave's flip labels, so the lever digit is arm[-1]; rows are matched on
    (cell, arm) so a mixed ledger's flood arms never leak in). The pause cell
    also echoes the E2 identity counts straight off the ledger."""
    out: dict = {}
    by_seq = {r["seq"]: r for r in rows}
    for cell in (("flood",) if with_flood else ()) + ("idle", "typing", "pause"):
        crs = [r for r in reps if r.get("cell") == cell and r["binding"]
               and r["valid_samples"] and r["mean_mw"] is not None]
        if not crs:
            continue
        off = [r["mean_mw"] for r in crs if r["arm"].endswith("0")]
        on = [r["mean_mw"] for r in crs if r["arm"].endswith("1")]
        entry = {
            "n_off": len(off), "n_on": len(on),
            "median_off_mw": round(statistics.median(off), 3) if off else None,
            "median_on_mw": round(statistics.median(on), 3) if on else None,
            "means_off": off, "means_on": on,
        }
        entry["ratio_on_over_off"] = _ratio(entry["median_on_mw"],
                                            entry["median_off_mw"])
        entry["gate_pass_informational"] = (
            entry["ratio_on_over_off"] <= ENERGY_GATE
            if entry["ratio_on_over_off"] is not None else None)
        if cell == "pause":
            led = [by_seq[r["seq"]] for r in crs if r["seq"] in by_seq]
            entry["identity_exact_count"] = sum(
                1 for r in led if r.get("identity_exact") is True)
            entry["cow_retires_positive_count"] = sum(
                1 for r in led if r.get("cow_retires_positive") is True)
            entry["n_engaged_rows"] = sum(1 for r in led if "identity_exact" in r)
        out[cell] = entry
    return out


def paired_regime(flood_reps: list[dict], am: dict | None) -> dict:
    """Per-Latin-round r_post: flood rows grouped 4-at-a-time in ledger
    order, a round counted only when its four members are exactly the four
    arms and all are binding+valid. Rounds that a re-run row displaced are
    skipped rather than mis-paired."""
    if not am:
        return {"median": None, "reason": "no flood arm map"}
    groups, skipped = [], 0
    ordered = list(flood_reps)
    for i in range(0, len(ordered) - 3, 4):
        g = ordered[i:i + 4]
        labels = {r["arm"] for r in g}
        if labels != {am[k] for k in ("b0", "b1", "f0", "f1")} or \
                not all(r["binding"] and r["valid_samples"] for r in g):
            skipped += 1
            continue
        by = {r["arm"]: r["mean_mw"] for r in g}
        if by[am["b0"]]:
            groups.append(round(by[am["f1"]] / by[am["b0"]], 4))
    return {"median": round(statistics.median(groups), 4) if groups else None,
            "rounds": groups, "n_rounds": len(groups), "n_skipped": skipped}


def present_pos_regime(flood_reps: list[dict], am: dict | None) -> dict:
    """Arm medians recomputed over binding valid reps with present > 0 only
    (the rendering regime), and the two ratios derived from them."""
    if not am:
        return {"medians": {}, "reason": "no flood arm map"}
    med = {}
    for arm in (am[k] for k in ("b0", "b1", "f0", "f1")):
        means = [r["mean_mw"] for r in flood_reps if r["arm"] == arm
                 and r["binding"] and r["valid_samples"] and r["present"] > 0
                 and r["mean_mw"] is not None]
        if means:
            med[arm] = {"n": len(means),
                        "median": round(statistics.median(means), 3)}
    g = {k: med.get(am[k], {}).get("median") for k in ("b0", "b1", "f0", "f1")}
    return {"medians": med, "r_E_base": _ratio(g["b1"], g["b0"]),
            "r_post": _ratio(g["f1"], g["b0"]),
            "flood_row": _ratio(g["f1"], g["f0"])}


def render_cell_ratio_png(stem: Path, cells: dict) -> None:
    """Per-cell ON/OFF ratio bars (the w26_energy.py summary PNG shape, over
    this file's write-a-.plt pngcairo pattern)."""
    if not cells:
        return
    png = stem.with_name(f"{stem.stem}-cells.png")
    datp = stem.with_name(f"{stem.stem}-cells.dat")
    datp.write_text("".join(f'{i} "{c}" {e["ratio_on_over_off"] or 0}\n'
                            for i, (c, e) in enumerate(cells.items())))
    plt = stem.with_name(f"{stem.stem}-cells.plt")
    plt.write_text(
        f'set terminal {TERMINAL}\nset output "{png}"\n'
        f'set title "{WAVE} energy ratio ON/OFF per cell '
        f'(Combined Power, median of rep means)"\n'
        f'set style data histograms\nset style fill solid 0.8 border -1\n'
        f'set boxwidth 0.6\nunset key\nset ylabel "ratio\\\\_on\\\\_over\\\\_off"\n'
        f'set xlabel "cell"\nset yrange [0:*]\n'
        f'plot "{datp}" using 3:xtic(2) lc rgb "#4477aa"\n')
    _gnuplot(plt, png)


def render_flood_trace_png(stem: Path, rows: list[dict], samples: list[dict]) -> None:
    """Raw combined_mw vs seconds-since-t0, one series per flood row (no edge
    trim, no averaging) -- the trace companion to the ratio bars."""
    flood = [r for r in rows if r.get("cell", "flood") == "flood"]
    blocks, plots = [], []
    for i, r in enumerate(flood):
        pts = sorted((round(s["epoch"] - r["t0"], 2), s["combined_mw"])
                     for s in samples
                     if r["t0"] <= s["epoch"] <= r["t1"] and "combined_mw" in s)
        if not pts:
            continue
        blocks.append(f"$S{i} << EOD\n" + "\n".join(f"{x} {y}" for x, y in pts) + "\nEOD")
        plots.append(f'$S{i} using 1:2 title "{r.get("arm_label", "?")}/s{r["seq"]}" '
                     f'lw 2 pt {5 + i % 8}')
    if not plots:
        return
    png = stem.with_name(f"{stem.stem}-flood-trace.png")
    plt = stem.with_name(f"{stem.stem}-flood-trace.plt")
    plt.write_text(
        f'set terminal {TERMINAL}\nset output "{png}"\n'
        f'set title "{WAVE} flood cell -- raw Combined Power per row"\n'
        + "\n".join(blocks) + "\n"
        f'set style data linespoints\nset xlabel "seconds since row t0"\n'
        f'set ylabel "combined\\\\_mw"\nset key outside right\n'
        f'plot {", ".join(plots)}\n')
    _gnuplot(plt, png)


def _gnuplot(plt: Path, png: Path) -> None:
    """PNG rendering is a deliverable, never a gate: warn and carry on."""
    try:
        r = subprocess.run([GNUPLOT, str(plt)], capture_output=True, text=True)
        if r.returncode or not png.exists() or not png.stat().st_size:
            raise RuntimeError(r.stderr.strip() or "gnuplot produced no output")
        print(f"wrote {png}", file=sys.stderr)
    except Exception as exc:
        print(f"WARNING: PNG render failed for {png.name}: {exc}", file=sys.stderr)


# ===========================================================================
# Energy: self-checks (the analyzer's own gate -- exit 1 on ANY mismatch)
# ===========================================================================

def _diff(diffs: list[str], label: str, got, want) -> None:
    if got != want:
        diffs.append(f"{label}: got {got!r} want {want!r}")


def _selfcheck_verdict(name: str, diffs: list[str], checked: int) -> int:
    if diffs:
        print(f"{name}: FAIL ({len(diffs)} mismatch(es) over {checked} checks)")
        for d in diffs:
            print(f"  {d}")
        return 1
    print(f"{name}: PASS ({checked} field comparisons, all exact)")
    return 0


def selfcheck_synthetic() -> int:
    """Hand-computable end-to-end check: a synthetic 4-arm ledger (2 binding
    reps/arm, 60 s rows spaced 70 s) plus a 1 Hz capture holding a KNOWN
    constant mW inside each row window. Every rep's n_samples/mean_mw and
    every ratio must equal the expectation computed straight from those
    constants -- an independent path from the analyzer's join."""
    arms = ["base0", "base1", "flag0", "flag1"]
    base = int(time.time()) - 7200
    rows, mw_of = [], {}
    for seq, arm in enumerate(latin_order(arms, 2)):
        t0 = base + seq * 70
        # Non-linear in seq: a linear ramp makes med(base0) == med(flag0)
        # under this Latin rotation and the three ratios stop discriminating.
        mw_of[seq] = 100.0 + 10.0 * seq + 7.0 * (seq % 3)
        rows.append({"tag": "synthetic", "seq": seq, "bench": "scrolling",
                     "env_arm": arm[-1], "t0": float(t0), "t1": float(t0 + 60),
                     "ftrace": {"present": 100.0}, "arm_label": arm,
                     "cell": "flood", "binding": True})
    last = int(rows[-1]["t1"])
    lines = ["Machine model: Synthetic", ""]
    for sec in range(base - 5, last + 6):
        mw = next((mw_of[r["seq"]] for r in rows if r["t0"] <= sec <= r["t1"]), 42.0)
        ts = time.strftime("%a %b %d %H:%M:%S %Y %z", time.localtime(sec))
        if time.mktime(time.strptime(re.sub(r"\s+[+-]\d{4}$", "", ts),
                                     "%a %b %d %H:%M:%S %Y")) != sec:
            print(f"synthetic: local time {ts} does not round-trip to {sec}")
            return 1
        lines += [f"*** Sampled system activity ({ts}) (1000.00ms elapsed) ***", "",
                  f"Combined Power (CPU + GPU + ANE): {mw} mW", ""]
    with tempfile.TemporaryDirectory(prefix="w26-selfcheck-") as td:
        cap = Path(td) / "powermetrics-synth.txt"
        cap.write_text("\n".join(lines))
        got = analyze_ledger({"tag": "synthetic", "rows": rows},
                             parse_powermetrics(cap))
    diffs: list[str] = []
    checked = 0
    # [t0+2, t1-2] closed over 1 Hz integer-second samples => 57 per rep.
    for rep in got["reps"]:
        _diff(diffs, f"rep[{rep['seq']}].n_samples", rep["n_samples"], 57)
        _diff(diffs, f"rep[{rep['seq']}].mean_mw", rep["mean_mw"], mw_of[rep["seq"]])
        _diff(diffs, f"rep[{rep['seq']}].valid_samples", rep["valid_samples"], True)
        checked += 3
    _diff(diffs, "len(reps)", len(got["reps"]), 8)
    _diff(diffs, "len(medians)", len(got["medians"]), 4)
    checked += 2
    want_med = {arm: statistics.median([mw_of[r["seq"]] for r in rows
                                        if r["arm_label"] == arm]) for arm in arms}
    for arm in arms:
        _diff(diffs, f"medians.{arm}.median", got["medians"][arm]["median"],
              round(want_med[arm], 3))
        _diff(diffs, f"medians.{arm}.n", got["medians"][arm]["n"], 2)
        checked += 2
    for key, num, den in (("r_E_base_n4", "base1", "base0"),
                          ("r_post_n4", "flag1", "base0"),
                          ("r_E_flag", "flag1", "flag0")):
        _diff(diffs, key, got[key], round(want_med[num] / want_med[den], 4))
        checked += 1
    want_rms = [rel_mad([mw_of[r["seq"]] for r in rows if r["arm_label"] == arm],
                        round(want_med[arm], 3)) for arm in arms]
    want_pooled = round(statistics.median([x for x in want_rms if x is not None]), 4)
    _diff(diffs, "pooled_within_arm_rel_mad",
          got["pooled_within_arm_rel_mad"], want_pooled)
    checked += 1
    return _selfcheck_verdict("selfcheck-synthetic", diffs, checked)


def selfcheck_retained() -> int:
    """Reproduce `.omc/verify/wave26b/results/e1-analysis.json` EXACTLY from
    the retained W26b ledger + capture. Read-only: writes nothing, renders
    nothing. Every key present in the retained artifact must match; keys the
    retained file does not carry (e.g. per-rep `cell`) are the only tolerated
    difference, and the retained ledger has no `cell` fields so none appear."""
    base = h.REPO_ROOT / ".omc" / "verify" / "wave26b" / "results"
    ledger = json.loads((base / "energy-ledger.json").read_text())
    want = json.loads((base / "e1-analysis.json").read_text())
    samples = parse_powermetrics(base / "powermetrics-w26b.txt")
    if not samples:
        print(f"selfcheck-retained: no samples parsed from {base}/powermetrics-w26b.txt")
        return 1
    got = analyze_ledger(ledger, samples)
    diffs: list[str] = []
    checked = 0
    # Non-vacuity: the retained artifact is 26 reps over 4 arms; a comparator
    # that silently visited fewer would "pass" for the wrong reason.
    _diff(diffs, "retained n_reps", len(want["reps"]), 26)
    _diff(diffs, "retained n_arms", len(want["medians"]), 4)
    _diff(diffs, "len(reps)", len(got["reps"]), len(want["reps"]))
    checked += 3
    for g, w in zip(got["reps"], want["reps"]):
        for k in w:
            _diff(diffs, f"rep[{w['seq']}/{w['arm']}].{k}", g.get(k), w[k])
            checked += 1
        _diff(diffs, f"rep[{w['seq']}].cell absent", "cell" in g, False)
        checked += 1
    _diff(diffs, "medians arms", sorted(got["medians"]), sorted(want["medians"]))
    checked += 1
    for arm, wm in want["medians"].items():
        for k in wm:
            _diff(diffs, f"medians.{arm}.{k}", got["medians"].get(arm, {}).get(k), wm[k])
            checked += 1
    for k in ("r_E_base_n4", "r_post_n4", "r_E_flag", "pooled_within_arm_rel_mad"):
        _diff(diffs, k, got.get(k), want[k])
        checked += 1
    # Frozen values, so a silently-rewritten retained artifact is caught too.
    for k, v in (("r_E_base_n4", 0.6131), ("r_post_n4", 0.6242),
                 ("r_E_flag", 1.0175), ("pooled_within_arm_rel_mad", 0.3508)):
        _diff(diffs, f"frozen {k}", got.get(k), v)
        checked += 1
    return _selfcheck_verdict("selfcheck-retained", diffs, checked)


def cmd_energy_analyze(args: argparse.Namespace) -> int:
    """Join an energy ledger against a powermetrics capture and emit the
    wave's ratio set. `--selfcheck-*` run the analyzer's own gates instead
    (read-only, no artifacts written)."""
    if args.selfcheck_synthetic:
        return selfcheck_synthetic()
    if args.selfcheck_retained:
        return selfcheck_retained()
    if not args.ledger or not args.capture:
        print("energy-analyze needs --ledger and --capture (or a --selfcheck-* mode)",
              file=sys.stderr)
        return 2
    ledger_path, pm_path = Path(args.ledger), Path(args.capture)
    ledger = json.loads(ledger_path.read_text())
    rows = ledger.get("rows", [])
    if not rows:
        print(f"ERROR: no rows in {ledger_path}", file=sys.stderr)
        return 2
    settle = None
    if args.flush_settle:
        settle = wait_flush_settle(pm_path, max(r["t1"] for r in rows))
        print(f"flush-settle: {settle}", file=sys.stderr)
    samples = parse_powermetrics(pm_path)
    if not samples:
        print(f"ERROR: no powermetrics samples parsed from {pm_path}", file=sys.stderr)
        return 1
    out = analyze_ledger(ledger, samples)
    if args.flush_settle and any(not r["binding"] and not r["valid_samples"]
                                 for r in out["reps"]):
        # ONE retry, non-binding (pilot) rows only -- binding rows are
        # governed by the driver's re-run-once rule, not by the analyzer.
        print(f"flush-settle: under-floor pilot rep(s); waiting "
              f"{FLUSH_SETTLE_TIMEOUT_S}s and re-analyzing ONCE", file=sys.stderr)
        time.sleep(FLUSH_SETTLE_TIMEOUT_S)
        out = analyze_ledger(ledger, parse_powermetrics(pm_path))
        out["reanalyzed_once"] = True
    out["ledger"] = str(ledger_path)
    out["capture"] = str(pm_path)
    if settle is not None:
        out["flush_settle"] = settle
    dest = Path(args.out) if args.out else ledger_path.with_name(
        f"{ledger_path.stem}-analysis.json")
    dest.write_text(json.dumps(out, indent=1))
    print(f"wrote {dest}", file=sys.stderr)
    render_cell_ratio_png(dest, out.get("cells", {}))
    render_flood_trace_png(dest, rows, samples)
    print(json.dumps({k: v for k, v in out.items()
                      if k not in ("reps", "ledger", "capture")}, indent=1))
    return 0


# ===========================================================================
# Energy: the drive
# ===========================================================================

def arm_order_for_rep(rep: int) -> tuple[str, str]:
    """Within-cell lever alternation: rep1 OFF,ON / rep2 ON,OFF / rep3 OFF,ON
    (the confirm shape; restarts at each cell)."""
    return ("0", "1") if rep % 2 == 1 else ("1", "0")


def cmd_energy(args: argparse.Namespace) -> int:
    """Energy drive against an operator-started powermetrics capture. Default
    (`--wave w26b`, no new flags) is the M3 4-arm flood block unchanged.
    Frozen validity: a binding rep with present == 0 is INVALID and re-run
    once (idle rows are exempt unless --idle-present-literal; pilot and ctx
    rows are non-binding and never invalidated). The ledger is REWRITTEN
    after every row, so an abort still leaves a usable file."""
    wa = WAVE_ARMS[WAVE]
    flip_bin = wa["binmap"][wa["flip"]]
    flip_arm = wa["flip"]
    cells = [c.strip() for c in args.cells.split(",") if c.strip()]
    bad = [c for c in cells if c not in ENERGY_CELLS]
    if bad:
        print(f"ERROR: unknown cell(s) {bad}; valid: {ENERGY_CELLS}", file=sys.stderr)
        return 2
    tag = "energy"
    pm_path = Path(args.capture) if args.capture else None
    name = f"energy-ledger-{args.tag}" if args.tag else "energy-ledger"
    rows: list[dict] = []
    out = {"tag": tag, "wave": WAVE, "rounds": args.rounds, "reps": args.reps,
           "cells": cells, "flood_arms": args.flood_arms,
           "capture": str(pm_path) if pm_path else None,
           "aborts": [], "rows": rows}
    seq = 0
    first_binding = False

    def flush() -> None:
        write_rows(name, out)

    def abort(reason: str, evidence: dict) -> None:
        cls = "S2" if first_binding else "E2"
        out["aborts"].append({"kind": "abort", "reason": reason,
                              "classification": cls, **evidence})
        print(f"ABORT ({cls}): {reason} :: {evidence}", file=sys.stderr)
        flush()

    def guard(when: str) -> bool:
        if pm_path is None:
            return True
        alive, evidence = wait_capture_alive(pm_path)
        if not alive:
            abort(f"capture not growing {when}", evidence)
        return alive

    def emit(cell: str, producer, env_arm: str, arm_label: str, sha: str, *,
             binding: bool = True, invalidate: bool = True, ctx: bool = False,
             **pkw) -> None:
        nonlocal seq, first_binding
        first_binding = first_binding or binding
        row = producer(env_arm, tag, seq, **pkw)
        row["arm_label"] = arm_label
        row["installed_sha"] = sha
        row["cell"] = cell
        row["binding"] = binding
        if ctx:
            row["ctx"] = True
        if binding and invalidate and row["ftrace"].get("present", 0) == 0:
            print(f"{tag} seq={seq} {arm_label}: INVALID zero-present; re-running once",
                  file=sys.stderr)
            row["binding"] = False
            row["invalid_zero_present"] = True
            rows.append(row)
            flush()
            row = producer(env_arm, tag, seq + 1000, **pkw)
            row["arm_label"] = arm_label
            row["installed_sha"] = sha
            row["cell"] = cell
            row["binding"] = row["ftrace"].get("present", 0) > 0
            row["rerun_of"] = seq
            if ctx:
                row["ctx"] = True
        rows.append(row)
        flush()
        print(f"{tag} seq={seq} {arm_label}: parse/mib="
              f"{row.get('parse_ms_per_mib')} "
              f"present={int(row['ftrace'].get('present', 0))}", file=sys.stderr)
        seq += 1

    def flood(env_arm: str, tag_: str, seq_: int) -> dict:
        return run_row("scrolling", env_arm, tag_, seq_)

    def pause(env_arm: str, tag_: str, seq_: int) -> dict:
        return run_row("sync_medium_cells", env_arm, tag_, seq_,
                       engaged=env_arm == "1")

    producers = {"flood": flood, "idle": run_idle_row,
                 "typing": run_typing_row, "pause": pause, "pilot": run_idle_row}
    try:
        if not guard("before first rep"):
            return 3
        for ci, cell in enumerate(cells):
            if ci > 0 and not guard(f"before cell {cell}"):
                return 3
            if cell == "pilot":
                for env_arm in ("0", "1"):
                    sha = install_binary(flip_bin)
                    emit("pilot", run_idle_row, env_arm, f"{flip_arm}{env_arm}",
                         sha, binding=False, invalidate=False)
            elif cell == "flood" and args.flood_arms == "four":
                for arm in latin_order(wa["four"], args.rounds):
                    sha = install_binary(wa["binmap"][arm[:-1]])
                    emit("flood", flood, arm[-1], arm, sha)
            elif cell == "flood":
                for rep in range(1, args.rounds + 1):
                    for env_arm in arm_order_for_rep(rep):
                        sha = install_binary(flip_bin)
                        emit("flood", flood, env_arm, f"{flip_arm}{env_arm}", sha)
            else:
                for rep in range(1, args.reps + 1):
                    for env_arm in arm_order_for_rep(rep):
                        sha = install_binary(flip_bin)
                        emit(cell, producers[cell], env_arm,
                             f"{flip_arm}{env_arm}", sha,
                             invalidate=cell != "idle" or args.idle_present_literal)
        if args.ctx_bpre:
            for env_arm in ("0", "1"):
                sha = install_binary("B_pre")
                emit("flood", flood, env_arm, f"bpre{env_arm}", sha,
                     binding=False, invalidate=False, ctx=True)
    except Exception as exc:
        abort(f"exception: {exc!r}", {})
        raise
    finally:
        # A failed restore leaves the WRONG .so installed -- loud, recorded,
        # but never allowed to mask the classified exit code above.
        try:
            out["restored"] = install_binary(wa["restore"])
        except OSError as exc:
            out["restore_failed"] = repr(exc)
            print(f"WARNING: could not restore {wa['restore']}: {exc}",
                  file=sys.stderr)
        flush()
    return 0


# ===========================================================================
# Generalized two-arm block + the G6 RSS driver
# ===========================================================================

def parse_arm_spec(spec: str) -> tuple[str, str]:
    binary, _, env_arm = spec.partition(":")
    if not binary or env_arm not in ("0", "1", "u"):
        raise SystemExit(f"bad arm spec {spec!r}; want BINARY:{{0,1,u}}")
    return binary, env_arm


def cmd_xab(args: argparse.Namespace) -> int:
    """Generalized two-arm block (G2 lever cost, CPU sanity): each arm is a
    BINARY:ENV pair, interleaved a,b / b,a per round with a FRESH-INODE
    install at every arm transition. ENV `u` leaves the lever var unset."""
    sides = {"a": parse_arm_spec(args.arm_a), "b": parse_arm_spec(args.arm_b)}
    tag = f"xab-{args.bench}-{args.tag}"
    rows: list[dict] = []
    for rnd in range(args.rounds):
        for side in (("b", "a") if rnd % 2 else ("a", "b")):
            binary, env_arm = sides[side]
            sha = install_binary(binary)
            row = run_row(args.bench, env_arm, tag, len(rows))
            row["arm_label"] = f"{side}:{binary}:{env_arm}"
            row["side"] = side
            row["installed_sha"] = sha
            rows.append(row)
            print(f"{tag} round {rnd} {row['arm_label']}: "
                  f"{row.get('parse_ms_per_mib', row.get('error'))}", file=sys.stderr)
    install_binary(WAVE_ARMS[WAVE]["default_bin"])

    def vals(side: str, field: str) -> list[float]:
        return [r[field] for r in rows if r["side"] == side
                and not r.get("error") and field in r]

    out: dict = {"tag": tag, "bench": args.bench, "arm_a": args.arm_a,
                 "arm_b": args.arm_b, "rounds": args.rounds, "rows": rows}
    a, b = vals("a", "parse_ms_per_mib"), vals("b", "parse_ms_per_mib")
    out["n_a"], out["n_b"] = len(a), len(b)
    if len(a) == len(b) == args.rounds:
        out["med_a"] = statistics.median(a)
        out["med_b"] = statistics.median(b)
        out["ratio_b_over_a"] = out["med_b"] / out["med_a"]
        ac, bc = vals("a", "cycles_per_mib"), vals("b", "cycles_per_mib")
        if len(ac) == len(bc) == args.rounds:
            out["med_a_cycles"] = statistics.median(ac)
            out["med_b_cycles"] = statistics.median(bc)
            out["ratio_b_over_a_cycles"] = out["med_b_cycles"] / out["med_a_cycles"]
    else:
        out["error"] = "n-floor breach"
    write_rows(tag, out)
    render_png(tag, rows)
    print(json.dumps({k: out.get(k) for k in
                      ("med_a", "med_b", "ratio_b_over_a", "ratio_b_over_a_cycles",
                       "error")}, indent=1))
    return 1 if out.get("error") else 0


def cmd_rss(args: argparse.Namespace) -> int:
    """G6 peak-RSS driver: `--reps` fresh-spawn pause-shape rows on one
    binary/lever arm, `ps -o rss=` polled every 0.5 s, peak KB per row.

    Fresh minimal driver on purpose: no tracked W26-era RSS driver survives,
    and `scripts/w25_cow_battery.py` is the G10 battery driver -- it is
    reused as-is for that leg rather than being generalized into this one."""
    tag = f"rss-{args.binary}-{args.env}"
    rows = []
    for rep in range(args.reps):
        sha = install_binary(args.binary)
        row = run_rss_row(args.env, tag, rep)
        row["arm_label"] = f"{args.binary}:{args.env}"
        row["installed_sha"] = sha
        rows.append(row)
        print(f"{tag} rep {rep}: peak_rss_kb={row['peak_rss_kb']} "
              f"identity={row.get('identity_exact')}", file=sys.stderr)
    install_binary(WAVE_ARMS[WAVE]["default_bin"])
    peaks = [r["peak_rss_kb"] for r in rows if r["peak_rss_kb"]]
    out = {"tag": tag, "binary": args.binary, "env_arm": args.env, "rows": rows,
           "peaks_kb": peaks, "n": len(peaks),
           "median_peak_rss_kb": statistics.median(peaks) if peaks else None,
           "median_peak_rss_mb": (round(statistics.median(peaks) / 1024.0, 2)
                                  if peaks else None)}
    write_rows(tag, out)
    print(json.dumps({k: out.get(k) for k in
                      ("peaks_kb", "median_peak_rss_kb", "median_peak_rss_mb")},
                     indent=1))
    return 0


def main() -> int:
    # The plan's frozen t4_producer invocation is `w26b_statecost.py
    # --engaged ...`; map that spelling onto the engaged subcommand.
    if sys.argv[1:2] == ["--engaged"]:
        sys.argv[1:2] = ["engaged"]
    # energy-analyze is pure post-processing (and its self-checks must stay
    # hermetic): it spawns no kitty, so there is nothing for caffeinate to
    # protect and no reason to spawn a process from a self-check.
    if "energy-analyze" in sys.argv[1:]:
        return _dispatch()
    # Display sleep collapses presents for entire 60 s rows (throughput -35%,
    # parse_ms/MiB +55% -- the OQ-1 regime, reproduced in the first threebin
    # block at ~01:00 with the operator idle). caffeinate -dis co-runs every
    # block so rows stay in the rendering regime; identical for all arms.
    caf = subprocess.Popen(["caffeinate", "-dis"])
    try:
        return _dispatch()
    finally:
        caf.terminate()


def _dispatch() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--wave", choices=tuple(WAVE_DIR), default="w26b",
                    help="artifact root + flood arm map (default w26b)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("pilot")
    p.add_argument("--xbin", action="store_true")
    p.set_defaults(fn=cmd_pilot)
    p = sub.add_parser("ab")
    p.add_argument("--bench", default="scrolling")
    p.add_argument("--rounds", type=int, default=8)
    p.add_argument("--tag", default="r1")
    p.set_defaults(fn=cmd_ab)
    p = sub.add_parser("threebin")
    p.add_argument("--rounds", type=int, default=5)
    p.set_defaults(fn=cmd_threebin)
    p = sub.add_parser("fourarm")
    p.add_argument("--bench", default="scrolling")
    p.add_argument("--rounds", type=int, default=8)
    p.add_argument("--share0-only", action="store_true")
    p.set_defaults(fn=cmd_fourarm)
    p = sub.add_parser("energy")
    p.add_argument("--rounds", type=int, default=6, help="flood 4-arm rounds")
    p.add_argument("--reps", type=int, default=3, help="per-arm reps, non-flood cells")
    p.add_argument("--cells", default="flood")
    p.add_argument("--capture", default=None,
                   help="powermetrics output file to liveness-guard against")
    p.add_argument("--tag", default=None, help="ledger suffix: energy-ledger-TAG.json")
    p.add_argument("--flood-arms", choices=("four", "flip"), default="four")
    p.add_argument("--idle-present-literal", action="store_true",
                   help="apply the zero-present invalidation to idle rows too")
    p.add_argument("--ctx-bpre", action="store_true",
                   help="append 2 non-binding B_pre flood context rows")
    p.set_defaults(fn=cmd_energy)
    p = sub.add_parser("energy-analyze")
    p.add_argument("--ledger", default=None)
    p.add_argument("--capture", default=None)
    p.add_argument("--out", default=None)
    p.add_argument("--flush-settle", action="store_true")
    p.add_argument("--selfcheck-synthetic", action="store_true")
    p.add_argument("--selfcheck-retained", action="store_true")
    p.set_defaults(fn=cmd_energy_analyze)
    p = sub.add_parser("engaged")
    p.add_argument("--rounds", type=int, default=5)
    p.add_argument("--with-flag", action="store_true")
    p.add_argument("--binary", default=None)
    p.add_argument("--env", choices=("0", "1", "u"), default="1")
    p.set_defaults(fn=cmd_engaged)
    p = sub.add_parser("xab")
    p.add_argument("--arm-a", required=True, help="BINARY:{0,1,u}")
    p.add_argument("--arm-b", required=True, help="BINARY:{0,1,u}")
    p.add_argument("--bench", default="scrolling")
    p.add_argument("--rounds", type=int, default=8)
    p.add_argument("--tag", default="g2")
    p.set_defaults(fn=cmd_xab)
    p = sub.add_parser("rss")
    p.add_argument("--binary", required=True)
    p.add_argument("--env", choices=("0", "1", "u"), default="1")
    p.add_argument("--reps", type=int, default=3)
    p.set_defaults(fn=cmd_rss)
    args = ap.parse_args()
    set_wave(args.wave)
    return args.fn(args)


if __name__ == "__main__":
    raise SystemExit(main())
