/*
 * Copyright (C) 2018 Kovid Goyal <kovid at kovidgoyal.net>
 *
 * Distributed under terms of the GPL3 license.
 */

#pragma once

#include <stdio.h>
#include <pthread.h>
#if defined(__FreeBSD__) || defined(__OpenBSD__)
#define FREEBSD_SET_NAME
#endif
#if defined(__APPLE__)
// I can't figure out how to get pthread.h to include this definition on macOS. MACOSX_DEPLOYMENT_TARGET does not work.
extern int pthread_setname_np(const char *name);
#elif defined(FREEBSD_SET_NAME)
// Function has a different name on FreeBSD
void pthread_set_name_np(pthread_t tid, const char *name);
#else
// Need _GNU_SOURCE for pthread_setname_np on linux and that causes other issues on systems with old glibc
extern int pthread_setname_np(pthread_t, const char *name);
#endif

static inline void
set_thread_name(const char *name) {
    int ret;
#if defined(__APPLE__)
    ret = pthread_setname_np(name);
#elif defined(FREEBSD_SET_NAME)
    pthread_set_name_np(pthread_self(), name);
    ret = 0;
#else
    ret = pthread_setname_np(pthread_self(), name);
#endif
    if (ret != 0) perror("Failed to set thread name");
}

#if defined(__APPLE__)
#include <pthread/qos.h>
#include <stdlib.h>
#include <string.h>
#endif

// R4 M1d: per-thread QoS *probe* (no class is assigned anywhere). Under
// KITTY_QOS_DEBUG=1 each instrumented thread head logs the class it
// inherited plus its relative priority — the census that makes a future
// assignment wave (R5) decidable, since pthread_create inherits the
// creator's class and process-wide rusage cannot see per-thread state.
// Plain getenv (process environment only); zero behavior when unset.
static inline void
report_thread_qos(const char *name) {
#if defined(__APPLE__)
    const char *v = getenv("KITTY_QOS_DEBUG");
    if (!v || !v[0] || strcmp(v, "0") == 0) return;
    qos_class_t qc = QOS_CLASS_UNSPECIFIED; int rel = 0;
    if (pthread_get_qos_class_np(pthread_self(), &qc, &rel) != 0) {
        fprintf(stderr, "qos_probe: thread=%s error=pthread_get_qos_class_np\n", name);
        return;
    }
    const char *qs;
    switch (qc) {
        case QOS_CLASS_USER_INTERACTIVE: qs = "user_interactive"; break;
        case QOS_CLASS_USER_INITIATED: qs = "user_initiated"; break;
        case QOS_CLASS_DEFAULT: qs = "default"; break;
        case QOS_CLASS_UTILITY: qs = "utility"; break;
        case QOS_CLASS_BACKGROUND: qs = "background"; break;
        default: qs = "unspecified"; break;
    }
    fprintf(stderr, "qos_probe: thread=%s qos=%s relpri=%d\n", name, qs, rel);
#else
    (void)name;
#endif
}
