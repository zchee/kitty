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
} LineBuf;


LineBuf* alloc_linebuf(unsigned int, unsigned int, TextCache*);
LineBuf* alloc_linebuf_with_pool(unsigned int, unsigned int, TextCache*, LineSlotPool*);
