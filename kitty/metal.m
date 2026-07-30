/*
 * metal.m
 * Copyright (C) 2024 Kovid Goyal <kovid at kovidgoyal.net>
 *
 * Distributed under terms of the GPL3 license.
 */

// Include system headers first to avoid macro conflicts
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <Cocoa/Cocoa.h>
#import <os/signpost.h>

// W27 P3.2: the KITTY_METAL_DRAWABLE_FORMAT probe's candidate table, shared
// with glfw/metal_context.m (which builds the CAMetalLayer from the same
// resolver). Included with the system headers, before data-types.h redefines
// MAX/MIN.
#include "metal_drawable_format.h"
// W27 P3.4: the TARGET_SPACE_* values the shaders branch on. Same header the
// .metal files include; the MSL-only half is behind __METAL_VERSION__, so from
// here it is just the three integer values — one definition, no drift.
#include "color_transfer.metal.h"

// Undefine system MAX/MIN before data-types.h redefines them
#undef MAX
#undef MIN

#include "metal.h"
// W27 GLSL-freezeout stage 1: the generated per-program uniform-slot enums
// (<CLASS>_U_<name>), consumed by the fill_*_uniforms() functions below in
// place of the old find_uniform_slot() string-literal lookups.
#include "uniforms_generated.h"
#include "state.h"
#include "png-reader.h"

#include <string.h>
#include <stdatomic.h>
#include <stddef.h>
#include <math.h> // pow: sRGB->linear for the wide-drawable clear colour
#include <sched.h> // sched_yield: ring-exhaustion safety valve (ring_acquire_slot)

// Dev/debug tracing, enabled by setting KITTY_METAL_LOG to a file path.
static const char*
metal_log_path(void) {
    static bool checked = false;
    static const char *path = NULL;
    if (!checked) { path = getenv("KITTY_METAL_LOG"); checked = true; }
    return path;
}
#define METAL_TRACE(...) { const char *mlp_ = metal_log_path(); if (mlp_) { FILE *tf_ = fopen(mlp_, "a"); if (tf_) { fprintf(tf_, __VA_ARGS__); fclose(tf_); } } }

// ----- Phase 0 instrumentation (os_signpost + per-frame stats) -----
// Every hook is gated by a cached env check: when KITTY_METAL_SIGNPOST and
// KITTY_METAL_STATS are unset each hook collapses to a single cached-bool
// test, so instrumentation is effectively zero-cost in normal runs.
static bool
metal_signpost_enabled(void) {
    static int state = -1;
    if (state < 0) { const char *v = getenv("KITTY_METAL_SIGNPOST"); state = (v && v[0] && strcmp(v, "0") != 0) ? 1 : 0; }
    return state == 1;
}

// os_log handle backing the signposts (subsystem/category shown in Instruments).
// Created lazily on first use; only ever reached when signposts are enabled.
static os_log_t
metal_signpost_log(void) {
    static os_log_t handle = NULL;
    if (!handle) handle = os_log_create("net.kovidgoyal.kitty", "metal");
    return handle;
}

static bool
metal_stats_enabled(void) {
    static int state = -1;
    if (state < 0) { const char *v = getenv("KITTY_METAL_STATS"); state = (v && v[0] && strcmp(v, "0") != 0) ? 1 : 0; }
    return state == 1;
}

// Emit one machine-parseable record (leading token + space-separated key=value
// pairs, newline-terminated) to KITTY_METAL_STATS_FILE (append) or stderr.
// Consumed by the latency/throughput harnesses — keep the line format stable.
// Callers pre-format so this stays a plain fputs (no varargs); safe to call
// from the Metal completion/present handler queues (stdio locks the stream).
static void
metal_stats_emit(const char *line) {
    static bool checked = false;
    static const char *path = NULL;
    if (!checked) { path = getenv("KITTY_METAL_STATS_FILE"); checked = true; }
    if (path) { FILE *f = fopen(path, "a"); if (f) { fputs(line, f); fclose(f); } }
    else { fputs(line, stderr); }
}

// KITTY_METAL_DUMP_FRAME golden-image harness: when set, the frame is rendered
// to a readable offscreen texture (not the drawable) so the dump — and a
// framebufferOnly=YES drawable — never reads drawable.texture. Cached once.
static const char*
metal_dump_frame_path(void) {
    static bool checked = false;
    static const char *path = NULL;
    if (!checked) { path = getenv("KITTY_METAL_DUMP_FRAME"); checked = true; }
    return path;
}

// C4a: a frame must render to the readable offscreen (never the framebufferOnly
// drawable, which cannot be read back) whenever it will be read this frame — the
// KITTY_METAL_DUMP_FRAME golden harness, or a pending thumbnail screenshot
// (take_screenshot_of_rectangular_region reads the "drawable" via
// glCopyTexImage2D before present). In that mode no drawable is acquired and
// nothing is presented; the reader gets the offscreen instead. Cleared once the
// thumbnail is captured (kitty/child-monitor.c), so normal frames present as usual.
static bool
metal_capture_to_offscreen(void) {
    return metal_dump_frame_path() != NULL || global_state.thumbnail_callback.os_window != 0;
}

// The pixel format of the frame's final colour target: the CAMetalLayer's
// drawable (the W27 P3.2 candidate, default BGRA8Unorm) or, in capture mode,
// the readable BGRA8 offscreen that stands in for it. Keeping the capture
// target at BGRA8 keeps the golden dump and the thumbnail read-back on their
// 8-bit assumption under every candidate, and — because the shader encode is
// selected per attachment format, not per process — makes the capture path a
// permanently correct sRGB control arm even while the real drawable is wide.
static MTLPixelFormat
drawable_attachment_format(void) {
    return metal_capture_to_offscreen() ? MTLPixelFormatBGRA8Unorm : kitty_drawable_pixel_format();
}

// Metal global state
static id<MTLDevice> mtl_device = nil;
static id<MTLCommandQueue> mtl_command_queue = nil;
static id<MTLLibrary> mtl_default_library = nil;

// Per-frame state
static id<MTLCommandBuffer> mtl_current_command_buffer = nil;
static id<MTLRenderCommandEncoder> mtl_current_encoder = nil;
static id<CAMetalDrawable> mtl_current_drawable = nil;
static MTLRenderPassDescriptor *mtl_current_render_pass = nil;
// The window's backing layer, created in glfw/metal_context.m.
static CAMetalLayer *mtl_current_layer = nil;
// Phase 4 (L1): the drawable delivered by the CAMetalDisplayLink for this frame,
// set via metal_set_link_drawable() before the link-driven render and cleared
// after. Unretained: it is owned by the CAMetalDisplayLinkUpdate for the duration
// of the delegate callback, and by the committed command buffer once presented.
static id<CAMetalDrawable> mtl_link_drawable = nil;
// Pace attribution: distinguishes a CAMetalDisplayLink-driven frame (pace=link)
// from anything else. The immediate-encode floor is per-OSWindow now
// (last_gpu_present_at, kitty/child-monitor.c), so no global present timestamp
// is kept.
static bool metal_frame_used_link_drawable = false;

// Clear color state
static float clear_r = 0, clear_g = 0, clear_b = 0, clear_a = 1;
static bool clear_pending = false;

// Forward declarations
static void end_current_encoder(void);
static bool ensure_command_buffer(void);
static bool ensure_drawable(void);
static id<MTLRenderCommandEncoder> begin_render_pass_to_drawable(bool clear);
static MTLPixelFormat wanted_attachment_format(bool for_clear);

// Viewport state
static MTLViewport mtl_viewport = {0, 0, 0, 0, 0, 1};
static struct {
    MTLViewport items[16];
    size_t used;
} saved_viewports;

// Scissor state
static bool scissor_enabled = false;
static MTLScissorRect mtl_scissor = {0, 0, 0, 0};

// Framebuffer SRGB state
static bool framebuffer_srgb_enabled = false;
// sRGB flag captured at glClear time (GL converts clear colors on write only
// when FRAMEBUFFER_SRGB is enabled at clear time)
static bool clear_srgb_flag = false;
// Attachment state of the currently open encoder (kitty/metal-pipeline-design.md)
static MTLPixelFormat mtl_current_enc_fmt = MTLPixelFormatInvalid;

// M1: single-pass layered rendering. Layered windows (transparency, bg image,
// graphics, overlays, cursor trail) render into a MEMORYLESS RGBA16Unorm working
// surface (color attachment 0, tile-memory only — never DRAM) using the existing
// linear-premultiplied compositing draws, then a resolve draw reads that surface
// via framebuffer fetch and writes the sRGB drawable (attachment 1), all in ONE
// pass — replacing the old RGBA16 DRAM FBO + separate BLIT pass. RGBA16Unorm
// matches the old FBO exactly so blending precision (issue #8953) is preserved.
#define LAYERED_WORK_FMT MTLPixelFormatRGBA16Unorm      // att0: memoryless working surface (SDR)
// W27 P4.2: RGBA16Unorm CLAMPS at 1.0, so while EDR is engaged it would eat the
// >1.0 components before they could reach the (rgba16f) drawable — images are
// layered-only, so this surface is on the path of every HDR pixel. The att0
// format therefore becomes per-frame: half-float while this window has EDR
// engaged, the unchanged RGBA16Unorm otherwise. Unorm stays the default so
// nothing about SDR rendering (blending precision, issue #8953) moves.
#define LAYERED_WORK_FMT_EDR MTLPixelFormatRGBA16Float
// Set once per prepare, per OS window, from child-monitor's lazy-engagement
// block (metal_set_edr_frame_state) — i.e. always before that window's frame is
// encoded, which is the only ordering this needs.
static bool edr_frame_engaged = false;
static float edr_frame_headroom = 1.0f;
static inline MTLPixelFormat layered_work_fmt(void) { return edr_frame_engaged ? LAYERED_WORK_FMT_EDR : LAYERED_WORK_FMT; }
static bool layered_pass_active = false;                // inside a layered pass? (per window: saved with the slot)
// H2 (W28.4a): the memoryless att0 working surface and its (w, h, fmt) cache key
// live in MetalWindowSlot, not here. As file-scope globals they formed a single
// slot keyed on the drawable size and format, so two OS windows of different
// sizes -- or with different EDR engagement -- alternated keys and recreated the
// texture EVERY frame, each one's lookup missing the other's entry.
// H2 (W28.4a): counts successful creations of a layered working surface. Nothing
// else observes this: allocs= tracks MTLBuffer only and tex_allocs= only counts
// GL_SRGB_ALPHA image textures, so a memoryless-texture rebuild was invisible to
// every existing counter. Steady state is 0 once the cache is per window.
static uint64_t metal_layered_surface_creates = 0;
// One resolve PSO per (att0, att1) format pair. att1 is the drawable's (the W27
// P3.2 candidate) or the BGRA8 capture offscreen's — two; att0 is the SDR or the
// EDR working-surface format (P4.2) — two. Four in the worst case.
static struct { MTLPixelFormat att0_fmt, att1_fmt; id<MTLRenderPipelineState> pso; } layers_resolve_psos[4];

// Active texture unit tracking. GL keeps an independent binding per
// (unit, target) pair — upload paths freely bind GL_TEXTURE_2D on whatever
// unit is active without disturbing that unit's 2D-array binding, so the
// shim must model both targets separately or an upload clobbers the sprite
// atlas binding the cell fragment shader samples.
static unsigned active_texture_unit = 0;
#define MAX_TEXTURE_UNITS 8
static GLuint bound_tex_2d[MAX_TEXTURE_UNITS] = {0};
static GLuint bound_tex_2d_array[MAX_TEXTURE_UNITS] = {0};

// Framebuffer tracking, mirroring gl.c semantics: set_framebuffer_to_use_
// for_output REGISTERS an indirection target, and binding fb 0 resolves to
// that registered target (not to the real default framebuffer).
static unsigned output_framebuffer = 0;  // registered indirection target
static unsigned bound_framebuffer = 0;   // actually bound render target

// Per-program uniform data store
// Each uniform location maps to a slot in this buffer.
// We store up to 4 floats per uniform (enough for vec4/uvec4).
#define MAX_UNIFORMS_PER_PROGRAM 300
#define ARRAY_UNIFORM_BASE 200
typedef union {
    float f[4];
    int32_t i[4];
    uint32_t u[4];
} UniformValue;

static struct {
    UniformValue values[MAX_UNIFORMS_PER_PROGRAM];
} uniform_stores[64];

// US-307 (G2 minor): array uniforms pack at ARRAY_UNIFORM_BASE + slot*16, spanning
// MAX_IMAGE_INSTANCES elements. Guard the headroom at compile time so growing
// MAX_IMAGE_INSTANCES or shrinking the store fails the build instead of
// metal_gl_uniform4fv silently clamping (base+i < MAX_UNIFORMS_PER_PROGRAM).
// W27 GLSL-freezeout stage 1: GRAPHICS_U_dest_rects is generated from
// SHADER_UNIFORMS['graphics'] (setup.py) into uniforms_generated.h, so this
// assert now tracks the manifest instead of a hand-maintained slot literal.
_Static_assert(ARRAY_UNIFORM_BASE + GRAPHICS_U_dest_rects * 16 + MAX_IMAGE_INSTANCES <= MAX_UNIFORMS_PER_PROGRAM,
               "graphics dest_rects array overflows the uniform value store");

// Gamma LUT — cached for binding to shaders
static const float *cached_gamma_lut = NULL;
static int cached_gamma_lut_count = 0;

// M5c: a persistent MTLBuffer holding the cell gamma LUT, bound by index at
// draw time instead of re-copied as a 1 KB setVertexBytes on every cell draw.
// srgb_lut (kitty/shaders.c) is a fixed, process-lifetime table uploaded with a
// stable pointer, so the buffer is (re)built only when that pointer or the entry
// count changes — in practice exactly once. Committed command buffers retain the
// resources they reference, so a rebuild that releases the old buffer is safe.
static id<MTLBuffer> gamma_lut_buffer = nil;
static const float *gamma_lut_buffer_src = NULL;
static int gamma_lut_buffer_count = 0;

static id<MTLBuffer>
ensure_gamma_lut_buffer(void) {
    if (!cached_gamma_lut || cached_gamma_lut_count <= 0) return nil;
    if (gamma_lut_buffer && gamma_lut_buffer_src == cached_gamma_lut && gamma_lut_buffer_count == cached_gamma_lut_count) {
        return gamma_lut_buffer;  // unchanged — no copy, just reuse the resident buffer
    }
    size_t bytes = (size_t)cached_gamma_lut_count * sizeof(float);
    if (!gamma_lut_buffer || gamma_lut_buffer_count != cached_gamma_lut_count) {
        [gamma_lut_buffer release];
        gamma_lut_buffer = [mtl_device newBufferWithLength:bytes options:MTLResourceStorageModeShared];
        if (!gamma_lut_buffer) { gamma_lut_buffer_src = NULL; gamma_lut_buffer_count = 0; return nil; }
    }
    memcpy(gamma_lut_buffer.contents, cached_gamma_lut, bytes);
    gamma_lut_buffer_src = cached_gamma_lut;
    gamma_lut_buffer_count = cached_gamma_lut_count;
    return gamma_lut_buffer;
}

// Current VAO binding for buffer access
static ssize_t current_bound_vao = -1;

// Cell-program options that GL bakes into the GLSL via cell_defines.glsl.
// The Metal shaders take them as function constants instead, so they are
// parsed out of the preprocessed source each time Python (re)compiles the
// cell programs — this keeps text_composition_strategy and
// text_fg_override_threshold live, including on config reload.
static struct {
    bool do_fg_override;
    int fg_override_algo;
    float fg_override_threshold;
    bool text_new_gamma;
} cell_shader_opts = { .fg_override_algo = 1, .text_new_gamma = true };

// ----- Programs -----

static Program programs[64] = {{0}};
static int current_program = -1;

// Pipeline states cached by (program, blend, attachment pixel format).
// A PSO's colorAttachments[0].pixelFormat must match the encoder target's
// format: the drawable is BGRA8Unorm with an sRGB view for FRAMEBUFFER_SRGB
// parity, and the layers FBO is RGBA16Unorm, so a single PSO per program
// cannot cover all render passes (see kitty/metal-pipeline-design.md).
#define NUM_PROGRAMS 14
// W27 P4.2 raised this from 8: att0 for a layered pass is now per-frame (SDR
// RGBA16Unorm / EDR RGBA16Float), which doubles the layered variants. A cell
// program can now want 2 (drawable, non-layered) + 2 (thumbnail-capture FBO,
// non-layered) + 4 (layered x2 formats x2 blend) = 8, i.e. exactly the old
// ceiling with zero slack; overflow degrades to dropped draws (pso_get returns
// nil), so the headroom is worth the few hundred bytes.
#define PSO_VARIANTS_PER_PROGRAM 12
typedef struct {
    id<MTLRenderPipelineState> pso;
    MTLPixelFormat fmt;
    // W27 P3.2: att1's format is baked into a layered PSO (Metal requires the
    // pipeline's attachment formats to match the render pass'), and att1 is the
    // drawable — which is the probe candidate on a normal frame and BGRA8 on a
    // capture frame. So it is part of the cache key, not a constant.
    MTLPixelFormat att1_fmt;      // layered only; MTLPixelFormatInvalid otherwise
    bool blend, layered, in_use;  // layered: M1 two-attachment (att0 work + att1 drawable) variant
} PSOCacheEntry;
static PSOCacheEntry pso_cache[NUM_PROGRAMS * PSO_VARIANTS_PER_PROGRAM];
static id<MTLRenderPipelineState> build_pso(int program, bool blend, MTLPixelFormat fmt, bool layered,
                                            MTLPixelFormat att1_fmt);
static id<MTLRenderPipelineState> ensure_layers_resolve_pso(MTLPixelFormat att0_fmt, MTLPixelFormat att1_fmt);  // M1: att0->att1 resolve PSO

// Drop the cell-program variants so the next pso_get rebuilds them with the
// current cell_shader_opts (config change / live reload).
static void
invalidate_cell_pipeline_states(void) {
    for (int p = 0; p <= 2; p++) {
        size_t base = (size_t)p * PSO_VARIANTS_PER_PROGRAM;
        for (size_t i = base; i < base + PSO_VARIANTS_PER_PROGRAM; i++) {
            if (pso_cache[i].in_use) {
                [pso_cache[i].pso release];
                pso_cache[i] = (PSOCacheEntry){0};
            }
        }
    }
}

// W27 P3.4 (chain 2). Python resolves these from the config
// (text_composition_strategy, text_fg_override_threshold) and hands them over
// directly. Before this they were recovered by string-scraping the `#define`s
// out of the preprocessed GLSL that Python passed to compile_shaders() — a
// graft-era channel that only worked because the Metal backend was wired into a
// GL API, and that made kitty/*.glsl load-bearing for Metal rendering config.
// Rebuilds the cell pipeline states only when a value actually changed: this is
// called on every config reload, and the old scrape invalidated unconditionally.
void
metal_set_cell_shader_opts(bool do_fg_override, int fg_override_algo, float fg_override_threshold, bool text_new_gamma) {
    if (cell_shader_opts.do_fg_override == do_fg_override &&
        cell_shader_opts.fg_override_algo == fg_override_algo &&
        cell_shader_opts.fg_override_threshold == fg_override_threshold &&
        cell_shader_opts.text_new_gamma == text_new_gamma) return;
    cell_shader_opts.do_fg_override = do_fg_override;
    cell_shader_opts.fg_override_algo = fg_override_algo;
    cell_shader_opts.fg_override_threshold = fg_override_threshold;
    cell_shader_opts.text_new_gamma = text_new_gamma;
    invalidate_cell_pipeline_states();
}

static id<MTLRenderPipelineState>
pso_get(int program, bool blend, MTLPixelFormat fmt, bool layered) {
    if (program < 0 || program >= NUM_PROGRAMS) return nil;
    // Resolved here rather than passed in, so every call site keeps its
    // signature and can never disagree with the pass being encoded.
    const MTLPixelFormat att1_fmt = layered ? drawable_attachment_format() : MTLPixelFormatInvalid;
    size_t base = (size_t)program * PSO_VARIANTS_PER_PROGRAM;
    size_t free_slot = SIZE_MAX;
    for (size_t i = base; i < base + PSO_VARIANTS_PER_PROGRAM; i++) {
        if (pso_cache[i].in_use) {
            if (pso_cache[i].blend == blend && pso_cache[i].fmt == fmt && pso_cache[i].layered == layered &&
                pso_cache[i].att1_fmt == att1_fmt) return pso_cache[i].pso;
        } else if (free_slot == SIZE_MAX) free_slot = i;
    }
    if (free_slot == SIZE_MAX) {
        log_error("Metal: pipeline state cache overflow for program %d", program);
        return nil;
    }
    id<MTLRenderPipelineState> pso = build_pso(program, blend, fmt, layered, att1_fmt);
    if (!pso) return nil;
    pso_cache[free_slot] = (PSOCacheEntry){.pso = pso, .fmt = fmt, .att1_fmt = att1_fmt, .blend = blend,
                                           .layered = layered, .in_use = true};
    return pso;
}

// Pipeline state creation helper
static id<MTLRenderPipelineState>
create_pipeline_state(NSString *vertex_fn, NSString *fragment_fn, bool enable_blend,
                      MTLVertexDescriptor *vertex_desc, MTLPixelFormat pixel_format,
                      bool layered, MTLPixelFormat att1_fmt, MTLFunctionConstantValues *constants) {
    if (!mtl_default_library) return nil;
    NSError *error = nil;

    id<MTLFunction> vert = constants ?
        [mtl_default_library newFunctionWithName:vertex_fn constantValues:constants error:&error] :
        [mtl_default_library newFunctionWithName:vertex_fn];
    if (!vert) {
        log_error("Metal: Failed to load vertex function '%s': %s",
            [vertex_fn UTF8String], error ? [[error localizedDescription] UTF8String] : "not found");
        return nil;
    }

    id<MTLFunction> frag = constants ?
        [mtl_default_library newFunctionWithName:fragment_fn constantValues:constants error:&error] :
        [mtl_default_library newFunctionWithName:fragment_fn];
    if (!frag) {
        log_error("Metal: Failed to load fragment function '%s': %s",
            [fragment_fn UTF8String], error ? [[error localizedDescription] UTF8String] : "not found");
        return nil;
    }

    MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
    desc.vertexFunction = vert;
    desc.fragmentFunction = frag;
    desc.colorAttachments[0].pixelFormat = pixel_format;
    if (layered) {
        // M1: two-attachment layered pass. att1 is the drawable, written only by
        // the resolve draw (its own PSO), so every compositing PSO masks it out
        // (it still writes att0 = the RGBA16Unorm working surface). Its format
        // must still match the pass (W27 P3.2: candidate, or BGRA8 in capture).
        desc.colorAttachments[1].pixelFormat = att1_fmt;
        desc.colorAttachments[1].writeMask = MTLColorWriteMaskNone;
    }
    if (vertex_desc) desc.vertexDescriptor = vertex_desc;

    if (enable_blend) {
        // Pre-multiplied alpha blending: src_factor=One, dst_factor=OneMinusSrcAlpha
        desc.colorAttachments[0].blendingEnabled = YES;
        desc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
        desc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        desc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
        desc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    }

    id<MTLRenderPipelineState> state = [mtl_device newRenderPipelineStateWithDescriptor:desc error:&error];
    if (!state) {
        log_error("Metal: Failed to create pipeline state for %s/%s: %s",
            [vertex_fn UTF8String], [fragment_fn UTF8String],
            [[error localizedDescription] UTF8String]);
    }
    return state;
}

// Vertex descriptor for the instanced cell programs (built once).
static MTLVertexDescriptor*
cell_vertex_descriptor(void) {
    static MTLVertexDescriptor *cell_vd = nil;
    if (!cell_vd) {
        cell_vd = [[MTLVertexDescriptor alloc] init];
        // Buffer 0: GPUCell data — attribute 0: colors (uvec3 = fg, bg, decoration_fg)
        cell_vd.attributes[0].format = MTLVertexFormatUInt3;
        cell_vd.attributes[0].offset = 0; // offsetof(GPUCell, fg)
        cell_vd.attributes[0].bufferIndex = 0;
        // attribute 1: sprite_idx (uvec2 = sprite_idx, attrs)
        cell_vd.attributes[1].format = MTLVertexFormatUInt2;
        cell_vd.attributes[1].offset = 12; // offsetof(GPUCell, sprite_idx)
        cell_vd.attributes[1].bufferIndex = 0;
        cell_vd.layouts[0].stride = 20; // sizeof(GPUCell), asserted in line.h
        cell_vd.layouts[0].stepFunction = MTLVertexStepFunctionPerInstance;
        cell_vd.layouts[0].stepRate = 1;
        // Buffer 1: selection data — attribute 2: is_selected (uint8)
        cell_vd.attributes[2].format = MTLVertexFormatUChar;
        cell_vd.attributes[2].offset = 0;
        cell_vd.attributes[2].bufferIndex = 5;
        cell_vd.layouts[5].stride = 1; // 1 byte per cell
        cell_vd.layouts[5].stepFunction = MTLVertexStepFunctionPerInstance;
        cell_vd.layouts[5].stepRate = 1;
    }
    return cell_vd;
}

// Build one pipeline state for (program, blend, attachment format).
// W27 P3.4: the target space the fragments must emit for a given attachment —
// i.e. who applies the linear->sRGB transfer. The values are defined once, in
// kitty/color_transfer.metal.h, which both this file and the shaders include,
// so the C side and the MSL cannot drift (a mismatch here would be a
// whole-gamma error that still compiles).
static int
target_color_space_for(MTLPixelFormat fmt, bool layered) {
    // Layered compositing draws target att0, the memoryless RGBA16Unorm working
    // surface, which is linear by construction. The resolve draw is the one that
    // faces the drawable and it resolves its own target space from att1.
    if (layered) return TARGET_SPACE_LINEAR;
    if (fmt == MTLPixelFormatBGRA10_XR_sRGB) return TARGET_SPACE_ROP_ENCODES;
    if (fmt == MTLPixelFormatBGRA10_XR || fmt == MTLPixelFormatRGBA16Float) return TARGET_SPACE_LINEAR;
    // Plain BGRA8Unorm: the default drawable, the capture offscreen, FBO targets.
    return TARGET_SPACE_ENCODE_SRGB;
}

// W27 P3.5: the primaries half of the attachment vocabulary. The wide arms'
// layers are tagged Display P3 (kitty_drawable_colorspace_name), so their
// fragments convert linear sRGB -> linear P3 at the exit; every BGRA8 target
// (default drawable, capture offscreen, FBO) and the layered working surface
// stay sRGB-primaries — the capture path remains a byte-stable sRGB control
// arm and the resolve converts for the whole layered stack. Same (fmt,
// layered) shape as target_color_space_for so the two halves of the
// attachment contract are specialized from the same inputs.
static bool
target_primaries_is_p3_for(MTLPixelFormat fmt, bool layered) {
    if (layered) return false;
    return fmt == MTLPixelFormatBGRA10_XR_sRGB || fmt == MTLPixelFormatBGRA10_XR || fmt == MTLPixelFormatRGBA16Float;
}

// Linear sRGB-primaries -> linear Display-P3-primaries, the C-side twin of the
// MSL srgb_to_p3() (values pinned once in kitty/color_transfer.metal.h).
static const double srgb_to_p3_matrix[3][3] = {
    { KITTY_SRGB_TO_P3_R0 },
    { KITTY_SRGB_TO_P3_R1 },
    { KITTY_SRGB_TO_P3_R2 },
};

// Programs that composite in LINEAR space and depend on the layered resolve to
// apply the transfer. They carry no target-space constant, so one of them
// rendering straight to the drawable would write linear values into an
// sRGB-encoded target — a whole-gamma error that still compiles and still runs.
static bool
program_is_layered_only(int program) {
    switch (program) {
        case 5: case 6: case 7:  // GRAPHICS, GRAPHICS_PREMULT, GRAPHICS_ALPHA_MASK
        case 8:                  // BGIMAGE
        case 9:                  // TINT
        case 10:                 // TRAIL
        case 13:                 // ROUNDED_RECT
            return true;
        default: return false;
    }
}

// W27 P3.4 invariant check. Today the layered-only property holds structurally:
// screen_needs_rendering_in_layers() (kitty/shaders.c) enumerates — term for
// term — exactly the UI that draw_cells_with_layers() draws with these
// programs (visual bell, drag overlay, scrollbar, progress bar, hyperlink
// target, window number, window logo, images), plus the background-image and
// cursor-trail terms in prepare_to_render_os_window(). draw_cells_without_
// layers() draws the cell program and nothing else. That pairing lives two
// files away from these shaders and nothing enforces it, so it is CHECKED here
// rather than assumed: build_pso sees every (program, layered) combination
// regardless of which call path produced it.
static void
layered_only_program_check(int program, bool layered) {
    if (layered || !program_is_layered_only(program)) return;
    if (global_state.debug_rendering) {
        fatal("Metal: program %d composites in linear space but a non-layered pipeline "
              "state was requested for it — screen_needs_rendering_in_layers() and "
              "draw_cells_with_layers() (kitty/shaders.c) have drifted apart", program);
    }
    // Not fatal in a normal build: a mis-encoded overlay is a cosmetic
    // degradation and killing the user's terminal over it would be worse. Once
    // per program — this runs per PSO build, not per frame, but a cache flush
    // (config reload) rebuilds them.
    static uint32_t reported = 0;
    if (program >= 0 && program < 32 && !(reported & (1u << program))) {
        reported |= 1u << program;
        log_error("Metal: program %d composites in linear space but is being built for a "
                  "non-layered pass; its output will be un-encoded on the drawable", program);
    }
}

// Program indices follow the enum in kitty/shaders.c: CELL=0, CELL_FG=1,
// CELL_BG=2, (sentinel)=3, BORDERS=4, GRAPHICS=5, GRAPHICS_PREMULT=6,
// GRAPHICS_ALPHA_MASK=7, BGIMAGE=8, TINT=9, TRAIL=10, BLIT=11,
// SCREENSHOT=12, ROUNDED_RECT=13.
static id<MTLRenderPipelineState>
build_pso(int program, bool blend, MTLPixelFormat fmt, bool layered, MTLPixelFormat att1_fmt) {
    if (!mtl_default_library) return nil;
    layered_only_program_check(program, layered);
    const int target_color_space = target_color_space_for(fmt, layered);
    const bool target_primaries_is_p3 = target_primaries_is_p3_for(fmt, layered);
    switch (program) {
        case 0: case 1: case 2: {
            MTLFunctionConstantValues *fc = [[MTLFunctionConstantValues alloc] init];
            bool only_fg = (program == 1);
            bool only_bg = (program == 2);
            [fc setConstantValue:&only_fg type:MTLDataTypeBool atIndex:0]; // ONLY_FOREGROUND
            [fc setConstantValue:&only_bg type:MTLDataTypeBool atIndex:1]; // ONLY_BACKGROUND
            [fc setConstantValue:&cell_shader_opts.do_fg_override type:MTLDataTypeBool atIndex:2]; // DO_FG_OVERRIDE
            [fc setConstantValue:&cell_shader_opts.fg_override_algo type:MTLDataTypeInt atIndex:3]; // FG_OVERRIDE_ALGO
            [fc setConstantValue:&cell_shader_opts.fg_override_threshold type:MTLDataTypeFloat atIndex:4]; // FG_OVERRIDE_THRESHOLD
            [fc setConstantValue:&cell_shader_opts.text_new_gamma type:MTLDataTypeBool atIndex:5]; // TEXT_NEW_GAMMA
            [fc setConstantValue:&target_color_space type:MTLDataTypeInt atIndex:6]; // TARGET_COLOR_SPACE
            [fc setConstantValue:&target_primaries_is_p3 type:MTLDataTypeBool atIndex:7]; // TARGET_PRIMARIES_IS_P3
            return create_pipeline_state(@"cell_vertex", @"cell_fragment", blend, cell_vertex_descriptor(), fmt, layered, att1_fmt, fc);
        }
        case 4: {
            MTLFunctionConstantValues *fc = [[MTLFunctionConstantValues alloc] init];
            [fc setConstantValue:&target_color_space type:MTLDataTypeInt atIndex:0]; // TARGET_COLOR_SPACE
            [fc setConstantValue:&target_primaries_is_p3 type:MTLDataTypeBool atIndex:1]; // TARGET_PRIMARIES_IS_P3
            return create_pipeline_state(@"border_vertex", @"border_fragment", blend, nil, fmt, layered, att1_fmt, fc);
        }
        case 5: case 6: case 7: {
            MTLFunctionConstantValues *fc = [[MTLFunctionConstantValues alloc] init];
            bool is_alpha_mask = (program == 7);
            bool is_premult = (program == 6);
            [fc setConstantValue:&is_alpha_mask type:MTLDataTypeBool atIndex:0];
            [fc setConstantValue:&is_premult type:MTLDataTypeBool atIndex:1];
            return create_pipeline_state(@"graphics_vertex", @"graphics_fragment", blend, nil, fmt, layered, att1_fmt, fc);
        }
        case 8: return create_pipeline_state(@"bgimage_vertex", @"bgimage_fragment", blend, nil, fmt, layered, att1_fmt, nil);
        case 9: return create_pipeline_state(@"tint_vertex", @"tint_fragment", blend, nil, fmt, layered, att1_fmt, nil);
        case 10: return create_pipeline_state(@"trail_vertex", @"trail_fragment", blend, nil, fmt, layered, att1_fmt, nil);
        case 11: return create_pipeline_state(@"blit_vertex", @"blit_fragment", blend, nil, fmt, layered, att1_fmt, nil);
        case 12: return create_pipeline_state(@"screenshot_vertex", @"screenshot_fragment", blend, nil, fmt, layered, att1_fmt, nil);
        case 13: return create_pipeline_state(@"rounded_rect_vertex", @"rounded_rect_fragment", blend, nil, fmt, layered, att1_fmt, nil);
        default: return nil; // 3 == CELL_PROGRAM_SENTINEL, never drawn
    }
}

// Pre-warm the drawable-format pipeline states so MSL/PSO errors surface at
// startup instead of mid-frame; FBO-format variants build lazily via pso_get.
static void
create_all_pipeline_states(void) {
    if (!mtl_default_library) return;
    int count = 0;
    // C1: the drawable is a single format — plain BGRA8Unorm by default, or the
    // W27 P3.2 candidate. sRGB is encoded in-shader (opaque cells/borders, only
    // when that format wants it) or in the resolve (layered), so the
    // BGRA8Unorm_sRGB drawable-view variant is gone.
    const MTLPixelFormat drawable_fmt = drawable_attachment_format();
    // W27 P3.4: only the cell programs and the borders ever render to the
    // drawable in a NON-layered pass (draw_cells_without_layers draws the cell
    // program and nothing else; draw_borders runs before the layered pass
    // opens). Every other program is layered-only — see
    // program_is_layered_only() — so pre-warming a drawable-format variant for
    // it built a pipeline state that could never be bound, and now would trip
    // the layered-only check. BLIT/SCREENSHOT target FBOs and build lazily.
    for (int p = 0; p <= 4; p++) {  // CELL, CELL_FG, CELL_BG, (sentinel), BORDERS
        if (p == 3) continue;       // CELL_PROGRAM_SENTINEL
        if (pso_get(p, false, drawable_fmt, false)) count++;
        if (pso_get(p, true, drawable_fmt, false)) count++;
    }
    // M1: pre-warm the layered two-attachment variants (att0 = RGBA16Unorm working
    // surface + att1 = drawable) for the programs that draw in the layered pass, so
    // MSL/PSO errors surface at startup and the first layered frame does not hitch.
    // BLIT (11, replaced by the native resolve) and SCREENSHOT (12) are never layered.
    // W27 P4.2: att0 is now per-frame (SDR RGBA16Unorm / EDR RGBA16Float), and
    // engagement can flip mid-session on any frame, so BOTH variants pre-warm —
    // otherwise the first frame after an HDR image appears pays the whole PSO
    // build inline, which is exactly the hitch this pre-warm exists to prevent.
    const MTLPixelFormat layered_fmts[2] = {LAYERED_WORK_FMT, LAYERED_WORK_FMT_EDR};
    for (int p = 0; p < NUM_PROGRAMS; p++) {
        if (p == 3 || p == 11 || p == 12) continue;
        for (size_t f = 0; f < arraysz(layered_fmts); f++) {
            if (pso_get(p, false, layered_fmts[f], true)) count++;
            if (pso_get(p, true, layered_fmts[f], true)) count++;
        }
    }
    for (size_t f = 0; f < arraysz(layered_fmts); f++) {
        if (ensure_layers_resolve_pso(layered_fmts[f], drawable_fmt)) count++;
    }
    if (global_state.debug_rendering) {
        NSLog(@"[Metal] Pre-warmed %d pipeline states", count);
    }
}

Program*
program_ptr(int program) { return programs + (size_t)program; }

GLuint
program_id(int program) { return programs[program].id; }

void
init_uniforms(int program) {
    Program *p = programs + program;
    // In Metal, uniforms are passed via buffers, not introspected from programs.
    // We still maintain the uniform array for API compatibility with shaders.c
    // but locations are just sequential indices.
    p->num_of_uniforms = 0;
}

GLint
get_uniform_location(int program, const char *name) {
    // In Metal, uniform locations are meaningless. Return a hash-based index
    // for tracking purposes. The actual data is passed via setVertexBytes/setFragmentBytes.
    Program *p = programs + program;
    const size_t n = strlen(name) + 1;
    for (GLint i = 0; i < p->num_of_uniforms; i++) {
        if (strncmp(p->uniforms[i].name, name, n) == 0) return p->uniforms[i].location;
    }
    // Add new uniform entry
    if (p->num_of_uniforms < 256) {
        Uniform *u = &p->uniforms[p->num_of_uniforms];
        snprintf(u->name, sizeof(u->name), "%s", name);
        u->location = p->num_of_uniforms;
        u->idx = p->num_of_uniforms;
        u->size = 1;
        u->type = GL_FLOAT;
        p->num_of_uniforms++;
        return u->location;
    }
    return -1;
}

// C5: the graphics rect arrays in MetalGraphicsUniforms are sized [16*4]; pin the
// instance count the shim marshals so a MAX_IMAGE_INSTANCES change can't silently
// under/over-run them (metal_uniforms.h can't see this state.h macro).
_Static_assert(MAX_IMAGE_INSTANCES == 16, "MetalGraphicsUniforms rect arrays are sized for 16 instances");

// C5: direct MSL-layout uniform fills. Each program's uniform slot is now the
// generated <CLASS>_U_<name> enumerator (uniforms_generated.h, from
// SHADER_UNIFORMS in setup.py) instead of a runtime find_uniform_slot() string
// lookup cached per-program: since get_uniform_locations_<name>() calls
// get_uniform_location() in exactly the enum's declaration order, the
// enumerator IS the slot index get_uniform_location assigned, at compile time.
// A renamed/reordered manifest entry now fails the build (undeclared
// identifier / wrong index) instead of silently zero-filling at draw time.
// Programs with variant siblings (cell 0-2, graphics 5-7) register identical
// names in identical order via the same get_uniform_locations_* call, so their
// slots match; VALUES are always read from the passed program's store. The
// byte-identical golden set cross-checks the whole path.
static inline float
slot_f(int program, GLint s, int comp) {
    return s >= 0 ? uniform_stores[program].values[s].f[comp] : 0.f;
}
static inline void
slot_fv(int program, GLint s, float *dest, int n) {
    for (int i = 0; i < n; i++) dest[i] = s >= 0 ? uniform_stores[program].values[s].f[i] : 0.f;
}

static void
fill_cell_draw_uniforms(int program, MetalCellDrawUniforms *u) {
    u->draw_bg_bitfield = uniform_stores[program].values[CELL_U_draw_bg_bitfield].u[0];
    u->row_offset = slot_f(program, CELL_U_row_offset, 0);
    u->text_contrast = slot_f(program, CELL_U_text_contrast, 0);
    u->text_gamma_adjustment = slot_f(program, CELL_U_text_gamma_adjustment, 0);
}

static void
fill_border_uniforms(int program, MetalBorderUniforms *u) {
    memset(u, 0, sizeof(*u));
    int base = ARRAY_UNIFORM_BASE + BORDER_U_colors * 16;
    for (int i = 0; i < 9 && base + i < MAX_UNIFORMS_PER_PROGRAM; i++)
        u->colors[i] = uniform_stores[program].values[base + i].u[0];
    u->background_opacity = slot_f(program, BORDER_U_background_opacity, 0);
    if (cached_gamma_lut) memcpy(u->gamma_lut, cached_gamma_lut, sizeof(u->gamma_lut));
}

static void
fill_graphics_uniforms(int program, MetalGraphicsUniforms *u) {
    memset(u, 0, sizeof(*u));
    {
        int base = ARRAY_UNIFORM_BASE + GRAPHICS_U_src_rects * 16;
        for (int i = 0; i < MAX_IMAGE_INSTANCES && base + i < MAX_UNIFORMS_PER_PROGRAM; i++)
            for (int c = 0; c < 4; c++) u->src_rects[i * 4 + c] = uniform_stores[program].values[base + i].f[c];
    }
    {
        int base = ARRAY_UNIFORM_BASE + GRAPHICS_U_dest_rects * 16;
        for (int i = 0; i < MAX_IMAGE_INSTANCES && base + i < MAX_UNIFORMS_PER_PROGRAM; i++)
            for (int c = 0; c < 4; c++) u->dest_rects[i * 4 + c] = uniform_stores[program].values[base + i].f[c];
    }
    u->extra_alpha = slot_f(program, GRAPHICS_U_extra_alpha, 0);
    slot_fv(program, GRAPHICS_U_amask_fg, u->amask_fg, 3);
    slot_fv(program, GRAPHICS_U_amask_bg_premult, u->amask_bg_premult, 4);
    // W27 P4.2 tone-map inputs. The floor at 1.0 is load-bearing rather than
    // cosmetic: edr_headroom is the shader's hard ceiling, so an unset (0.0)
    // slot would clamp the image to black. Every real draw sets it, and this
    // makes a draw that somehow did not merely SDR rather than broken.
    const float hr = slot_f(program, GRAPHICS_U_edr_headroom, 0);
    u->edr_headroom = hr >= 1.f ? hr : 1.f;
    u->src_is_hdr = slot_f(program, GRAPHICS_U_src_is_hdr, 0);
    u->src_max_component = slot_f(program, GRAPHICS_U_src_max_component, 0);
}

static void
fill_bgimage_uniforms(int program, MetalBgimageUniforms *u) {
    memset(u, 0, sizeof(*u));
    slot_fv(program, BGIMAGE_U_sizes, u->sizes, 4);
    slot_fv(program, BGIMAGE_U_positions, u->positions, 4);
    slot_fv(program, BGIMAGE_U_background, u->background, 4);
    u->tiled = slot_f(program, BGIMAGE_U_tiled, 0);
}

static void
fill_tint_uniforms(int program, MetalTintUniforms *u) {
    slot_fv(program, TINT_U_tint_color, u->tint_color, 4);
    slot_fv(program, TINT_U_edges, u->edges, 4);
}

static void
fill_trail_uniforms(int program, MetalTrailUniforms *u) {
    memset(u, 0, sizeof(*u));
    slot_fv(program, TRAIL_U_x_coords, u->x_coords, 4);
    slot_fv(program, TRAIL_U_y_coords, u->y_coords, 4);
    slot_fv(program, TRAIL_U_cursor_edge_x, u->cursor_edge_x, 2);
    slot_fv(program, TRAIL_U_cursor_edge_y, u->cursor_edge_y, 2);
    slot_fv(program, TRAIL_U_trail_color, u->trail_color, 3);
    u->trail_opacity = slot_f(program, TRAIL_U_trail_opacity, 0);
}

static void
fill_blit_uniforms(int program, MetalBlitUniforms *u) {
    slot_fv(program, BLIT_U_src_rect, u->src_rect, 4);
    slot_fv(program, BLIT_U_dest_rect, u->dest_rect, 4);
}

static void
fill_screenshot_uniforms(int program, MetalScreenshotUniforms *u) {
    memset(u, 0, sizeof(*u));
    slot_fv(program, SCREENSHOT_U_src_rect, u->src_rect, 4);
    slot_fv(program, SCREENSHOT_U_dest_rect, u->dest_rect, 4);
    slot_fv(program, SCREENSHOT_U_src_size, u->src_size, 2);
}

static void
fill_rounded_rect_uniforms(int program, MetalRoundedRectUniforms *u) {
    memset(u, 0, sizeof(*u));
    slot_fv(program, ROUNDED_RECT_U_color, u->color, 4);
    slot_fv(program, ROUNDED_RECT_U_background_color, u->background_color, 4);
    slot_fv(program, ROUNDED_RECT_U_rect, u->rect, 4);
    slot_fv(program, ROUNDED_RECT_U_params, u->params, 2);
}

// Number of entries in the ColorTable UBO: NUM_COLORS + MARK_MASK + MARK_MASK + 2
// (mirrors the array length in cell_vertex.glsl)
#define METAL_COLOR_TABLE_ENTRIES (256u + MARK_MASK + MARK_MASK + 2u)

GLint
get_uniform_information(int program, const char *name, GLenum information_type) {
    // The shim owns the introspection ABI: report tightly packed layouts so
    // the shared C writers produce exactly the memory the MSL shaders read.
    (void)program; (void)name;
    switch (information_type) {
        case GL_UNIFORM_SIZE: return METAL_COLOR_TABLE_ENTRIES;
        case GL_UNIFORM_OFFSET: return 0; // ColorTable lives in its own buffer
        case GL_UNIFORM_ARRAY_STRIDE: return sizeof(uint32_t); // packed uint[]
        default: return 0;
    }
}

GLint
attrib_location(int program, const char *name) {
    (void)program; (void)name;
    // Attribute locations are determined by vertex descriptor in Metal
    // Return 0 for all — actual binding happens in vertex descriptor setup
    return 0;
}

GLuint
block_index(int program, const char *name) {
    (void)program;
    if (name && strcmp(name, "ColorTable") == 0) return 1;
    return 0; // CellRenderData (and any other block)
}

// W27 P3.5b: the wide-gamut colour carrier's GPU-side float4 table rides
// alongside the packed uint ColorTable in the SAME MTLBuffer (bound a second
// time at a fixed byte offset -- see the ColorTable bind site below), so the
// buffer this size drives must be grown to fit both regions.
#define METAL_WIDE_COLOR_TABLE_BYTES (METAL_COLOR_TABLE_ENTRIES * 4u * sizeof(float))

GLint
block_size(int program, GLuint bidx) {
    (void)program;
    if (bidx == 1) return (GLint)(METAL_COLOR_TABLE_ENTRIES * sizeof(uint32_t) + METAL_WIDE_COLOR_TABLE_BYTES);
    return sizeof(MetalCellRenderData);
}

void
bind_program(int program) {
    current_program = program;
}

void
unbind_program(void) {
    current_program = -1;
}

// ----- Buffers -----

// D1: persistent fenced buffer ring. Each frequently-written logical buffer
// (cell, selection, uniform, color-table) becomes a small ring of resident
// MTLBuffers so steady-state rendering performs ZERO allocations, replacing the
// Wave-1 fresh-buffer-per-frame orphaning. Recycling is gated by explicit GPU
// completion (see ring_acquire_slot / stamp_ring_fences), never by the
// committed-CB-retains-the-buffer accident (Wave-1 hazard H3).
//
// Depth: with maximumDrawableCount=2 at most 2 frames reference a given buffer
// concurrently, so 3 slots always leave one GPU-idle slot to hand out. Slots
// grow lazily on demand up to BUFFER_RING_MAX (a safety cap above the working
// set of 3); the scan-based acquire naturally stabilizes at frames-in-flight+1.
#define BUFFER_RING_MAX 4

typedef struct {
    id<MTLBuffer> buf;              // owning +1 (MRC); released in delete_buffer / on grow
    void *ptr;                      // buf.contents (shared storage), cached
    GLsizeiptr size;                // this slot's allocation capacity (grow-only)
    id<MTLCommandBuffer> fence_cb;  // owning +1: the command buffer that last read
                                    // this slot; nil == free. Stamped at draw time.
    bool fresh;                     // D2: buffer was just (re)allocated => contents are
                                    // garbage; the cell-buffer partial-upload path must
                                    // do a full write before trusting a memcmp against it.
} MetalRingSlot;

typedef struct {
    id<MTLBuffer> mtl_buffer;   // ring: alias of ring[ring_head].buf (NOT owning);
                                // non-ring: the single owning buffer (borders)
    GLsizeiptr size;            // logical requested size
    GLenum usage;
    void *mapped_ptr;           // ring: ring[ring_head].ptr; non-ring: mtl_buffer.contents
    bool in_use;
    // D1 ring state (only populated once a buffer takes a ring write path)
    bool is_ring;
    int ring_count;             // slots allocated so far (0..BUFFER_RING_MAX)
    int ring_head;              // index of the current (newest) slot
    MetalRingSlot ring[BUFFER_RING_MAX];
} MetalBuffer;

#define MAX_CHILDREN 512
static MetalBuffer buffers[MAX_CHILDREN * 6 + 4];
static size_t buffer_count = 0;

// D1: MTLBuffer allocations performed while encoding the current frame (initial
// ring fill + grows). Emitted as the metal_stats allocs= field so verification
// can assert 0 in steady state. Written on the main (encode) thread only.
static int metal_frame_alloc_count = 0;

// G1: MTLTexture (re)allocations this frame -- newTextureWithDescriptor in
// metal_gl_tex_image_2d, the image-texture upload path. Before G1 an animation
// frame advance re-specced the whole texture every frame (1 alloc/advance);
// after G1 the steady-state path is replaceRegion (0). Emitted as tex_allocs=
// so verification can assert 0 texture allocs per steady-state animation frame.
static int metal_frame_tex_alloc_count = 0;

// G3-lite: bytes replaceRegion'd into IMAGE textures this frame (the graphics
// SubImage path: GL_RGB/GL_RGBA source into the RGBA image texture). Emitted as
// tex_bytes=. G1 alone uploads the full image each animation frame; G3-lite drops
// this to just the frame's delta rect when the delta is a non-blended copy.
static uint64_t metal_frame_tex_upload_bytes = 0;

// G2: graphics-program (image) draw calls this frame. Emitted as gfx_draws=.
// Instancing collapses a same-texture group's N refs into one draw; the kill
// switch KITTY_NO_INSTANCED_IMAGE_DRAWS=1 keeps the old one-draw-per-ref count.
static int metal_frame_gfx_draw_count = 0;

// D2: bytes written into per-frame VAO ring buffers this frame (cell dirty rows +
// selection + uniform + color-table). Emitted as the metal_stats bytes= field —
// the ≤8KB 1-line-edit exit-gate probe. Main (encode) thread only.
static uint64_t metal_frame_bytes_uploaded = 0;

void
metal_note_upload_bytes(uint64_t n) { metal_frame_bytes_uploaded += n; }

static ssize_t
create_buffer(GLenum usage) {
    // A slot is free only when explicitly released: a created-but-not-yet
    // allocated buffer has no MTLBuffer, and treating it as free hands the
    // same slot to two VAO buffers (the UBO then overwrites the selection
    // map — the G4-D1/G4-D2 corruption).
    for (size_t i = 0; i < sizeof(buffers)/sizeof(buffers[0]); i++) {
        if (!buffers[i].in_use) {
            buffers[i].size = 0;
            buffers[i].usage = usage;
            buffers[i].mtl_buffer = nil;
            buffers[i].mapped_ptr = NULL;
            buffers[i].in_use = true;
            // delete_buffer fully tears down the ring, so a recycled slot starts
            // clean; reset defensively in case this index was never used.
            buffers[i].is_ring = false;
            buffers[i].ring_count = 0;
            buffers[i].ring_head = 0;
            if (i >= buffer_count) buffer_count = i + 1;
            return i;
        }
    }
    fatal("Too many Metal buffers");
    return -1;
}

static void
delete_buffer(ssize_t buf_idx) {
    // This file builds under MRC: newBufferWithLength returns +1, so drop
    // the reference explicitly. mapped_ptr points into the MTLBuffer's
    // memory and must never be free()d.
    MetalBuffer *b = &buffers[buf_idx];
    if (b->is_ring) {
        // Ring slots own their buffers and fence command buffers; b->mtl_buffer
        // is only an alias of the current slot, so it must NOT be released here
        // (that would double-release the slot freed in this loop).
        for (int i = 0; i < b->ring_count; i++) {
            if (b->ring[i].buf) [b->ring[i].buf release];
            if (b->ring[i].fence_cb) [b->ring[i].fence_cb release];
            b->ring[i].buf = nil; b->ring[i].fence_cb = nil;
            b->ring[i].ptr = NULL; b->ring[i].size = 0; b->ring[i].fresh = false;
        }
        b->mtl_buffer = nil;
    } else if (b->mtl_buffer) {
        [b->mtl_buffer release];
        b->mtl_buffer = nil;
    }
    b->is_ring = false;
    b->ring_count = 0;
    b->ring_head = 0;
    b->mapped_ptr = NULL;
    b->size = 0;
    b->in_use = false;
}

static void
alloc_buffer_data(ssize_t idx, GLsizeiptr size) {
    MetalBuffer *b = &buffers[idx];
    if (b->size == size && b->mtl_buffer) return;
    b->size = size;
    if (b->mtl_buffer) { [b->mtl_buffer release]; b->mtl_buffer = nil; }
    b->mapped_ptr = NULL;
    if (size == 0) {
        // Metal doesn't allow zero-length buffers — allocate minimum 4 bytes
        size = 4;
    }
    b->mtl_buffer = [mtl_device newBufferWithLength:size options:MTLResourceStorageModeShared];
    b->mapped_ptr = b->mtl_buffer ? b->mtl_buffer.contents : NULL;
}

// ----- VAO -----

typedef struct {
    bool in_use;
    size_t num_buffers;
    ssize_t buffers[10];
} MetalVAO;

static MetalVAO vaos[4*MAX_CHILDREN + 10] = {{0}};

ssize_t
create_vao(void) {
    for (size_t i = 0; i < sizeof(vaos)/sizeof(vaos[0]); i++) {
        if (!vaos[i].in_use) {
            vaos[i].in_use = true;
            vaos[i].num_buffers = 0;
            return i;
        }
    }
    fatal("Too many Metal VAOs");
    return -1;
}

size_t
add_buffer_to_vao(ssize_t vao_idx, GLenum usage) {
    MetalVAO *vao = &vaos[vao_idx];
    if (vao->num_buffers >= sizeof(vao->buffers) / sizeof(vao->buffers[0])) {
        fatal("Too many buffers in a single VAO");
    }
    ssize_t buf = create_buffer(usage);
    vao->buffers[vao->num_buffers++] = buf;
    return vao->num_buffers - 1;
}

void
add_attribute_to_vao(int p, ssize_t vao_idx, const char *name, GLint size, GLenum data_type, GLsizei stride, void *offset, GLuint divisor) {
    (void)p; (void)vao_idx; (void)name; (void)size; (void)data_type; (void)stride; (void)offset; (void)divisor;
    // In Metal, vertex attributes are configured via MTLVertexDescriptor during pipeline creation.
    // This is a no-op stub; the actual vertex descriptor is built in compile_shaders().
}

void
remove_vao(ssize_t vao_idx) {
    MetalVAO *vao = &vaos[vao_idx];
    while (vao->num_buffers) {
        vao->num_buffers--;
        delete_buffer(vao->buffers[vao->num_buffers]);
    }
    vao->in_use = false;
}

void
bind_vertex_array(ssize_t vao_idx) {
    current_bound_vao = vao_idx;
}

void
unbind_vertex_array(void) {
    current_bound_vao = -1;
}

ssize_t
alloc_vao_buffer(ssize_t vao_idx, GLsizeiptr size, size_t bufnum, GLenum usage) {
    (void)usage;
    ssize_t buf_idx = vaos[vao_idx].buffers[bufnum];
    alloc_buffer_data(buf_idx, size);
    return buf_idx;
}

// D1: hand out a ring slot of buffer b whose GPU work is guaranteed complete,
// and make it current (b->mtl_buffer / b->mapped_ptr alias it). A slot is
// reusable when its fence command buffer is nil (never used) or has completed;
// stamp_ring_fences() ties each slot to the exact command buffer that reads it,
// so this is correct regardless of how command buffers from multiple OS windows
// interleave on the single command queue (fence-by-completion, not by luck).
//
// Slots are marked MTLResourceHazardTrackingModeUntracked [C3b]: the ring
// discipline (never write a slot the fence says is still in flight; buffers are
// only ever GPU-READ, never GPU-written) removes every hazard Metal's automatic
// tracking would guard, so tracking is pure overhead here.
static MetalRingSlot*
ring_acquire_slot(MetalBuffer *b) {
    b->is_ring = true;
    int chosen = -1;
    for (int i = 0; i < b->ring_count; i++) {
        MetalRingSlot *s = &b->ring[i];
        if (!s->fence_cb || s->fence_cb.status == MTLCommandBufferStatusCompleted) {
            if (s->fence_cb) { [s->fence_cb release]; s->fence_cb = nil; }
            chosen = i; break;
        }
    }
    if (chosen < 0) {
        if (b->ring_count < BUFFER_RING_MAX) {
            chosen = b->ring_count++;
            MetalRingSlot *s = &b->ring[chosen];
            s->buf = nil; s->ptr = NULL; s->size = 0; s->fence_cb = nil;
        } else {
            // Pathological: every slot still referenced by in-flight GPU work
            // AND the ring is at its safety cap. Cannot happen with depth 3 and
            // maximumDrawableCount=2, but never hand out an in-flight buffer:
            // block on the oldest slot (the single queue guarantees progress).
            chosen = 0;
            MetalRingSlot *s = &b->ring[chosen];
            while (s->fence_cb && s->fence_cb.status != MTLCommandBufferStatusCompleted) sched_yield();
            if (s->fence_cb) { [s->fence_cb release]; s->fence_cb = nil; }
        }
    }
    MetalRingSlot *s = &b->ring[chosen];
    GLsizeiptr need = b->size > 0 ? b->size : 4; // Metal forbids zero-length buffers
    if (!s->buf || s->size < need) {
        id<MTLBuffer> fresh = [mtl_device newBufferWithLength:need
                                                     options:MTLResourceStorageModeShared | MTLResourceHazardTrackingModeUntracked];
        if (fresh) {
            if (s->buf) [s->buf release];
            s->buf = fresh;
            s->ptr = fresh.contents;
            s->size = need;
            s->fresh = true; // D2: garbage contents until the first full write
            metal_frame_alloc_count++;
        }
    }
    b->ring_head = chosen;
    b->mtl_buffer = s->buf;
    b->mapped_ptr = s->ptr;
    return s;
}

void*
alloc_and_map_vao_buffer(ssize_t vao_idx, GLsizeiptr size, size_t bufnum, bool frequently_updated) {
    ssize_t buf_idx = vaos[vao_idx].buffers[bufnum];
    MetalBuffer *b = &buffers[buf_idx];
    if (frequently_updated) {
        // Full-buffer rewrite (GL_STREAM_DRAW + glMapBuffer): the caller
        // overwrites the whole buffer this frame (screen_update_cell_data /
        // screen_apply_selection), so return a GPU-idle ring slot with NO
        // contents copy. Steady state (constant grid) reuses slots: zero allocs.
        b->size = size;
        b->usage = GL_STREAM_DRAW;
        ring_acquire_slot(b);
        return b->mapped_ptr;
    }
    // Not frequently updated (borders): keep the single hazard-tracked buffer,
    // reused in place. Writes are rare (rect_data_is_dirty) and there is no
    // steady-state allocation, so it stays outside the ring.
    alloc_buffer_data(buf_idx, size);
    return b->mapped_ptr;
}

// D2: report (and consume) whether the ring slot just handed out for buffer
// `bufnum` was freshly (re)allocated — i.e. its contents are garbage and the
// caller must do a FULL write rather than a per-row memcmp diff. Call this
// immediately after alloc_and_map_vao_buffer(...true) for the cell buffer.
// Returns true (force full) for non-ring/edge cases so callers stay safe.
bool
metal_cell_ring_take_fresh(ssize_t vao_idx, size_t bufnum) {
    ssize_t buf_idx = vaos[vao_idx].buffers[bufnum];
    MetalBuffer *b = &buffers[buf_idx];
    if (!b->is_ring || b->ring_count == 0) return true;
    MetalRingSlot *s = &b->ring[b->ring_head];
    bool was_fresh = s->fresh;
    s->fresh = false;
    return was_fresh;
}

void*
map_vao_buffer(ssize_t vao_idx, size_t bufnum, GLenum access) {
    (void)access;
    ssize_t buf_idx = vaos[vao_idx].buffers[bufnum];
    return buffers[buf_idx].mapped_ptr;
}

// GL's glMapBufferRange(WRITE|INVALIDATE) lets the driver hand back fresh
// storage while the previous frame keeps reading the old allocation. The ring
// reproduces that without allocating: hand out a GPU-idle slot. Because a caller
// may write only [offset, offset+size) (D2's per-line uploads) and GL preserves
// bytes outside the invalidated range, the new slot is seeded (copy-forward)
// from the newest slot — so slot content == the last full write into the ring,
// exactly the map_vao_buffer_for_write_only contract. For D1 every caller still
// writes the whole buffer at offset 0, so the copy is currently redundant but
// keeps the invariant D2 builds on.
void*
map_vao_buffer_for_write_only(ssize_t vao_idx, size_t bufnum, int offset, unsigned size) {
    (void)size;
    ssize_t buf_idx = vaos[vao_idx].buffers[bufnum];
    MetalBuffer *b = &buffers[buf_idx];
    if (b->size <= 0) {
        // Never sized (should not happen: uniform/color-table are alloc'd at VAO
        // creation) — fall back to whatever single buffer exists.
        if (!b->mapped_ptr && b->mtl_buffer) b->mapped_ptr = b->mtl_buffer.contents;
        return b->mapped_ptr ? (uint8_t*)b->mapped_ptr + offset : NULL;
    }
    // First ring use: drop the single buffer pre-allocated by alloc_vao_buffer()
    // at VAO creation so it is not leaked (b->mtl_buffer becomes a ring alias).
    if (!b->is_ring && b->mtl_buffer) {
        [b->mtl_buffer release];
        b->mtl_buffer = nil;
        b->mapped_ptr = NULL;
    }
    // Capture the newest slot BEFORE acquiring (ring_acquire_slot moves ring_head).
    id<MTLBuffer> prevbuf = (b->is_ring && b->ring_count > 0) ? b->ring[b->ring_head].buf : nil;
    GLsizeiptr prevsize = (b->is_ring && b->ring_count > 0) ? b->ring[b->ring_head].size : 0;
    MetalRingSlot *s = ring_acquire_slot(b);
    if (prevbuf && prevbuf != s->buf) {
        GLsizeiptr copyable = prevsize < b->size ? prevsize : b->size;
        if (copyable > 0) memcpy(s->ptr, prevbuf.contents, (size_t)copyable);
    }
    if (!b->mapped_ptr) return NULL;
    return (uint8_t*)b->mapped_ptr + offset;
}

void
unmap_vao_buffer(ssize_t vao_idx, size_t bufnum) {
    (void)vao_idx; (void)bufnum;
    // With MTLStorageModeShared, there's no unmap step needed.
    // The GPU sees writes immediately through unified memory.
}

void
bind_vao_uniform_buffer(ssize_t vao_idx, size_t bufnum, GLuint bidx) {
    (void)bidx; (void)bufnum;
    current_bound_vao = vao_idx;
}

// ----- Textures -----

typedef struct {
    id<MTLTexture> texture;
    GLenum target; // GL_TEXTURE_2D or GL_TEXTURE_2D_ARRAY
    int width, height, depth;
    // US-307: newest frame index whose command buffer bound this texture for a
    // graphics draw. Compared against the completion watermark to tell whether an
    // async-presented committed frame may still be sampling it (see
    // texture_upload_in_flight). Written on the main thread (draw + realloc).
    uint64_t last_drawn_fidx;
} MetalTexture;

#define MAX_TEXTURES 1024
static MetalTexture textures[MAX_TEXTURES];
static GLuint texture_id_counter = 1; // 0 means unused

static MetalTexture*
get_texture(GLuint tex_id) {
    if (tex_id == 0 || tex_id >= MAX_TEXTURES) return NULL;
    return &textures[tex_id];
}

// ----- Framebuffers -----

typedef struct {
    bool in_use;
    GLuint attached_texture_id;
    id<MTLTexture> render_target;
} MetalFramebuffer;

#define MAX_FRAMEBUFFERS 32
static MetalFramebuffer framebuffers[MAX_FRAMEBUFFERS];
static GLuint framebuffer_id_counter = 1;

// ----- GL Init -----

void
gl_init(void) {
    static bool initialized = false;
    if (initialized) return;
    METAL_TRACE("gl_init: binary built " __DATE__ " " __TIME__ "\n");

    mtl_device = MTLCreateSystemDefaultDevice();
    if (!mtl_device) {
        fatal("Metal is not supported on this system");
    }

    mtl_command_queue = [mtl_device newCommandQueue];
    if (!mtl_command_queue) {
        fatal("Failed to create Metal command queue");
    }

    // Load compiled Metal shader library (.metallib)
    NSError *error = nil;

    // Build search paths: bundle Resources, next to executable, kitty/ subdir, cwd
    NSMutableArray<NSString *> *searchPaths = [NSMutableArray array];

    // 1. App bundle Resources directory
    NSString *bundlePath = [[NSBundle mainBundle] pathForResource:@"default" ofType:@"metallib"];
    if (bundlePath) [searchPaths addObject:bundlePath];

    // 2. Next to the executable (for development builds)
    NSString *execDir = [[[NSBundle mainBundle] executablePath] stringByDeletingLastPathComponent];
    [searchPaths addObject:[execDir stringByAppendingPathComponent:@"default.metallib"]];
    // 3. In ../Resources relative to executable (standard bundle layout)
    [searchPaths addObject:[[execDir stringByAppendingPathComponent:@"../Resources/default.metallib"] stringByStandardizingPath]];
    // 4. kitty/ subdirectory from executable's grandparent (dev layout: kitty.app/Contents/MacOS/kitty → ../../.. → kitty/)
    NSString *devRoot = [[[execDir stringByAppendingPathComponent:@"../../.."] stringByStandardizingPath] stringByAppendingPathComponent:@"kitty/default.metallib"];
    [searchPaths addObject:devRoot];
    // 5. Working directory fallbacks
    [searchPaths addObject:@"kitty/default.metallib"];
    [searchPaths addObject:@"default.metallib"];

    for (NSString *path in searchPaths) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
            NSURL *url = [NSURL fileURLWithPath:path];
            mtl_default_library = [mtl_device newLibraryWithURL:url error:&error];
            if (mtl_default_library) {
                METAL_TRACE("gl_init: loaded metallib from %s (functions: %s)\n",
                    [path UTF8String], [[[mtl_default_library functionNames] componentsJoinedByString:@","] UTF8String]);
                break;
            }
        }
    }
    if (!mtl_default_library) {
        mtl_default_library = [mtl_device newDefaultLibrary];
        METAL_TRACE("gl_init: fell back to newDefaultLibrary -> %d\n", mtl_default_library != nil);
    }
    if (!mtl_default_library) {
        log_error("Metal: No shader library found. Searched: %s", [[searchPaths componentsJoinedByString:@", "] UTF8String]);
    }
    METAL_TRACE("gl_init: lib=%d fns=%s\n", mtl_default_library != nil,
        mtl_default_library ? [[[mtl_default_library functionNames] componentsJoinedByString:@","] UTF8String] : "none");

    global_state.gl_version = (3 << 16) | 3; // Report as "3.3" for compatibility
    global_state.supports_framebuffer_srgb = true;

    // Create render pipeline states from the loaded metallib
    create_all_pipeline_states();

    initialized = true;

    if (global_state.debug_rendering) {
        log_error("[Metal] Initialized device: %s, library: %s, pipelines: %d",
            mtl_device ? [mtl_device.name UTF8String] : "nil",
            mtl_default_library ? "loaded" : "MISSING",
            pso_get(0, false, drawable_attachment_format(), false) ? NUM_PROGRAMS : 0);
    }
}

const char*
gl_version_string(void) {
    static char buf[256];
    snprintf(buf, sizeof(buf), "Metal (%s)", mtl_device ? [mtl_device.name UTF8String] : "no device");
    return buf;
}

// ----- Viewport -----

void
set_gpu_viewport(unsigned w, unsigned h) {
    mtl_viewport = (MTLViewport){0, 0, (double)w, (double)h, 0, 1};
    // Update the layer's drawableSize to match the viewport (the real
    // drawable size on the legacy CAMetalLayer; the stored mirror property —
    // drawable size on the CAMetalLayer)
    if (mtl_current_layer) {
        CGSize desired = CGSizeMake(w, h);
        if (!CGSizeEqualToSize(mtl_current_layer.drawableSize, desired)) {
            mtl_current_layer.drawableSize = desired;
        }
    }
}

Viewport
get_gpu_viewport(void) {
    return (Viewport){
        .left = (unsigned)mtl_viewport.originX,
        .top = (unsigned)mtl_viewport.originY,
        .width = (unsigned)mtl_viewport.width,
        .height = (unsigned)mtl_viewport.height
    };
}

void
save_viewport_using_bottom_left_origin(GLsizei newx, GLsizei newy, GLsizei width, GLsizei height) {
    if (saved_viewports.used >= arraysz(saved_viewports.items)) fatal("Too many nested saved viewports");
    saved_viewports.items[saved_viewports.used++] = mtl_viewport;
    // Metal uses top-left origin natively, convert from bottom-left
    // Note: In Metal the viewport origin is top-left, so we need the full height to convert
    mtl_viewport = (MTLViewport){(double)newx, (double)newy, (double)width, (double)height, 0, 1};
}

void
save_viewport_using_top_left_origin(GLsizei newx, GLsizei newy, GLsizei width, GLsizei height, GLsizei full_framebuffer_height) {
    (void)full_framebuffer_height;
    if (saved_viewports.used >= arraysz(saved_viewports.items)) fatal("Too many nested saved viewports");
    saved_viewports.items[saved_viewports.used++] = mtl_viewport;
    // Metal uses top-left origin natively — no conversion needed
    mtl_viewport = (MTLViewport){(double)newx, (double)newy, (double)width, (double)height, 0, 1};
}

void
restore_viewport(void) {
    if (!saved_viewports.used) fatal("Trying to restore a viewport when none is saved");
    mtl_viewport = saved_viewports.items[--saved_viewports.used];
}

// ----- Drawing -----

static int dq_log_count = 0;
static int metal_frame_counter = 0;

// Phase 0 per-frame instrumentation. metal_frame_index is a process-wide
// monotonic id used to correlate the stats and present records; unlike
// metal_frame_counter it advances every frame regardless of KITTY_METAL_LOG.
// metal_pass_count (render passes/encoders opened this frame — the
// acceptance-criterion-2 probe) and metal_frame_encode_start (CACurrentMediaTime
// captured AFTER the drawable is acquired — see the p99 fix in ensure_drawable —
// so encode_ms measures command encoding, NOT drawable-acquisition blocking) are
// per current window: saved/restored with the window slot below.
// metal_frame_drawable_wait accumulates time spent in nextDrawable this frame
// (emitted as drawable_wait_ms); with maximumDrawableCount=2 this is where the
// keypress-to-photon backpressure actually lives, so it is measured separately.
// H1 first-frame sentinel: frame indices start at 1, not 0, because
// last_drawn_fidx == 0 is the "never drawn" sentinel. With a 0-based counter the
// very first frame's binds stamped 0, which is indistinguishable from never
// drawn, so every sprite texture read as unstamped for the whole of frame 0 and
// the guard under-counted itself. Nothing depends on the absolute value: the
// completion watermark starts at 0 and only ever compares >, a fresh texture is
// still 0 and still reads "not in flight", and the US-307 fallback proof drives
// KITTY_METAL_TEST_FORCE_INFLIGHT counts rather than frame numbers.
static uint64_t metal_frame_index = 1;
// US-307: ungated per-frame GPU-completion watermark. Advanced (monotonically) by
// each committed frame's completed handler to that frame's metal_frame_index, so
// the CPU can tell whether a texture a committed frame referenced is still in
// flight. Written on Metal's completion thread, read on the main thread -> atomic.
static _Atomic uint64_t metal_completed_fidx = 0;
static int metal_pass_count = 0;
static double metal_frame_encode_start = 0.0;
static double metal_frame_drawable_wait = 0.0;

// US-307: is a still-in-flight committed frame potentially sampling this image
// texture? True when the newest frame that bound it has not yet completed on the
// GPU. The graphics.c upload paths consult this to avoid an in-place replaceRegion
// into a texture an async-presented frame is still reading (the G1 race). Called
// on the main thread (draw/upload); reads the atomic completion watermark.
bool
texture_upload_in_flight(uint32_t tex_id) {
    if (tex_id == 0 || tex_id >= MAX_TEXTURES) return false;
    // US-307 verification lever: KITTY_METAL_TEST_FORCE_INFLIGHT=N forces the first
    // N checks true to synthesize async-present contention deterministically, then
    // reverts to the real watermark. Lets a test drive an image through the racy
    // fresh-texture fallback and confirm deltas resume afterward. Inert when unset.
    static int force_remaining = -1;
    if (force_remaining < 0) {
        const char *v = getenv("KITTY_METAL_TEST_FORCE_INFLIGHT");
        force_remaining = (v && v[0]) ? atoi(v) : 0;
    }
    if (force_remaining > 0) { force_remaining--; return true; }
    return textures[tex_id].last_drawn_fidx > atomic_load_explicit(&metal_completed_fidx, memory_order_acquire);
}

// ----- H1 (W28.4a): sprite/decorations upload guard -----
// The atlas and decorations maps are Shared, tracked textures written by a CPU
// replaceRegion. Tracked mode orders GPU-vs-GPU accesses only, so it says
// nothing about a CPU write landing in a region a committed frame is still
// sampling. The in-tree argument for why that is safe (see the atlas-growth
// blit) rests on the write being to a DISJOINT region, which holds on every
// production path today -- sprite indices are allocated monotonically and never
// recycled inside a live atlas, and a font-size change builds a new atlas
// rather than resetting the old one. This guard is therefore defence-in-depth
// against that invariant being broken later, and it closes two defects that are
// real now: the watermark was stamped for the graphics unit only, and the 3D
// recreate path never reset it.
//
// DELIBERATE RE-SCOPE of KITTY_METAL_TEST_FORCE_INFLIGHT: that lever
// (texture_upload_in_flight above) forces the first N checks true from a single
// process-wide counter, and the US-307 test drives a precise number of image
// uploads through it. Routing the new sprite call sites through the same entry
// point would silently eat those N checks and change what that test exercises,
// so the sprite guard reads the watermark directly and the lever keeps meaning
// exactly what it meant before: the first N IMAGE-texture checks.
//
// The completion watermark this upload must reach before it is safe, and
// whether the stamp names the frame currently being ENCODED rather than a
// committed one.
//
// The self-frame case cannot be waited out directly: that frame's command
// buffer is not committed until metal_end_frame, so metal_completed_fidx can
// never reach it from here and waiting on it would burn the full cap. The
// earlier revision exempted it outright and returned "not in flight". That
// exemption leaned on an unasserted cross-file assumption about WHEN uploads
// happen relative to encoding, and it is also effectively dead: an upload
// during cell prep sees the previous frame's stamp, so the ordinary path
// already applies. It is replaced by the conservative target -- every frame
// STRICTLY BEFORE the one being encoded -- which is the strongest guarantee
// actually obtainable here, costs nothing when those frames have already
// completed (the normal case), and needs no assumption about upload phase.
static uint64_t
sprite_wait_target(GLuint tex_id, bool *selfframe) {
    *selfframe = false;
    if (tex_id == 0 || tex_id >= MAX_TEXTURES) return 0;
    const uint64_t drawn = textures[tex_id].last_drawn_fidx;
    if (!drawn) return 0;
    if (drawn >= metal_frame_index) {
        *selfframe = true;
        return metal_frame_index ? metal_frame_index - 1 : 0;
    }
    return drawn;
}

static bool
sprite_wait_target_pending(uint64_t target) {
    return target != 0 && target > atomic_load_explicit(&metal_completed_fidx, memory_order_acquire);
}

// Anti-vacuity instrumentation (W28.4a AC). Three distinct questions, because
// one counter cannot answer them and a naive reading of `waits` alone is
// actively misleading:
//   checks   the guard runs at all.
//   stamped  the guard saw a texture with a NON-ZERO last_drawn_fidx, i.e. the
//            unit 0/2/3/4 stamps are firing. This is the real anti-vacuity
//            signal. Before those stamps existed this would be 0 for every
//            sprite-side texture and the predicate was constant-false -- a
//            guard that reads as protection while never being able to fire.
//   waits    the predicate actually found a committed, unfinished frame.
//   selfframe entries into the conservative self-frame branch. Expected to be
//            0: an upload during cell prep sees the PREVIOUS frame's stamp. A
//            non-zero count is a discovery, not a failure -- it means some
//            upload path runs after that frame's own binds, which is exactly
//            the assumption the removed exemption used to depend on silently.
// `waits == 0` alongside `stamped > 0` is a HEALTHY result, not a vacuous one:
// it means the guarded race did not occur, which is expected when gpu is
// 0.23 ms-class against a ~16 ms tick. Only `stamped == 0` proves vacuity.
// All four are CUMULATIVE for the process, so a capture is judged on its LAST
// emitted line, never on "some line showed a non-zero". Forced runs (the lever
// below) and natural runs are reported separately and never summed.
static uint64_t metal_sprite_guard_checks = 0;
static uint64_t metal_sprite_guard_stamped = 0;
static uint64_t metal_sprite_guard_waits = 0;
static uint64_t metal_sprite_guard_timeouts = 0;
static uint64_t metal_sprite_guard_selfframe = 0;

// Verification lever, sprite-scoped on purpose: forces the first N guard calls
// down the wait branch so that branch is provably reachable and counted, even
// though the real race is rare in steady state. Deliberately SEPARATE from
// KITTY_METAL_TEST_FORCE_INFLIGHT so neither lever consumes the other's budget
// (see the re-scope note above). Inert when unset.
static bool
sprite_upload_force_inflight(void) {
    static int remaining = -1;
    if (remaining < 0) {
        const char *v = getenv("KITTY_METAL_TEST_FORCE_SPRITE_INFLIGHT");
        remaining = (v && v[0]) ? atoi(v) : 0;
    }
    if (remaining > 0) { remaining--; return true; }
    return false;
}

// Bounded wait before a CPU write to a sprite-side texture. gpu p50 is
// 0.23 ms-class, so when this blocks at all it is normally well under the cap.
// On expiry the write proceeds anyway: the callers cache the sprite index the
// moment they ask for the upload, so skipping or deferring the write leaves a
// permanently blank glyph rather than a late one. Proceeding is exactly today's
// behaviour, and the timeout counter makes the situation visible instead of
// silent.
#define SPRITE_UPLOAD_WAIT_CAP_MS 1.0
static void
guard_sprite_upload(GLuint tex_id) {
    metal_sprite_guard_checks++;
    if (tex_id && tex_id < MAX_TEXTURES && textures[tex_id].last_drawn_fidx) metal_sprite_guard_stamped++;
    bool selfframe = false;
    const uint64_t target = sprite_wait_target(tex_id, &selfframe);
    if (selfframe) metal_sprite_guard_selfframe++;
    const bool forced = sprite_upload_force_inflight();
    if (!forced && !sprite_wait_target_pending(target)) return;
    metal_sprite_guard_waits++;
    const monotonic_t deadline = monotonic() + ms_double_to_monotonic_t(SPRITE_UPLOAD_WAIT_CAP_MS);
    while (sprite_wait_target_pending(target)) {
        if (monotonic() >= deadline) { metal_sprite_guard_timeouts++; return; }
        sched_yield();
    }
}

// M3: has any render pass targeted the drawable yet this frame? The first
// drawable pass must not Load the recycled drawable (its contents are
// meaningless and kitty repaints 100% of it); later passes Load to preserve
// earlier draws. Per current window: saved/restored with the window slot,
// reset in metal_end_frame.
static bool drawable_pass_opened = false;

// D1: stamp every ring buffer bound by the currently-bound VAO with the command
// buffer that is about to read it. This is the ring's fence: a slot can only be
// recycled (ring_acquire_slot) once THIS command buffer reports completed, which
// is unconditionally correct no matter how command buffers from multiple OS
// windows interleave on the single command queue. Called at draw time (the CB is
// guaranteed live once an encoder exists) and is idempotent within a frame.
static void
stamp_ring_fences(ssize_t vao_idx) {
    if (vao_idx < 0 || !mtl_current_command_buffer) return;
    MetalVAO *vao = &vaos[vao_idx];
    for (size_t i = 0; i < vao->num_buffers; i++) {
        MetalBuffer *b = &buffers[vao->buffers[i]];
        if (!b->is_ring || b->ring_count == 0) continue;
        MetalRingSlot *s = &b->ring[b->ring_head];
        if (s->fence_cb != mtl_current_command_buffer) {
            [mtl_current_command_buffer retain];
            if (s->fence_cb) [s->fence_cb release];
            s->fence_cb = mtl_current_command_buffer;
        }
    }
}

void
draw_quad(bool blend, unsigned instance_count) {
    if (!mtl_current_layer) return;
    if (metal_log_path() && dq_log_count < 64) {
        CGSize ds = mtl_current_layer.drawableSize;
        METAL_TRACE("draw_quad[%d]: prog=%d blend=%d inst=%u vao=%zd fb=%u enc_fmt=%lu vp=(%.0f,%.0f,%.0f,%.0f) ds=%.0fx%.0f\n",
            dq_log_count, current_program, blend, instance_count, current_bound_vao,
            bound_framebuffer, (unsigned long)mtl_current_enc_fmt,
            mtl_viewport.originX, mtl_viewport.originY, mtl_viewport.width, mtl_viewport.height,
            ds.width, ds.height);
        dq_log_count++;
    }

    // If there's a pending clear and no encoder yet, start a render pass with clear
    if (clear_pending && !mtl_current_encoder) {
        begin_render_pass_to_drawable(true);
        clear_pending = false;
        if (!instance_count) return; // clear-only call
    }

    // GL_FRAMEBUFFER_SRGB (or the bound framebuffer) may change between
    // draws; when the required attachment differs, the pass must restart
    // (with Load, preserving prior draws).
    if (mtl_current_encoder && mtl_current_enc_fmt != wanted_attachment_format(false)) {
        end_current_encoder();
    }

    // Ensure we have an encoder for actual drawing
    if (!mtl_current_encoder) {
        begin_render_pass_to_drawable(false);
    }
    if (!mtl_current_encoder) return;

    // D1: fence the ring buffers this draw will read to this command buffer.
    stamp_ring_fences(current_bound_vao);

    // Set viewport
    [mtl_current_encoder setViewport:mtl_viewport];

    // Set scissor if enabled
    if (scissor_enabled) {
        // Clamp scissor rect to drawable dimensions
        id<MTLTexture> rt = mtl_current_render_pass ? mtl_current_render_pass.colorAttachments[0].texture : nil;
        NSUInteger dw = rt ? rt.width : 0;
        NSUInteger dh = rt ? rt.height : 0;
        MTLScissorRect sr = mtl_scissor;
        if (sr.x + sr.width > dw) sr.width = dw > sr.x ? dw - sr.x : 0;
        if (sr.y + sr.height > dh) sr.height = dh > sr.y ? dh - sr.y : 0;
        if (sr.width > 0 && sr.height > 0) {
            [mtl_current_encoder setScissorRect:sr];
        }
    }

    // Bind the pipeline state for (program, blend, current attachment format)
    if (current_program < 0 || current_program >= NUM_PROGRAMS) return;
    id<MTLRenderPipelineState> pso = pso_get(current_program, blend, mtl_current_enc_fmt, layered_pass_active);
    if (!pso) return;
    [mtl_current_encoder setRenderPipelineState:pso];

    // Bind VAO buffers and program-specific uniform data to the encoder
    // Program IDs: CELL=0-2, SENTINEL=3, BORDERS=4, GRAPHICS=5-7, BGIMAGE=8,
    //              TINT=9, TRAIL=10, BLIT=11, SCREENSHOT=12, ROUNDED_RECT=13
    if (current_program <= 2) {
        // Cell programs — bind GPUCell data, selection, uniform block, gamma_lut
        if (current_bound_vao >= 0) {
            MetalVAO *vao = &vaos[current_bound_vao];
            // Buffer 0: GPUCell data (vertex attribute buffer)
            if (vao->num_buffers > 0) {
                ssize_t buf_idx = vao->buffers[0];
                if (buffers[buf_idx].mtl_buffer) {
                    [mtl_current_encoder setVertexBuffer:buffers[buf_idx].mtl_buffer offset:0 atIndex:0];
                }
            }
            // Buffer 1 (selection) → Metal buffer index 5
            if (vao->num_buffers > 1) {
                ssize_t buf_idx = vao->buffers[1];
                if (buffers[buf_idx].mtl_buffer) {
                    [mtl_current_encoder setVertexBuffer:buffers[buf_idx].mtl_buffer offset:0 atIndex:5];
                }
            }
            // Buffer 2 (uniform block = CellRenderData + color_table) → Metal buffer index 1
            if (vao->num_buffers > 2) {
                ssize_t buf_idx = vao->buffers[2];
                if (buffers[buf_idx].mtl_buffer) {
                    [mtl_current_encoder setVertexBuffer:buffers[buf_idx].mtl_buffer offset:0 atIndex:1];
                }
            }
        }
        // Gamma LUT → buffer index 3 (M5c: bind the resident buffer instead of
        // copying 1 KB into the command stream via setVertexBytes every draw)
        id<MTLBuffer> glut = ensure_gamma_lut_buffer();
        if (glut) [mtl_current_encoder setVertexBuffer:glut offset:0 atIndex:3];
        // Buffer 3 (ColorTable UBO, packed uint[]) → Metal buffer index 4
        if (current_bound_vao >= 0) {
            MetalVAO *vao = &vaos[current_bound_vao];
            if (vao->num_buffers > 3) {
                ssize_t buf_idx = vao->buffers[3];
                if (buffers[buf_idx].mtl_buffer) {
                    [mtl_current_encoder setVertexBuffer:buffers[buf_idx].mtl_buffer offset:0 atIndex:4];
                    // W27 P3.5b: the wide-gamut colour carrier's float4 table
                    // shares this same MTLBuffer, at the fixed byte offset
                    // just past the packed uint region (see block_size() /
                    // METAL_WIDE_COLOR_TABLE_BYTES above) -> Metal buffer
                    // index 6.
                    [mtl_current_encoder setVertexBuffer:buffers[buf_idx].mtl_buffer offset:1056 atIndex:6];
                }
            }
        }
        // Per-draw uniforms (draw_bg_bitfield, row_offset, etc.) → buffer index 2
        MetalCellDrawUniforms cell_draw;
        fill_cell_draw_uniforms(current_program, &cell_draw);
        [mtl_current_encoder setVertexBytes:&cell_draw length:sizeof(cell_draw) atIndex:2];
        [mtl_current_encoder setFragmentBytes:&cell_draw length:sizeof(cell_draw) atIndex:2];

        // Bind textures: unit 0 = mono sprite atlas (2D array), unit 2 = mono
        // decorations map. F1: unit 3 = colored sprite atlas (fragment+vertex
        // tex 1), unit 4 = colored decorations map (vertex tex 3). ensure_sprite_map
        // keeps units 3/4 bound to a valid texture even under the kill switch, so
        // the fragment/vertex color samplers are always complete.
        // H1 (W28.4a): record the frame that samples each sprite-side texture,
        // exactly as the graphics unit already does below. Until this landed the
        // watermark was stamped for unit 1 ONLY, so last_drawn_fidx stayed 0 for
        // every atlas and decorations map and any in-flight predicate built on it
        // was constant-false -- a guard that reads as protection while never
        // firing. Stamped at bind time, when metal_frame_index still names the
        // frame being encoded (it is post-incremented at commit).
        if (bound_tex_2d_array[0] && bound_tex_2d_array[0] < MAX_TEXTURES && textures[bound_tex_2d_array[0]].texture) {
            [mtl_current_encoder setFragmentTexture:textures[bound_tex_2d_array[0]].texture atIndex:0];
            [mtl_current_encoder setVertexTexture:textures[bound_tex_2d_array[0]].texture atIndex:0];
            textures[bound_tex_2d_array[0]].last_drawn_fidx = metal_frame_index;
        }
        if (bound_tex_2d[2] && bound_tex_2d[2] < MAX_TEXTURES && textures[bound_tex_2d[2]].texture) {
            [mtl_current_encoder setVertexTexture:textures[bound_tex_2d[2]].texture atIndex:2];
            textures[bound_tex_2d[2]].last_drawn_fidx = metal_frame_index;
        }
        if (bound_tex_2d_array[3] && bound_tex_2d_array[3] < MAX_TEXTURES && textures[bound_tex_2d_array[3]].texture) {
            [mtl_current_encoder setFragmentTexture:textures[bound_tex_2d_array[3]].texture atIndex:1];
            [mtl_current_encoder setVertexTexture:textures[bound_tex_2d_array[3]].texture atIndex:1];
            textures[bound_tex_2d_array[3]].last_drawn_fidx = metal_frame_index;
        }
        if (bound_tex_2d[4] && bound_tex_2d[4] < MAX_TEXTURES && textures[bound_tex_2d[4]].texture) {
            [mtl_current_encoder setVertexTexture:textures[bound_tex_2d[4]].texture atIndex:3];
            textures[bound_tex_2d[4]].last_drawn_fidx = metal_frame_index;
        }
    } else if (current_program == 4) {
        // Borders — bind rect buffer from VAO, uniforms as buffer
        if (current_bound_vao >= 0) {
            MetalVAO *vao = &vaos[current_bound_vao];
            if (vao->num_buffers > 0) {
                ssize_t buf_idx = vao->buffers[0];
                if (buffers[buf_idx].mtl_buffer) {
                    [mtl_current_encoder setVertexBuffer:buffers[buf_idx].mtl_buffer offset:0 atIndex:0];
                }
            }
        }
        // C5: MetalBorderUniforms (colors[9] array at ARRAY_UNIFORM_BASE +
        // background_opacity + resident gamma_lut[256]); see fill_border_uniforms.
        MetalBorderUniforms border_u;
        fill_border_uniforms(current_program, &border_u);
        [mtl_current_encoder setVertexBytes:&border_u length:sizeof(border_u) atIndex:1];
    } else if (current_program >= 5 && current_program <= 7) {
        // C5: MetalGraphicsUniforms — per-instance src_rects/dest_rects[16] arrays
        // (ARRAY_UNIFORM_BASE, G2) then the extra_alpha/amask scalar tail; layout
        // pinned in metal_uniforms.h, filled by fill_graphics_uniforms.
        MetalGraphicsUniforms gfx_u;
        fill_graphics_uniforms(current_program, &gfx_u);
        metal_frame_gfx_draw_count++;  // G2: graphics-program draw call this frame
        [mtl_current_encoder setVertexBytes:&gfx_u length:sizeof(gfx_u) atIndex:0];
        [mtl_current_encoder setFragmentBytes:&gfx_u length:sizeof(gfx_u) atIndex:0];
        // Bind image texture from unit 1 (GRAPHICS_UNIT)
        if (bound_tex_2d[1] && bound_tex_2d[1] < MAX_TEXTURES && textures[bound_tex_2d[1]].texture) {
            [mtl_current_encoder setFragmentTexture:textures[bound_tex_2d[1]].texture atIndex:0];
            // US-307: record the frame that samples this image texture, so the
            // upload path can detect it is still in flight under async present.
            textures[bound_tex_2d[1]].last_drawn_fidx = metal_frame_index;
        }
    } else if (current_program == 8) {
        MetalBgimageUniforms bg_u;
        fill_bgimage_uniforms(current_program, &bg_u);
        [mtl_current_encoder setVertexBytes:&bg_u length:sizeof(bg_u) atIndex:0];
        [mtl_current_encoder setFragmentBytes:&bg_u length:sizeof(bg_u) atIndex:0];
        if (bound_tex_2d[1] && bound_tex_2d[1] < MAX_TEXTURES && textures[bound_tex_2d[1]].texture) {
            [mtl_current_encoder setFragmentTexture:textures[bound_tex_2d[1]].texture atIndex:0];
        }
    } else if (current_program == 9) {
        MetalTintUniforms tint_u;
        fill_tint_uniforms(current_program, &tint_u);
        [mtl_current_encoder setVertexBytes:&tint_u length:sizeof(tint_u) atIndex:0];
        [mtl_current_encoder setFragmentBytes:&tint_u length:sizeof(tint_u) atIndex:0];
    } else if (current_program == 10) {
        // C5: MetalTrailUniforms (float3 trail_color 16-aligned so trail_opacity
        // lands at 64); see fill_trail_uniforms + metal_uniforms.h assert.
        MetalTrailUniforms trail_u;
        fill_trail_uniforms(current_program, &trail_u);
        [mtl_current_encoder setVertexBytes:&trail_u length:sizeof(trail_u) atIndex:0];
        [mtl_current_encoder setFragmentBytes:&trail_u length:sizeof(trail_u) atIndex:0];
    } else if (current_program == 11) {
        MetalBlitUniforms blit_u;
        fill_blit_uniforms(current_program, &blit_u);
        [mtl_current_encoder setVertexBytes:&blit_u length:sizeof(blit_u) atIndex:0];
        [mtl_current_encoder setFragmentBytes:&blit_u length:sizeof(blit_u) atIndex:0];
        if (bound_tex_2d[1] && bound_tex_2d[1] < MAX_TEXTURES && textures[bound_tex_2d[1]].texture) {
            [mtl_current_encoder setFragmentTexture:textures[bound_tex_2d[1]].texture atIndex:0];
        }
    } else if (current_program == 12) {
        MetalScreenshotUniforms ss_u;
        fill_screenshot_uniforms(current_program, &ss_u);
        [mtl_current_encoder setVertexBytes:&ss_u length:sizeof(ss_u) atIndex:0];
        [mtl_current_encoder setFragmentBytes:&ss_u length:sizeof(ss_u) atIndex:0];
        if (bound_tex_2d[1] && bound_tex_2d[1] < MAX_TEXTURES && textures[bound_tex_2d[1]].texture) {
            [mtl_current_encoder setFragmentTexture:textures[bound_tex_2d[1]].texture atIndex:0];
        }
    } else if (current_program == 13) {
        MetalRoundedRectUniforms rr_u;
        fill_rounded_rect_uniforms(current_program, &rr_u);
        [mtl_current_encoder setVertexBytes:&rr_u length:sizeof(rr_u) atIndex:0];
        [mtl_current_encoder setFragmentBytes:&rr_u length:sizeof(rr_u) atIndex:0];
    }

    if (instance_count > 0) {
        [mtl_current_encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4 instanceCount:instance_count];
    } else {
        [mtl_current_encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    }
}

// ----- Framebuffer -----

const char*
check_framebuffer_status(void) {
    // Metal doesn't have framebuffer completeness checks like OpenGL.
    // Render target validity is checked at pipeline creation time.
    return NULL; // always "complete"
}

void
bind_framebuffer_for_output(unsigned fbid) {
    // fbid == 0 resolves to the registered output framebuffer (gl.c parity);
    // a nonzero fbid binds that framebuffer directly.
    unsigned target = fbid ? fbid : output_framebuffer;
    if (target != bound_framebuffer) {
        // End current render pass before switching targets; the next draw
        // opens an encoder on the new target.
        end_current_encoder();
        bound_framebuffer = target;
    }
}

void
set_framebuffer_to_use_for_output(unsigned fbid) {
    output_framebuffer = fbid;
}

// ----- Scissor -----

void
enable_scissor_using_top_left_origin(Viewport vp, unsigned full_framebuffer_height) {
    (void)full_framebuffer_height;
    scissor_enabled = true;
    // Metal uses top-left origin natively
    mtl_scissor = (MTLScissorRect){vp.left, vp.top, vp.width, vp.height};
}

void
disable_scissor(void) {
    scissor_enabled = false;
}

// ----- Texture Management -----

static void recycle_texture_id(GLuint id);

void
free_texture(GLuint *tex_id) {
    if (*tex_id && *tex_id < MAX_TEXTURES) recycle_texture_id(*tex_id);
    *tex_id = 0;
}

void
free_framebuffer(GLuint *fb_id) {
    if (*fb_id && *fb_id < MAX_FRAMEBUFFERS) {
        framebuffers[*fb_id].in_use = false;
        [framebuffers[*fb_id].render_target release];
        framebuffers[*fb_id].render_target = nil;
    }
    *fb_id = 0;
}

void
save_texture_as_png(uint32_t texture_id, const char *filename) {
    MetalTexture *t = get_texture(texture_id);
    if (!t || !t->texture) return;

    int width = (int)t->texture.width;
    int height = (int)t->texture.height;
    size_t sz = sizeof(uint32_t) * width * height;
    uint32_t *data = malloc(sz);
    if (!data) return;

    [t->texture getBytes:data
             bytesPerRow:width * 4
              fromRegion:MTLRegionMake2D(0, 0, width, height)
             mipmapLevel:0];

    // The linear->sRGB transfer below is correct only for a LINEAR source (e.g.
    // the RGBA16Unorm layers FBO). If the texture is already an sRGB format,
    // getBytes returns display-encoded bytes, so applying the transfer again
    // would double-encode (washed-out output) — skip it in that case.
    const bool src_is_srgb = (t->texture.pixelFormat == MTLPixelFormatRGBA8Unorm_sRGB ||
                              t->texture.pixelFormat == MTLPixelFormatBGRA8Unorm_sRGB);
    // Premultiplied -> straight alpha (and linear -> sRGB only when linear).
    for (int i = 0; i < width * height; i++) {
        uint32_t px = data[i];
        uint8_t r = (px >> 0) & 0xFF, g = (px >> 8) & 0xFF, b = (px >> 16) & 0xFF, a = (px >> 24) & 0xFF;
        float alpha = a / 255.0f;
        float rf = 0, gf = 0, bf = 0;
        if (alpha > 0.0f) {
            rf = (r / 255.0f) / alpha; gf = (g / 255.0f) / alpha; bf = (b / 255.0f) / alpha;
        }
        if (!src_is_srgb) {
            rf = (rf <= 0.0031308f) ? 12.92f * rf : 1.055f * powf(rf, 1.0f / 2.4f) - 0.055f;
            gf = (gf <= 0.0031308f) ? 12.92f * gf : 1.055f * powf(gf, 1.0f / 2.4f) - 0.055f;
            bf = (bf <= 0.0031308f) ? 12.92f * bf : 1.055f * powf(bf, 1.0f / 2.4f) - 0.055f;
        }
        r = (uint8_t)(rf * 255); g = (uint8_t)(gf * 255); b = (uint8_t)(bf * 255);
        data[i] = (r << 0) | (g << 8) | (b << 16) | (a << 24);
    }

    const char *png = png_from_32bit_rgba((char*)data, width, height, &sz, true);
    if (!sz) fatal("Failed to save PNG to %s with error: %s", filename, png);
    free(data);
    FILE *file = fopen(filename, "wb");
    fwrite(png, 1, sz, file);
    fclose(file);
}

// ----- Shader Compilation -----

GLuint
compile_shaders(GLenum shader_type, GLsizei count, const GLchar * const *source) {
    // The MSL equivalents live pre-compiled in the metallib, so there is nothing
    // to compile. W27 P3.4 (chain 2): this used to scrape the cell option
    // `#define`s back out of the GLSL source Python had just preprocessed —
    // kitty/*.glsl was therefore load-bearing for Metal rendering config, not
    // just for the GL backend. Those values now arrive through
    // metal_set_cell_shader_opts() before the programs are compiled, so all that
    // remains here is handing back a unique id for the GL shim's bookkeeping.
    (void)shader_type; (void)count; (void)source;
    static GLuint next_shader_id = 1;
    return next_shader_id++;
}

// ----- Metal Frame Management -----

// Per-OS-window rendering state. The state of the *current* window lives in
// the mtl_current_* globals (register-file pattern used throughout this
// file); metal_set_current_layer swaps those globals in and out of this
// table so multiple OS windows never share in-flight frame state.
typedef struct {
    void *layer_ptr;
    id<MTLCommandBuffer> cb;
    id<CAMetalDrawable> drawable;
    id<MTLRenderCommandEncoder> enc;
    MTLPixelFormat enc_fmt;
    bool clear_pending, clear_srgb;
    bool in_use;
    int pass_count;             // Phase 0: passes opened this frame (per window)
    double frame_encode_start;  // Phase 0 (p99-fixed): CACurrentMediaTime after drawable acquired
    double frame_drawable_wait; // p99: seconds spent in nextDrawable this frame
    bool drawable_pass_opened;  // M3: first drawable pass seen this frame?
    bool layered_pass_active;   // M1: mid single-pass layered render?
    // H2 (W28.4a): per-window layered working-surface cache. Unlike cb/drawable/
    // enc above -- which are UNRETAINED copies of autoreleased objects the queue
    // owns -- this texture is +1 OWNED by the slot. It therefore has NO
    // register-file mirror: one reference, one owner, so there is no way for a
    // global and a slot field to both name the same +1 and double-release it.
    // metal_forget_layer must release it before memsetting the slot.
    id<MTLTexture> layered_work_surface;                 // memoryless att0, sized to this window's drawable
    NSUInteger layered_work_w, layered_work_h;           // its cache key: size...
    MTLPixelFormat layered_work_surface_fmt;             // ...and format (memset 0 == MTLPixelFormatInvalid)
} MetalWindowSlot;
#define MAX_METAL_WINDOWS 64
static MetalWindowSlot metal_windows[MAX_METAL_WINDOWS];
static MetalWindowSlot *current_window_slot = NULL;

// ----- W28.0c: S5 partition instrumentation -----
// WALLS v1.2 puts S5 (gate->present) at 6.99 ms p50, of which encode + gpu
// account for well under a millisecond -- a ~6.2-6.7 ms near-constant is
// unattributed. Splitting it needs three stamps per frame:
//     gate->commit         commit_time - the tick's gate stamp (ktrace gate_ms)
//     commit->gpu-done     gpu_end - commit_time
//     gpu-done->presented  presented_time - gpu_end
// commit_time is taken on the CPU immediately after the commit, gpu_end is the
// completion handler's cb.GPUEndTime and presented_time the drawable's
// presentedTime. Apple documents the latter two as "host time, in seconds ...
// relative to system mach time" -- the same timebase CACurrentMediaTime() reads,
// so all three subtract directly and only the gate stamp (kitty's own
// process-relative monotonic clock) needs the shift the ktrace_epoch line
// already publishes. The three terms are emitted as tail fields on the stats
// records and joined offline on frame=.
//
// The last present is ALSO kept in process, per window, because a present
// timestamp is only usable as a pacing reference if the reader can tell frame
// N's stamp from frame N-1's -- so the (frame, time) PAIR is stored, never the
// bare time. This table is PARALLEL to metal_windows rather than a field in it:
// the writer is the drawable's presented handler, which runs on a Metal callback
// thread, while the main thread memsets a MetalWindowSlot on window teardown and
// on slot reuse -- and memset is not an atomic store.
//
// The pair is published as ONE 16-byte atomic: a single release store in the
// handler, a single acquire load in the reader, and every check performed on
// the reader's LOCAL copy. Nothing addresses a field of the atomic separately --
// a partial-field store would silently reintroduce exactly the tear this
// replaced. (An earlier attempt published the time into a parity-indexed array
// and then the key: it was torn. A reader could load the key for frame N, and a
// handler for frame N+2 -- the SAME parity -- could overwrite that array entry
// before publishing its own key, so the reader took N+2's time under N's key and
// the key re-read saw nothing wrong. Two frames of skew is not exotic under an
// async present.)
//
// Handler arrival order is NOT serialised here: if Metal ever delivers presented
// handlers for a window out of order, the last writer wins and the stamp can go
// backwards by a frame. That behaviour is pre-existing and unchanged, and every
// consumer already treats the frame index as the thing to judge freshness by, so
// it is considered-and-deferred rather than fixed with a CAS loop.
//
// SLOT LIFECYCLE (the ordering argument). A slot index outlives the window that
// owned it: metal_forget_layer memsets the slot and metal_set_current_layer
// hands the free slot to the next window, while a presented handler registered
// by the DEAD window may still be in flight and about to write. Clearing the
// entry on teardown does not fix this -- the main thread cannot order its clear
// against a callback that has not run yet, so a late write would simply
// resurrect the dead window's stamp under the new window's identity.
// The published key therefore carries the slot's OWNERSHIP EPOCH alongside the
// frame index: metal_present_slot_reassigned() bumps the epoch on every
// identity change (teardown and re-issue both), each handler captures the epoch
// it was registered under, and a reader accepts a key only when its epoch
// equals the slot's current one. A late write from the dead window publishes
// the OLD epoch and is rejected deterministically -- no clear, no undo, and no
// window in which prev_present_* can read the previous window's stamp. The
// epoch is compared, never trusted for ordering, so the main thread needs no
// atomic on its side.
// Packing (40-bit frame index, 24-bit epoch) puts the identity in one word so
// the published pair fits a single 16-byte atomic. Both halves are masked
// explicitly on the way in and compared masked on the way out, so a counter
// that outgrows its field wraps into a defined value instead of corrupting its
// neighbour. The bounds are not reachable in practice: 2^40 frames is ~34 years
// at 1000 fps, and 2^24 is 16.7M window-identity changes. at == 0 means "never
// stamped" (a real present time is never 0; see the no-op rule below).
#define PRESENT_STAMP_FIDX_BITS 40
#define PRESENT_STAMP_FIDX_MASK ((1ull << PRESENT_STAMP_FIDX_BITS) - 1)
#define PRESENT_STAMP_EPOCH_MASK ((1ull << 24) - 1)
typedef struct {
    uint64_t key;   // (epoch << 40) | frame index
    int64_t at;     // presentedTime as monotonic_t; 0 = no stamp
} MetalPresentPair;
// 16-byte alignment is a precondition for the pair being lock-free, so the
// assert is made against the aligned storage rather than a bare size/NULL query
// (which can answer false for alignment reasons that do not apply here). A
// libatomic lock taken on a Metal callback thread would be unacceptable, so
// this is a hard compile-time requirement, not a runtime probe.
static _Alignas(16) _Atomic MetalPresentPair metal_present_stamps[MAX_METAL_WINDOWS];
_Static_assert(sizeof(MetalPresentPair) == 16, "present stamp pair must be exactly 16 bytes");
_Static_assert(__atomic_always_lock_free(sizeof(MetalPresentPair), &metal_present_stamps[0]),
               "present stamp pair must be lock-free: it is published from a Metal callback thread");
// Current ownership epoch per slot index, and the counter it is handed out
// from. Main thread only (assignment and teardown both run there); handlers
// receive their epoch by value at registration and never read these.
static uint64_t metal_present_epochs[MAX_METAL_WINDOWS];
static uint64_t metal_present_epoch_counter;

// A slot index has changed owner: retire every stamp published under the old
// identity. Called from both sides of the reuse -- teardown (metal_forget_layer)
// and re-issue (metal_set_current_layer) -- so an index is never live under two
// epochs even if a window dies without a matching re-issue.
static void
metal_present_slot_reassigned(int slot_idx) {
    if (slot_idx < 0 || slot_idx >= MAX_METAL_WINDOWS) return;
    metal_present_epochs[slot_idx] = ++metal_present_epoch_counter;
}

// CACurrentMediaTime() and kitty's monotonic() both count mach-absolute
// nanoseconds but differ in epoch (monotonic() is process-relative, see
// kitty/monotonic.h), so a host-time seconds value becomes a monotonic_t by
// adding a one-shot offset sampled from a back-to-back read of both clocks.
// Sampling rather than assuming the two clocks share an origin keeps this
// correct without depending on how clock_gettime is mapped on Darwin. Seeded
// from the main thread and passed BY VALUE into the presented handler, so the
// cache is never touched from a callback thread.
static monotonic_t
media_time_to_monotonic_offset(void) {
    static monotonic_t offset = 0;
    static bool sampled = false;
    if (!sampled) {
        const double media = CACurrentMediaTime();
        offset = monotonic() - s_double_to_monotonic_t(media);
        sampled = true;
    }
    return offset;
}

// Index of a window slot in metal_windows, or -1 when no window is current.
static int
window_slot_index(void) {
    return current_window_slot ? (int)(current_window_slot - metal_windows) : -1;
}

// Publish frame fidx's present time for a window, under the ownership epoch the
// handler was registered with. `at` == 0 is the defined no-op: Apple reports
// presentedTime 0.0 both for a drawable that was never presented and for one
// whose frame was dropped, and neither is a photon, so the previous stamp is
// left in place. Runs on a Metal callback thread.
static void
stamp_present(int slot_idx, uint64_t epoch, uint64_t fidx, monotonic_t at) {
    if (slot_idx < 0 || slot_idx >= MAX_METAL_WINDOWS || at == 0) return;
    const MetalPresentPair pair = {
        .key = ((epoch & PRESENT_STAMP_EPOCH_MASK) << PRESENT_STAMP_FIDX_BITS) | (fidx & PRESENT_STAMP_FIDX_MASK),
        .at = at,
    };
    atomic_store_explicit(&metal_present_stamps[slot_idx], pair, memory_order_release);
}

// Read a window's newest present stamp, rejecting anything published under a
// previous owner of this slot index. False when nothing has been stamped yet,
// when the stamp belongs to a dead window, or when the key moved mid-read.
// Callers must additionally compare *fidx_out against the frame they care
// about -- a stamp that is real but older than the caller's frame means "this
// frame has not reached the display yet". Main thread.
static bool
read_present_stamp(int slot_idx, uint64_t *fidx_out, monotonic_t *at_out) {
    if (slot_idx < 0 || slot_idx >= MAX_METAL_WINDOWS) return false;
    const uint64_t epoch = metal_present_epochs[slot_idx] & PRESENT_STAMP_EPOCH_MASK;
    if (!epoch) return false;
    // One acquire load of the whole pair; every test below is on this local
    // copy, so key and at are necessarily from the same publication.
    const MetalPresentPair pair = atomic_load_explicit(&metal_present_stamps[slot_idx], memory_order_acquire);
    if (pair.at == 0) return false;
    if ((pair.key >> PRESENT_STAMP_FIDX_BITS) != epoch) return false;
    *fidx_out = pair.key & PRESENT_STAMP_FIDX_MASK;
    *at_out = pair.at;
    return true;
}

static void
save_current_window_state(void) {
    MetalWindowSlot *s = current_window_slot;
    if (!s) return;
    s->cb = mtl_current_command_buffer;
    s->drawable = mtl_current_drawable;
    s->enc = mtl_current_encoder;
    s->enc_fmt = mtl_current_enc_fmt;
    s->clear_pending = clear_pending;
    s->clear_srgb = clear_srgb_flag;
    s->pass_count = metal_pass_count;
    s->frame_encode_start = metal_frame_encode_start;
    s->frame_drawable_wait = metal_frame_drawable_wait;
    s->drawable_pass_opened = drawable_pass_opened;
    s->layered_pass_active = layered_pass_active;
}

static void
load_window_state(const MetalWindowSlot *s) {
    mtl_current_command_buffer = s->cb;
    mtl_current_drawable = s->drawable;
    mtl_current_encoder = s->enc;
    mtl_current_enc_fmt = s->enc_fmt;
    clear_pending = s->clear_pending;
    clear_srgb_flag = s->clear_srgb;
    metal_pass_count = s->pass_count;
    metal_frame_encode_start = s->frame_encode_start;
    metal_frame_drawable_wait = s->frame_drawable_wait;
    drawable_pass_opened = s->drawable_pass_opened;
    layered_pass_active = s->layered_pass_active;
}

// Set the current layer for rendering. Called when the OS window is made
// current.
void
metal_set_current_layer(void *layer) {
    if (current_window_slot && current_window_slot->layer_ptr == layer) {
        mtl_current_layer = (__bridge CAMetalLayer *)layer;
        return;
    }
    save_current_window_state();
    MetalWindowSlot *slot = NULL, *free_slot = NULL;
    if (layer) {
        for (int i = 0; i < MAX_METAL_WINDOWS; i++) {
            if (metal_windows[i].in_use) {
                if (metal_windows[i].layer_ptr == layer) { slot = &metal_windows[i]; break; }
            } else if (!free_slot) free_slot = &metal_windows[i];
        }
        if (!slot) {
            if (!free_slot) { log_error("Metal: too many OS windows for per-window state table"); return; }
            slot = free_slot;
            memset(slot, 0, sizeof(*slot));
            // W28.0c: this index now belongs to a new window -- retire any stamp
            // a previous owner's in-flight presented handler may still publish.
            metal_present_slot_reassigned((int)(slot - metal_windows));
            slot->in_use = true;
            slot->layer_ptr = layer;
            METAL_TRACE("new window layer=%p contentsScale=%.2f\n", layer, [(__bridge CAMetalLayer*)layer contentsScale]);
        }
    }
    current_window_slot = slot;
    if (slot) {
        load_window_state(slot);
    } else {
        mtl_current_command_buffer = nil;
        mtl_current_drawable = nil;
        mtl_current_encoder = nil;
        mtl_current_enc_fmt = MTLPixelFormatInvalid;
        clear_pending = false;
        clear_srgb_flag = false;
        metal_pass_count = 0;
        metal_frame_encode_start = 0.0;
        metal_frame_drawable_wait = 0.0;
        drawable_pass_opened = false;
        layered_pass_active = false;
    }
    mtl_current_layer = (__bridge CAMetalLayer *)layer;
}

// Get the current Metal device (for external use)
void*
metal_get_device(void) {
    return (__bridge void *)mtl_device;
}

// Window teardown: retire the per-window state slot so it does not outlive the
// window.
void
metal_forget_layer(void *layer) {
    if (!layer) return;
    for (int i = 0; i < MAX_METAL_WINDOWS; i++) {
        if (metal_windows[i].in_use && metal_windows[i].layer_ptr == layer) {
            if (current_window_slot == &metal_windows[i]) {
                // The dying window was current: drop the register-file copies too
                // (the slot never owned these refs; the queue/autorelease pool does).
                current_window_slot = NULL;
                mtl_current_command_buffer = nil;
                mtl_current_drawable = nil;
                mtl_current_encoder = nil;
                if (mtl_current_layer == (__bridge CAMetalLayer *)layer) mtl_current_layer = nil;
            }
            // W28.0c: retire this index's stamps here too, not only on re-issue --
            // a window can die without another ever taking its slot.
            metal_present_slot_reassigned(i);
            // H2: the slot OWNS this texture (+1 from newTextureWithDescriptor),
            // unlike the unretained cb/drawable/enc the memset below simply drops.
            // Memoryless carries no DRAM, but the object and its tile-memory
            // reservation still leak if the slot is zeroed without releasing.
            [metal_windows[i].layered_work_surface release];
            memset(&metal_windows[i], 0, sizeof(metal_windows[i]));
            break;
        }
    }
}

static void
end_current_encoder(void) {
    if (mtl_current_encoder) {
        [mtl_current_encoder endEncoding];
        mtl_current_encoder = nil;
    }
    mtl_current_enc_fmt = MTLPixelFormatInvalid;
}

static bool
ensure_command_buffer(void) {
    if (!mtl_current_command_buffer) {
        mtl_current_command_buffer = [mtl_command_queue commandBuffer];
        if (!mtl_current_command_buffer) return false;
        // GPU-side failures (page faults, invalid resources) surface only in
        // the completed status; without this they are silently dropped.
        [mtl_current_command_buffer addCompletedHandler:^(id<MTLCommandBuffer> cb) {
            if (cb.status == MTLCommandBufferStatusError) {
                log_error("Metal: command buffer failed: %s",
                          cb.error ? [[cb.error localizedDescription] UTF8String] : "unknown error");
            }
        }];
        // Phase 0: the command buffer's lifetime is this frame's CPU-encode
        // span. Begin the signpost here (once per frame, keyed on the cb pointer
        // so the matching end in metal_end_frame finds it). The encode_ms STAT
        // start stamp is NOT taken here: it is stamped after the drawable is
        // acquired (ensure_drawable) so that nextDrawable blocking is measured as
        // drawable_wait_ms, not silently folded into encode_ms (worker-prof #16).
        if (metal_signpost_enabled()) {
            os_log_t slog = metal_signpost_log();
            os_signpost_interval_begin(slog, os_signpost_id_make_with_pointer(slog, (__bridge void *)mtl_current_command_buffer), "frame_encode", "");
        }
    }
    return true;
}

void
metal_set_link_drawable(void *drawable) {
    // Phase 4 (L1): stash the CAMetalDisplayLink-delivered drawable for this
    // frame (or NULL to clear). __bridge only reinterprets the pointer — no
    // ownership transfer (the Update / committed command buffer own it).
    mtl_link_drawable = (__bridge id<CAMetalDrawable>)drawable;
}

static bool
ensure_drawable(void) {
    if (mtl_current_drawable) return true;
    // Phase 4 (L1): a CAMetalDisplayLink-delivered drawable short-circuits the
    // nextDrawable path. The vsync backpressure was already absorbed by the link
    // scheduling this delegate callback, so there is no nextDrawable block to
    // time — drawable_wait_ms stays 0.000 (kept for tolerant-parser stability;
    // its meaning is redefined under the link, see metal-pipeline-design.md).
    // encode_ms starts here, mirroring the nextDrawable path below.
    if (mtl_link_drawable) {
        mtl_current_drawable = mtl_link_drawable;
        metal_frame_used_link_drawable = true;  // pace=link (vs L2 pace=immediate)
        if (metal_stats_enabled()) metal_frame_encode_start = CACurrentMediaTime();
        return true;
    }
    if (mtl_current_layer) {
        CGSize ds = mtl_current_layer.drawableSize;
        if (ds.width < 1 || ds.height < 1) {
            if (mtl_viewport.width > 0 && mtl_viewport.height > 0) {
                mtl_current_layer.drawableSize = CGSizeMake(mtl_viewport.width, mtl_viewport.height);
            } else {
                return false;
            }
        }
        // Phase 0: nextDrawable can block on the drawable pool — span it.
        // p99 (worker-prof #16): time the block so it lands in drawable_wait_ms,
        // and stamp encode_ms's start only AFTER the drawable is in hand.
        const bool st = metal_stats_enabled();
        const double wait_t0 = st ? CACurrentMediaTime() : 0.0;
        if (metal_signpost_enabled()) {
            os_log_t slog = metal_signpost_log();
            os_signpost_id_t sid = os_signpost_id_generate(slog);
            os_signpost_interval_begin(slog, sid, "drawable_acquire", "");
            mtl_current_drawable = [mtl_current_layer nextDrawable];
            os_signpost_interval_end(slog, sid, "drawable_acquire", "");
        } else {
            mtl_current_drawable = [mtl_current_layer nextDrawable];
        }
        if (st) {
            const double now = CACurrentMediaTime();
            metal_frame_drawable_wait += now - wait_t0;      // reported as drawable_wait_ms
            if (mtl_current_drawable) metal_frame_encode_start = now; // encode_ms starts here
        }
    }
    return mtl_current_drawable != nil;
}

// The texture the current frame's drawable-bound content renders into: the
// link/nextDrawable drawable.
static id<MTLTexture>
current_drawable_texture(void) {
    return mtl_current_drawable.texture;
}

// C4a/e: persistent offscreen render target used only in KITTY_METAL_DUMP_FRAME
// mode. It mirrors the default drawable exactly (plain BGRA8Unorm; C1: sRGB is
// encoded in-shader, so no sRGB view is needed), so the final frame lands here
// byte-identically to how it would on the drawable — the harness reads THIS
// readable texture instead of drawable.texture, which lets the drawable be
// framebufferOnly=YES. Not on any production path.
// W27 P3.2: deliberately pinned to BGRA8 even when a wide candidate is selected
// — the golden harness and the thumbnail read-back both decode 4 bytes/pixel,
// and because the encode is chosen per attachment format this stays a correct
// sRGB render rather than a mis-tagged one.
static id<MTLTexture> dump_offscreen_base = nil;
static NSUInteger dump_offscreen_w = 0, dump_offscreen_h = 0;

static bool
ensure_dump_offscreen(void) {
    if (!mtl_current_layer) return false;
    CGSize ds = mtl_current_layer.drawableSize;
    NSUInteger w = (NSUInteger)ds.width, h = (NSUInteger)ds.height;
    if (w < 1 || h < 1) {
        if (mtl_viewport.width > 0 && mtl_viewport.height > 0) {
            w = (NSUInteger)mtl_viewport.width; h = (NSUInteger)mtl_viewport.height;
        } else return false;
    }
    if (dump_offscreen_base && dump_offscreen_w == w && dump_offscreen_h == h) return true;
    [dump_offscreen_base release]; dump_offscreen_base = nil;
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                    width:w height:h mipmapped:NO];
    // RenderTarget so it can be the layered pass's att1 / the opaque drawable
    // stand-in; Shared so the harness can getBytes it directly.
    desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    desc.storageMode = MTLStorageModeShared;
    dump_offscreen_base = [mtl_device newTextureWithDescriptor:desc];
    if (!dump_offscreen_base) return false;
    dump_offscreen_w = w; dump_offscreen_h = h;
    return dump_offscreen_base != nil;
}

// The attachment format the next render pass must use, given the bound
// framebuffer. C1: the drawable is a single format — plain BGRA8Unorm, or the
// W27 P3.2 candidate — and sRGB is encoded in-shader (opaque cells/borders) or
// in the resolve draw (layered), so GL_FRAMEBUFFER_SRGB no longer selects a
// drawable view.
static MTLPixelFormat
wanted_attachment_format(bool for_clear) {
    (void)for_clear;
    // M1: during a layered pass every compositing draw targets att0 (the working
    // surface), so the encoder must never be torn down by a format mismatch.
    if (layered_pass_active && current_window_slot) return current_window_slot->layered_work_surface_fmt;
    if (bound_framebuffer && bound_framebuffer < MAX_FRAMEBUFFERS &&
        framebuffers[bound_framebuffer].in_use && framebuffers[bound_framebuffer].render_target) {
        return framebuffers[bound_framebuffer].render_target.pixelFormat;
    }
    return drawable_attachment_format();
}

// M1: the memoryless RGBA16Unorm working surface (att0), grown to the drawable
// size. Memoryless => contents live only in tile memory during the pass, never
// DRAM, so a resize just recreates a zero-cost descriptor (no allocs= impact —
// that counter tracks MTLBuffer allocations only). Same RGBA16Unorm format as
// the old DRAM layers FBO, so blending precision (#8953) is unchanged.
// W27 P4.2: the format is part of the cache key now, not just the size — an EDR
// engagement flip must rebuild the surface, not silently keep rendering >1.0
// content into a texture that clamps it. Memoryless RGBA16Float (with blending)
// is supported on Apple GPUs, so the tile-only storage mode survives the flip.
// H2: cached per window. current_window_slot is guarded explicitly rather than
// inferred: metal_set_current_layer(NULL) leaves it NULL, and a layered frame
// without a window to own the surface has nowhere to cache it.
static bool
ensure_layered_work_surface(NSUInteger w, NSUInteger h) {
    MetalWindowSlot *s = current_window_slot;
    if (!s || w < 1 || h < 1) return false;
    const MTLPixelFormat want = layered_work_fmt();
    if (s->layered_work_surface && s->layered_work_w == w && s->layered_work_h == h && s->layered_work_surface_fmt == want) return true;
    [s->layered_work_surface release]; s->layered_work_surface = nil;
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:want
                                                                                    width:w height:h mipmapped:NO];
    desc.usage = MTLTextureUsageRenderTarget;    // framebuffer-fetch read+write; never sampled
    desc.storageMode = MTLStorageModeMemoryless; // tile memory only, never DRAM
    s->layered_work_surface = [mtl_device newTextureWithDescriptor:desc];
    if (!s->layered_work_surface) {
        s->layered_work_w = s->layered_work_h = 0; s->layered_work_surface_fmt = MTLPixelFormatInvalid; return false;
    }
    // Counted here, on the creation path only -- never on the cache-hit return
    // above, which is the whole point of the measurement.
    metal_layered_surface_creates++;
    if (global_state.debug_rendering && s->layered_work_surface_fmt != want) {
        NSLog(@"[Metal] layered working surface -> %s (%lux%lu, EDR %s, headroom %.3f)",
              want == LAYERED_WORK_FMT_EDR ? "RGBA16Float" : "RGBA16Unorm",
              (unsigned long)w, (unsigned long)h, edr_frame_engaged ? "engaged" : "off",
              (double)edr_frame_headroom);
    }
    s->layered_work_w = w; s->layered_work_h = h; s->layered_work_surface_fmt = want;
    return true;
}

// W27 P4.2: the current OS window's EDR state, published by child-monitor's
// lazy-engagement block (prepare_to_render_os_window) once per prepare, before
// that window's frame is encoded. It selects the working-surface format for the
// frame; the headroom is recorded for diagnostics and to keep the two halves of
// the tone-map policy (shader clamp target vs layer capability) reading from one
// source. Idempotent, so the caller can invoke it unconditionally.
void
metal_set_edr_frame_state(bool engaged, float headroom) {
    edr_frame_engaged = engaged;
    edr_frame_headroom = headroom >= 1.0f ? headroom : 1.0f;
}

// M1: the resolve PSO (fullscreen; reads att0 via [[color(0)]], writes att1).
// Built once per att1 format; committed command buffers retain it.
static id<MTLRenderPipelineState>
ensure_layers_resolve_pso(MTLPixelFormat att0_fmt, MTLPixelFormat att1_fmt) {
    for (size_t i = 0; i < arraysz(layers_resolve_psos); i++) {
        if (layers_resolve_psos[i].pso && layers_resolve_psos[i].att0_fmt == att0_fmt &&
                layers_resolve_psos[i].att1_fmt == att1_fmt)
            return layers_resolve_psos[i].pso;
    }
    if (!mtl_default_library) return nil;
    NSError *error = nil;
    // W27 P3.2: the resolve is where layered frames get their sRGB encode, so it
    // obeys the same rule as the opaque fragments — encode only when att1 is the
    // plain 8-bit target. A wide candidate writes linear (the _srgb XR format's
    // ROP encodes on store; the linear-stored ones want linear).
    MTLFunctionConstantValues *fc = [[MTLFunctionConstantValues alloc] init];
    const int resolve_target_space = target_color_space_for(att1_fmt, false);
    const bool resolve_primaries_is_p3 = target_primaries_is_p3_for(att1_fmt, false);
    [fc setConstantValue:&resolve_target_space type:MTLDataTypeInt atIndex:0]; // TARGET_COLOR_SPACE
    [fc setConstantValue:&resolve_primaries_is_p3 type:MTLDataTypeBool atIndex:1]; // TARGET_PRIMARIES_IS_P3
    id<MTLFunction> v = [mtl_default_library newFunctionWithName:@"layers_resolve_vertex"];
    id<MTLFunction> f = [mtl_default_library newFunctionWithName:@"layers_resolve_fragment"
                                                 constantValues:fc error:&error];
    if (!v || !f) { log_error("Metal: layers_resolve shader functions missing from metallib"); return nil; }
    MTLRenderPipelineDescriptor *d = [[MTLRenderPipelineDescriptor alloc] init];
    d.vertexFunction = v;
    d.fragmentFunction = f;
    d.colorAttachments[0].pixelFormat = att0_fmt;          // att0: read + passthrough (discarded)
    d.colorAttachments[1].pixelFormat = att1_fmt;          // att1: the drawable / capture offscreen
    id<MTLRenderPipelineState> pso = [mtl_device newRenderPipelineStateWithDescriptor:d error:&error];
    if (!pso) {
        log_error("Metal: failed to build layers resolve PSO: %s",
                error ? [[error localizedDescription] UTF8String] : "unknown");
        return nil;
    }
    for (size_t i = 0; i < arraysz(layers_resolve_psos); i++) {
        if (!layers_resolve_psos[i].pso) {
            layers_resolve_psos[i].pso = pso;
            layers_resolve_psos[i].att0_fmt = att0_fmt; layers_resolve_psos[i].att1_fmt = att1_fmt;
            return pso;
        }
    }
    log_error("Metal: layers resolve PSO cache overflow");  // unreachable: at most 2 att0 x 2 att1 formats
    [pso release];
    return nil;
}

// M1: open the single layered render pass. att0 = memoryless RGBA16Unorm working
// surface (cleared to transparent, mirroring clear_current_framebuffer on the old
// FBO), att1 = the drawable (or golden-dump offscreen). All subsequent layered
// compositing draws render linear-premultiplied into att0 via the existing
// shaders; metal_resolve_layered_frame() finishes the pass. Replaces the GL FBO
// setup in start_os_window_rendering on the Metal backend.
void
metal_begin_layered_frame(void) {
    if (!mtl_current_layer) return;
    end_current_encoder();
    if (!ensure_command_buffer()) return;

    id<MTLTexture> att1 = nil;
    if (metal_capture_to_offscreen()) {
        // Capture mode (golden dump or pending thumbnail): resolve into the
        // readable offscreen (plain BGRA8Unorm, sRGB encoded in-shader) instead of
        // the drawable — no drawable acquired.
        if (!ensure_dump_offscreen()) return;
        att1 = dump_offscreen_base;
    } else {
        if (!ensure_drawable()) return;
        att1 = current_drawable_texture();  // plain BGRA8Unorm base, or the P3.2 candidate
    }
    if (!att1) return;
    if (!ensure_layered_work_surface(att1.width, att1.height)) return;

    MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
    rpd.colorAttachments[0].texture = current_window_slot->layered_work_surface;
    rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
    rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
    rpd.colorAttachments[0].storeAction = MTLStoreActionDontCare;  // tile-only
    rpd.colorAttachments[1].texture = att1;
    // First drawable pass this frame => DontCare (the resolve overwrites 100%);
    // if an earlier pass wrote the drawable (live-resize blank) => Load to keep it.
    rpd.colorAttachments[1].loadAction = drawable_pass_opened ? MTLLoadActionLoad : MTLLoadActionDontCare;
    rpd.colorAttachments[1].storeAction = MTLStoreActionStore;
    mtl_current_render_pass = rpd;

    mtl_current_encoder = [mtl_current_command_buffer renderCommandEncoderWithDescriptor:rpd];
    if (!mtl_current_encoder) return;
    // draw_quad picks the layered (2-attachment) PSOs; the DYNAMIC att0 format
    // (W27 P4.2) flows through here into pso_get's cache key, so the SDR and EDR
    // working-surface variants can never be confused for one another.
    mtl_current_enc_fmt = current_window_slot->layered_work_surface_fmt;
    layered_pass_active = true;
    drawable_pass_opened = true;
    metal_pass_count++;  // the whole layered frame is this one encoder (acceptance criterion 2)
}

// M1: resolve the working surface (att0) onto the drawable (att1) in-shader and
// end the layered pass. Replaces the separate BLIT pass in stop_os_window_
// rendering on the Metal backend; the drawable is stored, the memoryless working
// surface discarded. Safe to call when no layered pass is active (no-op).
void
metal_resolve_layered_frame(void) {
    if (!layered_pass_active) return;
    if (mtl_current_encoder) {
        // att1's real format, straight from the pass being resolved (drawable or
        // capture offscreen), so the PSO can never disagree with it.
        id<MTLRenderPipelineState> pso = ensure_layers_resolve_pso(
                mtl_current_render_pass.colorAttachments[0].texture.pixelFormat,
                mtl_current_render_pass.colorAttachments[1].texture.pixelFormat);
        if (pso) {
            MTLViewport full = {0, 0, (double)current_window_slot->layered_work_w, (double)current_window_slot->layered_work_h, 0, 1};
            MTLScissorRect fullsr = {0, 0, current_window_slot->layered_work_w, current_window_slot->layered_work_h};
            [mtl_current_encoder setViewport:full];
            [mtl_current_encoder setScissorRect:fullsr];
            [mtl_current_encoder setRenderPipelineState:pso];
            [mtl_current_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        }
    }
    end_current_encoder();          // stores att1 (drawable); att0 (memoryless) discarded
    layered_pass_active = false;
}

// W27 P3.2: kitty hands the drawable's clear colour over sRGB-ENCODED and
// premultiplied (blank_canvas(..., for_final_output=true), kitty/shaders.c),
// which is exactly right for the plain BGRA8Unorm arm — the bytes go straight
// out. Every wide candidate's pipeline is linear instead (the _srgb XR format's
// ROP encodes on store, the other two store linear), so the clear must be
// linearized to match, or the padding kitty clears lands a whole gamma away
// from the cells that abut it.
// W27 P3.4: the clear is the ONE consumer of the transfer that is not a shader,
// so it deliberately asks the SAME predicate the fragments are specialized with
// (target_color_space_for) instead of testing formats itself. If a future
// target space needs different clear handling this is where it shows up: a
// shader-side change alone would silently leave the cleared padding behind.
static MTLClearColor
drawable_clear_color(MTLPixelFormat fmt) {
    if (target_color_space_for(fmt, false) == TARGET_SPACE_ENCODE_SRGB)
        return MTLClearColorMake(clear_r, clear_g, clear_b, clear_a);
    const double a = clear_a;
    const double inv = a > 0 ? 1.0 / a : 0.0;  // the transfer curve is defined on
    double c[3] = {clear_r * inv, clear_g * inv, clear_b * inv};  // UNpremultiplied colour
    for (int i = 0; i < 3; i++) {
        const double v = c[i] <= 0.04045 ? c[i] / 12.92 : pow((c[i] + 0.055) / 1.055, 2.4);
        c[i] = v * a;  // back to premultiplied, which is what CA composites
    }
    // W27 P3.5: the clear is also the one non-shader consumer of the primaries
    // conversion — same rule as the fragments (matrix on linear values;
    // commutes with the premultiplication above).
    if (target_primaries_is_p3_for(fmt, false)) {
        double p3[3];
        for (int i = 0; i < 3; i++)
            p3[i] = MAX(0.0, srgb_to_p3_matrix[i][0] * c[0] + srgb_to_p3_matrix[i][1] * c[1] + srgb_to_p3_matrix[i][2] * c[2]);
        memcpy(c, p3, sizeof(c));
    }
    return MTLClearColorMake(c[0], c[1], c[2], a);
}

static id<MTLRenderCommandEncoder>
begin_render_pass_to_drawable(bool clear) {
    end_current_encoder();
    if (!ensure_command_buffer()) return nil;

    id<MTLTexture> target_texture = nil;
    bool targeting_drawable = false;

    // Determine render target: offscreen framebuffer, golden-dump offscreen, or
    // the main drawable.
    if (bound_framebuffer && bound_framebuffer < MAX_FRAMEBUFFERS &&
        framebuffers[bound_framebuffer].in_use && framebuffers[bound_framebuffer].render_target) {
        target_texture = framebuffers[bound_framebuffer].render_target;
    } else if (metal_capture_to_offscreen()) {
        // Capture mode (golden dump or pending thumbnail): render the
        // drawable-bound content to the readable offscreen instead. No drawable
        // is acquired (the reader takes the offscreen; nothing is presented). C1:
        // plain BGRA8Unorm (sRGB encoded in-shader), so the bytes match the
        // drawable exactly.
        if (!ensure_dump_offscreen()) return nil;
        target_texture = dump_offscreen_base;
        targeting_drawable = true;
    } else {
        if (!ensure_drawable()) return nil;
        target_texture = current_drawable_texture();  // plain BGRA8Unorm (sRGB in-shader), or the P3.2 candidate
        targeting_drawable = true;
    }
    if (!target_texture) return nil;

    MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
    rpd.colorAttachments[0].texture = target_texture;
    if (clear) {
        rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
        rpd.colorAttachments[0].clearColor = drawable_clear_color(target_texture.pixelFormat);
    } else if (targeting_drawable && !drawable_pass_opened) {
        // M3: first drawable pass of the frame. The drawable is recycled from a
        // pool so its prior contents are meaningless, and kitty repaints 100% of
        // it — discard instead of loading a full drawable's worth of tile memory
        // (~31 MB @ 3456x2234 avoided per frame). Later drawable passes this
        // frame Load, preserving the earlier draws.
        rpd.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    } else {
        rpd.colorAttachments[0].loadAction = MTLLoadActionLoad;
    }
    rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
    if (targeting_drawable) drawable_pass_opened = true;
    mtl_current_render_pass = rpd;

    mtl_current_encoder = [mtl_current_command_buffer renderCommandEncoderWithDescriptor:rpd];
    mtl_current_enc_fmt = target_texture.pixelFormat;
    metal_pass_count++;  // Phase 0: acceptance-criterion-2 probe (== 1 for opaque frames)
    return mtl_current_encoder;
}

// Golden-image harness read-back (KITTY_METAL_DUMP_FRAME). The frame was
// rendered into dump_offscreen_base (begin_render_pass_to_drawable redirects the
// drawable-bound content there in dump mode); commit + wait for the GPU, then
// read that readable texture and write the PNG. No drawable is acquired or
// presented, so this path never touches drawable.texture and is independent of
// the layer's framebufferOnly setting. Dev/testing only — stalls every frame.
static void
dump_offscreen_frame(id<MTLCommandBuffer> cb, const char *path) {
    METAL_TRACE("dump: commit\n");
    [cb commit];
    [cb waitUntilCompleted];
    METAL_TRACE("dump: completed status=%ld\n", (long)cb.status);
    id<MTLTexture> tex = dump_offscreen_base;
    if (!tex) return;
    size_t w = tex.width, h = tex.height;
    uint32_t *data = malloc(w * h * 4);
    if (!data) return;
    [tex getBytes:data bytesPerRow:w * 4 fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0];
    METAL_TRACE("dump: read offscreen %zux%zu\n", w, h);
    for (size_t i = 0; i < w * h; i++) { // BGRA -> RGBA for the PNG encoder
        uint32_t px = data[i];
        data[i] = (px & 0xff00ff00u) | ((px & 0xffu) << 16) | ((px >> 16) & 0xffu);
    }
    size_t sz = 0;
    const char *png = png_from_32bit_rgba((const char*)data, w, h, &sz, false);
    if (sz) {
        char tmp[1024];
        snprintf(tmp, sizeof(tmp), "%s.tmp", path);
        FILE *f = fopen(tmp, "wb");
        if (f) { fwrite(png, 1, sz, f); fclose(f); rename(tmp, path); }
    }
    free(data);
}

// Dump one layer of a texture as straight RGBA PNG (dev harness).
static void
dump_texture_layer(GLuint tex_id, unsigned layer, const char *path) {
    MetalTexture *t = get_texture(tex_id);
    if (!t || !t->texture) return;
    size_t w = t->texture.width, h = t->texture.height;
    uint32_t *data = malloc(w * h * 4);
    if (!data) return;
    [t->texture getBytes:data bytesPerRow:w * 4 bytesPerImage:0 fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 slice:layer];
    size_t sz = 0;
    const char *png = png_from_32bit_rgba((const char*)data, w, h, &sz, false);
    if (sz) { FILE *f = fopen(path, "wb"); if (f) { fwrite(png, 1, sz, f); fclose(f); } }
    free(data);
    METAL_TRACE("dumped texture %u layer %u (%zux%zu) to %s\n", tex_id, layer, w, h, path);
}

void
metal_end_frame(void) {
    end_current_encoder();
    METAL_TRACE("end_frame[%d]: cb=%d drawable=%d\n", metal_frame_counter++, mtl_current_command_buffer != nil, mtl_current_drawable != nil);
    {
        static bool atlas_dumped = false;
        const char *ap = getenv("KITTY_METAL_DUMP_ATLAS");
        if (ap && !atlas_dumped && metal_frame_counter > 5) { atlas_dumped = true; dump_texture_layer(2, 0, ap); }
        static bool fbo_dumped = false;
        const char *fp = getenv("KITTY_METAL_DUMP_FBO");
        if (fp && !fbo_dumped && metal_frame_counter > 5 && framebuffers[1].render_target) {
            fbo_dumped = true;
            id<MTLTexture> t = framebuffers[1].render_target;
            size_t w = t.width, h = t.height;
            uint16_t *raw = malloc(w * h * 8);
            uint32_t *rgba = malloc(w * h * 4);
            if (raw && rgba) {
                [t getBytes:raw bytesPerRow:w * 8 fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0];
                for (size_t i = 0; i < w * h; i++) {
                    uint32_t r = raw[i*4] / 257, g = raw[i*4+1] / 257, b = raw[i*4+2] / 257, a = raw[i*4+3] / 257;
                    rgba[i] = r | (g << 8) | (b << 16) | (a << 24);
                }
                size_t sz = 0;
                const char *png = png_from_32bit_rgba((const char*)rgba, w, h, &sz, false);
                if (sz) { FILE *f = fopen(fp, "wb"); if (f) { fwrite(png, 1, sz, f); fclose(f); } }
                METAL_TRACE("dumped FBO texture (%zux%zu fmt=%lu) to %s\n", w, h, (unsigned long)t.pixelFormat, fp);
            }
            free(raw); free(rgba);
        }
    }
    if (mtl_current_command_buffer) {
        // Phase 0: close the CPU-encode span (opened at cb creation) and open a
        // present span around commit+present; frame stats and the present
        // timestamp are captured into the async handlers registered below.
        const bool sp = metal_signpost_enabled();
        const bool st = metal_stats_enabled();
        os_log_t slog = sp ? metal_signpost_log() : NULL;
        os_signpost_id_t present_sid = OS_SIGNPOST_ID_INVALID;
        if (sp) {
            os_signpost_interval_end(slog, os_signpost_id_make_with_pointer(slog, (__bridge void *)mtl_current_command_buffer), "frame_encode", "");
            present_sid = os_signpost_id_generate(slog);
            os_signpost_interval_begin(slog, present_sid, "present", "");
        }
        const uint64_t fidx = metal_frame_index++;
        // US-307: ungated per-frame completion watermark. When THIS frame's GPU
        // work finishes, advance metal_completed_fidx so the CPU can tell whether
        // an image texture a committed frame referenced is still being sampled
        // (async present). Must be unconditional -- the in-place-upload race exists
        // whenever a committed frame is in flight, independent of stats/signpost.
        // Single queue => FIFO completion, so the max is a formality that also
        // stays correct if a future path completes buffers out of order.
        [mtl_current_command_buffer addCompletedHandler:^(id<MTLCommandBuffer> cb) {
            (void)cb;
            uint64_t prev = atomic_load_explicit(&metal_completed_fidx, memory_order_relaxed);
            while (prev < fidx && !atomic_compare_exchange_weak_explicit(
                       &metal_completed_fidx, &prev, fidx, memory_order_release, memory_order_relaxed)) { }
        }];
        // Phase 4 step 6 (observability): attribute every frame's scheduling
        // source. resize (presentsWithTransaction) > unsynced (sync_to_monitor=no
        // => displaySyncEnabled=NO) > link (CAMetalDisplayLink drawable) >
        // immediate (L2 input-driven render outside the link). String literals are
        // static, so capturing `pace` in the async handlers below is safe.
        const char *pace =
            (mtl_current_layer && mtl_current_layer.presentsWithTransaction) ? "resize" :
            (mtl_current_layer && !mtl_current_layer.displaySyncEnabled) ? "unsynced" :
            metal_frame_used_link_drawable ? "link" : "immediate";
        if (st) {
            // GPU times are valid only once the buffer completes; encode ms and
            // the pass count are known now, so capture them into the handler.
            const double encode_ms = metal_frame_encode_start > 0.0 ? (CACurrentMediaTime() - metal_frame_encode_start) * 1000.0 : 0.0;
            const double drawable_wait_ms = metal_frame_drawable_wait * 1000.0; // p99: nextDrawable block, excluded from encode_ms
            const int passes = metal_pass_count;
            const int allocs = metal_frame_alloc_count; // D1: MTLBuffer allocs this frame (0 in steady state)
            const int tex_allocs = metal_frame_tex_alloc_count; // G1: MTLTexture (re)allocs this frame (0 in steady-state animation)
            const uint64_t tex_bytes = metal_frame_tex_upload_bytes; // G3-lite: image-texture upload bytes this frame (delta rect vs full image)
            const int gfx_draws = metal_frame_gfx_draw_count; // G2: graphics-program draw calls this frame (instancing collapses group refs)
            const uint64_t bytes = metal_frame_bytes_uploaded; // D2: VAO-buffer bytes uploaded this frame
            // H1 anti-vacuity counters. Process-cumulative, not per-frame, and
            // captured here because the handler runs on a Metal callback thread
            // while these are plain main-thread counters.
            const uint64_t guard_checks = metal_sprite_guard_checks;
            const uint64_t guard_stamped = metal_sprite_guard_stamped;
            const uint64_t guard_waits = metal_sprite_guard_waits;
            const uint64_t guard_timeouts = metal_sprite_guard_timeouts;
            const uint64_t guard_selfframe = metal_sprite_guard_selfframe;
            const uint64_t layered_creates = metal_layered_surface_creates;  // H2
            [mtl_current_command_buffer addCompletedHandler:^(id<MTLCommandBuffer> cb) {
                const double gpu_ms = (cb.GPUEndTime - cb.GPUStartTime) * 1000.0;
                // Sized from the worst case, recomputed whenever a field is
                // added: every counter at UINT64_MAX, every float at its widest,
                // is 534 bytes. snprintf would truncate silently, which on a
                // tail-appended format means the NEWEST field is the one lost.
                char line[640];
                // pace= is tail-appended (tolerant parsers, never $-anchored).
                // W28.0c: gpu_end= is the ABSOLUTE host time the GPU finished this
                // command buffer (gpu_ms stays the unchanged duration). It closes
                // the {commit->gpu-done} term of the S5 partition and opens
                // {gpu-done->presented}; both neighbours (metal_commit's
                // commit_time and metal_present's presented_time) are host time in
                // the same mach timebase, so the terms subtract directly.
                snprintf(line, sizeof line, "metal_stats frame=%llu encode_ms=%.3f gpu_ms=%.3f passes=%d allocs=%d tex_allocs=%d tex_bytes=%llu gfx_draws=%d bytes=%llu drawable_wait_ms=%.3f pace=%s gpu_end=%.9f sprite_guard_checks=%llu sprite_guard_stamped=%llu sprite_guard_waits=%llu sprite_guard_timeouts=%llu sprite_guard_selfframe=%llu layered_surface_creates=%llu\n",
                         (unsigned long long)fidx, encode_ms, gpu_ms, passes, allocs, tex_allocs, (unsigned long long)tex_bytes, gfx_draws, (unsigned long long)bytes, drawable_wait_ms, pace, cb.GPUEndTime,
                         (unsigned long long)guard_checks, (unsigned long long)guard_stamped,
                         (unsigned long long)guard_waits, (unsigned long long)guard_timeouts,
                         (unsigned long long)guard_selfframe, (unsigned long long)layered_creates);
                metal_stats_emit(line);
            }];
        }
        // Present timestamp (photon-adjacent) for the latency harness. The line
        // is still emitted under stats OR signpost only -- one line per present,
        // keyed to the frame id.
        // W28.0c: the HANDLER itself is now registered for every frame that has a
        // drawable, because the (frame, presentedTime) pair it stamps is the only
        // in-process record of when a frame actually reached the display, and a
        // reader that can only see it in instrumented runs cannot use it. The
        // per-frame block allocation is what battery 1 prices; the file write
        // stays gated.
        const int slot_idx = window_slot_index();
        if (mtl_current_drawable) {
            const bool emit_present = st || sp;
            const monotonic_t media_offset = media_time_to_monotonic_offset();  // sampled here: main thread
            // Captured by value: the handler must publish under the epoch this
            // slot index held at REGISTRATION, so that if the window dies before
            // the present lands the write is rejected instead of resurfacing as
            // the next window's stamp.
            const uint64_t slot_epoch = (slot_idx >= 0) ? metal_present_epochs[slot_idx] : 0;
            [mtl_current_drawable addPresentedHandler:^(id<MTLDrawable> d) {
                const double presented = d.presentedTime;
                stamp_present(slot_idx, slot_epoch, fidx, presented == 0.0 ? 0 : s_double_to_monotonic_t(presented) + media_offset);
                if (emit_present) {
                    char line[128];
                    snprintf(line, sizeof line, "metal_present frame=%llu presented_time=%.9f pace=%s\n",
                             (unsigned long long)fidx, presented, pace);
                    metal_stats_emit(line);
                }
            }];
        }

        const char *dump_path = metal_dump_frame_path();
        if (dump_path) {
            // Golden dump: the frame was rendered to the readable offscreen and
            // no drawable was acquired — commit + wait + read it + write the PNG.
            dump_offscreen_frame(mtl_current_command_buffer, dump_path);
        } else if (mtl_current_drawable && mtl_current_layer && mtl_current_layer.presentsWithTransaction) {
            // Live resize: present inside the current CA transaction so the
            // frame stays in lockstep with the window chrome. Documented
            // sequence: commit, wait until scheduled, then present.
            [mtl_current_command_buffer commit];
            [mtl_current_command_buffer waitUntilScheduled];
            [mtl_current_drawable present];
        } else {
            if (mtl_current_drawable) {
                [mtl_current_command_buffer presentDrawable:mtl_current_drawable];
            }
            [mtl_current_command_buffer commit];
        }
        // W28.0c: post-commit CPU stamp. Taken on the main thread the moment the
        // commit returns, so it carries no handler-dispatch latency: it closes the
        // {gate->commit} term of the S5 partition and opens {commit->gpu-done}.
        // It cannot ride the metal_stats/metal_present lines -- both handlers are
        // registered BEFORE the commit, so the value does not exist yet when they
        // capture -- hence its own record.
        const double commit_time = (st || sp) ? CACurrentMediaTime() : 0.0;
        if (sp) os_signpost_interval_end(slog, present_sid, "present", "");
        if (st || sp) {
            // prev_present_* is the newest present this window had stamped as of
            // this commit. It is the freshness datum the plan's floor-reference
            // question needs: a presentedTime-based pacing floor is only usable if
            // the stamp visible at gate time belongs to a recent frame, and
            // prev_present_frame vs frame= measures exactly that lag. Reported on
            // kitty's monotonic clock -- the same one the ktrace gate_ms stamps
            // use -- so the two subtract with no epoch shift, while commit_time
            // stays on the mach host clock its partition neighbours use.
            // -1 in either field means "no present stamped yet for this window".
            uint64_t prev_fidx = 0; monotonic_t prev_at = 0;
            const bool have_prev = read_present_stamp(slot_idx, &prev_fidx, &prev_at);
            char line[192];
            snprintf(line, sizeof line, "metal_commit frame=%llu commit_time=%.9f prev_present_frame=%lld prev_present_mono_ms=%.3f pace=%s\n",
                     (unsigned long long)fidx, commit_time,
                     have_prev ? (long long)prev_fidx : -1LL,
                     have_prev ? monotonic_t_to_s_double(prev_at) * 1000.0 : -1.0, pace);
            metal_stats_emit(line);
        }
        mtl_current_command_buffer = nil;
        mtl_current_drawable = nil;
    }
    mtl_current_render_pass = nil;
    clear_pending = false;
    metal_pass_count = 0;         // Phase 0: reset for the next frame (per current window)
    metal_frame_encode_start = 0.0; // p99: re-stamped in ensure_drawable, so clear here
    metal_frame_drawable_wait = 0.0; // p99: reset per-frame nextDrawable-wait accumulator
    metal_frame_alloc_count = 0;  // D1: reset per-frame ring allocation counter
    metal_frame_tex_alloc_count = 0;  // G1: reset per-frame texture (re)alloc counter
    metal_frame_tex_upload_bytes = 0;  // G3-lite: reset per-frame image-upload-bytes counter
    metal_frame_gfx_draw_count = 0;  // G2: reset per-frame graphics draw-call counter
    metal_frame_bytes_uploaded = 0; // D2: reset per-frame upload-bytes counter
    drawable_pass_opened = false; // M3: next frame's first drawable pass discards again
    layered_pass_active = false;  // M1: defensive — resolve normally clears it
    metal_frame_used_link_drawable = false; // pace: recomputed per frame in ensure_drawable
}

// W27 P2.4a (ADR-0021): timer-paced CAMetalLayer opt-in. When set, the legacy
// drawable arm is driven by the plain-CADisplayLink pace timer instead of a
// CAMetalDisplayLink (glfw/metal_context.m must agree — same env var, same
// default), so NO link ever owns the layer's drawable pool and the L2
// immediate-encode path is safe on the drawable arm too: nextDrawable is the
// pool's sole consumer. This is the echo-immediate port the arm consolidation
// requires (the winner arm lacked it; per-arm battery: typing presents 32 vs
// ~1100 per 30 s).
bool
metal_timer_pace_enabled(void) {
    // W27 (ADR-0021): default ON (the winner arm ships timer-paced); =0
    // restores the CAMetalDisplayLink driver for diagnosis.
    static int state = -1;
    if (state < 0) { const char *v = getenv("KITTY_METAL_TIMER_PACE"); state = (v && v[0] && v[0] == '0') ? 0 : 1; }
    return state == 1;
}

bool
metal_immediate_encode_enabled(void) {
    // W27: under timer pace no CAMetalDisplayLink is attached — the drawable
    // pool is unowned, nextDrawable-at-any-instant is the pre-Wave-4 proven
    // path, and L2 immediate-encode is safe (the SIGSEGV below was pool
    // ownership, not the layer). This is the low-latency half of the flood
    // pacing governor: cold input renders NOW, and render_prepared_os_window's
    // request_frame_render resumes the pace link so sustained damage collapses
    // to refresh-rate ticks.
    if (metal_timer_pace_enabled()) return true;
    // KITTY_METAL_TIMER_PACE=0 restores the CAMetalDisplayLink driver, where
    // rendering an input frame via nextDrawable while the link is attached
    // corrupts the drawable pool (SIGSEGV — see the "L2 ... DEFERRED" note in
    // metal-pipeline-design.md). KITTY_METAL_IMMEDIATE stays NEUTERED there —
    // it logs once and does nothing.
    static bool checked = false;
    if (!checked) {
        checked = true;
        const char *v = getenv("KITTY_METAL_IMMEDIATE");
        if (v && v[0] && strcmp(v, "0") != 0)
            log_error("KITTY_METAL_IMMEDIATE: immediate-encode requires the timer-paced "
                      "driver (see kitty/metal-pipeline-design.md); ignored");
    }
    return false;
}

// ----- GL Compatibility Functions (metal_gl_*) -----
// These are called via macros defined in metal.h

void metal_gl_enable(GLenum cap) {
    switch (cap) {
        case GL_BLEND: break; // blending is baked into each PSO
        case GL_FRAMEBUFFER_SRGB: framebuffer_srgb_enabled = true; break;
        case GL_SCISSOR_TEST: scissor_enabled = true; break;
        default: break;
    }
}

void metal_gl_disable(GLenum cap) {
    switch (cap) {
        case GL_BLEND: break; // blending is baked into each PSO
        case GL_FRAMEBUFFER_SRGB: framebuffer_srgb_enabled = false; break;
        case GL_SCISSOR_TEST: scissor_enabled = false; break;
        default: break;
    }
}

void metal_gl_clear_color(float r, float g, float b, float a) {
    clear_r = r; clear_g = g; clear_b = b; clear_a = a;
}

void metal_gl_clear(unsigned mask) {
    (void)mask;
    clear_pending = true;
    // GL converts clear colors on write only when FRAMEBUFFER_SRGB is on at
    // clear time; capture it for deferred application.
    clear_srgb_flag = framebuffer_srgb_enabled;
    if (mtl_current_layer) {
        end_current_encoder();
        begin_render_pass_to_drawable(true);
        clear_pending = false;
    }
}



void metal_gl_get_integerv(GLenum pname, GLint *params) {
    switch (pname) {
        case GL_VIEWPORT:
            params[0] = (GLint)mtl_viewport.originX;
            params[1] = (GLint)mtl_viewport.originY;
            params[2] = (GLint)mtl_viewport.width;
            params[3] = (GLint)mtl_viewport.height;
            break;
        case GL_MAX_TEXTURE_SIZE:
            // Metal supports up to 16384 on most Apple GPUs
            params[0] = 8192; // conservative limit matching existing Apple GL path
            break;
        case GL_MAX_ARRAY_TEXTURE_LAYERS:
            params[0] = 512; // matching existing Apple GL path
            break;
        case GL_TEXTURE_BINDING_2D:
            params[0] = 0;
            break;
        case GL_DRAW_FRAMEBUFFER_BINDING:
            params[0] = (GLint)bound_framebuffer;
            break;
        default:
            params[0] = 0;
            break;
    }
}

void metal_gl_active_texture(GLenum unit) {
    active_texture_unit = unit - 0x84C0; // GL_TEXTURE0 = 0x84C0
    if (active_texture_unit >= MAX_TEXTURE_UNITS) active_texture_unit = 0;
}

// Track "currently bound" texture per target type (for tex_image/tex_sub operations)
static GLuint currently_bound_texture_2d = 0;
static GLuint currently_bound_texture_2d_array = 0;

void metal_gl_bind_texture(GLenum target, GLuint id) {
    if (active_texture_unit < MAX_TEXTURE_UNITS) {
        if (target == GL_TEXTURE_2D) bound_tex_2d[active_texture_unit] = id;
        else if (target == GL_TEXTURE_2D_ARRAY) bound_tex_2d_array[active_texture_unit] = id;
    }
    // Also track per-target for tex_image/tex_sub calls
    if (target == GL_TEXTURE_2D) currently_bound_texture_2d = id;
    else if (target == GL_TEXTURE_2D_ARRAY) currently_bound_texture_2d_array = id;
}

static GLuint
get_bound_texture_for_target(GLenum target) {
    if (target == GL_TEXTURE_2D) return currently_bound_texture_2d;
    if (target == GL_TEXTURE_2D_ARRAY) return currently_bound_texture_2d_array;
    return currently_bound_texture_2d;
}

// Freed texture names are recycled like GL object names; a monotonic counter
// would exhaust the table in long image-heavy sessions (icat/file-manager
// previews) after which new images silently stop rendering.
static GLuint free_texture_ids[MAX_TEXTURES];
static size_t num_free_texture_ids = 0;

static void
recycle_texture_id(GLuint id) {
    [textures[id].texture release];
    textures[id].texture = nil;
    textures[id].target = 0;
    // H1: the object this watermark referred to is gone, so the stamp is
    // meaningless. metal_gl_gen_textures memsets the slot when the id is handed
    // out again, which made this redundant -- but only incidentally, and a
    // recycled id inheriting a stale high watermark would make the guard wait
    // on a frame that never bound the new texture. Clear it at the source.
    textures[id].last_drawn_fidx = 0;
    if (num_free_texture_ids < MAX_TEXTURES) free_texture_ids[num_free_texture_ids++] = id;
}

void metal_gl_gen_textures(int n, GLuint *ids) {
    for (int i = 0; i < n; i++) {
        if (num_free_texture_ids > 0) {
            ids[i] = free_texture_ids[--num_free_texture_ids];
            memset(&textures[ids[i]], 0, sizeof(MetalTexture));
        } else if (texture_id_counter < MAX_TEXTURES) {
            ids[i] = texture_id_counter++;
            memset(&textures[ids[i]], 0, sizeof(MetalTexture));
        } else {
            ids[i] = 0;
        }
    }
}


static MTLPixelFormat
pixel_format_for_gl(int internalformat) {
    switch (internalformat) {
        case GL_SRGB_ALPHA: case GL_SRGB8_ALPHA8: return MTLPixelFormatRGBA8Unorm_sRGB;
        // GL_RGBA16 is unsigned-normalized in GL; RGBA16Float would change
        // blending/rounding semantics of the layers FBO (issue #8953 path).
        case GL_RGBA16: return MTLPixelFormatRGBA16Unorm;
        // W27 P4.2: f=3232 graphics images. Sampling RGBA32Float with the
        // nearest/linear samplers the graphics fragment uses is supported on
        // Apple silicon (filterable float32 textures).
        case GL_RGBA32F: return MTLPixelFormatRGBA32Float;
        case GL_RGBA: return MTLPixelFormatRGBA8Unorm;
        case GL_RED: case GL_R8: return MTLPixelFormatR8Unorm;
        case GL_R32UI: return MTLPixelFormatR32Uint;
        case GL_RGB32UI: return MTLPixelFormatRGBA32Uint; // Metal doesn't have RGB32UI
        default: return MTLPixelFormatRGBA8Unorm;
    }
}

// Destination bytes-per-pixel for a Metal texture, so uploads size bytesPerRow
// from the actual texture format rather than a hardcoded 4 (G5/H2 fix).
static NSUInteger
mtl_bytes_per_pixel(MTLPixelFormat f) {
    switch (f) {
        case MTLPixelFormatR8Unorm: return 1;
        case MTLPixelFormatRGBA8Unorm: case MTLPixelFormatRGBA8Unorm_sRGB: case MTLPixelFormatR32Uint: return 4;
        case MTLPixelFormatRGBA16Unorm: return 8;
        case MTLPixelFormatRGBA32Uint: case MTLPixelFormatRGBA32Float: return 16;
        default: return 4;
    }
}

// Expand a tightly-packed GL_RGB (3 bpp) source into a freshly malloc'd RGBA
// (4 bpp) buffer with opaque alpha, matching GL's implicit alpha=1 expansion.
// Caller frees; returns NULL on alloc failure. Metal has no 3x8-bit format, so
// opaque graphics images (send_image_to_gpu, kitty/shaders.c GL_RGB path) must
// be widened before replaceRegion — reading 4-wide rows from a 3-wide buffer
// over-reads the heap and shears the image.
static uint32_t*
expand_rgb_to_rgba(const void *src_rgb, int width, int height) {
    size_t n = (size_t)width * (size_t)height;
    uint32_t *rgba = malloc(n * 4);
    if (!rgba) return NULL;
    const uint8_t *s = src_rgb;
    for (size_t i = 0; i < n; i++)
        rgba[i] = (uint32_t)s[i*3] | ((uint32_t)s[i*3+1] << 8) | ((uint32_t)s[i*3+2] << 16) | 0xFF000000u;
    return rgba;
}

void metal_gl_tex_image_2d(GLenum target, int level, int internalformat, int width, int height, int border, GLenum format, GLenum type, const void *data) {
    (void)level; (void)border;
    GLuint tex_id = get_bound_texture_for_target(target);
    if (tex_id == 0 || tex_id >= MAX_TEXTURES) return;
    MetalTexture *t = &textures[tex_id];

    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pixel_format_for_gl(internalformat)
                                                                                    width:width
                                                                                   height:height
                                                                                mipmapped:NO];
    desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
    desc.storageMode = MTLStorageModeShared;

    [t->texture release];
    t->texture = [mtl_device newTextureWithDescriptor:desc];
    t->last_drawn_fidx = 0;  // US-307: a freshly (re)allocated texture has no in-flight draws
    // G1: count only IMAGE-texture (re)allocs (the graphics/animation upload path
    // uses GL_SRGB_ALPHA). This excludes render-target textures such as the
    // thumbnail-capture scratch (setup_texture_as_render_target, GL_RGBA16), so
    // tex_allocs= isolates exactly the per-frame image realloc G1 removes: it is
    // 1/frame per animation advance before G1, 0 after (replaceRegion reuse).
    if (internalformat == GL_SRGB_ALPHA) metal_frame_tex_alloc_count++;
    t->target = GL_TEXTURE_2D;
    t->width = width;
    t->height = height;
    t->depth = 1;

    if (data) {
        NSUInteger dst_bpp = mtl_bytes_per_pixel(t->texture.pixelFormat);
        if (format == GL_RGB && type == GL_UNSIGNED_BYTE && dst_bpp == 4) {
            uint32_t *rgba = expand_rgb_to_rgba(data, width, height);
            if (!rgba) { log_error("Metal: RGB->RGBA expand alloc failed (%dx%d); skipping image upload", width, height); }
            else {
                [t->texture replaceRegion:MTLRegionMake2D(0, 0, width, height)
                              mipmapLevel:0 withBytes:rgba bytesPerRow:width * 4];
                free(rgba);
            }
        } else {
            [t->texture replaceRegion:MTLRegionMake2D(0, 0, width, height)
                          mipmapLevel:0 withBytes:data bytesPerRow:width * dst_bpp];
        }
    }
}

void metal_gl_tex_sub_image_2d(GLenum target, int level, int x, int y, int width, int height, GLenum format, GLenum type, const void *data) {
    (void)level;
    GLuint tex_id = get_bound_texture_for_target(target);
    MetalTexture *t = get_texture(tex_id);
    if (!t || !t->texture || !data) return;

    // H1: the decorations maps reach the GPU through this 2D path (the atlases
    // use the 3D array path below), so guarding only the 3D write would leave
    // two of the four sprite-side textures uncovered.
    guard_sprite_upload(tex_id);

    NSUInteger dst_bpp = mtl_bytes_per_pixel(t->texture.pixelFormat);
    // G3-lite: account image-texture upload bytes (RGB/RGBA source). A full-image
    // SubImage covers width*height==image; a delta upload covers only its rect.
    if (format == GL_RGB || format == GL_RGBA) metal_frame_tex_upload_bytes += (uint64_t)width * (uint64_t)height * dst_bpp;
    if (format == GL_RGB && type == GL_UNSIGNED_BYTE && dst_bpp == 4) {
        // Opaque graphics-image update: widen 3 bpp RGB to the RGBA8 texture.
        uint32_t *rgba = expand_rgb_to_rgba(data, width, height);
        if (!rgba) { log_error("Metal: RGB->RGBA expand alloc failed (%dx%d); skipping image update", width, height); return; }
        [t->texture replaceRegion:MTLRegionMake2D(x, y, width, height)
                      mipmapLevel:0 withBytes:rgba bytesPerRow:width * 4];
        free(rgba);
    } else {
        [t->texture replaceRegion:MTLRegionMake2D(x, y, width, height)
                      mipmapLevel:0 withBytes:data bytesPerRow:width * dst_bpp];
    }
}

static int tex_sub_3d_log_count = 0;

// F2/M6: a resident, grow-only scratch buffer for the GL_UNSIGNED_INT_8_8_8_8
// glyph byte-swap. Reused across uploads to eliminate the per-glyph
// malloc/free churn; capacity is bounded by the largest glyph tile uploaded.
static uint32_t *glyph_swap_scratch = NULL;
static size_t glyph_swap_scratch_px = 0;

void metal_gl_tex_sub_image_3d(GLenum target, int level, int x, int y, int z, int width, int height, int depth, GLenum format, GLenum type, const void *data) {
    (void)level; (void)format; (void)depth;
    GLuint tex_id = get_bound_texture_for_target(target);
    MetalTexture *t = get_texture(tex_id);
    if (!t || !t->texture || !data) return;

    // H1: the glyph atlases are written here. Wait, bounded, for any committed
    // frame still sampling this atlas before overwriting a region of it.
    guard_sprite_upload(tex_id);

    // F1: size bytesPerRow from the actual destination format. The mono atlas is
    // now single-channel R8 (GL_RED/GL_UNSIGNED_BYTE upload, bpp 1), while the
    // RGBA atlases stay 4 bpp. The byte-swap below only applies to the packed
    // GL_UNSIGNED_INT_8_8_8_8 RGBA uploads.
    NSUInteger bpp = mtl_bytes_per_pixel(t->texture.pixelFormat);
    // GL_UNSIGNED_INT_8_8_8_8 is a packed type: the R,G,B,A components live in
    // the uint32 from its most significant byte down, which on little-endian is
    // the reverse of the byte-ordered RGBA that Metal's replaceRegion expects.
    // Byte-swap each pixel through the resident scratch buffer (no per-glyph
    // malloc). replaceRegion on Shared storage copies synchronously, so the
    // scratch is free to be reused by the next upload immediately after.
    if (type == GL_UNSIGNED_INT_8_8_8_8) {
        size_t n = (size_t)width * (size_t)height;
        if (n > glyph_swap_scratch_px) {
            uint32_t *grown = realloc(glyph_swap_scratch, n * sizeof(uint32_t));
            if (!grown) {
                // HAZARD FIX: never fall through to upload the un-swapped bytes
                // (reversed channels → visibly corrupt glyphs). Fail loudly and
                // skip this upload; the atlas slot keeps its prior contents.
                log_error("Metal: glyph byte-swap scratch alloc failed (%zu px); skipping atlas upload", n);
                return;
            }
            glyph_swap_scratch = grown;
            glyph_swap_scratch_px = n;
        }
        const uint32_t *src = data;
        for (size_t i = 0; i < n; i++) glyph_swap_scratch[i] = __builtin_bswap32(src[i]);
        data = glyph_swap_scratch;
    }
    [t->texture replaceRegion:MTLRegionMake2D(x, y, width, height)
                  mipmapLevel:0
                        slice:z
                    withBytes:data
                  bytesPerRow:width * bpp
                bytesPerImage:0];
    if (tex_sub_3d_log_count < 5) {
        METAL_TRACE("tex_sub_3d: id=%u pos=(%d,%d,%d) size=%dx%d\n", tex_id, x, y, z, width, height);
        tex_sub_3d_log_count++;
    }
}

void metal_gl_tex_storage_3d(GLenum target, int levels, GLenum internalformat, int width, int height, int depth) {
    (void)levels;
    GLuint tex_id = get_bound_texture_for_target(target);
    if (tex_id == 0 || tex_id >= MAX_TEXTURES) return;
    MetalTexture *t = &textures[tex_id];

    MTLTextureDescriptor *desc = [[MTLTextureDescriptor alloc] init];
    desc.textureType = MTLTextureType2DArray;
    desc.pixelFormat = pixel_format_for_gl(internalformat);
    // F1: the mono R8 atlas stores coverage in the single red channel; swizzle so
    // a sampler reads coverage in .a (RGB<-1), matching the GL_TEXTURE_SWIZZLE_*
    // set on the GL backend and the .a-only sampling the cell fragment does for
    // mono glyphs. (glTexParameteri is a no-op on Metal, hence the swizzle here.)
    if (desc.pixelFormat == MTLPixelFormatR8Unorm) {
        desc.swizzle = MTLTextureSwizzleChannelsMake(
            MTLTextureSwizzleOne, MTLTextureSwizzleOne, MTLTextureSwizzleOne, MTLTextureSwizzleRed);
    }
    desc.width = width;
    desc.height = height;
    desc.arrayLength = depth;
    desc.mipmapLevelCount = 1;
    desc.usage = MTLTextureUsageShaderRead;
    desc.storageMode = MTLStorageModeShared;

    [t->texture release];
    t->texture = [mtl_device newTextureWithDescriptor:desc];
    t->target = GL_TEXTURE_2D_ARRAY;
    // H1: this is an in-place release+recreate, so the watermark now refers to a
    // texture object that no longer exists. The 2D sibling
    // (metal_gl_tex_image_2d) has always reset it here; the 3D path omitted it,
    // and the omission was survivable only because every caller happens to route
    // through metal_gl_gen_textures first. A stale high watermark would make the
    // guard wait for a frame that never bound this object.
    t->last_drawn_fidx = 0;
    t->width = width;
    t->height = height;
    t->depth = depth;
    METAL_TRACE("tex_storage_3d: id=%u %dx%dx%d fmt=%u\n", tex_id, width, height, depth, (unsigned)internalformat);
}

void metal_gl_get_tex_level_parameteriv(GLenum target, int level, GLenum pname, GLint *params) {
    (void)level;
    GLuint tex_id = get_bound_texture_for_target(target);
    MetalTexture *t = get_texture(tex_id);
    if (!t || !t->texture) { *params = 0; return; }
    switch (pname) {
        case GL_TEXTURE_WIDTH: *params = (GLint)t->texture.width; break;
        case GL_TEXTURE_HEIGHT: *params = (GLint)t->texture.height; break;
        case GL_TEXTURE_DEPTH: *params = (GLint)t->depth; break;
        case GL_TEXTURE_INTERNAL_FORMAT: *params = GL_RGBA; break;
        default: *params = 0; break;
    }
}

void metal_gl_get_tex_image(GLenum target, int level, GLenum format, GLenum type, void *pixels) {
    (void)level; (void)format; (void)type;
    GLuint tex_id = get_bound_texture_for_target(target);
    MetalTexture *t = get_texture(tex_id);
    if (!t || !t->texture || !pixels) return;

    NSUInteger bpp = 4;
    [t->texture getBytes:pixels
             bytesPerRow:t->texture.width * bpp
              fromRegion:MTLRegionMake2D(0, 0, t->texture.width, t->texture.height)
             mipmapLevel:0];
}

void metal_gl_copy_tex_image_2d(GLenum target, int level, GLenum internalformat, int x, int y, int width, int height, int border) {
    (void)level; (void)internalformat; (void)border;
    // Copy from current render target to texture via blit encoder
    GLuint tex_id = get_bound_texture_for_target(target);
    MetalTexture *t = get_texture(tex_id);
    if (!t) return;

    // Create or recreate the texture
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                    width:width
                                                                                   height:height
                                                                                mipmapped:NO];
    desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
    desc.storageMode = MTLStorageModeShared;
    [t->texture release];
    t->texture = [mtl_device newTextureWithDescriptor:desc];
    t->target = GL_TEXTURE_2D;
    t->width = width;
    t->height = height;
    t->depth = 1;

    // Copy from current drawable/render target to the new texture
    id<MTLTexture> source = nil;
    if (bound_framebuffer && bound_framebuffer < MAX_FRAMEBUFFERS && framebuffers[bound_framebuffer].render_target) {
        source = framebuffers[bound_framebuffer].render_target;
    } else if (metal_capture_to_offscreen() && dump_offscreen_base) {
        source = dump_offscreen_base;  // C4a: framebufferOnly drawable is unreadable; the frame rendered here
    } else if (mtl_current_drawable) {
        source = current_drawable_texture();
    }
    if (source && t->texture) {
        // Must end current encoder before using blit encoder
        end_current_encoder();
        if (!ensure_command_buffer()) return;
        id<MTLBlitCommandEncoder> blit = [mtl_current_command_buffer blitCommandEncoder];
        [blit copyFromTexture:source
                  sourceSlice:0 sourceLevel:0
                 sourceOrigin:MTLOriginMake(x, y, 0)
                   sourceSize:MTLSizeMake(width, height, 1)
                    toTexture:t->texture
             destinationSlice:0 destinationLevel:0
            destinationOrigin:MTLOriginMake(0, 0, 0)];
        [blit endEncoding];
    }
}

void metal_gl_copy_image_sub_data(GLuint src, GLenum srcTarget, int srcLevel, int srcX, int srcY, int srcZ,
                                   GLuint dst, GLenum dstTarget, int dstLevel, int dstX, int dstY, int dstZ,
                                   int width, int height, int depth) {
    (void)srcTarget; (void)srcLevel; (void)dstTarget; (void)dstLevel;
    MetalTexture *src_tex = get_texture(src);
    MetalTexture *dst_tex = get_texture(dst);
    if (!src_tex || !src_tex->texture || !dst_tex || !dst_tex->texture) return;

    id<MTLCommandBuffer> cmd = [mtl_command_queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];

    for (int z = 0; z < depth; z++) {
        [blit copyFromTexture:src_tex->texture
                  sourceSlice:srcZ + z
                  sourceLevel:0
                 sourceOrigin:MTLOriginMake(srcX, srcY, 0)
                   sourceSize:MTLSizeMake(width, height, 1)
                    toTexture:dst_tex->texture
             destinationSlice:dstZ + z
             destinationLevel:0
            destinationOrigin:MTLOriginMake(dstX, dstY, 0)];
    }

    [blit endEncoding];
    // F3: commit without stalling. This is the atlas-growth copy (old atlas ->
    // grown atlas), issued during cell prep before the frame's render command
    // buffer is committed in metal_end_frame. A single MTLCommandQueue runs its
    // command buffers in commit order without overlap, so this blit completes
    // before any later-committed frame samples the grown atlas. The new glyph
    // written afterwards (tex_sub_image_3d -> replaceRegion on Shared storage)
    // is a CPU-synchronous write to a disjoint region, immediately GPU-visible
    // via unified memory — so no waitUntilCompleted is needed here.
    [cmd commit];
}

void metal_gl_gen_framebuffers(int n, GLuint *ids) {
    for (int i = 0; i < n; i++) {
        ids[i] = 0;
        // Recycle released slots first (in_use false, id previously handed
        // out); the monotonic counter alone exhausts the table over a long
        // session of layers-FBO regeneration.
        for (GLuint id = 1; id < framebuffer_id_counter; id++) {
            if (!framebuffers[id].in_use) { ids[i] = id; break; }
        }
        if (!ids[i] && framebuffer_id_counter < MAX_FRAMEBUFFERS) ids[i] = framebuffer_id_counter++;
        if (ids[i]) {
            framebuffers[ids[i]].in_use = true;
            framebuffers[ids[i]].attached_texture_id = 0;
            framebuffers[ids[i]].render_target = nil;
        }
    }
}



void metal_gl_framebuffer_texture_2d(GLenum target, GLenum attachment, GLenum textarget, GLuint texture, int level) {
    (void)target; (void)attachment; (void)textarget; (void)level;
    if (bound_framebuffer && bound_framebuffer < MAX_FRAMEBUFFERS) {
        framebuffers[bound_framebuffer].attached_texture_id = texture;
        MetalTexture *t = get_texture(texture);
        // The framebuffer holds its own reference: the attached texture can
        // be deleted (and its slot reused) while the framebuffer lives.
        [framebuffers[bound_framebuffer].render_target release];
        framebuffers[bound_framebuffer].render_target = t ? [t->texture retain] : nil;
    }
}


void metal_gl_read_pixels(int x, int y, int width, int height, GLenum format, GLenum type, void *data) {
    (void)format; (void)type;
    // Must end encoding before reading back
    end_current_encoder();

    id<MTLTexture> source = nil;
    if (bound_framebuffer && bound_framebuffer < MAX_FRAMEBUFFERS && framebuffers[bound_framebuffer].render_target) {
        source = framebuffers[bound_framebuffer].render_target;
    } else if (metal_capture_to_offscreen() && dump_offscreen_base) {
        source = dump_offscreen_base;  // C4a: framebufferOnly drawable is unreadable; the frame rendered here
    } else if (mtl_current_drawable) {
        source = current_drawable_texture();
    }
    if (source && data) {
        // Ensure GPU work is complete before reading
        if (mtl_current_command_buffer) {
            [mtl_current_command_buffer commit];
            [mtl_current_command_buffer waitUntilCompleted];
            mtl_current_command_buffer = nil;
        }
        [source getBytes:data
             bytesPerRow:width * 4
              fromRegion:MTLRegionMake2D(x, y, width, height)
             mipmapLevel:0];
        // Start a new command buffer for any subsequent work
        ensure_command_buffer();
    }
}

// ----- Uniform value store -----
// Plain glUniform* values are captured here and marshalled into each
// program uniform struct at draw time (resolved by name in draw_quad).

void metal_gl_uniform1i(GLint loc, int v) {
    if (current_program >= 0 && loc >= 0 && loc < MAX_UNIFORMS_PER_PROGRAM) {
        uniform_stores[current_program].values[loc].i[0] = v;
    }
}
void metal_gl_uniform1f(GLint loc, float v) {
    if (current_program >= 0 && loc >= 0 && loc < MAX_UNIFORMS_PER_PROGRAM) {
        uniform_stores[current_program].values[loc].f[0] = v;
    }
}
void metal_gl_uniform2f(GLint loc, float x, float y) {
    if (current_program >= 0 && loc >= 0 && loc < MAX_UNIFORMS_PER_PROGRAM) {
        uniform_stores[current_program].values[loc].f[0] = x;
        uniform_stores[current_program].values[loc].f[1] = y;
    }
}
void metal_gl_uniform3f(GLint loc, float x, float y, float z) {
    if (current_program >= 0 && loc >= 0 && loc < MAX_UNIFORMS_PER_PROGRAM) {
        uniform_stores[current_program].values[loc].f[0] = x;
        uniform_stores[current_program].values[loc].f[1] = y;
        uniform_stores[current_program].values[loc].f[2] = z;
    }
}
void metal_gl_uniform4f(GLint loc, float x, float y, float z, float w) {
    if (current_program >= 0 && loc >= 0 && loc < MAX_UNIFORMS_PER_PROGRAM) {
        uniform_stores[current_program].values[loc].f[0] = x;
        uniform_stores[current_program].values[loc].f[1] = y;
        uniform_stores[current_program].values[loc].f[2] = z;
        uniform_stores[current_program].values[loc].f[3] = w;
    }
}
void metal_gl_uniform1ui(GLint loc, unsigned v) {
    if (current_program >= 0 && loc >= 0 && loc < MAX_UNIFORMS_PER_PROGRAM) {
        uniform_stores[current_program].values[loc].u[0] = v;
    }
}
void metal_gl_uniform1fv(GLint loc, int count, const float *v) {
    if (current_program >= 0 && loc >= 0) {
        if (count >= 256) {
            // This is the gamma_lut — cache it for shader binding
            cached_gamma_lut = v;
            cached_gamma_lut_count = count;
        }
        // Also store first few values in the uniform store
        if (loc < MAX_UNIFORMS_PER_PROGRAM) {
            uniform_stores[current_program].values[loc].f[0] = v[0];
        }
    }
}
// Array uniforms stored at ARRAY_UNIFORM_BASE to avoid overwriting scalar slots
void metal_gl_uniform1uiv(GLint loc, int count, const unsigned *v) {
    if (current_program >= 0 && loc >= 0) {
        if (count > 1) {
            // Store array data at ARRAY_UNIFORM_BASE + loc*16 to avoid collision with scalars
            int base = ARRAY_UNIFORM_BASE + loc * 16;
            for (int i = 0; i < count && (base + i) < MAX_UNIFORMS_PER_PROGRAM; i++) {
                uniform_stores[current_program].values[base + i].u[0] = v[i];
            }
        } else if (loc < MAX_UNIFORMS_PER_PROGRAM) {
            uniform_stores[current_program].values[loc].u[0] = v[0];
        }
    }
}
void metal_gl_uniform2fv(GLint loc, int count, const float *v) {
    if (current_program >= 0 && loc >= 0 && loc < MAX_UNIFORMS_PER_PROGRAM) {
        for (int i = 0; i < count * 2 && i < 4; i++) {
            uniform_stores[current_program].values[loc].f[i] = v[i];
        }
    }
}
void metal_gl_uniform4fv(GLint loc, int count, const float *v) {
    if (current_program < 0 || loc < 0) return;
    if (count > 1) {
        // G2: vec4 array. Store each element's 4 floats in one slot at
        // ARRAY_UNIFORM_BASE + loc*16 (the same 16-element stride used by
        // metal_gl_uniform1uiv), so it never collides with the scalar slots.
        int base = ARRAY_UNIFORM_BASE + loc * 16;
        for (int i = 0; i < count && (base + i) < MAX_UNIFORMS_PER_PROGRAM; i++) {
            for (int c = 0; c < 4; c++) uniform_stores[current_program].values[base + i].f[c] = v[i * 4 + c];
        }
    } else if (loc < MAX_UNIFORMS_PER_PROGRAM) {
        for (int i = 0; i < 4; i++) uniform_stores[current_program].values[loc].f[i] = v[i];
    }
}

// ----- Draw -----



// ----- Shader/Program Stubs -----



GLuint metal_gl_create_program(void) {
    static GLuint next_id = 1;
    return next_id++;
}

void metal_gl_get_programiv(GLuint prog, GLenum pname, GLint *params) {
    (void)prog;
    if (pname == GL_LINK_STATUS) *params = GL_TRUE;
    else if (pname == 0x8B86 /* GL_ACTIVE_UNIFORMS */) *params = 0;
    else *params = 0;
}

void metal_gl_delete_program(GLuint prog) { (void)prog; }

// ----- VAO/Buffer GL stubs -----









void* metal_gl_map_buffer_range(GLenum target, int offset, unsigned length, unsigned access) {
    (void)target; (void)offset; (void)length; (void)access;
    return NULL;
}


