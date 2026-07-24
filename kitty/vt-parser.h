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
    // Wave-21 L4: pause-snapshot COW probe (KITTY_PAUSE_SNAPSHOT_COW; zero when off)
    unsigned cow_copied;        // snapshot rows deep-copied this tick
    unsigned cow_skip_eligible; // snapshot rows whose identity key matched this tick
    // Wave-25 Lane S (KITTY_PAUSE_SNAPSHOT_SHARE; zero when off): per-tick
    // diffs of the process-cumulative share counters (line-buf.h) -- realized
    // R = (sum ref - sum retires) / sum total across a measurement block.
    unsigned share_rows_total;  // snapshot rows processed at BSU this tick (grid + history)
    unsigned share_rows_ref;    // grid rows acquired by reference this tick
    unsigned share_cow_retires; // COW retire copies paid this tick
    // R3: bytes merged from the out-of-band bulk channel's ring into the
    // parse arena this tick (a subset of bytes_read; 0 when no channel).
    size_t oob_bytes_read;
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
// R3 out-of-band bulk channel backlink (main thread only): the channel's
// ring is a second SPSC transport drained into the same parse arena as
// the pty ring by the main-thread parse tick.
struct OOBChannel;
void vt_parser_set_oob_channel(Parser*, struct OOBChannel*);
struct OOBChannel* vt_parser_oob_channel(const Parser*);
void parse_worker(void *p, ParseData *data, bool flush);
void parse_worker_dump(void *p, ParseData *data, bool flush);
