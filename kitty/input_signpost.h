/*
 * input_signpost.h
 * Copyright (C) 2026 Kovid Goyal <kovid at kovidgoyal.net>
 *
 * Distributed under terms of the GPL3 license.
 */

// W28.1 S1 split: stamps along the keystroke path, so a quiet-gated typing
// block can answer where S1 (inject -> key visible) actually goes. The block's
// question is how much of it is WindowServer/HID delivery outside kitty versus
// the per-keystroke Python dispatch inside it, and that cannot be answered from
// aggregate S1 -- only from the boundaries between them.
//
// The stamps are:
//     key_down_entry            AppKit handed us the event (glfw keyDown:)
//     key_dispatch              interval around the Python dispatch
//     key_to_child_*            the keystroke's bytes were scheduled to the pty
//
// so the harness pairs its own CGEventPost timestamp with key_down_entry to get
// the OS-side share, and reads the key_dispatch interval for the in-process
// Python cost the plan's feasibility clause turns on.
//
// NOT stamped: fake_scroll()'s schedule_write_to_child calls. Those synthesize
// scroll events and never carry a keystroke, so stamping them would put
// non-keystroke samples into a keystroke measurement.

#pragma once

#ifdef __APPLE__

#include <os/signpost.h>
#include <stdbool.h>
#include <stdlib.h>   // getenv
#include <string.h>   // strcmp

// Same subsystem as the Metal and child-monitor instrumentation so one filter
// catches all of kitty, but its own CATEGORY so the keystroke lane can be read
// without the per-frame render spans burying it.
static inline os_log_t
input_signpost_log(void) {
    static os_log_t handle;
    if (!handle) handle = os_log_create("net.kovidgoyal.kitty", "input");
    return handle;
}

// MEASURED, not assumed: os_signpost_enabled() returns TRUE on this system with
// no tracer attached, and an emit then costs ~310 ns (200k-iteration loop,
// macOS 27.0, M3 Max, 2026-07-31). Signposts go to the unified logging buffer
// whether or not anyone is collecting, so "free unless traced" is simply not a
// property this API has here. Four stamps on the keystroke path would therefore
// add ~1.2 us to EVERY keypress in a normal build -- negligible against S1's
// millisecond scale, but a real unconditional cost on the hot input path, paid
// by every user forever to serve one measurement block.
//
// Hence the env gate, matching the KITTY_METAL_SIGNPOST convention already used
// for the render spans: off, each stamp is one cached-int test. The risk an env
// gate introduces -- a harness that forgets to set it and captures nothing --
// is handled where it belongs, by the evidence-capability gate: a capture with
// zero stamps is VOID, not a quiet pass.
static inline bool
input_signpost_enabled(void) {
    static int state = -1;
    if (state < 0) {
        const char *v = getenv("KITTY_INPUT_SIGNPOST");
        state = (v && v[0] && strcmp(v, "0") != 0) ? 1 : 0;
    }
    return state == 1;
}
// The trailing "" on every os_signpost_* call is REQUIRED, not decorative:
// they are variadic macros, and omitting the vararg is a C23 extension this
// build rejects under -Werror. child-monitor.c and metal.m pass it for the
// same reason.
#define INPUT_SIGNPOST_EVENT(name) do { \
    if (input_signpost_enabled()) { \
        os_log_t _isp_log = input_signpost_log(); \
        os_signpost_event_emit(_isp_log, OS_SIGNPOST_ID_EXCLUSIVE, name, ""); \
    } \
} while (0)

// Intervals use OS_SIGNPOST_ID_EXCLUSIVE: every one of these is opened and
// closed on the main thread inside a single call, so no two are ever in flight
// at once and there is nothing to disambiguate.
#define INPUT_SIGNPOST_INTERVAL_BEGIN(name) do { \
    if (input_signpost_enabled()) { \
        os_log_t _isp_log = input_signpost_log(); \
        os_signpost_interval_begin(_isp_log, OS_SIGNPOST_ID_EXCLUSIVE, name, ""); \
    } \
} while (0)

#define INPUT_SIGNPOST_INTERVAL_END(name) do { \
    if (input_signpost_enabled()) { \
        os_log_t _isp_log = input_signpost_log(); \
        os_signpost_interval_end(_isp_log, OS_SIGNPOST_ID_EXCLUSIVE, name, ""); \
    } \
} while (0)

#else

// Non-Apple builds: the whole facility compiles out. os_signpost is a Darwin
// API and S1 is a macOS question.
#define INPUT_SIGNPOST_EVENT(name) ((void)0)
#define INPUT_SIGNPOST_INTERVAL_BEGIN(name) ((void)0)
#define INPUT_SIGNPOST_INTERVAL_END(name) ((void)0)

#endif
