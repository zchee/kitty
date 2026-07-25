#!/usr/bin/env python3.14
"""R4 C-image cell driver: an icat-class graphics loop inside a harness kitty.

Drives the kitty graphics protocol via the built `kitten icat` so the
graphics-command path runs for real: PNG decode on the parse path, image
adds (which spawn the DiskCacheWrite thread — the M1d probe's disk-cache
row), and `remove_images` trims whenever the storage quota is exceeded
(the only maint site group C-image can plausibly exercise, plan §M0b).

Usage: r4_image_cell.py --seconds 60 --log OUT.log [--env K=V ...]
The ftrace/probe stderr of the kitty under test lands in --log.
"""
from __future__ import annotations

import argparse
import struct
import sys
import time
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from _kitty_harness_common import spawn_kitty, terminate_kitty  # noqa: E402


def write_png(path: Path, w: int = 512, h: int = 512, seed: int = 7) -> None:
    """Minimal valid 8-bit grayscale PNG with deterministic noise (no PIL)."""
    def chunk(tag: bytes, data: bytes) -> bytes:
        return (struct.pack(">I", len(data)) + tag + data +
                struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))
    x = seed
    rows = bytearray()
    for _ in range(h):
        rows.append(0)  # filter: None
        for _ in range(w):
            x = (1103515245 * x + 12345) & 0x7FFFFFFF
            rows.append(x & 0xFF)
    ihdr = struct.pack(">IIBBBBB", w, h, 8, 0, 0, 0, 0)
    png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) +
           chunk(b"IDAT", zlib.compress(bytes(rows), 6)) + chunk(b"IEND", b""))
    path.write_bytes(png)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--seconds", type=float, default=60.0)
    ap.add_argument("--log", type=Path, required=True)
    ap.add_argument("--images", type=int, default=8, help="distinct PNGs cycled (distinct ids -> storage growth)")
    ap.add_argument("--env", action="append", default=[], metavar="K=V")
    args = ap.parse_args()
    workdir = args.log.parent / (args.log.stem + ".imgs")
    workdir.mkdir(parents=True, exist_ok=True)
    for i in range(args.images):
        write_png(workdir / f"img{i}.png", seed=7 + i)
    # The child drives the graphics protocol directly (APC _G, transfer by
    # file path, f=100 = PNG): each add without an explicit id creates a NEW
    # image, so storage grows monotonically and the quota trim
    # (remove_images via add_trim_predicate) can genuinely fire; a periodic
    # a=d,d=A delete keeps placements bounded. No kitten binary needed —
    # dev builds do not ship one.
    script = (
        f'end=$(( $(date +%s) + {int(args.seconds)} ));'
        f'n=0;'
        f'while [ $(date +%s) -lt $end ]; do'
        f'  for i in $(seq 0 {args.images - 1}); do'
        f'    b64=$(printf %s "{workdir}/img$i.png" | base64);'
        f'    printf "\033_Ga=T,f=100,t=f;%s\033\\\\" "$b64";'
        f'    n=$((n+1));'
        f'    if [ $((n % 32)) -eq 0 ]; then printf "\033_Ga=d,d=A\033\\\\"; printf "\033[2J\033[H"; fi;'
        f'  done;'
        f'done'
    )
    extra_env = {k: v for k, _, v in (kv.partition("=") for kv in args.env) if k}
    lf = open(args.log, "w")
    t0 = time.monotonic()
    proc = spawn_kitty(argv_command=["/bin/sh", "-c", script], extra_env=extra_env, stderr=lf)
    deadline = t0 + args.seconds + 20.0
    while time.monotonic() < deadline and proc.poll() is None:
        time.sleep(0.5)
    terminate_kitty(proc)
    lf.close()
    print(f"[r4-image-cell] done wall={time.monotonic() - t0:.1f}s log={args.log}")


if __name__ == "__main__":
    main()
