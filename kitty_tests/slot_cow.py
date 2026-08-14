#!/usr/bin/env python3
# License: GPLv3 Copyright: 2026, Kovid Goyal <kovid at kovidgoyal.net>

# Wave 25 (`.omc/plans/ralplan-wave25-slotcow-impl.md`) Lane H scaffolding
# for the slot-anchored refcounted-line COW pause-snapshot design
# (`.omc/verify/wave24/L-SLOTCOW-DESIGN.md`). Lane S (the product lane --
# per-slot refcount lane, free-list, `KITTY_PAUSE_SNAPSHOT_SHARE`) has
# landed (commits bbf47373e + 5816866df), so the tests below split into:
#
#   - in-process tests that hold in BOTH switch worlds (pause/write-storm/
#     unpause content fidelity; the reset-site bypass scenarios named in
#     `.omc/verify/wave25/W25-THREAD-AUDIT.md` Part (b), some augmented
#     with a SHARE=1 sub-check where the landed code changed what is
#     observable at that site) -- they run at whatever the build default
#     resolves to and assert nothing default-specific;
#   - arm-pinned subprocess tests via `run_share_subprocess`, which sets
#     KITTY_PAUSE_SNAPSHOT_SHARE explicitly ('1' ON legs, '0' explicit-OFF
#     legs) so each leg is correct regardless of the build default: the
#     Lane-S ON semantics (refcount-lane incref/retire/decref timeline,
#     pool identity across a rewrap-forcing resize, retire-before-lineptr
#     per handout-helper class, the history serial-0 deep-copy carve-out,
#     deferred-row finalize-before-incref, and the documented
#     incref-overflow bound). No test theater -- every assertion is a real,
#     falsifiable delta on `Screen.slot_share_stats()` /
#     `Screen.paused_snapshot_row_bytes()`.
#
# The write-class storm composer below (`compose_write_storm` and the
# `WRITE_CLASS_NAMES` list) is the single source of truth for the "9
# pinned write classes" (plan Sec. "Battery write classes"), imported by
# both this module's own roundtrip test and `scripts/w25_cow_battery.py`
# so the unit-level and battery-level coverage never drift apart.

import gc
import json
import os
import subprocess
import sys

from .base import BaseTest, parse_bytes

# Screen geometry shared by the roundtrip test and the battery driver.
# Wide/tall enough for DECSTBM region rotation (needs >= 4 lines) and
# ICH/DCH without running off the right margin.
COLS = 20
LINES = 6
SCROLLBACK = 200

# Fixed order the 9 pinned write classes are composed in every storm.
# Composing all 9 every cycle (rather than one class per cycle) is what
# satisfies AC-5's "not 50 trivial storms" requirement most directly.
WRITE_CLASS_NAMES = (
    'append_draw_notrack',
    'irm_insert_delete',
    'clear_class',
    'decstbm_region_rotate',
    'scroll_flood',
    'hyperlink_remap',
    'resize_while_paused',
    'rewrap_while_paused',
    'alt_screen_switch',
)


def feed(s, text) -> None:
    parse_bytes(s, text.encode() if isinstance(text, str) else text)


def setup_screen_with_history(s) -> None:
    # Seed some scrollback before the first cycle so write-class 8
    # (rewrap-while-paused) always has real history to rewrap, even on
    # cycle 0 -- not just from history accumulated by earlier cycles.
    for i in range(s.lines * 2):
        feed(s, f'seed{i:03d}\r\n')


# -- The 9 pinned write classes (plan "Battery write classes" list) ------

def cls_append_draw_notrack(s, cycle: int) -> None:
    # 1. append/draw (notrack path): plain character drawing is the hot
    # text-loop path (screen.c:776 linebuf_init_cells_notrack) -- the
    # MAJOR-1 pointer-materialization site the retire map is built around.
    feed(s, f'\x1b[{s.lines};1Hdraw{cycle % 10}')


def cls_irm_insert_delete(s, cycle: int) -> None:
    # 2. IRM insert/delete: ICH (insert char) / DCH (delete char) at a
    # fixed interior row.
    feed(s, f'\x1b[3;1Hbase{cycle % 10}xyz')
    feed(s, '\x1b[3;3H')   # cursor -> row 3, col 3
    feed(s, '\x1b[2@')     # ICH: insert 2 blanks
    feed(s, 'IJ')
    feed(s, '\x1b[1P')     # DCH: delete 1 char


def cls_clear_class(s, cycle: int) -> None:
    # 3. clear-class (linebuf_clear_line / linebuf_clear): EL alternating
    # with ED2 across cycles so both clear paths get exercised.
    feed(s, f'\x1b[4;1Hclearme{cycle % 10}')
    if cycle % 2 == 0:
        feed(s, '\x1b[4;1H\x1b[K')  # EL: erase to end of line
    else:
        feed(s, '\x1b[2J')          # ED2: erase display


def cls_decstbm_region_rotate(s, cycle: int) -> None:
    # 4. DECSTBM region rotate: set a scroll region, rotate it both
    # directions (IND at the region bottom, RI at the region top), then
    # restore full-screen margins -- the retire map touches line-buf
    # permute-adjacent paths here (W24 recorded-condition-2 precedent).
    feed(s, '\x1b[2;5r')
    feed(s, f'\x1b[5;1Hrot{cycle % 10}\n')   # IND at region bottom
    feed(s, '\x1b[2;1H\x1bM')                # RI at region top
    feed(s, '\x1b[r')                        # restore full-screen margins


def cls_scroll_flood(s, cycle: int) -> None:
    # 5. scroll flood: deep enough to force history handover of a slot
    # that may be held by the paused snapshot.
    for i in range(10):
        feed(s, f'flood{cycle:03d}-{i:02d}\r\n')


def cls_hyperlink_remap(s, cycle: int) -> None:
    # 6. hyperlink remap: feed distinct OSC 8 ids, then force the GC/remap
    # explicitly (screen_garbage_collect_hyperlink_pool ->
    # remap_hyperlink_ids, hyperlink.c:93/120/136) rather than waiting on
    # the organic 8192-add threshold.
    for i in range(6):
        feed(s, f'\x1b]8;;http://w25.test/{cycle}-{i}\x1b\\H{cycle % 10}{i}\x1b]8;;\x1b\\')
    s.garbage_collect_hyperlink_pool()


def cls_resize_while_paused(s, cycle: int) -> None:
    # 7. resize-while-paused: same columns, different line count -- no
    # rewrap, just a geometry realloc. screen_resize() calls
    # screen_pause_rendering(self, false, 0) as its FIRST statement
    # (reset site #5, W25-THREAD-AUDIT.md Part (b)), so this call ends
    # the pause as a side effect; re-BSU afterwards so classes 8/9 still
    # run under pause.
    lines, cols = s.lines, s.columns
    delta = 1 if cycle % 2 == 0 else -1
    new_lines = max(1, lines + delta)
    s.resize(new_lines, cols)
    s.resize(lines, cols)  # restore original geometry
    s.pause_rendering(True, 5000)


def cls_rewrap_while_paused(s, cycle: int) -> None:
    # 8. rewrap-while-paused: different columns on a screen with history
    # (setup_screen_with_history seeds it) -- forces resize.c's fresh-pool
    # rewrap path. Same auto-unpause/re-BSU caveat as class 7.
    lines, cols = s.lines, s.columns
    delta = 2 if cycle % 2 == 0 else -2
    new_cols = max(4, cols + delta)
    s.resize(lines, new_cols)
    s.resize(lines, cols)  # restore original geometry
    s.pause_rendering(True, 5000)


def cls_alt_screen_switch(s, cycle: int) -> None:
    # 9. alt-screen switch: per W25-THREAD-AUDIT.md Part (b) site #12,
    # screen_toggle_screen_buffer does NOT reset paused_rendering -- the
    # snapshot survives the toggle by design-vs-code delta. Safe under
    # pause today.
    feed(s, '\x1b[?1049h')
    feed(s, f'alt{cycle:04d}')
    feed(s, '\x1b[?1049l')


_WRITE_CLASS_FUNCS = (
    cls_append_draw_notrack,
    cls_irm_insert_delete,
    cls_clear_class,
    cls_decstbm_region_rotate,
    cls_scroll_flood,
    cls_hyperlink_remap,
    cls_resize_while_paused,
    cls_rewrap_while_paused,
    cls_alt_screen_switch,
)
assert len(_WRITE_CLASS_FUNCS) == len(WRITE_CLASS_NAMES)


# Battery split (M3): classes that KEEP the pause alive (1-6 + alt-screen,
# which does NOT reset the pause -- W25-THREAD-AUDIT Part (b) site 12) vs
# the two that funnel through the auto-unpause (resize/rewrap, site 5).
# The battery's frozen-snapshot byte compare is meaningful only while the
# ORIGINAL pause is still held, i.e. after the first group and before the
# resetting group.
_PAUSE_KEEPING_IDXS = (0, 1, 2, 3, 4, 5, 8)
_PAUSE_RESETTING_IDXS = (6, 7)


def compose_write_storm_frozen(s, cycle: int) -> list:
    """The pause-keeping write classes (the original BSU stays held)."""
    for i in _PAUSE_KEEPING_IDXS:
        _WRITE_CLASS_FUNCS[i](s, cycle)
    return [WRITE_CLASS_NAMES[i] for i in _PAUSE_KEEPING_IDXS]


def compose_write_storm_resetting(s, cycle: int) -> list:
    """resize/rewrap-while-paused: each funnels the auto-unpause (reset
    site 5) and re-issues BSU internally."""
    for i in _PAUSE_RESETTING_IDXS:
        _WRITE_CLASS_FUNCS[i](s, cycle)
    return [WRITE_CLASS_NAMES[i] for i in _PAUSE_RESETTING_IDXS]


def compose_write_storm(s, cycle: int) -> list:
    """Run all 9 pinned write classes, in order, against `s`.

    Returns the ordered list of class names exercised (always all 9 --
    composing every class every cycle is what satisfies AC-5's "not 50
    trivial storms" bar). Classes 7/8 internally end and re-start the
    pause (see their docstrings); the caller must not assume the screen
    is still paused between calls, only that it is paused again by the
    time this function returns (as long as it was paused on entry).
    """
    for fn in _WRITE_CLASS_FUNCS:
        fn(s, cycle)
    return list(WRITE_CLASS_NAMES)


def capture_shadow(s, reader: str = 'stubbed') -> list:
    """Shadow deep copy taken at BSU, before the first storm write.

    reader == 'available' (M3+): per-row raw (cpu_bytes, gpu_bytes) via the
    Lane-S debug accessor `Screen.paused_snapshot_row_bytes(y)`. At BSU the
    snapshot equals the live grid BY DEFINITION in both worlds (deep-copy:
    just copied; SHARE: shared slots not yet retired), so this IS the
    live-grid deep copy the plan's battery clause (a) names -- and the
    Python-held bytes cannot alias pool storage.
    reader == 'stubbed' (M2 form): text + spot attributes via existing
    bindings (`Line.__str__`, `Line.cursor_from`)."""
    if reader == 'available':
        return [s.paused_snapshot_row_bytes(y) for y in range(s.lines)]
    rows = []
    for y in range(s.lines):
        line = s.line(y)
        c = line.cursor_from(0)
        rows.append({'text': str(line), 'fg': c.fg, 'bg': c.bg, 'bold': c.bold})
    return rows


def compare_snapshot_to_shadow(s, shadow: list, reader: str = 'stubbed') -> dict:
    """Compare the paused snapshot's row bytes against `shadow`.

    `reader` is 'stubbed' (M2 default) or 'available'. The read path for
    snapshot bytes does not exist yet: only render paths (shaders.c:766,
    screen.c:4026-4035/4283-4287) and current_selections() read
    `paused_rendering.linebuf`, and neither exposes row content to Python
    (W25-THREAD-AUDIT.md Part (a).1; `.omc/verify/wave25/M2-SCOPING.md`
    records the M2 scoping decision). 'stubbed' returns a sentinel result
    without asserting anything about snapshot correctness -- it never
    fabricates a pass. When the Lane-S debug accessor lands (M3; name
    TBD, e.g. `Screen.paused_snapshot_row_bytes(y)`), swap the body of
    the `reader == 'available'` branch below for a real per-row byte
    comparison -- a ONE-FUNCTION swap, no caller changes required.
    """
    if reader == 'stubbed':
        return {'reader': 'stubbed', 'rows_checked': 0, 'mismatches': None}
    if reader != 'available':
        raise ValueError(f'unknown snapshot reader mode: {reader!r}')
    mismatches = []
    for y, expected in enumerate(shadow):
        actual = s.paused_snapshot_row_bytes(y)  # Lane-S debug accessor (M3)
        if actual != expected:
            mismatches.append(y)
    return {'reader': 'available', 'rows_checked': len(shadow), 'mismatches': mismatches}


# -- SHARE=1 (ON-arm) subprocess harness ----------------------------------
#
# KITTY_PAUSE_SNAPSHOT_SHARE resolves from the environment exactly ONCE per
# process (line-buf.c:76-82, `pause_snapshot_share_state`) -- and the first
# call anywhere in the process locks the resolution in (e.g. `history.c:53`
# checks it on every scroll, not just the first `pause_rendering()` call).
# Since test.py runs every kitty_tests module in one process, another module
# may already have resolved the one-shot switch (at whatever this build's
# default is) before this one even starts. A fresh subprocess with the env
# var set explicitly before Python starts is therefore the only robust way
# to pin EITHER arm from kitty_tests.
_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def run_share_subprocess(body: str, share: str = '1') -> dict:
    """Run `body` in a fresh subprocess with KITTY_PAUSE_SNAPSHOT_SHARE=`share`.

    share='1' pins the ON arm; share='0' pins the explicit-OFF (deep-copy)
    arm -- both are meaningful whatever the build default resolves to.

    `body` is Python source with `feed`, `setup_screen_with_history`, `COLS`,
    `LINES`, `SCROLLBACK` and a ready-made screen `s` (via
    `kitty_tests.BaseTest.create_screen`) already in scope; it must
    `print(json.dumps(...))` its verdict as the LAST line of stdout. Returns
    the parsed dict. A non-zero exit or unparseable stdout raises
    AssertionError with the full stdout/stderr attached -- a subprocess
    crash or a failed `assert` inside `body` is a real, loud test failure,
    never a silent skip.
    """
    script = (
        'import json, sys\n'
        f'sys.path.insert(0, {_REPO_ROOT!r})\n'
        'from kitty_tests.base import BaseTest, parse_bytes\n'
        'from kitty_tests.slot_cow import COLS, LINES, SCROLLBACK, feed, setup_screen_with_history\n'
        't = BaseTest()\n'
        's = t.create_screen(cols=COLS, lines=LINES, scrollback=SCROLLBACK)\n'
        + body
    )
    env = dict(os.environ)
    env['KITTY_PAUSE_SNAPSHOT_SHARE'] = share
    proc = subprocess.run(
        [sys.executable, '-c', script], cwd=_REPO_ROOT, env=env,
        capture_output=True, text=True, timeout=60,
    )
    if proc.returncode != 0:
        raise AssertionError(
            f'KITTY_PAUSE_SNAPSHOT_SHARE={share} subprocess exited {proc.returncode}\n'
            f'--- stdout ---\n{proc.stdout}\n--- stderr ---\n{proc.stderr}'
        )
    lines = [ln for ln in proc.stdout.splitlines() if ln.strip()]
    if not lines:
        raise AssertionError(f'SHARE={share} subprocess produced no stdout verdict; stderr={proc.stderr!r}')
    try:
        return json.loads(lines[-1])
    except ValueError as err:
        raise AssertionError(f'SHARE={share} subprocess stdout was not valid JSON: {lines[-1]!r}; stderr={proc.stderr!r}') from err


class TestSlotCOW(BaseTest):

    # -- In-process tests: they run at whatever the build default resolves
    # -- to and assert only what must hold in BOTH worlds -- no crash, and
    # -- live content fidelity across a storm composing all 9 write
    # -- classes. Arm-specific semantics live in the subprocess tests.

    def test_pause_storm_unpause_roundtrip_content_fidelity(self):
        s = self.create_screen(cols=COLS, lines=LINES, scrollback=SCROLLBACK)
        setup_screen_with_history(s)
        for cycle in range(5):
            with self.subTest(cycle=cycle):
                self.assertTrue(s.pause_rendering(True, 5000))
                shadow = capture_shadow(s)
                cmp_result = compare_snapshot_to_shadow(s, shadow, reader='stubbed')
                self.ae(cmp_result['reader'], 'stubbed')
                classes = compose_write_storm(s, cycle)
                self.ae(list(classes), list(WRITE_CLASS_NAMES))
                sentinel = f'END{cycle:04d}'
                feed(s, f'\x1b[1;1H\x1b[K{sentinel}')
                # pause_rendering(False) is a harmless no-op if classes
                # 7/8 already left the screen unpaused; it always returns
                # without raising.
                s.pause_rendering(False)
                self.ae(str(s.line(0)), sentinel, f'cycle {cycle}: live content did not match the storm-composed expectation')

    # -- Reset-site bypass scenarios (W25-THREAD-AUDIT.md Part (b)) -----
    # -- Each test asserts something concrete and observable about
    # -- TODAY's funnel/bypass behavior via the pause_rendering() return
    # -- value, not just "did not crash" -- except the dealloc case, where
    # -- Python object teardown genuinely has no other observable surface.

    def test_reset_site_bypass_dealloc(self):
        # Site #11 (screen.c:693-703): dealloc bypasses the unpause
        # funnel. In the deep-copy world (explicit OFF, or wherever the
        # default resolves OFF) there is no refcount/pool state to leak, so
        # the only honest assertion in-process is "does not crash."
        s = self.create_screen(cols=COLS, lines=LINES, scrollback=SCROLLBACK)
        self.assertTrue(s.pause_rendering(True, 5000))
        feed(s, 'still-paused')
        del s
        gc.collect()  # no exception/crash on collection while paused

        # Lane S landed: under SHARE=1 there IS refcount/pool state at this
        # bypass, and dealloc now calls the release helper
        # (screen_share_release_snapshot, screen.c:695-697) BEFORE
        # Py_CLEAR(linebuf) precisely to avoid leaking it. That helper ends
        # with `assert(self->paused_rendering.share_held == 0)`
        # (screen.c:3653, W25-THREAD-AUDIT.md assertion 4) -- if the release
        # were missing, wrongly ordered, or unbalanced, this subprocess
        # would abort with a non-zero exit instead of printing its verdict,
        # which `run_share_subprocess` turns into a loud test failure.
        result = run_share_subprocess('''
assert s.pause_rendering(True, 5000)
feed(s, "still-paused")
stats = s.slot_share_stats()
del s
import gc
gc.collect()  # dealloc runs here, mid-pause, with refs genuinely held

print(json.dumps({"held_before_dealloc": stats["held"]}))
''')
        self.assertGreater(result['held_before_dealloc'], 0, 'setup did not actually hold refs before dealloc -- this test would be vacuous')

    def test_reset_site_bypass_resize_triggering_realloc(self):
        # Site #5 (screen.c:544): screen_resize() calls
        # screen_pause_rendering(self, false, 0) as its FIRST statement,
        # funneled but running BEFORE any geometry work. Verify this
        # concretely: pause, resize (different cols -> geometry realloc),
        # then pause_rendering(False) must return False because the
        # resize already ended the pause.
        s = self.create_screen(cols=COLS, lines=LINES, scrollback=SCROLLBACK)
        setup_screen_with_history(s)
        self.assertTrue(s.pause_rendering(True, 5000))
        s.resize(LINES, COLS + 4)
        self.assertFalse(s.pause_rendering(False), 'resize did not end the pause via the site-#5 funnel as documented')
        feed(s, 'post-realloc')  # screen remains usable afterwards

        # Lane S landed: under SHARE=1 the site-#5 funnel now also RELEASES
        # held slot refs (release-all-FIRST) before resize does any geometry
        # work. Verify concretely: the pool anchor and every held ref must
        # be gone immediately after resize() returns (before any subsequent
        # pause), and a fresh pause afterward must acquire cleanly against
        # the new geometry.
        result = run_share_subprocess('''
assert s.pause_rendering(True, 5000)
before = s.slot_share_stats()
s.resize(LINES, COLS + 4)
after_resize = s.slot_share_stats()
esu_was_noop = s.pause_rendering(False) is False
fresh_ok = s.pause_rendering(True, 5000)
after_fresh = s.slot_share_stats()
assert s.pause_rendering(False)

print(json.dumps({
    "held_before": before["held"],
    "lines": LINES,
    "share_pool_active_after_resize": after_resize["share_pool_active"],
    "held_after_resize": after_resize["held"],
    "esu_was_noop": esu_was_noop,
    "fresh_ok": fresh_ok,
    "held_after_fresh": after_fresh["held"],
}))
''')
        self.ae(result['held_before'], result['lines'], 'setup did not hold every row before resize')
        self.ae(result['share_pool_active_after_resize'], 0, 'resize did not release the pool anchor via the site-#5 funnel')
        self.ae(result['held_after_resize'], 0, 'resize left rows held -- the release-all-FIRST discipline was violated')
        self.assertTrue(result['esu_was_noop'], 'resize did not already end the pause via the site-#5 funnel')
        self.assertTrue(result['fresh_ok'], 'a fresh pause after resize failed to acquire against the new geometry/pool')
        self.ae(result['held_after_fresh'], result['lines'], 'fresh pause after resize did not hold the new geometry correctly')

    def test_reset_site_bypass_screen_reset_ris(self):
        # Site #4 (screen.c:183): RIS (screen_reset) routes through the
        # funnel. Verify concretely: pause, feed RIS, then
        # pause_rendering(False) must return False (already unpaused).
        s = self.create_screen(cols=COLS, lines=LINES, scrollback=SCROLLBACK)
        self.assertTrue(s.pause_rendering(True, 5000))
        feed(s, '\x1bc')  # RIS
        self.assertFalse(s.pause_rendering(False), 'RIS did not end the pause via the site-#4 funnel as documented')

    def test_reset_site_bypass_alt_screen_toggle_survives_pause(self):
        # Site #12 (screen.c:1863-1899, screen_toggle_screen_buffer): the
        # design-vs-code delta the audit records -- NO reset exists at
        # HEAD, so the pause survives the toggle. Verify concretely:
        # pause, toggle to alt screen and back, then pause_rendering(True)
        # must return False (still paused, not a fresh BSU) BEFORE we
        # finally unpause.
        s = self.create_screen(cols=COLS, lines=LINES, scrollback=SCROLLBACK)
        self.assertTrue(s.pause_rendering(True, 5000))
        feed(s, '\x1b[?1049h')
        feed(s, 'alt-content')
        feed(s, '\x1b[?1049l')
        self.assertFalse(s.pause_rendering(True, 5000), 'alt-screen toggle unexpectedly reset the pause (site-#12 delta no longer holds)')
        self.assertTrue(s.pause_rendering(False))

    # -- Lane-S semantics (landed at M3, commits bbf47373e + 5816866df).
    # -- Every ON-arm scenario below runs in a subprocess with
    # -- KITTY_PAUSE_SNAPSHOT_SHARE=1 set BEFORE the interpreter starts
    # -- (see `run_share_subprocess`'s docstring for why this module cannot
    # -- just set os.environ in-process). Each assertion is a real,
    # -- falsifiable delta on `Screen.slot_share_stats()` /
    # -- `Screen.paused_snapshot_row_bytes()` -- not a >= 0 tautology.

    def test_refcount_lane_bsu_incref_cow_no_decref_release_single_decref(self):
        # (a) BSU acquire increfs each grid-backed slot exactly once; a COW
        # retire (linebuf_share_retire -> linebuf_share_retire_cold,
        # line-buf.c:131-149) does NOT decref -- held/lane_refsum are
        # untouched by a write into a held row; the single decref site is
        # snapshot Release (ESU, line_slot_pool_slot_decref,
        # line-buf.c:103-121), which pushes a retired, now-unheld slot to
        # the free-list (LIFO); the NEXT retire-alloc pops that freed slot
        # before growing the pool.
        result = run_share_subprocess('''
before_bsu = s.slot_share_stats()
assert s.pause_rendering(True, 5000), "BSU acquire must succeed on a fresh, never-paused screen"
after_bsu = s.slot_share_stats()

before_write = s.slot_share_stats()
feed(s, "\\x1b[1;1HX")  # single-cell draw into a held row -> must retire, never decref
after_write = s.slot_share_stats()

before_esu = s.slot_share_stats()
esu_ok = s.pause_rendering(False)
after_esu = s.slot_share_stats()

# Second write storm: pause again and retire exactly one row -- the
# retire-alloc must LIFO-pop the slot just freed instead of growing the pool.
before_reuse = s.slot_share_stats()
assert s.pause_rendering(True, 5000)
feed(s, "\\x1b[1;1HY")
after_reuse = s.slot_share_stats()
assert s.pause_rendering(False)

print(json.dumps({
    "lines": s.lines,
    "held_at_bsu": after_bsu["held"],
    "lane_refsum_at_bsu": after_bsu["lane_refsum"],
    "rows_ref_delta_at_bsu": after_bsu["rows_ref"] - before_bsu["rows_ref"],
    "cow_retires_delta_after_write": after_write["cow_retires"] - before_write["cow_retires"],
    "held_delta_after_write": after_write["held"] - before_write["held"],
    "lane_refsum_delta_after_write": after_write["lane_refsum"] - before_write["lane_refsum"],
    "esu_ok": esu_ok,
    "held_after_esu": after_esu["held"],
    "lane_refsum_after_esu": after_esu["lane_refsum"],
    "free_count_delta_after_esu": after_esu["free_count"] - before_esu["free_count"],
    "share_pool_active_after_esu": after_esu["share_pool_active"],
    "slots_used_delta_after_reuse": after_reuse["slots_used"] - before_reuse["slots_used"],
    "free_count_delta_after_reuse": after_reuse["free_count"] - before_reuse["free_count"],
}))
''')
        lines = result['lines']
        self.ae(result['held_at_bsu'], lines, 'BSU must hold every grid-backed row')
        self.ae(result['lane_refsum_at_bsu'], lines, 'BSU must incref every held slot exactly once')
        self.ae(result['rows_ref_delta_at_bsu'], lines, 'every row at BSU on an unscrolled screen must be acquired by reference')
        self.ae(result['cow_retires_delta_after_write'], 1, 'a write into a held row must retire exactly once')
        self.ae(result['held_delta_after_write'], 0, 'a COW retire must never change held (retire never decrefs)')
        self.ae(result['lane_refsum_delta_after_write'], 0, 'a COW retire must never change lane_refsum (retire never decrefs)')
        self.assertTrue(result['esu_ok'], 'ESU must end the pause that was just acquired')
        self.ae(result['held_after_esu'], 0, 'ESU (Release) must decref every held slot')
        self.ae(result['lane_refsum_after_esu'], 0, 'ESU (Release) must decref every held slot')
        self.ae(result['free_count_delta_after_esu'], 1, 'Release must push exactly the one retired slot to the free-list')
        self.ae(result['share_pool_active_after_esu'], 0, 'Release must drop the pool lifetime anchor')
        self.ae(result['slots_used_delta_after_reuse'], 0, 'the next retire-alloc must LIFO-pop the freed slot instead of growing the pool')
        self.ae(result['free_count_delta_after_reuse'], -1, 'the LIFO pop must drain exactly the one slot freed above')

    def test_pool_identity_across_rewrap_while_paused(self):
        # (b) Design-vs-code finding (code-verified against resize.c:297-303
        # and W25-THREAD-AUDIT.md Part (b) row 5): screen_resize()'s FIRST
        # statement funnels screen_pause_rendering(self, false, 0), which
        # runs screen_share_release_snapshot() (screen.c:3635-3657) BEFORE
        # resize_screen_buffers() ever allocates the fresh rewrap pool. This
        # release-all-FIRST discipline means the snapshot never has a chance
        # to observe -- let alone outlive into -- the rewrap's fresh pool;
        # the old design concern ("the snapshot holds the OLD LineSlotPool
        # alive via refcnt across rewrap") does not arise at HEAD because
        # nothing is held by the time rewrap allocates the new pool. What
        # IS observable and worth asserting: held drops to 0 and the pool
        # anchor is dropped strictly BEFORE the rewrap (share_pool_active
        # == 0 immediately after resize() returns), and a fresh pause
        # after a rewrap-forcing resize (history present, columns change)
        # acquires cleanly against the NEW geometry/pool.
        result = run_share_subprocess('''
setup_screen_with_history(s)
orig_lines, orig_cols = s.lines, s.columns
assert s.pause_rendering(True, 5000)
before = s.slot_share_stats()
s.resize(orig_lines + 1, orig_cols + 4)  # lines AND cols change -> forces a real rewrap
after_resize = s.slot_share_stats()
esu_was_noop = s.pause_rendering(False) is False
fresh_ok = s.pause_rendering(True, 5000)
after_fresh = s.slot_share_stats()
assert s.pause_rendering(False)

print(json.dumps({
    "held_before": before["held"],
    "orig_lines": orig_lines,
    "share_pool_active_after_resize": after_resize["share_pool_active"],
    "held_after_resize": after_resize["held"],
    "esu_was_noop": esu_was_noop,
    "fresh_ok": fresh_ok,
    "new_lines": s.lines,
    "held_after_fresh": after_fresh["held"],
}))
''')
        self.ae(result['held_before'], result['orig_lines'], 'setup did not hold every row before the rewrap-forcing resize')
        self.ae(result['share_pool_active_after_resize'], 0, 'resize must release the pool anchor via the site-5 funnel before rewrap runs')
        self.ae(result['held_after_resize'], 0, 'resize must drop every held ref via the site-5 funnel before rewrap runs')
        self.assertTrue(result['esu_was_noop'], 'resize must already have ended the pause via the site-5 funnel')
        self.assertTrue(result['fresh_ok'], 'a fresh pause after a rewrap-forcing resize must acquire cleanly')
        self.ae(result['held_after_fresh'], result['new_lines'], 'the fresh pause after resize must hold the NEW geometry, not the old one')

    def test_retire_before_lineptr_invariant(self):
        # (c) For each Sec.3 handout-helper class, cow_retire() must run
        # BEFORE cpu_lineptr/gpu_lineptr is computed: the snapshot's frozen
        # bytes for the target row must be byte-identical before and after
        # the write (the write always lands on the FRESH post-retire slot),
        # and a retire must actually have fired. Concrete VT triggers per
        # class (line-buf.c call sites, all code-verified this pass):
        #   draw               -> linebuf_init_cells_notrack (line-buf.c:318-327), screen.c:776 hot path
        #   IRM insert         -> linebuf_init_cells (line-buf.c:298-315), ICH
        #   ED clear (non-private, whole display) -> linebuf_clear_lines (line-buf.c:369-389), screen.c:2883 (\x1b[2J)
        #   SGR/erase-char     -> linebuf_init_line (line-buf.c:353-366), ECH (screen.c:3033) -- EL (\x1b[K) hits this SAME wrapper (screen.c:2775), not a distinct class
        #   TAB space-fill     -> linebuf_cpu_cells_for_line (line-buf.c:330-336), screen_tab (screen.c:2266)
        #   wrap-flag set      -> linebuf_set_last_char_as_continuation (line-buf.c:415-422), continue_to_next_line (screen.c:726-727)
        # All six target physical row 0 (a fresh pause/write/unpause bracket
        # per class keeps them independent); wrap-flag necessarily shares
        # its retire with the draw that fills the row (there is no VT
        # sequence that reaches the wrap boundary without drawing into the
        # row first) -- the assertion that matters (retire-before-mutate,
        # frozen bytes) holds regardless of which call site paid it.
        result = run_share_subprocess('''
CLASSES = [
    ("draw_notrack", "D"),
    ("irm_insert_init_cells", "\\x1b[2@"),
    ("ed_whole_display_clear_lines", "\\x1b[2J"),
    ("erase_char_init_line_wrapper", "\\x1b[1X"),
    ("tab_space_fill_cpu_cells_for_line", "\\t"),
    ("wrap_flag_set", "X" * (COLS + 2)),
]
classes = {}
for name, seq in CLASSES:
    assert s.pause_rendering(True, 5000), name
    feed(s, "\\x1b[1;1H")  # cursor -> row 0 col 0, fresh each cycle
    before_bytes = s.paused_snapshot_row_bytes(0)
    before_retires = s.slot_share_stats()["cow_retires"]
    feed(s, "\\x1b[1;1H" + seq)
    after_bytes = s.paused_snapshot_row_bytes(0)
    after_retires = s.slot_share_stats()["cow_retires"]
    classes[name] = {
        "frozen": before_bytes == after_bytes,
        "retire_delta": after_retires - before_retires,
    }
    assert s.pause_rendering(False), name

print(json.dumps({"classes": classes}))
''')
        for name, outcome in result['classes'].items():
            self.assertTrue(outcome['frozen'], f'{name}: snapshot row bytes changed after a write into a held row (retire-before-lineptr violated)')
            self.assertGreaterEqual(outcome['retire_delta'], 1, f'{name}: writing into a held row did not retire')

    def test_history_row_serial0_unconditional_copy(self):
        # (d) History rows (y < scrolled_by) are never acquired by slot-id
        # reference, even under SHARE=1 -- the W21 serial-0 rule
        # (screen.c:3752-3756: `share_rows = share && self->scrolled_by ==
        # 0`). Scroll into history so scrolled_by != 0, then pause: every
        # row (grid AND history-backed) must fall back to the whole-snapshot
        # deep copy -- held/lane_refsum stay 0, no row is acquired by
        # reference, and the snapshot bytes are still well-formed.
        result = run_share_subprocess('''
setup_screen_with_history(s)
before = s.slot_share_stats()
scrolled = s.scroll(3, True)
bsu_ok = s.pause_rendering(True, 5000)
after = s.slot_share_stats()
snap_ok = all(s.paused_snapshot_row_bytes(y) is not None for y in range(s.lines))
assert s.pause_rendering(False)

print(json.dumps({
    "scrolled": scrolled,
    "scrolled_by": s.scrolled_by,
    "bsu_ok": bsu_ok,
    "held": after["held"],
    "lane_refsum": after["lane_refsum"],
    "rows_ref_delta": after["rows_ref"] - before["rows_ref"],
    "share_pool_active": after["share_pool_active"],
    "snap_ok": snap_ok,
}))
''')
        self.assertTrue(result['scrolled'], 'scroll(3, True) must move the viewport given the seeded history')
        self.assertNotEqual(result['scrolled_by'], 0, 'scrolled_by must be non-zero for this to be a meaningful test of the serial-0 rule')
        self.assertTrue(result['bsu_ok'], 'BSU acquire must still succeed while scrolled')
        self.ae(result['held'], 0, 'a scrolled snapshot must never acquire any row by reference (W21 serial-0 rule)')
        self.ae(result['lane_refsum'], 0, 'a scrolled snapshot must never incref any slot')
        self.ae(result['rows_ref_delta'], 0, 'a scrolled snapshot must deep-copy every row, sharing none')
        self.ae(result['share_pool_active'], 0, 'a scrolled snapshot must not hold the pool lifetime anchor')
        self.assertTrue(result['snap_ok'], 'the deep-copied snapshot rows must still be readable')

    def test_deferred_row_finalize_before_incref_no_false_cow(self):
        # (e) A deferred (is_blank) grid row is finalized in the LIVE row
        # BEFORE its slot is increffed at BSU acquire (screen.c:3801-3819,
        # Critic IMPORTANT-1) -- no retire can fire DURING the acquire
        # itself, because no snapshot refcount exists on any row until the
        # acquire loop's own incref runs (screen.c:3639 makes BSU-while-
        # paused a no-op, so no snapshot is ever held going into an
        # acquire). Forcing is_blank deterministically from Python is not
        # possible (per the module docstring); the honest, always-true
        # form of this invariant is: the acquire call itself pays zero
        # retires, regardless of how many deferred rows exist, and the
        # snapshot it produces is immediately well-formed. The is_blank-
        # armed variant specifically is additionally covered by the write
        # storm's class composition (scroll flood + draw) in
        # `scripts/w25_cow_battery.py`.
        result = run_share_subprocess('''
for i in range(20):
    feed(s, f"flood{i:03d}\\r\\n")  # scroll flood: leaves freshly-scrolled rows lazily cleared
before = s.slot_share_stats()
bsu_ok = s.pause_rendering(True, 5000)
after = s.slot_share_stats()
snap = [s.paused_snapshot_row_bytes(y) for y in range(s.lines)]
snap_ok = all(row is not None and len(row[0]) > 0 and len(row[1]) > 0 for row in snap)
assert s.pause_rendering(False)

print(json.dumps({
    "bsu_ok": bsu_ok,
    "retire_delta_during_acquire": after["cow_retires"] - before["cow_retires"],
    "held": after["held"],
    "lines": s.lines,
    "snap_ok": snap_ok,
}))
''')
        self.assertTrue(result['bsu_ok'], 'BSU acquire must succeed after a scroll flood')
        self.ae(result['retire_delta_during_acquire'], 0, 'the acquire itself must never pay a retire (finalize-before-incref, no false COW)')
        self.ae(result['held'], result['lines'], 'every grid row must still be held after the flood (no scroll offset)')
        self.assertTrue(result['snap_ok'], 'the freshly-acquired snapshot rows must be well-formed')

    def test_incref_overflow_debug_assert(self):
        # (f) assert(refcount[slot] < UINT16_MAX) at incref (line-buf.c:99,
        # ARCH NOTE-2) is debug-build only and setup.py's release build
        # appends -DNDEBUG, so it cannot be exercised directly from a
        # kitty_tests run. The documented bound it protects IS testable:
        # per-slot holders are {0,1} today (one snapshot per screen), so
        # lane_refsum can never exceed `lines` across any number of
        # pause/unpause cycles. 50 cycles, each with a write into a held
        # row so both the incref and the retire paths run every cycle.
        result = run_share_subprocess('''
max_lane_refsum = 0
for cycle in range(50):
    assert s.pause_rendering(True, 5000), cycle
    stats = s.slot_share_stats()
    max_lane_refsum = max(max_lane_refsum, stats["lane_refsum"])
    assert stats["held"] <= s.lines, (cycle, stats["held"], s.lines)
    assert stats["lane_refsum"] <= s.lines, (cycle, stats["lane_refsum"], s.lines)
    feed(s, f"\\x1b[1;1Hc{cycle % 10}")
    assert s.pause_rendering(False), cycle

print(json.dumps({"cycles": 50, "max_lane_refsum": max_lane_refsum, "lines": s.lines}))
''')
        self.ae(result['cycles'], 50)
        self.assertLessEqual(result['max_lane_refsum'], result['lines'], 'lane_refsum exceeded lines -- the documented {0,1}-holder bound (incref-overflow assert) was violated')
    # -- Explicit-OFF legs (W26 F3): pin the OPT-OUT world by value so its
    # -- deep-copy semantics keep permanent unit coverage regardless of the
    # -- build default (the W26 flip made unset resolve ON; SHARE='0' is
    # -- now the only spelling of the deep-copy world).

    def test_explicit_off_roundtrip_content_fidelity(self):
        verdict = run_share_subprocess("""
import json
from kitty_tests.slot_cow import compose_write_storm, WRITE_CLASS_NAMES
setup_screen_with_history(s)
st0 = s.slot_share_stats()
assert s.pause_rendering(True, 5000)
st1 = s.slot_share_stats()
classes = compose_write_storm(s, 0)
feed(s, '\x1b[1;1H\x1b[KOFFEND')
s.pause_rendering(False)
st2 = s.slot_share_stats()
print(json.dumps({
    'classes': len(classes),
    'line0': str(s.line(0)),
    'held_at_bsu': st1['held'], 'refsum_at_bsu': st1['lane_refsum'],
    'rows_ref_delta': st1['rows_ref'] - st0['rows_ref'],
    'retires_delta': st2['cow_retires'] - st0['cow_retires'],
    'pool_active': st1['share_pool_active'],
}))
""", share='0')
        self.ae(verdict['classes'], 9)
        self.ae(verdict['line0'], 'OFFEND')
        self.ae(verdict['held_at_bsu'], 0)
        self.ae(verdict['refsum_at_bsu'], 0)
        self.ae(verdict['rows_ref_delta'], 0)
        self.ae(verdict['retires_delta'], 0)
        self.ae(verdict['pool_active'], 0)

    def test_explicit_off_funnel_resize_release(self):
        verdict = run_share_subprocess("""
import json
setup_screen_with_history(s)
assert s.pause_rendering(True, 5000)
before = s.slot_share_stats()
s.resize(LINES, COLS - 2)
mid = s.slot_share_stats()
ok_second = s.pause_rendering(True, 5000)
after = s.slot_share_stats()
s.pause_rendering(False)
print(json.dumps({
    'held_paused': before['held'], 'pool_active_paused': before['share_pool_active'],
    'held_after_resize': mid['held'], 'pool_active_after_resize': mid['share_pool_active'],
    'second_pause_ok': bool(ok_second), 'held_second': after['held'],
}))
""", share='0')
        self.ae(verdict['held_paused'], 0)
        self.ae(verdict['pool_active_paused'], 0)
        self.ae(verdict['held_after_resize'], 0)
        self.ae(verdict['pool_active_after_resize'], 0)
        self.assertTrue(verdict['second_pause_ok'])
        self.ae(verdict['held_second'], 0)
