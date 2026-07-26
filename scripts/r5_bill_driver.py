#!/usr/bin/env python3.14
"""R5 Q-bill driver: kitty lifetime CPU per delivered MiB, armed vs unset.

Contention detector for the QoS promotion (plan v2 pre-mortem 3, CPU
side): a 200 MiB pty flood per row, alternating unset/armed, ftrace ON
in BOTH arms (KITTY_FRAME_TRACE=1 — instrument-env parity; only
KITTY_THREAD_QOS differs). R4-VERDICT deviation #1 methodology: the
frozen R3 fixture (r3_bill_battery.py) has no arm/env hooks and its
purpose-built replacement was never committed, so this is the committed,
reusable driver.

Bill = kitty lifetime CPU (proc_pid_rusage user+system, _r3_rusage) /
delivered MiB (client-reported bytes_written). The rusage snap is taken
the moment the client's result file appears — the client sleeps 1 s
before exiting, which leaves a safe window to sample the still-running
kitty. Identical treatment in both arms, so the residual-drain second is
priced equally. Gate (frozen): mean bill(armed)/mean bill(unset) <= 1.02.
"""

from __future__ import annotations

import argparse
import json
import os
import statistics
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _kitty_harness_common as h
import _r3_rusage as rusage
from r5_echo_probe import binary_shas

VERIFY_DIR = h.REPO_ROOT / ".omc" / "verify" / "r5" / "results"
CLIENT = str(h.REPO_ROOT / "scripts" / "oob_flood_client.py")


def run_row(arm: str, row_no: int, mib: int, tag: str) -> dict:
    h.wait_for_build_lock_clear()
    VERIFY_DIR.mkdir(parents=True, exist_ok=True)
    result_file = VERIFY_DIR / f"bill-{tag}-{arm}-r{row_no}.client.json"
    stderr_file = VERIFY_DIR / f"bill-{tag}-{arm}-r{row_no}.stderr.log"
    result_file.unlink(missing_ok=True)
    env = {"KITTY_OOB_RESULT_FILE": str(result_file), "KITTY_QOS_DEBUG": "1",
           "KITTY_FRAME_TRACE": "1"}
    if arm == "armed":
        env["KITTY_THREAD_QOS"] = "1"
    argv = ["python3.14", CLIENT, "--arm", "pty", "--mib", str(mib)]
    row: dict = {"arm": arm, "row": row_no, "mib_requested": mib,
                 "load_before": os.getloadavg()[0],
                 "wave26_default_inherited": True, **binary_shas()}
    with open(stderr_file, "wb") as ef:
        proc = h.spawn_kitty(argv, extra_env=env, stderr=ef)
        deadline = time.monotonic() + 600
        snap = None
        while time.monotonic() < deadline:
            if result_file.exists():
                try:
                    snap = rusage.snap(proc.pid)
                except Exception as e:  # kitty already gone: row invalid
                    row["error"] = f"rusage snap failed: {e}"
                break
            if proc.poll() is not None:
                row["error"] = "kitty exited before client result"
                break
            time.sleep(0.05)
        else:
            row["error"] = "timeout waiting for client result"
        try:
            proc.wait(timeout=30)
        except subprocess.TimeoutExpired:
            h.terminate_kitty(proc)
    if row.get("error"):
        return row
    res = json.loads(result_file.read_text())
    if res.get("error"):
        row["error"] = res["error"]
        return row
    delivered_mib = res.get("bytes_written", 0) / (1024 * 1024)
    if delivered_mib <= 0:
        row["error"] = "zero bytes delivered"
        return row
    row["cpu_ms"] = snap["cpu_ns"] / 1e6
    row["delivered_mib"] = delivered_mib
    row["bill_cpu_ms_per_mib"] = row["cpu_ms"] / delivered_mib
    row["wakeups"] = snap.get("wakeups")
    row["seconds"] = res.get("seconds")
    row["mb_per_s"] = res.get("mb_per_s")
    return row


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--rows", type=int, default=3, help="rows per arm")
    ap.add_argument("--mib", type=int, default=200)
    ap.add_argument("--tag", default="run")
    args = ap.parse_args()

    out: dict = {"mib": args.mib, "rows_per_arm": args.rows, "rows": []}
    for i in range(args.rows):
        for arm in ("unset", "armed"):  # alternate inside each pair
            print(f"bill row {i + 1}/{args.rows} arm={arm}", file=sys.stderr)
            out["rows"].append(run_row(arm, i + 1, args.mib, args.tag))

    ok = lambda a: [r["bill_cpu_ms_per_mib"] for r in out["rows"]
                    if r["arm"] == a and not r.get("error")]
    unset, armed = ok("unset"), ok("armed")
    if len(unset) == args.rows and len(armed) == args.rows:
        out["mean_bill_unset"] = statistics.fmean(unset)
        out["mean_bill_armed"] = statistics.fmean(armed)
        out["bill_ratio"] = out["mean_bill_armed"] / out["mean_bill_unset"]
    else:
        out["error"] = "invalid rows present; ratio not computed"

    dest = VERIFY_DIR / f"bill-{args.tag}-summary.json"
    dest.write_text(json.dumps(out, indent=1))
    print(json.dumps(out, indent=1))
    print(f"wrote {dest}", file=sys.stderr)
    return 1 if out.get("error") else 0


if __name__ == "__main__":
    raise SystemExit(main())
