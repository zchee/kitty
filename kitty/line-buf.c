/*
 * line-buf.c
 * Copyright (C) 2016 Kovid Goyal <kovid at kovidgoyal.net>
 *
 * Distributed under terms of the GPL3 license.
 */

#include "data-types.h"
#include "lineops.h"
#include "resize.h"

#include <structmember.h>

extern PyTypeObject Line_Type;
extern PyTypeObject HistoryBuf_Type;

// Line-slot pool (line-pool.h): slab storage with stable addresses shared
// between a LineBuf and its HistoryBuf so scroll moves slot ids, not cells.

LineSlotPool*
line_slot_pool_alloc(index_type xnum, index_type slab_capacity) {
    LineSlotPool *pool = calloc(1, sizeof(LineSlotPool));
    if (!pool) return NULL;
    pool->xnum = xnum; pool->refcnt = 1;
    // round up to a power of two: the hot lineptr math becomes
    // shift+mask (a runtime division here cost ~2% draw throughput)
    index_type cap = 1; uint8_t shift = 0;
    while (cap < MAX(1u, slab_capacity)) { cap <<= 1; shift++; }
    pool->slab_capacity = cap; pool->slab_shift = shift; pool->slab_mask = cap - 1;
    return pool;
}

void
line_slot_pool_incref(LineSlotPool *pool) { if (pool) pool->refcnt++; }

void
line_slot_pool_decref(LineSlotPool *pool) {
    if (!pool || --pool->refcnt) return;
    for (size_t i = 0; i < pool->num_slabs; i++) free(pool->slabs[i].mem);
    free(pool->slabs);
    free(pool);
}

static bool
pool_add_slab(LineSlotPool *pool) {
    LineSlotSlab *slabs = realloc(pool->slabs, sizeof(LineSlotSlab) * (pool->num_slabs + 1));
    if (!slabs) return false;
    pool->slabs = slabs;
    const size_t cpu_sz = (size_t)pool->xnum * pool->slab_capacity * sizeof(CPUCell);
    const size_t gpu_sz = (size_t)pool->xnum * pool->slab_capacity * sizeof(GPUCell);
    void *mem = calloc(1, cpu_sz + gpu_sz);
    if (!mem) return false;
    LineSlotSlab *s = pool->slabs + pool->num_slabs;
    s->mem = mem; s->cpu = mem; s->gpu = (GPUCell*)((uint8_t*)mem + cpu_sz);
    pool->num_slabs++;
    return true;
}

index_type
line_slot_pool_take(LineSlotPool *pool) {
    if (pool->slots_used >= pool->num_slabs * pool->slab_capacity) {
        if (!pool_add_slab(pool)) fatal("Out of memory allocating a line-slot slab");
    }
    return (index_type)pool->slots_used++;
}

static CPUCell*
cpu_lineptr(LineBuf *linebuf, index_type y) {
    return pool_cpu_lineptr(linebuf->pool, y);
}

static GPUCell*
gpu_lineptr(LineBuf *linebuf, index_type y) {
    return pool_gpu_lineptr(linebuf->pool, y);
}

static void
clear_chars_to(LineBuf* linebuf, index_type y, char_type ch) {
    clear_chars_in_line(cpu_lineptr(linebuf, y), gpu_lineptr(linebuf, y), linebuf->xnum, ch);
}

void
linebuf_clear(LineBuf *self, char_type ch) {
    linebuf_gen_bump_range(self, 0, self->ynum - 1);  // Wave-21 L4: every row's content changes
    // per-line via line_map: slot assignments are preserved, only the
    // content is cleared (cell storage is pool slots, not one block)
    for (index_type i = 0; i < self->ynum; i++) {
        const index_type slot = self->line_map[i];
        zero_at_ptr_count(cpu_lineptr(self, slot), self->xnum);
        zero_at_ptr_count(gpu_lineptr(self, slot), self->xnum);
    }
    zero_at_ptr_count(self->line_attrs, self->ynum);
    if (ch != 0) {
        for (index_type i = 0; i < self->ynum; i++) {
            clear_chars_to(self, self->line_map[i], ch);
            self->line_attrs[i].val = 0;
            self->line_attrs[i].has_dirty_text = true;
        }
    }
}

void
linebuf_mark_line_dirty(LineBuf *self, index_type y) {
    const index_type p = lb_phys(self, y);
    self->line_attrs[p].has_dirty_text = true;
    linebuf_gen_bump(self, p);  // Wave-21 L4: co-located with the dirty mark
}

void
linebuf_mark_line_clean(LineBuf *self, index_type y) {
    self->line_attrs[lb_phys(self, y)].has_dirty_text = false;
}

void
linebuf_set_line_has_image_placeholders(LineBuf *self, index_type y, bool val) {
    const index_type p = lb_phys(self, y);
    self->line_attrs[p].has_image_placeholders = val;
    linebuf_gen_bump(self, p);  // Wave-21 L4: attr change without a dirty mark
}

void
linebuf_clear_attrs_and_dirty(LineBuf *self, index_type y) {
    const index_type p = lb_phys(self, y);
    self->line_attrs[p].val = 0;
    self->line_attrs[p].has_dirty_text = true;
    linebuf_gen_bump(self, p);  // Wave-21 L4
}

static PyObject*
clear(LineBuf *self, PyObject *a UNUSED) {
#define clear_doc "Clear all lines in this LineBuf"
    linebuf_clear(self, BLANK_CHAR);
    Py_RETURN_NONE;
}

// Wave-21 L4: allocation serials are 1-based (0 = the snapshot's
// never-matches sentinel). Main-thread only, like all LineBuf allocation.
static uint32_t linebuf_serial_counter = 0;

LineBuf *
alloc_linebuf_(PyTypeObject *cls, unsigned int lines, unsigned int columns, TextCache *text_cache, LineSlotPool *pool) {
    if (columns > 5000 || lines > 50000) {
        PyErr_SetString(PyExc_ValueError, "Number of rows or columns is too large.");
        return NULL;
    }

    const size_t area = columns * lines;
    if (area == 0) {
        PyErr_SetString(PyExc_ValueError, "Cannot create an empty LineBuf");
        return NULL;
    }

    LineBuf *self = (LineBuf*)cls->tp_alloc(cls, 0);
    if (self != NULL) {
        self->xnum = columns;
        self->ynum = lines;
        self->head = 0;  // S3: line_map/line_attrs start un-rotated
        // Cell storage lives in the slot pool; a private pool's slab is
        // sized exactly for this container, while a shared pool (with the
        // paired HistoryBuf, for the slot handover on scroll) uses
        // history-segment-sized slabs and grows with scrollback.
        if (pool) { line_slot_pool_incref(pool); self->pool = pool; }
        else self->pool = line_slot_pool_alloc(columns, lines);
        // Combined allocation: 4-byte lanes first (4-byte aligned), the
        // 1-byte LineAttrs last -> line_map | scratch | line_xlimit | gen_at_pos
        // | line_attrs. line_xlimit (Wave-15 L1) and gen_at_pos (Wave-21 L4,
        // repurposed by Wave-24 D0) precede line_attrs so the 4-byte arrays
        // stay aligned for any `lines` (a trailing 4-byte lane after the
        // 1-byte LineAttrs lane would misalign unless lines%4==0).
        _Static_assert(sizeof(index_type) == sizeof(uint32_t), "gen_at_pos lane sizing assumes 4-byte index_type");
        self->line_map = self->pool ? PyMem_Calloc(1, lines * (4 * sizeof(index_type) + sizeof(LineAttrs))) : NULL;
        if (!self->line_map) { line_slot_pool_decref(self->pool); self->pool = NULL; Py_CLEAR(self); return NULL; }
        self->scratch = self->line_map + lines;
        self->line_xlimit = self->scratch + lines;
        self->gen_at_pos = (uint32_t*)(self->line_xlimit + lines);
        self->line_attrs = (LineAttrs*)(self->gen_at_pos + lines);
        self->serial = ++linebuf_serial_counter;  // Wave-21 L4: 1-based; 0 = never-matches sentinel
        self->text_cache = tc_incref(text_cache);
        self->line = alloc_line(self->text_cache);
        self->line->xnum = columns;
        for(index_type i = 0; i < lines; i++) {
            self->line_map[i] = line_slot_pool_take(self->pool);
            if (BLANK_CHAR != 0) clear_chars_to(self, self->line_map[i], BLANK_CHAR);
        }
    }
    return self;
}

static PyObject *
new_linebuf_object(PyTypeObject *type, PyObject *args, PyObject UNUSED *kwds) {
    unsigned int xnum = 1, ynum = 1;

    if (!PyArg_ParseTuple(args, "II", &ynum, &xnum)) return NULL;
    TextCache *tc = tc_alloc();
    if (!tc) return PyErr_NoMemory();
    PyObject *ans = (PyObject*)alloc_linebuf_(type, ynum, xnum, tc, NULL);
    tc_decref(tc);
    return ans;
}

static void
dealloc(LineBuf* self) {
    self->text_cache = tc_decref(self->text_cache);
    PyMem_Free(self->line_map);
    line_slot_pool_decref(self->pool);
    Py_CLEAR(self->line);
    Py_TYPE(self)->tp_free((PyObject*)self);
}

void
linebuf_init_cells(LineBuf *lb, index_type idx, CPUCell **c, GPUCell **g) {
    // S1 (Phase 13B): callers fetch these pointers to WRITE GPUCells (draw
    // run-fills, multicell, char shifts), so materialize any deferred clear.
    linebuf_materialize_blank(lb, idx);
    const index_type p = lb_phys(lb, idx);
    // Wave-15 L1: this (tracking) variant is used by in-place mutators (IRM
    // insert/delete shift, multicell nuke/halve, colored-blank) whose extent the
    // append-draw notes do not describe. Mark a deferred row UNTRACKED so
    // linebuf_finalize_hwm_line rescans it (rare; never the scroll flood, which
    // uses linebuf_init_cells_notrack and records the exact extent).
    if (lb->line_attrs[p].is_blank) lb->line_xlimit[p] = XLIMIT_UNTRACKED;
    const index_type ynum = lb->line_map[p];
    *c = cpu_lineptr(lb, ynum);
    *g = gpu_lineptr(lb, ynum);
}

void
linebuf_init_cells_notrack(LineBuf *lb, index_type idx, CPUCell **c, GPUCell **g) {
    // Wave-15 L1: the append-draw path's cell fetch. Identical to
    // linebuf_init_cells but WITHOUT the UNTRACKED mark -- the caller records the
    // exact write extent via linebuf_note_write_extent, keeping finalize O(1).
    linebuf_materialize_blank(lb, idx);
    const index_type ynum = lb->line_map[lb_phys(lb, idx)];
    *c = cpu_lineptr(lb, ynum);
    *g = gpu_lineptr(lb, ynum);
}

CPUCell*
linebuf_cpu_cells_for_line(LineBuf *lb, index_type idx) {
    const index_type ynum = lb->line_map[lb_phys(lb, idx)];
    return cpu_lineptr(lb, ynum);
}

static void
init_line(LineBuf *lb, Line *l, index_type ynum) {
    l->cpu_cells = cpu_lineptr(lb, ynum);
    l->gpu_cells = gpu_lineptr(lb, ynum);
}

void
linebuf_init_line_at(LineBuf *self, index_type idx, Line *line) {
    line->ynum = idx;
    line->xnum = self->xnum;
    line->attrs = self->line_attrs[lb_phys(self, idx)];
    init_line(self, line, self->line_map[lb_phys(self, idx)]);
}

void
linebuf_init_line(LineBuf *self, index_type idx) {
    // S1 (Phase 13B): the idx-only wrapper feeds GPUCell writers (SGR-region
    // apply, insert/delete/erase-char cursor fills) and direct GPUCell readers,
    // so materialize any deferred clear here. The explicit-Line variant
    // (linebuf_init_line_at) stays pure so the render path can peek is_blank and
    // emit blank_diff with the deferred GPUCells left untouched.
    linebuf_make_authoritative(self, idx);
    linebuf_init_line_at(self, idx, self->line);
}

void
linebuf_clear_lines(LineBuf *self, const Cursor *cursor, index_type start, index_type end) {
#if BLANK_CHAR != 0
#error This implementation is incorrect for BLANK_CHAR != 0
#endif
#define lineptr(which, i) which##_lineptr(self, self->line_map[lb_phys(self, i)])
    GPUCell *first_gpu_line = lineptr(gpu, start);
    const GPUCell gc = cursor_as_gpu_cell(cursor);
    memset_array(first_gpu_line, gc, self->xnum);
    const size_t cpu_stride = sizeof(CPUCell) * self->xnum;
    memset(lineptr(cpu, start), 0, cpu_stride);
    const size_t gpu_stride = sizeof(GPUCell) * self->xnum;
    linebuf_clear_attrs_and_dirty(self, start);
    for (index_type i = start + 1; i < end; i++) {
        memset(lineptr(cpu, i), 0, cpu_stride);
        memcpy(lineptr(gpu, i), first_gpu_line, gpu_stride);
        linebuf_clear_attrs_and_dirty(self, i);
    }
#undef lineptr
}

static PyObject*
line(LineBuf *self, PyObject *y) {
#define line_doc      "Return the specified line as a Line object. Note the Line Object is a live view into the underlying buffer. And only a single line object can be used at a time."
    unsigned long idx = PyLong_AsUnsignedLong(y);
    if (idx >= self->ynum) {
        PyErr_SetString(PyExc_IndexError, "Line number too large");
        return NULL;
    }
    linebuf_init_line(self, idx);
    Py_INCREF(self->line);
    return (PyObject*)self->line;
}

CPUCell*
linebuf_cpu_cell_at(LineBuf *self, index_type x, index_type y) {
    return &cpu_lineptr(self, self->line_map[lb_phys(self, y)])[x];
}

bool
linebuf_line_ends_with_continuation(LineBuf *self, index_type y) {
    return y < self->ynum ? cpu_lineptr(self, self->line_map[lb_phys(self, y)])[self->xnum - 1].next_char_was_wrapped : false;
}

void
linebuf_set_last_char_as_continuation(LineBuf *self, index_type y, bool continued) {
    if (y < self->ynum) {
        const index_type p = lb_phys(self, y);
        cpu_lineptr(self, self->line_map[p])[self->xnum - 1].next_char_was_wrapped = continued;
        linebuf_gen_bump(self, p);  // Wave-21 L4: cell mutation without a dirty mark
    }
}


static PyObject*
set_attribute(LineBuf *self, PyObject *args) {
#define set_attribute_doc "set_attribute(which, val) -> Set the attribute on all cells in the line."
    unsigned int val;
    char *which;
    if (!PyArg_ParseTuple(args, "sI", &which, &val)) return NULL;
    for (index_type y = 0; y < self->ynum; y++) {
        if (!set_named_attribute_on_line(gpu_lineptr(self, self->line_map[y]), which, val, self->xnum)) {
            PyErr_SetString(PyExc_KeyError, "Unknown cell attribute"); return NULL;
        }
        self->line_attrs[y].has_dirty_text = true;
        linebuf_gen_bump(self, y);  // Wave-21 L4 (order-agnostic full-row loop)
    }
    Py_RETURN_NONE;
}

static PyObject*
set_continued(LineBuf *self, PyObject *args) {
#define set_continued_doc "set_continued(y, val) -> Set the continued values for the specified line."
    unsigned int y;
    int val;
    if (!PyArg_ParseTuple(args, "Ip", &y, &val)) return NULL;
    if (y > self->ynum || y < 1) { PyErr_SetString(PyExc_ValueError, "Out of bounds."); return NULL; }
    linebuf_set_last_char_as_continuation(self, y-1, val);
    Py_RETURN_NONE;
}

static PyObject*
dirty_lines(LineBuf *self, PyObject *a UNUSED) {
#define dirty_lines_doc "dirty_lines() -> Line numbers of all lines that have dirty text."
    PyObject *ans = PyList_New(0);
    for (index_type i = 0; i < self->ynum; i++) {
        if (self->line_attrs[lb_phys(self, i)].has_dirty_text) {
            PyList_Append(ans, PyLong_FromUnsignedLong(i));
        }
    }
    return ans;
}

static bool
allocate_line_storage(Line *line, bool initialize) {
    if (initialize) {
        line->cpu_cells = PyMem_Calloc(line->xnum, sizeof(CPUCell));
        line->gpu_cells = PyMem_Calloc(line->xnum, sizeof(GPUCell));
        if (line->cpu_cells == NULL || line->gpu_cells == NULL) { PyErr_NoMemory(); return false; }
        if (BLANK_CHAR != 0) clear_chars_in_line(line->cpu_cells, line->gpu_cells, line->xnum, BLANK_CHAR);
    } else {
        line->cpu_cells = PyMem_Malloc(line->xnum * sizeof(CPUCell));
        line->gpu_cells = PyMem_Malloc(line->xnum * sizeof(GPUCell));
        if (line->cpu_cells == NULL || line->gpu_cells == NULL) { PyErr_NoMemory(); return false; }
    }
    line->needs_free = 1;
    return true;
}

static PyObject*
create_line_copy_inner(LineBuf* self, index_type y) {
    Line src, *line;
    line = alloc_line(self->text_cache);
    if (line == NULL) return PyErr_NoMemory();
    src.xnum = self->xnum; line->xnum = self->xnum;
    if (!allocate_line_storage(line, 0)) { Py_CLEAR(line); return PyErr_NoMemory(); }
    line->ynum = y;
    line->attrs = self->line_attrs[lb_phys(self, y)];
    init_line(self, &src, self->line_map[lb_phys(self, y)]);
    copy_line(&src, line);
    return (PyObject*)line;
}

static PyObject*
create_line_copy(LineBuf *self, PyObject *ynum) {
#define create_line_copy_doc "Create a new Line object that is a copy of the line at ynum. Note that this line has its own copy of the data and does not refer to the data in the LineBuf."
    index_type y = (index_type)PyLong_AsUnsignedLong(ynum);
    if (y >= self->ynum) { PyErr_SetString(PyExc_ValueError, "Out of bounds"); return NULL; }
    return create_line_copy_inner(self, y);
}

static PyObject*
copy_line_to(LineBuf *self, PyObject *args) {
#define copy_line_to_doc "Copy the line at ynum to the provided line object."
    unsigned int y;
    Line src, *dest;
    if (!PyArg_ParseTuple(args, "IO!", &y, &Line_Type, &dest)) return NULL;
    if (y >= self->ynum) { PyErr_SetString(PyExc_IndexError, "Out of bounds"); return NULL; }
    src.xnum = self->xnum; dest->xnum = self->xnum;
    dest->ynum = y;
    dest->attrs = self->line_attrs[lb_phys(self, y)];
    init_line(self, &src, self->line_map[lb_phys(self, y)]);
    copy_line(&src, dest);
    Py_RETURN_NONE;
}

static void
clear_line_(Line *l, index_type xnum) {
#if BLANK_CHAR != 0
#error This implementation is incorrect for BLANK_CHAR != 0
#endif
    zero_at_ptr_count(l->cpu_cells, xnum);
    zero_at_ptr_count(l->gpu_cells, xnum);
    l->attrs.has_dirty_text = false;
}

// S1/S2 (Phase 13B): the recycled-row scroll clear has three arms, resolved
// once from the environment (precedence below). DEFAULT is HWM — flipped
// 2026-07-07 after the Wave-15 acceptance gate (hwm+L2 0.66x eager on both
// scroll axes, dense no-harm, goldens + pixel goldens byte-identical, the
// interior-gap defect fixed by the S1-lite jump materialize). Arms:
//   EAGER    (KITTY_DISABLE_LAZY_ROW_CLEAR set and != "0" — the escape
//            hatch, wins over everything; or KITTY_ENABLE_HWM_CLEAR=0 — the
//            explicit HWM opt-out): the original 32B clear (both CPUCells
//            and GPUCells zeroed at scroll).
//   RELOCATE (KITTY_DISABLE_LAZY_ROW_CLEAR=0): S1 - 12B CPU clear at scroll,
//            defer the GPU clear, materialize (zero the whole GPU row) on
//            write. Diagnostic A/B arm only.
//   HWM      (DEFAULT; also KITTY_ENABLE_HWM_CLEAR=1): S2+L1 - 12B CPU clear
//            at scroll, defer the GPU clear, and clear only the untouched GPU
//            tail [xlimit,xnum) at line finalize (O(1) via the tracked write
//            extent; 0 bytes for full-width lines), the render clipping the
//            in-progress line. With the L2 consumer clip (default-ON, below)
//            the finalize tail-zero is deferred to the render/history clip.
// Cached function-static, like the draw-loop run-fill levers.
static int scroll_clear_mode_state = -1;

ScrollClearMode
scroll_clear_mode(void) {
    if (UNLIKELY(scroll_clear_mode_state < 0)) {
        const char *d = getenv("KITTY_DISABLE_LAZY_ROW_CLEAR");
        const char *h = getenv("KITTY_ENABLE_HWM_CLEAR");
        if (d && d[0] && strcmp(d, "0") != 0) scroll_clear_mode_state = SCROLL_CLEAR_EAGER;
        else if (d && d[0]) scroll_clear_mode_state = SCROLL_CLEAR_RELOCATE;  // "0"
        else if (h && h[0] && strcmp(h, "0") == 0) scroll_clear_mode_state = SCROLL_CLEAR_EAGER;  // explicit opt-out
        else scroll_clear_mode_state = SCROLL_CLEAR_HWM;  // DEFAULT (flipped 2026-07-07; also explicit "1")
    }
    return (ScrollClearMode)scroll_clear_mode_state;
}

// Wave-21 L4 (KITTY_PAUSE_SNAPSHOT_COW): one-shot process-lifetime resolution,
// same pattern as scroll_clear_mode above. The cold resolver lives here; the
// hot inline test is pause_snapshot_cow_enabled() in line-buf.h. -1 unresolved.
int pause_snapshot_cow_state = -1;
bool
pause_snapshot_cow_resolve(void) {
    const char *v = getenv("KITTY_PAUSE_SNAPSHOT_COW");
    pause_snapshot_cow_state = (v && v[0] && strcmp(v, "0") != 0) ? 1 : 0;
    return pause_snapshot_cow_state != 0;
}

// Wave-15 L1 escape hatches (see line-buf.h), resolved once like scroll_clear_mode.
bool
xlimit_track_disabled(void) {
    static int cached = -1;
    if (UNLIKELY(cached < 0)) {
        const char *v = getenv("KITTY_DISABLE_XLIMIT_TRACK");
        cached = (v && v[0] && v[0] != '0') ? 1 : 0;
    }
    return cached == 1;
}

bool
xlimit_verify_enabled(void) {
    static int cached = -1;
    if (UNLIKELY(cached < 0)) {
        const char *v = getenv("KITTY_XLIMIT_VERIFY");
        cached = (v && v[0] && v[0] != '0') ? 1 : 0;
    }
    return cached == 1;
}

bool
consumer_tail_clip_enabled(void) {
    static int cached = -1;
    if (UNLIKELY(cached < 0)) {
        // DEFAULT ON since the 2026-07-07 flip; KITTY_ENABLE_CONSUMER_TAIL_CLIP=0
        // is the opt-out (drops back to the L1 finalize tail-zero).
        const char *v = getenv("KITTY_ENABLE_CONSUMER_TAIL_CLIP");
        cached = (v && v[0] == '0') ? 0 : 1;
    }
    return cached == 1;
}

void
linebuf_clear_line(LineBuf *self, index_type y, bool clear_attrs, bool allow_lazy) {
#if BLANK_CHAR != 0
#error This implementation is incorrect for BLANK_CHAR != 0
#endif
    const index_type p = lb_phys(self, y);
    index_type ym = self->line_map[p];
    CPUCell *c = cpu_lineptr(self, ym); GPUCell *g = gpu_lineptr(self, ym);
    // The 12B CPUCell clear stays eager in EVERY arm: every text reader
    // (xlimit_for_line/line_is_empty/line_length/unicode_in_range/line_as_ansi)
    // keys off CPUCell fields, so a recycled row must read blank immediately
    // (the pre-overwrite contract in kitty_tests/scroll_semantics.py) and the
    // HWM render clip derives its extent from these clean CPUCells.
    linebuf_gen_bump(self, p);  // Wave-24 D0: content write (former W21 no-bump exception)
    zero_at_ptr_count(c, self->xnum);
    if (clear_attrs) self->line_attrs[p].val = 0;
    // RELOCATE/HWM on a full-screen marginless scroll defer the 20B GPUCell
    // clear behind is_blank; EAGER and every region/reverse/resize caller
    // (allow_lazy=false) zero it now.
    if (allow_lazy && scroll_clear_mode() != SCROLL_CLEAR_EAGER) {
        self->line_attrs[p].is_blank = 1;
        self->line_xlimit[p] = 0;  // L1: begin a fresh deferred-row write high-water
    } else {
        zero_at_ptr_count(g, self->xnum);
    }
}

// S1 (Phase 13B): perform a deferred (lazy) GPUCell clear now and drop the
// is_blank marker, so a caller that reads or writes the GPUCells sees
// authoritative (zeroed) data. No-op when the row was not lazily cleared.
// INVARIANT: any writer that clears is_blank must leave the GPUCells fully
// defined — here that is the whole-row zero (a documented RELOCATE: the draw
// path re-covers drawn cells, so the vtebench headline is ~0). S2 swaps this
// body for a tail-only clear of [hwm, xnum) WITHOUT touching call sites.
// S1 RELOCATE materialize: on the first write, zero the whole deferred GPU row
// and drop is_blank. HWM keeps is_blank to line finalize and EAGER never sets
// it, so this is a no-op in those arms; the is_blank guard is inlined at the
// call sites via linebuf_materialize_blank (line-buf.h).
void
linebuf_materialize_blank_line(LineBuf *self, index_type y) {
    const index_type p = lb_phys(self, y);
    if (!self->line_attrs[p].is_blank || scroll_clear_mode() != SCROLL_CLEAR_RELOCATE) return;
    self->line_attrs[p].is_blank = 0;
    zero_at_ptr_count(gpu_lineptr(self, self->line_map[p]), self->xnum);
    linebuf_gen_bump(self, p);  // Wave-21 L4: GPU cells + is_blank changed
}

// Wave-15 S1-lite (ADR §10c): materialize a deferred (is_blank) row NOW -- zero the
// WHOLE GPU row and drop is_blank; mark it dirty so render_line re-covers the drawn
// CPU runs. Unlike finalize/clip (which zero only the tail [xlimit, xnum)), a full-
// row zero leaves no stale cell anywhere -- correct for a DISCONTIGUOUS write whose
// interior gaps line_xlimit (an upper bound) cannot locate. Called from the cursor-
// positioning commands (never the append-only flood: draw + CR + LF), so zero flood
// cost. Independent of the line_xlimit / UNTRACKED tracking. Any mode (self-gated on
// is_blank; a no-op under EAGER, which never sets it).
void
linebuf_materialize_deferred_row(LineBuf *self, index_type y) {
    const index_type p = lb_phys(self, y);
    if (!self->line_attrs[p].is_blank) return;
    self->line_attrs[p].is_blank = 0;
    self->line_attrs[p].has_dirty_text = true;
    zero_at_ptr_count(gpu_lineptr(self, self->line_map[p]), self->xnum);
    linebuf_gen_bump(self, p);  // Wave-21 L4
}

// L1: backward xlimit scan (last non-blank CPUCell + 1) starting from `start`.
// Starting from the tracked upper bound makes this O(1) for the scroll flood;
// starting from xnum reproduces the pre-L1 full scan (kill-switch / verify /
// UNTRACKED). cpu_cells are eager 12B-cleared in every arm, so ch_and_idx is the
// authoritative emptiness test.
static index_type
xlimit_scan(const CPUCell *c, index_type start) {
    index_type x = start;
    while (x && !c[x - 1].ch_and_idx) x--;
    return x;
}

// S2 HWM finalize (also correct for a RELOCATE un-drawn row: xlimit==0 zeroes
// the whole row): a deferred row keeps its drawn GPUCells [0, xlimit) and a
// stale tail [xlimit, xnum); clear the tail (0 work for full-width lines) and
// drop is_blank when the cursor leaves the row or it is evicted to scrollback.
// xlimit is derived from the clean (eager 12B-cleared) CPUCells.
void
linebuf_finalize_hwm_line(LineBuf *self, index_type y) {
    const index_type p = lb_phys(self, y);
    if (!self->line_attrs[p].is_blank) return;
    self->line_attrs[p].is_blank = 0;
    linebuf_gen_bump(self, p);  // Wave-21 L4: is_blank drop + GPU tail zero below
    const index_type ym = self->line_map[p];
    const CPUCell *c = cpu_lineptr(self, ym);
    // L1: line_xlimit is an UPPER BOUND on the write extent -- the max cursor
    // column any draw reached (a draw always advances the cursor past what it
    // writes), or XLIMIT_UNTRACKED when a non-append mutator moved content past
    // the cursor (IRM shift) or cleared it. Scanning backward from the bound
    // yields the exact xlimit: O(1) for the flood (bound == 1), full scan for
    // UNTRACKED / kill-switch. Never under-clears because bound >= true extent.
    index_type bound = self->line_xlimit[p];
    if (UNLIKELY(bound > self->xnum) || UNLIKELY(xlimit_track_disabled())) bound = self->xnum;
    index_type xlimit = xlimit_scan(c, bound);
    if (UNLIKELY(xlimit_verify_enabled())) {
        const index_type full = xlimit_scan(c, self->xnum);
        if (xlimit != full) {  // bound fell below the true extent -> would under-clear
            log_error("xlimit-verify: MISMATCH finalize y=%u phys=%u bound=%u boundscan=%u fullscan=%u xnum=%u",
                      y, p, self->line_xlimit[p], xlimit, full, self->xnum);
            abort();
        }
    }
    if (xlimit < self->xnum) zero_at_ptr_count(gpu_lineptr(self, ym) + xlimit, self->xnum - xlimit);
}

// init_line choke: is_blank guaranteed set by the inline caller.
void
linebuf_make_authoritative_cold(LineBuf *self, index_type y) {
    if (scroll_clear_mode() == SCROLL_CLEAR_HWM) linebuf_finalize_hwm_line(self, y);
    else linebuf_materialize_blank_line(self, y);  // RELOCATE (EAGER never sets is_blank)
}

static PyObject*
clear_line(LineBuf *self, PyObject *val) {
#define clear_line_doc "clear_line(y) -> Clear the specified line"
    index_type y = (index_type)PyLong_AsUnsignedLong(val);
    if (y >= self->ynum) { PyErr_SetString(PyExc_ValueError, "Out of bounds"); return NULL; }
    linebuf_clear_line(self, y, true, false);
    Py_RETURN_NONE;
}

// ============================ PHYSICAL-INDEX ZONE ============================
// S3 (Phase 13B) invariant: EVERY logical-row access to line_map/line_attrs
// goes through lb_phys() EXCEPT (1) linebuf_normalize below (the head-rotation
// primitive), (2) the four reorder functions it enables (linebuf_index /
// _reverse_index / _insert_lines / _delete_lines), which run ONLY at head==0
// (the marginless fast path returns early with an O(1) head bump; every other
// entry calls linebuf_normalize first), and (3) order-agnostic full-row loops
// (linebuf_clear/set_attribute) and the head==0 alloc rebuild. A raw line_map[
// ]/line_attrs[] index anywhere else is a bug — use lb_phys.
// ============================================================================
// linebuf_normalize rotates line_map/line_attrs so logical row 0 sits at
// physical 0 (head->0), letting the physical-index reorder ops below run
// unchanged. Cold path only; the hot marginless scroll never calls this.
// scratch is ynum index_type (4*ynum bytes), big enough to also stage the
// ynum-byte line_attrs pass.
static void
linebuf_normalize(LineBuf *self) {
    if (self->head == 0) return;
    const index_type h = self->head, n = self->ynum;
    for (index_type i = 0; i < n; i++) {
        index_type p = h + i; if (p >= n) p -= n;
        self->scratch[i] = self->line_map[p];
    }
    memcpy(self->line_map, self->scratch, n * sizeof(self->line_map[0]));
    LineAttrs *as = (LineAttrs*)self->scratch;
    for (index_type i = 0; i < n; i++) {
        index_type p = h + i; if (p >= n) p -= n;
        as[i] = self->line_attrs[p];
    }
    memcpy(self->line_attrs, as, n * sizeof(self->line_attrs[0]));
    for (index_type i = 0; i < n; i++) {  // L1: rotate line_xlimit alongside line_attrs
        index_type p = h + i; if (p >= n) p -= n;
        self->scratch[i] = self->line_xlimit[p];
    }
    memcpy(self->line_xlimit, self->scratch, n * sizeof(self->line_xlimit[0]));
    if (UNLIKELY(pause_snapshot_cow_enabled())) {
        // Wave-24 D0: gen_at_pos co-rotates with line_map so each entry stays
        // attached to the slot whose content it describes (pure permutes never
        // change content). Switch-gated like every gen write; scratch is free
        // for reuse here (its prior passes have been memcpy'd out).
        for (index_type i = 0; i < n; i++) {
            index_type p = h + i; if (p >= n) p -= n;
            self->scratch[i] = self->gen_at_pos[p];
        }
        memcpy(self->gen_at_pos, self->scratch, n * sizeof(self->gen_at_pos[0]));
    }
    self->head = 0;
}

void
linebuf_index(LineBuf* self, index_type top, index_type bottom) {
    if (top >= self->ynum - 1 || bottom >= self->ynum || bottom <= top) return;
    // S3: marginless full-height scroll up is an O(1) head bump (logical row y
    // becomes physical head+1+y; old logical 0 wraps to logical ynum-1). This is
    // the vtebench/normal-scroll hot path; no memmove.
    if (top == 0 && bottom == self->ynum - 1) {
        self->head = self->head + 1 >= self->ynum ? 0 : self->head + 1;
        return;
    }
    // Region scroll: normalize then run the original physical rotate.
    linebuf_normalize(self);
    index_type old_top = self->line_map[top];
    LineAttrs old_attrs = self->line_attrs[top];
    index_type old_xlimit = self->line_xlimit[top];
    const index_type num = bottom - top;
    memmove(self->line_map + top, self->line_map + top + 1, sizeof(self->line_map[0]) * num);
    memmove(self->line_attrs + top, self->line_attrs + top + 1, sizeof(self->line_attrs[0]) * num);
    memmove(self->line_xlimit + top, self->line_xlimit + top + 1, sizeof(self->line_xlimit[0]) * num);
    self->line_map[bottom] = old_top;
    self->line_attrs[bottom] = old_attrs;
    self->line_xlimit[bottom] = old_xlimit;
    if (UNLIKELY(pause_snapshot_cow_enabled())) {
        // Wave-24 D0: gen co-moves with line_map (pure permute — no content
        // change; the vacated row's clear happens at the caller and records
        // its own content write there).
        const uint32_t old_gen = self->gen_at_pos[top];
        memmove(self->gen_at_pos + top, self->gen_at_pos + top + 1, sizeof(self->gen_at_pos[0]) * num);
        self->gen_at_pos[bottom] = old_gen;
    }
}

static PyObject*
pyw_index(LineBuf *self, PyObject *args) {
#define index_doc "index(top, bottom) -> Scroll all lines in the range [top, bottom] by one upwards. After scrolling, bottom will be top."
    unsigned int top, bottom;
    if (!PyArg_ParseTuple(args, "II", &top, &bottom)) return NULL;
    linebuf_index(self, top, bottom);
    Py_RETURN_NONE;
}

void
linebuf_reverse_index(LineBuf *self, index_type top, index_type bottom) {
    if (top >= self->ynum - 1 || bottom >= self->ynum || bottom <= top) return;
    // S3: marginless full-height reverse scroll (down) is an O(1) head bump back
    // (old logical ynum-1 wraps to logical 0).
    if (top == 0 && bottom == self->ynum - 1) {
        self->head = self->head == 0 ? self->ynum - 1 : self->head - 1;
        return;
    }
    linebuf_normalize(self);
    index_type old_bottom = self->line_map[bottom];
    LineAttrs old_attrs = self->line_attrs[bottom];
    index_type old_xlimit = self->line_xlimit[bottom];
    const bool cow_gen = UNLIKELY(pause_snapshot_cow_enabled());  // Wave-24 D0: gen co-moves
    const uint32_t old_gen = cow_gen ? self->gen_at_pos[bottom] : 0;
    for (index_type i = bottom; i > top; i--) {
        self->line_map[i] = self->line_map[i - 1];
        self->line_attrs[i] = self->line_attrs[i - 1];
        self->line_xlimit[i] = self->line_xlimit[i - 1];
        if (cow_gen) self->gen_at_pos[i] = self->gen_at_pos[i - 1];
    }
    self->line_map[top] = old_bottom;
    self->line_attrs[top] = old_attrs;
    self->line_xlimit[top] = old_xlimit;
    if (cow_gen) self->gen_at_pos[top] = old_gen;
}

static PyObject*
reverse_index(LineBuf *self, PyObject *args) {
#define reverse_index_doc "reverse_index(top, bottom) -> Scroll all lines in the range [top, bottom] by one down. After scrolling, top will be bottom."
    unsigned int top, bottom;
    if (!PyArg_ParseTuple(args, "II", &top, &bottom)) return NULL;
    linebuf_reverse_index(self, top, bottom);
    Py_RETURN_NONE;
}


static PyObject*
is_continued(LineBuf *self, PyObject *val) {
#define is_continued_doc "is_continued(y) -> Whether the line y is continued or not"
    unsigned long y = PyLong_AsUnsignedLong(val);
    if (y >= self->ynum) { PyErr_SetString(PyExc_ValueError, "Out of bounds."); return NULL; }
    if (y > 0 && linebuf_line_ends_with_continuation(self, y-1)) { Py_RETURN_TRUE; }
    Py_RETURN_FALSE;
}

void
linebuf_insert_lines(LineBuf *self, unsigned int num, unsigned int y, unsigned int bottom) {
    index_type i;
    if (y >= self->ynum || y > bottom || bottom >= self->ynum) return;
    index_type ylimit = bottom + 1;
    if (ylimit < y || (num = MIN(ylimit - y, num)) < 1) return;
    linebuf_normalize(self);  // S3: physical rotate below assumes head==0
    const size_t scratch_sz = sizeof(self->scratch[0]) * num;
    const bool cow_gen = UNLIKELY(pause_snapshot_cow_enabled());  // Wave-24 D0
    memcpy(self->scratch, self->line_map + ylimit - num, scratch_sz);
    for (i = ylimit - 1; i >= y + num; i--) {
        self->line_map[i] = self->line_map[i - num];
        self->line_attrs[i] = self->line_attrs[i - num];
        self->line_xlimit[i] = self->line_xlimit[i - num];
        // Wave-24 D0: gen co-moves with the shifted rows; the rotated-in rows
        // at [y, y+num) are content-cleared below and get fresh assignments
        // there, so their stale gens need no staging.
        if (cow_gen) self->gen_at_pos[i] = self->gen_at_pos[i - num];
    }
    memcpy(self->line_map + y, self->scratch, scratch_sz);
    Line l;
    for (i = y; i < y + num; i++) {
        init_line(self, &l, self->line_map[i]);
        clear_line_(&l, self->xnum);
        self->line_attrs[i].val = 0;
        self->line_xlimit[i] = 0;
        linebuf_gen_bump(self, i);  // Wave-24 D0: content write (row cleared)
    }
}

static PyObject*
insert_lines(LineBuf *self, PyObject *args) {
#define insert_lines_doc "insert_lines(num, y, bottom) -> Insert num blank lines at y, only changing lines in the range [y, bottom]."
    unsigned int y, num, bottom;
    if (!PyArg_ParseTuple(args, "III", &num, &y, &bottom)) return NULL;
    linebuf_insert_lines(self, num, y, bottom);
    Py_RETURN_NONE;
}

void
linebuf_delete_lines(LineBuf *self, index_type num, index_type y, index_type bottom) {
    index_type i;
    index_type ylimit = bottom + 1;
    num = MIN(bottom + 1 - y, num);
    if (y >= self->ynum || y > bottom || bottom >= self->ynum || num < 1) return;
    linebuf_normalize(self);  // S3: physical rotate below assumes head==0
    const size_t scratch_sz = sizeof(self->scratch[0]) * num;
    const bool cow_gen = UNLIKELY(pause_snapshot_cow_enabled());  // Wave-24 D0
    memcpy(self->scratch, self->line_map + y, scratch_sz);
    for (i = y; i < ylimit && i + num < self->ynum; i++) {
        self->line_map[i] = self->line_map[i + num];
        self->line_attrs[i] = self->line_attrs[i + num];
        self->line_xlimit[i] = self->line_xlimit[i + num];
        // Wave-24 D0: gen co-moves with the shifted rows; the rotated-in rows
        // at [ylimit-num, ylimit) are content-cleared below and get fresh
        // assignments there.
        if (cow_gen) self->gen_at_pos[i] = self->gen_at_pos[i + num];
    }
    memcpy(self->line_map + ylimit - num, self->scratch, scratch_sz);
    Line l;
    for (i = ylimit - num; i < ylimit; i++) {
        init_line(self, &l, self->line_map[i]);
        clear_line_(&l, self->xnum);
        self->line_attrs[i].val = 0;
        self->line_xlimit[i] = 0;
        linebuf_gen_bump(self, i);  // Wave-24 D0: content write (row cleared)
    }
}

static PyObject*
delete_lines(LineBuf *self, PyObject *args) {
#define delete_lines_doc "delete_lines(num, y, bottom) -> Delete num lines at y, only changing lines in the range [y, bottom]."
    unsigned int y, num, bottom;
    if (!PyArg_ParseTuple(args, "III", &num, &y, &bottom)) return NULL;
    linebuf_delete_lines(self, num, y, bottom);
    Py_RETURN_NONE;
}

void
linebuf_copy_line_to(LineBuf *self, Line *line, index_type where) {
    const index_type wp = lb_phys(self, where);  // S3: logical row -> physical
    init_line(self, self->line, self->line_map[wp]);
    copy_line(line, self->line);
    self->line_attrs[wp] = line->attrs;
    self->line_attrs[wp].has_dirty_text = true;
    linebuf_gen_bump(self, wp);  // Wave-21 L4
    // L2: a deferred (is_blank) source carried a stale GPU tail across and this
    // buffer's line_xlimit lane is not the source's extent; finalize-on-copy from
    // the eager-clean CPUCells so copy_line_to always yields an authoritative row.
    if (UNLIKELY(self->line_attrs[wp].is_blank)) {
        const CPUCell *c = self->line->cpu_cells;
        index_type xl = self->xnum;
        while (xl && !c[xl - 1].ch_and_idx) xl--;
        if (xl < self->xnum) zero_at_ptr_count(self->line->gpu_cells + xl, self->xnum - xl);
        self->line_attrs[wp].is_blank = 0;
    }
}

static PyObject*
as_ansi(LineBuf *self, PyObject *callback) {
#define as_ansi_doc "as_ansi(callback) -> The contents of this buffer as ANSI escaped text. callback is called with each successive line."
    Line l = {.xnum=self->xnum, .text_cache=self->text_cache};
    // remove trailing empty lines
    index_type ylimit = self->ynum - 1;
    ANSIBuf output = {0}; ANSILineState s = {.output_buf=&output};
    do {
        init_line(self, &l, self->line_map[lb_phys(self, ylimit)]);
        output.len = 0;
        line_as_ansi(&l, &s, 0, l.xnum, 0, true);
        if (output.len) break;
        ylimit--;
    } while(ylimit > 0);

    for(index_type i = 0; i <= ylimit; i++) {
        bool output_newline = !linebuf_line_ends_with_continuation(self, i);
        output.len = 0;
        init_line(self, &l, self->line_map[lb_phys(self, i)]);
        line_as_ansi(&l, &s, 0, l.xnum, 0, true);
        if (output_newline) {
            ensure_space_for(&output, buf, Py_UCS4, output.len + 1, capacity, 2048, false);
            output.buf[output.len++] = 10; // 10 = \n
        }
        PyObject *ans = PyUnicode_FromKindAndData(PyUnicode_4BYTE_KIND, output.buf, output.len);
        if (ans == NULL) { PyErr_NoMemory(); goto end; }
        PyObject *ret = PyObject_CallFunctionObjArgs(callback, ans, NULL);
        Py_CLEAR(ans);
        if (ret == NULL) goto end;
        Py_CLEAR(ret);
    }
end:
    free(output.buf);
    if (PyErr_Occurred()) return NULL;
    Py_RETURN_NONE;
}

static Line*
get_line(void *x, int y) {
    LineBuf *self = (LineBuf*)x;
    linebuf_init_line(self, MAX(0, y));
    return self->line;
}

static PyObject*
as_text(LineBuf *self, PyObject *args) {
    ANSIBuf output = {0};
    PyObject* ans = as_text_generic(args, self, get_line, self->ynum, &output, false);
    free(output.buf);
    return ans;
}


static PyObject*
__str__(LineBuf *self) {
    RAII_PyObject(lines, PyTuple_New(self->ynum));
    RAII_ANSIBuf(buf);
    if (lines == NULL) return PyErr_NoMemory();
    for (index_type i = 0; i < self->ynum; i++) {
        init_line(self, self->line, self->line_map[lb_phys(self, i)]);
        PyObject *t = line_as_unicode(self->line, false, &buf);
        if (t == NULL) return NULL;
        PyTuple_SET_ITEM(lines, i, t);
    }
    RAII_PyObject(sep, PyUnicode_FromString("\n"));
    return PyUnicode_Join(sep, lines);
}

// Boilerplate {{{
static PyObject*
copy_old(LineBuf *self, PyObject *y);
#define copy_old_doc "Copy the contents of the specified LineBuf to this LineBuf. Both must have the same number of columns, but the number of lines can be different, in which case the bottom lines are copied."

static PyObject*
rewrap(LineBuf *self, PyObject *args);
#define rewrap_doc "rewrap(new_screen) -> Fill up new screen (which can have different size to this screen) with as much of the contents of this screen as will fit. Return lines that overflow."

static PyMethodDef methods[] = {
    METHOD(line, METH_O)
    METHOD(clear_line, METH_O)
    METHOD(copy_old, METH_O)
    METHOD(copy_line_to, METH_VARARGS)
    METHOD(create_line_copy, METH_O)
    METHOD(rewrap, METH_VARARGS)
    METHOD(clear, METH_NOARGS)
    METHOD(as_ansi, METH_O)
    METHODB(as_text, METH_VARARGS),
    METHOD(set_attribute, METH_VARARGS)
    METHOD(set_continued, METH_VARARGS)
    METHOD(dirty_lines, METH_NOARGS)
    {"index", (PyCFunction)pyw_index, METH_VARARGS, NULL},
    METHOD(reverse_index, METH_VARARGS)
    METHOD(insert_lines, METH_VARARGS)
    METHOD(delete_lines, METH_VARARGS)
    METHOD(is_continued, METH_O)
    {NULL, NULL, 0, NULL}  /* Sentinel */
};

static PyMemberDef members[] = {
    {"xnum", T_UINT, offsetof(LineBuf, xnum), READONLY, "xnum"},
    {"ynum", T_UINT, offsetof(LineBuf, ynum), READONLY, "ynum"},
    {NULL}  /* Sentinel */
};

PyTypeObject LineBuf_Type = {
    PyVarObject_HEAD_INIT(NULL, 0)
    .tp_name = "fast_data_types.LineBuf",
    .tp_basicsize = sizeof(LineBuf),
    .tp_dealloc = (destructor)dealloc,
    .tp_flags = Py_TPFLAGS_DEFAULT,
    .tp_doc = "Line buffers",
    .tp_methods = methods,
    .tp_members = members,
    .tp_str = (reprfunc)__str__,
    .tp_new = new_linebuf_object
};

INIT_TYPE(LineBuf)
// }}}

static PyObject*
copy_old(LineBuf *self, PyObject *y) {
    if (!PyObject_TypeCheck(y, &LineBuf_Type)) { PyErr_SetString(PyExc_TypeError, "Not a LineBuf object"); return NULL; }
    LineBuf *other = (LineBuf*)y;
    if (other->xnum != self->xnum) { PyErr_SetString(PyExc_ValueError, "LineBuf has a different number of columns"); return NULL; }
    Line sl = {.text_cache=self->text_cache}, ol = {.text_cache=self->text_cache};
    sl.xnum = self->xnum; ol.xnum = other->xnum;

    for (index_type i = 0; i < MIN(self->ynum, other->ynum); i++) {
        index_type s = self->ynum - 1 - i, o = other->ynum - 1 - i;
        self->line_attrs[lb_phys(self, s)] = other->line_attrs[lb_phys(other, o)];
        self->line_xlimit[lb_phys(self, s)] = other->line_xlimit[lb_phys(other, o)];  // L1: carry xhwm (same-width copy)
        s = self->line_map[lb_phys(self, s)]; o = other->line_map[lb_phys(other, o)];
        init_line(self, &sl, s); init_line(other, &ol, o);
        copy_line(&ol, &sl);
    }
    Py_RETURN_NONE;
}

static PyObject*
rewrap(LineBuf *self, PyObject *args) {
    unsigned int lines, columns;
    if (!PyArg_ParseTuple(args, "II", &lines, &columns)) return NULL;
    TrackCursor cursors[1] = {{.is_sentinel=true}};
    ANSIBuf as_ansi_buf = {0};
    ResizeResult r = resize_screen_buffers(self, NULL, lines, columns, &as_ansi_buf, cursors);
    free(as_ansi_buf.buf);
    if (!r.ok) return PyErr_NoMemory();
    return Py_BuildValue("NII", r.lb, r.num_content_lines_before, r.num_content_lines_after);
}


LineBuf *
alloc_linebuf(unsigned int lines, unsigned int columns, TextCache *tc) { return alloc_linebuf_(&LineBuf_Type, lines, columns, tc, NULL); }

LineBuf*
alloc_linebuf_with_pool(unsigned int lines, unsigned int columns, TextCache *tc, LineSlotPool *pool) { return alloc_linebuf_(&LineBuf_Type, lines, columns, tc, pool); }
