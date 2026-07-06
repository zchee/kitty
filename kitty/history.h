/*
 * history.h
 * Copyright (C) 2024 Kovid Goyal <kovid at kovidgoyal.net>
 *
 * Distributed under terms of the GPL3 license.
 */

#pragma once

#include "line.h"
#include "line-pool.h"

typedef struct {
    void *ringbuf;
    size_t maximum_size;
    bool rewrap_needed;
} PagerHistoryBuf;


typedef struct {
    PyObject_HEAD

    index_type xnum, ynum;
    // cell storage lives in pool slots; slot_ring[position] holds the
    // slot id and attrs_ring[position] the per-line attrs (by value).
    // Positions are allocated lazily in chunks, like the segments the
    // pool replaced; the ring arrays hold ids/values, so realloc growth
    // is safe (slot ADDRESSES stay stable inside the pool's slabs).
    LineSlotPool *pool;
    index_type *slot_ring;
    LineAttrs *attrs_ring;
    index_type positions_allocated;
    PagerHistoryBuf *pagerhist;
    Line *line;
    TextCache *text_cache;
    index_type start_of_data, count;
} HistoryBuf;


HistoryBuf* alloc_historybuf(unsigned int, unsigned int, unsigned int, TextCache *tc);
HistoryBuf *historybuf_alloc_for_rewrap(unsigned int columns, HistoryBuf *self);
void historybuf_finish_rewrap(HistoryBuf *dest, HistoryBuf *src);
void historybuf_fast_rewrap(HistoryBuf *dest, HistoryBuf *src);
index_type historybuf_next_dest_line(HistoryBuf *self, ANSIBuf *as_ansi_buf, Line *src_line, index_type dest_y, Line *dest_line, bool continued);
bool historybuf_is_line_continued(HistoryBuf *self, index_type lnum);
void historybuf_delete_newest_lines(HistoryBuf *self, index_type count);
