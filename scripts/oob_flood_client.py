#!/usr/bin/env python3
"""Synthetic OOB flood client (R3 step-2 parser-ceiling probe + W-B echo).

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

W-B echo mode (R3 acceptance redefinition): --ping runs a second thread
that writes ESC[6n to the tty every --ping-interval-ms and times the CPR
reply on stdin (cbreak). In the pty arm the request contends with the flood
for the same 1024 B tty output queue; in the oob arm the tty queue carries
only pings — that contention delta IS the measured mechanism. --duration-s
switches the flood from a fixed byte total to a deadline loop, --pace-mbs
caps flood throughput (64 KiB chunks, nvim-like frame cadence), --idle
skips the flood entirely (Gz parity cell).

Results go as one JSON object to $KITTY_OOB_RESULT_FILE.
"""

import argparse
import json
import os
import select
import struct
import sys
import threading
import time

LINE_LEN = 100          # bytes per text line incl. newline (scroll-heavy, parser-representative)
BLOCK_TARGET = 4 * 1024 * 1024
PACED_CHUNK = 64 * 1024


def build_block() -> bytes:
    body = (b"abcdefghijklmnopqrstuvwxyz0123456789 " * 4)[: LINE_LEN - 1]
    line = body + b"\n"
    return line * max(1, BLOCK_TARGET // len(line))


def ping_loop(stop: threading.Event, interval_s: float, rtts: list[int], misc: dict) -> None:
    import termios
    import tty as tty_mod

    old = termios.tcgetattr(0)
    tty_mod.setcbreak(0)
    try:
        while not stop.is_set():
            t0 = time.monotonic_ns()
            os.write(1, b"\x1b[6n")
            got = False
            deadline = time.monotonic() + 2.0
            while time.monotonic() < deadline:
                r, _, _ = select.select([0], [], [], 0.25)
                if not r:
                    continue
                data = os.read(0, 256)
                if b"R" in data:
                    got = True
                    break
            if got:
                rtts.append(time.monotonic_ns() - t0)
            else:
                misc["timeouts"] += 1
            stop.wait(interval_s)
    finally:
        termios.tcsetattr(0, termios.TCSADRAIN, old)


def flood(fd: int, block: bytes, total: int, duration_s: float | None,
          pace_mbs: float | None) -> tuple[int, float, str | None]:
    written = 0
    err = None
    chunk_len = PACED_CHUNK if pace_mbs else len(block)
    view = memoryview(block)
    t0 = time.monotonic()
    deadline = t0 + duration_s if duration_s else None
    while True:
        now = time.monotonic()
        if deadline is not None:
            if now >= deadline:
                break
        elif written >= total:
            break
        off = written % len(block) if deadline is not None else 0
        end = min(off + chunk_len, len(block))
        if deadline is None:
            end = min(end, off + total - written)
        try:
            written += os.write(fd, view[off:end])
        except OSError as e:
            err = f"write failed after {written} bytes: {e}"
            break
        if pace_mbs:
            expect = written / (pace_mbs * 1024 * 1024)
            ahead = expect - (time.monotonic() - t0)
            if ahead > 0:
                time.sleep(min(ahead, 0.05))
    return written, time.monotonic() - t0, err


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--arm", choices=("pty", "oob"), required=True)
    ap.add_argument("--mib", type=int, default=256)
    ap.add_argument("--ping", action="store_true")
    ap.add_argument("--ping-interval-ms", type=float, default=20.0)
    ap.add_argument("--duration-s", type=float, default=None)
    ap.add_argument("--pace-mbs", type=float, default=None)
    ap.add_argument("--idle", action="store_true")
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

    rtts: list[int] = []
    misc = {"timeouts": 0}
    stop = threading.Event()
    pinger = None
    if args.ping and err is None:
        pinger = threading.Thread(target=ping_loop,
                                  args=(stop, args.ping_interval_ms / 1000.0, rtts, misc),
                                  daemon=True)
        pinger.start()

    written = 0
    elapsed = None
    if err is None and not args.idle:
        written, elapsed, err = flood(fd, block, total, args.duration_s, args.pace_mbs)
    elif args.idle and args.duration_s:
        time.sleep(args.duration_s)

    if pinger is not None:
        stop.set()
        pinger.join(timeout=5.0)

    res = {
        "arm": args.arm,
        "requested_bytes": total if args.duration_s is None else None,
        "bytes_written": written,
        "seconds": elapsed,
        "mb_per_s": (written / (1024 * 1024)) / elapsed if elapsed else None,
        "oob_env_present": oob_env is not None,
        "error": err,
    }
    if args.ping:
        res.update({"ping_count": len(rtts), "ping_timeouts": misc["timeouts"],
                    "ping_interval_ms": args.ping_interval_ms, "rtt_ns": rtts})
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
