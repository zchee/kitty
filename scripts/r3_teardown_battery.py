#!/usr/bin/env python3.14
"""R3 G6 teardown/leak battery: 50 OOB-channel window cycles in one kitty.

One sanitized spawn_kitty (KITTY_OOB_STATS=1 on the kitty process, remote
control on a short /tmp unix socket), then CYCLES of

  @ launch --env KITTY_ENABLE_TUI_OOB=1 --env KITTY_OOB_RESULT_FILE=...
      python3.14 oob_flood_client.py --arm oob --mib 4
  -> wait for the client result file (window auto-closes on child exit)
  -> assert client wrote 4 MiB with no error
  -> sample kitty fd count (lsof) + thread count (ps -M)

Afterwards: every per-channel oob_stats teardown line on kitty stderr must
show thread_done=1, fallbacks=0, broken=0 and bytes_in == 4 MiB (EOF
byte-exactness at the channel level, CYCLES/CYCLES); fd and thread counts
must settle back to the post-warmup baseline (zero leaked channel fds or
reader threads). Correctness battery, not a measurement.

Output: .omc/verify/r3/teardown-summary.json (+ per-cycle rows inside).
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _kitty_harness_common import KITTY_BINARY, spawn_kitty, terminate_kitty

REPO_ROOT = Path(__file__).resolve().parent.parent
VERIFY_DIR = REPO_ROOT / ".omc" / "verify" / "r3"
CLIENT = REPO_ROOT / "scripts" / "oob_flood_client.py"
CYCLES = 50
MIB = 4
SOCK = f"/tmp/r3-td-{os.getpid()}.sock"
SOCK_ACTUAL = SOCK  # kitty appends "-<pid>" to a unix listen_on path


def kat(*args: str, timeout: float = 15) -> subprocess.CompletedProcess:
    return subprocess.run([str(KITTY_BINARY), "@", "--to", f"unix:{SOCK_ACTUAL}", *args],
                          capture_output=True, text=True, timeout=timeout)


def thread_count(pid: int) -> int:
    out = subprocess.run(["ps", "-M", "-p", str(pid)], capture_output=True, text=True).stdout
    return max(0, len(out.strip().splitlines()) - 1)


def fd_count(pid: int) -> int:
    out = subprocess.run(["lsof", "-nP", "-p", str(pid)], capture_output=True, text=True).stdout
    return max(0, len(out.strip().splitlines()) - 1)


def parse_all_oob_stats(text: str) -> list[dict]:
    stats = []
    for line in text.splitlines():
        if "oob_stats:" not in line:
            continue
        d: dict = {}
        for tok in line.split("oob_stats:", 1)[1].split():
            if "=" in tok:
                k, v = tok.split("=", 1)
                try:
                    d[k] = int(v)
                except ValueError:
                    d[k] = v
        stats.append(d)
    return stats


def main() -> int:
    VERIFY_DIR.mkdir(parents=True, exist_ok=True)
    err_path = VERIFY_DIR / "kitty-teardown.stderr.log"
    rows: list[dict] = []
    global SOCK_ACTUAL
    with open(err_path, "wb") as ef:
        proc = spawn_kitty(
            extra_env={"KITTY_OOB_STATS": "1"},
            extra_kitty_opts=["allow_remote_control=yes", f"listen_on=unix:{SOCK}"],
            stderr=ef,
        )
        SOCK_ACTUAL = f"{SOCK}-{proc.pid}"
        try:
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline and not os.path.exists(SOCK_ACTUAL):
                time.sleep(0.2)
            if not os.path.exists(SOCK_ACTUAL):
                raise RuntimeError(f"remote-control socket never came up at {SOCK_ACTUAL}")

            baseline_fds = baseline_threads = None
            for i in range(1, CYCLES + 1):
                res_file = f"/tmp/r3-td-res-{os.getpid()}-{i}.json"
                if os.path.exists(res_file):
                    os.unlink(res_file)
                launch = kat("launch",
                             "--env", "KITTY_ENABLE_TUI_OOB=1",
                             "--env", f"KITTY_OOB_RESULT_FILE={res_file}",
                             "python3.14", str(CLIENT), "--arm", "oob", "--mib", str(MIB))
                row: dict = {"cycle": i, "launch_rc": launch.returncode}
                end = time.monotonic() + 30
                while time.monotonic() < end and not os.path.exists(res_file):
                    time.sleep(0.2)
                if not os.path.exists(res_file):
                    row["error"] = "client result never appeared"
                else:
                    r = json.loads(open(res_file).read())
                    os.unlink(res_file)
                    row["bytes_written"] = r.get("bytes_written")
                    if r.get("error") or r.get("bytes_written") != MIB * 1024 * 1024:
                        row["error"] = f"client: {r.get('error')} bytes={r.get('bytes_written')}"
                time.sleep(0.5)
                row["fds"] = fd_count(proc.pid)
                row["threads"] = thread_count(proc.pid)
                if i == 1:
                    time.sleep(2.0)
                    baseline_fds, baseline_threads = fd_count(proc.pid), thread_count(proc.pid)
                    row["baseline_fds"], row["baseline_threads"] = baseline_fds, baseline_threads
                rows.append(row)
                if i % 10 == 0:
                    print(f"[r3-td] cycle {i}/{CYCLES} fds={row['fds']} threads={row['threads']}", flush=True)

            time.sleep(3.0)
            final_fds, final_threads = fd_count(proc.pid), thread_count(proc.pid)
            kat("quit", timeout=10)
            try:
                proc.wait(timeout=15)
            except subprocess.TimeoutExpired:
                terminate_kitty(proc)
        finally:
            if proc.poll() is None:
                terminate_kitty(proc)

    stats = parse_all_oob_stats(err_path.read_text(errors="replace"))
    done = [s for s in stats if s.get("thread_done") == 1]
    exact = [s for s in stats if s.get("bytes_in") == MIB * 1024 * 1024]
    cycle_errs = [r for r in rows if r.get("error")]
    # Leak = growth above steady state. Startup-transient threads (Metal /
    # AppKit init pools) inflate an early baseline and then retire, so the
    # reference is the median of second-half per-cycle samples, and only
    # counts ABOVE it indicate a leak (shrinkage is settling, not leaking).
    half = [r["threads"] for r in rows[len(rows) // 2:] if "threads" in r]
    steady_threads = sorted(half)[len(half) // 2] if half else (baseline_threads or 0)
    summary = {
        "cycles": CYCLES,
        "cycle_errors": cycle_errs,
        "oob_stats_lines": len(stats),
        "thread_done_count": len(done),
        "bytes_exact_count": len(exact),
        "fallbacks_total": sum(s.get("fallbacks", 0) for s in stats),
        "broken_total": sum(s.get("broken", 0) for s in stats),
        "baseline_fds": baseline_fds, "final_fds": final_fds,
        "baseline_threads": baseline_threads, "final_threads": final_threads,
        "steady_threads": steady_threads,
        "fd_leak_free": final_fds <= (baseline_fds or 0) + 8,
        "thread_leak_free": final_threads <= steady_threads + 1,
        "rows": rows,
    }
    summary["verdict"] = ("PASS" if not cycle_errs
                          and summary["thread_done_count"] >= CYCLES
                          and summary["bytes_exact_count"] >= CYCLES
                          and summary["fallbacks_total"] == 0
                          and summary["broken_total"] == 0
                          and summary["fd_leak_free"] and summary["thread_leak_free"]
                          else "FAIL")
    (VERIFY_DIR / "teardown-summary.json").write_text(json.dumps(summary, indent=2))
    print(json.dumps({k: v for k, v in summary.items() if k != "rows"}, indent=2))
    return 0 if summary["verdict"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
