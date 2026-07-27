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

VERIFY = h.REPO_ROOT / ".omc" / "verify" / "wave26b"
RESULTS = VERIFY / "results"
BINDIR = VERIFY / "binaries"
SO_PATH = h.REPO_ROOT / "kitty" / "fast_data_types.so"

VTEBENCH = Path("/Users/zchee/src/github.com/alacritty/vtebench/target/release/vtebench")
VB_BENCH = Path("/Users/zchee/src/github.com/alacritty/vtebench/benchmarks")

SEGMENT_SECS = 60
PACING_S = 10.0
LOAD_THRESHOLD = 8.0
BOOT_RESAMPLES = 4000
BOOT_SEED = 4
YNUM = 30  # spawn_kitty geometry row count: the engaged identity multiplier

FTRACE_RE = re.compile(r"ftrace: seq=\d+ .*")
KV_RE = re.compile(r"(\w+)=([-\d.]+)")


def bench_dir(bench: str) -> Path:
    d = VERIFY / "bench-links"
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


def run_row(bench: str, env_arm: str, tag: str, seq: int, engaged: bool = False) -> dict:
    """One fresh-spawn 60 s vtebench row on the CURRENTLY INSTALLED binary."""
    h.wait_for_build_lock_clear()
    RESULTS.mkdir(parents=True, exist_ok=True)
    load = wait_for_quiet()
    td = Path(tempfile.mkdtemp(prefix=f"w26b-{tag}-"))
    dat = td / "out.dat"
    stderr_path = RESULTS / f"{tag}-s{seq}.stderr.log"
    env = {"KITTY_FRAME_TRACE": "1", "KITTY_PAUSE_SNAPSHOT_SHARE": env_arm}
    row: dict = {"tag": tag, "seq": seq, "bench": bench, "env_arm": env_arm,
                 "load_before": load, "so_sha": live_so_sha(),
                 "t0": time.time()}
    snap = None
    with open(stderr_path, "wb") as fh:
        proc = h.spawn_kitty(["/bin/sh", "-c", vtebench_cmd(bench, dat)],
                             take_focus=False, extra_env=env, stderr=fh)
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
    row["load_after"] = os.getloadavg()[0]
    text = stderr_path.read_text(errors="replace")
    tot = ftrace_totals(text)
    row["ftrace"] = tot
    mib = tot.get("bytes", 0.0) / (1024 * 1024)
    row["mib"] = round(mib, 3)
    if mib > 0:
        row["parse_ms_per_mib"] = tot.get("parse_ms", 0.0) / mib
    else:
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
    else:
        if tot.get("share_rows_total", 0.0) != 0.0:
            row["error"] = (row.get("error", "") +
                            " non-engaged row saw share_rows_total != 0").strip()
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
    """M2: {B_base,B_flag} x {SHARE=0,1}, Latin square, n rounds/arm."""
    arms = ["base0", "base1", "flag0", "flag1"]
    binmap = {"base": "B_base", "flag": "B_flag"}
    tag = f"fourarm-{args.bench}"
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
    if len(med) == 4:
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
                       "t3_scrolling", "t2_elimination_fraction",
                       "t5_cycles_ratio", "instructions_ratio", "error")}, indent=1))
    return 1 if out.get("error") else 0


def cmd_engaged(args: argparse.Namespace) -> int:
    """T4: engaged cell (sync_medium_cells) per binary, alternating."""
    arms = ["B_base", "B_flag"] if args.with_flag else ["B_base"]
    tag = "engaged"
    rows = []
    for rnd in range(args.rounds):
        order = arms if rnd % 2 == 0 else list(reversed(arms))
        for name in order:
            sha = install_binary(name)
            seq = len(rows)
            row = run_row("sync_medium_cells", "1", tag, seq, engaged=True)
            row["arm_label"] = name
            row["installed_sha"] = sha
            rows.append(row)
            print(f"{tag} round {rnd} {name}: parse/mib="
                  f"{row.get('parse_ms_per_mib')} identity={row.get('identity_exact')} "
                  f"cow+={row.get('cow_retires_positive')}", file=sys.stderr)
    install_binary("B_base")
    valid = [r for r in rows if not r.get("error") and r.get("identity_exact")
             and r.get("cow_retires_positive")]
    out: dict = {"tag": tag, "rows": rows, "n_valid": len(valid)}
    for name in arms:
        vals = [r["parse_ms_per_mib"] for r in valid if r["arm_label"] == name]
        out[f"med_{name}"] = statistics.median(vals) if vals else None
        out[f"n_{name}"] = len(vals)
    if args.with_flag and out.get("med_B_base") and out.get("med_B_flag"):
        out["t4_ratio"] = out["med_B_flag"] / out["med_B_base"]
    write_rows(tag, out)
    render_png(tag, rows)
    print(json.dumps({k: out.get(k) for k in
                      ("med_B_base", "med_B_flag", "t4_ratio", "n_valid")}, indent=1))
    return 0


def main() -> int:
    # The plan's frozen t4_producer invocation is `w26b_statecost.py
    # --engaged ...`; map that spelling onto the engaged subcommand.
    if sys.argv[1:2] == ["--engaged"]:
        sys.argv[1:2] = ["engaged"]
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
    p.set_defaults(fn=cmd_fourarm)
    p = sub.add_parser("engaged")
    p.add_argument("--rounds", type=int, default=5)
    p.add_argument("--with-flag", action="store_true")
    p.set_defaults(fn=cmd_engaged)
    args = ap.parse_args()
    return args.fn(args)


if __name__ == "__main__":
    raise SystemExit(main())
