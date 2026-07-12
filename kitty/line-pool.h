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

// slab capacity for pools that grow with scrollback (the granularity the
// history segments had); private single-container pools size exactly
#define LINE_POOL_DEFAULT_SLAB 2048u

typedef struct LineSlotSlab {
    CPUCell *cpu;
    GPUCell *gpu;
    void *mem;
} LineSlotSlab;

typedef struct LineSlotPool {
    index_type xnum;
    // slab capacity in slots, fixed per pool and rounded up to a power
    // of two so the hot slot->address math is shift+mask, not division:
    // sized for the container on single-container private pools,
    // history-segment-sized (2048) for pools that grow with scrollback
    index_type slab_capacity;
    uint8_t slab_shift;
    index_type slab_mask;
    unsigned refcnt;
    size_t num_slabs, slots_used;
    LineSlotSlab *slabs;
    // Wave-25 Lane S (KITTY_PAUSE_SNAPSHOT_SHARE): snapshot-holder refcount
    // lane + retire bookkeeping. Allocated lazily at the first SHARE
    // snapshot acquire on this pool and grown alongside the slabs; NULL
    // means no snapshot has ever shared slots here, so the unset world's
    // write checkouts pay exactly one pointer-load + branch. The lane
    // counts SNAPSHOT holders only -- live/history containment stays
    // implicit in id-containment (never counted). retired[] marks slots
    // that left live containment via a COW retire while still held; only
    // such slots are pushed to the LIFO free list, and ONLY at snapshot
    // Release (BSU increfs / COW never decrefs / Release single-decref),
    // which makes mid-pause recycling of a held slot structurally
    // impossible.
    uint16_t *refcnt_lane;
    uint8_t *retired;
    index_type *free_ids;
    size_t free_count, free_cap;
    size_t lane_cap;
} LineSlotPool;

LineSlotPool* line_slot_pool_alloc(index_type xnum, index_type slab_capacity);
void line_slot_pool_incref(LineSlotPool *pool);
void line_slot_pool_decref(LineSlotPool *pool);
// hands out the next unused slot, growing by one slab if needed; aborts
// on allocation failure like the rest of the cell-storage allocators
index_type line_slot_pool_take(LineSlotPool *pool);
// Wave-25 Lane S: lazy refcount-lane management + the retire-alloc path.
// ensure_share_lane sizes the lane to current pool capacity (aborts on
// allocation failure like the other cell allocators); take_reusing pops
// the free list before growing.
void line_slot_pool_ensure_share_lane(LineSlotPool *pool);
void line_slot_pool_slot_incref(LineSlotPool *pool, index_type slot);
void line_slot_pool_slot_decref(LineSlotPool *pool, index_type slot);
index_type line_slot_pool_take_reusing(LineSlotPool *pool);

static inline CPUCell*
pool_cpu_lineptr(const LineSlotPool *pool, index_type slot) {
    return pool->slabs[slot >> pool->slab_shift].cpu + (size_t)(slot & pool->slab_mask) * pool->xnum;
}

static inline GPUCell*
pool_gpu_lineptr(const LineSlotPool *pool, index_type slot) {
    return pool->slabs[slot >> pool->slab_shift].gpu + (size_t)(slot & pool->slab_mask) * pool->xnum;
}
