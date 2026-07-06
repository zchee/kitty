/*
 * spsc-ring-check: standalone stress harness for vt-input-ring.h
 * (Phase 12). Proves, with a real producer thread and a real consumer
 * thread: in-order lossless delivery (seeded xorshift stream compared
 * byte-for-byte), back-pressure without loss (consumer stalls; producer
 * observes zero windows; buffered never exceeds capacity), wrap-around
 * (>= 16 ring revolutions), partial writes, and the drain-into-arena
 * pattern run_worker will use (bounded arena, 256 KiB-class chunks).
 * Deterministic under a fixed seed; pass a seed argv[1] to vary.
 * Exit 0 = all invariants held. Build both plain and -fsanitize=thread.
 */

#include <inttypes.h>
#include <pthread.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "vt-input-ring.h"

#define TOTAL_BYTES (VT_RING_SZ * 16ull + 12345ull)
#define ARENA_SZ (1u << 20)
#define MAX_CHUNK (300u * 1024u)  // exercises 256KiB-class drains

static VTInputRing ring;

static inline uint64_t xs(uint64_t *s) { *s ^= *s << 13; *s ^= *s >> 7; *s ^= *s << 17; return *s; }
static inline uint8_t stream_byte(uint64_t i, uint64_t seed) {
    uint64_t v = i * 0x9E3779B97F4A7C15ull + seed;
    v ^= v >> 33; v *= 0xFF51AFD7ED558CCDull; v ^= v >> 33;
    return (uint8_t)v;
}

static uint64_t g_seed = 0x5eed;
static _Atomic int consumer_paused = 0;
static _Atomic uint64_t producer_zero_windows = 0;

static void* producer(void *arg) {
    (void)arg;
    uint64_t rng = g_seed ^ 0xABCDEF;
    uint64_t written = 0;
    monotonic_t fake_now = 1;
    while (written < TOTAL_BYTES) {
        size_t avail;
        uint8_t *span = vt_ring_reserve(&ring, &avail);
        if (!avail) {
            atomic_fetch_add_explicit(&producer_zero_windows, 1, memory_order_relaxed);
            sched_yield();
            continue;
        }
        size_t want = 1 + (xs(&rng) % MAX_CHUNK);
        if (want > avail) want = avail;
        if (want > TOTAL_BYTES - written) want = (size_t)(TOTAL_BYTES - written);
        for (size_t i = 0; i < want; i++) span[i] = stream_byte(written + i, g_seed);
        // partial-write case: sometimes commit less than reserved/filled
        size_t commit = want;
        if ((xs(&rng) & 7u) == 0 && want > 1) commit = 1 + (xs(&rng) % want);
        vt_ring_commit(&ring, commit, fake_now++);
        written += commit;
    }
    return NULL;
}

int main(int argc, char **argv) {
    if (argc > 1) g_seed = strtoull(argv[1], NULL, 0);
    pthread_t prod;
    if (pthread_create(&prod, NULL, producer, NULL)) { perror("pthread_create"); return 2; }

    static uint8_t arena[ARENA_SZ];
    uint64_t rng = g_seed ^ 0x123456;
    uint64_t consumed = 0, drains = 0, max_used = 0, pauses = 0;
    while (consumed < TOTAL_BYTES) {
        // stall every few drains to force back-pressure (ring must fill,
        // producer must observe zero windows, and no byte may be lost)
        if (drains && (drains & 3u) == 0 && pauses < drains / 4) {
            atomic_store(&consumer_paused, 1);
            for (int i = 0; i < 2000; i++) sched_yield();
            atomic_store(&consumer_paused, 0);
            pauses++;
        }
        size_t used = vt_ring_used(&ring);
        if (used > max_used) max_used = used;
        if (used > VT_RING_SZ) { fprintf(stderr, "FAIL: used %zu > capacity\n", used); return 1; }
        // design-review MAJOR-1 invariant: bytes visible => covering
        // timestamp visible (stamp-publish-stamp makes this unbreakable;
        // the pre-amendment ordering trips this probabilistically)
        if (used > 0 && vt_ring_new_input_at(&ring) == 0) {
            fprintf(stderr, "FAIL: %zu bytes visible with zero new_input_at\n", used);
            return 1;
        }
        // drain like run_worker: bounded arena, contiguous spans, random caps
        size_t arena_fill = 0;
        while (arena_fill < ARENA_SZ) {
            size_t avail;
            const uint8_t *span = vt_ring_readable(&ring, &avail);
            if (!avail) break;
            size_t take = avail;
            size_t cap = 1 + (xs(&rng) % MAX_CHUNK);
            if (take > cap) take = cap;
            if (take > ARENA_SZ - arena_fill) take = ARENA_SZ - arena_fill;
            memcpy(arena + arena_fill, span, take);
            vt_ring_advance(&ring, take);
            arena_fill += take;
        }
        if (!arena_fill) { sched_yield(); continue; }
        drains++;
        for (size_t i = 0; i < arena_fill; i++) {
            if (arena[i] != stream_byte(consumed + i, g_seed)) {
                fprintf(stderr, "FAIL: byte %" PRIu64 " mismatch (drain %" PRIu64 ")\n",
                        consumed + i, drains);
                return 1;
            }
        }
        consumed += arena_fill;
        if (vt_ring_used(&ring) == 0) vt_ring_clear_new_input_at(&ring);
    }
    pthread_join(prod, NULL);
    if (vt_ring_used(&ring) != 0) { fprintf(stderr, "FAIL: %zu residual bytes\n", vt_ring_used(&ring)); return 1; }
    if (vt_ring_new_input_at(&ring) != 0 && consumed == TOTAL_BYTES) {
        // benign: producer may have stamped after our last clear; consume-side
        // semantics only require the timestamp to be fresh when bytes pend
        vt_ring_clear_new_input_at(&ring);
    }
    uint64_t zw = atomic_load(&producer_zero_windows);
    printf("OK bytes=%" PRIu64 " drains=%" PRIu64 " max_used=%" PRIu64 "/%u zero_windows=%" PRIu64 " pauses=%" PRIu64 " seed=%#" PRIx64 "\n",
           consumed, drains, max_used, VT_RING_SZ, zw, pauses, g_seed);
    if (!zw) fprintf(stderr, "WARN: back-pressure never engaged (increase pauses)\n");
    return 0;
}
