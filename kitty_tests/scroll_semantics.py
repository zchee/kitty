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
