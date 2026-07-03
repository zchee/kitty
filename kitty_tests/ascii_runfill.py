#!/usr/bin/env python
# License: GPLv3 Copyright: 2026, Kovid Goyal <kovid at kovidgoyal.net>

# Differential fuzz test for the batched ASCII run-fill path in
# draw_ascii_run() (kitty/screen.c). It feeds the *same* byte stream to two
# screens, one with the bulk path enabled and one with it forced off via
# kitty.fast_data_types.set_ascii_runfill_enabled(), and asserts the
# resulting screen state is byte-identical. The bulk path is an internal
# fast-path optimization only: it must never be observable from the output.

import os
import random

from kitty.fast_data_types import set_ascii_runfill_enabled

from . import BaseTest, parse_bytes

DECAWM_OFF = b'\x1b[?7l'
DECAWM_ON = b'\x1b[?7h'
IRM_ON = b'\x1b[4h'
IRM_OFF = b'\x1b[4l'
CHARSET_G0_SPECIAL = b'\x1b(0'
CHARSET_G0_ASCII = b'\x1b(B'
SHIFT_OUT = b'\x0e'
SHIFT_IN = b'\x0f'

MODE_TOGGLES = (DECAWM_OFF, DECAWM_ON, IRM_ON, IRM_OFF)
CHARSET_SHIFTS = (CHARSET_G0_SPECIAL, CHARSET_G0_ASCII, SHIFT_OUT, SHIFT_IN)

# A grab-bag of wide/emoji/combining/zero-width units. Each is inserted
# whole (as its own token) so multi-codepoint grapheme clusters (ZWJ
# sequences, skin-tone modifiers, regional-indicator flags) stay intact.
WIDE_EMOJI_COMBINING_UNITS = (
    '日', '本', '語', 'あ', 'ニ', 'ハ',
    '\U0001f600',                                                          # emoji, wide
    '\U0001f468‍\U0001f469‍\U0001f467‍\U0001f466',          # ZWJ family sequence
    '\U0001f469\U0001f3fd',                                                # emoji + skin tone modifier
    '\U0001f1ee\U0001f1f3',                                                # regional indicator flag pair
    'é',                                                             # 'e' + combining acute accent
    'é',                                                              # precomposed 'é'
    'X​Y',                                                            # zero width space
    'X‌Y',                                                            # zero width non-joiner
    'X‍Y',                                                            # zero width joiner (no emoji context)
)

SGR_CODES = (
    0, 1, 2, 3, 4, 7, 9, 21, 22, 23, 24, 27, 28, 29,
    30, 31, 32, 33, 34, 35, 36, 37, 39,
    40, 41, 42, 43, 44, 45, 46, 47, 49,
    90, 91, 92, 93, 94, 95, 96, 97,
    100, 101, 102, 103, 104, 105, 106, 107,
)


def hyperlink(url='', id=''):
    params = f'id={id}' if id else ''
    return f'\x1b]8;{params};{url}\x1b\\'.encode('utf-8')


def _ascii_run(rng: random.Random, cols: int) -> bytes:
    n = rng.randint(1, 3 * cols)
    return bytes(rng.randint(0x20, 0x7e) for _ in range(n))


def _sgr(rng: random.Random) -> bytes:
    codes = [rng.choice(SGR_CODES) for _ in range(rng.randint(1, 3))]
    return ('\x1b[' + ';'.join(map(str, codes)) + 'm').encode('ascii')


def _cursor_move(rng: random.Random, cols: int, lines: int) -> bytes:
    row, col = rng.randint(1, lines), rng.randint(1, cols)
    return f'\x1b[{row};{col}H'.encode('ascii')


# weighted per the fuzz spec: mostly ASCII runs, with a long tail of
# controls/SGR/wide-chars/cursor-moves/mode-toggles/charset-shifts.
_FUZZ_CATEGORIES = (
    ('ascii', 73), ('control', 10), ('sgr', 5), ('wide', 5),
    ('cursor', 3), ('mode', 2), ('charset', 2),
)
_FUZZ_NAMES = [c for c, _ in _FUZZ_CATEGORIES]
_FUZZ_WEIGHTS = [w for _, w in _FUZZ_CATEGORIES]


def _fuzz_token(rng: random.Random, category: str, cols: int, lines: int) -> bytes:
    if category == 'ascii':
        return _ascii_run(rng, cols)
    if category == 'control':
        return rng.choice((b'\n', b'\t', b'\r'))
    if category == 'sgr':
        return _sgr(rng)
    if category == 'wide':
        return rng.choice(WIDE_EMOJI_COMBINING_UNITS).encode('utf-8')
    if category == 'cursor':
        return _cursor_move(rng, cols, lines)
    if category == 'mode':
        return rng.choice(MODE_TOGGLES)
    return rng.choice(CHARSET_SHIFTS)  # charset


def make_fuzz_case(rng: random.Random) -> tuple[bytes, int, int]:
    cols = rng.randint(5, 120)
    lines = rng.randint(3, 30)
    data = bytearray()
    for _ in range(rng.randint(15, 40)):
        category = rng.choices(_FUZZ_NAMES, weights=_FUZZ_WEIGHTS, k=1)[0]
        data += _fuzz_token(rng, category, cols, lines)
    return bytes(data), cols, lines


def _deterministic_cases() -> list[tuple[str, bytes, int, int]]:
    cases: list[tuple[str, bytes, int, int]] = []

    def add(name, data, cols=10, lines=6):
        cases.append((name, bytes(data), cols, lines))

    add('plain_long_ascii_lines', b'the quick brown fox jumps over the lazy dog ' * 6, cols=20, lines=8)

    # runs crossing the wrap boundary exactly: line width, width - 1, width + 1
    for delta, label in ((-1, 'width_minus_1'), (0, 'width_exact'), (1, 'width_plus_1')):
        n = 10 + delta
        add(f'wrap_boundary_{label}', bytes((0x61 + (i % 26)) for i in range(n)), cols=10, lines=6)

    add('decawm_off_overflow', DECAWM_OFF + b'0123456789' * 4, cols=10, lines=4)
    add('irm_inserts', IRM_ON + b'1234567890' + b'\x1b[1G' + b'AB', cols=10, lines=4)
    add('charset_shift', CHARSET_G0_SPECIAL + b'/_/_/_' + CHARSET_G0_ASCII + b'abc', cols=15, lines=4)
    add('wide_before_run', '日本語'.encode() + b'hello', cols=15, lines=4)
    add('wide_after_run', b'hello' + '日本語'.encode(), cols=15, lines=4)
    add('wide_overwrite_partial', 'hello日本語world'.encode() + b'\x1b[1;7H' + b'XYZ', cols=20, lines=4)
    add('combining_char_adjacent', b'abc' + 'é'.encode() + b'def', cols=15, lines=4)
    add('zwj_family_sequence', b'abc' + '\U0001f468‍\U0001f469‍\U0001f467‍\U0001f466'.encode() + b'xyz', cols=20, lines=4)
    add('tabs_and_newlines_interleaved', b'ab\tcd\ncdef\r\nghij\tklmn', cols=12, lines=6)
    add('csi_rep_after_ascii', b'a' + b'\x1b[5b' + b'bcdef', cols=15, lines=4)
    add('sgr_mid_stream_then_runs', b'\x1b[31mred' + b'\x1b[4munderline' + b'\x1b[0mplain', cols=20, lines=4)
    add('hyperlinks_around_runs', hyperlink('http://example.com', '1') + b'linked' + hyperlink() + b'plain', cols=20, lines=4)
    add('cursor_move_mid_run_overwrite', b'0123456789' + b'\x1b[1;4H' + b'XYZ', cols=12, lines=4)

    return cases


DETERMINISTIC_CASES = _deterministic_cases()


def _snapshot(screen):
    # Comparator surface: visible-line text+SGR (as_ansi encodes fg/bg/
    # decoration_fg/bold/italic/etc via SGR transitions), per-cell hyperlink
    # ids (as_ansi() alone can't see these, see module docstring below),
    # wrap-continuation flags, and final cursor position.
    #
    # NOTE: Line.width(x) is deliberately NOT compared here: kitty/line.c's
    # width() returns a bare C `0` (i.e. NULL) instead of PyLong_FromLong(0)
    # for any cell with no text, which CPython surfaces as `SystemError:
    # error return without exception set` instead of the intended `0`. That
    # is a pre-existing bug unrelated to ascii_runfill, out of scope to fix
    # here; as_ansi() already reflects wide-character layout since it emits
    # each logical character's glyph exactly once.
    lines, hyperlink_ids, continued = [], [], []
    for y in range(screen.lines):
        line = screen.line(y)
        lines.append(line.as_ansi())
        hyperlink_ids.append(line.hyperlink_ids())
        continued.append(screen.linebuf.is_continued(y))
    return {
        'lines': tuple(lines),
        'hyperlink_ids': tuple(hyperlink_ids),
        'continued': tuple(continued),
        'cursor': (screen.cursor.x, screen.cursor.y),
    }


def _diff_snapshots(snap_a, snap_b, label_a='bulk', label_b='scalar'):
    diffs = []
    if snap_a['cursor'] != snap_b['cursor']:
        diffs.append(f"cursor: {label_a}={snap_a['cursor']!r} {label_b}={snap_b['cursor']!r}")
    for y in range(len(snap_a['lines'])):
        if snap_a['lines'][y] != snap_b['lines'][y]:
            diffs.append(f"line {y} text/sgr: {label_a}={snap_a['lines'][y]!r} {label_b}={snap_b['lines'][y]!r}")
        if snap_a['continued'][y] != snap_b['continued'][y]:
            diffs.append(f"line {y} continued: {label_a}={snap_a['continued'][y]!r} {label_b}={snap_b['continued'][y]!r}")
        if snap_a['hyperlink_ids'][y] != snap_b['hyperlink_ids'][y]:
            diffs.append(f"line {y} hyperlink_ids: {label_a}={snap_a['hyperlink_ids'][y]!r} {label_b}={snap_b['hyperlink_ids'][y]!r}")
    return diffs


class TestAsciiRunfill(BaseTest):

    def assert_screens_match(self, screen_a, screen_b, context, label_a='bulk', label_b='scalar'):
        diffs = _diff_snapshots(_snapshot(screen_a), _snapshot(screen_b), label_a, label_b)
        if diffs:
            self.fail(context + '\n' + '\n'.join(diffs))

    def assert_paths_match(self, data: bytes, cols: int, lines: int, context: str) -> None:
        scrollback = max(3, lines)
        prev = set_ascii_runfill_enabled(True)
        try:
            bulk = self.create_screen(cols=cols, lines=lines, scrollback=scrollback)
            parse_bytes(bulk, data)
        finally:
            set_ascii_runfill_enabled(prev)
        prev = set_ascii_runfill_enabled(False)
        try:
            scalar = self.create_screen(cols=cols, lines=lines, scrollback=scrollback)
            parse_bytes(scalar, data)
        finally:
            set_ascii_runfill_enabled(prev)
        self.assert_screens_match(bulk, scalar, context)

    def test_ascii_runfill(self):
        # 0) Comparator self-check: prove assert_screens_match() actually
        # detects divergence, so a vacuously-passing comparator can't hide
        # real regressions in the cases below.
        s_abc = self.create_screen(cols=10, lines=3, scrollback=3)
        parse_bytes(s_abc, b'abc')
        s_abd = self.create_screen(cols=10, lines=3, scrollback=3)
        parse_bytes(s_abd, b'abd')
        with self.assertRaises(AssertionError):
            self.assert_screens_match(s_abc, s_abd, 'comparator self-check', 'abc-screen', 'abd-screen')

        # 1) Deterministic adversarial cases.
        for name, data, cols, lines in DETERMINISTIC_CASES:
            with self.subTest(case=name):
                self.assert_paths_match(data, cols, lines, context=f'deterministic case={name!r} data={data!r}')

        # 2) Randomized fuzz, seed fixed by default for reproducibility.
        seed = os.environ.get('KITTY_FUZZ_SEED', '1337')
        rng = random.Random(int(seed))
        for i in range(200):
            data, cols, lines = make_fuzz_case(rng)
            with self.subTest(fuzz_index=i):
                self.assert_paths_match(
                    data, cols, lines,
                    context=f'fuzz seed={seed} index={i} cols={cols} lines={lines} data={data!r}')
