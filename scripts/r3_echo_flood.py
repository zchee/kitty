#!/usr/bin/env python3.14
"""R3 W-B echo battery: DSR RTT under flood, {tty, oob} x {idle, paced, unpaced}.

Redefined-acceptance battery (plan W-B): the synthetic client
(oob_flood_client.py --ping) floods bulk through {pty | oob} while a second
thread round-trips ESC[6n on the tty every 20 ms. In the pty arm the ping
request shares the 1024 B tty output queue with the flood; in the oob arm
the tty queue carries only pings. Cells:

  idle    — no flood; channel armed in the oob arm (Gz core parity gate)
  paced   — 6 MB/s flood (nvim-representative rate; G5 label gate)
  unpaced — full-rate flood (observational)

2 passes x 2 arms per cell, interleaved with rotated order (DSR doctrine:
n >= 500 post-warmup RTTs per arm+cell, 20-sample warmup drop per pass,
chronological plot for non-stationarity, means+quantiles never medians
alone).

Gates: Gz idle |delta p50| < 0.3 ms (core). G5 paced p50(oob) <=
p50(tty) - 0.3 ms AND p99(oob) <= p99(tty) (labels INTERACTIVITY-CLAIMED
only). Outputs under .omc/verify/r3/: echo-results.jsonl,
echo-summary.json, r3-echo.png, r3-echo-chrono.png.
"""

from __future__ import annotations

import json
import os
import statistics
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _kitty_harness_common as h
from r3_nvim_ab import parse_oob_stats

PASSES = 2
DURATION_S = 15.0
WARMUP_DROP = 20
VERIFY_DIR = h.REPO_ROOT / ".omc" / "verify" / "r3"
CELLS = {"idle": ["--idle"], "paced": ["--pace-mbs", "6"], "unpaced": []}
CLIENT = str(h.REPO_ROOT / "scripts" / "oob_flood_client.py")


def run_row(cell: str, arm: str, pass_no: int) -> dict:
    h.wait_for_build_lock_clear()
    result_file = VERIFY_DIR / f"echo-{cell}-{arm}-p{pass_no}.json"
    stderr_file = VERIFY_DIR / f"kitty-echo-{cell}-{arm}-p{pass_no}.stderr.log"
    result_file.unlink(missing_ok=True)
    env = {"KITTY_OOB_RESULT_FILE": str(result_file)}
    if arm == "oob":
        env["KITTY_ENABLE_TUI_OOB"] = "1"
        env["KITTY_OOB_STATS"] = "1"
    argv = ["python3.14", CLIENT, "--arm", "pty" if arm == "tty" else "oob",
            "--ping", "--duration-s", str(DURATION_S)] + CELLS[cell]
    row: dict = {"cell": cell, "battery_arm": arm, "pass": pass_no,
                 "load_before": os.getloadavg()[0]}
    with open(stderr_file, "wb") as ef:
        proc = h.spawn_kitty(argv, extra_env=env, stderr=ef)
        try:
            proc.wait(timeout=DURATION_S + 60)
        except subprocess.TimeoutExpired:
            h.terminate_kitty(proc)
            row["error"] = "timeout (deadlock?)"
            return row
    if not result_file.exists():
        row["error"] = "no client result"
        return row
    row.update(json.loads(result_file.read_text()))
    stats = parse_oob_stats(stderr_file.read_text(errors="replace"))
    row["oob_stats"] = stats
    rtts = row.get("rtt_ns", [])
    row["rtt_post_warmup"] = rtts[WARMUP_DROP:]
    if arm == "oob":
        if stats is None or stats.get("handshake_ok") != 1 or stats.get("fallbacks", 0) != 0 or stats.get("broken", 0) != 0:
            row.setdefault("error", f"bad channel state: {stats}")
        if cell != "idle" and (stats or {}).get("bytes_in", 0) <= 0:
            row.setdefault("error", "identity FAIL: oob flood cell with bytes_in == 0")
    else:
        if row.get("oob_env_present"):
            row.setdefault("error", "KITTY_TUI_OOB_FD present in gate-off arm")
    if row.get("ping_timeouts", 1) != 0:
        row.setdefault("error", f"{row.get('ping_timeouts')} ping timeouts")
    if len(row["rtt_post_warmup"]) < 250:
        row.setdefault("error", f"only {len(row['rtt_post_warmup'])} post-warmup RTTs")
    return row


def q(vals: list[int], frac: float) -> float:
    s = sorted(vals)
    return s[min(len(s) - 1, int(frac * len(s)))] / 1e6


def cell_stats(rows: list[dict], cell: str, arm: str) -> dict:
    rtts = [x for r in rows
            if r["cell"] == cell and r["battery_arm"] == arm and not r.get("error")
            for x in r["rtt_post_warmup"]]
    return {"n": len(rtts), "mean_ms": statistics.fmean(rtts) / 1e6 if rtts else float("nan"),
            "p50_ms": q(rtts, 0.50) if rtts else float("nan"),
            "p90_ms": q(rtts, 0.90) if rtts else float("nan"),
            "p99_ms": q(rtts, 0.99) if rtts else float("nan"),
            "max_ms": max(rtts) / 1e6 if rtts else float("nan")}


def emit_pngs(summary: dict, rows: list[dict]) -> bool:
    dat = VERIFY_DIR / "r3-echo.dat"
    lines = []
    for i, cell in enumerate(CELLS):
        for j, arm in enumerate(("tty", "oob")):
            s = summary["cells"][cell][arm]
            lines.append(f'{i * 3 + j} {s["p50_ms"]:.4f} {s["p99_ms"]:.4f} "{cell}-{arm}"')
    dat.write_text("\n".join(lines) + "\n")
    gp = VERIFY_DIR / "r3-echo.gp"
    gp.write_text(f"""set terminal pngcairo size 1000,620 font 'Helvetica,12'
set output '{VERIFY_DIR / "r3-echo.png"}'
set title 'R3 W-B echo: DSR RTT under flood ({PASSES} passes x {DURATION_S:.0f}s, 20ms cadence, post-warmup)'
set ylabel 'RTT ms'
set grid ytics
set boxwidth 0.35
set style fill solid 0.5
set yrange [0:*]
plot '{dat}' using 1:2:xtic(4) with boxes lc rgb '#1f77b4' title 'p50', \\
     '{dat}' using 1:3 with points pt 7 ps 1.5 lc rgb '#d62728' title 'p99'
""")
    chrono = VERIFY_DIR / "r3-echo-chrono.dat"
    clines = []
    for r in rows:
        if r.get("error"):
            continue
        base = {"tty": 0, "oob": 1}[r["battery_arm"]]
        for k, v in enumerate(r["rtt_post_warmup"]):
            clines.append(f'{k} {v / 1e6:.4f} {base} "{r["cell"]}"')
    chrono.write_text("\n".join(clines) + "\n")
    gp2 = VERIFY_DIR / "r3-echo-chrono.gp"
    gp2.write_text(f"""set terminal pngcairo size 1200,620 font 'Helvetica,12'
set output '{VERIFY_DIR / "r3-echo-chrono.png"}'
set title 'R3 W-B echo: chronological RTT (all cells/passes; non-stationarity check)'
set xlabel 'sample index within pass'
set ylabel 'RTT ms'
set grid ytics
plot '{chrono}' using 1:($3 == 0 ? $2 : 1/0) with points pt 0 lc rgb '#1f77b4' title 'tty', \\
     '{chrono}' using 1:($3 == 1 ? $2 : 1/0) with points pt 0 lc rgb '#d62728' title 'oob'
""")
    try:
        subprocess.run(["gnuplot", str(gp)], check=True, capture_output=True, timeout=30)
        subprocess.run(["gnuplot", str(gp2)], check=True, capture_output=True, timeout=30)
        return (VERIFY_DIR / "r3-echo.png").exists() and (VERIFY_DIR / "r3-echo-chrono.png").exists()
    except (subprocess.CalledProcessError, FileNotFoundError, subprocess.TimeoutExpired) as e:
        print(f"[r3-echo] gnuplot failed: {e}", file=sys.stderr)
        return False


def main() -> int:
    VERIFY_DIR.mkdir(parents=True, exist_ok=True)
    rows: list[dict] = []
    for pass_no in range(1, PASSES + 1):
        arms = ("tty", "oob") if pass_no % 2 == 1 else ("oob", "tty")
        for cell in CELLS:
            for arm in arms:
                print(f"[r3-echo] pass {pass_no}/{PASSES} cell={cell} arm={arm} ...", flush=True)
                row = run_row(cell, arm, pass_no)
                rows.append(row)
                n = len(row.get("rtt_post_warmup", []))
                print(f"[r3-echo]   -> n={n} err={row.get('error')}", flush=True)
                time.sleep(1.0)

    with open(VERIFY_DIR / "echo-results.jsonl", "w") as f:
        for r in rows:
            slim = {k: v for k, v in r.items() if k != "rtt_ns"}
            f.write(json.dumps(slim) + "\n")

    errors = [{k: r.get(k) for k in ("cell", "battery_arm", "pass", "error")}
              for r in rows if r.get("error")]
    summary: dict = {"passes": PASSES, "duration_s": DURATION_S, "errors": errors,
                     "loadavg_range": [min(r["load_before"] for r in rows),
                                       max(r["load_before"] for r in rows)]}
    if not errors:
        summary["cells"] = {c: {a: cell_stats(rows, c, a) for a in ("tty", "oob")} for c in CELLS}
        idle_t, idle_o = summary["cells"]["idle"]["tty"], summary["cells"]["idle"]["oob"]
        paced_t, paced_o = summary["cells"]["paced"]["tty"], summary["cells"]["paced"]["oob"]
        summary["Gz_idle_parity"] = {
            "dp50_ms": idle_o["p50_ms"] - idle_t["p50_ms"], "gate_abs_ms": 0.3,
            "pass": abs(idle_o["p50_ms"] - idle_t["p50_ms"]) < 0.3}
        summary["G5_flood_win"] = {
            "dp50_ms": paced_t["p50_ms"] - paced_o["p50_ms"],
            "p99_ratio": paced_o["p99_ms"] / paced_t["p99_ms"],
            "claimed": (paced_o["p50_ms"] <= paced_t["p50_ms"] - 0.3
                        and paced_o["p99_ms"] <= paced_t["p99_ms"])}
        summary["png"] = emit_pngs(summary, rows)
        summary["verdict"] = "GZ-PASS" if summary["Gz_idle_parity"]["pass"] else "GZ-MISS"
    else:
        summary["verdict"] = "ERROR"
    (VERIFY_DIR / "echo-summary.json").write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary, indent=2))
    return 0 if summary["verdict"] == "GZ-PASS" else (2 if summary["verdict"] == "GZ-MISS" else 1)


if __name__ == "__main__":
    raise SystemExit(main())
