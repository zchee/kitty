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
    Line *line;
    TextCache *text_cache;
    // S3 (Phase 13B): head-offset circular indexing of line_map/line_attrs so a
    // marginless full-height scroll is an O(1) head bump instead of a memmove of
    // the whole range. Logical row y lives at physical lb_phys(y). Region
    // scrolls and the rare reorder ops (reverse-index, insert/delete lines)
    // normalize (head->0) first and keep their physical code. head is 0 for a
    // freshly allocated/resized buffer.
    index_type head;
} LineBuf;

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
