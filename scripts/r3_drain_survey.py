#!/usr/bin/env python3.14
"""R3 W-D drain-bound real-workload survey (discovery, bounded, not a gate).

Pre-registered definition (plan W-D): a workload is drain-bound iff its
2-round screen shows oob/tty wall ratio <= 0.77 (>= 1.3x win) OR sustained
pty-arm kitty-side ingest rate >= 20 MB/s. Candidates are nvim-hosted only
(nvim is the only patched client):

  term_cat     — :terminal cat <100 MB text file> (inner passthrough)
  term_flood   — :terminal python3.14 <flood generator> (~100 MB)
  scroll_nosyn — 3-loop full-fixture scroll with syntax OFF (raw grid rate)
  subst        — 30x global :%s toggle churn with forced redraws
  paste        — whole-fixture yank + 8 appended pastes with redraws

2 rounds x {tty, oob}, rotated order, KITTY_FRAME_TRACE for kitty-side
bytes (SUM of per-tick `bytes=`) and oob identity (SUM oob_drained).
Outcome FOUND/NOT-FOUND per candidate; drivers: scripts/r3_survey.vim.
Outputs: .omc/verify/r3/survey-results.jsonl, survey-summary.json,
r3-survey.png.
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
from r3_bill_battery import ftrace_sums
from r3_nvim_ab import FIXTURE, NVIM, build_fixture, parse_oob_stats

ROUNDS = 2
VERIFY_DIR = h.REPO_ROOT / ".omc" / "verify" / "r3"
SURVEY_VIM = h.REPO_ROOT / "scripts" / "r3_survey.vim"
CANDIDATES = ("term_cat", "term_flood", "scroll_nosyn", "subst", "paste")
ROW_TIMEOUT = 240.0
BIG_FILE = Path("/tmp/r3-survey-big.txt")
GEN_FILE = Path("/tmp/r3-survey-gen.py")


def build_inputs() -> None:
    if not BIG_FILE.exists() or BIG_FILE.stat().st_size < 100 * 1024 * 1024:
        line = (b"abcdefghijklmnopqrstuvwxyz0123456789 " * 3)[:99] + b"\n"
        with open(BIG_FILE, "wb") as f:
            for _ in range(1_048_576):
                f.write(line)
    GEN_FILE.write_text(
        "import sys\n"
        "line = ('abcdefghijklmnopqrstuvwxyz0123456789 ' * 3)[:99] + '\\n'\n"
        "w = sys.stdout.write\n"
        "for _ in range(1_048_576): w(line)\n")


def run_row(cand: str, arm: str, round_no: int) -> dict:
    h.wait_for_build_lock_clear()
    result_file = VERIFY_DIR / f"survey-{cand}-{arm}-r{round_no}.json"
    stderr_file = VERIFY_DIR / f"kitty-survey-{cand}-{arm}-r{round_no}.stderr.log"
    result_file.unlink(missing_ok=True)
    env = {"NVIM_AB_RESULT": str(result_file), "NVIM_SURVEY_MODE": cand,
           "NVIM_SURVEY_FILE": str(BIG_FILE), "NVIM_SURVEY_GEN": str(GEN_FILE),
           "KITTY_FRAME_TRACE": "1"}
    if arm == "oob":
        env["KITTY_ENABLE_TUI_OOB"] = "1"
        env["KITTY_OOB_STATS"] = "1"
    argv = [str(NVIM), "--clean", "+source " + str(SURVEY_VIM), str(FIXTURE)]
    row: dict = {"cand": cand, "battery_arm": arm, "round": round_no,
                 "load_before": os.getloadavg()[0]}
    with open(stderr_file, "wb") as ef:
        proc = h.spawn_kitty(argv, extra_env=env, stderr=ef)
        try:
            proc.wait(timeout=ROW_TIMEOUT)
        except subprocess.TimeoutExpired:
            h.terminate_kitty(proc)
            row["error"] = f"timeout {ROW_TIMEOUT}s"
            return row
    if not result_file.exists():
        row["error"] = "no result file"
        return row
    row.update(json.loads(result_file.read_text()))
    text = stderr_file.read_text(errors="replace")
    row["ftrace"] = ftrace_sums(text)
    row["oob_stats"] = parse_oob_stats(text)
    if arm == "oob":
        st = row["oob_stats"]
        if st is None or st.get("handshake_ok") != 1 or st.get("fallbacks", 0) != 0:
            row.setdefault("error", f"bad channel state: {st}")
        if row["ftrace"]["oob_drained"] == 0:
            row.setdefault("error", "identity FAIL: oob row drained nothing via OOB")
    elif row["ftrace"]["oob_drained"] != 0:
        row.setdefault("error", "identity FAIL: tty row with oob bytes")
    row["ingest_mb_s"] = (row["ftrace"]["bytes_drained"] / (1024 * 1024)) / row["seconds"]
    return row


def main() -> int:
    VERIFY_DIR.mkdir(parents=True, exist_ok=True)
    if not NVIM.exists():
        print(f"ERROR: patched nvim not found at {NVIM}", file=sys.stderr)
        return 1
    build_fixture()
    build_inputs()

    rows: list[dict] = []
    for round_no in range(1, ROUNDS + 1):
        arms = ("tty", "oob") if round_no % 2 == 1 else ("oob", "tty")
        for cand in CANDIDATES:
            for arm in arms:
                print(f"[r3-survey] r{round_no} {cand} arm={arm} ...", flush=True)
                row = run_row(cand, arm, round_no)
                rows.append(row)
                print(f"[r3-survey]   -> {row.get('seconds', 0):.2f}s"
                      f" ingest={row.get('ingest_mb_s', 0):.1f}MB/s err={row.get('error')}", flush=True)
                time.sleep(1.0)

    with open(VERIFY_DIR / "survey-results.jsonl", "w") as f:
        for r in rows:
            f.write(json.dumps(r) + "\n")

    cands: dict = {}
    for cand in CANDIDATES:
        ok = [r for r in rows if r["cand"] == cand and not r.get("error")]
        tty = [r["seconds"] for r in ok if r["battery_arm"] == "tty"]
        oob = [r["seconds"] for r in ok if r["battery_arm"] == "oob"]
        rate = [r["ingest_mb_s"] for r in ok if r["battery_arm"] == "tty"]
        c = {"tty_wall_s": tty, "oob_wall_s": oob,
             "pty_ingest_mb_s": statistics.fmean(rate) if rate else None,
             "errors": [r.get("error") for r in rows if r["cand"] == cand and r.get("error")]}
        if tty and oob:
            c["wall_ratio"] = statistics.fmean(oob) / statistics.fmean(tty)
            c["drain_bound"] = c["wall_ratio"] <= 0.77 or (c["pty_ingest_mb_s"] or 0) >= 20.0
        cands[cand] = c

    found = [k for k, v in cands.items() if v.get("drain_bound")]
    summary = {"rounds": ROUNDS, "candidates": cands, "found": found,
               "verdict": "FOUND" if found else "NOT-FOUND",
               "loadavg_range": [min(r["load_before"] for r in rows),
                                 max(r["load_before"] for r in rows)]}

    dat = VERIFY_DIR / "r3-survey.dat"
    dat.write_text("\n".join(
        f'{i} {cands[c].get("wall_ratio", float("nan")):.4f} {cands[c].get("pty_ingest_mb_s") or 0:.1f} "{c}"'
        for i, c in enumerate(CANDIDATES)) + "\n")
    gp = VERIFY_DIR / "r3-survey.gp"
    gp.write_text(f"""set terminal pngcairo size 1000,620 font 'Helvetica,12'
set output '{VERIFY_DIR / "r3-survey.png"}'
set title 'R3 W-D drain-bound survey: oob/tty wall ratio per candidate ({ROUNDS} rounds)'
set ylabel 'oob / tty wall ratio'
set y2label 'pty ingest MB/s'
set ytics nomirror
set y2tics
set grid ytics
set boxwidth 0.4
set style fill solid 0.5
set yrange [0:1.3]
plot '{dat}' using 1:2:xtic(4) with boxes lc rgb '#1f77b4' title 'wall ratio', \\
     0.77 with lines dt 2 lc rgb '#d62728' title 'drain-bound bar (0.77)', \\
     '{dat}' using 1:3 axes x1y2 with points pt 7 ps 1.5 lc rgb '#2ca02c' title 'pty MB/s (y2)'
""")
    try:
        subprocess.run(["gnuplot", str(gp)], check=True, capture_output=True, timeout=30)
        summary["png"] = (VERIFY_DIR / "r3-survey.png").exists()
    except (subprocess.CalledProcessError, FileNotFoundError, subprocess.TimeoutExpired):
        summary["png"] = False

    (VERIFY_DIR / "survey-summary.json").write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
