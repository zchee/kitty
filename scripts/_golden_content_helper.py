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

# W27 P3.6 / GLSL-freeze-out stage 0: two additional scenes close the golden
# coverage hole over the GRAPHICS and ROUNDED_RECT programs (risk R4 in
# GLSL-FREEZEOUT-DESIGN.md). Scene selection rides argv[1]; NO argument means
# the legacy scene, byte-for-byte identical to the pre-P3.6 content, so the
# four existing golden configs keep their baselines.
#
# An 8x8 RGBA PNG, generated deterministically (four R/G/B/W quadrants plus
# two mid-tone pixels) and embedded so the scene needs no filesystem asset.
# Displayed via the graphics protocol APC directly (a=T transmit+display,
# f=100 PNG, c/r scale to cells) -- no kitten involved, stdlib only.
_GRAPHICS_PNG_B64 = (
    "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAYAAADED76LAAAAMklEQVR4nGP8z8DwnwEJ"
    "MKJyGZhQeFgAaQoaHQ5gUfIfFTocaPiPDEBuQnEVGpcKjgQAJbEe80vcVQEAAAAASUVO"
    "RK5CYII="
)


def _disable_tty_echo() -> None:
    # W27 P3.5 finding: capture windows take keyboard focus, and any key the
    # operator happens to press while a capture is settling is ECHOED by the
    # tty into the frame (observed as caret-notation arrow keys rendered at
    # the parked cursor — the true mechanism behind the "204-class" golden
    # flakes). The helper never reads input, so turning ECHO off makes the
    # painted content deterministic even when keys arrive mid-capture.
    try:
        import termios
        fd = sys.stdin.fileno()
        attrs = termios.tcgetattr(fd)
        attrs[3] &= ~termios.ECHO  # lflags
        termios.tcsetattr(fd, termios.TCSANOW, attrs)
    except Exception:
        pass  # not a tty (or no termios): nothing to echo, nothing to do


def main() -> int:
    _disable_tty_echo()
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

    scene = sys.argv[1] if len(sys.argv) > 1 else "legacy"
    if scene == "graphics":
        # GRAPHICS program coverage: transmit + display the embedded PNG at a
        # fixed cell rect below the text content. Nearest-sampled upscale of
        # flat quadrants stays flat, so the block is pixel-deterministic.
        out.write("\x1b[7;1H")
        out.write(f"\x1b_Ga=T,f=100,c=16,r=4;{_GRAPHICS_PNG_B64}\x1b\\")
    elif scene == "progress":
        # ROUNDED_RECT program coverage: a determinate OSC 9;4 progress report
        # (state 1, 50 %) makes kitty draw the progress-bar overlay (option
        # progress_bar, default 'top'); determinate bars do not animate, so
        # the held frame is static.
        out.write("\x1b]9;4;1;50\x1b\\")
    elif scene == "palette":
        # W27 P3.6: OKLCH palette entries through kitty's own parser (OSC 4 →
        # Color.parse_color) painted as SGR 48;5 swatches — the golden twin of
        # the .omc accuracy-gate palette rows. On the BGRA8 capture control arm
        # this locks the dump-channel rendering of wide-capable palette
        # entries across the format flip (baselined at the P3.6 re-baseline).
        specs = (
            "oklch(0.62 0.26 29)", "oklch(0.87 0.22 110)", "oklch(0.86 0.30 142)",
            "oklch(0.80 0.16 195)", "oklch(0.70 0.40 25)", "oklch(0.55 0.30 264)",
            "oklch(0.80 0.20 150)", "oklch(0.50 0.28 290)",
        )
        for i, spec in enumerate(specs):
            out.write(f"\x1b]4;{16 + i};{spec}\x1b\\")
        out.write("\x1b[7;1H")
        for i in range(len(specs)):
            out.write(f"\x1b[48;5;{16 + i}m    \x1b[0m")

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
