/*
 * line-buf.h
 * Copyright (C) 2024 Kovid Goyal <kovid at kovidgoyal.net>
 *
 * Distributed under terms of the GPL3 license.
 */

#pragma once

#include "line.h"
#include "line-pool.h"
#include "text-cache.h"

typedef struct {
    PyObject_HEAD

    LineSlotPool *pool;  // cell storage; line_map[y] holds pool slot ids
    index_type xnum, ynum, *line_map, *scratch;
    LineAttrs *line_attrs;
    // Wave-15 L1: per-physical-row exclusive write high-water (xhwm), one entry
    // per row, indexed by lb_phys() exactly like line_attrs and permuted
    // alongside it. Meaningful ONLY while line_attrs[p].is_blank is set (a
    // deferred HWM row); linebuf_finalize_hwm_line reads it to skip the O(xnum)
    // backward xlimit scan. Lives in the same combined allocation as line_map.
    index_type *line_xlimit;
    // Wave-24 D0 (repurposed from the Wave-21 visual-key lane): CONTENT
    // generation of the pool slot currently mapped at each position, indexed
    // by lb_phys() and living in the same combined allocation. Written (ONLY
    // when pause_snapshot_cow_enabled()) as an ASSIGNMENT from the per-buffer
    // monotonic gen_counter — values are unique per LineBuf, so two equal
    // gens can only be the SAME assignment event carried along by the
    // co-rotation below (coincidental equality across position lanes is
    // structurally impossible; wrap caveat: 2^32 content writes between two
    // snapshots of one window, same class as the serial wrap). Assigned at
    // every content-write site including the three former W21 exceptions
    // (linebuf_clear_line, remap_hyperlink_ids, screen_tab's space-fill) and
    // the history slot handover (incoming slot never eligible). NEVER bumped
    // by pure line_map permutes: linebuf_normalize and the region
    // reorder ops CO-ROTATE this lane with line_map (same moves as
    // line_attrs/line_xlimit, switch-gated) so each entry stays attached to
    // the slot whose content it describes — that is the whole point of the
    // slot-anchored key (the pause snapshot compares by slot id, not visual
    // position; cell payloads themselves never move between slots).
    uint32_t *gen_at_pos;
    Line *line;
    TextCache *text_cache;
    // S3 (Phase 13B): head-offset circular indexing of line_map/line_attrs so a
    // marginless full-height scroll is an O(1) head bump instead of a memmove of
    // the whole range. Logical row y lives at physical lb_phys(y). Region
    // scrolls and the rare reorder ops (reverse-index, insert/delete lines)
    // normalize (head->0) first and keep their physical code. head is 0 for a
    // freshly allocated/resized buffer.
    index_type head;
    // Wave-21 L4: process-unique allocation serial (1-based; 0 is the
    // never-matches sentinel the pause snapshot writes for history-backed
    // rows). A resized/rewrapped/alt-screen LineBuf gets a fresh serial, so
    // snapshot keys recorded against a previous allocation are structurally
    // unable to match (slot/phys ABA guard). Assigned unconditionally at
    // alloc: one increment per LineBuf allocation, never on a hot path.
    uint32_t serial;
    // Wave-24 D0: monotonic source for gen_at_pos assignments (see the lane
    // comment above). Only advances when pause_snapshot_cow_enabled().
    uint32_t gen_counter;
} LineBuf;

// Wave-21 L4 (KITTY_PAUSE_SNAPSHOT_COW): one-shot process-lifetime switch,
// resolved at first use exactly like scroll_clear_mode() and NEVER re-read,
// so a mid-session env flip is structurally impossible. OFF (unset/"0") keeps
// the true legacy path: no generation bumps, no snapshot key bookkeeping.
extern int pause_snapshot_cow_state;  // -1 unresolved, else 0/1 (line-buf.c)
bool pause_snapshot_cow_resolve(void);
static inline bool
pause_snapshot_cow_enabled(void) {
    const int s = pause_snapshot_cow_state;
    return UNLIKELY(s < 0) ? pause_snapshot_cow_resolve() : s != 0;
}

// Wave-24 D0: record a content write to the slot mapped at physical
// position p. Callers pass lb_phys(y), or a raw physical index inside the
// head==0 reorder ops and the order-agnostic full-row loops. Assignment
// from the monotonic counter (not ++) so every write event carries a
// buffer-unique value — see the gen_at_pos lane comment.
static inline void
linebuf_gen_bump(LineBuf *self, index_type p) {
    if (UNLIKELY(pause_snapshot_cow_enabled())) self->gen_at_pos[p] = ++self->gen_counter;
}
static inline void
linebuf_gen_bump_range(LineBuf *self, index_type p_start, index_type p_end_incl) {
    if (UNLIKELY(pause_snapshot_cow_enabled())) {
        for (index_type p = p_start; p <= p_end_incl; p++) self->gen_at_pos[p] = ++self->gen_counter;
    }
}

// S3: map a logical row index to its physical slot in line_map/line_attrs.
// One add + predicated subtract (head+y < 2*ynum always), no divide.
static inline index_type
lb_phys(const LineBuf *lb, index_type y) {
    index_type p = lb->head + y;
    return p >= lb->ynum ? p - lb->ynum : p;
}

// Wave-15 L1: sentinel stored in line_xlimit[p] when a non-append mutator (IRM
// insert/delete shift, multicell nuke/halve, colored-blank) changes a deferred
// row's write extent in a way the draw notes do not describe. > xnum always, so
// linebuf_finalize_hwm_line falls back to the O(xnum) scan for that row (rare;
// never the scroll flood). PyMem_Calloc zero-inits line_xlimit, so a fresh row
// reads as 0 (tracked, empty) until a mutator marks it.
#define XLIMIT_UNTRACKED ((index_type)-1)

// Wave-15 L1 escape hatches, resolved once (pattern of scroll_clear_mode()).
// KITTY_DISABLE_XLIMIT_TRACK set & !="0" -> linebuf_finalize_hwm_line keeps the
// O(xnum) backward scan (Step-3 A/B; byte-identical to pre-L1). KITTY_XLIMIT_VERIFY=1
// -> every tracked-xhwm consumption ALSO runs the scan and abort()s on mismatch
// (runtime-gated, NOT assert -- setup.py appends -DNDEBUG). Both default off/on-track.
bool xlimit_track_disabled(void);
bool xlimit_verify_enabled(void);
// Wave-15 S1-lite (ADR §10c): full-row materialize of a deferred (is_blank) row --
// zero all GPU + drop is_blank + mark dirty. Called from the cursor-positioning
// commands so a following discontiguous write cannot leave stale interior-gap
// GPUCells. Self-gated on is_blank; a no-op under EAGER; off the append flood.
void linebuf_materialize_deferred_row(LineBuf *self, index_type y);

// Wave-15 L2 (DEFAULT ON since the 2026-07-07 flip; meaningful only under HWM;
// KITTY_ENABLE_CONSUMER_TAIL_CLIP=0 opts out back to the L1 finalize tail-zero).
// Defer the parse-side finalize tail-zero for scrolled/evicted rows -- carry
// is_blank to the visible + history render clip, which owns the GPUCell tail.
bool consumer_tail_clip_enabled(void);

// Wave-15 L1: raise row y's write-extent UPPER BOUND to x_excl -- the cursor
// column just past a draw store. A draw always advances the cursor past what it
// writes, so the running max is always >= the true extent; finalize scans
// backward from it (O(1) for the flood) instead of from xnum. Self-gates on
// is_blank: a no-op under EAGER (never is_blank) and RELOCATE (linebuf_init_cells
// materializes -> is_blank dropped before any store). Called right after each
// cursor-advancing print store; non-append mutators mark XLIMIT_UNTRACKED instead
// (see linebuf_init_cells).
static inline void
linebuf_note_write_extent(LineBuf *self, index_type y, index_type x_excl) {
    const index_type p = lb_phys(self, y);
    if (self->line_attrs[p].is_blank && x_excl > self->line_xlimit[p]) self->line_xlimit[p] = x_excl;
}

// Wave-15 L1: mark row y's extent UNTRACKED (finalize rescans from xnum). For the
// rare direct multi-row cell writers that bypass linebuf_init_cells' mark
// (multiline-multicell nuke via range_line_), whose spaces/clears the cursor
// bound cannot describe. Self-gates on is_blank; never the width-1 scroll flood.
static inline void
linebuf_mark_xlimit_untracked(LineBuf *self, index_type y) {
    const index_type p = lb_phys(self, y);
    if (self->line_attrs[p].is_blank) self->line_xlimit[p] = XLIMIT_UNTRACKED;
}

// S1/S2: the write-choke materialize (init_cells/init_line). The is_blank guard
// is inlined so the common EAGER path (is_blank never set) is a no-op with no
// call; the cold body (line-buf.c) is RELOCATE-only. HWM keeps is_blank until
// finalize, so its work is deferred, not done here.
void linebuf_materialize_blank_line(LineBuf *self, index_type y);
static inline void
linebuf_materialize_blank(LineBuf *self, index_type y) {
    if (self->line_attrs[lb_phys(self, y)].is_blank) linebuf_materialize_blank_line(self, y);
}

// The init_line choke (readers + colored-blank writers: erase/SGR/insert-char
// write cpu-blank + colored GPUCells). Make a deferred row authoritative first
// so its content is not later mistaken for a deferred tail: RELOCATE zeros the
// whole row, HWM finalizes (tail only) and drops is_blank. init_cells (the
// plain draw) uses linebuf_materialize_blank instead, keeping is_blank so HWM
// can clip the un-drawn tail at render.
void linebuf_make_authoritative_cold(LineBuf *self, index_type y);
static inline void
linebuf_make_authoritative(LineBuf *self, index_type y) {
    if (self->line_attrs[lb_phys(self, y)].is_blank) linebuf_make_authoritative_cold(self, y);
}


LineBuf* alloc_linebuf(unsigned int, unsigned int, TextCache*);
LineBuf* alloc_linebuf_with_pool(unsigned int, unsigned int, TextCache*, LineSlotPool*);
