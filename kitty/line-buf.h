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


LineBuf* alloc_linebuf(unsigned int, unsigned int, TextCache*);
LineBuf* alloc_linebuf_with_pool(unsigned int, unsigned int, TextCache*, LineSlotPool*);
