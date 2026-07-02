#!/usr/bin/env python3.14
"""Internal helper for scripts/metal-golden.py -- not a standalone tool.

Prints deterministic, fixed test-screen content (16/256/truecolor SGR text,
common programming-ligature trigger sequences, emoji, then a fixed cursor
position) and sleeps, so that a KITTY_METAL_DUMP_FRAME capture taken any
time after this process starts reflects settled, reproducible content
regardless of which kitty config launched it (the golden-image config
matrix varies kitty options, not this content).

Deliberately writes nothing that depends on terminal size, locale, or
randomness -- the same bytes every run, so pixel differences between two
capture sessions are attributable to rendering, not content drift.
"""

from __future__ import annotations

import sys
import time

_CLEAR_HOME = "\x1b[2J\x1b[H"
_RESET = "\x1b[0m"

_SIXTEEN_COLOR_FG = list(range(30, 38)) + list(range(90, 98))
_256_COLOR_SAMPLE = (196, 46, 21, 226, 129, 51, 208, 87)
_TRUECOLOR_SAMPLE = (
    (255, 0, 0), (0, 255, 0), (0, 0, 255),
    (255, 255, 0), (0, 255, 255), (255, 0, 255),
)
_LIGATURE_TRIGGERS = "-> => != === <= >= && || :: ++ -- <<< >>>"
_EMOJI = "\U0001F600 \U0001F389 \U0001F680 ❤️ \U0001F44D \U0001F525"


def main() -> int:
    out = sys.stdout
    out.write(_CLEAR_HOME)

    out.write("".join(f"\x1b[{c}mAB{_RESET}" for c in _SIXTEEN_COLOR_FG))
    out.write("\r\n")

    out.write("".join(f"\x1b[38;5;{c}mXY{_RESET}" for c in _256_COLOR_SAMPLE))
    out.write("\r\n")

    out.write("".join(f"\x1b[38;2;{r};{g};{b}mZZ{_RESET}" for r, g, b in _TRUECOLOR_SAMPLE))
    out.write("\r\n")

    out.write(_LIGATURE_TRIGGERS)
    out.write("\r\n")

    out.write(_EMOJI)
    out.write("\r\n")

    # Fixed final cursor position, deterministic across every config in the
    # matrix, so cursor rendering itself is part of the reproducible frame.
    out.write("\x1b[10;1H")
    out.flush()

    # Hold the settled frame steady long enough for the harness to capture
    # it via KITTY_METAL_DUMP_FRAME (which dumps every frame while set, so
    # the on-disk PNG at any moment during this sleep reflects this content).
    time.sleep(2.0)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
