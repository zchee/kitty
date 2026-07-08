/*
 * Copyright (C) 2023 Kovid Goyal <kovid at kovidgoyal.net>
 *
 * Distributed under terms of the GPL3 license.
 */

#pragma once

#include "data-types.h"

typedef struct { int x; } PARSER_STATE_HANDLE;

typedef struct Parser {
    PyObject_HEAD

    PARSER_STATE_HANDLE *state;
} Parser;

typedef struct ParseData {
    PyObject *dump_callback;
    monotonic_t now;

    bool input_read, write_space_created, has_pending_input;
    monotonic_t time_since_new_input;
    size_t bytes_read;  // bytes advanced out of the transport ring into the parse arena this parse (throughput probe)

    // Wave-19 L4: DECSET-2026 pause/drain decomposition probe. Always
    // populated (cheap per-tick bookkeeping, not per-byte) so KITTY_FRAME_TRACE
    // can report tick shape without a rebuild; the child-monitor.c emitter
    // remains the sole env-var-gated (zero-cost-when-off) consumer.
    size_t parsed_bytes;      // bytes actually consumed out of the arena this tick (0 if not admitted)
    size_t arena_fill_start;  // unparsed bytes already resident in the arena at tick entry
    size_t arena_fill_end;    // unparsed bytes resident in the arena at tick exit
    size_t ring_fill_start;   // transport ring bytes-used at tick entry
    size_t ring_fill_end;     // transport ring bytes-used at tick exit
    unsigned pause_starts;    // successful screen_pause_rendering(true) (BSU) calls this tick
    unsigned pause_stops;     // successful screen_pause_rendering(false) (ESU) calls this tick
} ParseData;

// The must only be called on the main thread
Parser* alloc_vt_parser(id_type window_id);
void free_vt_parser(Parser*);
void reset_vt_parser(Parser*);


// SPSC transport contract (no internal lock): the three producer calls
// below are for the io thread only — a single producer feeding the
// lock-free ring in vt-input-ring.h; parse_worker/parse_worker_dump run
// on the main thread as the single consumer
uint8_t* vt_parser_create_write_buffer(Parser*, size_t*);
void vt_parser_commit_write(Parser*, size_t);
bool vt_parser_arm_pollin(const Parser*);
size_t vt_parser_ring_free_total(const Parser*);
void parse_worker(void *p, ParseData *data, bool flush);
void parse_worker_dump(void *p, ParseData *data, bool flush);
