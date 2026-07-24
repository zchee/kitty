/*
 * pump.c
 * Copyright (C) 2026 Kovid Goyal <kovid at kovidgoyal.net>
 *
 * Distributed under terms of the GPL3 license.
 *
 * kitty-pump: forward bytes from fd 0 to fd 1 until EOF.
 *
 * The KITTY_PTY_PUMP helper (Plan A, .omc/plans/plan-2026-07-24-pty-pump-
 * ingestion-r1r2.md): spawned per child with stdin = the pty master
 * (blocking) and stdout = a pipe to kitty's io thread. macOS allocates every
 * tty output queue as a flat 1024-byte buffer (XNU ttymalloc, TTYCLSIZE), so
 * draining a flooding child costs one scheduler round-trip per KiB; this
 * process pays that ping-pong in isolation while kitty wakes per ~16-64 KiB
 * pipe batch (S0-v2 gate: 13.2x MB/s, 13.7x bytes/wakeup at 100us consumer
 * dwell).
 *
 * Exit status: 0 on clean stream end (EOF, pty EIO after the session leader
 * exits, or consumer EPIPE), 1 on any unexpected errno.
 */
#include <errno.h>
#include <signal.h>
#include <stdbool.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <sys/select.h>
#include <unistd.h>

// O_NONBLOCK lives on the shared open file description: kitty sets the pty
// master non-blocking for its own write path, which makes this process's
// fd 0 non-blocking too. EAGAIN therefore parks in select() and retries —
// the wait cost stays inside the pump, which is the whole point.
static void
wait_for(int fd, bool for_write) {
    fd_set s;
    FD_ZERO(&s);
    FD_SET(fd, &s);
    select(fd + 1, for_write ? NULL : &s, for_write ? &s : NULL, NULL, NULL);
}

int
main(void) {
    signal(SIGPIPE, SIG_IGN);
    static char buf[65536];
    const bool dbg = getenv("KITTY_PUMP_DEBUG") != NULL;
    if (dbg) fprintf(stderr, "kitty-pump: started\n");
    for (;;) {
        const ssize_t n = read(0, buf, sizeof(buf));
        if (dbg) fprintf(stderr, "kitty-pump: read %zd (errno=%d)\n", n, n < 0 ? errno : 0);
        if (n == 0) return 0;
        if (n < 0) {
            if (errno == EINTR) continue;
            if (errno == EAGAIN || errno == EWOULDBLOCK) { wait_for(0, false); continue; }
            if (errno == EIO) return 0;
            fprintf(stderr, "kitty-pump: read: %s\n", strerror(errno));
            return 1;
        }
        for (ssize_t off = 0; off < n;) {
            const ssize_t w = write(1, buf + off, (size_t)(n - off));
            if (w < 0) {
                if (errno == EINTR) continue;
                if (errno == EAGAIN || errno == EWOULDBLOCK) { wait_for(1, true); continue; }
                if (errno == EPIPE) return 0;
                fprintf(stderr, "kitty-pump: write: %s\n", strerror(errno));
                return 1;
            }
            off += w;
        }
    }
}
