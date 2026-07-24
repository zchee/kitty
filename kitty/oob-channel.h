/*
 * oob-channel.h
 * Copyright (C) 2026 Kovid Goyal <kovid at kovidgoyal.net>
 *
 * Distributed under terms of the GPL3 license.
 */

// R3: out-of-band bulk channel — a kitty-provided socketpair that lets a
// cooperating full-screen app (opt-in at both ends) send its bulk TUI
// byte stream past the 1024-byte kernel pty queue. Each channel owns a
// blocking reader thread that is the sole SPSC producer for a dedicated
// second VTInputRing; the sole consumer is the main-thread parse tick,
// which drains it into the same parse arena as the pty ring (vt-parser.c),
// so the pty ingestion path and its invariants are untouched. Control,
// queries, input, signals and winsize all stay on the pty.

#pragma once

#include "data-types.h"
#include "vt-input-ring.h"

typedef struct OOBChannel OOBChannel;

// ---- consumer-side hooks (main thread only; used by vt-parser.c) ----

// The channel's transport ring (no side effects).
VTInputRing* oob_channel_ring(OOBChannel *c);

// Drain entry: clears the coalesced-wakeup flag BEFORE the caller's head
// load (W22-O2-style clear-before-drain bracketing) and returns the ring.
// A commit the ensuing drain misses is guaranteed to raise a fresh
// wakeup_main_loop().
VTInputRing* oob_channel_drain_ring(OOBChannel *c);

// Once per parse tick after every tail advance the tick will make: wake a
// producer parked on the full ring (the vt-input-ring FR-2 protocol,
// delivered over this channel's mutex/condvar pair).
void oob_channel_after_drain(OOBChannel *c);

bool init_oob_channel(PyObject *module);
