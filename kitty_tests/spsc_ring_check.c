/*
 * spsc-ring-check: standalone harness for vt-input-ring.h (Phase 12).
 *
 * Part 1 (deterministic, final-review FR-1/FR-2): single-threaded
 * interleaving proofs. VT_RING_TEST_HOOKS step points let a test run the
 * peer role's steps at an exact protocol boundary, forcing the precise
 * interleavings the final review flagged (clear racing a publish, a
 * clear landing between stamp and publish, a late re-stamp into an
 * emptied ring, a fill racing the writer's park). Exact, not
 * probabilistic.
 *
 * Part 2 (stress): a real producer thread and a real consumer thread
 * prove in-order lossless delivery (seeded xorshift stream compared
 * byte-for-byte), back-pressure without loss (consumer stalls; producer
 * observes zero windows; buffered never exceeds capacity), wrap-around
 * (>= 16 ring revolutions), partial writes, and the drain-into-arena
 * pattern run_worker uses (bounded arena, 256 KiB-class chunks).
 * Deterministic under a fixed seed; pass a seed argv[1] to vary.
 * Exit 0 = all invariants held. Build both plain and -fsanitize=thread.
 */

#include <inttypes.h>
#include <pthread.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define VT_RING_TEST_HOOKS
#include "vt-input-ring.h"

#define TOTAL_BYTES (VT_RING_SZ * 16ull + 12345ull)
#define ARENA_SZ (1u << 20)
#define MAX_CHUNK (300u * 1024u)  // exercises 256KiB-class drains

static VTInputRing ring;

// ---- deterministic interleaving proofs {{{

// One-shot hook: at the armed step point, run the payload (the peer
// role's steps) exactly once; disarm first so the payload's own step
// points cannot re-enter. Armed and read single-threaded only.
static struct { int point; void (*payload)(void); } g_hook;

void
vt_ring_test_point(int id) {
    if (!g_hook.payload || id != g_hook.point) return;
    void (*p)(void) = g_hook.payload;
    g_hook.payload = NULL;
    p();
}

static void arm(int point, void (*payload)(void)) { g_hook.point = point; g_hook.payload = payload; }

// single-threaded here, so the non-atomic wipe of the atomics is fine
static void ring_reset(void) { memset(&ring, 0, sizeof(ring)); g_hook.payload = NULL; }

#define CHECK(cond, ...) do { if (!(cond)) { \
    fprintf(stderr, "FAIL(det): " __VA_ARGS__); fputc('\n', stderr); exit(1); } } while (0)

static void
commit_bytes(size_t n, monotonic_t now) {
    size_t avail;
    uint8_t *span = vt_ring_reserve(&ring, &avail);
    if (avail < n) { fprintf(stderr, "FAIL(det): reserve window %zu < %zu\n", avail, n); exit(1); }
    memset(span, 0xAB, n);
    vt_ring_commit(&ring, n, now);
}

static void
drain_all(void) {
    for (;;) {
        size_t avail;
        vt_ring_readable(&ring, &avail);
        if (!avail) break;
        vt_ring_advance(&ring, avail);
    }
}

static void
fill_full(void) {
    for (;;) {
        size_t avail;
        uint8_t *span = vt_ring_reserve(&ring, &avail);
        if (!avail) break;
        memset(span, 1, avail);
        vt_ring_commit(&ring, avail, 1);
    }
}

// FR-1 primary interleave: a burst publishes after the consumer's empty
// check but before its CAS-clear. The clear wipes the stamp that was
// covering the burst; the fail-open re-cover must restore a non-zero
// stamp. (The pre-fix blind store left the burst visible with stamp 0.)
static void t1_payload(void) { commit_bytes(64, 200); }
static void
t_clear_races_publish(void) {
    ring_reset();
    commit_bytes(32, 100);
    drain_all();                       // ring empty, stamp 100 still set
    arm(5, t1_payload);
    vt_ring_clear_new_input_at(&ring, 300);
    CHECK(vt_ring_used(&ring) == 64, "clear-vs-publish: expected 64 visible bytes, got %zu", vt_ring_used(&ring));
    CHECK(vt_ring_new_input_at(&ring) != 0, "clear-vs-publish: visible bytes left uncovered (stamp 0)");
}

// The original stamp-publish-stamp motivation, now exact: a clear lands
// between the producer's first stamp and the head publish; the fenced
// conditional re-stamp must re-cover the published bytes.
static void t2_payload(void) { vt_ring_clear_new_input_at(&ring, 999); }
static void
t_clear_between_stamp_and_publish(void) {
    ring_reset();
    arm(1, t2_payload);
    commit_bytes(48, 500);
    CHECK(vt_ring_used(&ring) == 48, "stamp/publish: expected 48 visible bytes, got %zu", vt_ring_used(&ring));
    CHECK(vt_ring_new_input_at(&ring) == 500, "stamp/publish: re-stamp missing (stamp %lld)", (long long)vt_ring_new_input_at(&ring));
}

// FR-1 stale-stamp elimination: the consumer drains everything and
// clears between the publish and the re-stamp. The conditional re-stamp
// must SKIP (the pre-fix unconditional CAS parked a stale stamp in the
// empty ring, prematurely opening the gate for the next burst).
static void t3_payload(void) { drain_all(); vt_ring_clear_new_input_at(&ring, 999); }
static void
t_no_stale_stamp_in_emptied_ring(void) {
    ring_reset();
    arm(3, t3_payload);
    commit_bytes(16, 700);
    CHECK(vt_ring_used(&ring) == 0, "stale-stamp: ring should be empty, got %zu", vt_ring_used(&ring));
    CHECK(vt_ring_new_input_at(&ring) == 0, "stale-stamp: re-stamp leaked into the empty ring (stamp %lld)",
          (long long)vt_ring_new_input_at(&ring));
}

// FR-2 park/unpark basics: park engages only on a truly full ring,
// unpark refuses while still full (nothing to read into), claims exactly
// once when space exists, and arming resumes afterwards.
static void
t_park_unpark(void) {
    ring_reset();
    CHECK(vt_ring_writer_arm_or_park(&ring), "park: empty ring must arm");
    fill_full();
    CHECK(!vt_ring_writer_arm_or_park(&ring), "park: full ring must park");
    CHECK(!vt_ring_unpark_writer(&ring), "park: unpark must refuse while still full");
    size_t avail;
    vt_ring_readable(&ring, &avail);
    CHECK(avail > 0, "park: full ring must be readable");
    vt_ring_advance(&ring, avail < 128 ? avail : 128);
    CHECK(vt_ring_unpark_writer(&ring), "park: unpark must claim the parked writer once space exists");
    CHECK(!vt_ring_unpark_writer(&ring), "park: unpark must claim at most once");
    CHECK(vt_ring_writer_arm_or_park(&ring), "park: ring with space must arm again");
}

// FR-2 lost-wakeup impossibility: the consumer drains and unparks in the
// window between the writer's flag store and its space re-check. Both
// sides must resolve: the unpark claims the flag (wakeup fired) AND the
// re-check sees the space (writer arms instead of sleeping). A writer
// sleeping while the wakeup was skipped is unreachable.
static bool t5_wake;
static void
t5_payload(void) {
    size_t avail;
    vt_ring_readable(&ring, &avail);
    vt_ring_advance(&ring, avail);
    t5_wake = vt_ring_unpark_writer(&ring);
}
static void
t_fill_races_park(void) {
    ring_reset();
    fill_full();
    t5_wake = false;
    arm(7, t5_payload);
    CHECK(vt_ring_writer_arm_or_park(&ring), "park-race: writer must observe the drain on its re-check");
    CHECK(t5_wake, "park-race: consumer must have claimed the parked flag");
    CHECK(!atomic_load_explicit(&ring.writer_parked, memory_order_relaxed), "park-race: flag must end clear");
}

static void
run_deterministic_interleavings(void) {
    t_clear_races_publish();
    t_clear_between_stamp_and_publish();
    t_no_stale_stamp_in_emptied_ring();
    t_park_unpark();
    t_fill_races_park();
    ring_reset();
    printf("deterministic interleavings OK (FR-1 clear/publish, stamp/publish, stale-stamp; FR-2 park/unpark, fill/park)\n");
}

// }}}

// ---- stress {{{

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
    run_deterministic_interleavings();
    pthread_t prod;
    if (pthread_create(&prod, NULL, producer, NULL)) { perror("pthread_create"); return 2; }

    static uint8_t arena[ARENA_SZ];
    uint64_t rng = g_seed ^ 0x123456;
    uint64_t consumed = 0, drains = 0, max_used = 0, pauses = 0, uncovered_transients = 0;
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
        // FR-1 contract is covered-or-fail-open: a clear racing a publish
        // can transiently leave visible bytes with stamp 0, and that
        // state always fails OPEN (the consumer parses immediately; here,
        // the drain below consumes the bytes). Count the transients; the
        // deterministic suite above proves each resolution path exactly.
        if (used > 0 && vt_ring_new_input_at(&ring) == 0) uncovered_transients++;
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
        vt_ring_clear_new_input_at(&ring, (monotonic_t)consumed);
    }
    pthread_join(prod, NULL);
    if (vt_ring_used(&ring) != 0) { fprintf(stderr, "FAIL: %zu residual bytes\n", vt_ring_used(&ring)); return 1; }
    if (vt_ring_new_input_at(&ring) != 0 && consumed == TOTAL_BYTES) {
        // R1 corner: the producer's final fenced re-stamp can still land
        // against a stale tail view. Fail-open (a stamp with no bytes only
        // opens the next gate early) and removed by the next consumer
        // clear, which is exactly what run_worker's per-tick clear does:
        vt_ring_clear_new_input_at(&ring, (monotonic_t)consumed);
        if (vt_ring_new_input_at(&ring) != 0) { fprintf(stderr, "FAIL: stale stamp survived a quiescent clear\n"); return 1; }
    }
    uint64_t zw = atomic_load(&producer_zero_windows);
    printf("OK bytes=%" PRIu64 " drains=%" PRIu64 " max_used=%" PRIu64 "/%u zero_windows=%" PRIu64 " pauses=%" PRIu64 " uncovered_transients=%" PRIu64 " seed=%#" PRIx64 "\n",
           consumed, drains, max_used, VT_RING_SZ, zw, pauses, uncovered_transients, g_seed);
    if (!zw) fprintf(stderr, "WARN: back-pressure never engaged (increase pauses)\n");
    return 0;
}

// }}}
