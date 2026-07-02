#!/usr/bin/env python3.14
"""Internal helper for scripts/metal-baseline.py -- not a standalone tool.

Times N sequential `cat FIXTURE` runs and writes a JSON summary of the raw
per-run wall-clock samples to OUT_PATH.

This is invoked by metal-baseline.py (run_in_kitty(), _kitty_harness_common.py)
as the foreground command of a live kitty window; that wrapper redirects
THIS PROCESS's own stdout/stderr (fd 1/2) to a capture file via a shell
`>file 2>&1` so run_in_kitty() can report child_output for OTHER callers
(e.g. kitten __benchmark__'s printed results table). That means fd 1 here is
NOT the pty -- `cat`'s output must NOT be allowed to simply inherit it, or
this measures file I/O, not terminal ingestion (a real bug caught via a
post-hoc physics check: 5.4MB in ~5ms implies ~1 GB/s, ~10x the ascii-scenario
ingest ceiling measured in the same JSON -- impossible for a pty pipeline).
Every timed `cat` explicitly writes to /dev/tty (opened directly, bypassing
whatever fd 1 is redirected to), which is this window's real pty and drives
real terminal parsing/rendering -- exactly like the ghostty devlog-006
methodology this replicates (`time cat file` x10). Timing data is written to
a separate file (OUT_PATH), not stdout, so it never mixes with the
terminal-visible cat output or perturbs what is being measured.

Usage: _cat_timing_helper.py FIXTURE REPS OUT_PATH
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    fixture, reps_s, out_path = argv[1], argv[2], argv[3]
    try:
        reps = int(reps_s)
    except ValueError:
        print(f"REPS must be an integer, got {reps_s!r}", file=sys.stderr)
        return 2

    samples_ms: list[float] = []
    errors: list[str] = []
    tty_fd = os.open("/dev/tty", os.O_WRONLY)
    try:
        for i in range(reps):
            start = time.perf_counter()
            try:
                # stdout=tty_fd: cat writes directly to the controlling
                # pty, NOT this process's own (redirected) fd 1 -- see the
                # module docstring for why that distinction is load-bearing.
                subprocess.run(["cat", fixture], stdout=tty_fd, check=True)
            except (subprocess.CalledProcessError, OSError) as exc:
                errors.append(f"run {i}: {exc}")
                continue
            samples_ms.append((time.perf_counter() - start) * 1000.0)
    finally:
        os.close(tty_fd)

    with open(out_path, "w") as fh:
        json.dump({"samples_ms": samples_ms, "errors": errors, "requested_reps": reps}, fh)

    return 0 if samples_ms else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
