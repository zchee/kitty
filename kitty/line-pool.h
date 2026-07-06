/*
 * line-pool.h
 * Copyright (C) 2026 Kovid Goyal <kovid at kovidgoyal.net>
 *
 * Distributed under terms of the GPL3 license.
 */

// Slab pool of line slots (one slot = cpu[xnum] + gpu[xnum] cells) with
// stable addresses, shared between a LineBuf and its HistoryBuf so that
// scrolling can move lines by slot id instead of copying cells (Phase 10).
// Slabs never move or shrink; slot ids are monotonically handed out and
// never freed individually — containers exchange ids 1:1 (swap semantics),
// so the pool's high-water mark is bounded by lb->ynum + history capacity,
// the same envelope the previous block-per-container layout had.

#pragma once

#include "line.h"

typedef struct LineSlotSlab {
    CPUCell *cpu;
    GPUCell *gpu;
    void *mem;
} LineSlotSlab;

typedef struct LineSlotPool {
    index_type xnum;
    // slab capacity in slots, fixed per pool: sized exactly for
    // single-container private pools, history-segment-sized (2048) for
    // pools that grow with scrollback
    index_type slab_capacity;
    unsigned refcnt;
    size_t num_slabs, slots_used;
    LineSlotSlab *slabs;
} LineSlotPool;

LineSlotPool* line_slot_pool_alloc(index_type xnum, index_type slab_capacity);
void line_slot_pool_incref(LineSlotPool *pool);
void line_slot_pool_decref(LineSlotPool *pool);
// hands out the next unused slot, growing by one slab if needed; aborts
// on allocation failure like the rest of the cell-storage allocators
index_type line_slot_pool_take(LineSlotPool *pool);

static inline CPUCell*
pool_cpu_lineptr(const LineSlotPool *pool, index_type slot) {
    return pool->slabs[slot / pool->slab_capacity].cpu + (size_t)(slot % pool->slab_capacity) * pool->xnum;
}

static inline GPUCell*
pool_gpu_lineptr(const LineSlotPool *pool, index_type slot) {
    return pool->slabs[slot / pool->slab_capacity].gpu + (size_t)(slot % pool->slab_capacity) * pool->xnum;
}
