#!/usr/bin/env python3.14
"""R3 step-4 A/B: patched-nvim scroll replay, OOB on vs off, same binary.

Arms (3 interleaved rounds each):
  tty : OOB gate unset — nvim flushes to the pty (today's world)
  oob : KITTY_ENABLE_TUI_OOB=1 + KITTY_OOB_STATS=1 — flush_buf routes the
        rendered stream through the socketpair channel

Each round spawns a harness kitty (spawn_kitty: sanitized env, MonoLisaCode,
100c x 30c) whose foreground child is the patched nvim scrolling through a
syntax-highlighted C fixture with forced redraws (r3_replay.vim). The wall
time of the replay loop is the drain-wall metric (flush_buf blocks on the
transport, so redraw wall = render + drain).

Plan acceptance gate: oob wall >= 2.0x faster than tty wall. The kitty-side
oob_stats line cross-checks that the oob arm really routed its bytes
(bytes_in threshold) and never fell back (fallbacks=0).

Outputs under .omc/verify/r3/: nvim-ab-results.jsonl, nvim-ab-summary.json,
r3-nvim-ab.png (gnuplot).
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
SCRIPT_DIR = Path(__file__).resolve().parent
VERIFY_DIR = h.REPO_ROOT / ".omc" / "verify" / "r3"
REPLAY_VIM = SCRIPT_DIR / "r3_replay.vim"
FIXTURE = VERIFY_DIR / "fixture.c"
NVIM = Path("/Users/zchee/src/github.com/neovim/neovim/build/bin/nvim")
KITTY_EXIT_TIMEOUT = 300.0
MIN_OOB_BYTES = 20 * 1024 * 1024  # split-brain floor: the replay must route >= this much via OOB


def build_fixture() -> None:
    if FIXTURE.exists() and FIXTURE.stat().st_size > 2 * 1024 * 1024:
        return
    srcs = sorted((h.REPO_ROOT / "kitty").glob("*.c"))
    with open(FIXTURE, "w") as out:
        total = 0
        while total < 3 * 1024 * 1024:
            for s in srcs:
                text = s.read_text(errors="replace")
                out.write(text)
                total += len(text)
                if total >= 3 * 1024 * 1024:
                    break


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
    result_file = VERIFY_DIR / f"nvim-ab-{arm}-r{round_no}.json"
    stderr_file = VERIFY_DIR / f"kitty-nvim-{arm}-r{round_no}.stderr.log"
    result_file.unlink(missing_ok=True)

    env = {"NVIM_AB_RESULT": str(result_file)}
    if arm == "oob":
        env["KITTY_ENABLE_TUI_OOB"] = "1"
        env["KITTY_OOB_STATS"] = "1"

    argv = [str(NVIM), "--clean", "+source " + str(REPLAY_VIM), str(FIXTURE)]
    load_before = os.getloadavg()[0]
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
        row["error"] = "replay wrote no result file"
        return row
    row.update(json.loads(result_file.read_text()))
    stats = parse_oob_stats(stderr_file.read_text(errors="replace"))
    row["kitty_oob_stats"] = stats
    if arm == "oob":
        if stats is None:
            row.setdefault("error", "no oob_stats line on kitty stderr")
        else:
            if stats.get("handshake_ok") != 1 or stats.get("fallbacks", 0) != 0 or stats.get("broken", 0) != 0:
                row.setdefault("error", f"bad channel state: {stats}")
            elif stats.get("bytes_in", 0) < MIN_OOB_BYTES:
                row.setdefault("error", f"only {stats.get('bytes_in', 0)} bytes routed via OOB (arming failed?)")
    else:
        if row.get("oob_env"):
            row.setdefault("error", "KITTY_TUI_OOB_FD present in the gate-off arm (audit FAIL)")
    return row


def emit_png(rows: list[dict], out_png: Path) -> bool:
    dat = VERIFY_DIR / "r3-nvim-ab.dat"
    lines = []
    for i, arm in enumerate(("tty", "oob")):
        for r in rows:
            if r["arm"] == arm and r.get("seconds"):
                lines.append(f"{i} {r['seconds']:.3f} \"{arm}-r{r['round']}\"")
    dat.write_text("\n".join(lines) + "\n")
    gp = VERIFY_DIR / "r3-nvim-ab.gp"
    gp.write_text(f"""set terminal pngcairo size 900,600 font 'Helvetica,12'
set output '{out_png}'
set title 'R3 nvim A/B: full-fixture scroll replay wall (same patched binary, {ROUNDS} rounds)'
set ylabel 'replay wall seconds (lower is better)'
set xrange [-0.5:1.5]
set yrange [0:*]
set xtics ('tty (pty path)' 0, 'oob (bulk channel)' 1)
set grid ytics
plot '{dat}' using 1:2 with points pt 7 ps 2 lc rgb '#d62728' notitle, \\
     '{dat}' using 1:2:3 with labels offset 2,0.5 font ',9' notitle
""")
    try:
        subprocess.run(["gnuplot", str(gp)], check=True, capture_output=True, timeout=30)
        return out_png.exists()
    except (subprocess.CalledProcessError, FileNotFoundError, subprocess.TimeoutExpired) as e:
        print(f"[r3-nvim-ab] gnuplot PNG emission failed: {e}", file=sys.stderr)
        return False


def main() -> int:
    VERIFY_DIR.mkdir(parents=True, exist_ok=True)
    if not NVIM.exists():
        print(f"ERROR: patched nvim not found at {NVIM}", file=sys.stderr)
        return 1
    build_fixture()

    rows: list[dict] = []
    for round_no in range(1, ROUNDS + 1):
        for arm in ("tty", "oob"):
            print(f"[r3-nvim-ab] round {round_no}/{ROUNDS} arm={arm} ...", flush=True)
            row = run_arm(arm, round_no)
            rows.append(row)
            desc = f"{row['seconds']:.2f}s ({row.get('pages')} pages)" if row.get("seconds") else row.get("error")
            print(f"[r3-nvim-ab]   -> {desc}", flush=True)
            time.sleep(1.0)

    with open(VERIFY_DIR / "nvim-ab-results.jsonl", "w") as f:
        for r in rows:
            f.write(json.dumps(r) + "\n")

    errors = [r for r in rows if r.get("error")]
    tty = [r["seconds"] for r in rows if r["arm"] == "tty" and r.get("seconds")]
    oob = [r["seconds"] for r in rows if r["arm"] == "oob" and r.get("seconds")]
    summary: dict = {
        "rounds": ROUNDS,
        "tty_wall_s": tty, "oob_wall_s": oob,
        "tty_median_s": statistics.median(tty) if tty else None,
        "oob_median_s": statistics.median(oob) if oob else None,
        "errors": [{k: r.get(k) for k in ("arm", "round", "error")} for r in errors],
        "load_degraded": any(r.get("load_degraded") for r in rows),
    }
    if tty and oob and not errors:
        summary["speedup"] = summary["tty_median_s"] / summary["oob_median_s"]
        summary["gate_2x"] = summary["speedup"] >= 2.0
        summary["verdict"] = "PASS" if summary["gate_2x"] else "BELOW-GATE"
    else:
        summary["verdict"] = "ERROR"
    summary["png"] = emit_png(rows, VERIFY_DIR / "r3-nvim-ab.png")

    (VERIFY_DIR / "nvim-ab-summary.json").write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary, indent=2))
    return 0 if summary["verdict"] == "PASS" else (2 if summary["verdict"] == "BELOW-GATE" else 1)


if __name__ == "__main__":
    raise SystemExit(main())
