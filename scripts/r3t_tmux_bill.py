#!/usr/bin/env python3.14
"""M0 W-T bill battery: tmux->kitty hop, {gate-unset, gate-on} on ONE tmux binary.

Per plan-2026-07-24-tmux-oob-client-m0.md. Each row spawns a harness kitty
whose child is the WORKTREE tmux (never PATH tmux) with an isolated socket
and -f /dev/null, running the workload inside the single pane:

  t1: oob_flood_client.py --arm pty --pace-mbs 6 --duration-s 30
      (pane pty -> tmux server -> client tty/channel -> kitty)
  t2: nvim --clean scroll replay (r3_replay.vim, NVIM_AB_LOOPS)

The arm is the kitty child's gate env (KITTY_ENABLE_TUI_OOB unset|1); the
tmux binary is constant. Bills are lifetime rusage totals (last-wins polls,
scripts/_r3_rusage.py) for the trio {kitty, tmux client, tmux server} —
fresh isolated server per row makes server lifetime row-scoped. kitty-side
ftrace gives ingest reads (io_* cumulative -> LAST), output bytes and the
oob split (ft_* per-tick -> SUM). tmux renders adaptively, so cross-arm
byte parity is NOT expected: bill metrics normalize per output MiB, with
the T-G4 sanity band [0.80, 1.25] recorded (pre-mortem a: outside band ->
adjudicate W-T2 only).

Pre-registered adjudication (frozen before any patched-tmux data): T-G1a
(reads/MiB <= 0.35), T-G1b (trio wakeups/MiB <= 0.75), T-G2 (trio CPU/MiB
<= 0.95, no single process > 1.10) must hold on BOTH workloads; T-G3 (wall
ratio <= 1.05) on t2 only.

Usage: r3t_tmux_bill.py --workload {t1,t2} [--baseline] [--rounds N]
  --baseline: 1 round, stock-tmux expectations (no handshake anywhere:
  oob_drained == 0 in BOTH arms; validates pid/rusage plumbing only).
Outputs under .omc/verify/r3t/: bill-<wl>[-baseline]-results.jsonl,
bill-<wl>[-baseline]-summary.json, r3t-bill-<wl>.png (full mode).
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
from r3_bill_battery import ftrace_sums
from r3_nvim_ab import FIXTURE, NVIM, REPLAY_VIM, build_fixture, parse_oob_stats

# R3T_TMUX_BIN overrides the binary under test (M2 builds land in the main
# checkout); the default stays the M0/M1 worktree binary for reproducibility.
TMUX = Path(os.environ.get("R3T_TMUX_BIN",
                           "/Users/zchee/src/github.com/tmux/tmux-worktrees/r3t-oob-m0/tmux"))
VERIFY_DIR = h.REPO_ROOT / ".omc" / "verify" / "r3t"
CLIENT = h.REPO_ROOT / "scripts" / "oob_flood_client.py"
T1_DURATION_S = 30.0
T2_LOOPS = 10
ROW_TIMEOUT = 600.0


def tmux_ctl(sock: str, *args: str) -> str:
    out = subprocess.run([str(TMUX), "-L", sock, *args],
                         capture_output=True, text=True, timeout=10)
    return out.stdout.strip()


def resolve_pids(kitty_pid: int, sock: str, deadline_s: float = 20.0) -> dict:
    pids: dict = {"client": None, "server": None, "inner": None}
    end = time.monotonic() + deadline_s
    while time.monotonic() < end and None in pids.values():
        try:
            if pids["client"] is None:
                out = subprocess.run(["pgrep", "-P", str(kitty_pid), "-x", "tmux"],
                                     capture_output=True, text=True, timeout=5)
                got = [int(x) for x in out.stdout.split()]
                if got:
                    pids["client"] = got[0]
            if pids["server"] is None:
                s = tmux_ctl(sock, "display-message", "-p", "#{pid}")
                if s.isdigit():
                    pids["server"] = int(s)
            if pids["inner"] is None:
                s = tmux_ctl(sock, "display-message", "-p", "#{pane_pid}")
                if s.isdigit():
                    pids["inner"] = int(s)
        except (subprocess.TimeoutExpired, ValueError):
            pass
        if None in pids.values():
            time.sleep(0.2)
    return pids


PANE_OFF_CFG = Path("/tmp/r3t-pane-off.conf")


def run_row(workload: str, arm: str, round_no: int, tag: str) -> dict:
    h.wait_for_build_lock_clear()
    VERIFY_DIR.mkdir(parents=True, exist_ok=True)
    sock = f"r3t-{os.getpid()}-{tag}{workload}-{arm}-r{round_no}"
    result_file = VERIFY_DIR / f"bill-{tag}{workload}-{arm}-r{round_no}.json"
    stderr_file = VERIFY_DIR / f"kitty-{tag}{workload}-{arm}-r{round_no}.stderr.log"
    result_file.unlink(missing_ok=True)

    # M2 pane-hop A/B: both arms keep the client hop armed; the pane offer
    # is toggled via a config file setting kitty-oob-pane off.
    pane_ab = arm in ("paneon", "paneoff")
    cfg = "/dev/null"
    if arm == "paneoff":
        PANE_OFF_CFG.write_text("set -g kitty-oob-pane off\n")
        cfg = str(PANE_OFF_CFG)

    env = {"KITTY_FRAME_TRACE": "1"}
    if arm == "oob" or pane_ab:
        env["KITTY_ENABLE_TUI_OOB"] = "1"
        env["KITTY_OOB_STATS"] = "1"

    if workload == "t1":
        inner = ["-e", f"KITTY_OOB_RESULT_FILE={result_file}",
                 "python3.14", str(CLIENT), "--arm", "pty",
                 "--pace-mbs", "6", "--duration-s", str(T1_DURATION_S)]
    else:
        inner = ["-e", f"NVIM_AB_RESULT={result_file}",
                 "-e", f"NVIM_AB_LOOPS={T2_LOOPS}",
                 str(NVIM), "--clean", "+source " + str(REPLAY_VIM), str(FIXTURE)]
    argv = [str(TMUX), "-L", sock, "-f", cfg, "new-session"] + inner

    row: dict = {"workload": workload, "arm": arm, "round": round_no,
                 "load_before": os.getloadavg()[0]}
    snaps: dict = {"kitty": None, "client": None, "server": None, "inner": None}
    pane_var = ""
    last_pane_poll = 0.0
    with open(stderr_file, "wb") as ef:
        proc = h.spawn_kitty(argv, extra_env=env, stderr=ef)
        pids = resolve_pids(proc.pid, sock)
        row["pids"] = {"kitty": proc.pid, **pids}
        deadline = time.monotonic() + ROW_TIMEOUT
        while proc.poll() is None and time.monotonic() < deadline:
            for name, pid in (("kitty", proc.pid), ("client", pids["client"]),
                              ("server", pids["server"]), ("inner", pids["inner"])):
                if pid is None:
                    continue
                try:
                    snaps[name] = ru.snap(pid)
                except OSError:
                    pass
            if pane_ab and time.monotonic() - last_pane_poll > 2.0:
                last_pane_poll = time.monotonic()
                s = tmux_ctl(sock, "list-panes", "-F", "#{pane_kitty_oob}")
                if s:
                    pane_var = s
            time.sleep(0.1)
        if proc.poll() is None:
            h.terminate_kitty(proc)
            row["error"] = f"kitty did not exit within {ROW_TIMEOUT}s"
            return row
    subprocess.run([str(TMUX), "-L", sock, "kill-server"],
                   capture_output=True, timeout=10)
    row["load_after"] = os.getloadavg()[0]
    if None in row["pids"].values():
        row["error"] = f"pid resolution incomplete: {row['pids']}"
        return row
    if not result_file.exists():
        row["error"] = "workload wrote no result file"
        return row
    row["inner_result"] = json.loads(result_file.read_text())
    row["bills"] = snaps
    row["pane_var"] = pane_var
    row["pane_counts"] = parse_pane_var(pane_var)
    text = stderr_file.read_text(errors="replace")
    row["ftrace"] = ftrace_sums(text)
    row["oob_stats"] = parse_oob_stats(text)
    if any(v is None for k, v in snaps.items() if k != "inner" or pane_ab):
        row.setdefault("error", "rusage sampling never succeeded for a pid")
    return row


def parse_pane_var(s: str) -> dict:
    m = re.match(r"armed r=(\d+) b=(\d+) pty=(\d+)", s)
    if m:
        return {"state": "armed", "oob_reads": int(m.group(1)),
                "oob_bytes": int(m.group(2)), "pty_reads": int(m.group(3))}
    m = re.match(r"(none|offered|fallback) pty=(\d+)", s)
    if m:
        return {"state": m.group(1), "pty_reads": int(m.group(2))}
    return {"state": s or "unknown"}


def check_identity(row: dict, arm: str, patched: bool) -> None:
    ft, st = row["ftrace"], row["oob_stats"]
    if not patched:
        if ft["oob_drained"] != 0:
            row.setdefault("error", "baseline: oob_drained > 0 with stock tmux?!")
        return
    if arm in ("paneon", "paneoff"):
        # Client hop is armed in BOTH pane-A/B arms.
        if st is None or st.get("handshake_ok") != 1 or st.get("fallbacks", 0) != 0:
            row.setdefault("error", f"identity FAIL: bad client channel {st}")
        pc = row.get("pane_counts", {})
        if arm == "paneon" and (pc.get("state") != "armed" or pc.get("oob_bytes", 0) <= 0):
            row.setdefault("error", f"identity FAIL: paneon not armed ({row.get('pane_var')})")
        if arm == "paneoff" and pc.get("state") != "none":
            row.setdefault("error", f"identity FAIL: paneoff state {row.get('pane_var')}")
        return
    if arm == "oob":
        if st is None or st.get("handshake_ok") != 1 or st.get("fallbacks", 0) != 0:
            row.setdefault("error", f"identity FAIL: bad channel state {st}")
        if ft["oob_drained"] == 0:
            row.setdefault("error", "identity FAIL: oob row drained nothing via channel")
    elif ft["oob_drained"] != 0:
        row.setdefault("error", "identity FAIL: unset row with channel bytes")


def analyze_pane(rows: list[dict]) -> dict:
    def mib(r):
        return r["ftrace"]["bytes_drained"] / (1024 * 1024)

    def pooled_p(arm, fn):
        vals = [fn(r) for r in rows if r["arm"] == arm and not r.get("error")]
        return statistics.fmean(vals) if vals else float("nan")

    def pane_reads(r):
        pc = r["pane_counts"]
        if pc.get("state") == "armed":
            return pc["oob_reads"] + pc["pty_reads"]
        return pc.get("pty_reads", 0)

    get = {
        "out_mib": mib,
        "pane_reads_per_mib": lambda r: pane_reads(r) / mib(r),
        "quartet_cpu_per_mib": lambda r: sum(r["bills"][p]["cpu_ns"] for p in ("kitty", "client", "server", "inner")) / mib(r),
        "quartet_wk_per_mib": lambda r: sum(r["bills"][p]["wakeups"] for p in ("kitty", "client", "server", "inner")) / mib(r),
        "nvim_cpu_per_mib": lambda r: r["bills"]["inner"]["cpu_ns"] / mib(r),
        "server_cpu_per_mib": lambda r: r["bills"]["server"]["cpu_ns"] / mib(r),
        "kitty_cpu_per_mib": lambda r: r["bills"]["kitty"]["cpu_ns"] / mib(r),
        "client_cpu_per_mib": lambda r: r["bills"]["client"]["cpu_ns"] / mib(r),
        "wall_s": lambda r: r["inner_result"].get("seconds") or float("nan"),
    }
    means = {a: {k: pooled_p(a, f) for k, f in get.items()} for a in ("paneoff", "paneon")}
    off, on = means["paneoff"], means["paneon"]
    ratios = {k: (on[k] / off[k] if off[k] else float("nan")) for k in get}
    on_reads = pooled_p("paneon", pane_reads)
    off_reads = pooled_p("paneoff", pane_reads)
    nvim_bytes = pooled_p("paneon", lambda r: r["pane_counts"].get("oob_bytes", 0))
    # P-G1 is priced per delivered MiB, matching the M0/M1 analyze() convention:
    # the pane arm delivers more bytes, so a raw read-count ratio understates
    # the per-byte cost of the pty arm. The raw ratio stays reported because the
    # W-P1 verdict quotes it.
    g1 = ratios["pane_reads_per_mib"]
    g1_raw = on_reads / off_reads if off_reads else float("nan")
    # Aliases so the shared emit_png bar chart renders the P-family ratios.
    ratios["reads_per_mib"] = g1
    ratios["wakeups_per_mib"] = ratios["quartet_wk_per_mib"]
    ratios["cpu_ns_per_mib"] = ratios["quartet_cpu_per_mib"]
    out = {"means": means, "ratios": ratios,
           "paneon_reads": on_reads, "paneoff_reads": off_reads,
           "P_G1_raw_reads_ratio": g1_raw,
           "nvim_pane_bytes": nvim_bytes,
           "bytes_band": ratios["out_mib"],
           "bytes_band_ok": 0.80 <= ratios["out_mib"] <= 1.25}
    out["gates"] = {
        "P_G1_pane_reads": {"ratio": g1, "gate": 0.35, "pass": g1 <= 0.35,
                            "raw_ratio": g1_raw, "convention": "per delivered MiB"},
        "P_G2_quartet_cpu": {"ratio": ratios["quartet_cpu_per_mib"], "gate": 0.92,
                             "kitty": ratios["kitty_cpu_per_mib"], "client": ratios["client_cpu_per_mib"],
                             "server": ratios["server_cpu_per_mib"], "nvim": ratios["nvim_cpu_per_mib"],
                             "pass": ratios["quartet_cpu_per_mib"] <= 0.92
                             and all(ratios[f"{p}_cpu_per_mib"] <= 1.10
                                     for p in ("kitty", "client", "server", "nvim"))},
        "P_G3_wall": {"ratio": ratios["wall_s"], "gate": 1.05,
                      "pass": ratios["wall_s"] <= 1.05},
    }
    out["quartet_wk_ratio_observational"] = ratios["quartet_wk_per_mib"]
    return out


def analyze(rows: list[dict], workload: str) -> dict:
    def mib(r):
        return r["ftrace"]["bytes_drained"] / (1024 * 1024)

    def pooled(arm, fn):
        vals = [fn(r) for r in rows if r["arm"] == arm and not r.get("error")]
        return statistics.fmean(vals) if vals else float("nan")

    get = {
        "out_mib": mib,
        "reads_per_mib": lambda r: (r["ftrace"]["io_reads"]
                                    + (r["oob_stats"] or {}).get("reads", 0)) / mib(r),
        "wakeups_per_mib": lambda r: sum(r["bills"][p]["wakeups"] for p in ("kitty", "client", "server")) / mib(r),
        "cpu_ns_per_mib": lambda r: sum(r["bills"][p]["cpu_ns"] for p in ("kitty", "client", "server")) / mib(r),
        "kitty_cpu_per_mib": lambda r: r["bills"]["kitty"]["cpu_ns"] / mib(r),
        "client_cpu_per_mib": lambda r: r["bills"]["client"]["cpu_ns"] / mib(r),
        "server_cpu_per_mib": lambda r: r["bills"]["server"]["cpu_ns"] / mib(r),
        "wall_s": lambda r: r["inner_result"].get("seconds") or float("nan"),
    }
    means = {a: {k: pooled(a, f) for k, f in get.items()} for a in ("unset", "oob")}
    u, ob = means["unset"], means["oob"]
    ratios = {k: (ob[k] / u[k] if u[k] else float("nan")) for k in get}
    out = {"means": means, "ratios": ratios,
           "bytes_band": ratios["out_mib"], "bytes_band_ok": 0.80 <= ratios["out_mib"] <= 1.25}
    out["gates"] = {
        "T_G1a_reads": {"ratio": ratios["reads_per_mib"], "gate": 0.35,
                        "pass": ratios["reads_per_mib"] <= 0.35},
        "T_G1b_wakeups": {"ratio": ratios["wakeups_per_mib"], "gate": 0.75,
                          "pass": ratios["wakeups_per_mib"] <= 0.75},
        "T_G2_cpu": {"ratio": ratios["cpu_ns_per_mib"], "gate": 0.95,
                     "kitty": ratios["kitty_cpu_per_mib"], "client": ratios["client_cpu_per_mib"],
                     "server": ratios["server_cpu_per_mib"],
                     "pass": ratios["cpu_ns_per_mib"] <= 0.95
                     and all(ratios[f"{p}_cpu_per_mib"] <= 1.10 for p in ("kitty", "client", "server"))},
    }
    if workload == "t2":
        out["gates"]["T_G3_wall"] = {"ratio": ratios["wall_s"], "gate": 1.05,
                                     "pass": ratios["wall_s"] <= 1.05}
    return out


def emit_png(summary: dict, workload: str) -> bool:
    ratios = summary["ratios"]
    bars = [("reads/MiB (<=0.35)", ratios["reads_per_mib"]),
            ("wakeups/MiB (<=0.75)", ratios["wakeups_per_mib"]),
            ("cpu/MiB (<=0.95)", ratios["cpu_ns_per_mib"]),
            ("bytes band", ratios["out_mib"]),
            ("wall", ratios["wall_s"])]
    dat = VERIFY_DIR / f"r3t-bill-{workload}.dat"
    dat.write_text("\n".join(f'{i} {v:.4f} "{n}"' for i, (n, v) in enumerate(bars)) + "\n")
    gp = VERIFY_DIR / f"r3t-bill-{workload}.gp"
    out_png = VERIFY_DIR / f"r3t-bill-{workload}.png"
    gp.write_text(f"""set terminal pngcairo size 1000,620 font 'Helvetica,12'
set output '{out_png}'
set title 'M0 W-{workload.upper()} bill: oob/unset pooled ratios (tmux->kitty hop)'
set ylabel 'gate-on / gate-unset ratio (lower is better)'
set xrange [-0.6:4.6]
set yrange [0:1.4]
set grid ytics
set boxwidth 0.5
set style fill solid 0.55
plot '{dat}' using 1:2:xtic(3) with boxes lc rgb '#2ca02c' notitle, \\
     '{dat}' using 1:($2+0.05):(sprintf('%.3f', $2)) with labels font ',10' notitle, \\
     1.0 with lines dt 2 lc rgb '#7f7f7f' title 'parity'
""")
    try:
        subprocess.run(["gnuplot", str(gp)], check=True, capture_output=True, timeout=30)
        return out_png.exists()
    except (subprocess.CalledProcessError, FileNotFoundError, subprocess.TimeoutExpired) as e:
        print(f"[r3t-bill] gnuplot failed: {e}", file=sys.stderr)
        return False


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--workload", choices=("t1", "t2"), required=True)
    ap.add_argument("--baseline", action="store_true")
    ap.add_argument("--rounds", type=int, default=3)
    ap.add_argument("--pane-ab", action="store_true",
                    help="M2 W-P1: pane-hop A/B (client hop armed in both arms)")
    args = ap.parse_args()
    rounds = 1 if args.baseline else args.rounds
    tag = ("paneab-" if args.pane_ab else "") + ("baseline-" if args.baseline else "")

    if not TMUX.exists():
        print(f"ERROR: worktree tmux not found at {TMUX}", file=sys.stderr)
        return 1
    if args.workload == "t2":
        if not NVIM.exists():
            print(f"ERROR: patched nvim not found at {NVIM}", file=sys.stderr)
            return 1
        build_fixture()

    rows: list[dict] = []
    for round_no in range(1, rounds + 1):
        if args.pane_ab:
            arms = ("paneoff", "paneon") if round_no % 2 == 1 else ("paneon", "paneoff")
        else:
            arms = ("unset", "oob") if round_no % 2 == 1 else ("oob", "unset")
        for arm in arms:
            print(f"[r3t-bill] {tag}{args.workload} round {round_no}/{rounds} arm={arm} ...", flush=True)
            row = run_row(args.workload, arm, round_no, tag)
            if not row.get("error"):
                check_identity(row, arm, patched=not args.baseline)
            rows.append(row)
            ft = row.get("ftrace", {})
            desc = (f"{ft.get('bytes_drained', 0) / 1e6:.1f}MB drained oob={ft.get('oob_drained', 0)}"
                    if not row.get("error") else row["error"])
            print(f"[r3t-bill]   -> {desc}", flush=True)
            time.sleep(1.0)

    with open(VERIFY_DIR / f"bill-{tag}{args.workload}-results.jsonl", "w") as f:
        for r in rows:
            f.write(json.dumps(r) + "\n")

    errors = [{k: r.get(k) for k in ("workload", "arm", "round", "error")}
              for r in rows if r.get("error")]
    summary: dict = {"workload": args.workload, "baseline": args.baseline,
                     "rounds": rounds, "errors": errors,
                     "loadavg_range": [min(r["load_before"] for r in rows),
                                       max(r.get("load_after", r["load_before"]) for r in rows)]}
    if not errors:
        if args.pane_ab:
            summary.update(analyze_pane(rows))
            summary["png"] = emit_png(summary, f"paneab-{args.workload}")
            summary["verdict"] = ("ALL-PASS" if all(g["pass"] for g in summary["gates"].values())
                                  else "GATE-MISS")
        else:
            summary.update(analyze(rows, args.workload))
            if not args.baseline:
                summary["png"] = emit_png(summary, args.workload)
                summary["verdict"] = ("ALL-PASS" if all(g["pass"] for g in summary["gates"].values())
                                      else "GATE-MISS")
            else:
                summary["verdict"] = "BASELINE-OK"
    else:
        summary["verdict"] = "ERROR"
    (VERIFY_DIR / f"bill-{tag}{args.workload}-summary.json").write_text(json.dumps(summary, indent=2))
    print(json.dumps({k: v for k, v in summary.items() if k != "means"}, indent=2))
    return 0 if summary["verdict"] in ("ALL-PASS", "BASELINE-OK") else (2 if summary["verdict"] == "GATE-MISS" else 1)


if __name__ == "__main__":
    raise SystemExit(main())
