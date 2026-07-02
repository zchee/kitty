#!/usr/bin/env python3.14
"""Deterministic pseudo-Japanese UTF-8 text fixture generator.

Produces reproducible, byte-for-byte-identical text (same seed + size always
yields the same output) that approximates real Japanese prose's UTF-8 byte
density, for use as a `cat`-throughput benchmark fixture. This replicates the
input used by the ghostty devlog-006 methodology (a fixed ~5.4 MB Japanese
text file, `cat` x10, <2% variance) referenced by
.omc/plans/2026-07-02-metal-worlds-fastest-optimization.md SS6 Phase 0 step 3
and SS12.

The output is NOT linguistically valid Japanese -- it is only required to
reproduce realistic multi-byte UTF-8 density for a throughput test. This is
the same approach the upstream Go benchmark kitten uses for its own
`chinese_lorem_ipsum` fixture (tools/cmd/benchmark/main.go). The fixture
itself is intentionally not committed to the repository; regenerate it with
this script on demand (it runs in well under a second).
"""

from __future__ import annotations

import argparse
import random
import sys
from pathlib import Path

# Representative character pools: hiragana, katakana, common CJK ideographs,
# Japanese punctuation, and half-width digits.
_HIRAGANA = [chr(c) for c in range(0x3041, 0x3097)]
_KATAKANA = [chr(c) for c in range(0x30A1, 0x30FB)]
_KANJI = [chr(c) for c in range(0x4E00, 0x9FA0)]
_PUNCTUATION = list("、。「」『』・！？…ー")
_DIGITS_HALFWIDTH = list("0123456789")

# Weighted pool: hiragana dominates real Japanese text byte-for-byte, kanji
# is common but less frequent than hiragana, katakana and punctuation rarer.
_SENTENCE_POOL = _HIRAGANA * 6 + _KATAKANA * 2 + _KANJI * 4 + _PUNCTUATION + _DIGITS_HALFWIDTH
_SENTENCE_LEN_RANGE = (8, 40)
_TERMINATORS = "。！？"
_PARAGRAPH_BREAK_PROBABILITY = 0.12


def generate(size_bytes: int, seed: int) -> str:
    """Generate deterministic pseudo-Japanese text of approximately size_bytes.

    Args:
        size_bytes: Target output size in UTF-8 encoded bytes.
        seed: Seed for the deterministic PRNG; identical (size_bytes, seed)
            always produces identical output.

    Returns:
        Generated text, UTF-8 encoding of which is at most size_bytes long.
    """
    rng = random.Random(seed)
    parts: list[str] = []
    total = 0
    min_len, max_len = _SENTENCE_LEN_RANGE
    while total < size_bytes:
        length = rng.randint(min_len, max_len)
        sentence = "".join(rng.choice(_SENTENCE_POOL) for _ in range(length))
        sentence += rng.choice(_TERMINATORS)
        if rng.random() < _PARAGRAPH_BREAK_PROBABILITY:
            sentence += "\n"
        parts.append(sentence)
        total += len(sentence.encode("utf-8"))
    encoded = "".join(parts).encode("utf-8")
    if len(encoded) > size_bytes:
        # Truncate on a UTF-8 boundary by dropping any trailing partial
        # sequence rather than raising on a mid-character cut.
        encoded = encoded[:size_bytes].decode("utf-8", errors="ignore").encode("utf-8")
    return encoded.decode("utf-8")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--seed", type=int, default=5361, help="PRNG seed (default: 5361)")
    parser.add_argument(
        "--size-bytes", type=int, default=5_400_000,
        help="target output size in bytes (default: 5,400,000 ~= devlog-006's 5.4 MB)",
    )
    parser.add_argument("--output", type=Path, required=True, help="path to write the fixture to")
    args = parser.parse_args(argv)

    if args.size_bytes <= 0:
        parser.error("--size-bytes must be positive")

    text = generate(args.size_bytes, args.seed)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(text, encoding="utf-8")
    actual_size = args.output.stat().st_size
    print(f"wrote {actual_size} bytes (target {args.size_bytes}, seed {args.seed}) to {args.output}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
