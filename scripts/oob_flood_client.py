#!/usr/bin/env python3
"""Synthetic OOB flood client (R3 step-2 parser-ceiling probe).

Runs as the foreground child inside a harness kitty (spawn_kitty). Two arms:
  --arm pty : write the payload to fd 1 (the pty) — the 1024-byte kernel
              queue path, today's world; run with the OOB gate UNSET so this
              arm doubles as the no-socketpair world audit.
  --arm oob : KOOB1 handshake on $KITTY_TUI_OOB_FD, then flood the payload
              through the socketpair into kitty's second transport ring.

Timing note: a completed blocking write means the bytes left the client.
For the OOB arm the in-flight slack is bounded by SO_SNDBUF+RCVBUF (~2 MiB)
plus the 1 MiB transport ring plus the 1 MiB parse arena — under 2% of the
default 256 MiB payload — so sustained client-side write throughput tracks
the parser-side consumption ceiling. The kitty-side oob_stats line
(KITTY_OOB_STATS=1) cross-checks that every byte actually arrived.

Results go as one JSON object to $KITTY_OOB_RESULT_FILE.
"""

import argparse
import json
import os
import struct
import sys
import time

LINE_LEN = 100          # bytes per text line incl. newline (scroll-heavy, parser-representative)
BLOCK_TARGET = 4 * 1024 * 1024


def build_block() -> bytes:
    body = (b"abcdefghijklmnopqrstuvwxyz0123456789 " * 4)[: LINE_LEN - 1]
    line = body + b"\n"
    return line * max(1, BLOCK_TARGET // len(line))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--arm", choices=("pty", "oob"), required=True)
    ap.add_argument("--mib", type=int, default=256)
    args = ap.parse_args()

    total = args.mib * 1024 * 1024
    block = build_block()
    oob_env = os.environ.get("KITTY_TUI_OOB_FD")

    err = None
    if args.arm == "oob":
        if not oob_env:
            err = "KITTY_TUI_OOB_FD not set in the oob arm (gate not plumbed?)"
            fd = -1
        else:
            fd = int(oob_env)
            os.set_blocking(fd, True)
            hs = b"KOOB1\n" + struct.pack("<I", 0)
            n = os.write(fd, hs)
            assert n == len(hs)
    else:
        fd = 1

    written = 0
    elapsed = None
    if err is None:
        view = memoryview(block)
        t0 = time.monotonic()
        while written < total:
            chunk = view[: min(len(block), total - written)]
            try:
                written += os.write(fd, chunk)
            except OSError as e:
                err = f"write failed after {written} bytes: {e}"
                break
        elapsed = time.monotonic() - t0

    res = {
        "arm": args.arm,
        "requested_bytes": total,
        "bytes_written": written,
        "seconds": elapsed,
        "mb_per_s": (written / (1024 * 1024)) / elapsed if elapsed else None,
        "oob_env_present": oob_env is not None,
        "error": err,
    }
    out = os.environ.get("KITTY_OOB_RESULT_FILE")
    if out:
        with open(out, "w") as f:
            json.dump(res, f)
    else:
        print(json.dumps(res), file=sys.stderr)
    # let kitty drain the residual ring/arena before the window closes
    time.sleep(1.0)
    return 0 if err is None else 1


if __name__ == "__main__":
    raise SystemExit(main())
