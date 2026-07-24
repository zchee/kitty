#!/usr/bin/env python3.14
"""R3 W-A bill battery: nvim fixed-work replay, per-process bill A/B.

Redefined-acceptance battery (plan-2026-07-24-r3-nvim-acceptance-
redefinition.md W-A): same patched nvim binary, arms {tty, oob}, 10-loop
scroll replay (NVIM_AB_LOOPS), 3 interleaved rounds with rotated arm order.
Per row this driver samples the LIFETIME resource bill of both processes
(kitty + nvim) via scripts/_r3_rusage.py (proc_pid_rusage RUSAGE_INFO_V4):
CPU ns, OS wakeups (pkg_idle + interrupt), billed energy (observational).
Processes exist only for the row, so final lifetime totals ARE the row bill
(sampled by polling until exit; last successful sample wins).

Transport-syscall counts come from the kitty side: SUM(io_reads) over
KITTY_FRAME_TRACE ticks (pty reads) + oob_stats `reads` (OOB reads), and
byte parity from SUM(" bytes=") (ft_bytes_drained, oob-inclusive) vs
oob_stats bytes_in. Arm identity is asserted per row on the tick SUM of
oob_drained (>0 for oob rows, ==0 for tty rows).

Gates (pre-registered): G1a reads ratio <= 0.25; G1b wakeups ratio <= 0.70;
G2 CPU ratio <= 0.90 AND per-process <= 1.05; G3 wall ratio <= 1.02;
G4 drained-bytes parity +/-2% AND oob pty-reads <= 50/loop-set.

Usage: r3_bill_battery.py [--dry-run]   (dry-run: 1 round, no gate verdicts)
Outputs under .omc/verify/r3/: bill-results.jsonl, bill-summary.json,
r3-bill.png (gnuplot pngcairo).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import statistics
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _kitty_harness_common as h
import _r3_rusage as ru
from r3_nvim_ab import FIXTURE, NVIM, REPLAY_VIM, build_fixture, parse_oob_stats

ROUNDS = 3
LOOPS = 10
VERIFY_DIR = h.REPO_ROOT / ".omc" / "verify" / "r3"
KITTY_EXIT_TIMEOUT = 600.0
MIN_OOB_BYTES = 180 * 1024 * 1024  # ~22 MB/loop x 10 loops x 0.8 slack


def find_nvim_pid(kitty_pid: int, deadline_s: float = 15.0) -> int | None:
    end = time.monotonic() + deadline_s
    while time.monotonic() < end:
        try:
            out = subprocess.run(["pgrep", "-P", str(kitty_pid), "-x", "nvim"],
                                 capture_output=True, text=True, timeout=5)
            pids = [int(x) for x in out.stdout.split()]
            if pids:
                return pids[0]
        except (subprocess.TimeoutExpired, ValueError):
            pass
        time.sleep(0.1)
    return None


def ftrace_sums(text: str) -> dict:
    # Two counter families share the ftrace line: ft_* fields (bytes=,
    # oob_drained=) reset per tick -> SUM; io_* fields are lifetime-cumulative
    # snapshots (child-monitor.c:735 atomic_load of io_read_calls) -> LAST.
    sums = {"io_reads": 0, "io_read_bytes": 0, "bytes_drained": 0, "oob_drained": 0, "ticks": 0}
    for line in text.splitlines():
        if "ftrace: seq=" not in line:
            continue
        m_reads = re.search(r" io_reads=(\d+)", line)
        m_rbytes = re.search(r" io_read_bytes=(\d+)", line)
        m_bytes = re.search(r" bytes=(\d+)", line)
        m_oob = re.search(r" oob_drained=(\d+)", line)
        if not (m_reads and m_bytes and m_oob):
            continue
        sums["ticks"] += 1
        sums["io_reads"] = int(m_reads.group(1))
        sums["io_read_bytes"] = int(m_rbytes.group(1)) if m_rbytes else 0
        sums["bytes_drained"] += int(m_bytes.group(1))
        sums["oob_drained"] += int(m_oob.group(1))
    return sums


def run_row(arm: str, round_no: int) -> dict:
    h.wait_for_build_lock_clear()
    result_file = VERIFY_DIR / f"bill-{arm}-r{round_no}.json"
    stderr_file = VERIFY_DIR / f"kitty-bill-{arm}-r{round_no}.stderr.log"
    result_file.unlink(missing_ok=True)

    env = {"NVIM_AB_RESULT": str(result_file), "NVIM_AB_LOOPS": str(LOOPS),
           "KITTY_FRAME_TRACE": "1"}
    if arm == "oob":
        env["KITTY_ENABLE_TUI_OOB"] = "1"
        env["KITTY_OOB_STATS"] = "1"

    argv = [str(NVIM), "--clean", "+source " + str(REPLAY_VIM), str(FIXTURE)]
    row: dict = {"arm": arm, "round": round_no, "loops": LOOPS,
                 "load_before": os.getloadavg()[0]}
    kitty_snap: dict | None = None
    nvim_snap: dict | None = None
    with open(stderr_file, "wb") as ef:
        proc = h.spawn_kitty(argv, extra_env=env, stderr=ef)
        nvim_pid = find_nvim_pid(proc.pid)
        row["kitty_pid"], row["nvim_pid"] = proc.pid, nvim_pid
        deadline = time.monotonic() + KITTY_EXIT_TIMEOUT
        while proc.poll() is None and time.monotonic() < deadline:
            try:
                kitty_snap = ru.snap(proc.pid)
            except OSError:
                pass
            if nvim_pid is not None:
                try:
                    nvim_snap = ru.snap(nvim_pid)
                except OSError:
                    pass
            time.sleep(0.1)
        if proc.poll() is None:
            h.terminate_kitty(proc)
            row["error"] = f"kitty did not exit within {KITTY_EXIT_TIMEOUT}s"
            return row
    row["load_after"] = os.getloadavg()[0]
    if nvim_pid is None:
        row["error"] = "nvim child pid never found"
        return row
    if not result_file.exists():
        row["error"] = "replay wrote no result file"
        return row
    row.update(json.loads(result_file.read_text()))
    row["kitty_bill"], row["nvim_bill"] = kitty_snap, nvim_snap

    text = stderr_file.read_text(errors="replace")
    row["ftrace"] = ftrace_sums(text)
    stats = parse_oob_stats(text)
    row["oob_stats"] = stats

    ft = row["ftrace"]
    if arm == "oob":
        if stats is None:
            row.setdefault("error", "no oob_stats line on kitty stderr")
        elif stats.get("handshake_ok") != 1 or stats.get("fallbacks", 0) != 0 or stats.get("broken", 0) != 0:
            row.setdefault("error", f"bad channel state: {stats}")
        elif stats.get("bytes_in", 0) < MIN_OOB_BYTES:
            row.setdefault("error", f"only {stats.get('bytes_in', 0)} B via OOB (arming failed?)")
        elif ft["oob_drained"] == 0:
            row.setdefault("error", "identity FAIL: oob row with oob_drained sum == 0")
        row["ingest_reads"] = ft["io_reads"] + (stats.get("reads", 0) if stats else 0)
    else:
        if row.get("oob_env"):
            row.setdefault("error", "KITTY_TUI_OOB_FD present in gate-off arm (audit FAIL)")
        if ft["oob_drained"] != 0:
            row.setdefault("error", "identity FAIL: tty row with oob_drained sum > 0")
        row["ingest_reads"] = ft["io_reads"]
    if kitty_snap is None or nvim_snap is None:
        row.setdefault("error", "rusage sampling never succeeded for a pid")
    return row


def pooled(rows: list[dict], arm: str, fn) -> float:
    vals = [fn(r) for r in rows if r["arm"] == arm and not r.get("error")]
    return statistics.fmean(vals) if vals else float("nan")


def analyze(rows: list[dict], dry: bool) -> dict:
    get = {
        "wall_s": lambda r: r["seconds"],
        "ingest_reads": lambda r: r["ingest_reads"],
        "wakeups": lambda r: r["kitty_bill"]["wakeups"] + r["nvim_bill"]["wakeups"],
        "cpu_ns": lambda r: r["kitty_bill"]["cpu_ns"] + r["nvim_bill"]["cpu_ns"],
        "kitty_cpu_ns": lambda r: r["kitty_bill"]["cpu_ns"],
        "nvim_cpu_ns": lambda r: r["nvim_bill"]["cpu_ns"],
        "kitty_wakeups": lambda r: r["kitty_bill"]["wakeups"],
        "nvim_wakeups": lambda r: r["nvim_bill"]["wakeups"],
        "bytes_drained": lambda r: r["ftrace"]["bytes_drained"],
        "energy_nj": lambda r: r["kitty_bill"]["billed_energy_nj"] + r["nvim_bill"]["billed_energy_nj"],
        "pty_reads": lambda r: r["ftrace"]["io_reads"],
    }
    means: dict = {a: {k: pooled(rows, a, f) for k, f in get.items()} for a in ("tty", "oob")}
    t, ob = means["tty"], means["oob"]
    ratios = {k: (ob[k] / t[k] if t[k] else float("nan"))
              for k in ("wall_s", "ingest_reads", "wakeups", "cpu_ns",
                        "kitty_cpu_ns", "nvim_cpu_ns", "kitty_wakeups",
                        "nvim_wakeups", "energy_nj")}
    parity = abs(ob["bytes_drained"] - t["bytes_drained"]) / t["bytes_drained"]
    out = {"means": means, "ratios": ratios, "bytes_parity_relerr": parity}
    if not dry:
        out["gates"] = {
            "G1a_reads": {"ratio": ratios["ingest_reads"], "gate": 0.25,
                          "pass": ratios["ingest_reads"] <= 0.25},
            "G1b_wakeups": {"ratio": ratios["wakeups"], "gate": 0.70,
                            "pass": ratios["wakeups"] <= 0.70},
            "G2_cpu": {"ratio": ratios["cpu_ns"], "gate": 0.90,
                       "kitty": ratios["kitty_cpu_ns"], "nvim": ratios["nvim_cpu_ns"],
                       "pass": ratios["cpu_ns"] <= 0.90
                       and ratios["kitty_cpu_ns"] <= 1.05 and ratios["nvim_cpu_ns"] <= 1.05},
            "G3_wall": {"ratio": ratios["wall_s"], "gate": 1.02,
                        "pass": ratios["wall_s"] <= 1.02},
            "G4_parity": {"relerr": parity, "gate": 0.02,
                          "oob_pty_reads": ob["pty_reads"],
                          "pass": parity <= 0.02 and ob["pty_reads"] <= 50},
        }
        out["core_gates_pass"] = all(g["pass"] for g in out["gates"].values())
    return out


def emit_png(summary: dict, out_png: Path) -> bool:
    ratios = summary["ratios"]
    bars = [("reads (G1a<=0.25)", ratios["ingest_reads"], 0.25),
            ("wakeups (G1b<=0.70)", ratios["wakeups"], 0.70),
            ("cpu (G2<=0.90)", ratios["cpu_ns"], 0.90),
            ("wall (G3<=1.02)", ratios["wall_s"], 1.02),
            ("energy (obs.)", ratios["energy_nj"], float("nan"))]
    dat = VERIFY_DIR / "r3-bill.dat"
    dat.write_text("\n".join(
        f'{i} {v:.4f} {g if g == g else "-"} "{label}"'
        for i, (label, v, g) in enumerate(bars)) + "\n")
    gp = VERIFY_DIR / "r3-bill.gp"
    gp.write_text(f"""set terminal pngcairo size 1000,620 font 'Helvetica,12'
set output '{out_png}'
set title 'R3 W-A bill battery: oob/tty pooled mean ratios ({ROUNDS} rounds x {LOOPS}-loop replay)'
set ylabel 'oob / tty ratio (lower is better)'
set xrange [-0.6:4.6]
set yrange [0:1.3]
set grid ytics
set boxwidth 0.5
set style fill solid 0.55
plot '{dat}' using 1:2:xtic(4) with boxes lc rgb '#2ca02c' notitle, \\
     '{dat}' using 1:(strcol(3) eq '-' ? 1/0 : column(3)):(0.35) with xerrorbars lc rgb '#d62728' pt 0 lw 2 title 'gate', \\
     '{dat}' using 1:($2+0.05):(sprintf('%.3f', $2)) with labels font ',10' notitle, \\
     1.0 with lines dt 2 lc rgb '#7f7f7f' title 'parity'
""")
    try:
        subprocess.run(["gnuplot", str(gp)], check=True, capture_output=True, timeout=30)
        return out_png.exists()
    except (subprocess.CalledProcessError, FileNotFoundError, subprocess.TimeoutExpired) as e:
        print(f"[r3-bill] gnuplot PNG emission failed: {e}", file=sys.stderr)
        return False


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    rounds = 1 if args.dry_run else ROUNDS

    VERIFY_DIR.mkdir(parents=True, exist_ok=True)
    if not NVIM.exists():
        print(f"ERROR: patched nvim not found at {NVIM}", file=sys.stderr)
        return 1
    build_fixture()

    rows: list[dict] = []
    for round_no in range(1, rounds + 1):
        arms = ("tty", "oob") if round_no % 2 == 1 else ("oob", "tty")
        for arm in arms:
            print(f"[r3-bill] round {round_no}/{rounds} arm={arm} ...", flush=True)
            row = run_row(arm, round_no)
            rows.append(row)
            desc = (f"{row['seconds']:.2f}s reads={row.get('ingest_reads')} "
                    f"cpu={(row['kitty_bill']['cpu_ns'] + row['nvim_bill']['cpu_ns']) / 1e9:.2f}s "
                    f"wk={row['kitty_bill']['wakeups'] + row['nvim_bill']['wakeups']}"
                    if not row.get("error") else row["error"])
            print(f"[r3-bill]   -> {desc}", flush=True)
            time.sleep(1.0)

    tag = "dryrun-" if args.dry_run else ""
    with open(VERIFY_DIR / f"bill-{tag}results.jsonl", "w") as f:
        for r in rows:
            f.write(json.dumps(r) + "\n")

    errors = [{k: r.get(k) for k in ("arm", "round", "error")} for r in rows if r.get("error")]
    summary = {"rounds": rounds, "loops": LOOPS, "errors": errors,
               "loadavg_range": [min(r["load_before"] for r in rows),
                                 max(r.get("load_after", r["load_before"]) for r in rows)]}
    if len(errors) == 0:
        summary.update(analyze(rows, args.dry_run))
        if not args.dry_run:
            summary["png"] = emit_png(summary, VERIFY_DIR / "r3-bill.png")
        summary["verdict"] = ("DRY-OK" if args.dry_run
                              else ("ALL-PASS" if summary["core_gates_pass"] else "GATE-MISS"))
    else:
        summary["verdict"] = "ERROR"
    (VERIFY_DIR / f"bill-{tag}summary.json").write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary, indent=2))
    return 0 if summary["verdict"] in ("ALL-PASS", "DRY-OK") else (2 if summary["verdict"] == "GATE-MISS" else 1)


if __name__ == "__main__":
    raise SystemExit(main())
