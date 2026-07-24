#!/usr/bin/env python3.14
"""R3 step-2 gate probe: parser-side consumption ceiling through the OOB
channel vs the pty, using the synthetic flood client (oob_flood_client.py).

Arms (3 interleaved rounds each, plan §Implementation steps 2 / §Pre-mortem 3):
  pty : flood fd 1, OOB gate UNSET  — today's world + no-socketpair audit
  oob : flood KITTY_TUI_OOB_FD, KITTY_ENABLE_TUI_OOB=1 + KITTY_OOB_STATS=1

GATE (hard, from the approved plan): if oob_median < 2.0 * pty_median the
lane STOPs before any nvim patch. Target band: oob_median >= 300 MB/s.

Outputs under .omc/verify/r3/: per-round flood JSONs, kitty stderr logs
(oob_stats lines), results.jsonl, summary.json, r3-oob-probe.png (gnuplot).
"""

import json
import os
import statistics
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _kitty_harness_common as h

ROUNDS = 3
MIB = 256
SCRIPT_DIR = Path(__file__).resolve().parent
VERIFY_DIR = h.REPO_ROOT / ".omc" / "verify" / "r3"
CLIENT = SCRIPT_DIR / "oob_flood_client.py"
KITTY_EXIT_TIMEOUT = 180.0


def loadavg1() -> float:
    return os.getloadavg()[0]


def parse_oob_stats(text: str) -> dict | None:
    for line in reversed(text.splitlines()):
        if "oob_stats:" in line:
            fields = {}
            for tok in line.split("oob_stats:", 1)[1].split():
                if "=" in tok:
                    k, v = tok.split("=", 1)
                    try:
                        fields[k] = int(v)
                    except ValueError:
                        fields[k] = v
            return fields
    return None


def run_arm(arm: str, round_no: int) -> dict:
    h.wait_for_build_lock_clear()
    result_file = VERIFY_DIR / f"flood-{arm}-r{round_no}.json"
    stderr_file = VERIFY_DIR / f"kitty-{arm}-r{round_no}.stderr.log"
    result_file.unlink(missing_ok=True)

    env = {"KITTY_OOB_RESULT_FILE": str(result_file)}
    if arm == "oob":
        env["KITTY_ENABLE_TUI_OOB"] = "1"
        env["KITTY_OOB_STATS"] = "1"

    load_before = loadavg1()
    argv = ["python3.14", str(CLIENT), "--arm", arm, "--mib", str(MIB)]
    with open(stderr_file, "wb") as ef:
        proc = h.spawn_kitty(argv, extra_env=env, stderr=ef)
        try:
            proc.wait(timeout=KITTY_EXIT_TIMEOUT)
        except subprocess.TimeoutExpired:
            h.terminate_kitty(proc)
            return {"arm": arm, "round": round_no, "error": f"kitty did not exit within {KITTY_EXIT_TIMEOUT}s"}

    row: dict = {"arm": arm, "round": round_no, "load_before": load_before,
                 "load_degraded": load_before > 6.0}
    if not result_file.exists():
        row["error"] = "flood client wrote no result file"
        return row
    row.update(json.loads(result_file.read_text()))
    if arm == "oob":
        stats = parse_oob_stats(stderr_file.read_text(errors="replace"))
        row["kitty_oob_stats"] = stats
        if stats is None:
            row.setdefault("error", "no oob_stats line on kitty stderr")
        else:
            if stats.get("handshake_ok") != 1 or stats.get("fallbacks", 0) != 0:
                row.setdefault("error", f"bad channel state: {stats}")
            if stats.get("bytes_in") != row.get("bytes_written"):
                row.setdefault("error",
                               f"byte mismatch: client wrote {row.get('bytes_written')}, kitty ingested {stats.get('bytes_in')}")
    else:
        if row.get("oob_env_present"):
            row.setdefault("error", "KITTY_TUI_OOB_FD present in the gate-off world (audit FAIL)")
    return row


def emit_png(rows: list[dict], out_png: Path) -> bool:
    dat = VERIFY_DIR / "r3-oob-probe.dat"
    lines = []
    for i, arm in enumerate(("pty", "oob")):
        for r in rows:
            if r["arm"] == arm and r.get("mb_per_s"):
                lines.append(f"{i} {r['mb_per_s']:.2f} \"{arm}-r{r['round']}\"")
    dat.write_text("\n".join(lines) + "\n")
    gp = VERIFY_DIR / "r3-oob-probe.gp"
    gp.write_text(f"""set terminal pngcairo size 900,600 font 'Helvetica,12'
set output '{out_png}'
set title 'R3 OOB channel probe: parser-side consumption ceiling ({MIB} MiB text flood, {ROUNDS} rounds)'
set ylabel 'MB/s (client-side sustained write throughput)'
set xrange [-0.5:1.5]
set xtics ('pty (1024B kernel queue)' 0, 'oob (socketpair + 2nd ring)' 1)
set grid ytics
set boxwidth 0.3
plot '{dat}' using 1:2 with points pt 7 ps 2 lc rgb '#1f77b4' notitle, \\
     '{dat}' using 1:2:3 with labels offset 2,0.5 font ',9' notitle
""")
    try:
        subprocess.run(["gnuplot", str(gp)], check=True, capture_output=True, timeout=30)
        return out_png.exists()
    except (subprocess.CalledProcessError, FileNotFoundError, subprocess.TimeoutExpired) as e:
        print(f"[r3-probe] gnuplot PNG emission failed: {e}", file=sys.stderr)
        return False


def main() -> int:
    VERIFY_DIR.mkdir(parents=True, exist_ok=True)
    rows: list[dict] = []
    for round_no in range(1, ROUNDS + 1):
        for arm in ("pty", "oob"):
            print(f"[r3-probe] round {round_no}/{ROUNDS} arm={arm} ...", flush=True)
            row = run_arm(arm, round_no)
            rows.append(row)
            print(f"[r3-probe]   -> {row.get('mb_per_s') and f'{row['mb_per_s']:.1f} MB/s' or row.get('error')}", flush=True)
            time.sleep(1.0)

    with open(VERIFY_DIR / "results.jsonl", "w") as f:
        for r in rows:
            f.write(json.dumps(r) + "\n")

    errors = [r for r in rows if r.get("error")]
    pty = [r["mb_per_s"] for r in rows if r["arm"] == "pty" and r.get("mb_per_s")]
    oob = [r["mb_per_s"] for r in rows if r["arm"] == "oob" and r.get("mb_per_s")]
    summary: dict = {
        "mib_per_round": MIB, "rounds": ROUNDS,
        "pty_mbps": pty, "oob_mbps": oob,
        "pty_median": statistics.median(pty) if pty else None,
        "oob_median": statistics.median(oob) if oob else None,
        "errors": [{k: r[k] for k in ("arm", "round", "error")} for r in errors],
        "load_degraded": any(r.get("load_degraded") for r in rows),
    }
    if pty and oob:
        summary["speedup"] = summary["oob_median"] / summary["pty_median"]
        summary["gate_2x"] = summary["speedup"] >= 2.0
        summary["target_300"] = summary["oob_median"] >= 300.0
        summary["verdict"] = "GO" if summary["gate_2x"] else "STOP"
    else:
        summary["verdict"] = "ERROR"
    summary["png"] = emit_png(rows, VERIFY_DIR / "r3-oob-probe.png")

    (VERIFY_DIR / "summary.json").write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary, indent=2))
    return 0 if summary["verdict"] == "GO" else (2 if summary["verdict"] == "STOP" else 1)


if __name__ == "__main__":
    raise SystemExit(main())
