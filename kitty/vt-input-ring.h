/*
 * vt-input-ring.h
 * Copyright (C) 2026 Kovid Goyal <kovid at kovidgoyal.net>
 *
 * Distributed under terms of the GPL3 license.
 */

// Lock-free SPSC byte ring for the IO-thread -> main-thread parser input
// handoff (Phase 12). Transport only: the consumer drains it into the
// parser's contiguous PS.buf arena, so the in-place escape scanners are
// untouched. One producer (the io thread's read_bytes), one consumer (the
// main-thread parse tick). Indices are free-running size_t counters
// (masked on access); used = head - tail is overflow-safe. The producer
// publishes bytes with a release store of head after writing them; the
// consumer acquires head before reading, and symmetrically for tail and
// space.
//
// new_input_at carries the first-unabsorbed-input timestamp for
// input_delay batching. Its protocol makes "bytes visible without a
// covering timestamp" impossible (design-review MAJOR-1): the producer
// stamps BEFORE publishing head, and stamps again AFTER the publish to
// cover the race where the consumer's clear-on-empty lands between the
// first stamp and the publish. The consumer clears it only while the
// ring is observably empty. Invariant (asserted by the stress harness):
// whenever the consumer observes used > 0, new_input_at != 0.
//
// The ring is 1 MiB and intended to be HEAP-ALLOCATED next to the parser
// state (a VTInputRing* member), never embedded by value in PS
// (design-review MAJOR-4: embedding would double per-parser resident
// memory and bloat the posix_memalign'd PS block).
//
// Reserve/commit keep lightweight bookkeeping so API misuse
// (double-reserve, committing more than reserved) trips an assert in
// harness/debug builds (design-review MAJOR-3); release builds compile
// the checks out with NDEBUG.

#pragma once

#include <assert.h>
#include <stdatomic.h>
#include <stdalign.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "monotonic.h"

// Overridable so the stress harness can build a tiny ring that forces
// full-ring transitions even under TSan slowdown.
#ifndef VT_RING_SZ
#define VT_RING_SZ (1u << 20)
#endif
#define VT_RING_MASK (VT_RING_SZ - 1u)

typedef struct VTInputRing {
    uint8_t buf[VT_RING_SZ];
    // producer-owned; consumer only acquire-loads it
    alignas(64) _Atomic size_t head;
    // consumer-owned; producer only acquire-loads it
    alignas(64) _Atomic size_t tail;
    alignas(64) _Atomic monotonic_t new_input_at;
    // producer-thread-private reserve bookkeeping (not atomic: only the
    // producer touches it)
    size_t reserved_sz;
    bool reserve_active;
} VTInputRing;

_Static_assert(offsetof(VTInputRing, tail) - offsetof(VTInputRing, head) >= 64, "head/tail must not share a cache line");
_Static_assert(offsetof(VTInputRing, new_input_at) - offsetof(VTInputRing, tail) >= 64, "tail/new_input_at must not share a cache line");
_Static_assert((VT_RING_SZ & VT_RING_MASK) == 0, "ring capacity must be a power of two");

// ---- producer side (io thread) ----

// Largest contiguous writable span at the current head. Zero iff the
// ring is completely full (contig = SZ - (head & MASK) is always >= 1,
// so min(free_total, contig) == 0 only when free_total == 0: no
// spurious stall at wrap). Shorter-than-total windows near the ring end
// just mean the next reserve continues at the start; bytes never move.
static inline uint8_t*
vt_ring_reserve(VTInputRing *ring, size_t *sz) {
    assert(!ring->reserve_active && "double reserve without commit");
    const size_t head = atomic_load_explicit(&ring->head, memory_order_relaxed);
    const size_t tail = atomic_load_explicit(&ring->tail, memory_order_acquire);
    const size_t free_total = VT_RING_SZ - (head - tail);
    const size_t contig = VT_RING_SZ - (head & VT_RING_MASK);
    *sz = free_total < contig ? free_total : contig;
    ring->reserved_sz = *sz;
    ring->reserve_active = *sz > 0;
    return ring->buf + (head & VT_RING_MASK);
}

// Publish sz bytes written into the last reserve()d span. commit(0) is a
// no-op (and cancels the reservation). now stamps new_input_at with the
// stamp-publish-stamp protocol described above.
static inline void
vt_ring_commit(VTInputRing *ring, size_t sz, monotonic_t now) {
    assert(sz <= ring->reserved_sz && "commit larger than reservation");
    ring->reserved_sz = 0;
    ring->reserve_active = false;
    if (!sz) return;
    monotonic_t expected = 0;
    atomic_compare_exchange_strong_explicit(&ring->new_input_at, &expected, now,
                                            memory_order_relaxed, memory_order_relaxed);
    const size_t head = atomic_load_explicit(&ring->head, memory_order_relaxed);
    atomic_store_explicit(&ring->head, head + sz, memory_order_release);
    // re-stamp: covers the consumer clearing between the first stamp and
    // the publish (it can only clear while it observes an empty ring)
    expected = 0;
    atomic_compare_exchange_strong_explicit(&ring->new_input_at, &expected, now,
                                            memory_order_relaxed, memory_order_relaxed);
}

static inline bool
vt_ring_has_space(VTInputRing *ring) {
    const size_t head = atomic_load_explicit(&ring->head, memory_order_relaxed);
    const size_t tail = atomic_load_explicit(&ring->tail, memory_order_acquire);
    return head - tail < VT_RING_SZ;
}

// ---- consumer side (main thread) ----

// Largest contiguous readable span at the current tail (zero when empty).
static inline const uint8_t*
vt_ring_readable(VTInputRing *ring, size_t *sz) {
    const size_t tail = atomic_load_explicit(&ring->tail, memory_order_relaxed);
    const size_t head = atomic_load_explicit(&ring->head, memory_order_acquire);
    const size_t used = head - tail;
    const size_t contig = VT_RING_SZ - (tail & VT_RING_MASK);
    *sz = used < contig ? used : contig;
    return ring->buf + (tail & VT_RING_MASK);
}

static inline void
vt_ring_advance(VTInputRing *ring, size_t sz) {
    const size_t tail = atomic_load_explicit(&ring->tail, memory_order_relaxed);
    atomic_store_explicit(&ring->tail, tail + sz, memory_order_release);
}

static inline size_t
vt_ring_used(VTInputRing *ring) {
    const size_t tail = atomic_load_explicit(&ring->tail, memory_order_relaxed);
    const size_t head = atomic_load_explicit(&ring->head, memory_order_acquire);
    return head - tail;
}

static inline monotonic_t
vt_ring_new_input_at(VTInputRing *ring) {
    return atomic_load_explicit(&ring->new_input_at, memory_order_relaxed);
}

// Clear the batching timestamp; call only while the ring is observably
// empty (the producer's re-stamp covers the publish race).
static inline void
vt_ring_clear_new_input_at(VTInputRing *ring) {
    atomic_store_explicit(&ring->new_input_at, 0, memory_order_relaxed);
}
