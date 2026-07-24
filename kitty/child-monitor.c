/*
 * child-monitor.c
 * Copyright (C) 2017 Kovid Goyal <kovid at kovidgoyal.net>
 *
 * Distributed under terms of the GPL3 license.
 */

#include "loop-utils.h"
#include "safe-wrappers.h"
#include "state.h"
#include "threading.h"
#include "screen.h"
#include "monotonic.h"
#include <termios.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <signal.h>
#include <stdatomic.h>
extern PyTypeObject Screen_Type;

// Phase 4 (L5): host time of the last local key input, stamped on the main thread
// in on_key_input() and read by the I/O thread (io_loop) to fast-path a
// keystroke's echo past the input_delay coalescing. Relaxed atomic — a stale read
// only misses one fast-path, which is harmless.
static _Atomic(monotonic_t) last_local_key_input_at = 0;
void note_local_key_input(void) { atomic_store_explicit(&last_local_key_input_at, monotonic(), memory_order_relaxed); }
// A keystroke echo is a SMALL read arriving shortly after the key; bulk output
// (large reads) keeps batching to avoid full-redraw flicker.
#define L5_SMALL_READ_MAX ((size_t)128)
#define L5_KEY_RECENCY_WINDOW (ms_to_monotonic_t(50ll))

#if defined(__APPLE__) || defined(__OpenBSD__)
#define NO_SIGQUEUE 1
#endif

#ifdef DEBUG_EVENT_LOOP
#define EVDBG(...) timed_debug_print(__VA_ARGS__)
#else
#define EVDBG(...)
#endif

#ifdef __APPLE__
#include <os/signpost.h>
#include <mach/mach_time.h>  // Wave-20 T1.1: ktrace_epoch mono↔mach clock anchor
#include <sys/event.h>       // Wave-22: reader-thread kqueue wait + EVFILT_USER wake channel
#include <sys/resource.h>    // Wave-22: RLIMIT_NOFILE raise (ON arm only)
#include <limits.h>          // Wave-22: OPEN_MAX clamp for setrlimit

// Phase 0 instrumentation: env-gated os_signpost spans for the main loop's
// parse/render/render-gate stages. Uses the same log subsystem/category as
// the Metal backend's instrumentation (kitty/metal.m) so every span lands in
// one Instruments track. Zero-cost when KITTY_METAL_SIGNPOST is unset: each
// call site collapses to a single cached-bool check.
static bool
child_monitor_signpost_enabled(void) {
    static int state = -1;
    if (state < 0) { const char *v = getenv("KITTY_METAL_SIGNPOST"); state = (v && v[0] && strcmp(v, "0") != 0) ? 1 : 0; }
    return state == 1;
}

// os_log handle backing the signposts. Created lazily on first use; only
// ever reached when signposts are enabled.
static os_log_t
child_monitor_signpost_log(void) {
    static os_log_t handle = NULL;
    if (!handle) handle = os_log_create("net.kovidgoyal.kitty", "metal");
    return handle;
}
#endif

#define EXTRA_FDS 2
#ifndef MSG_NOSIGNAL
// Apple does not implement MSG_NOSIGNAL
#define MSG_NOSIGNAL 0
#endif
#define USE_RENDER_FRAMES (global_state.has_render_frames && OPT(sync_to_monitor))

typedef struct {
    char *data;
    size_t sz;
    id_type peer_id;
    bool is_remote_control_peer;
} Message;

typedef struct {
    PyObject_HEAD

    PyObject *dump_callback, *update_screen, *death_notify;
    unsigned int count;
    bool shutting_down;
    pthread_t io_thread, talk_thread;

    int talk_fd, listen_fd;
    Message *messages;
    size_t messages_capacity, messages_count;
    LoopData io_loop_data;
    void (*parse_func)(void*, ParseData*, bool);
} ChildMonitor;


#ifdef KITTY_BACKEND_METAL
// Wave-22: per-child reader thread (KITTY_READER_THREADS, default-OFF).
typedef struct ReaderThread ReaderThread;
#endif

typedef struct {
    Screen *screen;
    bool needs_removal, child_died;
    int fd;
    // Where this child's OUTPUT is read from. Equal to fd normally; under
    // KITTY_PTY_PUMP it is the pump pipe's read end while fd (the pty
    // master) keeps serving writes, TIOCSWINSZ and process-group queries.
    // Every POLLIN/read site must use read_fd; every other use stays on fd.
    int read_fd;
    unsigned long id;
    pid_t pid;
    int exit_status;
#ifdef KITTY_BACKEND_METAL
    // Wave-22: non-NULL iff this child's reads are owned by a reader thread
    // (ON arm). Compaction memmoves it with the child; mutated on the io
    // thread under children_mutex; read by the main thread only under
    // children_mutex (the O15 publish/retire protocol).
    ReaderThread *reader;
#endif
} Child;

static const Child EMPTY_CHILD = {0};
// Gauge of live children whose read_fd != fd (KITTY_PTY_PUMP interposed).
// Ungated: add/remove_children run in both backends; only the ftrace
// reporting of it is Metal-gated.
static _Atomic(unsigned) io_pump_children;
#define screen_mutex(op, which) \
    pthread_mutex_##op(&screen->which##_buf_lock);
#define children_mutex(op) \
    pthread_mutex_##op(&children_lock);
#define talk_mutex(op) \
    pthread_mutex_##op(&talk_lock);


static Child children[MAX_CHILDREN] = {{0}};
static Child scratch[MAX_CHILDREN] = {{0}};
static Child add_queue[MAX_CHILDREN] = {{0}}, remove_queue[MAX_CHILDREN] = {{0}}, remove_notify[MAX_CHILDREN] = {{0}};
static size_t add_queue_count = 0, remove_queue_count = 0;
// Sized for the KITTY_PTY_PUMP worst case: every child slot may need one
// per-iteration POLLOUT tail slot for its pty master (the child slot itself
// watches the pump pipe for POLLIN). Tail slots are rebuilt every io_loop
// iteration; pump-off worlds never use them.
static struct pollfd children_fds[2 * MAX_CHILDREN + EXTRA_FDS] = {{0}};
// Tail-slot index -> child index map for the current io_loop iteration
// (io-thread private, rebuilt alongside the tail slots).
static size_t pump_out_child[MAX_CHILDREN];
static pthread_mutex_t children_lock, talk_lock;
static bool kill_signal_received = false, reload_config_signal_received = false;
static ChildMonitor *the_monitor = NULL;

typedef struct {
    pid_t pid;
    int status;
} ReapedPID;

static pid_t monitored_pids[256] = {0};
static size_t monitored_pids_count = 0;
static ReapedPID reaped_pids[arraysz(monitored_pids)] = {{0}};
static size_t reaped_pids_count = 0;



// Main thread functions {{{

#define FREE_CHILD(x) \
    Py_CLEAR((x).screen); x = EMPTY_CHILD;

#define XREF_CHILD(x, OP) OP(x.screen);
#define INCREF_CHILD(x) XREF_CHILD(x, Py_INCREF)
#define DECREF_CHILD(x) XREF_CHILD(x, Py_DECREF)

// The max time to wait for events from the window system
// before ticking over the main loop. Negative values mean wait forever.
static monotonic_t maximum_wait = -1;

static void
set_maximum_wait(monotonic_t val) {
    if (val >= 0 && (val < maximum_wait || maximum_wait < 0)) maximum_wait = val;
}

#define KITTY_HANDLED_SIGNALS SIGINT, SIGHUP, SIGTERM, SIGCHLD, SIGUSR1, SIGUSR2, 0

static void
mask_variadic_signals(int sentinel, ...) {
    sigset_t signals;
    sigemptyset(&signals);
    va_list valist;
    va_start(valist, sentinel);
    while (true) {
        int sig = va_arg(valist, int);
        if (sig == sentinel) break;
        sigaddset(&signals, sig);
    }
    va_end(valist);
#ifdef HAS_SIGNAL_FD
    sigprocmask(SIG_BLOCK, &signals, NULL);
#else
    struct sigaction act = {.sa_handler=SIG_IGN, .sa_flags=SA_RESTART, .sa_mask = signals};
    va_start(valist, sentinel);
    while (true) {
        int sig = va_arg(valist, int);
        if (sig == sentinel) break;
        sigaction(sig, &act, NULL);
    }
    va_end(valist);
#endif
}

static PyObject*
mask_kitty_signals_process_wide(PyObject *self UNUSED, PyObject *a UNUSED) {
    mask_variadic_signals(0, KITTY_HANDLED_SIGNALS);
    Py_RETURN_NONE;
}

static int verify_peer_uid = false;

#ifdef KITTY_BACKEND_METAL
// Wave-22: defined with the reader machinery in the io-thread section;
// needed at ChildMonitor init for the condition-6 RLIMIT_NOFILE raise.
static bool reader_threads_enabled(void);
static void raise_nofile_limit_for_readers(void);
#endif

static PyObject *
new_childmonitor_object(PyTypeObject *type, PyObject *args, PyObject UNUSED *kwds) {
    ChildMonitor *self;
    PyObject *dump_callback, *death_notify;
    int talk_fd = -1, listen_fd = -1;
    int ret;

    if (the_monitor) { PyErr_SetString(PyExc_RuntimeError, "Can have only a single ChildMonitor instance"); return NULL; }
    if (!PyArg_ParseTuple(args, "OO|iip", &death_notify, &dump_callback, &talk_fd, &listen_fd, &verify_peer_uid)) return NULL;
    if ((ret = pthread_mutex_init(&children_lock, NULL)) != 0) {
        PyErr_Format(PyExc_RuntimeError, "Failed to create children_lock mutex: %s", strerror(ret));
        return NULL;
    }
    if ((ret = pthread_mutex_init(&talk_lock, NULL)) != 0) {
        PyErr_Format(PyExc_RuntimeError, "Failed to create talk_lock mutex: %s", strerror(ret));
        return NULL;
    }
    self = (ChildMonitor *)type->tp_alloc(type, 0);
    if (!init_loop_data(&self->io_loop_data, KITTY_HANDLED_SIGNALS)) return PyErr_SetFromErrno(PyExc_OSError);
    self->talk_fd = talk_fd;
    self->listen_fd = listen_fd;
    if (self == NULL) return PyErr_NoMemory();
    self->death_notify = death_notify; Py_INCREF(death_notify);
    if (dump_callback != Py_None) {
        self->dump_callback = dump_callback; Py_INCREF(dump_callback);
        self->parse_func = parse_worker_dump;
    } else self->parse_func = parse_worker;
    self->count = 0;
    children_fds[0].fd = self->io_loop_data.wakeup_read_fd; children_fds[1].fd = self->io_loop_data.signal_read_fd;
    children_fds[0].events = POLLIN; children_fds[1].events = POLLIN; children_fds[2].events = POLLIN;
    the_monitor = self;
#ifdef KITTY_BACKEND_METAL
    // Wave-22 condition 6: ON arm only, before the first reader spawn. The
    // OFF arm performs no raise and stays the true legacy process.
    if (reader_threads_enabled()) raise_nofile_limit_for_readers();
#endif

    return (PyObject*) self;
}

static void
dealloc(ChildMonitor* self) {
    if (self->messages) {
        for (size_t i = 0; i < self->messages_count; i++) free(self->messages[i].data);
        free(self->messages); self->messages = NULL;
        self->messages_count = 0; self->messages_capacity = 0;
    }
    pthread_mutex_destroy(&children_lock);
    pthread_mutex_destroy(&talk_lock);
    Py_CLEAR(self->dump_callback);
    Py_CLEAR(self->death_notify);
    while (remove_queue_count) {
        remove_queue_count--;
        FREE_CHILD(remove_queue[remove_queue_count]);
    }
    while (add_queue_count) {
        add_queue_count--;
        FREE_CHILD(add_queue[add_queue_count]);
    }
    free_loop_data(&self->io_loop_data);
    Py_TYPE(self)->tp_free((PyObject*)self);
}

static PyObject*
handled_signals(ChildMonitor *self, PyObject *args UNUSED) {
    PyObject *ans = PyTuple_New(self->io_loop_data.num_handled_signals);
    if (ans) {
        for (Py_ssize_t i = 0; i < PyTuple_GET_SIZE(ans); i++) {
            PyTuple_SET_ITEM(ans, i, PyLong_FromLong((long)self->io_loop_data.handled_signals[i]));
        }
    }
    return ans;
}

static void
wakeup_io_loop(ChildMonitor *self, bool in_signal_handler) {
    wakeup_loop(&self->io_loop_data, in_signal_handler, "io_loop");
}

static void* io_loop(void *data);
static void* talk_loop(void *data);
static void send_response_to_peer(id_type peer_id, const char *msg, size_t msg_sz, bool is_async_response);
static void wakeup_talk_loop(bool);
static bool add_peer_to_injection_queue(int peer_fd, int pipe_fd);
static int start_talk_thread(ChildMonitor*);
static bool talk_thread_started = false;

static bool
simple_read_from_pipe(int fd, void *data, size_t sz) {
    // read a small amount of data to a pipe handling only EINTR
    while (true) {
        ssize_t ret = read(fd, data, sz);
        if (ret == -1 && errno == EINTR) continue;
        return ret == (ssize_t)sz;
    }
}


static PyObject*
inject_peer(PyObject *s, PyObject *a) {
#define inject_peer_doc "inject_peer(fd) -> Start communication with a peer over the specified file descriptor"
    ChildMonitor *self = (ChildMonitor*)s;
    if (!PyLong_Check(a)) { PyErr_SetString(PyExc_TypeError, "peer fd must be an int"); return NULL; }
    long fd = PyLong_AsLong(a);
    if (fd < 0) { PyErr_Format(PyExc_ValueError, "Invalid peer fd: %ld", fd); return NULL; }
    if ((errno = start_talk_thread(self)) != 0) return PyErr_SetFromErrno(PyExc_OSError);
    int fds[2] = {0};
    if (!self_pipe(fds, false)) {
        safe_close(fd, __FILE__, __LINE__);
        return PyErr_SetFromErrno(PyExc_OSError);
    }
    if (!add_peer_to_injection_queue(fd, fds[1])) {
        safe_close(fd, __FILE__, __LINE__);
        safe_close(fds[0], __FILE__, __LINE__); safe_close(fds[1], __FILE__, __LINE__);
        PyErr_SetString(PyExc_RuntimeError, "Too many peers waiting to be injected");
        return NULL;
    }
    wakeup_talk_loop(false);
    id_type peer_id = 0;
    bool ok = simple_read_from_pipe(fds[0], &peer_id, sizeof(peer_id));
    safe_close(fds[0], __FILE__, __LINE__);
    if (!ok) { PyErr_SetString(PyExc_RuntimeError, "Failed to read peer id from self pipe"); return NULL; }
    return PyLong_FromUnsignedLongLong(peer_id);
}

static PyObject *
start(PyObject *s, PyObject *a UNUSED) {
#define start_doc "start() -> Start the I/O thread"
    ChildMonitor *self = (ChildMonitor*)s;
    int ret;
    if (self->talk_fd > -1 || self->listen_fd > -1) {
        if ((errno = start_talk_thread(self)) != 0) return PyErr_SetFromErrno(PyExc_OSError);
    }
    ret = pthread_create(&self->io_thread, NULL, io_loop, self);
    if (ret != 0) return PyErr_Format(PyExc_OSError, "Failed to start I/O thread with error: %s", strerror(ret));

    Py_RETURN_NONE;
}

static PyObject *
wakeup(ChildMonitor *self, PyObject *args UNUSED) {
#define wakeup_doc "wakeup() -> wakeup the ChildMonitor I/O thread, forcing it to exit from poll() if it is waiting there."
    wakeup_io_loop(self, false);
    Py_RETURN_NONE;
}

static PyObject *
add_child(ChildMonitor *self, PyObject *args) {
#define add_child_doc "add_child(id, pid, fd, read_fd, screen) -> Add a child. read_fd is where output is read from (== fd unless KITTY_PTY_PUMP interposes a pump pipe)."
    children_mutex(lock);
    if (self->count + add_queue_count >= MAX_CHILDREN) { PyErr_SetString(PyExc_ValueError, "Too many children"); children_mutex(unlock); return NULL; }
    add_queue[add_queue_count] = EMPTY_CHILD;
#define A(attr) &add_queue[add_queue_count].attr
    if (!PyArg_ParseTuple(args, "kiiiO", A(id), A(pid), A(fd), A(read_fd), A(screen))) {
        children_mutex(unlock);
        return NULL;
    }
#undef A
    INCREF_CHILD(add_queue[add_queue_count]);
    add_queue_count++;
    children_mutex(unlock);
    wakeup_io_loop(self, false);
    Py_RETURN_NONE;
}

static const unsigned write_buf_limit = 100 * 1024 * 1024;

#define schedule_write_to_child_generic(id, num, va_start, get_next_arg, va_end, found, too_much_data) \
    ChildMonitor *self = the_monitor; \
    const char *data; \
    size_t szval, sz = 0; \
    va_start(ap, num); \
    for (unsigned int i = 0; i < num; i++) { \
        get_next_arg(ap); \
        sz += szval; \
    } \
    va_end(ap); \
    children_mutex(lock); \
    for (size_t i = 0; i < self->count; i++) { \
        if (children[i].id == id) { \
            Screen *screen = children[i].screen; \
            screen_mutex(lock, write); \
            size_t space_left = screen->write_buf_sz - screen->write_buf_used; \
            if (space_left < sz) { \
                if (screen->write_buf_used + sz > write_buf_limit) { \
                    too_much_data = true; \
                    screen_mutex(unlock, write); \
                    break; \
                } \
                screen->write_buf_sz = screen->write_buf_used + sz; \
                screen->write_buf = PyMem_RawRealloc(screen->write_buf, screen->write_buf_sz); \
                if (screen->write_buf == NULL) { fatal("Out of memory."); } \
            } \
            found = true; \
            va_start(ap, num); \
            for (unsigned int i = 0; i < num; i++) { \
                get_next_arg(ap); \
                memcpy(screen->write_buf + screen->write_buf_used, data, szval); \
                screen->write_buf_used += szval; \
            } \
            va_end(ap); \
            if (screen->write_buf_sz > BUFSIZ && screen->write_buf_used < BUFSIZ) { \
                screen->write_buf_sz = BUFSIZ; \
                screen->write_buf = PyMem_RawRealloc(screen->write_buf, screen->write_buf_sz); \
                if (screen->write_buf == NULL) { fatal("Out of memory."); } \
            } \
            if (screen->write_buf_used) wakeup_io_loop(self, false); \
            screen_mutex(unlock, write); \
            break; \
        } \
    } \
    children_mutex(unlock);

void
schedule_write_to_child_if_possible(id_type id, const char *data, size_t sz, bool *found, bool *too_much_data, size_t keep_space) {
    children_mutex(lock);
    ChildMonitor *self = the_monitor;
    *found = false; *too_much_data = false;
    size_t limit = write_buf_limit > keep_space ? write_buf_limit - keep_space : 0;
    for (size_t i = 0; i < self->count; i++) {
        if (children[i].id == id) {
            Screen *screen = children[i].screen;
            screen_mutex(lock, write);
            size_t space_left = screen->write_buf_sz - screen->write_buf_used;
            if (space_left < sz) {
                if (screen->write_buf_used + sz > limit) {
                    *too_much_data = true;
                    screen_mutex(unlock, write);
                    break;
                }
                screen->write_buf_sz = screen->write_buf_used + sz;
                screen->write_buf = PyMem_RawRealloc(screen->write_buf, screen->write_buf_sz);
                if (screen->write_buf == NULL) { fatal("Out of memory."); }
            }
            *found = true;
            memcpy(screen->write_buf + screen->write_buf_used, data, sz);
            screen->write_buf_used += sz;
            if (screen->write_buf_sz > BUFSIZ && screen->write_buf_used < BUFSIZ) {
                screen->write_buf_sz = BUFSIZ;
                screen->write_buf = PyMem_RawRealloc(screen->write_buf, screen->write_buf_sz);
                if (screen->write_buf == NULL) { fatal("Out of memory."); }
            }
            if (screen->write_buf_used) wakeup_io_loop(self, false);
            screen_mutex(unlock, write);
            break;
        }
    }
    children_mutex(unlock);
}

bool
schedule_write_to_child(id_type id, unsigned num, ...) {
    va_list ap;
    bool too_much_data = false, found = false;
#define get_next_arg(ap) data = va_arg(ap, const char*); szval = va_arg(ap, size_t);
    schedule_write_to_child_generic(id, num, va_start, get_next_arg, va_end, found, too_much_data);
#undef get_next_arg
    if (too_much_data) log_error("Too much data being written to child with id: %llu dropping it", id);
    return found;
}

bool
schedule_write_to_child_python(id_type id, const char *prefix, PyObject *ap, const char *suffix) {
    if (!PyTuple_Check(ap)) return false;
    bool has_prefix = prefix && prefix[0], has_suffix = suffix && suffix[0];
    const size_t extra = (has_prefix ? 1 : 0) + (has_suffix ? 1 : 0);
    size_t num = PyTuple_GET_SIZE(ap) + extra;
    Py_ssize_t pidx;
#define py_start(ap, num) pidx = 0;
#define py_end(ap) pidx = 0;
#define get_next_arg(ap) { \
    size_t pidxf = pidx++; \
    if (pidxf == 0 && has_prefix) { data = prefix; szval = strlen(prefix); } \
    else { \
        if (has_prefix) pidxf--; \
        if (has_suffix && pidxf >= (size_t)PyTuple_GET_SIZE(ap)) { data = suffix; szval = strlen(suffix); } \
        else { \
            PyObject *t = PyTuple_GET_ITEM(ap, pidxf); \
            if (PyBytes_Check(t)) { data = PyBytes_AS_STRING(t); szval = PyBytes_GET_SIZE(t); } \
            else { \
                Py_ssize_t usz; \
                data = PyUnicode_AsUTF8AndSize(t, &usz); szval = usz; \
                if (!data) fatal("Failed to convert object to bytes in schedule_write_to_child_python"); \
            } \
        } \
    } \
}
    bool found = false, too_much_data = false;
    schedule_write_to_child_generic(id, num, py_start, get_next_arg, py_end, found, too_much_data);
    if (too_much_data) log_error("Too much data being written to child with id: %llu dropping it", id);
    return found;
#undef py_start
#undef py_end
#undef get_next_arg
}

static PyObject *
needs_write(ChildMonitor UNUSED *self, PyObject *args) {
#define needs_write_doc "needs_write(id, data) -> Queue data to be written to child."
    unsigned long id;
    Py_buffer buf;
    if (!PyArg_ParseTuple(args, "ky*", &id, &buf)) return NULL;
    if (schedule_write_to_child(id, 1, buf.buf, (size_t)buf.len)) { Py_RETURN_TRUE; }
    Py_RETURN_FALSE;
}

static PyObject *
shutdown_monitor(ChildMonitor *self, PyObject *a UNUSED) {
#define shutdown_monitor_doc "shutdown_monitor() -> Shutdown the monitor loop."
    self->shutting_down = true;
    wakeup_talk_loop(false);
    wakeup_io_loop(self, false);
    int ret = pthread_join(self->io_thread, NULL);
    if (ret != 0) return PyErr_Format(PyExc_OSError, "Failed to join() I/O thread with error: %s", strerror(ret));
    if (talk_thread_started) {
        ret = pthread_join(self->talk_thread, NULL);
        if (ret != 0) return PyErr_Format(PyExc_OSError, "Failed to join() talk thread with error: %s", strerror(ret));
    }
    talk_thread_started = false;
    Py_RETURN_NONE;
}

#ifdef KITTY_BACKEND_METAL
// KITTY_FRAME_TRACE=1: Wave-15 Step-0 per-tick frame-readiness probe. Sibling of
// KITTY_PACING_DEBUG -- the env var is resolved ONCE into a cached bool (zero
// cost when off, a single predictable branch), Metal-only, main-thread only,
// allocation-free. Emits one parseable "ftrace:" line per main-loop tick
// (process_global_state) via log_error, capturing that tick's timeline: a
// monotonic timestamp, the inter-tick gap, bytes drained from the transport
// ring, parse wall, render wall, and the focused (bench) window's render-gate
// outcome + whether a present was committed. Fully composable with
// KITTY_PACING_DEBUG (independent state; both may be on at once, no arm changes).
// Step-0b reconstructs per-sample timelines from these lines correlated with
// vtebench sample boundaries (a vtebench "sample" times write_all(bench)+flush of
// the benchmark buffer, i.e. PTY write back-pressure, so bytes-drained/tick is
// the throughput axis -- there is no present-sync in the sample loop).
typedef enum FtGateOutcome {
    FT_GATE_NONE = 0,   // focused window not gated this tick (render() skipped it, or none focused)
    FT_GATE_IMMEDIATE,  // immediate-encode fast path (rendered inline)
    FT_GATE_READY,      // render_state READY / keep_rendering_till_swap fallthrough (rendered)
    FT_GATE_RESCUE,     // Wave-14 stall-rescue fired (rendered inline)
    FT_GATE_NREQ,       // deferred: NOT_REQUESTED -> requested a frame, no render this tick
    FT_GATE_FALLBACK,   // deferred: REQUESTED past the stall bound but refresh-capped, no render
    FT_GATE_WAITING,    // deferred: REQUESTED and link fresh, waiting for the pace tick, no render
    FT_GATE_ECHO_IMM,   // Wave-20 L-TYPING lever: keypress-echo frame encoded inline from the
                        // REQUESTED state (KITTY_METAL_ECHO_IMMEDIATE=1 only; default OFF)
} FtGateOutcome;
// All written on the render/main thread (gate + parse) and read by the emitter
// on the same thread, so plain statics suffice (mirrors pacing_stall_bound_eff).
static uint64_t ft_seq;                // emitted-line counter
static monotonic_t ft_prev_ts;         // previous emitted tick timestamp, for gap_ms
static uint64_t ft_bytes_drained;      // bytes drained from transport rings this tick
static uint64_t ft_oob_drained;        // R3: subset of ft_bytes_drained that came from OOB channel rings
static FtGateOutcome ft_gate_outcome;  // focused window's gate branch this tick
static bool ft_present_committed;      // focused window presented (swap) this tick
static const char* const ft_gate_names[] = {
    "none", "immediate", "ready", "rescue", "nreq", "fallback", "waiting", "echo_imm"
};
// Wave-19 L4: DECSET-2026 pause/drain decomposition fields (summed across
// every screen parsed this tick, mirroring ft_bytes_drained; the fill
// gauges overwrite-per-screen since the bench harness runs one window).
static uint64_t ft_parsed_bytes;
static uint64_t ft_pause_starts, ft_pause_stops;
// Wave-21 L4: pause-snapshot COW probe counters (KITTY_PAUSE_SNAPSHOT_COW).
static uint64_t ft_cow_copied, ft_cow_skip_eligible;
static uint64_t ft_share_rows_total, ft_share_rows_ref, ft_share_cow_retires;  // Wave-25 Lane S
static size_t ft_arena_fill_start, ft_arena_fill_end;
static size_t ft_ring_fill_start, ft_ring_fill_end;
static bool ft_paused_at_end;
// Wave-19 L3: io-thread-side PTY read/poll probe. Written by the io thread
// (io_loop/read_bytes, single writer), read by the main thread when it
// piggybacks these cumulative (never-reset) counters onto the ftrace line;
// relaxed atomics are sufficient since these are diagnostic-only and no
// other state is synchronized off them (mirrors last_local_key_input_at's
// existing cross-thread convention in this file).
static _Atomic(uint64_t) io_loop_iters;        // io_loop while()-top passes
static _Atomic(uint64_t) io_poll_calls;        // poll() syscalls issued
static _Atomic(uint64_t) io_poll_ns;           // wall time inside poll()
static _Atomic(uint64_t) io_read_calls;        // read_bytes() successful read() syscalls
static _Atomic(uint64_t) io_read_bytes;        // bytes returned by those read() calls
static _Atomic(uint64_t) io_read_ns;           // wall time inside the read() syscall
static _Atomic(uint64_t) io_avail_bytes;       // sum of available_buffer_space offered to read()
static _Atomic(uint64_t) io_wrap_capped_calls; // reads whose request was capped by the ring's
                                                // physical wrap point rather than by true free space
static _Atomic(uint64_t) io_pollin_disarmed;   // vt_parser_arm_pollin() false (ring genuinely full)
// Wave-20 T1.1: per-keypress-echo stage stamps (S1..S4 of the typing
// input→present decomposition; S5 pairs offline with the metal_present
// stats line). S1 is last_local_key_input_at itself. Io-thread fields are
// relaxed atomics (io_loop is their single writer); kt_parse_at/
// kt_emitted_key_at are main-thread-only plain statics. One in-flight
// journey is enough: the typing harness paces injections >= 80 ms apart,
// far beyond a single echo's lifetime; a fresh key simply supersedes an
// unemitted predecessor (visible as a missing seq in the artifact).
static _Atomic(monotonic_t) kt_echo_read_at;   // S2: io thread read this key's echo
static _Atomic(uint64_t) kt_echo_bytes;        // bytes in that echo read pass
static _Atomic(bool) kt_l5_miss;               // echo missed the L5 fast-path window (still stamped)
static monotonic_t kt_parse_at;                // S3: first do_parse at/after the echo
static monotonic_t kt_emitted_key_at;          // dedupe: newest key stamp already emitted
static uint64_t kt_seq;                        // emitted ktrace line counter
static bool kt_epoch_emitted;                  // one-time mono↔mach anchor line
// Instrumentation-only recency bound for stamping an echo that missed the
// L5 window (plan T1.1 l5_miss rule: stamp + flag, never drop).
#define KT_ECHO_STAMP_WINDOW (ms_to_monotonic_t(500ll))
// Wave-22 (named gate instrument): per-reader-thread counters. One slot per
// reader thread, claimed at reader spawn and owned single-writer by that
// reader for its lifetime — keyed by reader, never by children[] index,
// because remove_children() compacts that array. Cumulative, never reset;
// summed onto the ftrace line by the main thread with the same
// relaxed-atomic convention as the io_* family above. rd_wake_* decompose
// wakeups by cause; their sum equals wakeups (the pinned gate-2 numerator
// is ALL causes).
typedef struct {
    _Atomic(uint64_t) wakeups;         // returns from the blocking kevent wait, ALL causes
    _Atomic(uint64_t) wake_data;       //   cause: master-fd data readiness
    _Atomic(uint64_t) wake_timer;      //   cause: deferred batch-flush timeout
    _Atomic(uint64_t) wake_unpark;     //   cause: consumer unpark trigger
    _Atomic(uint64_t) wake_teardown;   //   cause: teardown/shutdown trigger
    _Atomic(uint64_t) reads;           // successful read() syscalls
    _Atomic(uint64_t) bytes;           // bytes returned by those reads
    _Atomic(uint64_t) park_cycles;     // ring-full park entries
    _Atomic(uint64_t) batch_flushes;   // deferred-window main-loop wakeups issued
    _Atomic(uint64_t) echo_immediates; // L5 echo-bypass immediate wakeups issued
} ReaderCounters;
static ReaderCounters reader_counters[MAX_CHILDREN];
// Slot high-water mark, bumped under children_mutex when a reader claims a
// slot. Stays 0 while KITTY_READER_THREADS is off, so the ftrace sum loop
// below runs zero iterations on the OFF arm.
static _Atomic(unsigned) reader_slot_hwm;

static bool
frame_trace_enabled(void) {
    static int cached = -1;
    if (UNLIKELY(cached < 0)) {
        const char *v = getenv("KITTY_FRAME_TRACE");
        cached = (v && v[0] && v[0] != '0') ? 1 : 0;
    }
    return cached == 1;
}

// Wave-22 kill switch: per-child reader-thread skeleton. ON iff the env var
// is set, non-empty and not exactly "0". One-shot cached like
// frame_trace_enabled() — resolved at first use for the process lifetime, so
// a mid-session env flip is structurally impossible and the OFF arm's only
// cost is this cached-bool branch at each gated call site.
static bool
reader_threads_enabled(void) {
    static int cached = -1;
    if (UNLIKELY(cached < 0)) {
        const char *v = getenv("KITTY_READER_THREADS");
        cached = (v && v[0] && strcmp(v, "0") != 0) ? 1 : 0;
    }
    return cached == 1;
}

// Wave-22 aggregate wakeup coalescing (design D2.5). Memory orders on every
// operation touching this flag are pinned by the proof-carrying spec
// .omc/verify/wave22/R22-B2-RESTATEMENT.md (P3/P4/P5): reader CAS 0->1 with
// seq_cst success AND failure orders; main-thread clear = seq_cst store at
// parse-tick entry BEFORE any ring drain (clear-before-drain, O2), followed
// by a seq_cst fence. Do not weaken any of them: the CAS-loser's bytes are
// proven visible only through that seq_cst bracketing.
static _Atomic(bool) main_wakeup_pending;

// Wave-22 reader thread (one per child, D2.1). The reader is the sole SPSC
// producer for its child's ring (D2.2); its kqueue carries EVFILT_READ on
// the master fd plus the EVFILT_USER wake channel (M0-verified: cross-thread
// NOTE_TRIGGER wake, trigger-before-wait retention, trigger->join->close
// teardown; .omc/verify/wave22/R22-EVFILT-USER.md).
struct ReaderThread {
    pthread_t thread;
    ChildMonitor *monitor;
    Screen *screen;      // borrowed: the Child's ref outlives the reader — the
                         // child reaches remove_queue only AFTER the join
    int kq;              // reader-owned kqueue; closed only after join (O6)
    int master_fd;       // shared OFD: nonblocking reads only, flags never mutated (O9)
    unsigned slot;       // reader_counters index, stable for the reader's lifetime
    _Atomic(bool) stop;  // release-store by teardown, acquire-load by the reader (P10)
    unsigned long child_id;
};

#define READER_WAKE_IDENT 1
// Condition 7 (pre-registered): bounded drain CAP, the D4-validated value.
#define READER_DRAIN_CAP 64
// Wave-22: reader-owned wake-channel trigger; also used by the main thread
// under children_mutex (O15) and by teardown before the join.
static void reader_trigger_wake(ReaderThread *rt);
static void reader_unpark_for_screen(ChildMonitor *self, Screen *screen);

static inline double
ft_ms(monotonic_t t) { return (double)t / (double)MONOTONIC_T_1e6; }

static void
frame_trace_emit(monotonic_t ts, bool input_read, monotonic_t parse_dt, monotonic_t render_dt) {
    const monotonic_t gap = ft_prev_ts ? ts - ft_prev_ts : 0;
    ft_prev_ts = ts;
    // Wave-19 L3: cumulative (never-reset) io-thread counters, loaded with
    // relaxed atomics since this is diagnostic-only cross-thread reporting
    // piggybacked on the main-thread ftrace line (post-process by diffing
    // consecutive lines; avoids any read-then-reset race with the writer).
    const uint64_t io_iters = atomic_load_explicit(&io_loop_iters, memory_order_relaxed);
    const uint64_t io_polls = atomic_load_explicit(&io_poll_calls, memory_order_relaxed);
    const uint64_t io_pns = atomic_load_explicit(&io_poll_ns, memory_order_relaxed);
    const uint64_t io_reads = atomic_load_explicit(&io_read_calls, memory_order_relaxed);
    const uint64_t io_rbytes = atomic_load_explicit(&io_read_bytes, memory_order_relaxed);
    const uint64_t io_rns = atomic_load_explicit(&io_read_ns, memory_order_relaxed);
    const uint64_t io_avail = atomic_load_explicit(&io_avail_bytes, memory_order_relaxed);
    const uint64_t io_wrapcap = atomic_load_explicit(&io_wrap_capped_calls, memory_order_relaxed);
    const uint64_t io_pdis = atomic_load_explicit(&io_pollin_disarmed, memory_order_relaxed);
    // Wave-22: per-reader instrument sums (cumulative, diff consecutive
    // lines like io_*). The loop is bounded by the spawn high-water mark,
    // so the OFF arm sums nothing and every rd_* field reads 0.
    uint64_t rd_wakes = 0, rd_wd = 0, rd_wt = 0, rd_wu = 0, rd_wx = 0,
             rd_reads = 0, rd_rbytes = 0, rd_parks = 0, rd_flushes = 0, rd_echo = 0;
    const unsigned rd_hwm = atomic_load_explicit(&reader_slot_hwm, memory_order_relaxed);
    for (unsigned ri = 0; ri < rd_hwm; ri++) {
        const ReaderCounters *rc = reader_counters + ri;
#define RSUM(dst, field) dst += atomic_load_explicit(&rc->field, memory_order_relaxed)
        RSUM(rd_wakes, wakeups); RSUM(rd_wd, wake_data); RSUM(rd_wt, wake_timer);
        RSUM(rd_wu, wake_unpark); RSUM(rd_wx, wake_teardown);
        RSUM(rd_reads, reads); RSUM(rd_rbytes, bytes);
        RSUM(rd_parks, park_cycles); RSUM(rd_flushes, batch_flushes); RSUM(rd_echo, echo_immediates);
#undef RSUM
    }
    log_error("ftrace: seq=%llu ts_ms=%.3f gap_ms=%.3f bytes=%llu parse_ms=%.3f render_ms=%.3f"
              " input_read=%d gate=%s present=%d parsed=%llu pause_on=%llu pause_off=%llu"
              " paused_end=%d arena0=%llu arena1=%llu ring0=%llu ring1=%llu"
              " cow_copied=%llu cow_skip_eligible=%llu"
              " share_rows_total=%llu share_rows_ref=%llu share_cow_retires=%llu"
              " io_iters=%llu io_polls=%llu io_poll_ms=%.3f io_reads=%llu io_read_bytes=%llu"
              " io_read_ms=%.3f io_avail_bytes=%llu io_wrap_capped=%llu io_pollin_off=%llu"
              " pump_children=%u"
              " rd_on=%d rd_kevent_wakeups=%llu rd_wake_data=%llu rd_wake_timer=%llu"
              " rd_wake_unpark=%llu rd_wake_teardown=%llu rd_read_calls=%llu rd_read_bytes=%llu"
              " rd_park_cycles=%llu rd_batch_flushes=%llu rd_echo_immediates=%llu"
              " oob_drained=%llu",
              (unsigned long long)(++ft_seq), ft_ms(ts), ft_ms(gap),
              (unsigned long long)ft_bytes_drained, ft_ms(parse_dt), ft_ms(render_dt),
              input_read ? 1 : 0, ft_gate_names[ft_gate_outcome], ft_present_committed ? 1 : 0,
              (unsigned long long)ft_parsed_bytes, (unsigned long long)ft_pause_starts, (unsigned long long)ft_pause_stops,
              ft_paused_at_end ? 1 : 0,
              (unsigned long long)ft_arena_fill_start, (unsigned long long)ft_arena_fill_end,
              (unsigned long long)ft_ring_fill_start, (unsigned long long)ft_ring_fill_end,
              (unsigned long long)ft_cow_copied, (unsigned long long)ft_cow_skip_eligible,
              (unsigned long long)ft_share_rows_total, (unsigned long long)ft_share_rows_ref, (unsigned long long)ft_share_cow_retires,
              (unsigned long long)io_iters, (unsigned long long)io_polls, ft_ms((monotonic_t)io_pns),
              (unsigned long long)io_reads, (unsigned long long)io_rbytes, ft_ms((monotonic_t)io_rns),
              (unsigned long long)io_avail, (unsigned long long)io_wrapcap, (unsigned long long)io_pdis,
              atomic_load_explicit(&io_pump_children, memory_order_relaxed),
              reader_threads_enabled() ? 1 : 0, (unsigned long long)rd_wakes, (unsigned long long)rd_wd,
              (unsigned long long)rd_wt, (unsigned long long)rd_wu, (unsigned long long)rd_wx,
              (unsigned long long)rd_reads, (unsigned long long)rd_rbytes,
              (unsigned long long)rd_parks, (unsigned long long)rd_flushes, (unsigned long long)rd_echo,
              (unsigned long long)ft_oob_drained);
}
#endif

static bool
do_parse(ChildMonitor *self, Screen *screen, monotonic_t now, bool flush) {
    ParseData pd = {.dump_callback = self->dump_callback, .now = now};
    self->parse_func(screen, &pd, flush);
#ifdef KITTY_BACKEND_METAL
    // Sum ring bytes drained this tick across every screen parsed (frame-trace).
    if (UNLIKELY(frame_trace_enabled())) {
        // Wave-20 T1.1 (S3): first parse tick at/after the stamped echo.
        if (pd.input_read) {
            const monotonic_t kt_echo = atomic_load_explicit(&kt_echo_read_at, memory_order_relaxed);
            if (kt_echo > kt_parse_at) kt_parse_at = now;
        }
        ft_bytes_drained += pd.bytes_read;
        ft_oob_drained += pd.oob_bytes_read;  // R3: pty/oob drain split
        ft_parsed_bytes += pd.parsed_bytes;
        ft_pause_starts += pd.pause_starts;
        ft_pause_stops += pd.pause_stops;
        ft_cow_copied += pd.cow_copied;  // Wave-21 L4
        ft_cow_skip_eligible += pd.cow_skip_eligible;
        ft_share_rows_total += pd.share_rows_total;  // Wave-25 Lane S
        ft_share_rows_ref += pd.share_rows_ref;
        ft_share_cow_retires += pd.share_cow_retires;
        ft_arena_fill_start = pd.arena_fill_start;
        ft_arena_fill_end = pd.arena_fill_end;
        ft_ring_fill_start = pd.ring_fill_start;
        ft_ring_fill_end = pd.ring_fill_end;
        ft_paused_at_end = ft_paused_at_end || (screen->paused_rendering.expires_at != 0);
    }
#endif
    // independent of input_read: the top-of-tick ring drain can free a
    // full transport ring even when the input_delay gate declines to
    // parse, and the stalled reader needs its POLLIN re-armed either way
    if (pd.write_space_created) {
#ifdef KITTY_BACKEND_METAL
        // Wave-22 ON arm: the parked producer is this screen's reader
        // thread, not the io thread — deliver the unpark to its wake
        // channel (children_mutex-held load+trigger, O15).
        if (reader_threads_enabled()) reader_unpark_for_screen(self, screen);
        else
#endif
        wakeup_io_loop(self, false);
    }
    if (pd.input_read) {
        if (screen->paused_rendering.expires_at) {
            set_maximum_wait(MAX(0, screen->paused_rendering.expires_at - now));
            // DECSET-2026 pause gates rendering, not ring drain: without the
            // input-cadence bound below, ticks that end inside a BSU..ESU
            // window arm only the pause-expiry timeout (up to 2s) and drain
            // cadence collapses to io-wakeup starvation (~3x slower drain on
            // sync-heavy streams; Wave-19 Probe C).
            set_maximum_wait(OPT(input_delay) - pd.time_since_new_input);
        } else set_maximum_wait(OPT(input_delay) - pd.time_since_new_input);
    } else if (pd.has_pending_input) set_maximum_wait(OPT(input_delay) - pd.time_since_new_input);
    return pd.input_read;
}

static bool
parse_input(ChildMonitor *self) {
    // Parse all available input that was read in the I/O thread.
    size_t count = 0, remove_count = 0;
    bool input_read = false, reload_config_called = false;
    monotonic_t now = monotonic();
#ifdef KITTY_BACKEND_METAL
    // Wave-22 O2 clear-before-drain (R22-B2-RESTATEMENT.md P4+P5): consume
    // the coalesced-wakeup flag BEFORE any ring drain of this tick, then
    // fence so every drain load below is bracketed after the clear. The
    // clear must never move after the drains; the fence must not be dropped
    // in favor of the rings' internal fences (those run too late).
    if (reader_threads_enabled()) {
        atomic_store_explicit(&main_wakeup_pending, false, memory_order_seq_cst);
        atomic_thread_fence(memory_order_seq_cst);
    }
#endif
    children_mutex(lock);
    while (remove_queue_count) {
        remove_queue_count--;
        remove_notify[remove_count] = remove_queue[remove_queue_count];
        INCREF_CHILD(remove_notify[remove_count]);
        remove_count++;
        FREE_CHILD(remove_queue[remove_queue_count]);
    }

    bool signal_tick = false;
    if (UNLIKELY(kill_signal_received || reload_config_signal_received)) {
        signal_tick = true;
        if (kill_signal_received) {
            global_state.quit_request = IMPERATIVE_CLOSE_REQUESTED;
            global_state.has_pending_closes = true;
            request_tick_callback();
            kill_signal_received = false;
        }
        else if (reload_config_signal_received) {
            reload_config_signal_received = false;
            reload_config_called = true;
        }
    } else {
        count = self->count;
        for (size_t i = 0; i < count; i++) {
            scratch[i] = children[i];
            INCREF_CHILD(scratch[i]);
        }
    }
    children_mutex(unlock);
#ifdef KITTY_BACKEND_METAL
    // W22 M3.5 MAJOR-1 + W23 F-A: the signal branch leaves count == 0, so
    // this tick drains NO child rings — yet on the reader arm the P4 clear
    // above may have absorbed a coalesced wakeup (a CAS-loser and any
    // parked reader now expect THIS tick to drain and unpark), and on the
    // legacy arm the skipped do_parse means write_space_created never
    // reaches wakeup_io_loop for a parked io producer. Re-arm immediately
    // for BOTH arms: the signal flags were consumed above, so the next
    // tick takes the draining arm — no livelock. The legacy-arm window is
    // mechanism-real but narrow (the io thread's own signal-delivery pass
    // re-arms its wakeup chain via data_received; see
    // .omc/verify/wave23/R23-SIGTICK-VERIFICATION.md); the GL build's
    // instance of the same upstream-inherited gap is recorded for
    // upstream reporting, not patched here.
    if (UNLIKELY(signal_tick)) wakeup_main_loop();
#else
    (void)signal_tick;
#endif

    Message *msgs = NULL;
    size_t msgs_count = 0;
    talk_mutex(lock);
    if (UNLIKELY(self->messages_count)) {
        msgs = malloc(sizeof(Message) * self->messages_count);
        if (msgs) {
            memcpy(msgs, self->messages, sizeof(Message) * self->messages_count);
            msgs_count = self->messages_count;
        }
        memset(self->messages, 0, sizeof(Message) * self->messages_capacity);
        self->messages_count = 0;
    }
    talk_mutex(unlock);

    if (msgs_count) {
        for (size_t i = 0; i < msgs_count; i++) {
            Message *msg = msgs + i;
            PyObject *resp = NULL;
            if (msg->data) {
                resp = PyObject_CallMethod(global_state.boss, "peer_message_received", "y#KO", msg->data, (int)msg->sz, msg->peer_id, msg->is_remote_control_peer ? Py_True : Py_False);
                free(msg->data);
                if (!resp) PyErr_Print();
            }
            if (resp) {
                if (PyBytes_Check(resp)) send_response_to_peer(msg->peer_id, PyBytes_AS_STRING(resp), PyBytes_GET_SIZE(resp), false);
                else if (resp == Py_None) send_response_to_peer(msg->peer_id, NULL, 0, false);
                else if (resp == Py_True) send_response_to_peer(msg->peer_id, NULL, 0, true);
                Py_CLEAR(resp);
            } else send_response_to_peer(msg->peer_id, NULL, 0, false);
        }
        free(msgs); msgs = NULL;
    }

    while(remove_count) {
        // must be done while no locks are held, since the locks are non-recursive and
        // the python function could call into other functions in this module
        remove_count--;
        if (remove_notify[remove_count].screen) do_parse(self, remove_notify[remove_count].screen, now, true);
        PyObject *t = PyObject_CallFunction(
            self->death_notify, "kOi", remove_notify[remove_count].id, remove_notify[remove_count].child_died ? Py_True : Py_False, remove_notify[remove_count].exit_status);
        if (t == NULL) PyErr_Print();
        else Py_DECREF(t);
        FREE_CHILD(remove_notify[remove_count]);
    }

    for (size_t i = 0; i < count; i++) {
        if (!scratch[i].needs_removal) {
            if (do_parse(self, scratch[i].screen, now, false)) input_read = true;
        }
        DECREF_CHILD(scratch[i]);
    }
    if (reload_config_called) {
        call_boss(load_config_file, NULL);
    }
    return input_read;
}

static bool
mark_child_for_close(ChildMonitor *self, id_type window_id) {
    bool found = false;
    children_mutex(lock);
    for (size_t i = 0; i < self->count; i++) {
        if (children[i].id == window_id) {
            children[i].needs_removal = true;
            found = true;
            break;
        }
    }
    if (!found) {
        for (size_t i = 0; i < add_queue_count; i++) {
            if (add_queue[i].id == window_id) {
                add_queue[i].needs_removal = true;
                found = true;
                break;
            }
        }

    }
    children_mutex(unlock);
    wakeup_io_loop(self, false);
    return found;
}


static PyObject *
mark_for_close(ChildMonitor *self, PyObject *args) {
#define mark_for_close_doc "Mark a child to be removed from the child monitor"
    id_type window_id;
    if (!PyArg_ParseTuple(args, "K", &window_id)) return NULL;
    if (mark_child_for_close(self, window_id)) { Py_RETURN_TRUE; }
    Py_RETURN_FALSE;
}

static bool
pty_resize(int fd, struct winsize *dim) {
    while(true) {
        if (ioctl(fd, TIOCSWINSZ, dim) == -1) {
            if (errno == EINTR) continue;
            if (errno != EBADF && errno != ENOTTY) {
                log_error("Failed to resize tty associated with fd: %d with error: %s", fd, strerror(errno));
                return false;
            }
        }
        break;
    }
    return true;
}

static PyObject *
resize_pty(ChildMonitor *self, PyObject *args) {
#define resize_pty_doc "Resize the pty associated with the specified child"
    unsigned long window_id;
    struct winsize dim;
    int fd = -1;
    if (!PyArg_ParseTuple(args, "kHHHH", &window_id, &dim.ws_row, &dim.ws_col, &dim.ws_xpixel, &dim.ws_ypixel)) return NULL;
    children_mutex(lock);
#define FIND(queue, count) { \
    for (size_t i = 0; i < count; i++) { \
        if (queue[i].id == window_id) { \
            fd = queue[i].fd; \
            break; \
        } \
    }}
    FIND(children, self->count);
    if (fd == -1) FIND(add_queue, add_queue_count);
    if (fd != -1) {
        if (!pty_resize(fd, &dim)) PyErr_SetFromErrno(PyExc_OSError);
    } else log_error("Failed to send resize signal to child with id: %lu (children count: %u) (add queue: %zu)", window_id, self->count, add_queue_count);
    children_mutex(unlock);
    if (PyErr_Occurred()) return NULL;
    Py_RETURN_NONE;
}

bool
set_iutf8(int UNUSED fd, bool UNUSED on) {
#ifdef IUTF8
    struct termios attrs;
    if (tcgetattr(fd, &attrs) != 0) return false;
    if (on) attrs.c_iflag |= IUTF8;
    else attrs.c_iflag &= ~IUTF8;
    if (tcsetattr(fd, TCSANOW, &attrs) != 0) return false;
#endif
    return true;
}

static PyObject*
pyset_iutf8(ChildMonitor *self, PyObject *args) {
    id_type window_id;
    int on;
    PyObject *found = Py_False;
    if (!PyArg_ParseTuple(args, "Kp", &window_id, &on)) return NULL;
    children_mutex(lock);
    for (size_t i = 0; i < self->count; i++) {
        if (children[i].id == window_id) {
            found = Py_True;
            if (!set_iutf8(children_fds[EXTRA_FDS + i].fd, on & 1)) PyErr_SetFromErrno(PyExc_OSError);
            break;
        }
    }
    children_mutex(unlock);
    if (PyErr_Occurred()) return NULL;
    Py_INCREF(found);
    return found;
}

#undef FREE_CHILD
#undef INCREF_CHILD
#undef DECREF_CHILD

static bool
cursor_needs_render(Window *w) {
    return memcmp(&w->render_data.screen->last_rendered.cursor, &w->render_data.screen->cursor_render_info, sizeof(CursorRenderInfo)) != 0;
}

static bool
collect_cursor_info(CursorRenderInfo *ans, Window *w, monotonic_t now, OSWindow *os_window) {
    WindowRenderData *rd = &w->render_data;
    const Cursor *cursor;
    if (screen_is_overlay_active(rd->screen)) {
        // Do not force the cursor to be visible here for the sake of some programs that prefer it hidden
        cursor = &(rd->screen->overlay_line.original_line.cursor);
        ans->x = rd->screen->overlay_line.cursor_x;
        ans->y = rd->screen->overlay_line.ynum;
    } else {
        cursor = rd->screen->paused_rendering.expires_at ? &rd->screen->paused_rendering.cursor : rd->screen->cursor;
        ans->x = cursor->x; ans->y = cursor->y;
    }
    ans->is_visible = false; ans->multicursor_count = 0; ans->cursor_opacity = 1; ans->text_blink_opacity = 1;
    if (!rd->screen->scrolled_by) {
        ans->multicursor_count = screen_multi_cursor_count(rd->screen);
        ans->is_visible = screen_is_cursor_visible(rd->screen);
    }
    if (!ans->is_visible && ans->multicursor_count == 0 && !rd->screen->sgr_blink_was_used) return cursor_needs_render(w);
    monotonic_t time_since_start_blink = now - os_window->cursor_blink_zero_time;
    const bool allow_blinking = OPT(cursor_blink_interval) > 0;
    const bool blink_has_ceased = OPT(cursor_stop_blinking_after) != 0 && time_since_start_blink > OPT(cursor_stop_blinking_after);
    const bool cursor_blinking = !cursor->non_blinking && os_window->is_focused;
    float blink_opacity = 1.f;
    if (allow_blinking && !blink_has_ceased && (cursor_blinking || rd->screen->sgr_blink_was_used)) {
        if (animation_is_valid(OPT(animation.cursor))) {
            monotonic_t duration = OPT(cursor_blink_interval) * 2;
            monotonic_t time_into_cycle = time_since_start_blink % duration;
            double frac_into_cycle = (double)time_into_cycle / (double)duration;
            blink_opacity = (float)apply_easing_curve(OPT(animation.cursor), frac_into_cycle, duration);
            set_maximum_wait(ANIMATION_SAMPLE_WAIT);
        } else {
            monotonic_t n = time_since_start_blink / OPT(cursor_blink_interval);
            blink_opacity = 1 - n % 2;
            set_maximum_wait((n + 1) * OPT(cursor_blink_interval) - time_since_start_blink);
        }
    }
    ans->text_blink_opacity = blink_opacity;
    ans->cursor_opacity = cursor_blinking ? blink_opacity: 1.0f;
    ans->shape = cursor->shape ? cursor->shape : OPT(cursor_shape);
    ans->is_focused = os_window->is_focused;
    return cursor_needs_render(w);
}

static void
change_menubar_title(PyObject *title UNUSED) {
#ifdef __APPLE__
    static PyObject *current_title = NULL;
    if (title != current_title) {
        current_title = title;
        if (title && OPT(macos_show_window_title_in) & MENUBAR) update_menu_bar_title(title);
    }
#endif
}

static bool
prepare_to_render_os_window(OSWindow *os_window, monotonic_t now, unsigned int *active_window_id, color_type *active_window_bg, unsigned int *num_visible_windows, bool *all_windows_have_same_bg, bool scan_for_animated_images) {
#define TD os_window->tab_bar_render_data
    bool needs_render = os_window->needs_render;
    os_window->needs_render = false;
    bool was_previously_rendered_with_layers = os_window->needs_layers;
    os_window->needs_layers = (
        !global_state.supports_framebuffer_srgb || effective_os_window_alpha(os_window) < 1.f ||
        os_window->live_resize.in_progress || (background_image_for_os_window(os_window) != NULL)
    );
    if (TD.screen && os_window->num_tabs && !os_window->has_too_few_tabs) {
        if (!os_window->tab_bar_data_updated) {
            call_boss(update_tab_bar_data, "K", os_window->id);
            os_window->tab_bar_data_updated = true;
        }
        // we never render a cursor in the tab bar
        CursorRenderInfo *cri = &TD.screen->cursor_render_info;
        zero_at_ptr(cri); cri->x = TD.screen->cursor->x; cri->y = TD.screen->cursor->y;
        if (send_cell_data_to_gpu(TD.vao_idx, TD.screen, os_window)) needs_render = true;
        os_window->needs_layers = os_window->needs_layers || screen_needs_rendering_in_layers(os_window, NULL, TD.screen);
    }
    if (OPT(mouse_hide.hide_wait) > 0 && !is_mouse_hidden(os_window)) {
        if (now - os_window->last_mouse_activity_at >= OPT(mouse_hide.hide_wait)) hide_mouse(os_window);
        else set_maximum_wait(OPT(mouse_hide.hide_wait) - now + os_window->last_mouse_activity_at);
    }
    Tab *tab = os_window->tabs + os_window->active_tab;
    *active_window_bg = OPT(background);
    *all_windows_have_same_bg = true;
    *num_visible_windows = 0;
    color_type first_window_bg = 0;
    os_window->needs_layers = os_window->needs_layers || (OPT(cursor_trail) && tab->cursor_trail.needs_render);
    for (unsigned int i = 0; i < tab->num_windows; i++) {
        Window *w = tab->windows + i;
#define WD w->render_data
        if (w->visible && WD.screen) {
            os_window->needs_layers = os_window->needs_layers || screen_needs_rendering_in_layers(os_window, w, WD.screen);
            screen_check_pause_rendering(WD.screen, now);
            *num_visible_windows += 1;
            color_type window_bg = colorprofile_to_color(WD.screen->color_profile, WD.screen->color_profile->overridden.default_bg, WD.screen->color_profile->configured.default_bg).rgb;
            if (*num_visible_windows == 1) first_window_bg = window_bg;
            if (first_window_bg != window_bg) *all_windows_have_same_bg = false;
            if (w->last_drag_scroll_at > 0) {
                if (now - w->last_drag_scroll_at >= ms_to_monotonic_t(20ll)) {
                    if (drag_scroll(w, os_window)) {
                        w->last_drag_scroll_at = now;
                        set_maximum_wait(ms_to_monotonic_t(20ll));
                        needs_render = true;
                    } else w->last_drag_scroll_at = 0;
                } else set_maximum_wait(now - w->last_drag_scroll_at);
            }
            bool is_active_window = i == tab->active_window;
            if (is_active_window) {
                *active_window_id = w->id;
                if (collect_cursor_info(&WD.screen->cursor_render_info, w, now, os_window)) needs_render = true;
                WD.screen->cursor_render_info.is_focused = os_window->is_focused;
                set_os_window_title_from_window(w, os_window);
                *active_window_bg = window_bg;
                if (OPT(cursor_trail)) {
                    if (os_window->last_active_tab != os_window->active_tab && os_window->last_active_tab < os_window->num_tabs) {
                        tab->cursor_trail = os_window->tabs[os_window->last_active_tab].cursor_trail;
                        tab->cursor_trail.needs_render = true;
                        tab->cursor_trail.updated_at = now;
                        os_window->cursor_blink_zero_time = now;
                    }
                    if (update_cursor_trail(&tab->cursor_trail, w, now, os_window)) {
                        needs_render = true;
                        // A max wait of zero causes key input processing to be
                        // slow so handle the case of OPT(repaint_delay) == 0, see https://github.com/kovidgoyal/kitty/pull/8066
                        set_maximum_wait(MAX(OPT(repaint_delay), ms_to_monotonic_t(1ll)));
                    } else if (OPT(cursor_trail) > now - WD.screen->cursor->position_changed_by_client_at) {
                        // If update_cursor_trail failed due to time threshold, the trail animation
                        // should be evaluated again shortly. Schedule next update when enough time
                        // has passed since the cursor was last moved.
                        set_maximum_wait(OPT(cursor_trail) - now + WD.screen->cursor->position_changed_by_client_at);
                    }
                }
            } else {
                if (WD.screen->cursor_render_info.render_even_when_unfocused) {
                    if (collect_cursor_info(&WD.screen->cursor_render_info, w, now, os_window)) needs_render = true;
                    WD.screen->cursor_render_info.is_focused = false;
                } else {
                    if (WD.screen->sgr_blink_was_used) {
                        if (collect_cursor_info(&WD.screen->cursor_render_info, w, now, os_window)) needs_render = true;
                        WD.screen->cursor_render_info.is_focused = false;
                    } else {
                        WD.screen->cursor_render_info.text_blink_opacity = 1;
                    }
                    WD.screen->cursor_render_info.cursor_opacity = 0;
                }
            }
            if (scan_for_animated_images) {
                monotonic_t min_gap;
                if (scan_active_animations(WD.screen->grman, now, &min_gap, true)) needs_render = true;
                if (min_gap < MONOTONIC_T_MAX) {
                    global_state.check_for_active_animated_images = true;
                    set_maximum_wait(min_gap);
                }
            }
            if (send_cell_data_to_gpu(WD.vao_idx, WD.screen, os_window)) needs_render = true;
            if (WD.screen->start_visual_bell_at | WD.screen->start_drag_overlay_at) needs_render = true;
            // Prepare window title bar screen data for GPU
            WindowRenderData *trd = &w->window_title_render_data;
            if (trd->screen && trd->geometry.bottom > trd->geometry.top && trd->geometry.right > trd->geometry.left) {
                trd->screen->cursor_render_info.is_visible = false;
                if (send_cell_data_to_gpu(trd->vao_idx, trd->screen, os_window)) needs_render = true;
            }
        }
    }
    return needs_render || was_previously_rendered_with_layers != os_window->needs_layers;
}

static void
thumbnail_callback(OSWindow *os_window) {
#define tc global_state.thumbnail_callback
    Region region = {.right=os_window->viewport_width, .bottom=os_window->viewport_height};
    if (tc.window) {
        Window *w = window_for_window_id(tc.window);
        if (!w) return;
        region.left = w->render_data.geometry.left;
        region.top = w->render_data.geometry.top;
        region.right = w->render_data.geometry.right;
        region.bottom = w->render_data.geometry.bottom;
    } else {
        if (!tc.include_tab_bar) {
            Region central = {0}, tab_bar = {0};
            os_window_regions(os_window, &central, &tab_bar);
            if (tab_bar.bottom > tab_bar.top) region = central;
        }
    }
    unsigned vw = region.right - region.left, vh = region.bottom - region.top;
    unsigned thumb_w = (unsigned)(vw * tc.scale), thumb_h = (unsigned)(vh * tc.scale);
    if (thumb_w > tc.max_width) {
        thumb_w = tc.max_width;
        double scale = 300. / vw;
        thumb_h = (unsigned)(vh * scale + 0.5f);
    }
    RAII_PyObject(pixels, PyBytes_FromStringAndSize(NULL, (Py_ssize_t)4 * thumb_w * thumb_h));
    if (pixels && global_state.boss) {
        take_screenshot_of_rectangular_region(
            os_window, region, (unsigned char*)PyBytes_AS_STRING(pixels), &thumb_w, &thumb_h);
        _PyBytes_Resize(&pixels, (Py_ssize_t)4 * thumb_w * thumb_h);
        PyObject *r = PyObject_CallMethod(
            global_state.boss, tc.callback, "KKOII", os_window->id, tc.window, pixels, thumb_w, thumb_h);
        if (!r) PyErr_Print(); else Py_DECREF(r);
    }
#undef tc
}

static void
render_prepared_os_window(OSWindow *os_window, unsigned int active_window_id, color_type active_window_bg, unsigned int num_visible_windows, bool all_windows_have_same_bg) {
    Tab *tab = os_window->tabs + os_window->active_tab;
    setup_os_window_for_rendering(os_window, tab, NULL, true);
    BorderRects *br = &tab->border_rects;
    draw_borders(br->vao_idx, br->num_border_rects, br->rect_buf, br->is_dirty, active_window_bg, num_visible_windows, all_windows_have_same_bg, os_window);
    br->is_dirty = false;
    if (TD.screen && os_window->num_tabs && !os_window->has_too_few_tabs) draw_cells(&TD, os_window, true, true, false, NULL);
    unsigned int num_of_visible_windows = 0;
    Window *active_window = NULL;
    for (unsigned int i = 0; i < tab->num_windows; i++) { if (tab->windows[i].visible) num_of_visible_windows++; }
    for (unsigned int i = 0; i < tab->num_windows; i++) {
        Window *w = tab->windows + i;
        if (w->visible && WD.screen) {
            bool is_active_window = i == tab->active_window;
            if (is_active_window) active_window = w;
            draw_cells(&WD, os_window, is_active_window, false, num_of_visible_windows == 1, w);
            if (WD.screen->start_visual_bell_at | WD.screen->start_drag_overlay_at) set_maximum_wait(ANIMATION_SAMPLE_WAIT);
            WindowRenderData *trd = &w->window_title_render_data;
            if (trd->screen && trd->geometry.right > trd->geometry.left && trd->geometry.bottom > trd->geometry.top)
                draw_cells(trd, os_window, i == tab->active_window, true, false, NULL);
        }
    }
    setup_os_window_for_rendering(os_window, tab, active_window, false);
    if (global_state.thumbnail_callback.os_window == os_window->id) {
        thumbnail_callback(os_window);
        global_state.thumbnail_callback.os_window = 0;
    }
    swap_window_buffers(os_window);
#ifdef KITTY_BACKEND_METAL
    // Governor floor: on the IOSurface path the present happens synchronously
    // inside the swap, so this is the per-window last-present stamp the
    // immediate-encode gate compares against.
    os_window->last_gpu_present_at = monotonic();
#endif
    os_window->last_active_tab = os_window->active_tab; os_window->last_num_tabs = os_window->num_tabs; os_window->last_active_window_id = active_window_id;
    os_window->focused_at_last_render = os_window->is_focused;
    if (os_window->redraw_count) os_window->redraw_count--;
    if (USE_RENDER_FRAMES) request_frame_render(os_window);
#undef WD
#undef TD
}

static bool
no_render_frame_received_recently(OSWindow *w, monotonic_t now, monotonic_t max_wait) {
    bool ans = now - w->last_render_frame_received_at > max_wait;
    if (ans && global_state.debug_rendering) {
        if (global_state.is_wayland) {
            log_error("No render frame received in %.2f seconds", monotonic_t_to_s_double(max_wait));
        } else  {
            log_error("No render frame received in %.2f seconds, re-requesting", monotonic_t_to_s_double(max_wait));
        }
    }
    return ans;
}

#ifdef KITTY_BACKEND_METAL
// L6 (Wave-13a): the immediate-encode floor is derived from the refresh period
// of the display the window is actually on, instead of a hard-coded 8 ms.
#define IMMEDIATE_FLOOR_MIN_MS 3.0     // positive minimum: a key-repeat storm can never unpace flood
#define IMMEDIATE_FLOOR_FALLBACK_MS 8.0 // refresh unknown -> the historical constant

// Refresh rate (Hz) of the display the OS window is currently on, or 0 if
// unknown. Reads the GLFW monitor cache (refreshed on the monitor-config
// callback, not a live per-call CGDisplay query). glfwGetWindowMonitor is
// non-NULL only in fullscreen, so windowed mode finds the monitor whose bounds
// contain the window centre; primary monitor is the last resort.
static int
os_window_refresh_hz(OSWindow *w) {
    if (!w->handle || global_state.is_wayland) return 0;  // Wayland has no absolute positions; Metal is macOS-only anyway
    GLFWmonitor *mon = glfwGetWindowMonitor(w->handle);
    if (!mon) {
        int wx = 0, wy = 0, ww = 0, wh = 0;
        glfwGetWindowPos(w->handle, &wx, &wy);
        glfwGetWindowSize(w->handle, &ww, &wh);
        const int cx = wx + ww / 2, cy = wy + wh / 2;
        int count = 0;
        GLFWmonitor **mons = glfwGetMonitors(&count);
        for (int i = 0; mons && i < count; i++) {
            int mx = 0, my = 0;
            glfwGetMonitorPos(mons[i], &mx, &my);
            const GLFWvidmode *vm = glfwGetVideoMode(mons[i]);
            if (vm && cx >= mx && cx < mx + vm->width && cy >= my && cy < my + vm->height) { mon = mons[i]; break; }
        }
    }
    if (!mon) mon = glfwGetPrimaryMonitor();
    if (!mon) return 0;
    const GLFWvidmode *vm = glfwGetVideoMode(mon);
    return (vm && vm->refreshRate > 0) ? vm->refreshRate : 0;
}

// Per-window immediate-encode floor. Default: ~0.5x the display refresh period
// (8 ms @60 Hz, ~4.2 ms @120 Hz ProMotion — the win the hard-coded 8 ms left on
// the table for fast typing on ProMotion) with a positive minimum, falling back
// to the historical 8 ms when the refresh is unknown. Cached on the OS window
// and recomputed at most ~1/s, which absorbs a monitor hotplug or refresh-rate
// switch within a second without a per-frame query. This helper is only reached
// on cold input (the caller checks render_state before it) — plus, with the
// opt-in Wave-20 echo-immediate lever, on REQUESTED ticks within the 50 ms
// key-recency window — never on the steady flood hot path.
// KITTY_METAL_IMMEDIATE_FLOOR_MS=<n> forces a fixed n-ms floor (n>0); 0/unset
// derives from the refresh.
static monotonic_t
immediate_encode_floor(OSWindow *w, monotonic_t now) {
    static int env_floor_ms = -2;  // -2 unread, -1 derive, >=0 fixed override
    if (UNLIKELY(env_floor_ms == -2)) {
        const char *v = getenv("KITTY_METAL_IMMEDIATE_FLOOR_MS");
        env_floor_ms = -1;
        if (v && v[0]) { char *end = NULL; long n = strtol(v, &end, 10); if (end != v && n > 0 && n < 100000) env_floor_ms = (int)n; }
    }
    if (env_floor_ms >= 0) return ms_to_monotonic_t(env_floor_ms);
    if (w->immediate_present_floor <= 0 || now - w->immediate_floor_computed_at >= ms_to_monotonic_t(1000ll)) {
        const int hz = os_window_refresh_hz(w);
        double floor_ms = IMMEDIATE_FLOOR_FALLBACK_MS;
        if (hz > 0) {
            floor_ms = 0.5 * (1000.0 / (double)hz);
            if (floor_ms < IMMEDIATE_FLOOR_MIN_MS) floor_ms = IMMEDIATE_FLOOR_MIN_MS;
        }
        w->immediate_present_floor = ms_double_to_monotonic_t(floor_ms);
        w->immediate_floor_computed_at = now;
    }
    return w->immediate_present_floor;
}

// Wave-20 L-TYPING lever (P3, plan §Phase 3): extend the L2 immediate-encode
// fast path to keypress-echo frames that arrive while a pace-link frame
// request is already outstanding. T1-TYPING-DECOMP measured that 197/300
// echo frames classify gate=waiting and eat one full link-tick wait (S5
// 18.4 ms p50) — the only stage holding the typing rank prize. Rendering
// inline while RENDER_FRAME_REQUESTED is the Wave-14 stall-rescue's proven
// operation (request_frame_render is idempotent; the post-render resync
// re-syncs the link), and the immediate-encode floor still applies, so an
// autorepeat storm cannot present above the refresh-capped fast-path rate.
// Eligibility marker: a local key press within L5_KEY_RECENCY_WINDOW (the
// same 50 ms recency the io-side echo fast path uses).
// VERDICT (P2.1 re-adjudication, n=300/arm, GATE-ADJUDICATION.md): the
// lever works mechanically — the gate=waiting echo class vanishes and S5
// collapses 16.7→9.4 ms p50, the physical vsync-quantization floor — but
// the photon recovers only Δp50 5.96 / Δp99 1.67 ms against thresholds
// 9.32 / 10.04 (ABS floor 2.90): NO-CHARTER. The residual gap lives in S2
// (io wake + echo turnaround), Wave-21 reader-thread territory. This stays
// a measurement/reproduction lever ONLY: default OFF is byte-identical
// (goldens 4/4 max_diff=0, idle 0.0%); never flip without a fresh gate.
static bool
metal_echo_immediate_enabled(void) {
    static int cached = -1;
    if (UNLIKELY(cached < 0)) {
        const char *v = getenv("KITTY_METAL_ECHO_IMMEDIATE");
        cached = (v && v[0] && v[0] != '0') ? 1 : 0;
    }
    return cached == 1;
}

// Wave-14 pacing stall-rescue bounds. Refresh-derived from the same cached
// os_window_refresh_hz() the immediate floor uses, but stored in a SEPARATE
// OSWindow field (resync_refresh_period) -- the lead constraint is that the
// rescue must NOT touch immediate_present_floor / immediate_encode_floor. The
// period is recomputed at most ~1/s (a monitor hotplug / refresh switch
// converges within a second) and falls back to 60 Hz when the refresh is unknown.
#define RESYNC_STALL_MULT 3ll           // stall bound = 3x refresh period: above link
                                        // jitter, so a healthy REQUESTED link (restamping
                                        // last_render_frame_received_at every ~refresh)
                                        // never trips it -- only >=3 missed ticks do.
#define RESYNC_STALL_MIN_MS 24ll        // clamp floor (fast displays)
#define RESYNC_STALL_MAX_MS 60ll        // clamp ceiling (slow/unknown displays)
#define RESYNC_REFRESH_FALLBACK_HZ 60.0 // refresh unknown -> assume 60 Hz (16.67 ms period)

static monotonic_t
resync_refresh_period(OSWindow *w, monotonic_t now) {
    if (w->resync_refresh_period <= 0 || now - w->resync_refresh_computed_at >= ms_to_monotonic_t(1000ll)) {
        const int hz = os_window_refresh_hz(w);
        const double period_ms = 1000.0 / (hz > 0 ? (double)hz : RESYNC_REFRESH_FALLBACK_HZ);
        w->resync_refresh_period = ms_double_to_monotonic_t(period_ms);
        w->resync_refresh_computed_at = now;
    }
    return w->resync_refresh_period;
}

#define RESYNC_STALL_OVERRIDE_MIN_MS 8ll   // KITTY_PACING_RESYNC_STALL_MS clamp floor
#define RESYNC_STALL_OVERRIDE_MAX_MS 250ll // ...and ceiling (the old fallback cap)

// Last effective resync stall bound, cached for the KITTY_PACING_DEBUG dump
// (stall_bound_eff_ms). Written by resync_stall_bound() at the gate, read by
// pacing_debug_dump(); both on the render/main thread. 0 until first computed --
// also the value reported while the rescue is kill-switched off, since
// resync_stall_bound() is not called on that path.
static monotonic_t pacing_stall_bound_eff;

// KITTY_PACING_RESYNC_STALL_MS: Step-3 bound-sweep override. When set to a valid
// positive integer it REPLACES the 3x-refresh resync_stall_bound() formula with a
// fixed <n> ms clamped to [8, 250]; unset/invalid -> the refresh-derived bound
// EXACTLY. Resolved ONCE (same cache pattern as immediate_encode_floor's env
// override). resync_present_floor is deliberately NOT affected (stays 1x refresh
// -- pre-mortem #2 flood-storm cap). Returns the clamped monotonic_t, or 0 = none.
static monotonic_t
resync_stall_override(void) {
    static long cached_ms = -2;  // -2 unread, -1 no override, >=8 clamped ms
    if (UNLIKELY(cached_ms == -2)) {
        cached_ms = -1;
        const char *v = getenv("KITTY_PACING_RESYNC_STALL_MS");
        if (v && v[0]) {
            char *end = NULL; long n = strtol(v, &end, 10);
            if (end != v && *end == '\0' && n > 0) {
                if (n < RESYNC_STALL_OVERRIDE_MIN_MS) n = RESYNC_STALL_OVERRIDE_MIN_MS;
                if (n > RESYNC_STALL_OVERRIDE_MAX_MS) n = RESYNC_STALL_OVERRIDE_MAX_MS;
                cached_ms = n;
            }
        }
    }
    return cached_ms > 0 ? ms_to_monotonic_t((monotonic_t)cached_ms) : 0;
}

// Staleness bound for the stall-rescue: a REQUESTED link whose last delivered
// frame (last_render_frame_received_at) is older than this is treated as stalled.
static monotonic_t
resync_stall_bound(OSWindow *w, monotonic_t now) {
    const monotonic_t ov = resync_stall_override();
    monotonic_t b;
    if (ov > 0) b = ov;  // fixed override: skip the 3x-refresh formula entirely
    else {
        b = RESYNC_STALL_MULT * resync_refresh_period(w, now);
        const monotonic_t lo = ms_to_monotonic_t(RESYNC_STALL_MIN_MS), hi = ms_to_monotonic_t(RESYNC_STALL_MAX_MS);
        if (b < lo) b = lo;
        if (b > hi) b = hi;
    }
    pacing_stall_bound_eff = b;  // report the effective bound in the debug dump
    return b;
}

// Inline-rescue present floor (= 1x refresh period): caps stall-rescue renders at
// <=1/refresh so a fully starved link cannot drive flood above the refresh rate
// (preserves 13A L6). Also the deferred-with-pending-damage re-tick wait.
static monotonic_t
resync_present_floor(OSWindow *w, monotonic_t now) {
    return resync_refresh_period(w, now);
}

// KITTY_DISABLE_PACING_RESYNC: kill-switch for the Wave-14 stall-rescue, resolved
// ONCE into a cached bool (same pattern as pacing_debug_enabled). Precedence: set
// and not "0" -> rescue OFF = HEAD-identical 250 ms-defer behavior (fixed 250 ms
// stall bound, always defer, no inline render-through); unset or "0" -> rescue ON
// (default). Orthogonal to KITTY_ENABLE_HWM_CLEAR.
static bool
pacing_resync_disabled(void) {
    static int cached = -1;
    if (UNLIKELY(cached < 0)) {
        const char *v = getenv("KITTY_DISABLE_PACING_RESYNC");
        cached = (v && v[0] && v[0] != '0') ? 1 : 0;
    }
    return cached == 1;
}

// KITTY_PACING_DEBUG=1: Wave-14 Step-0 confirmation instrumentation for the
// immediate-encode governor gate below. Debug-only and Metal-only: the env var
// is resolved ONCE into a cached bool (zero cost when off -- a single
// predictable branch), nothing is allocated in the hot path, and all counter
// state lives on the render/main thread that owns the gate (no cross-thread
// access). One parseable "pacing:" line is emitted via log_error every
// PACING_DUMP_EVERY gate evaluations and again at teardown. Counters are
// cumulative for the life of the process, so a run's totals are the
// reason=teardown record (or the last reason=periodic line if the process is
// killed before teardown).
#define PACING_DUMP_EVERY 512u
typedef struct PacingDebugCounters {
    uint64_t ticks;               // render_os_window gate evaluations sampled
    uint64_t input_driven_ticks;  // ...of which were input-driven (pending input damage)
    uint64_t immediate_taken;     // immediate_encode == true  (low-latency fast path)
    uint64_t immediate_disq;      // immediate_encode == false (deferred to the pace link)
    uint64_t floor_blocked;       // disqualified ONLY by the immediate-encode floor: the
                                  // Phase-13B "fast parse lands damage inside the floor" chain
    uint64_t defer_not_requested; // defer branch: render_state NOT_REQUESTED -> request_frame_render
    uint64_t defer_fallback250;   // defer branch: REQUESTED + 250ms no_render_frame fallback -> request
    uint64_t defer_waiting;       // defer branch: REQUESTED and link fresh -> wait for the next link tick
    uint64_t stall_link_in_runloop; // of the stale defers: link still in the runloop (H1: starved-in-place)
    uint64_t stall_link_removed;    // of the stale defers: link removed from the runloop (H2: paused-desync)
    uint64_t gap_bucket[7];       // now-last_gpu_present_at at the gate, ms: <4,4-8,8-16,16-40,40-80,80-250,>=250
} PacingDebugCounters;
static PacingDebugCounters pacing_dbg;
static uint64_t pacing_dbg_since_dump, pacing_dbg_seq;

static bool
pacing_debug_enabled(void) {
    static int cached = -1;
    if (UNLIKELY(cached < 0)) {
        const char *v = getenv("KITTY_PACING_DEBUG");
        cached = (v && v[0] && v[0] != '0') ? 1 : 0;
    }
    return cached == 1;
}

// Coarse fixed buckets for now-last_gpu_present_at at the gate (indices map to
// the gap_* keys emitted by pacing_debug_dump).
static unsigned
pacing_gap_bucket(monotonic_t gap) {
    if (gap < ms_to_monotonic_t(4ll)) return 0;
    if (gap < ms_to_monotonic_t(8ll)) return 1;
    if (gap < ms_to_monotonic_t(16ll)) return 2;
    if (gap < ms_to_monotonic_t(40ll)) return 3;
    if (gap < ms_to_monotonic_t(80ll)) return 4;
    if (gap < ms_to_monotonic_t(250ll)) return 5;
    return 6;
}

static void
pacing_debug_dump(const char *reason) {
    const PacingDebugCounters *c = &pacing_dbg;
    log_error("pacing: reason=%s seq=%llu ticks=%llu input_driven=%llu imm_taken=%llu imm_disq=%llu"
              " floor_blocked=%llu defer_nreq=%llu defer_fallback250=%llu defer_waiting=%llu"
              " stall_in_runloop=%llu stall_removed=%llu"
              " gap_lt4=%llu gap_4_8=%llu gap_8_16=%llu gap_16_40=%llu gap_40_80=%llu gap_80_250=%llu gap_ge250=%llu"
              " stall_bound_eff_ms=%d",
              reason, (unsigned long long)(++pacing_dbg_seq),
              (unsigned long long)c->ticks, (unsigned long long)c->input_driven_ticks,
              (unsigned long long)c->immediate_taken, (unsigned long long)c->immediate_disq,
              (unsigned long long)c->floor_blocked,
              (unsigned long long)c->defer_not_requested, (unsigned long long)c->defer_fallback250,
              (unsigned long long)c->defer_waiting,
              (unsigned long long)c->stall_link_in_runloop, (unsigned long long)c->stall_link_removed,
              (unsigned long long)c->gap_bucket[0], (unsigned long long)c->gap_bucket[1],
              (unsigned long long)c->gap_bucket[2], (unsigned long long)c->gap_bucket[3],
              (unsigned long long)c->gap_bucket[4], (unsigned long long)c->gap_bucket[5],
              (unsigned long long)c->gap_bucket[6],
              monotonic_t_to_ms(pacing_stall_bound_eff));
}

// Sampled once per gate evaluation on the render/main thread, only when the
// cached debug bool is set. Reads w's gate inputs only; when nonfloor_ok holds
// the gate already resolved immediate_encode_floor() this tick, so the re-call
// hits the per-window cache without an extra refresh (no behavior change).
static void
pacing_debug_sample_gate(OSWindow *w, monotonic_t now, bool input_driven, bool immediate_encode) {
    const monotonic_t gap = now - w->last_gpu_present_at;
    pacing_dbg.ticks++;
    if (input_driven) pacing_dbg.input_driven_ticks++;
    pacing_dbg.gap_bucket[pacing_gap_bucket(gap)]++;
    if (immediate_encode) pacing_dbg.immediate_taken++;
    else {
        pacing_dbg.immediate_disq++;
        const bool nonfloor_ok = metal_immediate_encode_enabled()
            && input_driven && !w->keep_rendering_till_swap && USE_RENDER_FRAMES
            && w->render_state == RENDER_FRAME_NOT_REQUESTED && !w->live_resize.in_progress
            && global_state.thumbnail_callback.os_window != w->id;
        if (nonfloor_ok && gap < immediate_encode_floor(w, now)) pacing_dbg.floor_blocked++;
    }
    if (UNLIKELY(++pacing_dbg_since_dump >= PACING_DUMP_EVERY)) { pacing_dbg_since_dump = 0; pacing_debug_dump("periodic"); }
}
#endif

bool
render_os_window(OSWindow *w, monotonic_t now, bool scan_for_animated_images, bool input_driven) {
    // P9-0 test-only lever (like KITTY_METAL_TEST_FORCE_INFLIGHT): suppress
    // all per-window rendering (shape + cell-data upload + encode + present)
    // while parse/io/timers run identically, to measure how much flood wall
    // time main-thread render interleave costs. Never set outside harnesses.
    static int suppress_render = -1;
    if (UNLIKELY(suppress_render < 0)) {
        const char *v = getenv("KITTY_TEST_SUPPRESS_RENDER");
        suppress_render = (v && v[0] && v[0] != '0') ? 1 : 0;
    }
    if (UNLIKELY(suppress_render == 1)) return false;
    if (!w->num_tabs) return false;
    if (!should_os_window_be_rendered(w) && global_state.thumbnail_callback.os_window != w->id) {
        update_os_window_title(w);
        if (w->is_focused) change_menubar_title(w->window_title);
        return false;
    }
#ifdef __APPLE__
    const bool sp = child_monitor_signpost_enabled();
    os_log_t slog = sp ? child_monitor_signpost_log() : NULL;
    os_signpost_id_t render_gate_sid = sp ? os_signpost_id_make_with_pointer(slog, w) : OS_SIGNPOST_ID_INVALID;
#endif
    // L2 immediate-encode-on-input — the low-latency half of the IOSurface
    // flood governor. When damage is input-driven and the pace link is idle
    // (render_state NOT_REQUESTED) and at least the immediate-encode floor
    // (L6: ~0.5x the display refresh period; see immediate_encode_floor) has
    // passed since THIS window last presented, render the frame now instead of
    // deferring to the next link tick (which costs ~1 frame of latency). On the
    // IOSurface path the present is a layer.contents swap — no drawable pool
    // exists, so rendering at an arbitrary instant is safe (pace=immediate).
    // render_prepared_os_window's request_frame_render resyncs the link
    // afterward, so continuous output (flood) transitions to link pacing on
    // its next frame — that resync IS the governor's throughput half: flood
    // encodes at the refresh rate, not the parse rate. The floor is per-window
    // (one window's flood must not starve another's fast path) and stays
    // positive so it caps a key-repeat storm within a refresh.
#ifdef KITTY_BACKEND_METAL
    // Frame-trace: resolve the focused-window gate probe once for this window.
    const bool ft = UNLIKELY(frame_trace_enabled()) && w->is_focused;
#endif
    bool immediate_encode = false;
#ifdef KITTY_BACKEND_METAL
    bool echo_immediate = false;
    if (metal_immediate_encode_enabled()
        && input_driven && !w->keep_rendering_till_swap && USE_RENDER_FRAMES
        && !w->live_resize.in_progress
        && global_state.thumbnail_callback.os_window != w->id) {
        // Original eligibility: pace link idle. Lever (default OFF): a
        // keypress-echo frame may also encode inline from the REQUESTED
        // (gate=waiting) state — see metal_echo_immediate_enabled(). The
        // floor check stays last so the flood hot path (REQUESTED, no
        // recent key) still never reaches immediate_encode_floor().
        bool state_ok = w->render_state == RENDER_FRAME_NOT_REQUESTED;
        if (!state_ok && w->render_state == RENDER_FRAME_REQUESTED
            && metal_echo_immediate_enabled()
            && now - atomic_load_explicit(&last_local_key_input_at, memory_order_relaxed) <= L5_KEY_RECENCY_WINDOW) {
            state_ok = true;
            echo_immediate = true;
        }
        if (state_ok && now - w->last_gpu_present_at >= immediate_encode_floor(w, now)) immediate_encode = true;
        else echo_immediate = false;
    }
#else
    (void)input_driven;
#endif
#ifdef KITTY_BACKEND_METAL
    if (UNLIKELY(pacing_debug_enabled())) pacing_debug_sample_gate(w, now, input_driven, immediate_encode);
#endif
    if (immediate_encode) {
#ifdef KITTY_BACKEND_METAL
        if (ft) ft_gate_outcome = echo_immediate ? FT_GATE_ECHO_IMM : FT_GATE_IMMEDIATE;
#endif
#ifdef __APPLE__
        if (sp) os_signpost_event_emit(slog, render_gate_sid, "render_gate", "window=%llu state=%{public}s", w->id, "immediate");
#endif
    } else if (!w->keep_rendering_till_swap && USE_RENDER_FRAMES && w->render_state != RENDER_FRAME_READY) {
        // Preserve the original short-circuit exactly: no_render_frame_received_recently
        // is evaluated iff render_state != NOT_REQUESTED, and request_frame_render is
        // called iff either sub-condition holds. The two locals also let the pacing
        // debug counters classify which sub-branch fired (see KITTY_PACING_DEBUG).
        const bool nreq = w->render_state == RENDER_FRAME_NOT_REQUESTED;
        bool stall_rescue = false;
#ifdef KITTY_BACKEND_METAL
        // Wave-14 stall-rescue (ADR 2026-07-07): under sustained scroll a
        // RENDER_FRAME_REQUESTED frame whose pace link is starved (H1) ages past
        // the staleness bound; HEAD then waits the full 250 ms fallback while the
        // link sits in the runloop undelivered. Instead: shorten the bound to ~3x
        // refresh AND render the pending damage inline THIS tick -- symmetric to
        // the immediate-encode fast path, which also falls through to the render
        // path below (stamping last_gpu_present_at and re-arming the link at :977).
        // Refresh-capped by resync_present_floor so a fully starved link cannot
        // drive flood above the refresh rate (preserves 13A L6). The kill-switch
        // KITTY_DISABLE_PACING_RESYNC restores HEAD's fixed-250 ms defer behavior.
        const bool resync_off = pacing_resync_disabled();
        const monotonic_t stall_bound = resync_off ? ms_to_monotonic_t(250ll) : resync_stall_bound(w, now);
        const bool stale = !nreq && no_render_frame_received_recently(w, now, stall_bound);
        stall_rescue = !resync_off && stale && now - w->last_gpu_present_at >= resync_present_floor(w, now);
        if (nreq || stale) request_frame_render(w);
        if (UNLIKELY(pacing_debug_enabled())) {
            if (nreq) pacing_dbg.defer_not_requested++;
            else if (stale) {
                pacing_dbg.defer_fallback250++;
                // Confirm counter (ADR §5): at a stall, is the link still a runloop
                // member (H1: starved-in-place) or removed (H2: paused-desync)?
                if (glfwCocoaIsRenderLinkInRunloop(w->handle)) pacing_dbg.stall_link_in_runloop++;
                else pacing_dbg.stall_link_removed++;
            }
            else pacing_dbg.defer_waiting++;
        }
        // Frame-trace: classify the focused window's deferred-gate branch. Order
        // matters -- stall_rescue implies stale, so it is tested first (pacing's
        // defer_fallback250 lumps rescue in with capped fallbacks; here they split).
        if (ft) {
            if (stall_rescue) ft_gate_outcome = FT_GATE_RESCUE;
            else if (nreq) ft_gate_outcome = FT_GATE_NREQ;
            else if (stale) ft_gate_outcome = FT_GATE_FALLBACK;
            else ft_gate_outcome = FT_GATE_WAITING;
        }
#else
        const bool stale = !nreq && no_render_frame_received_recently(w, now, ms_to_monotonic_t(250ll));
        if (nreq || stale) request_frame_render(w);
#endif
        if (!stall_rescue && w->id != global_state.thumbnail_callback.os_window) {
            // dont respect render frames soon after a resize on Wayland as they cause flicker because
            // we want to fill the newly resized buffer ASAP, not at compositors convenience
            if (!global_state.is_wayland || (monotonic() - w->viewport_resized_at) > s_double_to_monotonic_t(1)) {
#ifdef __APPLE__
                if (sp) os_signpost_event_emit(slog, render_gate_sid, "render_gate", "window=%llu state=%{public}s", w->id, "deferred");
#endif
#ifdef KITTY_BACKEND_METAL
                // Deferred with pending damage but the refresh-cap gated the inline
                // rescue off this tick: re-tick within one refresh so the damage
                // renders promptly instead of waiting for the next input wakeup.
                // set_maximum_wait is min-semantics -- only tightens a longer wait.
                // Gated by !resync_off so the kill-switch path stays HEAD-identical
                // (HEAD never sets a wait here; pre-mortem #7).
                if (!resync_off && (nreq || stale)) set_maximum_wait(resync_present_floor(w, now));
#endif
                return false;
            }
        }
        // stall_rescue (Metal) falls through here to the render path, exactly as
        // immediate_encode does, rendering the pending damage inline this tick.
#ifdef __APPLE__
        if (sp) os_signpost_event_emit(slog, render_gate_sid, "render_gate", "window=%llu state=%{public}s", w->id, "REQUESTED");
#endif
    }
#ifdef __APPLE__
    else if (sp) os_signpost_event_emit(slog, render_gate_sid, "render_gate", "window=%llu state=%{public}s", w->id, "READY");
#endif
#ifdef KITTY_BACKEND_METAL
    // Neither immediate nor the deferred branch classified this tick: the gate
    // fell through on render_state READY / keep_rendering_till_swap.
    if (ft && ft_gate_outcome == FT_GATE_NONE) ft_gate_outcome = FT_GATE_READY;
#endif
    w->render_calls++;
    make_os_window_context_current(w);
    bool needs_render = w->redraw_count > 0 || w->live_resize.in_progress || global_state.thumbnail_callback.os_window == w->id;
    if (w->viewport_size_dirty) {
        set_gpu_viewport(w->viewport_width, w->viewport_height);
        w->viewport_size_dirty = false;
        needs_render = true;
    }
    unsigned int active_window_id = 0, num_visible_windows = 0;
    bool all_windows_have_same_bg;
    color_type active_window_bg = 0;
    if (!w->fonts_data) { log_error("No fonts data found for window id: %llu", w->id); return false; }
    if (prepare_to_render_os_window(w, now, &active_window_id, &active_window_bg, &num_visible_windows, &all_windows_have_same_bg, scan_for_animated_images)) needs_render = true;
    if (w->last_active_window_id != active_window_id || w->last_active_tab != w->active_tab || w->focused_at_last_render != w->is_focused) needs_render = true;
    if (w->render_calls < 3 && background_image_for_os_window(w) != NULL) needs_render = true;
    if (needs_render) {
        render_prepared_os_window(w, active_window_id, active_window_bg, num_visible_windows, all_windows_have_same_bg);
#ifdef KITTY_BACKEND_METAL
        if (ft) ft_present_committed = true;  // swap_window_buffers presented this tick
#endif
    }
    if (w->is_focused) change_menubar_title(w->window_title);
    return needs_render;
}

static void
render(monotonic_t now, bool input_read) {
    EVDBG("input_read: %d, check_for_active_animated_images: %d\n", input_read, global_state.check_for_active_animated_images);
#ifdef __APPLE__
    const bool sp = child_monitor_signpost_enabled();
    os_log_t slog = sp ? child_monitor_signpost_log() : NULL;
    if (sp) os_signpost_interval_begin(slog, OS_SIGNPOST_ID_EXCLUSIVE, "render", "");
#endif
    static monotonic_t last_render_at = MONOTONIC_T_MIN;
    monotonic_t time_since_last_render = last_render_at == MONOTONIC_T_MIN ? OPT(repaint_delay) : now - last_render_at;
    if (!input_read && time_since_last_render < OPT(repaint_delay) && !global_state.thumbnail_callback.os_window) {
        set_maximum_wait(OPT(repaint_delay) - time_since_last_render);
#ifdef __APPLE__
        if (sp) os_signpost_interval_end(slog, OS_SIGNPOST_ID_EXCLUSIVE, "render", "");
#endif
        return;
    }

    const bool scan_for_animated_images = global_state.check_for_active_animated_images;
    global_state.check_for_active_animated_images = false;
    call_boss(cache_process_data, "O", Py_True);

    for (size_t i = 0; i < global_state.num_os_windows; i++) {
        OSWindow *w = global_state.os_windows + i;
#ifdef __APPLE__
        // rendering is done in cocoa_os_window_resized()
        if (w->live_resize.in_progress) {
#ifdef KITTY_BACKEND_METAL
            // Backstop for a stuck live-resize. macOS can latch viewWillStartLiveResize
            // (e.g. spuriously when a window becomes key) without ever sending
            // viewDidEndLiveResize, and the resize debounce (process_pending_resizes)
            // does not run while the window is idle — so live_resize.in_progress stays
            // true, this loop skips the window forever, and its paused
            // CAMetalDisplayLink never resumes: the Wave-4 once-then-freeze. If no real
            // resize event has arrived recently, end the resize now —
            // change_live_resize_state() recreates the link and marks the window
            // REQUESTED so rendering resumes. A genuine drag keeps last_resize_event_at
            // fresh and is still skipped (rendered via cocoa_os_window_resized).
            static int recovery_disabled = -1;
            if (recovery_disabled < 0) { const char *v = getenv("KITTY_METAL_NO_RESIZE_RECOVERY"); recovery_disabled = (v && v[0] && v[0] != '0') ? 1 : 0; }
            // Recover only when the resize is stale (no real event for 150ms) AND
            // glfwCocoaResetLiveResizeGuards accepts — it DECLINES (returns false,
            // leaving the guards intact) while the left mouse button is down, i.e. a
            // genuine drag the user is holding still. On decline we skip and re-check
            // next pass. On accept it has unlatched the GLFW-side live-resize flag and
            // presentsWithTransaction, so change_live_resize_state(false) creates a
            // fresh link (viewWillStartLiveResize DESTROYED the old one) and marks
            // REQUESTED, and the window renders again.
            if (!recovery_disabled && now - w->live_resize.last_resize_event_at > ms_to_monotonic_t(150ll)
                && glfwCocoaResetLiveResizeGuards(w->handle)) {
                change_live_resize_state(w, false);
            } else continue;
#else
            continue;
#endif
        }
#endif
        if (!render_os_window(w, now, scan_for_animated_images, input_read)) {
            // since we didn't scan the window for animations, force a rescan on next wakeup/render frame
            if (scan_for_animated_images) global_state.check_for_active_animated_images = true;
        }
        if (w->keep_rendering_till_swap) {
            debug_rendering("Re-rendering window %llu on the %u attempt since swap did not happen\n", w->id, w->keep_rendering_till_swap);
            set_maximum_wait(OPT(repaint_delay));
            w->needs_render = true;
            w->keep_rendering_till_swap--;
        }

    }
    last_render_at = now;
    call_boss(cache_process_data, "O", Py_False);
#ifdef __APPLE__
    if (sp) os_signpost_interval_end(slog, OS_SIGNPOST_ID_EXCLUSIVE, "render", "");
#endif
#undef TD
}


typedef struct { int fd; uint8_t *buf; size_t sz; } ThreadWriteData;

static ThreadWriteData*
alloc_twd(size_t sz) {
    ThreadWriteData *data = calloc(1, sizeof(ThreadWriteData));
    if (data != NULL) {
        data->sz = sz;
        data->buf = malloc(sz);
        if (data->buf == NULL) { free(data); data = NULL; }
    }
    return data;
}

static void
free_twd(ThreadWriteData *x) {
    if (x != NULL) free(x->buf);
    free(x);
}

static PyObject*
sig_queue(PyObject *self UNUSED, PyObject *args) {
    int pid, signal, value;
    if (!PyArg_ParseTuple(args, "iii", &pid, &signal, &value)) return NULL;
#ifdef NO_SIGQUEUE
    if (kill(pid, signal) != 0) { PyErr_SetFromErrno(PyExc_OSError); return NULL; }
#else
    union sigval v;
    v.sival_int = value;
    if (sigqueue(pid, signal, v) != 0) { PyErr_SetFromErrno(PyExc_OSError); return NULL; }
#endif
    Py_RETURN_NONE;
}

static PyObject*
monitor_pid(PyObject *self UNUSED, PyObject *args) {
    int pid;
    bool ok = true;
    if (!PyArg_ParseTuple(args, "i", &pid)) return NULL;
    children_mutex(lock);
    if (monitored_pids_count >= arraysz(monitored_pids)) {
        PyErr_SetString(PyExc_RuntimeError, "Too many monitored pids");
        ok = false;
    } else {
        monitored_pids[monitored_pids_count++] = pid;
    }
    children_mutex(unlock);
    if (!ok) return NULL;
    Py_RETURN_NONE;
}

static void
report_reaped_pids(void) {
    static ReapedPID pids[64];
    size_t i = 0;
    children_mutex(lock);
    if (reaped_pids_count) {
        for (; i < reaped_pids_count && i < arraysz(pids); i++) {
            pids[i] = reaped_pids[i];
        }
        reaped_pids_count = 0;
    }
    children_mutex(unlock);
    for (size_t n = 0; n < i; n++) { call_boss(on_monitored_pid_death, "li", (long)pids[n].pid, pids[n].status); }
}

static void*
thread_write(void *x) {
    ThreadWriteData *data = (ThreadWriteData*)x;
    set_thread_name("KittyWriteStdin");
    int flags = fcntl(data->fd, F_GETFL, 0);
    if (flags == -1) { free_twd(data); return 0; }
    flags &= ~O_NONBLOCK;
    fcntl(data->fd, F_SETFL, flags);
    size_t pos = 0;
    while (pos < data->sz) {
        errno = 0;
        ssize_t nbytes = write(data->fd, data->buf + pos, data->sz - pos);
        if (nbytes < 0) {
            if (errno == EAGAIN || errno == EINTR) continue;
            break;
        }
        if (nbytes == 0) break;
        pos += nbytes;
    }
    if (pos < data->sz) {
        log_error("Failed to write all data to STDIN of child process with error: %s", strerror(errno));
    }
    safe_close(data->fd, __FILE__, __LINE__);
    free_twd(data);
    return 0;
}

PyObject*
cm_thread_write(PyObject UNUSED *self, PyObject *args) {
    static pthread_t thread;
    int fd;
    Py_ssize_t sz;
    const char *buf;
    if (!PyArg_ParseTuple(args, "is#", &fd, &buf, &sz)) return NULL;
    ThreadWriteData *data = alloc_twd(sz);
    if (data == NULL) return PyErr_NoMemory();
    data->fd = fd;
    memcpy(data->buf, buf, data->sz);
    int ret = pthread_create(&thread, NULL, thread_write, data);
    if (ret != 0) { safe_close(fd, __FILE__, __LINE__); free_twd(data); return PyErr_Format(PyExc_OSError, "Failed to start write thread with error: %s", strerror(ret)); }
    pthread_detach(thread);
    Py_RETURN_NONE;
}

static void
python_timer_callback(id_type timer_id, void *data) {
    PyObject *callback = (PyObject*)data;
    unsigned long long id = timer_id;
    PyObject *ret = PyObject_CallFunction(callback, "K", id);
    if (ret == NULL) PyErr_Print();
    else Py_DECREF(ret);
}

static void
python_timer_cleanup(id_type timer_id UNUSED, void *data) {
    if (data) Py_DECREF((PyObject*)data);
}

static PyObject*
add_python_timer(PyObject *self UNUSED, PyObject *args) {
    PyObject *callback;
    double interval;
    int repeats = 1;
    if (!PyArg_ParseTuple(args, "Od|p", &callback, &interval, &repeats)) return NULL;
    unsigned long long timer_id = add_main_loop_timer(s_double_to_monotonic_t(interval), repeats ? true: false, python_timer_callback, callback, python_timer_cleanup);
    Py_INCREF(callback);
    return Py_BuildValue("K", timer_id);
}

static PyObject*
remove_python_timer(PyObject *self UNUSED, PyObject *args) {
    unsigned long long timer_id;
    if (!PyArg_ParseTuple(args, "K", &timer_id)) return NULL;
    remove_main_loop_timer(timer_id);
    Py_RETURN_NONE;
}


static void
process_pending_resizes(monotonic_t now) {
    global_state.has_pending_resizes = false;
    for (size_t i = 0; i < global_state.num_os_windows; i++) {
        OSWindow *w = global_state.os_windows + i;
        if (w->live_resize.in_progress) {
            bool update_viewport = false;
            if (w->live_resize.from_os_notification) {
                if (w->live_resize.os_says_resize_complete) update_viewport = true;
                else {
                    // prevent a "hang" if the OS never sends a resize complete event
                    // also reflow the screen when the user pauses resizing so the user can see what the resized
                    // screen will look like.
                    if ((now - w->live_resize.last_resize_event_at) > OPT(resize_debounce_time).on_pause) update_viewport = true;
                    else {
                        global_state.has_pending_resizes = true;
                        set_maximum_wait(s_double_to_monotonic_t(0.05));
                    }
                }
            } else {
                monotonic_t debounce_time = OPT(resize_debounce_time).on_end;
                // if more than one resize event has occurred, wait at least 0.2 secs
                // before repainting, to avoid rapid transitions between the cells banner
                // and the normal screen
                if (now - w->live_resize.last_resize_event_at >= debounce_time) update_viewport = true;
                else {
                    global_state.has_pending_resizes = true;
                    set_maximum_wait(debounce_time - now + w->live_resize.last_resize_event_at);
                }
            }
            if (update_viewport) {
                update_os_window_viewport(w, true);
                change_live_resize_state(w, false);
                zero_at_ptr(&w->live_resize);
                // because the window size should be hidden even if update_os_window_viewport does nothing
                // On Wayland some compositors require two redraws after a
                // resize to actually render correctly (Run kitty -1 --wait-for-os-window-close in sway to reproduce)
                w->redraw_count = global_state.is_wayland ? 2 : 1;
            }
        }
    }
}

static void
close_os_window(ChildMonitor *self, OSWindow *os_window) {
    int w = os_window->window_width, h = os_window->window_height;
    if (os_window->before_fullscreen.is_set && is_os_window_fullscreen(os_window)) {
        w = os_window->before_fullscreen.w; h = os_window->before_fullscreen.h;
    }
    int x = 0, y = 0;
    if (os_window->handle && !global_state.is_wayland) glfwGetWindowPos(os_window->handle, &x, &y);
    bool is_layer_shell = os_window->is_layer_shell;
    destroy_os_window(os_window);
    call_boss(on_os_window_closed, "KiiiiO", os_window->id, x, y, w, h, is_layer_shell ? Py_True : Py_False);
    for (size_t t=0; t < os_window->num_tabs; t++) {
        Tab *tab = os_window->tabs + t;
        for (size_t w = 0; w < tab->num_windows; w++) mark_child_for_close(self, tab->windows[w].id);
    }
    remove_os_window(os_window->id);
}

static bool
process_pending_closes(ChildMonitor *self) {
    if (global_state.quit_request == CONFIRMABLE_CLOSE_REQUESTED) {
        call_boss(quit, "");
    }
    if (global_state.quit_request == IMPERATIVE_CLOSE_REQUESTED) {
        for (size_t w = 0; w < global_state.num_os_windows; w++) global_state.os_windows[w].close_request = IMPERATIVE_CLOSE_REQUESTED;
    }
    bool has_open_windows = false;
    for (size_t w = global_state.num_os_windows; w > 0; w--) {
        OSWindow *os_window = global_state.os_windows + w - 1;
        switch(os_window->close_request) {
            case NO_CLOSE_REQUESTED:
                has_open_windows = true;
                break;
            case CONFIRMABLE_CLOSE_REQUESTED:
                os_window->close_request = CLOSE_BEING_CONFIRMED;
                call_boss(confirm_os_window_close, "K", os_window->id);
                if (os_window->close_request == IMPERATIVE_CLOSE_REQUESTED) {
                    close_os_window(self, os_window);
                } else has_open_windows = true;
                break;
            case CLOSE_BEING_CONFIRMED:
                has_open_windows = true;
                break;
            case IMPERATIVE_CLOSE_REQUESTED:
                close_os_window(self, os_window);
                break;
        }
    }
    global_state.has_pending_closes = false;
#ifdef __APPLE__
    if (!OPT(macos_quit_when_last_window_closed)) {
        if (!has_open_windows && global_state.quit_request != IMPERATIVE_CLOSE_REQUESTED) has_open_windows = true;
    }
#endif
    return !has_open_windows;
}

#ifdef __APPLE__
// If we create new OS windows during wait_events(), using global menu actions
// via the mouse causes a crash because of the way autorelease pools work in
// glfw/cocoa. So we use a flag instead.
static bool cocoa_pending_actions[NUM_COCOA_PENDING_ACTIONS] = {0};
static bool has_cocoa_pending_actions = false;
typedef struct cocoa_list { char **items; size_t count, capacity; } cocoa_list;
typedef struct {
    char* wd;
    cocoa_list open_urls, untracked_notifications;
} CocoaPendingActionsData;
static CocoaPendingActionsData cocoa_pending_actions_data = {0};

static void
cocoa_append_to_pending_list(cocoa_list *array, const char* item) {
    ensure_space_for(array, items, char*, array->count + 1, capacity, 8, false);
    array->items[array->count++] = strdup(item);
}

static void
cocoa_free_pending_list(cocoa_list *array) {
    for (size_t i = 0; i < array->count; i++) free(array->items[i]);
    free(array->items); zero_at_ptr(array);
}

static void
cocoa_free_actions_data(void) {
    if (cocoa_pending_actions_data.wd) { free(cocoa_pending_actions_data.wd); cocoa_pending_actions_data.wd = NULL; }
    cocoa_free_pending_list(&cocoa_pending_actions_data.open_urls);
    cocoa_free_pending_list(&cocoa_pending_actions_data.untracked_notifications);
}

void
set_cocoa_pending_action(CocoaPendingAction action, const char *data) {
    if (data) {
        switch(action) {
            case LAUNCH_URLS:
                cocoa_append_to_pending_list(&cocoa_pending_actions_data.open_urls, data); break;
            case COCOA_NOTIFICATION_UNTRACKED:
                cocoa_append_to_pending_list(&cocoa_pending_actions_data.untracked_notifications, data); break;
            default:
                if (cocoa_pending_actions_data.wd) free(cocoa_pending_actions_data.wd);
                cocoa_pending_actions_data.wd = strdup(data);
                break;
        }
    }
    cocoa_pending_actions[action] = true;
    has_cocoa_pending_actions = true;
    // The main loop may be blocking on the event queue, if e.g. unfocused.
    // Unjam it so the pending action is processed right now.
    wakeup_main_loop();
}

static void
process_cocoa_pending_actions(void) {
    if (cocoa_pending_actions[PREFERENCES_WINDOW]) { call_boss(edit_config_file, NULL); }
    if (cocoa_pending_actions[NEW_OS_WINDOW]) { call_boss(new_os_window, NULL); }
    if (cocoa_pending_actions[CLOSE_OS_WINDOW]) { call_boss(close_os_window, NULL); }
    if (cocoa_pending_actions[CLOSE_TAB]) { call_boss(close_tab, NULL); }
    if (cocoa_pending_actions[NEW_TAB]) { call_boss(new_tab, NULL); }
    if (cocoa_pending_actions[NEXT_TAB]) { call_boss(next_tab, NULL); }
    if (cocoa_pending_actions[PREVIOUS_TAB]) { call_boss(previous_tab, NULL); }
    if (cocoa_pending_actions[DETACH_TAB]) { call_boss(detach_tab, NULL); }
    if (cocoa_pending_actions[NEW_WINDOW]) { call_boss(new_window, NULL); }
    if (cocoa_pending_actions[CLOSE_WINDOW]) { call_boss(close_window, NULL); }
    if (cocoa_pending_actions[RESET_TERMINAL]) { call_boss(clear_terminal, "sO", "reset", Py_True ); }
    if (cocoa_pending_actions[CLEAR_TERMINAL_AND_SCROLLBACK]) { call_boss(clear_terminal, "sO", "to_cursor", Py_True ); }
    if (cocoa_pending_actions[CLEAR_SCROLLBACK]) { call_boss(clear_terminal, "sO", "scrollback", Py_True ); }
    if (cocoa_pending_actions[CLEAR_SCREEN]) { call_boss(clear_terminal, "sO", "to_cursor_scroll", Py_True ); }
    if (cocoa_pending_actions[CLEAR_LAST_COMMAND]) { call_boss(clear_terminal, "sO", "last_command", Py_True ); }
    if (cocoa_pending_actions[RELOAD_CONFIG]) { call_boss(load_config_file, NULL); }
    if (cocoa_pending_actions[TOGGLE_MACOS_SECURE_KEYBOARD_ENTRY]) { call_boss(toggle_macos_secure_keyboard_entry, NULL); }
    if (cocoa_pending_actions[MACOS_CYCLE_THROUGH_OS_WINDOWS]) { call_boss(macos_cycle_through_os_windows, NULL); }
    if (cocoa_pending_actions[MACOS_CYCLE_THROUGH_OS_WINDOWS_BACKWARDS]) { call_boss(macos_cycle_through_os_windows_backwards, NULL); }
    if (cocoa_pending_actions[SEARCH_SCROLLBACK]) { call_boss(search_scrollback_in_active, NULL); }
    if (cocoa_pending_actions[TOGGLE_FULLSCREEN]) { call_boss(toggle_fullscreen, NULL); }
    if (cocoa_pending_actions[OPEN_KITTY_WEBSITE]) { call_boss(open_kitty_website, NULL); }
    if (cocoa_pending_actions[HIDE]) { call_boss(hide_macos_app, NULL); }
    if (cocoa_pending_actions[HIDE_OTHERS]) { call_boss(hide_macos_other_apps, NULL); }
    if (cocoa_pending_actions[MINIMIZE]) { call_boss(minimize_macos_window, NULL); }
    if (cocoa_pending_actions[QUIT]) { call_boss(quit, NULL); }
    if (cocoa_pending_actions[PASTE_FROM_CLIPBOARD]) { call_boss(paste_from_clipboard, NULL); }
    if (cocoa_pending_actions[COPY_OR_NOOP]) { call_boss(copy_or_noop, NULL); }
    if (cocoa_pending_actions_data.wd) {
        if (cocoa_pending_actions[NEW_OS_WINDOW_WITH_WD]) { call_boss(new_os_window_with_wd, "sO", cocoa_pending_actions_data.wd, Py_True); }
        if (cocoa_pending_actions[NEW_TAB_WITH_WD]) { call_boss(new_tab_with_wd, "sO", cocoa_pending_actions_data.wd, Py_True); }
        if (cocoa_pending_actions[USER_MENU_ACTION]) { call_boss(user_menu_action, "s", cocoa_pending_actions_data.wd); }
        free(cocoa_pending_actions_data.wd);
        cocoa_pending_actions_data.wd = NULL;
    }
    for (unsigned cpa = 0; cpa < cocoa_pending_actions_data.open_urls.count; cpa++) {
        if (cocoa_pending_actions_data.open_urls.items[cpa]) {
            call_boss(launch_urls, "s", cocoa_pending_actions_data.open_urls.items[cpa]);
            free(cocoa_pending_actions_data.open_urls.items[cpa]);
            cocoa_pending_actions_data.open_urls.items[cpa] = NULL;
        }
    }
    cocoa_pending_actions_data.open_urls.count = 0;

    for (unsigned cpa = 0; cpa < cocoa_pending_actions_data.untracked_notifications.count; cpa++) {
        if (cocoa_pending_actions_data.untracked_notifications.items[cpa]) {
            cocoa_report_live_notifications(cocoa_pending_actions_data.untracked_notifications.items[cpa]);
            free(cocoa_pending_actions_data.untracked_notifications.items[cpa]);
            cocoa_pending_actions_data.untracked_notifications.items[cpa] = NULL;
        }
    }
    cocoa_pending_actions_data.untracked_notifications.count = 0;


    memset(cocoa_pending_actions, 0, sizeof(cocoa_pending_actions));
    has_cocoa_pending_actions = false;

}
#endif

static void process_global_state(void *data);

static void
do_state_check(id_type timer_id UNUSED, void *data) {
    EVDBG("State check timer fired");
    process_global_state(data);
}

static id_type state_check_timer = 0;

static void
process_global_state(void *data) {
    EVDBG("Processing global state");
    ChildMonitor *self = data;
    maximum_wait = -1;
    bool state_check_timer_enabled = false;
    bool input_read = false;

    monotonic_t now = monotonic();
    if (global_state.has_pending_resizes) {
        process_pending_resizes(now);
        input_read = true;
    }
#ifdef KITTY_BACKEND_METAL
    // Frame-trace: reset this tick's per-tick accumulators before parse/render.
    const bool ft_on = UNLIKELY(frame_trace_enabled());
    if (ft_on) {
        ft_bytes_drained = 0; ft_gate_outcome = FT_GATE_NONE; ft_present_committed = false;
        ft_parsed_bytes = 0; ft_pause_starts = 0; ft_pause_stops = 0; ft_paused_at_end = false;
        ft_cow_copied = 0; ft_cow_skip_eligible = 0;  // Wave-21 L4
        ft_share_rows_total = 0; ft_share_rows_ref = 0; ft_share_cow_retires = 0;  // Wave-25 Lane S
        ft_oob_drained = 0;  // R3
    }
#endif
#ifdef __APPLE__
    const bool sp = child_monitor_signpost_enabled();
    os_log_t slog = sp ? child_monitor_signpost_log() : NULL;
    if (sp) os_signpost_interval_begin(slog, OS_SIGNPOST_ID_EXCLUSIVE, "parse", "");
#endif
#ifdef KITTY_BACKEND_METAL
    const monotonic_t ft_parse_t0 = ft_on ? monotonic() : 0;
#endif
    if (parse_input(self)) input_read = true;
#ifdef KITTY_BACKEND_METAL
    const monotonic_t ft_parse_t1 = ft_on ? monotonic() : 0;
#endif
#ifdef __APPLE__
    if (sp) os_signpost_interval_end(slog, OS_SIGNPOST_ID_EXCLUSIVE, "parse", "");
#endif
    render(now, input_read);
#ifdef KITTY_BACKEND_METAL
    // One ftrace line per tick, after render so the gate outcome + present are set.
    if (ft_on) {
        const monotonic_t ft_render_t1 = monotonic();
        frame_trace_emit(now, input_read, ft_parse_t1 - ft_parse_t0, ft_render_t1 - ft_parse_t1);
        // Wave-20 T1.1: emit one ktrace line per completed keypress-echo
        // journey — this tick both parsed the echo (S3 stamped) and
        // classified the render gate (S4 = this tick's ts). S5 (present)
        // pairs offline against the metal_present line; present= records
        // whether THIS tick already committed a swap.
        // One-time clock anchor: kitty's monotonic() is PROCESS-relative
        // (monotonic_() - monotonic_start_time, monotonic.h) while the
        // harness's injection stamps and metal_present's presented_time are
        // mach_absolute_time-derived since boot (CACurrentMediaTime
        // equivalent). Emitting both clocks in one instant lets the analyzer
        // shift every ktrace stamp into the mach timebase.
        if (UNLIKELY(!kt_epoch_emitted)) {
            kt_epoch_emitted = true;
            mach_timebase_info_data_t kt_tb; mach_timebase_info(&kt_tb);
            const double kt_mach_ms = (double)mach_absolute_time() * kt_tb.numer / kt_tb.denom / 1e6;
            log_error("ktrace_epoch: mono_ms=%.3f mach_ms=%.3f", ft_ms(monotonic()), kt_mach_ms);
        }
        const monotonic_t kt_key = atomic_load_explicit(&last_local_key_input_at, memory_order_relaxed);
        const monotonic_t kt_echo = atomic_load_explicit(&kt_echo_read_at, memory_order_relaxed);
        if (kt_key > kt_emitted_key_at && kt_echo >= kt_key && kt_parse_at >= kt_echo) {
            log_error("ktrace: seq=%llu key_ms=%.3f echo_ms=%.3f echo_bytes=%llu parse_ms=%.3f gate_ms=%.3f gate=%s present=%d l5_miss=%d",
                      (unsigned long long)(++kt_seq), ft_ms(kt_key), ft_ms(kt_echo),
                      (unsigned long long)atomic_load_explicit(&kt_echo_bytes, memory_order_relaxed),
                      ft_ms(kt_parse_at), ft_ms(now),
                      ft_gate_names[ft_gate_outcome], ft_present_committed ? 1 : 0,
                      atomic_load_explicit(&kt_l5_miss, memory_order_relaxed) ? 1 : 0);
            kt_emitted_key_at = kt_key;
        }
    }
#endif
#ifdef __APPLE__
    if (has_cocoa_pending_actions) {
        process_cocoa_pending_actions();
        maximum_wait = 0;  // ensure loop ticks again so that the actions side effects are performed immediately
    }
#endif
    report_reaped_pids();
    bool should_quit = false;
    if (global_state.has_pending_closes) should_quit = process_pending_closes(self);
    if (should_quit) {
        stop_main_loop();
    } else {
        if (maximum_wait >= 0) {
            if (maximum_wait == 0) request_tick_callback();
            else state_check_timer_enabled = true;
        }
    }
    update_main_loop_timer(state_check_timer, MAX(0, maximum_wait), state_check_timer_enabled);
}

static PyObject*
main_loop(ChildMonitor *self, PyObject *a UNUSED) {
#define main_loop_doc "The main thread loop"
    state_check_timer = add_main_loop_timer(1000, true, do_state_check, self, NULL);
    run_main_loop(process_global_state, self);
#ifdef KITTY_BACKEND_METAL
    if (pacing_debug_enabled()) pacing_debug_dump("teardown");
#endif
#ifdef __APPLE__
    cocoa_free_actions_data();
#endif
    if (PyErr_Occurred()) return NULL;
    Py_RETURN_NONE;
}

// }}}

// I/O thread functions {{{

#ifdef KITTY_BACKEND_METAL
// Wave-22 reader-thread machinery (KITTY_READER_THREADS, default-OFF).
// Implements L-READER-DESIGN.md rev.2 §D2.5's pinned loop shape with the
// O1-O15 obligations; memory orders per .omc/verify/wave22/
// R22-B2-RESTATEMENT.md. The OFF arm never reaches any of this.

// Condition 6: fd budget. A reader costs its own kqueue beside the child's
// already-open master (2 fds/child at MAX_CHILDREN=512 vs the macOS 256
// soft default kitty never raises). ON arm only; failure fails toward OFF
// (children beyond the budget keep the legacy io-thread read path).
static unsigned reader_fd_budget_children;  // how many readers may exist at once
static unsigned live_readers;               // io thread only, under children_mutex
static bool reader_budget_warned;

static void
raise_nofile_limit_for_readers(void) {
    struct rlimit rl;
    if (getrlimit(RLIMIT_NOFILE, &rl) != 0) {
        log_error("Wave-22 readers: getrlimit(RLIMIT_NOFILE) failed: %s", strerror(errno));
        return;
    }
    rlim_t target = (rlim_t)MAX_CHILDREN * 2 + 1024;
    if (target > rl.rlim_max) target = rl.rlim_max;
#ifdef OPEN_MAX
    // macOS rejects rlim_cur > OPEN_MAX (pinned quirk): clamp the request.
    if (target > OPEN_MAX) target = OPEN_MAX;
#endif
    if (rl.rlim_cur < target) {
        struct rlimit want = {.rlim_cur = target, .rlim_max = rl.rlim_max};
        if (setrlimit(RLIMIT_NOFILE, &want) == 0) rl.rlim_cur = target;
        else log_error("Wave-22 readers: setrlimit(RLIMIT_NOFILE, %llu) failed: %s;"
                       " readers limited to the current budget", (unsigned long long)target, strerror(errno));
    }
    // Keep half the remaining headroom (after a 256-fd reserve for the rest
    // of the process) for the 2-fds/child budget.
    reader_fd_budget_children = rl.rlim_cur > 256 ? (unsigned)((rl.rlim_cur - 256) / 2) : 0;
    if (reader_fd_budget_children > MAX_CHILDREN) reader_fd_budget_children = MAX_CHILDREN;
}

// Counter-slot recycling: cumulative counters are never reset (the ftrace
// consumer diffs consecutive line sums), so a recycled slot just keeps
// accumulating — the sum stays monotone. All under children_mutex.
static unsigned reader_slot_free[MAX_CHILDREN];
static size_t reader_slot_free_count;

// O7 deferral: children whose reader must be joined before their fds close
// and before their death is published to remove_queue. io-thread private.
static struct { Child child; ReaderThread *rt; } reader_teardown_pending[MAX_CHILDREN];
static size_t reader_teardown_pending_count;

static void
reader_trigger_wake(ReaderThread *rt) {
    struct kevent kev;
    EV_SET(&kev, READER_WAKE_IDENT, EVFILT_USER, 0, NOTE_TRIGGER, 0, NULL);
    if (kevent(rt->kq, &kev, 1, NULL, 0, NULL) < 0)
        log_error("Wave-22 reader %lu: NOTE_TRIGGER failed: %s", rt->child_id, strerror(errno));
}

// O15 (Critic condition 1, conforming shape): children_mutex-held
// load+trigger. Teardown retires the handle under the same mutex BEFORE the
// join and the close, so no trigger here can ever land on a closed or
// recycled kqueue. A child ABSENT from children[] is a retired one — its
// reader is exiting and teardown wakes it via its own ordered trigger, so
// dropping that unpark is benign. A PRESENT child with reader == NULL is a
// fallback child (reader_spawn failed, condition 6 fail-toward-OFF): the io
// thread is ITS parked ring producer, and vt_ring_unpark_writer already
// consumed writer_parked before this call — dropping the wake would stall
// that child's input permanently (M3.5 review F1). Route it to the io loop
// exactly as the OFF arm does; within children[] reader == NULL uniquely
// means fallback, because teardown NULLs the handle and removes the child
// in the same mutex-held remove_children pass.
static void
reader_unpark_for_screen(ChildMonitor *self, Screen *screen) {
    children_mutex(lock);
    for (size_t i = 0; i < self->count; i++) {
        if (children[i].screen == screen) {
            if (children[i].reader) reader_trigger_wake(children[i].reader);
            else wakeup_io_loop(self, false);
            break;
        }
    }
    children_mutex(unlock);
}

static void
reader_set_master_enabled(ReaderThread *rt, bool on) {
    struct kevent kev;
    EV_SET(&kev, rt->master_fd, EVFILT_READ, on ? EV_ENABLE : EV_DISABLE, 0, 0, NULL);
    if (kevent(rt->kq, &kev, 1, NULL, 0, NULL) < 0)
        log_error("Wave-22 reader %lu: EVFILT_READ %s failed: %s", rt->child_id,
                  on ? "enable" : "disable", strerror(errno));
}

// O8: the io/main thread stays the sole servicer of KITTY_HANDLED_SIGNALS.
static void
reader_block_handled_signals(void) {
    sigset_t signals;
    sigemptyset(&signals);
    const int sigs[] = { KITTY_HANDLED_SIGNALS };  // macro ends with the 0 sentinel
    for (size_t i = 0; sigs[i] != 0; i++) sigaddset(&signals, sigs[i]);
    pthread_sigmask(SIG_BLOCK, &signals, NULL);
}

// P3 (R22-B2-RESTATEMENT.md): the aggregate-coalescing CAS. seq_cst on BOTH
// orders is load-bearing — the CAS-loser's commit-visibility proof needs the
// failure load inside the seq_cst total order. Returns true iff this caller
// won and issued the wakeup; a loser owes nothing (a winner's wakeup is in
// flight and its tick drains ALL rings — condition 9).
static bool
reader_coalesced_wakeup(void) {
    bool expected = false;
    if (atomic_compare_exchange_strong_explicit(&main_wakeup_pending, &expected, true,
                                                memory_order_seq_cst, memory_order_seq_cst)) {
        wakeup_main_loop();
        return true;
    }
    return false;
}

// O1 flush-wakeup-before-park (N1): a reader NEVER blocks on a full ring
// without a covering main-loop wakeup in flight. Clear the deferred batch
// state and wake NOW, bypassing the batch window, gated only by the CAS
// (CAS-loss = one already in flight; correct either way).
static void
reader_flush_wakeup_before_park(bool *deferred, monotonic_t *last_wakeup_at) {
    *deferred = false;
    reader_coalesced_wakeup();
    *last_wakeup_at = monotonic();
}

// Drain-batch epilogue: the coalesced main-wakeup decision (D2.5).
static void
reader_epilogue(ReaderCounters *rc, size_t total,
                bool *deferred, monotonic_t *last_wakeup_at) {
    if (!total) return;
    const monotonic_t now = monotonic();
    const monotonic_t kt_key = atomic_load_explicit(&last_local_key_input_at, memory_order_relaxed);
    // O3 (per-reader total — the F11 delta: a flood in another pane no
    // longer masks this pane's echo, so this is a per-child denominator).
    const bool key_echo = total <= L5_SMALL_READ_MAX && now - kt_key <= L5_KEY_RECENCY_WINDOW;
    // O13: kt_* stamping migrated from io_loop, FULL predicate preserved
    // including the kt_key > 0 guard. The single-writer assumption behind
    // kt_* relaxes to "the reader that first echoes each key": racing
    // readers are benign — relaxed atomics guarding an instrument, and the
    // kt_echo_read_at < kt_key guard is monotone (one reader wins, a stale
    // read only misses one stamp).
    if (UNLIKELY(frame_trace_enabled())
            && kt_key > 0 && atomic_load_explicit(&kt_echo_read_at, memory_order_relaxed) < kt_key
            && now - kt_key <= KT_ECHO_STAMP_WINDOW) {
        atomic_store_explicit(&kt_echo_bytes, (uint64_t)total, memory_order_relaxed);
        atomic_store_explicit(&kt_l5_miss, !key_echo, memory_order_relaxed);
        atomic_store_explicit(&kt_echo_read_at, now, memory_order_relaxed);
    }
    if (key_echo) {
        // Immediate: bypasses BOTH the input_delay window and the
        // main_wakeup_pending batch flag (default-ON L5 semantics).
        atomic_fetch_add_explicit(&rc->echo_immediates, 1, memory_order_relaxed);
        wakeup_main_loop();
        *last_wakeup_at = now;
        *deferred = false;
        return;
    }
    // O4: at most one wakeup per OPT(input_delay) window per reader; a
    // within-window batch defers, and the next kevent wait gets the
    // remaining-window timeout so the deferred flush fires on time.
    if (now - *last_wakeup_at > OPT(input_delay)) {
        if (reader_coalesced_wakeup()) atomic_fetch_add_explicit(&rc->batch_flushes, 1, memory_order_relaxed);
        *last_wakeup_at = now;
        *deferred = false;
    } else *deferred = true;
}

// D2.4 child-death path: bytes from every successful read are already
// committed (commit-before-continue), so EOF is byte-exact by construction.
static void
reader_mark_child_dead(ReaderThread *rt) {
    ChildMonitor *self = rt->monitor;
    children_mutex(lock);
    for (size_t i = 0; i < self->count; i++) {
        if (children[i].id == rt->child_id) { children[i].needs_removal = true; break; }
    }
    children_mutex(unlock);
    wakeup_io_loop(self, false);  // the io loop performs the ordered teardown
    wakeup_main_loop();           // parse the final committed bytes promptly
}

static void*
reader_main(void *arg) {
    ReaderThread *rt = arg;
    set_thread_name("KittyReader");
    reader_block_handled_signals();  // O8
    ReaderCounters *rc = reader_counters + rt->slot;
    Screen *screen = rt->screen;
    bool deferred = false;        // O4 pending-flush state
    bool master_enabled = true;   // EVFILT_READ armed on the kqueue
    monotonic_t last_wakeup_at = -1;
    while (!atomic_load_explicit(&rt->stop, memory_order_acquire)) {
        // ARM: ring-full parks the producer inside the ring's FR-2 protocol
        // (flag + seq_cst fence + re-check), exactly as the io thread does
        // today — the reader is the single producer, so the pairing holds.
        if (!vt_parser_arm_pollin(screen->vt_parser)) {
            reader_flush_wakeup_before_park(&deferred, &last_wakeup_at);  // O1
            atomic_fetch_add_explicit(&rc->park_cycles, 1, memory_order_relaxed);
            // PARKED: block on the wake channel ONLY. The master stays
            // level-ready while the ring is full; leaving it armed would
            // busy-loop the park (C4), so disable it for the park's
            // duration.
            if (master_enabled) { reader_set_master_enabled(rt, false); master_enabled = false; }
            struct kevent ev;
            const int n = kevent(rt->kq, NULL, 0, &ev, 1, NULL);
            if (n < 0) {
                if (errno == EINTR) continue;
                log_error("Wave-22 reader %lu: park kevent failed: %s", rt->child_id, strerror(errno));
                reader_mark_child_dead(rt);
                break;
            }
            atomic_fetch_add_explicit(&rc->wakeups, 1, memory_order_relaxed);
            if (atomic_load_explicit(&rt->stop, memory_order_acquire)) {
                atomic_fetch_add_explicit(&rc->wake_teardown, 1, memory_order_relaxed);
                break;
            }
            atomic_fetch_add_explicit(&rc->wake_unpark, 1, memory_order_relaxed);
            continue;  // loop top re-checks stop and re-arms
        }
        if (!master_enabled) { reader_set_master_enabled(rt, true); master_enabled = true; }
        // POLL: block; finite timeout only when a deferred flush is owed
        // (timed-kevent deferred flush — kevent timespec is ns-granular, so
        // the OPT(input_delay) ms window is representable exactly).
        struct timespec ts, *tsp = NULL;
        if (deferred) {
            monotonic_t remaining = OPT(input_delay) - (monotonic() - last_wakeup_at);
            if (remaining < 0) remaining = 0;
            ts.tv_sec = remaining / MONOTONIC_T_1e9;
            ts.tv_nsec = remaining % MONOTONIC_T_1e9;
            tsp = &ts;
        }
        struct kevent evs[2];
        const int n = kevent(rt->kq, NULL, 0, evs, 2, tsp);
        if (n < 0) {
            if (errno == EINTR) continue;
            log_error("Wave-22 reader %lu: kevent failed: %s", rt->child_id, strerror(errno));
            reader_mark_child_dead(rt);
            break;
        }
        atomic_fetch_add_explicit(&rc->wakeups, 1, memory_order_relaxed);
        if (atomic_load_explicit(&rt->stop, memory_order_acquire)) {
            atomic_fetch_add_explicit(&rc->wake_teardown, 1, memory_order_relaxed);
            break;
        }
        if (n == 0) {
            // TIMER: the deferred batch window expired — flush (O4),
            // CAS-gated like every batched wakeup.
            atomic_fetch_add_explicit(&rc->wake_timer, 1, memory_order_relaxed);
            if (deferred) {
                if (reader_coalesced_wakeup()) atomic_fetch_add_explicit(&rc->batch_flushes, 1, memory_order_relaxed);
                deferred = false;
                last_wakeup_at = monotonic();
            }
            continue;
        }
        bool have_data = false;
        int64_t avail = 0;
        for (int e = 0; e < n; e++) {
            if (evs[e].filter == EVFILT_READ) { have_data = true; avail = evs[e].data; }
        }
        if (!have_data) {
            // Wake-channel trigger while not parked: a benign spurious
            // unpark (a stale park claim at worst sends one — ring header
            // comment) or a teardown race already handled at loop top.
            atomic_fetch_add_explicit(&rc->wake_unpark, 1, memory_order_relaxed);
            continue;
        }
        atomic_fetch_add_explicit(&rc->wake_data, 1, memory_order_relaxed);
        // DRAIN: O5 kqueue-with-availability-count — read ceil(avail/quantum)
        // times with NO trailing EAGAIN probe (the avail bound, not an empty
        // read, ends the loop); O11 CAP bound; O10 errno discipline.
        size_t total = 0;
        bool child_dead = false;
        for (unsigned iters = 0; iters < READER_DRAIN_CAP; iters++) {
            if (!vt_parser_arm_pollin(screen->vt_parser)) break;  // ring filled -> park next loop
            size_t space;
            uint8_t *buf = vt_parser_create_write_buffer(screen->vt_parser, &space);
            if (!space) break;
            const ssize_t len = read(rt->master_fd, buf, space);  // NONBLOCKING (K1-K3, O9)
            if (len < 0) {
                vt_parser_commit_write(screen->vt_parser, 0);
                if (errno == EINTR) continue;       // retry, bounded by CAP
                if (errno == EAGAIN) break;         // kernel drained -> re-poll (C2)
                if (errno != EIO) log_error("Wave-22 reader %lu: read failed: %s", rt->child_id, strerror(errno));
                child_dead = true;
                break;
            }
            if (len == 0) { vt_parser_commit_write(screen->vt_parser, 0); child_dead = true; break; }
            vt_parser_commit_write(screen->vt_parser, (size_t)len);  // P1 publish + P2 fence
            atomic_fetch_add_explicit(&rc->reads, 1, memory_order_relaxed);
            atomic_fetch_add_explicit(&rc->bytes, (uint64_t)len, memory_order_relaxed);
            total += (size_t)len;
            if ((int64_t)len >= avail) break;  // avail-count satisfied, no EAGAIN probe
            avail -= len;
        }
        reader_epilogue(rc, total, &deferred, &last_wakeup_at);  // EPILOGUE (order per P-checklist 4)
        if (child_dead) { reader_mark_child_dead(rt); break; }
    }
    return NULL;
}

// W23 F-C: test-only spawn-failure injection so the fallback-child paths
// (budget exhaustion, F1 unpark delivery) are battery-exercisable instead
// of inspection-only. KITTY_READER_SPAWN_FAIL unset or "0" = injection
// off (one cached-bool branch, spawn path otherwise byte-identical);
// "all" = every spawn fails; a number n = the first n spawns fail. The
// failure happens BEFORE any fd or allocation, returning NULL exactly
// like the budget-exhausted path the caller already handles. Counter
// mutation is race-free: reader_spawn runs under children_mutex.
static bool
reader_spawn_fail_injected(void) {
    static int mode = -2;  // -2 unresolved, -1 all, 0 off, >0 remaining count
    if (UNLIKELY(mode == -2)) {
        const char *v = getenv("KITTY_READER_SPAWN_FAIL");
        if (!v || !v[0] || strcmp(v, "0") == 0) mode = 0;
        else if (strcmp(v, "all") == 0) mode = -1;
        else mode = MAX(atoi(v), 0);
    }
    if (mode == 0) return false;
    if (mode == -1) return true;
    mode--;
    return true;
}

// Spawn at add_children (O14); children_mutex held by the caller.
static ReaderThread*
reader_spawn(ChildMonitor *self, Child *c) {
    if (UNLIKELY(reader_spawn_fail_injected())) {
        log_error("Wave-23 readers: spawn failure injected (KITTY_READER_SPAWN_FAIL); child %lu keeps the legacy io read path", c->id);
        return NULL;
    }
    if (live_readers >= reader_fd_budget_children) {
        if (!reader_budget_warned) {
            log_error("Wave-22 readers: fd budget (%u) exhausted; child %lu keeps the legacy io read path",
                      reader_fd_budget_children, c->id);
            reader_budget_warned = true;
        }
        return NULL;
    }
    ReaderThread *rt = calloc(1, sizeof(ReaderThread));
    if (!rt) return NULL;
    rt->monitor = self; rt->screen = c->screen; rt->master_fd = c->read_fd; rt->child_id = c->id;
    rt->kq = kqueue();
    if (rt->kq < 0) {
        log_error("Wave-22 readers: kqueue() failed: %s; child %lu keeps the legacy path", strerror(errno), c->id);
        free(rt);
        return NULL;
    }
    struct kevent evs[2];
    EV_SET(&evs[0], rt->master_fd, EVFILT_READ, EV_ADD, 0, 0, NULL);
    EV_SET(&evs[1], READER_WAKE_IDENT, EVFILT_USER, EV_ADD | EV_CLEAR, 0, 0, NULL);
    if (kevent(rt->kq, evs, 2, NULL, 0, NULL) < 0) {
        log_error("Wave-22 readers: kevent registration failed: %s; child %lu keeps the legacy path",
                  strerror(errno), c->id);
        safe_close(rt->kq, __FILE__, __LINE__);
        free(rt);
        return NULL;
    }
    if (reader_slot_free_count) rt->slot = reader_slot_free[--reader_slot_free_count];
    else {
        const unsigned hwm = atomic_load_explicit(&reader_slot_hwm, memory_order_relaxed);
        if (hwm >= MAX_CHILDREN) { safe_close(rt->kq, __FILE__, __LINE__); free(rt); return NULL; }
        rt->slot = hwm;
        atomic_store_explicit(&reader_slot_hwm, hwm + 1, memory_order_relaxed);
    }
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, 256u * 1024u);  // O14: pinned 256 KiB
    const int ret = pthread_create(&rt->thread, &attr, reader_main, rt);
    pthread_attr_destroy(&attr);
    if (ret != 0) {
        log_error("Wave-22 readers: pthread_create failed: %s; child %lu keeps the legacy path",
                  strerror(ret), c->id);
        reader_slot_free[reader_slot_free_count++] = rt->slot;
        safe_close(rt->kq, __FILE__, __LINE__);
        free(rt);
        return NULL;
    }
    live_readers++;
    return rt;
}

// O6/O7 completion, run by the io thread with children_mutex RELEASED:
// join (the reader is guaranteed to wake: its stop flag is set and its wake
// channel was triggered while the handle was still published) -> close the
// reader-owned kqueue only after the join -> close the child fd only now
// that no thread can be blocked on it -> only then publish the child to
// remove_queue, so the main thread's death notification (and the Child's
// final DECREF) cannot run while the reader still uses the screen. Joining
// under children_mutex would deadlock against a reader in its child-death
// path; closing earlier would strand the reader on a closing fd (the macOS
// hazard D2.4 rejects).
static void
finish_reader_teardowns(ChildMonitor *self UNUSED) {
    if (!reader_teardown_pending_count) return;
    for (size_t i = 0; i < reader_teardown_pending_count; i++) {
        ReaderThread *rt = reader_teardown_pending[i].rt;
        pthread_join(rt->thread, NULL);
        safe_close(rt->kq, __FILE__, __LINE__);
        safe_close(reader_teardown_pending[i].child.fd, __FILE__, __LINE__);
        if (reader_teardown_pending[i].child.read_fd != reader_teardown_pending[i].child.fd)
            safe_close(reader_teardown_pending[i].child.read_fd, __FILE__, __LINE__);
        children_mutex(lock);
        live_readers--;
        reader_slot_free[reader_slot_free_count++] = rt->slot;
        remove_queue[remove_queue_count] = reader_teardown_pending[i].child;
        remove_queue_count++;
        children_mutex(unlock);
        free(rt);
        reader_teardown_pending[i].rt = NULL;
        reader_teardown_pending[i].child = EMPTY_CHILD;
    }
    reader_teardown_pending_count = 0;
    wakeup_main_loop();  // deliver the deferred death notifications
}
#endif

static void
add_children(ChildMonitor *self) {
    for (; add_queue_count > 0 && self->count < MAX_CHILDREN;) {
        add_queue_count--;
        children[self->count] = add_queue[add_queue_count];
        add_queue[add_queue_count] = EMPTY_CHILD;
        children_fds[EXTRA_FDS + self->count].fd = children[self->count].read_fd;
        if (children[self->count].read_fd != children[self->count].fd)
            atomic_fetch_add_explicit(&io_pump_children, 1, memory_order_relaxed);
        if (UNLIKELY(getenv("KITTY_PUMP_DEBUG")))
            log_error("pump-dbg: add child id=%lu fd=%d read_fd=%d slot=%u", children[self->count].id,
                      children[self->count].fd, children[self->count].read_fd, EXTRA_FDS + self->count);
#ifdef KITTY_BACKEND_METAL
        if (reader_threads_enabled()) {
            // Wave-22 ON arm (O14): the reader owns this child's reads from
            // birth; a failed spawn falls back to the legacy POLLIN path
            // for this child only (fail toward OFF).
            children[self->count].reader = reader_spawn(self, &children[self->count]);
            children_fds[EXTRA_FDS + self->count].events = children[self->count].reader ? 0 : POLLIN;
        } else
#endif
        children_fds[EXTRA_FDS + self->count].events = POLLIN;
        self->count++;
    }
}


static void
hangup(pid_t pid) {
    errno = 0;
    pid_t pgid = getpgid(pid);
    if (errno == ESRCH) return;
    if (errno != 0) { perror("Failed to get process group id for child"); return; }
    if (killpg(pgid, SIGHUP) != 0) {
        if (errno != ESRCH) perror("Failed to kill child");
    }
}


static void
cleanup_child(ssize_t i) {
    safe_close(children[i].fd, __FILE__, __LINE__);
    if (children[i].read_fd != children[i].fd) safe_close(children[i].read_fd, __FILE__, __LINE__);
    hangup(children[i].pid);
}


static void
remove_children(ChildMonitor *self) {
    if (self->count > 0) {
        size_t count = 0;
        for (ssize_t i = self->count - 1; i >= 0; i--) {
            if (children[i].needs_removal) {
                count++;
#ifdef KITTY_BACKEND_METAL
                if (children[i].reader) {
                    // Wave-22 O7/O15: retire the wake handle under
                    // children_mutex BEFORE the join (after this store no
                    // main-thread unpark can reach this kqueue), request
                    // stop (release), trigger the wake channel, and DEFER
                    // the join + fd closes + remove_queue publication to
                    // finish_reader_teardowns() outside the mutex. hangup()
                    // keeps its legacy timing.
                    ReaderThread *rt = children[i].reader;
                    children[i].reader = NULL;
                    atomic_store_explicit(&rt->stop, true, memory_order_release);
                    reader_trigger_wake(rt);
                    hangup(children[i].pid);
                    reader_teardown_pending[reader_teardown_pending_count].child = children[i];
                    reader_teardown_pending[reader_teardown_pending_count].rt = rt;
                    reader_teardown_pending_count++;
                } else {
                    cleanup_child(i);
                    remove_queue[remove_queue_count] = children[i];
                    remove_queue_count++;
                }
#else
                cleanup_child(i);
                remove_queue[remove_queue_count] = children[i];
                remove_queue_count++;
#endif
                if (children[i].read_fd != children[i].fd)
                    atomic_fetch_sub_explicit(&io_pump_children, 1, memory_order_relaxed);
                children[i] = EMPTY_CHILD;
                children_fds[EXTRA_FDS + i].fd = -1;
                size_t num_to_right = self->count - 1 - i;
                if (num_to_right > 0) {
                    memmove(children + i, children + i + 1, num_to_right * sizeof(Child));
                    memmove(children_fds + EXTRA_FDS + i, children_fds + EXTRA_FDS + i + 1, num_to_right * sizeof(struct pollfd));
                }
            }
        }
        self->count -= count;
    }
}


static bool
read_bytes(int fd, Screen *screen, size_t *nread) {
    ssize_t len;
    size_t available_buffer_space;

    *nread = 0;  // L5: bytes read this call (for the keystroke-echo fast-path)
    uint8_t *buf = vt_parser_create_write_buffer(screen->vt_parser, &available_buffer_space);
    if (!available_buffer_space) return true;
#ifdef KITTY_BACKEND_METAL
    // Wave-19 L3 probe: io-thread side of the ftrace instrumentation.
    // free_total must be snapshotted now, alongside available_buffer_space
    // and before commit_write moves the ring's head, or the wrap-capped
    // comparison below would compare pre- and post-commit ring states.
    const bool io_ft = UNLIKELY(frame_trace_enabled());
    const monotonic_t io_t0 = io_ft ? monotonic() : 0;
    const size_t io_free_total = io_ft ? vt_parser_ring_free_total(screen->vt_parser) : 0;
#endif

    while(true) {
        len = read(fd, buf, available_buffer_space);
        if (len < 0) {
            if (errno == EINTR || errno == EAGAIN) continue;
            if (errno != EIO) perror("Call to read() from child fd failed");
            vt_parser_commit_write(screen->vt_parser, 0);
            return false;
        }
        break;
    }
    vt_parser_commit_write(screen->vt_parser, len);
    if (len > 0) *nread = (size_t)len;
#ifdef KITTY_BACKEND_METAL
    if (io_ft) {
        atomic_fetch_add_explicit(&io_read_calls, 1, memory_order_relaxed);
        atomic_fetch_add_explicit(&io_read_bytes, (uint64_t)len, memory_order_relaxed);
        atomic_fetch_add_explicit(&io_read_ns, (uint64_t)(monotonic() - io_t0), memory_order_relaxed);
        atomic_fetch_add_explicit(&io_avail_bytes, (uint64_t)available_buffer_space, memory_order_relaxed);
        // Distinguish "capped by the ring's flat-array wrap point" (a read
        // sizing artifact) from "capped by genuine ring occupancy" (real
        // backpressure): the former is smaller than the ring's true total
        // free space, the latter equals it.
        if (available_buffer_space < io_free_total)
            atomic_fetch_add_explicit(&io_wrap_capped_calls, 1, memory_order_relaxed);
    }
#endif
    return len != 0;
}


typedef struct { bool kill_signal, child_died, reload_config; } SignalSet;

static bool
handle_signal(const siginfo_t *siginfo, void *data) {
    SignalSet *ss = data;
    switch(siginfo->si_signo) {
        case SIGINT:
        case SIGTERM:
        case SIGHUP:
            ss->kill_signal = true;
            break;
        case SIGCHLD:
            ss->child_died = true;
            break;
        case SIGUSR1:
            ss->reload_config = true;
            break;
        case SIGUSR2:
            log_error("Received SIGUSR2: %d\n", siginfo->si_value.sival_int);
            break;
        default:
            break;
    }
    return true;
}

static void
mark_child_for_removal(ChildMonitor *self, pid_t pid, int exit_status) {
    children_mutex(lock);
    for (size_t i = 0; i < self->count; i++) {
        if (children[i].pid == pid) {
            children[i].needs_removal = true;
            children[i].exit_status = exit_status;
            children[i].child_died = true;
            break;
        }
    }
    children_mutex(unlock);
}

static void
mark_monitored_pids(pid_t pid, int status) {
    children_mutex(lock);
    for (ssize_t i = monitored_pids_count - 1; i >= 0; i--) {
        if (pid == monitored_pids[i]) {
            if (reaped_pids_count < arraysz(reaped_pids)) {
                reaped_pids[reaped_pids_count].status = status;
                reaped_pids[reaped_pids_count++].pid = pid;
            }
            remove_i_from_array(monitored_pids, (size_t)i, monitored_pids_count);
        }
    }
    children_mutex(unlock);
}

static void
reap_children(ChildMonitor *self, bool enable_close_on_child_death) {
    int status;
    pid_t pid;
    (void)self;
    while(true) {
        pid = waitpid(-1, &status, WNOHANG);
        if (pid == -1) {
            if (errno != EINTR) break;
        } else if (pid > 0) {
            if (enable_close_on_child_death) mark_child_for_removal(self, pid, status);
            mark_monitored_pids(pid, status);
        } else break;
    }
}

#ifdef KITTY_PRINT_BYTES_SENT_TO_CHILD
static void
print_text(const unsigned char *text, ssize_t sz) {
    for (ssize_t i = 0; i < sz; i++) {
        unsigned char ch = text[i];
        if (32 <= ch && ch < 127) {
            if (ch == '\\') fprintf(stderr, "%c", ch);
            fprintf(stderr, "%c", ch);
        } else fprintf(stderr, "\\x%02x", ch);
    }
}
#endif


static void
write_to_child(int fd, Screen *screen) {
    size_t written = 0;
    ssize_t ret = 0;
    screen_mutex(lock, write);
    while (written < screen->write_buf_used) {
        ret = write(fd, screen->write_buf + written, screen->write_buf_used - written);
#ifdef KITTY_PRINT_BYTES_SENT_TO_CHILD
        fprintf(stderr, "Wrote: %zd bytes: ", ret);
#endif
        if (ret > 0) {
#ifdef KITTY_PRINT_BYTES_SENT_TO_CHILD
            print_text(screen->write_buf + written, ret);
#endif
            written += ret;
        }
        else if (ret == 0) {
            // could mean anything, ignore
            break;
        } else {
            if (errno == EINTR) continue;
            if (errno == EWOULDBLOCK || errno == EAGAIN) break;
            perror("Call to write() to child fd failed, discarding data.");
            written = screen->write_buf_used;
        }
#ifdef KITTY_PRINT_BYTES_SENT_TO_CHILD
        fprintf(stderr, "\n");
#endif
    }
    if (written) {
        screen->write_buf_used -= written;
        if (screen->write_buf_used) {
            memmove(screen->write_buf, screen->write_buf + written, screen->write_buf_used);
        }
    }
    screen_mutex(unlock, write);
}

static void*
io_loop(void *data) {
    // The I/O thread loop
    size_t i;
    int ret;
    bool has_more, data_received, has_pending_wakeups = false;
    size_t total_read_bytes;  // L5: bytes read this poll iteration (echo fast-path)
    monotonic_t last_main_loop_wakeup_at = -1, now = -1;
    Screen *screen;
    ChildMonitor *self = (ChildMonitor*)data;
    set_thread_name("KittyChildMon");

    while (LIKELY(!self->shutting_down)) {
        children_mutex(lock);
        remove_children(self);
        add_children(self);
        children_mutex(unlock);
#ifdef KITTY_BACKEND_METAL
        // Wave-22: joins deferred by remove_children run with the mutex
        // released (a reader's child-death path takes children_mutex).
        finish_reader_teardowns(self);
#endif
        data_received = false;
        total_read_bytes = 0;
        // KITTY_PTY_PUMP: per-iteration POLLOUT tail slots (see children_fds).
        size_t pump_out_count = 0;
#ifdef KITTY_BACKEND_METAL
        // Wave-19 L3 probe: one io_loop pass. frame_trace_enabled() is a
        // cached static-bool check (getenv() runs once), cheap to call
        // every iteration even when off.
        const bool io_ft = UNLIKELY(frame_trace_enabled());
        if (io_ft) atomic_fetch_add_explicit(&io_loop_iters, 1, memory_order_relaxed);
#endif
        for (i = 0; i < self->count + EXTRA_FDS; i++) children_fds[i].revents = 0;
        for (i = 0; i < self->count; i++) {
            screen = children[i].screen;
            /* printf("i:%lu id:%lu fd: %d read_buf_sz: %lu write_buf_used: %lu\n", i, children[i].id, children[i].fd, screen->read_buf_sz, screen->write_buf_used); */
#ifdef KITTY_BACKEND_METAL
            if (children[i].reader) {
                // Wave-22 ON arm (D2.3): reads and the ring producer side
                // belong to this child's reader; the io thread keeps only
                // POLLOUT. With nothing to write the fd is excluded from
                // the pollset entirely (fd = -1) so an unmaskable POLLHUP
                // from a dying child cannot spin the io poll while the
                // reader delivers the EOF through its own path.
                screen_mutex(lock, write);
                const bool wants_out = screen->write_buf_used > 0;
                screen_mutex(unlock, write);
                children_fds[EXTRA_FDS + i].fd = wants_out ? children[i].fd : -1;
                children_fds[EXTRA_FDS + i].events = wants_out ? POLLOUT : 0;
                continue;
            }
#endif
            // arm-or-park: on a full ring this parks the reader inside the
            // ring's waiter protocol before dropping POLLIN, so the parse
            // tick's unpark (write_space_created -> wakeup_io_loop) cannot
            // be lost to a fill that races the fullness check
            const bool pollin_armed = vt_parser_arm_pollin(screen->vt_parser);
#ifdef KITTY_BACKEND_METAL
            if (io_ft && !pollin_armed) atomic_fetch_add_explicit(&io_pollin_disarmed, 1, memory_order_relaxed);
#endif
            children_fds[EXTRA_FDS + i].events = pollin_armed ? POLLIN : 0;
            screen_mutex(lock, write);
            const bool wants_out = screen->write_buf_used > 0;
            screen_mutex(unlock, write);
            if (children[i].read_fd != children[i].fd) {
                // KITTY_PTY_PUMP: this child's slot fd is the pump pipe
                // (POLLIN only); pending writes need the pty master, which
                // one pollfd cannot also watch — append a per-iteration
                // POLLOUT tail slot for the master instead.
                if (wants_out) {
                    const size_t t = EXTRA_FDS + self->count + pump_out_count;
                    children_fds[t].fd = children[i].fd;
                    children_fds[t].events = POLLOUT;
                    children_fds[t].revents = 0;
                    pump_out_child[pump_out_count++] = i;
                }
            } else {
                children_fds[EXTRA_FDS + i].events |= wants_out ? POLLOUT : 0;
            }
        }
#ifdef KITTY_BACKEND_METAL
        // count/time only the branches that actually issue poll(2); the
        // has_pending_wakeups && time_delta<0 case sets ret=0 without
        // polling and must not be counted as a syscall.
#define TIMED_POLL(...) do { \
    const monotonic_t io_poll_t0 = io_ft ? monotonic() : 0; \
    ret = poll(__VA_ARGS__); \
    if (io_ft) { \
        atomic_fetch_add_explicit(&io_poll_calls, 1, memory_order_relaxed); \
        atomic_fetch_add_explicit(&io_poll_ns, (uint64_t)(monotonic() - io_poll_t0), memory_order_relaxed); \
    } \
} while (0)
#else
#define TIMED_POLL(...) do { ret = poll(__VA_ARGS__); } while (0)
#endif
        if (has_pending_wakeups) {
            now = monotonic();
            monotonic_t time_delta = OPT(input_delay) - (now - last_main_loop_wakeup_at);
            if (time_delta >= 0) TIMED_POLL(children_fds, self->count + EXTRA_FDS + pump_out_count, monotonic_t_to_ms(time_delta));
            else ret = 0;
        } else {
            TIMED_POLL(children_fds, self->count + EXTRA_FDS + pump_out_count, -1);
        }
#undef TIMED_POLL
        if (ret > 0) {
            // W23 F-B: the old logical `revents && POLLIN` was true on ANY
            // event; the explicit mask keeps that drain-on-any-event intent
            // (POLLERR/POLLHUP on these process-lifetime self-pipe fds is
            // unreachable by construction — both ends process-owned).
            if (children_fds[0].revents & (POLLIN | POLLHUP | POLLERR)) drain_fd(children_fds[0].fd); // wakeup
            if (children_fds[1].revents & (POLLIN | POLLHUP | POLLERR)) {
                SignalSet ss = {0};
                data_received = true;
                read_signals(children_fds[1].fd, handle_signal, &ss);
                if (ss.kill_signal || ss.reload_config) {
                    children_mutex(lock);
                    if (ss.kill_signal) kill_signal_received = true;
                    if (ss.reload_config) reload_config_signal_received = true;
                    children_mutex(unlock);
                }
                if (ss.child_died) reap_children(self, OPT(close_on_child_death));
            }
            for (i = 0; i < self->count; i++) {
#ifdef KITTY_BACKEND_METAL
                // Wave-22 ON arm: this child's reads (and its EOF/POLLHUP)
                // are the reader's; the io thread services only POLLOUT
                // below. Reading here would violate the single-producer
                // ring contract (D2.2).
                if (children[i].reader) {
                    if (children_fds[EXTRA_FDS + i].revents & POLLOUT) {
                        write_to_child(children[i].fd, children[i].screen);
                    }
                    continue;
                }
#endif
                if (children_fds[EXTRA_FDS + i].revents & (POLLIN | POLLHUP)) {
                    data_received = true;
                    size_t nread = 0;
                    has_more = read_bytes(children_fds[EXTRA_FDS + i].fd, children[i].screen, &nread);
                    total_read_bytes += nread;
                    if (!has_more) {
                        // child is dead
                        children_mutex(lock);
                        children[i].needs_removal = true;
                        children_mutex(unlock);
                    }
                }
                if (children_fds[EXTRA_FDS + i].revents & POLLOUT) {
                    write_to_child(children[i].fd, children[i].screen);
                }
                if (children_fds[EXTRA_FDS + i].revents & POLLNVAL) {
                    // fd was closed
                    children_mutex(lock);
                    children[i].needs_removal = true;
                    children_mutex(unlock);
                    log_error("The child %lu had its fd unexpectedly closed", children[i].id);
                }
            }
            // KITTY_PTY_PUMP: service the per-iteration POLLOUT tail slots
            // (pty masters of pump children with pending writes). The child
            // indices are stable within this iteration: add/remove ran with
            // the mutex at loop top and only this thread compacts children[].
            for (size_t t = 0; t < pump_out_count; t++) {
                if (children_fds[EXTRA_FDS + self->count + t].revents & POLLOUT) {
                    const size_t ci = pump_out_child[t];
                    write_to_child(children[ci].fd, children[ci].screen);
                }
            }
#ifdef DEBUG_POLL_EVENTS
            for (i = 0; i < self->count + EXTRA_FDS; i++) {
#define P(w) if (children_fds[i].revents & w) printf("i:%lu %s\n", i, #w);
                P(POLLIN); P(POLLPRI); P(POLLOUT); P(POLLERR); P(POLLHUP); P(POLLNVAL);
#undef P
            }
#endif
        } else if (ret < 0) {
            if (errno != EAGAIN && errno != EINTR) {
                perror("Call to poll() failed");
            }
        }
#define WAKEUP { wakeup_main_loop(); last_main_loop_wakeup_at = now; has_pending_wakeups = false; }
        // we only wakeup the main loop after input_delay as wakeup is an expensive operation
        // on some platforms, such as cocoa
        if (data_received) {
            now = monotonic();
            // Phase 4 (L5): a SMALL read arriving within L5_KEY_RECENCY_WINDOW of a
            // local key press is the echo of that keystroke — wake the main loop
            // immediately (skip the input_delay coalescing) so the first echo
            // renders ~input_delay sooner. Bulk output (large reads) still batches,
            // avoiding full-redraw flicker.
            const bool key_echo = total_read_bytes > 0 && total_read_bytes <= L5_SMALL_READ_MAX
                && (now - atomic_load_explicit(&last_local_key_input_at, memory_order_relaxed)) <= L5_KEY_RECENCY_WINDOW;
            // Wave-20 T1.1 (S2): stamp the FIRST read after each key press as
            // that key's echo. An echo outside the L5 window (> 128 B or
            // > 50 ms, up to the instrumentation bound) is stamped too and
            // flagged l5_miss — reported as a sub-population, never dropped.
            if (io_ft && total_read_bytes > 0) {
                const monotonic_t kt_key = atomic_load_explicit(&last_local_key_input_at, memory_order_relaxed);
                if (kt_key > 0 && atomic_load_explicit(&kt_echo_read_at, memory_order_relaxed) < kt_key
                        && now - kt_key <= KT_ECHO_STAMP_WINDOW) {
                    atomic_store_explicit(&kt_echo_bytes, (uint64_t)total_read_bytes, memory_order_relaxed);
                    atomic_store_explicit(&kt_l5_miss, !key_echo, memory_order_relaxed);
                    atomic_store_explicit(&kt_echo_read_at, now, memory_order_relaxed);
                }
            }
            if (key_echo || now - last_main_loop_wakeup_at > OPT(input_delay)) WAKEUP
            else has_pending_wakeups = true;
        } else {
            if (has_pending_wakeups && (now = monotonic()) - last_main_loop_wakeup_at > OPT(input_delay)) WAKEUP
        }
    }
#undef WAKEUP
    children_mutex(lock);
    for (i = 0; i < self->count; i++) children[i].needs_removal = true;
    remove_children(self);
    children_mutex(unlock);
#ifdef KITTY_BACKEND_METAL
    // Wave-22 O7 shutdown order: remove_children set every reader's stop
    // flag and triggered every wake channel under the mutex; now join them
    // all and only then close their fds.
    finish_reader_teardowns(self);
#endif
    return 0;
}
// }}}

// {{{ Talk thread functions

typedef struct {
    id_type id;
    size_t num_of_unresponded_messages_sent_to_main_thread, fd_array_idx;
    bool finished_reading, waiting_for_async_response;
    int fd;
    struct {
        char *data;
        size_t capacity, used, command_end;
        bool finished;
    } read;
    struct {
        char *data;
        size_t capacity, used;
        bool failed;
    } write;
    bool is_remote_control_peer;
} Peer;
static id_type peer_id_counter = 0;

typedef struct {
    size_t num_peers, peers_capacity;
    Peer *peers;
    LoopData loop_data;
} TalkData;
static TalkData talk_data = {0};

static int
start_talk_thread(ChildMonitor *self) {
    if (talk_thread_started) return 0;
    if (!init_loop_data(&talk_data.loop_data, 0)) return errno;
    int ret = pthread_create(&self->talk_thread, NULL, talk_loop, self);
    talk_thread_started = ret == 0;
    return ret;
}

typedef struct pollfd PollFD;
#define PEER_LIMIT 256
#define nuke_socket(s) { shutdown(s, SHUT_RDWR); safe_close(s, __FILE__, __LINE__); }

static id_type
add_peer(int peer, bool is_remote_control_peer) {
    id_type ans = 0;
    if (talk_data.num_peers < PEER_LIMIT) {
        ensure_space_for(&talk_data, peers, Peer, talk_data.num_peers + 8, peers_capacity, 8, false);
        Peer *p = talk_data.peers + talk_data.num_peers++;
        memset(p, 0, sizeof(Peer));
        p->fd = peer; p->id = ++peer_id_counter;
        if (!p->id) p->id = ++peer_id_counter;
        ans = p->id;
        p->is_remote_control_peer = is_remote_control_peer;
    } else {
        log_error("Too many peers want to talk, ignoring one.");
        nuke_socket(peer);
    }
    return ans;
}

static bool
getpeerid(int fd, uid_t *euid, gid_t *egid) {
#ifdef __linux__
    struct ucred cr;
    socklen_t sz = sizeof(cr);
    if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cr, &sz) != 0) return false;
    *euid = cr.uid; *egid = cr.gid;
#else
    if (getpeereid(fd, euid, egid) != 0) return false;
#endif
    return true;
}


static bool
accept_peer(int listen_fd, bool shutting_down, bool is_remote_control_peer) {
    int peer = accept(listen_fd, NULL, NULL);
    if (UNLIKELY(peer == -1)) {
        if (errno == EINTR) return true;
        if (!shutting_down) perror("accept() on talk socket failed!");
        return false;
    }
    if (verify_peer_uid) {
        uid_t peer_uid; gid_t peer_gid;
        if (!getpeerid(peer, &peer_uid, &peer_gid)) {
            log_error("Denying access to peer because failed to get uid and gid for peer: %d with error: %s", peer, strerror(errno));
            shutdown(peer, SHUT_RDWR);
            safe_close(peer, __FILE__, __LINE__);
            return true;
        }
        if (peer_uid != geteuid()) {
            log_error("Denying access to peer because its uid (%d) does not match our uid (%d)", peer_uid, geteuid());
            shutdown(peer, SHUT_RDWR);
            safe_close(peer, __FILE__, __LINE__);
            return true;
        }
    }
    add_peer(peer, is_remote_control_peer);
    return true;
}

static void
free_peer(Peer *peer) {
    free(peer->read.data); peer->read.data = NULL;
    free(peer->write.data); peer->write.data = NULL;
    if (peer->fd > -1) { nuke_socket(peer->fd); peer->fd = -1; }
}

#define KITTY_CMD_PREFIX "\x1bP@kitty-cmd{"

static void
queue_peer_message(ChildMonitor *self, Peer *peer) {
    talk_mutex(lock);
    ensure_space_for(self, messages, Message, self->messages_count + 16, messages_capacity, 16, true);
    Message *m = self->messages + self->messages_count++;
    memset(m, 0, sizeof(Message));
    if (peer->read.used) {
        m->data = malloc(peer->read.used);
        if (m->data) {
            memcpy(m->data, peer->read.data, peer->read.used);
            m->sz = peer->read.used;
        }
    }
    m->peer_id = peer->id;
    m->is_remote_control_peer = peer->is_remote_control_peer;
    peer->num_of_unresponded_messages_sent_to_main_thread++;
    talk_mutex(unlock);
    wakeup_main_loop();
}

static void
notify_on_peer_removal(ChildMonitor *self, const Peer *p) {
    ensure_space_for(self, messages, Message, self->messages_count + 16, messages_capacity, 16, true);
    Message *m = self->messages + self->messages_count++;
    memset(m, 0, sizeof(Message));
    m->data = strdup("peer_death");
    if (m->data) m->sz = strlen("peer_death");
    m->peer_id = p->id;
    m->is_remote_control_peer = p->id;
}

static bool
has_complete_peer_command(Peer *peer) {
    peer->read.command_end = 0;
    if (peer->read.used > sizeof(KITTY_CMD_PREFIX) && memcmp(peer->read.data, KITTY_CMD_PREFIX, sizeof(KITTY_CMD_PREFIX)-1) == 0) {
        for (size_t i = sizeof(KITTY_CMD_PREFIX)-1; i < peer->read.used - 1; i++) {
            if (peer->read.data[i] == 0x1b && peer->read.data[i+1] == '\\') {
                peer->read.command_end = i + 2;
                break;
            }
        }
    }
    return peer->read.command_end ? true : false;
}


static void
dispatch_peer_command(ChildMonitor *self, Peer *peer) {
    if (peer->read.command_end) {
        size_t used = peer->read.used;
        peer->read.used = peer->read.command_end;
        queue_peer_message(self, peer);
        peer->read.used = used;
        if (peer->read.used > peer->read.command_end) {
            peer->read.used -= peer->read.command_end;
            memmove(peer->read.data, peer->read.data + peer->read.command_end, peer->read.used);
        } else peer->read.used = 0;
        peer->read.command_end = 0;
    }
}

static void
read_from_peer(ChildMonitor *self, Peer *peer) {
#define failed(msg) { log_error("Reading from peer failed: %s", msg); shutdown(peer->fd, SHUT_RD); peer->read.finished = true; return; }
    if (peer->read.used >= peer->read.capacity) {
        if (peer->read.capacity >= 64 * 1024) failed("Ignoring too large message from peer");
        peer->read.capacity = MAX(8192u, peer->read.capacity * 2);
        peer->read.data = realloc(peer->read.data, peer->read.capacity);
        if (!peer->read.data) failed("Out of memory");
    }
    ssize_t n = recv(peer->fd, peer->read.data + peer->read.used, peer->read.capacity - peer->read.used, 0);
    if (n == 0) {
        peer->read.finished = true;
        shutdown(peer->fd, SHUT_RD);
        while (has_complete_peer_command(peer)) dispatch_peer_command(self, peer);
        queue_peer_message(self, peer);
        free(peer->read.data); peer->read.data = NULL;
        peer->read.used = 0; peer->read.capacity = 0;
    } else if (n < 0) {
        if (errno != EINTR) failed(strerror(errno));
    } else {
        peer->read.used += n;
        while (has_complete_peer_command(peer)) dispatch_peer_command(self, peer);
    }
#undef failed
}

static void
write_to_peer(Peer *peer) {
    talk_mutex(lock);
    ssize_t n = send(peer->fd, peer->write.data, peer->write.used, MSG_NOSIGNAL);
    if (n == 0) { log_error("send() to peer failed to send any data"); peer->write.used = 0; peer->write.failed = true; }
    else if (n < 0) {
        if (errno != EINTR) { log_error("write() to peer socket failed with error: %s", strerror(errno)); peer->write.used = 0; peer->write.failed = true; }
    } else {
        if ((size_t)n < peer->write.used) memmove(peer->write.data, peer->write.data + n, peer->write.used - n);
        peer->write.used -= n;
    }
    talk_mutex(unlock);
}

static void
wakeup_talk_loop(bool in_signal_handler) {
    if (talk_thread_started) wakeup_loop(&talk_data.loop_data, in_signal_handler, "talk_loop");
}


static bool
prune_peers(ChildMonitor *self) {
    bool pruned = false;
    for (size_t idx = talk_data.num_peers; idx-- > 0;) {
        Peer *p = talk_data.peers + idx;
        if (p->read.finished && !p->num_of_unresponded_messages_sent_to_main_thread && !p->write.used && !p->waiting_for_async_response) {
            notify_on_peer_removal(self, p);
            free_peer(p);
            remove_i_from_array(talk_data.peers, idx, talk_data.num_peers);
            pruned = true;
        }
    }
    return pruned;
}

static struct {
    size_t num;
    struct { int peer_fd, pipe_fd; } fds[16];
} peers_to_inject = {0};

static bool
add_peer_to_injection_queue(int peer_fd, int pipe_fd) {
    bool added = false;
    talk_mutex(lock);
    if (peers_to_inject.num < arraysz(peers_to_inject.fds)) {
        peers_to_inject.fds[peers_to_inject.num].peer_fd = peer_fd;
        peers_to_inject.fds[peers_to_inject.num].pipe_fd = pipe_fd;
        peers_to_inject.num++;
        added = true;
    }
    talk_mutex(unlock);
    return added;
}

static void
simple_write_to_pipe(int fd, void *data, size_t sz) {
    // write a small amount of data to a pipe handling only EINTR
    while (true) {
        ssize_t ret = write(fd, data, sz);
        if (ret == -1 && errno == EINTR) continue;
        break;
    }
}


static void*
talk_loop(void *data) {
    // The talk thread loop
    ChildMonitor *self = (ChildMonitor*)data;
    set_thread_name("KittyPeerMon");
    // talk_data.loop_data is initialized by the thread that spawns this one, before it is spawned (see inject_peer() and start())
    PollFD fds[PEER_LIMIT + 8] = {{0}};
    size_t num_listen_fds = 0, num_peer_fds = 0;
#define add_listener(which) \
    if (self->which > -1) { \
        fds[num_listen_fds].fd = self->which; fds[num_listen_fds++].events = POLLIN; \
    }
    add_listener(talk_fd); add_listener(listen_fd);
#undef add_listener
    fds[num_listen_fds].fd = talk_data.loop_data.wakeup_read_fd; fds[num_listen_fds++].events = POLLIN;

    while (LIKELY(!self->shutting_down)) {
        num_peer_fds = 0;
        bool need_to_wakup_main_loop = false;
        talk_mutex(lock);
        if (peers_to_inject.num) {
            for (size_t i = 0; i < peers_to_inject.num; i++) {
                id_type added_peer_id = add_peer(peers_to_inject.fds[i].peer_fd, true);
                simple_write_to_pipe(peers_to_inject.fds[i].pipe_fd, &added_peer_id, sizeof(id_type));
                safe_close(peers_to_inject.fds[i].pipe_fd, __FILE__, __LINE__);
            }
            peers_to_inject.num = 0;
        }
        if (talk_data.num_peers > 0) {
            if (prune_peers(self)) need_to_wakup_main_loop = true;
            for (size_t i = 0; i < talk_data.num_peers; i++) {
                Peer *p = talk_data.peers + i;
                if (!p->read.finished || p->write.used) {
                    p->fd_array_idx = num_listen_fds + num_peer_fds++;
                    fds[p->fd_array_idx].fd = p->fd;
                    fds[p->fd_array_idx].revents = 0;
                    int flags = 0;
                    if (!p->read.finished) flags |= POLLIN;
                    if (p->write.used) flags |= POLLOUT;
                    fds[p->fd_array_idx].events = flags;
                } else p->fd_array_idx = 0;
            }
        }
        talk_mutex(unlock);
        if (need_to_wakup_main_loop) wakeup_main_loop();
        for (size_t i = 0; i < num_listen_fds; i++) fds[i].revents = 0;
        int ret = poll(fds, num_listen_fds + num_peer_fds, -1);
        if (ret > 0) {
            for (size_t i = 0; i < num_listen_fds - 1; i++) {
                if (fds[i].revents & POLLIN) {
                    if (!accept_peer(fds[i].fd, self->shutting_down, fds[i].fd == self->listen_fd)) goto end;
                }
            }
            if (fds[num_listen_fds - 1].revents & POLLIN) {
                drain_fd(fds[num_listen_fds - 1].fd);  // wakeup
            }
            for (size_t k = 0; k < talk_data.num_peers; k++) {
                Peer *p = talk_data.peers + k;
                if (p->fd_array_idx) {
                    if (fds[p->fd_array_idx].revents & POLLIN) read_from_peer(self, p);
                    if (fds[p->fd_array_idx].revents & POLLOUT) write_to_peer(p);
                    if (fds[p->fd_array_idx].revents & POLLHUP) {
                        // try to read and write nonetheless these functions will set the failed flags.
                        if (!p->read.finished) read_from_peer(self, p);
                        if (p->write.used) write_to_peer(p);
                    }
                    if (fds[p->fd_array_idx].revents & POLLNVAL) {
                        p->read.finished = true;
                        p->write.failed = true; p->write.used = 0;
                    }
                }
            }
        } else if (ret < 0) { if (errno != EAGAIN && errno != EINTR) perror("poll() on talk fds failed"); }
    }
end:
    free_loop_data(&talk_data.loop_data);
    for (size_t i = 0; i < talk_data.num_peers; i++) free_peer(talk_data.peers + i);
    free(talk_data.peers);
    return 0;
}

static void
send_response_to_peer(id_type peer_id, const char *msg, size_t msg_sz, bool is_async_response) {
    bool wakeup = false;
    talk_mutex(lock);
    for (size_t i = 0; i < talk_data.num_peers; i++) {
        Peer *peer = talk_data.peers + i;
        if (peer->id == peer_id) {
            peer->waiting_for_async_response = is_async_response;
            if (peer->num_of_unresponded_messages_sent_to_main_thread) peer->num_of_unresponded_messages_sent_to_main_thread--;
            if (!peer->write.failed) {
                if (peer->write.capacity - peer->write.used < msg_sz) {
                    void *data = realloc(peer->write.data, peer->write.capacity + msg_sz);
                    if (data) {
                        peer->write.data = data;
                        peer->write.capacity += msg_sz;
                    } else fatal("Out of memory");
                }
                if (msg_sz && msg) {
                    memcpy(peer->write.data + peer->write.used, msg, msg_sz);
                    peer->write.used += msg_sz;
                }
            }
            wakeup = true;
            break;
        }
    }
    talk_mutex(unlock);
    if (wakeup) wakeup_talk_loop(false);
}

// }}}

// Boilerplate {{{
static PyMethodDef methods[] = {
    METHOD(add_child, METH_VARARGS)
    METHOD(inject_peer, METH_O)
    METHOD(needs_write, METH_VARARGS)
    METHOD(start, METH_NOARGS)
    METHOD(wakeup, METH_NOARGS)
    METHOD(shutdown_monitor, METH_NOARGS)
    METHOD(main_loop, METH_NOARGS)
    METHOD(mark_for_close, METH_VARARGS)
    METHOD(resize_pty, METH_VARARGS)
    METHODB(handled_signals, METH_NOARGS),
    {"set_iutf8_winid", (PyCFunction)pyset_iutf8, METH_VARARGS, ""},
    {NULL}  /* Sentinel */
};


PyTypeObject ChildMonitor_Type = {
    PyVarObject_HEAD_INIT(NULL, 0)
    .tp_name = "fast_data_types.ChildMonitor",
    .tp_basicsize = sizeof(ChildMonitor),
    .tp_dealloc = (destructor)dealloc,
    .tp_flags = Py_TPFLAGS_DEFAULT,
    .tp_doc = "ChildMonitor",
    .tp_methods = methods,
    .tp_new = new_childmonitor_object,
};



static PyObject*
safe_pipe(PyObject *self UNUSED, PyObject *args) {
    int nonblock = 1;
    if (!PyArg_ParseTuple(args, "|p", &nonblock)) return NULL;
    int fds[2] = {0};
    if (!self_pipe(fds, nonblock)) return PyErr_SetFromErrno(PyExc_OSError);
    return Py_BuildValue("ii", fds[0], fds[1]);
}

static PyObject*
cocoa_set_menubar_title(PyObject *self UNUSED, PyObject *args UNUSED) {
#ifdef __APPLE__
    PyObject *title = NULL;
    if (!PyArg_ParseTuple(args, "U", &title)) return NULL;
    change_menubar_title(title);
#endif
    Py_RETURN_NONE;
}

static PyObject*
send_data_to_peer(PyObject *self UNUSED, PyObject *args) {
    char * msg; Py_ssize_t sz;
    unsigned long long peer_id;
    int is_async_response = 0;
    if (!PyArg_ParseTuple(args, "Ks#|p", &peer_id, &msg, &sz, &is_async_response)) return NULL;
    send_response_to_peer(peer_id, msg, sz, is_async_response);
    Py_RETURN_NONE;
}

static PyMethodDef module_methods[] = {
    METHODB(safe_pipe, METH_VARARGS),
    {"add_timer", (PyCFunction)add_python_timer, METH_VARARGS, ""},
    {"remove_timer", (PyCFunction)remove_python_timer, METH_VARARGS, ""},
    METHODB(monitor_pid, METH_VARARGS),
    METHODB(send_data_to_peer, METH_VARARGS),
    METHODB(cocoa_set_menubar_title, METH_VARARGS),
    METHODB(mask_kitty_signals_process_wide, METH_NOARGS),
    {"sigqueue", (PyCFunction)sig_queue, METH_VARARGS, ""},
    {NULL}  /* Sentinel */
};

bool
init_child_monitor(PyObject *module) {
    if (PyType_Ready(&ChildMonitor_Type) < 0) return false;
    if (PyModule_AddObject(module, "ChildMonitor", (PyObject *)&ChildMonitor_Type) != 0) return false;
    Py_INCREF(&ChildMonitor_Type);
    if (PyModule_AddFunctions(module, module_methods) != 0) return false;
#ifdef NO_SIGQUEUE
    PyModule_AddIntConstant(module, "has_sigqueue", 0);
#else
    PyModule_AddIntConstant(module, "has_sigqueue", 1);
#endif
    return true;
}

// }}}
