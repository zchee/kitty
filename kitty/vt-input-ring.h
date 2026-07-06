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
// input_delay batching. Its contract (final-review FR-1) is
// covered-or-fail-open: in every quiescent state with unconsumed bytes
// the stamp is a non-zero time at or before the oldest byte's arrival,
// and the only reachable transients are a zero or older-than-arrival
// stamp, both of which OPEN the input_delay gate early. A missing or
// stale stamp can never delay parsing or lose bytes. Protocol: the
// producer stamps (CAS from 0) BEFORE publishing head, then after a
// seq_cst fence re-stamps only while unconsumed bytes remain (so a late
// re-stamp cannot park a stale value in an empty ring); the consumer
// clears with a CAS against the value it observed while the ring was
// observably empty, then re-covers (fail-open, stamp = now) if bytes
// became visible across the clear. The fences pair the producer's
// tail recheck with the consumer's clear so exactly one side resolves
// each race. spsc_ring_check.c drives every one of these interleavings
// deterministically through the VT_RING_TEST_HOOKS points below.
//
// writer_parked is the back-pressure waiter flag (final-review FR-2).
// The io thread must not sleep with POLLIN removed while drainable
// space exists: before parking it publishes writer_parked, fences
// (seq_cst), and re-checks space; the consumer advances tail, fences
// (seq_cst), then claims the flag. The fence pair makes a lost wakeup
// impossible: either the parking writer's re-check sees the new space,
// or the consumer's claim sees the parked flag and wakes it.
//
// The ring is 1 MiB and intended to be HEAP-ALLOCATED next to the parser
// state (a VTInputRing* member), never embedded by value in PS
// (design-review MAJOR-4: embedding would double per-parser resident
// memory and bloat the posix_memalign'd PS block).
//
// Reserve/commit keep lightweight bookkeeping so API misuse
// (double-reserve, committing more than reserved) aborts in ALL build
// flavors (final-review FR-3 restored the mutex-era fatal() contract;
// NDEBUG no longer compiles the guards out). The checks sit on the
// per-read() edge, not the per-byte path.

#pragma once

#include <stdatomic.h>
#include <stdalign.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "monotonic.h"

// Overridable so the stress harness can build a tiny ring that forces
// full-ring transitions even under TSan slowdown.
#ifndef VT_RING_SZ
#define VT_RING_SZ (1u << 20)
#endif
#define VT_RING_MASK (VT_RING_SZ - 1u)

// Deterministic interleaving hooks for the test harness: protocol step
// boundaries call vt_ring_test_point(id) so a single-threaded test can
// run the peer's steps at an exact point. Compiles to nothing in
// production builds.
#ifdef VT_RING_TEST_HOOKS
void vt_ring_test_point(int id);
#define VT_RING_STEP(id) vt_ring_test_point(id)
#else
#define VT_RING_STEP(id) ((void)0)
#endif
// step ids: 1 = commit after first stamp (pre-publish), 2 = commit after
// head publish (pre-fence), 3 = commit after fence (pre conditional
// re-stamp), 5 = clear after empty check (pre CAS), 6 = clear after CAS
// (pre fail-open re-cover), 7 = park after flag store (pre re-check)

#define VT_RING_MISUSE(msg) do { \
    fprintf(stderr, "vt-input-ring API misuse: %s\n", msg); \
    abort(); \
} while (0)

typedef struct VTInputRing {
    uint8_t buf[VT_RING_SZ];
    // producer-owned; consumer only acquire-loads it
    alignas(64) _Atomic size_t head;
    // consumer-owned; producer only acquire-loads it
    alignas(64) _Atomic size_t tail;
    // stamped by the producer, cleared by the consumer; keep it off both
    // index lines and away from the producer's reserve bookkeeping
    alignas(64) _Atomic monotonic_t new_input_at;
    // back-pressure waiter flag: set by the parking io thread, claimed
    // by the draining consumer
    alignas(64) _Atomic bool writer_parked;
    // producer-thread-private reserve bookkeeping (not atomic: only the
    // producer touches it)
    alignas(64) size_t reserved_sz;
    bool reserve_active;
} VTInputRing;

_Static_assert(offsetof(VTInputRing, tail) - offsetof(VTInputRing, head) >= 64, "head/tail must not share a cache line");
_Static_assert(offsetof(VTInputRing, new_input_at) - offsetof(VTInputRing, tail) >= 64, "tail/new_input_at must not share a cache line");
_Static_assert(offsetof(VTInputRing, writer_parked) - offsetof(VTInputRing, new_input_at) >= 64, "new_input_at/writer_parked must not share a cache line");
_Static_assert(offsetof(VTInputRing, reserved_sz) - offsetof(VTInputRing, writer_parked) >= 64, "writer_parked/reserve bookkeeping must not share a cache line");
_Static_assert((VT_RING_SZ & VT_RING_MASK) == 0, "ring capacity must be a power of two");

// ---- producer side (io thread) ----

// Largest contiguous writable span at the current head. Zero iff the
// ring is completely full (contig = SZ - (head & MASK) is always >= 1,
// so min(free_total, contig) == 0 only when free_total == 0: no
// spurious stall at wrap). Shorter-than-total windows near the ring end
// just mean the next reserve continues at the start; bytes never move.
static inline uint8_t*
vt_ring_reserve(VTInputRing *ring, size_t *sz) {
    if (ring->reserve_active) VT_RING_MISUSE("reserve while a reservation is active");
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
// covered-or-fail-open protocol described above.
static inline void
vt_ring_commit(VTInputRing *ring, size_t sz, monotonic_t now) {
    if (sz > ring->reserved_sz) VT_RING_MISUSE("commit larger than reservation");
    ring->reserved_sz = 0;
    ring->reserve_active = false;
    if (!sz) return;
    monotonic_t expected = 0;
    atomic_compare_exchange_strong_explicit(&ring->new_input_at, &expected, now,
                                            memory_order_relaxed, memory_order_relaxed);
    VT_RING_STEP(1);
    const size_t head = atomic_load_explicit(&ring->head, memory_order_relaxed);
    atomic_store_explicit(&ring->head, head + sz, memory_order_release);
    VT_RING_STEP(2);
    // re-stamp: covers a consumer clear that raced between the first
    // stamp and the publish. Fenced and conditional on bytes remaining
    // unconsumed so a late re-stamp cannot leave a stale value in an
    // empty ring: either this fence-ordered tail load sees the consumer's
    // full drain (skip), or the consumer's fence-ordered clear sees this
    // re-stamp and removes it (FR-1).
    atomic_thread_fence(memory_order_seq_cst);
    VT_RING_STEP(3);
    if (head + sz - atomic_load_explicit(&ring->tail, memory_order_relaxed) > 0) {
        expected = 0;
        atomic_compare_exchange_strong_explicit(&ring->new_input_at, &expected, now,
                                                memory_order_relaxed, memory_order_relaxed);
    }
}

static inline bool
vt_ring_has_space(VTInputRing *ring) {
    const size_t head = atomic_load_explicit(&ring->head, memory_order_relaxed);
    const size_t tail = atomic_load_explicit(&ring->tail, memory_order_acquire);
    return head - tail < VT_RING_SZ;
}

// POLLIN decision for the io thread (FR-2). True: space exists, keep
// reading. False: the ring is full and the writer is now parked; the
// consumer's fence-paired unpark will wake it via write_space_created.
// The post-park re-check closes the race where the consumer drained
// between the fullness observation and the park.
static inline bool
vt_ring_writer_arm_or_park(VTInputRing *ring) {
    if (vt_ring_has_space(ring)) {
        // clear a stale park from an earlier full window (a concurrent
        // consumer claim at worst sends one spurious wakeup)
        if (atomic_load_explicit(&ring->writer_parked, memory_order_relaxed))
            atomic_store_explicit(&ring->writer_parked, false, memory_order_relaxed);
        return true;
    }
    atomic_store_explicit(&ring->writer_parked, true, memory_order_relaxed);
    VT_RING_STEP(7);
    atomic_thread_fence(memory_order_seq_cst);
    if (vt_ring_has_space(ring)) {
        atomic_store_explicit(&ring->writer_parked, false, memory_order_relaxed);
        return true;
    }
    return false;
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

// Consumer-side batching-stamp maintenance; call after draining, with
// the tick's clock. Clears only while the ring is observably empty, only
// the value that was observed (a CAS, so a stamp covering bytes this
// consumer never saw cannot be wiped), and re-covers fail-open (stamp =
// now) if a publish raced across the clear (FR-1).
static inline void
vt_ring_clear_new_input_at(VTInputRing *ring, monotonic_t now) {
    atomic_thread_fence(memory_order_seq_cst);
    monotonic_t ts = atomic_load_explicit(&ring->new_input_at, memory_order_relaxed);
    if (!ts || vt_ring_used(ring)) return;
    VT_RING_STEP(5);
    atomic_compare_exchange_strong_explicit(&ring->new_input_at, &ts, 0,
                                            memory_order_relaxed, memory_order_relaxed);
    VT_RING_STEP(6);
    if (vt_ring_used(ring)) {
        monotonic_t expected = 0;
        atomic_compare_exchange_strong_explicit(&ring->new_input_at, &expected, now,
                                                memory_order_relaxed, memory_order_relaxed);
    }
}

// Claim a parked writer (FR-2); call once per parse tick after draining.
// True means the caller must wake the io loop. The seq_cst fence pairs
// with the park-side fence: either the parker's space re-check sees this
// tick's tail advances, or this load sees the parked flag. Full ring
// after the drain means the tick freed nothing (arena full) — leave the
// writer parked; the immediate next tick (the gate's ring-full override)
// parses, frees arena space, drains and unparks.
static inline bool
vt_ring_unpark_writer(VTInputRing *ring) {
    atomic_thread_fence(memory_order_seq_cst);
    if (!atomic_load_explicit(&ring->writer_parked, memory_order_relaxed)) return false;
    if (!vt_ring_has_space(ring)) return false;
    return atomic_exchange_explicit(&ring->writer_parked, false, memory_order_relaxed);
}
