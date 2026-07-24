/*
 * oob-channel.c
 * Copyright (C) 2026 Kovid Goyal <kovid at kovidgoyal.net>
 *
 * Distributed under terms of the GPL3 license.
 */

// R3 out-of-band bulk channel (see oob-channel.h for the design contract).
//
// Lifecycle (all registry operations run on the main thread, under the GIL):
//   attach  — boss.add_child hands over the kitty-side socketpair fd right
//             after child_monitor.add_child; spawns the reader thread and
//             links the channel to the screen's parser (PS->oob).
//   detach  — boss.on_child_death; runs AFTER the child-monitor removal
//             path's final flushing do_parse, so the last committed bytes
//             have already merged. Unlinks the parser first (the caller IS
//             the main thread, so no drain can be concurrent), then
//             stop+shutdown+join, then frees.
// The reader thread never touches Python state; it only reads the fd,
// produces into the ring and pokes wakeup_main_loop().
//
// Fail-open: a handshake mismatch or read error shuts the socket down so a
// still-writing client gets EPIPE/ECONNRESET immediately (instead of
// blocking forever against a departed reader) and reverts to the tty. A
// child that never speaks the handshake (any unpatched program under the
// enabled gate) just leaves the thread parked in the handshake read until
// child exit closes the peer.

#include "oob-channel.h"
#include "vt-parser.h"
#include "screen.h"
#include "state.h"
#include "threading.h"
#include "safe-wrappers.h"
#include "monotonic.h"

#include <errno.h>
#include <pthread.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#define OOB_MAGIC "KOOB1\n"
#define OOB_MAGIC_SZ 6u
#define OOB_HANDSHAKE_SZ 10u
// 64 KiB read cap (plan §Design 2): bounds per-wakeup latency without
// measurably costing throughput against a 1 MiB ring.
#define OOB_READ_CAP (64u * 1024u)

struct OOBChannel {
    VTInputRing *ring;      // heap, 64-aligned; sole producer = this channel's thread
    Parser *parser;         // strong Python ref; the PS->oob backlink target
    id_type window_id;
    int fd;                 // kitty-side end of the socketpair
    pthread_t thread;
    bool thread_started;
    // guards stop and pairs with cond for full-ring parking: the producer
    // holds the mutex from the park decision through cond_wait, the
    // consumer signals under it, so the FR-2 flag claim can never race a
    // waiter into a lost wakeup.
    pthread_mutex_t mutex;
    pthread_cond_t cond;
    bool stop;              // guarded by mutex
    uint32_t flags;         // raw handshake flags (reserved, v1 ignores them)
    _Atomic(bool) wakeup_pending;  // W22-O2-style main-loop wakeup coalescing
    _Atomic(bool) thread_done;
    _Atomic(bool) handshake_ok;
    _Atomic(bool) broken;          // handshake mismatch or read error (fail-open)
    // stats: producer-written relaxed, main-thread read (diagnostic only)
    _Atomic(uint64_t) bytes_in, reads, fallbacks, park_cycles;
    _Atomic(size_t) ring_highwater;
    struct OOBChannel *next;       // registry link; main thread only
};

static OOBChannel *channels = NULL;  // main-thread-only registry
static unsigned num_channels = 0;

VTInputRing*
oob_channel_ring(OOBChannel *c) { return c->ring; }

VTInputRing*
oob_channel_drain_ring(OOBChannel *c) {
    // clear-before-drain: the store must precede the caller's head
    // acquire-load so a commit this drain misses observes the cleared
    // flag and raises a fresh wakeup (same seq_cst bracketing as the
    // W22 O2 proof for main_wakeup_pending).
    atomic_store_explicit(&c->wakeup_pending, false, memory_order_seq_cst);
    atomic_thread_fence(memory_order_seq_cst);
    return c->ring;
}

void
oob_channel_after_drain(OOBChannel *c) {
    if (vt_ring_unpark_writer(c->ring)) {
        pthread_mutex_lock(&c->mutex);
        pthread_cond_signal(&c->cond);
        pthread_mutex_unlock(&c->mutex);
    }
}

// producer side: commit published, now coalesce a main-loop wakeup
static void
oob_notify_main(OOBChannel *c) {
    atomic_thread_fence(memory_order_seq_cst);
    if (!atomic_exchange_explicit(&c->wakeup_pending, true, memory_order_seq_cst))
        wakeup_main_loop();
}

static bool
oob_read_handshake(OOBChannel *c) {
    uint8_t hs[OOB_HANDSHAKE_SZ];
    size_t got = 0;
    while (got < sizeof(hs)) {
        const ssize_t n = read(c->fd, hs + got, sizeof(hs) - got);
        if (n > 0) { got += (size_t)n; continue; }
        if (n < 0 && errno == EINTR) continue;
        // EOF before a handshake is the normal exit of an unpatched child
        // under the enabled gate; a read error is fail-open either way
        if (n < 0) atomic_store_explicit(&c->broken, true, memory_order_relaxed);
        return false;
    }
    if (memcmp(hs, OOB_MAGIC, OOB_MAGIC_SZ) != 0) {
        atomic_store_explicit(&c->broken, true, memory_order_relaxed);
        atomic_fetch_add_explicit(&c->fallbacks, 1, memory_order_relaxed);
        return false;
    }
    memcpy(&c->flags, hs + OOB_MAGIC_SZ, sizeof(c->flags));
    atomic_store_explicit(&c->handshake_ok, true, memory_order_relaxed);
    return true;
}

static void*
oob_read_loop(void *arg) {
    OOBChannel *c = arg;
    set_thread_name("KittyOOBRead");
    if (oob_read_handshake(c)) {
        for (;;) {
            pthread_mutex_lock(&c->mutex);
            bool stop = c->stop;
            bool parked = false;
            while (!stop && !vt_ring_writer_arm_or_park(c->ring)) {
                if (!parked) { parked = true; atomic_fetch_add_explicit(&c->park_cycles, 1, memory_order_relaxed); }
                pthread_cond_wait(&c->cond, &c->mutex);
                stop = c->stop;
            }
            pthread_mutex_unlock(&c->mutex);
            if (stop) break;
            size_t sz;
            uint8_t *span = vt_ring_reserve(c->ring, &sz);
            if (!sz) continue;  // defensive: re-run the park protocol
            if (sz > OOB_READ_CAP) sz = OOB_READ_CAP;
            const ssize_t n = read(c->fd, span, sz);
            if (n > 0) {
                vt_ring_commit(c->ring, (size_t)n, monotonic());
                atomic_fetch_add_explicit(&c->bytes_in, (uint64_t)n, memory_order_relaxed);
                atomic_fetch_add_explicit(&c->reads, 1, memory_order_relaxed);
                const size_t used = vt_ring_used(c->ring);
                if (used > atomic_load_explicit(&c->ring_highwater, memory_order_relaxed))
                    atomic_store_explicit(&c->ring_highwater, used, memory_order_relaxed);
                oob_notify_main(c);
                continue;
            }
            vt_ring_commit(c->ring, 0, 0);  // cancel the reservation
            if (n < 0 && errno == EINTR) continue;
            if (n < 0) {
                atomic_store_explicit(&c->broken, true, memory_order_relaxed);
                atomic_fetch_add_explicit(&c->fallbacks, 1, memory_order_relaxed);
            }
            break;  // EOF (peer closed on child exit) or read error
        }
    }
    // Close our direction on every exit path so a still-writing peer gets
    // EPIPE now instead of blocking against a departed reader (fail-open).
    // The fd itself stays open for detach to close after the join.
    shutdown(c->fd, SHUT_RDWR);
    atomic_store_explicit(&c->thread_done, true, memory_order_relaxed);
    oob_notify_main(c);  // let the main loop observe the terminal state promptly
    return NULL;
}

static OOBChannel*
find_channel(id_type window_id) {
    for (OOBChannel *c = channels; c; c = c->next) if (c->window_id == window_id) return c;
    return NULL;
}

static void
free_channel_struct(OOBChannel *c) {
    pthread_mutex_destroy(&c->mutex);
    pthread_cond_destroy(&c->cond);
    free(c->ring);
    free(c);
}

extern PyTypeObject Screen_Type;

static PyObject*
py_oob_channel_attach(PyObject *self UNUSED, PyObject *args) {
#define attach_doc "oob_channel_attach(screen, fd) -> bool. Attach an OOB bulk-channel reader to the screen's parser. Takes ownership of fd on every path."
    PyObject *screen_obj; int fd;
    if (!PyArg_ParseTuple(args, "O!i", &Screen_Type, &screen_obj, &fd)) return NULL;
    Screen *screen = (Screen*)screen_obj;
    if (fd < 0 || screen->vt_parser == NULL || vt_parser_oob_channel(screen->vt_parser) != NULL || find_channel(screen->window_id) != NULL) {
        if (fd > -1) safe_close(fd, __FILE__, __LINE__);
        log_error("oob-channel: refusing attach for window %llu (bad fd or already attached)", (unsigned long long)screen->window_id);
        Py_RETURN_FALSE;
    }
    OOBChannel *c = calloc(1, sizeof(OOBChannel));
    if (!c) { safe_close(fd, __FILE__, __LINE__); return PyErr_NoMemory(); }
    if (posix_memalign((void**)&c->ring, 64, sizeof(VTInputRing)) != 0) {
        free(c); safe_close(fd, __FILE__, __LINE__); return PyErr_NoMemory();
    }
    memset(c->ring, 0, sizeof(VTInputRing));
    pthread_mutex_init(&c->mutex, NULL);
    pthread_cond_init(&c->cond, NULL);
    c->fd = fd;
    c->window_id = screen->window_id;
    c->parser = screen->vt_parser;
    if (pthread_create(&c->thread, NULL, oob_read_loop, c) != 0) {
        log_error("oob-channel: pthread_create failed for window %llu: %s", (unsigned long long)c->window_id, strerror(errno));
        safe_close(fd, __FILE__, __LINE__);
        free_channel_struct(c);
        Py_RETURN_FALSE;
    }
    c->thread_started = true;
    Py_INCREF(c->parser);  // the parser must outlive PS->oob and the ring
    vt_parser_set_oob_channel(c->parser, c);
    c->next = channels; channels = c; num_channels++;
    Py_RETURN_TRUE;
}

static void
emit_stats_line(OOBChannel *c) {
    log_error("oob_stats: window=%llu bytes_in=%llu reads=%llu park_cycles=%llu ring_used=%zu ring_highwater=%zu fallbacks=%llu handshake_ok=%d broken=%d thread_done=%d",
              (unsigned long long)c->window_id,
              (unsigned long long)atomic_load_explicit(&c->bytes_in, memory_order_relaxed),
              (unsigned long long)atomic_load_explicit(&c->reads, memory_order_relaxed),
              (unsigned long long)atomic_load_explicit(&c->park_cycles, memory_order_relaxed),
              vt_ring_used(c->ring),
              atomic_load_explicit(&c->ring_highwater, memory_order_relaxed),
              (unsigned long long)atomic_load_explicit(&c->fallbacks, memory_order_relaxed),
              atomic_load_explicit(&c->handshake_ok, memory_order_relaxed) ? 1 : 0,
              atomic_load_explicit(&c->broken, memory_order_relaxed) ? 1 : 0,
              atomic_load_explicit(&c->thread_done, memory_order_relaxed) ? 1 : 0);
}

static PyObject*
py_oob_channel_detach(PyObject *self UNUSED, PyObject *args) {
#define detach_doc "oob_channel_detach(window_id) -> bool. Stop, join and free the window's OOB channel (no-op False if none)."
    unsigned long long window_id;
    if (!PyArg_ParseTuple(args, "K", &window_id)) return NULL;
    OOBChannel *c = find_channel(window_id);
    if (!c) Py_RETURN_FALSE;
    // Unlink from the parser FIRST: attach/detach and the parse tick all
    // run on the main thread, so after this store no drain can touch the
    // ring we are about to free.
    vt_parser_set_oob_channel(c->parser, NULL);
    pthread_mutex_lock(&c->mutex);
    c->stop = true;
    pthread_cond_broadcast(&c->cond);
    pthread_mutex_unlock(&c->mutex);
    shutdown(c->fd, SHUT_RDWR);  // unblock a reader sleeping in read()
    if (c->thread_started) {
        Py_BEGIN_ALLOW_THREADS
        pthread_join(c->thread, NULL);
        Py_END_ALLOW_THREADS
    }
    const char *v = getenv("KITTY_OOB_STATS");
    if (v && v[0] && strcmp(v, "0") != 0) emit_stats_line(c);
    OOBChannel **pp = &channels;
    while (*pp && *pp != c) pp = &(*pp)->next;
    if (*pp) { *pp = c->next; num_channels--; }
    safe_close(c->fd, __FILE__, __LINE__);
    Py_DECREF(c->parser);
    free_channel_struct(c);
    Py_RETURN_TRUE;
}

static PyObject*
py_oob_channel_stats(PyObject *self UNUSED, PyObject *args) {
#define stats_doc "oob_channel_stats(window_id) -> dict | None. Diagnostic counters for the window's OOB channel."
    unsigned long long window_id;
    if (!PyArg_ParseTuple(args, "K", &window_id)) return NULL;
    OOBChannel *c = find_channel(window_id);
    if (!c) Py_RETURN_NONE;
    return Py_BuildValue(
        "{s:K, s:K, s:K, s:K, s:n, s:n, s:O, s:O, s:O}",
        "bytes_in", (unsigned long long)atomic_load_explicit(&c->bytes_in, memory_order_relaxed),
        "reads", (unsigned long long)atomic_load_explicit(&c->reads, memory_order_relaxed),
        "park_cycles", (unsigned long long)atomic_load_explicit(&c->park_cycles, memory_order_relaxed),
        "fallbacks", (unsigned long long)atomic_load_explicit(&c->fallbacks, memory_order_relaxed),
        "ring_used", (Py_ssize_t)vt_ring_used(c->ring),
        "ring_highwater", (Py_ssize_t)atomic_load_explicit(&c->ring_highwater, memory_order_relaxed),
        "handshake_ok", atomic_load_explicit(&c->handshake_ok, memory_order_relaxed) ? Py_True : Py_False,
        "broken", atomic_load_explicit(&c->broken, memory_order_relaxed) ? Py_True : Py_False,
        "thread_done", atomic_load_explicit(&c->thread_done, memory_order_relaxed) ? Py_True : Py_False);
}

static PyObject*
py_oob_channel_count(PyObject *self UNUSED, PyObject *args UNUSED) {
#define count_doc "oob_channel_count() -> int. Number of live OOB channels (teardown-battery probe)."
    return PyLong_FromUnsignedLong(num_channels);
}

static PyMethodDef module_methods[] = {
    {"oob_channel_attach", (PyCFunction)py_oob_channel_attach, METH_VARARGS, attach_doc},
    {"oob_channel_detach", (PyCFunction)py_oob_channel_detach, METH_VARARGS, detach_doc},
    {"oob_channel_stats", (PyCFunction)py_oob_channel_stats, METH_VARARGS, stats_doc},
    {"oob_channel_count", (PyCFunction)py_oob_channel_count, METH_NOARGS, count_doc},
    {NULL, NULL, 0, NULL}
};

bool
init_oob_channel(PyObject *module) {
    return PyModule_AddFunctions(module, module_methods) == 0;
}
