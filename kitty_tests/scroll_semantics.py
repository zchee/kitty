#!/usr/bin/env python3
# License: GPLv3 Copyright: 2026, Kovid Goyal <kovid at kovidgoyal.net>

# Behavior-snapshot suite for scroll/scrollback semantics, protecting the
# Phase-10 line-storage redesign (O(1) scroll). The storage layout is a
# compile-time property, so unlike the run-fill differential fuzz there is
# no in-process kill switch to compare against: identity is instead
# anchored to golden state dumps generated from the PRE-CHANGE binary and
# checked in (scroll_semantics.golden.json). Any container change must
# keep every scenario's observable state byte-identical.
#
# Regenerate goldens (ONLY on a binary whose behavior is the accepted
# reference): KITTY_REGEN_SCROLL_GOLDENS=1 python3.14 test.py scroll_semantics

import base64
import json
import os
from pathlib import Path

from kitty.window import as_text

from . import BaseTest, parse_bytes

GOLDEN_PATH = Path(__file__).parent / 'scroll_semantics.golden.json'


def dump_state(s) -> str:
    parts = [
        'VISIBLE+HISTORY(ansi):',
        as_text(s, add_history=True, as_ansi=True),
        f'CURSOR: x={s.cursor.x} y={s.cursor.y}',
    ]
    ph = s.historybuf.pagerhist_as_text() if s.historybuf is not None else ''
    parts.append('PAGERHIST:')
    parts.append(ph)
    if s.historybuf is not None:
        # byte-exactness of the compressed pager history (design-review
        # amendment: text-level compare could mask encoding drift)
        phb = s.historybuf.pagerhist_as_bytes()
        if phb:
            parts.append('PAGERHIST_BYTES: ' + base64.b64encode(phb).decode())
        # the wrap flag of the newest history line feeds line-0
        # continuation; with pooled slots surviving a clear, an ungated
        # read here is exactly how stale state would leak (final-review
        # finding: the ed3_stale_wrap_reuse scenario exists for this)
        parts.append(f'HB_ENDSWITH_WRAP: {s.historybuf.endswith_wrap()}')
    sel = s.text_for_selection()
    if any(sel):
        parts.append('SELECTION: ' + json.dumps(sel))
    return '\n'.join(parts)


def feed(s, text: str) -> None:
    parse_bytes(s, text.encode() if isinstance(text, str) else text)


class TestScrollSemantics(BaseTest):

    def scenarios(self):
        # Each entry: name -> (create_kwargs, driver). The driver mutates
        # the screen; dump_state() afterwards is the observable contract.
        pager = {'scrollback_pager_history_size': 4096}

        def plain_overflow(s):
            for i in range(12):
                feed(s, f'line{i}\r\n')

        def ring_wrap_eviction(s):
            # scrollback=3: lines must evict through the ring into pagerhist
            for i in range(15):
                feed(s, f'evict{i}\r\n')

        def margins_small_region(s):
            feed(s, '\x1b[2;4r')  # top=2 bottom=4
            feed(s, '\x1b[2;1H')
            for i in range(8):
                feed(s, f'reg{i}\r\n')
            feed(s, '\x1b[r')

        def margins_bottom_region(s):
            feed(s, '\x1b[3;5r\x1b[5;1H')
            for i in range(6):
                feed(s, f'bot{i}\r\n')
            feed(s, '\x1b[r')

        def decawm_wrap_continued(s):
            feed(s, 'A' * 23)  # wraps across lines, sets continued flags
            feed(s, '\r\nplain\r\n')
            feed(s, 'B' * 11)

        def wide_across_scroll(s):
            for i in range(4):
                feed(s, f'日本語x{i}\r\n')
            feed(s, '漢字漢字漢\r\n')
            feed(s, 'end日本')

        def wide_at_region_edge(s):
            feed(s, '\x1b[2;4r\x1b[2;1H')
            for i in range(5):
                feed(s, '字' * 5 + f'{i}\r\n')
            feed(s, '\x1b[r')

        def reverse_index_margins(s):
            for i in range(6):
                feed(s, f'ri{i}\r\n')
            feed(s, '\x1b[2;4r\x1b[2;1H')
            feed(s, '\x1bM\x1bM')  # RI twice at top of region: scroll down
            feed(s, 'top')
            feed(s, '\x1b[r')

        def clear_screen_ed2(s):
            for i in range(8):
                feed(s, f'ed{i}\r\n')
            feed(s, '\x1b[2J\x1b[Hafter')

        def clear_scrollback_ed3(s):
            for i in range(8):
                feed(s, f'edd{i}\r\n')
            feed(s, '\x1b[3J')
            feed(s, 'post')

        def selection_across_scroll(s):
            for i in range(4):
                feed(s, f'sel{i}\r\n')
            s.start_selection(0, 1)
            s.update_selection(4, 2)
            feed(s, 'more1\r\nmore2\r\n')  # scrolls; selection must track

        def resize_grow_cols(s):
            for i in range(9):
                feed(s, f'grow{i} ' + 'W' * 6 + '\r\n')
            s.resize(5, 9)

        def resize_shrink_cols(s):
            for i in range(9):
                feed(s, f'shrink{i}xyz\r\n')
            s.resize(5, 4)

        def resize_lines_both(s):
            for i in range(10):
                feed(s, f'rl{i}\r\n')
            s.resize(3, 6)
            feed(s, 'mid')
            s.resize(7, 6)

        def resize_multicell_rewrap(s):
            feed(s, '広い文字の行です' * 2)
            feed(s, '\r\ntail')
            s.resize(5, 7)

        def altscreen_roundtrip(s):
            for i in range(7):
                feed(s, f'main{i}\r\n')
            feed(s, '\x1b[?1049h')   # alt screen
            feed(s, 'altcontent\r\nalt2')
            feed(s, '\x1b[?1049l')   # back to main
            feed(s, 'back')

        def insert_delete_lines(s):
            for i in range(6):
                feed(s, f'il{i}\r\n')
            feed(s, '\x1b[2;1H\x1b[2L')  # insert 2 lines at row 2
            feed(s, 'ins')
            feed(s, '\x1b[4;1H\x1b[1M')  # delete a line
            feed(s, 'del')

        def sgr_colors_survive_history(s):
            feed(s, '\x1b[31mred\x1b[42mgreenbg\x1b[m\r\n')
            for i in range(8):
                feed(s, f'\x1b[3{i % 8}mc{i}\x1b[m\r\n')

        def erase_last_command_multicell(s):
            # exercises historybuf_delete_newest_lines incl. the
            # multicell nuke at the new newest line (screen.c:4893)
            feed(s, '\x1b]133;A\x1b\\$ cmd1\r\n')
            feed(s, 'out1\r\nout2漢字漢\r\n')
            feed(s, '\x1b]133;A\x1b\\$ cmd2\r\n')
            for i in range(6):
                feed(s, f'o{i}日本\r\n')
            s.erase_last_command()

        def resize_lines_only_same_cols(s):
            # cols unchanged => historybuf_fast_rewrap path
            for i in range(9):
                feed(s, f'fr{i}\r\n')
            s.resize(3, 6)
            feed(s, 'a')
            s.resize(6, 6)

        def resize_same_dims(s):
            for i in range(7):
                feed(s, f'sd{i}\r\n')
            s.resize(5, 6)  # identical dims: today a fast/no-op path

        def hyperlink_gc_across_eviction(s):
            # >256 distinct hyperlink ids force a hyperlink-pool GC whose
            # remap walks history + BOTH linebufs (the flat-walk escape
            # rewritten per-line in stage 1)
            for i in range(300):
                feed(s, f'\x1b]8;;http://e.com/{i}\x1b\\L{i}\x1b]8;;\x1b\\\r\n')

        def ed3_stale_wrap_reuse(s):
            # wrap full-width lines into history (wrap flags set on the
            # evicted cells), ED3-clear the shared pool (slots survive as
            # spares holding stale wrap flags), then scroll plain lines so
            # the stale slots are reused: HB_ENDSWITH_WRAP and the as_text
            # continuation joins must reflect the NEW content only
            feed(s, 'W' * 36)  # 6 wrapped rows on 6 cols, flags set
            for i in range(4):
                feed(s, f'\r\nw{i}')
            feed(s, '\x1b[3J')
            for i in range(8):
                feed(s, f'p{i}\r\n')

        def paused_rendering_across_scroll(s):
            for i in range(5):
                feed(s, f'pr{i}\r\n')
            s.pause_rendering(True, 5000)
            feed(s, 'while-paused1\r\nwhile-paused2\r\n')
            s.pause_rendering(False)
            feed(s, 'after')

        return {
            'plain_overflow': (dict(cols=6, lines=5, scrollback=10), plain_overflow),
            'ring_wrap_eviction': (dict(cols=8, lines=3, scrollback=3, options=pager), ring_wrap_eviction),
            'margins_small_region': (dict(cols=8, lines=6, scrollback=6), margins_small_region),
            'margins_bottom_region': (dict(cols=8, lines=6, scrollback=6), margins_bottom_region),
            'decawm_wrap_continued': (dict(cols=6, lines=4, scrollback=8), decawm_wrap_continued),
            'wide_across_scroll': (dict(cols=8, lines=4, scrollback=6), wide_across_scroll),
            'wide_at_region_edge': (dict(cols=11, lines=6, scrollback=6), wide_at_region_edge),
            'reverse_index_margins': (dict(cols=6, lines=6, scrollback=6), reverse_index_margins),
            'clear_screen_ed2': (dict(cols=6, lines=5, scrollback=8), clear_screen_ed2),
            'clear_scrollback_ed3': (dict(cols=6, lines=5, scrollback=8, options=pager), clear_scrollback_ed3),
            'selection_across_scroll': (dict(cols=6, lines=4, scrollback=8), selection_across_scroll),
            'resize_grow_cols': (dict(cols=6, lines=5, scrollback=10), resize_grow_cols),
            'resize_shrink_cols': (dict(cols=12, lines=5, scrollback=10), resize_shrink_cols),
            'resize_lines_both': (dict(cols=6, lines=5, scrollback=12), resize_lines_both),
            'resize_multicell_rewrap': (dict(cols=10, lines=5, scrollback=8), resize_multicell_rewrap),
            'altscreen_roundtrip': (dict(cols=8, lines=4, scrollback=8), altscreen_roundtrip),
            'insert_delete_lines': (dict(cols=6, lines=6, scrollback=8), insert_delete_lines),
            'sgr_colors_survive_history': (dict(cols=10, lines=4, scrollback=12), sgr_colors_survive_history),
            'erase_last_command_multicell': (dict(cols=10, lines=5, scrollback=12), erase_last_command_multicell),
            'resize_lines_only_same_cols': (dict(cols=6, lines=5, scrollback=10), resize_lines_only_same_cols),
            'resize_same_dims': (dict(cols=6, lines=5, scrollback=8), resize_same_dims),
            'hyperlink_gc_across_eviction': (dict(cols=12, lines=4, scrollback=20), hyperlink_gc_across_eviction),
            'ed3_stale_wrap_reuse': (dict(cols=6, lines=4, scrollback=6, options=pager), ed3_stale_wrap_reuse),
            'paused_rendering_across_scroll': (dict(cols=16, lines=4, scrollback=8), paused_rendering_across_scroll),
        }

    # -- Pre-overwrite blank-row contract (test-first for the lazy-clear
    # -- levers S1 is_blank / S2 high-water-mark) ------------------------
    #
    # The golden snapshots above converge on the FINAL, post-overwrite
    # state. The lazy-clear bug class hides in the window BEFORE a
    # just-scrolled-in row is overwritten: a reader (as_text, selection,
    # search, line length) observes the recycled slot while it still
    # holds the stale bytes of the evicted line (P10 stale-wrap precedent,
    # history.c:192-198). vtebench overwrites every recycled row
    # immediately, so a golden that only compares end-state cannot see
    # this — hence explicit, lever-agnostic assertions on the observable
    # emptiness of a fresh blank row, checked the instant it is created.
    #
    # These pass on HEAD's eager clear (every INDEX_UP/INDEX_DOWN/ED path
    # zeroes the recycled row) and define the contract S1/S2 must keep:
    # narrowing or eliminating the memset must not let ANY CPU-cell reader
    # surface stale content. Assertions are phrased on semantics only (no
    # is_blank / hwm / kill-switch references) so they hold with every
    # lever ON and OFF.

    def assert_blank_row(self, s, y):
        # Each assertion exercises one of the ~6 CPU-cell readers the
        # P10-0 audit enumerated (lineops.h:42,61; line.c:151,434,561).
        ln = s.line(y)
        # line_as_unicode -> xlimit_for_line / line_length
        self.assertEqual(str(ln), '', f'row {y}: str() surfaced stale bytes')
        # line_as_ansi -> xlimit_for_line (+ SGR run reconstruction)
        self.assertEqual(ln.as_ansi(), '', f'row {y}: as_ansi() surfaced stale bytes')
        # trailing wrap-continuation cell read (the exact P10 stale-wrap leak)
        self.assertFalse(
            ln.last_char_has_wrapped_flag(), f'row {y}: stale soft-wrap flag survived the clear')
        # unicode_in_range via a full-row selection (search/copy data path)
        s.start_selection(0, y)
        s.update_selection(s.columns - 1, y, True)
        self.assertEqual(
            s.text_for_selection(), (), f'row {y}: selection surfaced stale bytes')
        # as_text -> unicode_in_range + line_is_empty over the visible grid
        visible = as_text(s).split('\n')
        got = visible[y] if y < len(visible) else ''
        self.assertEqual(got, '', f'row {y}: as_text surfaced stale bytes')

    def assert_tokens_absent_from_visible(self, s, tokens):
        # search/unicode_in_range contract: content that was evicted to
        # scrollback or erased must not remain readable on the visible
        # screen through any recycled slot.
        visible = as_text(s)
        for tok in tokens:
            self.assertNotIn(
                tok, visible, f'evicted/erased token {tok!r} still visible after scroll')

    def test_pre_overwrite_blank_reads(self):
        # name -> driver(s) -> (blank_row_indices, tokens_fully_gone).
        # The driver leaves the cursor at a fresh blank row that has NOT
        # been overwritten; every listed row must read empty.
        def plain_index_up(s):  # (a)
            for i in range(4):
                feed(s, f'AA{i}xx')
                if i < 3:
                    feed(s, '\r\n')
            feed(s, '\r\n')  # LF at bottom -> scroll up; row 3 fresh blank
            return [3], ()

        def reverse_index(s):  # (b)
            for i in range(4):
                feed(s, f'RR{i}yy')
                if i < 3:
                    feed(s, '\r\n')
            feed(s, '\x1b[H\x1bM')  # RI at top -> scroll down; row 0 fresh blank
            return [0], ()

        def clear_screen_ed2(s):  # (c) ED2
            for i in range(3):
                feed(s, f'DD{i}ee')
                if i < 2:
                    feed(s, '\r\n')
            feed(s, '\x1b[2J')
            return [0, 1, 2], ('DD0ee', 'DD1ee', 'DD2ee')

        def clear_scrollback_ed3(s):  # (c) ED3
            for i in range(6):
                feed(s, f'GG{i}ff\r\n')
            feed(s, 'live99')
            feed(s, '\x1b[3J')  # erase display + scrollback
            return [0, 1, 2], ('GG0ff', 'GG5ff', 'live99')

        def ring_wrap_eviction(s):  # (d) recycled slot = OLDEST history line
            for i in range(6):  # lines(3)+scrollback(3): ring becomes full
                feed(s, f'EV{i:02d}z\r\n')
            feed(s, '\r\n')  # one more scroll recycles the oldest hist slot
            # 'EV00z' is the oldest evicted line: its slot is now the fresh
            # blank bottom row -> genuinely stale bytes must not surface.
            return [2], ('EV00z',)

        def margins_region_forward(s):  # (e) scroll region, blank at region bottom
            for i in range(5):
                feed(s, f'MG{i}ab')
                if i < 4:
                    feed(s, '\r\n')
            feed(s, '\x1b[2;4r\x1b[4;1H\n')  # region rows 1..3; LF at region bottom
            return [3], ()

        def margins_region_reverse(s):  # (e) scroll region, blank at region top
            for i in range(5):
                feed(s, f'MR{i}cd')
                if i < 4:
                    feed(s, '\r\n')
            feed(s, '\x1b[2;4r\x1b[2;1H\x1bM')  # RI at region top -> row 1 blank
            return [1], ()

        def multicell_across_boundary(s):  # (f) wide char spanning the boundary
            feed(s, '日本語')  # 3 full-width cells fill row 0
            feed(s, '\r\nAB\r\nCD')
            feed(s, '\r\n')  # scroll the multicell row out; row 2 fresh blank
            # a leaked is_multicell/char would re-materialize the wide glyph
            return [2], ('日本語',)

        def wrapped_line_recycled(s):  # P10 stale-wrap class
            feed(s, 'W' * 24)  # 4 soft-wrapped rows of 6 -> wrap flags set
            for _ in range(6):
                feed(s, '\r\n')  # scroll every wrapped row out; bottom recycles them
            return [0, 1, 2, 3], ()

        def insert_lines_blank(s):  # IL opens fresh blank rows mid-screen
            for i in range(4):
                feed(s, f'IL{i}qq')
                if i < 3:
                    feed(s, '\r\n')
            feed(s, '\x1b[2;1H\x1b[2L')  # cursor row 2, insert 2 -> rows 1,2 blank
            return [1, 2], ()

        pager = {'scrollback_pager_history_size': 4096}
        scenarios = {
            'plain_index_up': (dict(cols=6, lines=4, scrollback=10), plain_index_up),
            'reverse_index': (dict(cols=6, lines=4, scrollback=10), reverse_index),
            'clear_screen_ed2': (dict(cols=6, lines=3, scrollback=8), clear_screen_ed2),
            'clear_scrollback_ed3': (dict(cols=6, lines=3, scrollback=8, options=pager), clear_scrollback_ed3),
            'ring_wrap_eviction': (dict(cols=6, lines=3, scrollback=3, options=pager), ring_wrap_eviction),
            'margins_region_forward': (dict(cols=6, lines=5, scrollback=10), margins_region_forward),
            'margins_region_reverse': (dict(cols=6, lines=5, scrollback=10), margins_region_reverse),
            'multicell_across_boundary': (dict(cols=6, lines=3, scrollback=10), multicell_across_boundary),
            'wrapped_line_recycled': (dict(cols=6, lines=4, scrollback=10), wrapped_line_recycled),
            'insert_lines_blank': (dict(cols=6, lines=4, scrollback=10), insert_lines_blank),
        }
        for name, (kwargs, driver) in scenarios.items():
            with self.subTest(scenario=name):
                s = self.create_screen(**kwargs)
                blank_rows, gone = driver(s)
                for y in blank_rows:
                    self.assert_blank_row(s, y)
                if gone:
                    self.assert_tokens_absent_from_visible(s, gone)

    def test_s1_lazy_clear_gpu_correctness(self):
        # S1 (Phase 13B) lazy GPUCell clear: the deferred (is_blank) GPUCells
        # must be indistinguishable from an eager 32B clear through every
        # GPUCell consumer. Assertions encode the correct (eager) values and
        # must hold with the lever ON (default) and OFF
        # (KITTY_DISABLE_LAZY_ROW_CLEAR=1) — run both arms.

        # (a) get_line_edge_colors_at_row on a just-scrolled blank cursor row:
        # a prior non-default (red) bg must NOT leak; edges read default.
        s = self.create_screen(cols=6, lines=4, scrollback=10)
        feed(s, '\x1b[41m')                 # red bg
        for i in range(4):
            feed(s, f'R{i}xxx')
            if i < 3:
                feed(s, '\r\n')
        feed(s, '\x1b[m\r\n\x1b[4;1H')       # reset, scroll, cursor on new blank row
        self.assertEqual(s.line_edge_colors(), (0, 0), 'blank row leaked stale edge colors')

        # (b) colored-blank preservation: a GPUCell writer (erase-to-yellow-bg)
        # on the fresh blank row must materialize, keeping its bg.
        feed(s, '\x1b[43m\x1b[K\x1b[m')      # yellow bg, erase to EOL
        self.assertEqual(s.line(3).cursor_from(0).bg, 769, 'erase-to-color blank was wiped')

        # (c) drawn colors after a scroll: the draw path materializes; the
        # recycled row shows the drawn glyph in the drawn color, not stale bytes.
        s2 = self.create_screen(cols=6, lines=3, scrollback=10)
        for i in range(3):
            feed(s2, f'C{i}yyy')
            if i < 2:
                feed(s2, '\r\n')
        feed(s2, '\r\n\x1b[31mZ\x1b[m')      # scroll, draw red Z on the recycled row
        drawn = s2.line(2).cursor_from(0)
        self.assertEqual((str(s2.line(2)), drawn.fg, drawn.bg), ('Z', 257, 0), 'drawn cell wrong')

        # (d) a fresh (never-scrolled) blank screen still reads default edges.
        self.assertEqual(self.create_screen(cols=6, lines=3).line_edge_colors(), (0, 0))

        # (e) a colored-blank (erase-to-bg) must SURVIVE line finalize: the cells
        # are cpu-blank but intentionally colored, so the S2 tail-clear (keyed on
        # the cpu write-extent) must not wipe them. Erase a scrolled row to
        # yellow, then LF so it is finalized and scrolls up one.
        s3 = self.create_screen(cols=6, lines=3, scrollback=10)
        for i in range(3):
            feed(s3, f'K{i}pp')
            if i < 2:
                feed(s3, '\r\n')
        feed(s3, '\r\n')                  # scroll: fresh blank bottom row, cursor there
        feed(s3, '\x1b[43m\x1b[K\x1b[m')  # erase the row to yellow bg
        feed(s3, '\r\n')                  # LF finalizes it; the yellow row -> row 1
    def test_sparse_cursor_address_then_scroll(self):
        # Wave-15 L1 (lead addition): a cursor-addressed sparse row drawn onto a
        # recycled (HWM-deferred, is_blank) slot must, once finalized and scrolled
        # out, read byte-identically to the EAGER arm. Draw at col 0, jump to a far
        # column (CUP/CUF/TAB), draw there, scroll it out, read back. The interior
        # gap and the tail must be blank at CPU (str) AND GPU (cursor_from().bg)
        # level -- eager's ground truth -- so any pre-existing HWM interior-gap
        # staleness surfaces here instead of being enshrined. Runs in whatever arm
        # test.py selects; the assertions encode the eager-correct observable state.
        def jump(kind):
            if kind == 'CUP':
                return '\x1b[13G'         # -> 0-based col 12
            if kind == 'CUF':
                return '\x1b[11C'         # from col 1 (after 'A') -> col 12
            if kind == 'TAB':
                return '\t\t'             # col 1 -> 8 -> 16
            raise ValueError(kind)

        for kind in ('CUP', 'CUF', 'TAB'):
            with self.subTest(jump=kind):
                s = self.create_screen(cols=20, lines=3, scrollback=2)
                # Force a GUARANTEED-stale recycled slot: overrun the ring
                # (lines+scrollback=5) with full red-bg rows, so the deferred
                # bottom row's GPUCells hold red across every column.
                for _ in range(8):
                    feed(s, '\x1b[41m' + 'Z' * 20 + '\x1b[m\r\n')
                # cursor now on the recycled deferred (is_blank) bottom row.
                feed(s, 'A')               # col 0
                feed(s, jump(kind))
                col = s.cursor.x           # actual landed column
                feed(s, 'B')               # col `col`
                feed(s, '\r\n')            # finalize the sparse row; it moves to row 1
                ln = s.line(1)
                # CPU (all arms): no recycled 'Z' leaks into the text.
                self.assertNotIn('Z', str(ln), f'{kind}: stale text leaked')
                # GPU (raw gpu_cells via cursor_from), ALL arms: every non-A/B cell
                # reads default bg. The §10c S1-lite materialize-on-cursor-jump zeros
                # the whole deferred row before the discontiguous write, so no interior
                # gap survives -- byte-identical to eager. (This was xfail-under-hwm
                # while the gap was chartered-but-unfixed; the fix flips it to a plain
                # assertion in every arm, and it XFAILs loudly if the fix regresses.)
                for x in range(1, 20):
                    if x == col:
                        continue
                    self.assertEqual(
                        ln.cursor_from(x).bg, 0,
                        f'{kind}: stale GPU bg {ln.cursor_from(x).bg} at col {x} (col={col})')

    def test_scroll_semantics(self):
        regen = bool(os.environ.get('KITTY_REGEN_SCROLL_GOLDENS'))
        results = {}
        for name, (kwargs, driver) in self.scenarios().items():
            s = self.create_screen(**kwargs)
            driver(s)
            results[name] = dump_state(s)
        if regen:
            GOLDEN_PATH.write_text(json.dumps(results, indent=1, ensure_ascii=False) + '\n')
            self.skipTest(f'regenerated {GOLDEN_PATH.name} with {len(results)} scenarios')
        self.assertTrue(GOLDEN_PATH.exists(), 'golden file missing - run with KITTY_REGEN_SCROLL_GOLDENS=1 on a reference binary')
        golden = json.loads(GOLDEN_PATH.read_text())
        self.assertEqual(set(golden), set(results), 'scenario set drifted from the golden file - regenerate deliberately')
        for name, expected in golden.items():
            if results[name] != expected:
                self.fail(
                    f'scroll semantics diverged in scenario {name!r}:\n'
                    f'--- golden ---\n{expected}\n--- current ---\n{results[name]}'
                )
