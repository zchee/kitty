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
#import <IOSurface/IOSurface.h>
#import <os/signpost.h>

// Undefine system MAX/MIN before data-types.h redefines them
#undef MAX
#undef MIN

#include "metal.h"
#include "state.h"
#include "png-reader.h"

#include <string.h>
#include <stddef.h>
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

// Metal global state
static id<MTLDevice> mtl_device = nil;
static id<MTLCommandQueue> mtl_command_queue = nil;
static id<MTLLibrary> mtl_default_library = nil;

// Per-frame state
static id<MTLCommandBuffer> mtl_current_command_buffer = nil;
static id<MTLRenderCommandEncoder> mtl_current_encoder = nil;
static id<CAMetalDrawable> mtl_current_drawable = nil;
static MTLRenderPassDescriptor *mtl_current_render_pass = nil;
static CAMetalLayer *mtl_current_layer = nil;
// Phase 4 (L1): the drawable delivered by the CAMetalDisplayLink for this frame,
// set via metal_set_link_drawable() before the link-driven render and cleared
// after. Unretained: it is owned by the CAMetalDisplayLinkUpdate for the duration
// of the delegate callback, and by the committed command buffer once presented.
static id<CAMetalDrawable> mtl_link_drawable = nil;
// Pace attribution (legacy drawable path): distinguishes a
// CAMetalDisplayLink-driven frame (pace=link) from anything else. The
// immediate-encode floor is per-OSWindow now (last_gpu_present_at,
// kitty/child-monitor.c), so no global present timestamp is kept.
static bool metal_frame_used_link_drawable = false;
// Phase-4 step 7 spike (KITTY_METAL_IOSURFACE=1): IOSurface presentation model.
// The frame renders into an IOSurface-backed texture from a per-window ring
// instead of a CAMetalLayer drawable, and presents by assigning the surface to
// layer.contents once the GPU completes — no drawable pool, no nextDrawable
// (pacing comes from a plain CADisplayLink). These hold the CURRENT window's in-flight target
// (register-file pattern; saved/loaded with the window slot). Both are
// borrowed from the ring — never retained/released here.
static id<MTLTexture> mtl_iosurface_target = nil;
static IOSurfaceRef mtl_iosurface_surface = NULL;
// Governor attribution: set (via metal_set_frame_link_driven) around the render
// invoked from the CADisplayLink pace-tick callback, so metal_end_frame can tag
// link-paced frames pace=iosurface vs input-immediate frames pace=immediate.
static bool metal_frame_link_driven = false;

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
#define LAYERED_WORK_FMT MTLPixelFormatRGBA16Unorm      // att0: memoryless working surface
#define LAYERED_DRAWABLE_FMT MTLPixelFormatBGRA8Unorm   // att1: drawable / dump target
static bool layered_pass_active = false;                // inside a layered pass? (per window: saved with the slot)
static id<MTLTexture> layered_work_surface = nil;       // memoryless att0, grown to the drawable size
static NSUInteger layered_work_w = 0, layered_work_h = 0;
static id<MTLRenderPipelineState> layers_resolve_pso = nil;  // built once

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
#define PSO_VARIANTS_PER_PROGRAM 8
typedef struct {
    id<MTLRenderPipelineState> pso;
    MTLPixelFormat fmt;
    bool blend, layered, in_use;  // layered: M1 two-attachment (att0 work + att1 drawable) variant
} PSOCacheEntry;
static PSOCacheEntry pso_cache[NUM_PROGRAMS * PSO_VARIANTS_PER_PROGRAM];
static id<MTLRenderPipelineState> build_pso(int program, bool blend, MTLPixelFormat fmt, bool layered);
static id<MTLRenderPipelineState> ensure_layers_resolve_pso(void);  // M1: att0->att1 resolve PSO

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

static id<MTLRenderPipelineState>
pso_get(int program, bool blend, MTLPixelFormat fmt, bool layered) {
    if (program < 0 || program >= NUM_PROGRAMS) return nil;
    size_t base = (size_t)program * PSO_VARIANTS_PER_PROGRAM;
    size_t free_slot = SIZE_MAX;
    for (size_t i = base; i < base + PSO_VARIANTS_PER_PROGRAM; i++) {
        if (pso_cache[i].in_use) {
            if (pso_cache[i].blend == blend && pso_cache[i].fmt == fmt && pso_cache[i].layered == layered) return pso_cache[i].pso;
        } else if (free_slot == SIZE_MAX) free_slot = i;
    }
    if (free_slot == SIZE_MAX) {
        log_error("Metal: pipeline state cache overflow for program %d", program);
        return nil;
    }
    id<MTLRenderPipelineState> pso = build_pso(program, blend, fmt, layered);
    if (!pso) return nil;
    pso_cache[free_slot] = (PSOCacheEntry){.pso = pso, .fmt = fmt, .blend = blend, .layered = layered, .in_use = true};
    return pso;
}

// Pipeline state creation helper
static id<MTLRenderPipelineState>
create_pipeline_state(NSString *vertex_fn, NSString *fragment_fn, bool enable_blend,
                      MTLVertexDescriptor *vertex_desc, MTLPixelFormat pixel_format,
                      bool layered, MTLFunctionConstantValues *constants) {
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
        // (it still writes att0 = the RGBA16Unorm working surface).
        desc.colorAttachments[1].pixelFormat = LAYERED_DRAWABLE_FMT;
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
// Program indices follow the enum in kitty/shaders.c: CELL=0, CELL_FG=1,
// CELL_BG=2, (sentinel)=3, BORDERS=4, GRAPHICS=5, GRAPHICS_PREMULT=6,
// GRAPHICS_ALPHA_MASK=7, BGIMAGE=8, TINT=9, TRAIL=10, BLIT=11,
// SCREENSHOT=12, ROUNDED_RECT=13.
static id<MTLRenderPipelineState>
build_pso(int program, bool blend, MTLPixelFormat fmt, bool layered) {
    if (!mtl_default_library) return nil;
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
            bool cell_srgb_encode = !layered; // C1: opaque path (drawable) encodes sRGB in-shader
            [fc setConstantValue:&cell_srgb_encode type:MTLDataTypeBool atIndex:6]; // SRGB_ENCODE_OUTPUT
            return create_pipeline_state(@"cell_vertex", @"cell_fragment", blend, cell_vertex_descriptor(), fmt, layered, fc);
        }
        case 4: {
            MTLFunctionConstantValues *fc = [[MTLFunctionConstantValues alloc] init];
            bool border_srgb_encode = !layered; // C1: opaque borders encode sRGB in-shader
            [fc setConstantValue:&border_srgb_encode type:MTLDataTypeBool atIndex:0]; // SRGB_ENCODE_OUTPUT
            return create_pipeline_state(@"border_vertex", @"border_fragment", blend, nil, fmt, layered, fc);
        }
        case 5: case 6: case 7: {
            MTLFunctionConstantValues *fc = [[MTLFunctionConstantValues alloc] init];
            bool is_alpha_mask = (program == 7);
            bool is_premult = (program == 6);
            [fc setConstantValue:&is_alpha_mask type:MTLDataTypeBool atIndex:0];
            [fc setConstantValue:&is_premult type:MTLDataTypeBool atIndex:1];
            return create_pipeline_state(@"graphics_vertex", @"graphics_fragment", blend, nil, fmt, layered, fc);
        }
        case 8: return create_pipeline_state(@"bgimage_vertex", @"bgimage_fragment", blend, nil, fmt, layered, nil);
        case 9: return create_pipeline_state(@"tint_vertex", @"tint_fragment", blend, nil, fmt, layered, nil);
        case 10: return create_pipeline_state(@"trail_vertex", @"trail_fragment", blend, nil, fmt, layered, nil);
        case 11: return create_pipeline_state(@"blit_vertex", @"blit_fragment", blend, nil, fmt, layered, nil);
        case 12: return create_pipeline_state(@"screenshot_vertex", @"screenshot_fragment", blend, nil, fmt, layered, nil);
        case 13: return create_pipeline_state(@"rounded_rect_vertex", @"rounded_rect_fragment", blend, nil, fmt, layered, nil);
        default: return nil; // 3 == CELL_PROGRAM_SENTINEL, never drawn
    }
}

// Pre-warm the drawable-format pipeline states so MSL/PSO errors surface at
// startup instead of mid-frame; FBO-format variants build lazily via pso_get.
static void
create_all_pipeline_states(void) {
    if (!mtl_default_library) return;
    int count = 0;
    // C1: the drawable is now a single format — plain BGRA8Unorm. sRGB is encoded
    // in-shader (opaque cells/borders) or in the resolve (layered), so the
    // BGRA8Unorm_sRGB drawable-view variant is gone.
    for (int p = 0; p < NUM_PROGRAMS; p++) {
        if (p == 3) continue; // CELL_PROGRAM_SENTINEL
        if (pso_get(p, false, MTLPixelFormatBGRA8Unorm, false)) count++;
        if (pso_get(p, true, MTLPixelFormatBGRA8Unorm, false)) count++;
    }
    // M1: pre-warm the layered two-attachment variants (att0 = RGBA16Unorm working
    // surface + att1 = drawable) for the programs that draw in the layered pass, so
    // MSL/PSO errors surface at startup and the first layered frame does not hitch.
    // BLIT (11, replaced by the native resolve) and SCREENSHOT (12) are never layered.
    for (int p = 0; p < NUM_PROGRAMS; p++) {
        if (p == 3 || p == 11 || p == 12) continue;
        if (pso_get(p, false, LAYERED_WORK_FMT, true)) count++;
        if (pso_get(p, true, LAYERED_WORK_FMT, true)) count++;
    }
    if (ensure_layers_resolve_pso()) count++;
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

// Find an existing uniform slot by name without creating one. Slots are
// assigned by get_uniform_location in whatever order the generated
// uniforms_generated.h code calls it; resolving by name at draw time keeps
// the shim independent of that order.
static GLint
find_uniform_slot(int program, const char *name) {
    if (program < 0 || program >= 64) return -1;
    Program *p = programs + program;
    for (GLint i = 0; i < p->num_of_uniforms; i++) {
        if (strcmp(p->uniforms[i].name, name) == 0) return p->uniforms[i].location;
    }
    return -1;
}

static float
uval_f(const char *name, int comp) {
    GLint s = find_uniform_slot(current_program, name);
    return s >= 0 ? uniform_stores[current_program].values[s].f[comp] : 0.f;
}

static uint32_t
uval_u(const char *name, int comp) {
    GLint s = find_uniform_slot(current_program, name);
    return s >= 0 ? uniform_stores[current_program].values[s].u[comp] : 0u;
}

static void
uval_fv(const char *name, float *dest, int n) {
    GLint s = find_uniform_slot(current_program, name);
    for (int i = 0; i < n; i++) dest[i] = s >= 0 ? uniform_stores[current_program].values[s].f[i] : 0.f;
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

GLint
block_size(int program, GLuint bidx) {
    (void)program;
    if (bidx == 1) return (GLint)(METAL_COLOR_TABLE_ENTRIES * sizeof(uint32_t));
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
            pso_get(0, false, MTLPixelFormatBGRA8Unorm, false) ? NUM_PROGRAMS : 0);
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
    // Update the CAMetalLayer drawable size to match the viewport
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
static uint64_t metal_frame_index = 0;
static int metal_pass_count = 0;
static double metal_frame_encode_start = 0.0;
static double metal_frame_drawable_wait = 0.0;

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
                }
            }
        }
        // Per-draw uniforms (draw_bg_bitfield, row_offset, etc.) → buffer index 2
        MetalCellDrawUniforms cell_draw = {0};
        cell_draw.text_contrast = uval_f("text_contrast", 0);
        cell_draw.text_gamma_adjustment = uval_f("text_gamma_adjustment", 0);
        cell_draw.draw_bg_bitfield = uval_u("draw_bg_bitfield", 0);
        cell_draw.row_offset = uval_f("row_offset", 0);
        [mtl_current_encoder setVertexBytes:&cell_draw length:sizeof(cell_draw) atIndex:2];
        [mtl_current_encoder setFragmentBytes:&cell_draw length:sizeof(cell_draw) atIndex:2];

        // Bind textures: unit 0 = sprite atlas (2D array), unit 2 = decorations map
        if (bound_tex_2d_array[0] && bound_tex_2d_array[0] < MAX_TEXTURES && textures[bound_tex_2d_array[0]].texture) {
            [mtl_current_encoder setFragmentTexture:textures[bound_tex_2d_array[0]].texture atIndex:0];
            [mtl_current_encoder setVertexTexture:textures[bound_tex_2d_array[0]].texture atIndex:0];
        }
        if (bound_tex_2d[2] && bound_tex_2d[2] < MAX_TEXTURES && textures[bound_tex_2d[2]].texture) {
            [mtl_current_encoder setVertexTexture:textures[bound_tex_2d[2]].texture atIndex:2];
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
        // Multi-element uniform arrays (colors[9]) live at ARRAY_UNIFORM_BASE +
        // slot*16 (see metal_gl_uniform1uiv), keeping scalar slots intact.
        struct { uint32_t colors[9]; float background_opacity; float gamma_lut[256]; } border_u = {0}; // mirrors BorderUniforms: scalar arrays pack, no padding
        GLint colors_slot = find_uniform_slot(current_program, "colors");
        if (colors_slot >= 0) {
            int base = ARRAY_UNIFORM_BASE + colors_slot * 16;
            for (int i = 0; i < 9 && base + i < MAX_UNIFORMS_PER_PROGRAM; i++) {
                border_u.colors[i] = uniform_stores[current_program].values[base + i].u[0];
            }
        }
        border_u.background_opacity = uval_f("background_opacity", 0);
        if (cached_gamma_lut) memcpy(border_u.gamma_lut, cached_gamma_lut, sizeof(border_u.gamma_lut));
        [mtl_current_encoder setVertexBytes:&border_u length:sizeof(border_u) atIndex:1];
    } else if (current_program >= 5 && current_program <= 7) {
        // Mirrors GraphicsUniforms in graphics_shaders.metal: the float3
        // amask_fg is 16-byte aligned in MSL, so the CPU twin needs explicit
        // padding (MSL sizeof == 80, not the packed 64).
        struct { float src_rect[4]; float dest_rect[4]; float extra_alpha; float _pad0[3]; float amask_fg[3]; float _pad1; float amask_bg_premult[4]; } gfx_u = {0};
        uval_fv("src_rect", gfx_u.src_rect, 4);
        uval_fv("dest_rect", gfx_u.dest_rect, 4);
        gfx_u.extra_alpha = uval_f("extra_alpha", 0);
        uval_fv("amask_fg", gfx_u.amask_fg, 3);
        uval_fv("amask_bg_premult", gfx_u.amask_bg_premult, 4);
        [mtl_current_encoder setVertexBytes:&gfx_u length:sizeof(gfx_u) atIndex:0];
        [mtl_current_encoder setFragmentBytes:&gfx_u length:sizeof(gfx_u) atIndex:0];
        // Bind image texture from unit 1 (GRAPHICS_UNIT)
        if (bound_tex_2d[1] && bound_tex_2d[1] < MAX_TEXTURES && textures[bound_tex_2d[1]].texture) {
            [mtl_current_encoder setFragmentTexture:textures[bound_tex_2d[1]].texture atIndex:0];
        }
    } else if (current_program == 8) {
        struct { float sizes[4]; float positions[4]; float background[4]; float tiled; float pad[3]; } bg_u = {0};
        uval_fv("sizes", bg_u.sizes, 4);
        uval_fv("positions", bg_u.positions, 4);
        uval_fv("background", bg_u.background, 4);
        bg_u.tiled = uval_f("tiled", 0);
        [mtl_current_encoder setVertexBytes:&bg_u length:sizeof(bg_u) atIndex:0];
        [mtl_current_encoder setFragmentBytes:&bg_u length:sizeof(bg_u) atIndex:0];
        if (bound_tex_2d[1] && bound_tex_2d[1] < MAX_TEXTURES && textures[bound_tex_2d[1]].texture) {
            [mtl_current_encoder setFragmentTexture:textures[bound_tex_2d[1]].texture atIndex:0];
        }
    } else if (current_program == 9) {
        struct { float tint_color[4]; float edges[4]; } tint_u = {0};
        uval_fv("tint_color", tint_u.tint_color, 4);
        uval_fv("edges", tint_u.edges, 4);
        [mtl_current_encoder setVertexBytes:&tint_u length:sizeof(tint_u) atIndex:0];
        [mtl_current_encoder setFragmentBytes:&tint_u length:sizeof(tint_u) atIndex:0];
    } else if (current_program == 10) {
        // Mirrors TrailUniforms: MSL float3 occupies 16 bytes, so trail_color
        // pads to 64 and trail_opacity lands at offset 64 (sizeof == 80).
        struct { float x_coords[4]; float y_coords[4]; float cursor_edge_x[2]; float cursor_edge_y[2];
                 float trail_color[3]; float _pad0; float trail_opacity; float _pad1[3]; } trail_u = {0};
        uval_fv("x_coords", trail_u.x_coords, 4);
        uval_fv("y_coords", trail_u.y_coords, 4);
        uval_fv("cursor_edge_x", trail_u.cursor_edge_x, 2);
        uval_fv("cursor_edge_y", trail_u.cursor_edge_y, 2);
        uval_fv("trail_color", trail_u.trail_color, 3);
        trail_u.trail_opacity = uval_f("trail_opacity", 0);
        [mtl_current_encoder setVertexBytes:&trail_u length:sizeof(trail_u) atIndex:0];
        [mtl_current_encoder setFragmentBytes:&trail_u length:sizeof(trail_u) atIndex:0];
    } else if (current_program == 11) {
        struct { float src_rect[4]; float dest_rect[4]; } blit_u = {0};
        uval_fv("src_rect", blit_u.src_rect, 4);
        uval_fv("dest_rect", blit_u.dest_rect, 4);
        [mtl_current_encoder setVertexBytes:&blit_u length:sizeof(blit_u) atIndex:0];
        [mtl_current_encoder setFragmentBytes:&blit_u length:sizeof(blit_u) atIndex:0];
        if (bound_tex_2d[1] && bound_tex_2d[1] < MAX_TEXTURES && textures[bound_tex_2d[1]].texture) {
            [mtl_current_encoder setFragmentTexture:textures[bound_tex_2d[1]].texture atIndex:0];
        }
    } else if (current_program == 12) {
        struct { float src_rect[4]; float dest_rect[4]; float src_size[2]; float pad[2]; } ss_u = {0};
        uval_fv("src_rect", ss_u.src_rect, 4);
        uval_fv("dest_rect", ss_u.dest_rect, 4);
        uval_fv("src_size", ss_u.src_size, 2);
        [mtl_current_encoder setVertexBytes:&ss_u length:sizeof(ss_u) atIndex:0];
        [mtl_current_encoder setFragmentBytes:&ss_u length:sizeof(ss_u) atIndex:0];
        if (bound_tex_2d[1] && bound_tex_2d[1] < MAX_TEXTURES && textures[bound_tex_2d[1]].texture) {
            [mtl_current_encoder setFragmentTexture:textures[bound_tex_2d[1]].texture atIndex:0];
        }
    } else if (current_program == 13) {
        struct { float color[4]; float background_color[4]; float rect[4]; float params[2]; float pad[2]; } rr_u = {0};
        uval_fv("color", rr_u.color, 4);
        uval_fv("background_color", rr_u.background_color, 4);
        uval_fv("rect", rr_u.rect, 4);
        uval_fv("params", rr_u.params, 2);
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

static bool
parse_define_value(const char *source, const char *name, float *val) {
    const char *p = strstr(source, name);
    if (!p) return false;
    p += strlen(name);
    *val = strtof(p, NULL);
    return true;
}

static void invalidate_cell_pipeline_states(void);

GLuint
compile_shaders(GLenum shader_type, GLsizei count, const GLchar * const *source) {
    (void)shader_type;
    // The MSL equivalents live pre-compiled in the metallib; this call only
    // harvests the option defines Python substituted into the GLSL source.
    for (GLsizei i = 0; i < count; i++) {
        if (!source[i] || !strstr(source[i], "#define TEXT_NEW_GAMMA")) continue;
        float v;
        if (parse_define_value(source[i], "#define TEXT_NEW_GAMMA ", &v)) cell_shader_opts.text_new_gamma = v != 0.f;
        if (parse_define_value(source[i], "#define DO_FG_OVERRIDE ", &v)) cell_shader_opts.do_fg_override = v != 0.f;
        if (parse_define_value(source[i], "#define FG_OVERRIDE_ALGO ", &v)) cell_shader_opts.fg_override_algo = (int)v;
        if (parse_define_value(source[i], "#define FG_OVERRIDE_THRESHOLD ", &v)) cell_shader_opts.fg_override_threshold = v;
        invalidate_cell_pipeline_states();
        break;
    }
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
    id<MTLTexture> iosurface_target;  // spike: in-flight IOSurface render target (borrowed from the ring)
    IOSurfaceRef iosurface_surface;   // spike: its backing surface (borrowed)
} MetalWindowSlot;
#define MAX_METAL_WINDOWS 64
static MetalWindowSlot metal_windows[MAX_METAL_WINDOWS];
static MetalWindowSlot *current_window_slot = NULL;

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
    s->iosurface_target = mtl_iosurface_target;
    s->iosurface_surface = mtl_iosurface_surface;
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
    mtl_iosurface_target = s->iosurface_target;
    mtl_iosurface_surface = s->iosurface_surface;
}

// Set the current CAMetalLayer for rendering. Called when the OS window is
// made current.
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
        mtl_iosurface_target = nil;
        mtl_iosurface_surface = NULL;
    }
    mtl_current_layer = (__bridge CAMetalLayer *)layer;
}

// Get the current Metal device (for external use)
void*
metal_get_device(void) {
    return (__bridge void *)mtl_device;
}

// ----- IOSurface presentation model (the default; Phase-4 step 7 graduated) -----
// Frames render into IOSurface-backed BGRA8 textures (a 3-deep per-window
// ring) and present by assigning the surface to layer.contents inside an
// explicit CATransaction once the GPU completes. Core Animation composites
// the new contents at the next display refresh — vsync-clean with no drawable
// pool, which is what makes input-driven immediate rendering safe (the L2
// blocker was nextDrawable corrupting the pool under an attached
// CAMetalDisplayLink). Pacing (the flood governor) is a plain CADisplayLink
// in glfw/metal_context.m driving the render gate at the refresh rate; cold
// input bypasses it via the immediate-encode gate (kitty/child-monitor.c).
// Rings are freed on window close (metal_forget_layer). No colorspace is
// attached to the surfaces (see metal-pipeline-design.md).
// KITTY_METAL_IOSURFACE=0 = legacy CAMetalDisplayLink + drawable path.
bool
metal_iosurface_enabled(void) {
    // Wave-5 default: the IOSurface model IS the Metal presentation path.
    // KITTY_METAL_IOSURFACE=0 is the kill switch back to the legacy
    // CAMetalDisplayLink + drawable-pool path.
    static int state = -1;
    if (state < 0) { const char *v = getenv("KITTY_METAL_IOSURFACE"); state = (v && v[0] && strcmp(v, "0") == 0) ? 0 : 1; }
    return state == 1;
}

#define IOSURFACE_RING_DEPTH 3
typedef struct {
    void *layer_ptr;
    IOSurfaceRef surfaces[IOSURFACE_RING_DEPTH];
    id<MTLTexture> textures[IOSURFACE_RING_DEPTH];
    NSUInteger width, height;
    unsigned next_slot;
    bool in_use;
} IOSurfacePresentRing;
static IOSurfacePresentRing iosurface_rings[MAX_METAL_WINDOWS];

static void
iosurface_ring_release(IOSurfacePresentRing *r) {
    for (unsigned i = 0; i < IOSURFACE_RING_DEPTH; i++) {
        [r->textures[i] release]; r->textures[i] = nil;
        if (r->surfaces[i]) { CFRelease(r->surfaces[i]); r->surfaces[i] = NULL; }
    }
    r->width = 0; r->height = 0; r->next_slot = 0;
}

static bool
iosurface_ring_ensure(IOSurfacePresentRing *r, NSUInteger w, NSUInteger h) {
    if (r->width == w && r->height == h && r->textures[0]) return true;
    iosurface_ring_release(r);
    for (unsigned i = 0; i < IOSURFACE_RING_DEPTH; i++) {
        const size_t bpr = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, (size_t)w * 4);
        NSDictionary *props = @{
            (__bridge NSString*)kIOSurfaceWidth: @(w),
            (__bridge NSString*)kIOSurfaceHeight: @(h),
            (__bridge NSString*)kIOSurfaceBytesPerElement: @4u,
            (__bridge NSString*)kIOSurfaceBytesPerRow: @(bpr),
            // 0x42475241 = 'BGRA', matching MTLPixelFormatBGRA8Unorm (the
            // drawable format) so the render pipeline is byte-identical.
            (__bridge NSString*)kIOSurfacePixelFormat: @((uint32_t)0x42475241),
        };
        r->surfaces[i] = IOSurfaceCreate((__bridge CFDictionaryRef)props);
        if (!r->surfaces[i]) {
            log_error("Metal: IOSurfaceCreate failed (%lux%lu)", (unsigned long)w, (unsigned long)h);
            iosurface_ring_release(r); return false;
        }
        MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                        width:w height:h mipmapped:NO];
        // RenderTarget: the frame draws into it. ShaderRead + Shared keep it
        // readable, so screenshot/thumbnail copies work directly off the target
        // (framebufferOnly does not apply — this is not a drawable).
        desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        desc.storageMode = MTLStorageModeShared;
        r->textures[i] = [mtl_device newTextureWithDescriptor:desc iosurface:r->surfaces[i] plane:0];
        if (!r->textures[i]) {
            log_error("Metal: IOSurface-backed texture creation failed (%lux%lu)", (unsigned long)w, (unsigned long)h);
            iosurface_ring_release(r); return false;
        }
    }
    r->width = w; r->height = h; r->next_slot = 0;
    return true;
}

static IOSurfacePresentRing *
iosurface_ring_for_layer(void *layer_ptr) {
    IOSurfacePresentRing *free_r = NULL;
    for (unsigned i = 0; i < MAX_METAL_WINDOWS; i++) {
        if (iosurface_rings[i].in_use) {
            if (iosurface_rings[i].layer_ptr == layer_ptr) return &iosurface_rings[i];
        } else if (!free_r) free_r = &iosurface_rings[i];
    }
    if (!free_r) { log_error("Metal: too many OS windows for IOSurface ring table"); return NULL; }
    memset(free_r, 0, sizeof(*free_r));
    free_r->in_use = true; free_r->layer_ptr = layer_ptr;
    return free_r;
}

// Pick this frame's render target from the ring. Prefers a surface the window
// server is not holding (IOSurfaceIsInUse covers scan-out and in-flight
// compositing); since contents is assigned only after waitUntilCompleted, a
// 3-deep ring always has a free slot in practice.
static bool
iosurface_acquire_target(void) {
    if (mtl_iosurface_target) return true;
    if (!mtl_current_layer) { METAL_TRACE("iosurface: no current layer\n"); return false; }
    CGSize ds = mtl_current_layer.drawableSize;
    NSUInteger w = (NSUInteger)ds.width, h = (NSUInteger)ds.height;
    if (w < 1 || h < 1) {
        if (mtl_viewport.width > 0 && mtl_viewport.height > 0) {
            w = (NSUInteger)mtl_viewport.width; h = (NSUInteger)mtl_viewport.height;
        } else return false;
    }
    IOSurfacePresentRing *r = iosurface_ring_for_layer((__bridge void*)mtl_current_layer);
    if (!r || !iosurface_ring_ensure(r, w, h)) return false;
    unsigned chosen = r->next_slot;
    for (unsigned probe = 0; probe < IOSURFACE_RING_DEPTH; probe++) {
        unsigned s = (r->next_slot + probe) % IOSURFACE_RING_DEPTH;
        if (!IOSurfaceIsInUse(r->surfaces[s])) { chosen = s; break; }
    }
    r->next_slot = (chosen + 1) % IOSURFACE_RING_DEPTH;
    mtl_iosurface_target = r->textures[chosen];
    mtl_iosurface_surface = r->surfaces[chosen];
    METAL_TRACE("iosurface: acquired slot %u (%lux%lu)\n", chosen, (unsigned long)w, (unsigned long)h);
    if (metal_stats_enabled()) metal_frame_encode_start = CACurrentMediaTime();  // encode_ms starts here, as on the drawable paths
    return true;
}

// Measurement-only (stats/signpost runs): the drawable path stamps presents
// with -presentedTime; a contents assignment has no such callback, so pair
// each present with the next display-refresh timestamp from a CADisplayLink
// (macOS 14+). presented_time is therefore a lower bound within one refresh
// of true glass time (exact when the render server makes that refresh's
// deadline, one refresh early when it misses); commit_time is tail-appended
// so offline analysis can bound it. The link stays paused whenever no
// presents are pending.
#define IOSURFACE_PENDING_MAX 64u
@interface KittyIOSurfacePresentStamper : NSObject {
    @public
    uint64_t frames[IOSURFACE_PENDING_MAX];
    double commit_times[IOSURFACE_PENDING_MAX];
    const char *paces[IOSURFACE_PENDING_MAX];
    unsigned count;
    CADisplayLink *link;
}
- (void)tick:(CADisplayLink *)dl;
@end

@implementation KittyIOSurfacePresentStamper
- (void)tick:(CADisplayLink *)dl {
    const double ts = dl.timestamp;  // the refresh that just displayed
    unsigned emitted = 0;
    while (emitted < count && commit_times[emitted] <= ts) {
        char line[192];
        snprintf(line, sizeof line, "metal_present frame=%llu presented_time=%.9f pace=%s commit_time=%.9f\n",
                 (unsigned long long)frames[emitted], ts, paces[emitted], commit_times[emitted]);
        metal_stats_emit(line);
        emitted++;
    }
    if (emitted && emitted < count) {
        memmove(frames, frames + emitted, (count - emitted) * sizeof(frames[0]));
        memmove(commit_times, commit_times + emitted, (count - emitted) * sizeof(commit_times[0]));
        memmove(paces, paces + emitted, (count - emitted) * sizeof(paces[0]));
    }
    count -= emitted;
    if (!count) dl.paused = YES;
}
@end

// Window teardown: free the per-window IOSurface ring (3 surfaces pin up to
// ~90 MB for a retina-fullscreen window) and retire the per-window state slot,
// so neither outlives the window. Core Animation retains whatever surface is
// still set as layer.contents, so releasing our refs here is safe even if the
// closing window is mid-composite.
void
metal_forget_layer(void *layer) {
    if (!layer) return;
    for (unsigned i = 0; i < MAX_METAL_WINDOWS; i++) {
        if (iosurface_rings[i].in_use && iosurface_rings[i].layer_ptr == layer) {
            iosurface_ring_release(&iosurface_rings[i]);
            iosurface_rings[i].in_use = false;
            iosurface_rings[i].layer_ptr = NULL;
            break;
        }
    }
    for (int i = 0; i < MAX_METAL_WINDOWS; i++) {
        if (metal_windows[i].in_use && metal_windows[i].layer_ptr == layer) {
            if (current_window_slot == &metal_windows[i]) {
                // The dying window was current: drop the register-file copies too
                // (the slot never owned these refs; the queue/autorelease pool does).
                current_window_slot = NULL;
                mtl_current_command_buffer = nil;
                mtl_current_drawable = nil;
                mtl_current_encoder = nil;
                mtl_iosurface_target = nil;
                mtl_iosurface_surface = NULL;
                if (mtl_current_layer == (__bridge CAMetalLayer *)layer) mtl_current_layer = nil;
            }
            memset(&metal_windows[i], 0, sizeof(metal_windows[i]));
            break;
        }
    }
}

static KittyIOSurfacePresentStamper *iosurface_stamper = nil;

static void
iosurface_note_present(uint64_t frame, double commit_time, const char *pace) {
    if (!iosurface_stamper) {
        iosurface_stamper = [[KittyIOSurfacePresentStamper alloc] init];
        CADisplayLink *dl = [[NSScreen mainScreen] displayLinkWithTarget:iosurface_stamper selector:@selector(tick:)];
        if (dl) {
            [dl retain];  // MRC: returned autoreleased; keep it alive with the stamper
            [dl addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
            iosurface_stamper->link = dl;
        }
    }
    KittyIOSurfacePresentStamper *s = iosurface_stamper;
    if (!s->link) return;  // headless (no screen): presents go unstamped
    if (s->count >= IOSURFACE_PENDING_MAX) {  // sustained flood: drop the oldest (coalesced by CA anyway)
        memmove(s->frames, s->frames + 1, (IOSURFACE_PENDING_MAX - 1) * sizeof(s->frames[0]));
        memmove(s->commit_times, s->commit_times + 1, (IOSURFACE_PENDING_MAX - 1) * sizeof(s->commit_times[0]));
        memmove(s->paces, s->paces + 1, (IOSURFACE_PENDING_MAX - 1) * sizeof(s->paces[0]));
        s->count = IOSURFACE_PENDING_MAX - 1;
    }
    s->frames[s->count] = frame;
    s->commit_times[s->count] = commit_time;
    s->paces[s->count] = pace;
    s->count++;
    s->link.paused = NO;
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
metal_set_frame_link_driven(bool v) {
    // Pace attribution for the IOSurface model: cocoa_metal_frame_callback
    // brackets its render with true/false so a link-tick render is tagged
    // pace=iosurface and everything else (input-immediate, sync=no inline,
    // resize) falls through to the other tags.
    metal_frame_link_driven = v;
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
    // Phase-4 step 7 spike: the IOSurface presentation model never touches the
    // drawable pool — the frame's target comes from the per-window surface ring.
    if (metal_iosurface_enabled()) return iosurface_acquire_target();
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
// link/nextDrawable drawable normally, or the ring surface under the
// IOSurface spike (in which case no drawable exists).
static id<MTLTexture>
current_drawable_texture(void) {
    if (mtl_iosurface_target) return mtl_iosurface_target;
    return mtl_current_drawable.texture;
}

// C4a/e: persistent offscreen render target used only in KITTY_METAL_DUMP_FRAME
// mode. It mirrors the drawable exactly (plain BGRA8Unorm; C1: sRGB is encoded
// in-shader, so no sRGB view is needed), so the final frame lands here
// byte-identically to how it would on the drawable — the harness reads THIS
// readable texture instead of drawable.texture, which lets the drawable be
// framebufferOnly=YES. Not on any production path.
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
// framebuffer. C1: the drawable is a single plain BGRA8Unorm format — sRGB is
// encoded in-shader (opaque cells/borders) or in the resolve draw (layered), so
// GL_FRAMEBUFFER_SRGB no longer selects a drawable view.
static MTLPixelFormat
wanted_attachment_format(bool for_clear) {
    (void)for_clear;
    // M1: during a layered pass every compositing draw targets att0 (the working
    // surface), so the encoder must never be torn down by a format mismatch.
    if (layered_pass_active) return LAYERED_WORK_FMT;
    if (bound_framebuffer && bound_framebuffer < MAX_FRAMEBUFFERS &&
        framebuffers[bound_framebuffer].in_use && framebuffers[bound_framebuffer].render_target) {
        return framebuffers[bound_framebuffer].render_target.pixelFormat;
    }
    return MTLPixelFormatBGRA8Unorm;
}

// M1: the memoryless RGBA16Unorm working surface (att0), grown to the drawable
// size. Memoryless => contents live only in tile memory during the pass, never
// DRAM, so a resize just recreates a zero-cost descriptor (no allocs= impact —
// that counter tracks MTLBuffer allocations only). Same RGBA16Unorm format as
// the old DRAM layers FBO, so blending precision (#8953) is unchanged.
static bool
ensure_layered_work_surface(NSUInteger w, NSUInteger h) {
    if (w < 1 || h < 1) return false;
    if (layered_work_surface && layered_work_w == w && layered_work_h == h) return true;
    [layered_work_surface release]; layered_work_surface = nil;
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:LAYERED_WORK_FMT
                                                                                    width:w height:h mipmapped:NO];
    desc.usage = MTLTextureUsageRenderTarget;    // framebuffer-fetch read+write; never sampled
    desc.storageMode = MTLStorageModeMemoryless; // tile memory only, never DRAM
    layered_work_surface = [mtl_device newTextureWithDescriptor:desc];
    if (!layered_work_surface) { layered_work_w = layered_work_h = 0; return false; }
    layered_work_w = w; layered_work_h = h;
    return true;
}

// M1: the resolve PSO (fullscreen; reads att0 via [[color(0)]], writes att1).
// Built once; committed command buffers retain it.
static id<MTLRenderPipelineState>
ensure_layers_resolve_pso(void) {
    if (layers_resolve_pso) return layers_resolve_pso;
    if (!mtl_default_library) return nil;
    NSError *error = nil;
    id<MTLFunction> v = [mtl_default_library newFunctionWithName:@"layers_resolve_vertex"];
    id<MTLFunction> f = [mtl_default_library newFunctionWithName:@"layers_resolve_fragment"];
    if (!v || !f) { log_error("Metal: layers_resolve shader functions missing from metallib"); return nil; }
    MTLRenderPipelineDescriptor *d = [[MTLRenderPipelineDescriptor alloc] init];
    d.vertexFunction = v;
    d.fragmentFunction = f;
    d.colorAttachments[0].pixelFormat = LAYERED_WORK_FMT;      // att0: read + passthrough (discarded)
    d.colorAttachments[1].pixelFormat = LAYERED_DRAWABLE_FMT;  // att1: the drawable
    layers_resolve_pso = [mtl_device newRenderPipelineStateWithDescriptor:d error:&error];
    if (!layers_resolve_pso) log_error("Metal: failed to build layers resolve PSO: %s",
            error ? [[error localizedDescription] UTF8String] : "unknown");
    return layers_resolve_pso;
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
        att1 = current_drawable_texture();  // plain BGRA8Unorm base
    }
    if (!att1) return;
    if (!ensure_layered_work_surface(att1.width, att1.height)) return;

    MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
    rpd.colorAttachments[0].texture = layered_work_surface;
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
    mtl_current_enc_fmt = LAYERED_WORK_FMT;  // draw_quad picks the layered (2-attachment) PSOs
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
        id<MTLRenderPipelineState> pso = ensure_layers_resolve_pso();
        if (pso) {
            MTLViewport full = {0, 0, (double)layered_work_w, (double)layered_work_h, 0, 1};
            MTLScissorRect fullsr = {0, 0, layered_work_w, layered_work_h};
            [mtl_current_encoder setViewport:full];
            [mtl_current_encoder setScissorRect:fullsr];
            [mtl_current_encoder setRenderPipelineState:pso];
            [mtl_current_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        }
    }
    end_current_encoder();          // stores att1 (drawable); att0 (memoryless) discarded
    layered_pass_active = false;
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
        target_texture = current_drawable_texture();  // plain BGRA8Unorm; sRGB in-shader
        targeting_drawable = true;
    }
    if (!target_texture) return nil;

    MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
    rpd.colorAttachments[0].texture = target_texture;
    if (clear) {
        rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
        rpd.colorAttachments[0].clearColor = MTLClearColorMake(clear_r, clear_g, clear_b, clear_a);
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
        // Phase 4 step 6 (observability): attribute every frame's scheduling
        // source. resize (presentsWithTransaction) > unsynced (sync_to_monitor=no
        // => displaySyncEnabled=NO) > link (CAMetalDisplayLink drawable) >
        // immediate (L2 input-driven render outside the link). String literals are
        // static, so capturing `pace` in the async handlers below is safe.
        const char *pace =
            mtl_iosurface_target ? (
                (mtl_current_layer && mtl_current_layer.presentsWithTransaction) ? "resize" :
                (mtl_current_layer && !mtl_current_layer.displaySyncEnabled) ? "unsynced" :
                metal_frame_link_driven ? "iosurface" : "immediate") :
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
            const uint64_t bytes = metal_frame_bytes_uploaded; // D2: VAO-buffer bytes uploaded this frame
            [mtl_current_command_buffer addCompletedHandler:^(id<MTLCommandBuffer> cb) {
                const double gpu_ms = (cb.GPUEndTime - cb.GPUStartTime) * 1000.0;
                char line[256];
                // pace= is tail-appended (tolerant parsers, never $-anchored).
                snprintf(line, sizeof line, "metal_stats frame=%llu encode_ms=%.3f gpu_ms=%.3f passes=%d allocs=%d bytes=%llu drawable_wait_ms=%.3f pace=%s\n",
                         (unsigned long long)fidx, encode_ms, gpu_ms, passes, allocs, (unsigned long long)bytes, drawable_wait_ms, pace);
                metal_stats_emit(line);
            }];
        }
        // Present timestamp (photon-adjacent) for the latency harness. Emitted
        // under stats OR signpost; one line per present, keyed to the frame id.
        if ((st || sp) && mtl_current_drawable) {
            [mtl_current_drawable addPresentedHandler:^(id<MTLDrawable> d) {
                char line[128];
                snprintf(line, sizeof line, "metal_present frame=%llu presented_time=%.9f pace=%s\n",
                         (unsigned long long)fidx, d.presentedTime, pace);
                metal_stats_emit(line);
            }];
        }

        const char *dump_path = metal_dump_frame_path();
        if (dump_path) {
            // Golden dump: the frame was rendered to the readable offscreen and
            // no drawable was acquired — commit + wait + read it + write the PNG.
            dump_offscreen_frame(mtl_current_command_buffer, dump_path);
        } else if (mtl_iosurface_target) {
            // Spike present: no implicit GPU→CA fence exists for manually
            // assigned contents, so wait for the GPU (terminal frames encode
            // <1 ms of GPU work; Ghostty's synchronous path does the same),
            // then swap the surface into layer.contents on this same
            // main-thread turn. The explicit transaction + flush pushes the
            // swap to the render server NOW even inside an enclosing implicit
            // (AppKit event) transaction; CA composites it at the next display
            // refresh — vsync-clean without a drawable pool.
            [mtl_current_command_buffer commit];
            [mtl_current_command_buffer waitUntilCompleted];
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            mtl_current_layer.contents = (__bridge id)mtl_iosurface_surface;
            [CATransaction commit];
            [CATransaction flush];
            METAL_TRACE("iosurface: presented frame %llu\n", (unsigned long long)fidx);
            if (st || sp) iosurface_note_present(fidx, CACurrentMediaTime(), pace);
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
        if (sp) os_signpost_interval_end(slog, present_sid, "present", "");
        mtl_current_command_buffer = nil;
        mtl_current_drawable = nil;
    }
    mtl_current_render_pass = nil;
    clear_pending = false;
    metal_pass_count = 0;         // Phase 0: reset for the next frame (per current window)
    metal_frame_encode_start = 0.0; // p99: re-stamped in ensure_drawable, so clear here
    metal_frame_drawable_wait = 0.0; // p99: reset per-frame nextDrawable-wait accumulator
    metal_frame_alloc_count = 0;  // D1: reset per-frame ring allocation counter
    metal_frame_bytes_uploaded = 0; // D2: reset per-frame upload-bytes counter
    drawable_pass_opened = false; // M3: next frame's first drawable pass discards again
    layered_pass_active = false;  // M1: defensive — resolve normally clears it
    metal_frame_used_link_drawable = false; // pace: recomputed per frame in ensure_drawable
    mtl_iosurface_target = nil;   // next frame acquires a fresh ring slot
    mtl_iosurface_surface = NULL;
    metal_frame_link_driven = false; // pace: re-marked per link-tick render
}

bool
metal_immediate_encode_enabled(void) {
    // Under the IOSurface presentation model (the default) there is no drawable
    // pool, so an input-driven frame can render + present at any instant — L2
    // immediate-encode is intrinsic and always on. This is the low-latency half
    // of the flood pacing governor: cold input renders NOW (~14 ms
    // PTY-write→present), and render_prepared_os_window's request_frame_render
    // resumes the pace link so sustained damage collapses to refresh-rate ticks.
    if (metal_iosurface_enabled()) return true;
    // Legacy (KITTY_METAL_IOSURFACE=0) drawable path: rendering an input frame
    // via nextDrawable while the CAMetalDisplayLink is attached corrupts the
    // drawable pool (SIGSEGV — see the "L2 ... DEFERRED" note in
    // metal-pipeline-design.md). KITTY_METAL_IMMEDIATE stays NEUTERED there —
    // it logs once and does nothing.
    static bool checked = false;
    if (!checked) {
        checked = true;
        const char *v = getenv("KITTY_METAL_IMMEDIATE");
        if (v && v[0] && strcmp(v, "0") != 0)
            log_error("KITTY_METAL_IMMEDIATE: immediate-encode requires the IOSurface "
                      "presentation model (see kitty/metal-pipeline-design.md); ignored");
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

void metal_gl_viewport(int x, int y, int w, int h) {
    mtl_viewport = (MTLViewport){(double)x, (double)y, (double)w, (double)h, 0, 1};
}

void metal_gl_scissor(int x, int y, int w, int h) {
    mtl_scissor = (MTLScissorRect){(NSUInteger)x, (NSUInteger)y, (NSUInteger)w, (NSUInteger)h};
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

void metal_gl_delete_textures(int n, const GLuint *ids) {
    for (int i = 0; i < n; i++) {
        if (ids[i] && ids[i] < MAX_TEXTURES) recycle_texture_id(ids[i]);
    }
}

static MTLPixelFormat
pixel_format_for_gl(int internalformat) {
    switch (internalformat) {
        case GL_SRGB_ALPHA: case GL_SRGB8_ALPHA8: return MTLPixelFormatRGBA8Unorm_sRGB;
        // GL_RGBA16 is unsigned-normalized in GL; RGBA16Float would change
        // blending/rounding semantics of the layers FBO (issue #8953 path).
        case GL_RGBA16: return MTLPixelFormatRGBA16Unorm;
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
        case MTLPixelFormatRGBA32Uint: return 16;
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

    NSUInteger dst_bpp = mtl_bytes_per_pixel(t->texture.pixelFormat);
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

    NSUInteger bpp = 4;
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
    desc.width = width;
    desc.height = height;
    desc.arrayLength = depth;
    desc.mipmapLevelCount = 1;
    desc.usage = MTLTextureUsageShaderRead;
    desc.storageMode = MTLStorageModeShared;

    [t->texture release];
    t->texture = [mtl_device newTextureWithDescriptor:desc];
    t->target = GL_TEXTURE_2D_ARRAY;
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
    } else if (mtl_current_drawable || mtl_iosurface_target) {
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

void metal_gl_delete_framebuffers(int n, const GLuint *ids) {
    for (int i = 0; i < n; i++) {
        if (ids[i] && ids[i] < MAX_FRAMEBUFFERS) {
            framebuffers[ids[i]].in_use = false;
            [framebuffers[ids[i]].render_target release];
            framebuffers[ids[i]].render_target = nil;
        }
    }
}

void metal_gl_bind_framebuffer(GLenum target, GLuint id) {
    // Direct glBindFramebuffer: binds literally (no output indirection).
    (void)target;
    if (id != bound_framebuffer) {
        end_current_encoder();
        bound_framebuffer = id;
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

GLenum metal_gl_check_framebuffer_status(GLenum target) {
    (void)target;
    return GL_FRAMEBUFFER_COMPLETE;
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
    } else if (mtl_current_drawable || mtl_iosurface_target) {
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
    if (current_program >= 0 && loc >= 0 && loc < MAX_UNIFORMS_PER_PROGRAM) {
        for (int i = 0; i < count * 4 && i < 4; i++) {
            uniform_stores[current_program].values[loc].f[i] = v[i];
        }
    }
}

// ----- Draw -----
void metal_gl_draw_arrays(GLenum mode, int first, int count) {
    (void)mode; (void)first; (void)count;
    // Stub — actual drawing happens in draw_quad()
}

void metal_gl_draw_arrays_instanced(GLenum mode, int first, int count, int instancecount) {
    (void)mode; (void)first; (void)count; (void)instancecount;
    // Stub — actual drawing happens in draw_quad()
}

const unsigned char* metal_gl_get_string(GLenum name) {
    switch (name) {
        case GL_VERSION: return (const unsigned char*)"Metal";
        case GL_VENDOR: return (const unsigned char*)"Apple";
        case GL_RENDERER: return (const unsigned char*)(mtl_device ? [mtl_device.name UTF8String] : "Metal");
        case GL_SHADING_LANGUAGE_VERSION: return (const unsigned char*)"MSL 2.4";
        default: return (const unsigned char*)"";
    }
}

// ----- Shader/Program Stubs -----

GLuint metal_gl_create_shader(GLenum type) {
    (void)type;
    static GLuint next_id = 1;
    return next_id++;
}

void metal_gl_get_shaderiv(GLuint id, GLenum pname, GLint *params) {
    (void)id;
    if (pname == GL_COMPILE_STATUS) *params = GL_TRUE;
    else *params = 0;
}

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
void metal_gl_use_program(GLuint prog) { (void)prog; }

// ----- VAO/Buffer GL stubs -----

void metal_gl_gen_vertex_arrays(int n, GLuint *ids) {
    for (int i = 0; i < n; i++) {
        static GLuint next_id = 1;
        ids[i] = next_id++;
    }
}

void metal_gl_delete_vertex_arrays(int n, const GLuint *ids) {
    (void)n; (void)ids;
}

void metal_gl_bind_vertex_array(GLuint id) { (void)id; }

void metal_gl_gen_buffers(int n, GLuint *ids) {
    for (int i = 0; i < n; i++) {
        static GLuint next_id = 1;
        ids[i] = next_id++;
    }
}

void metal_gl_delete_buffers(int n, const GLuint *ids) {
    (void)n; (void)ids;
}

void metal_gl_bind_buffer(GLenum target, GLuint id) { (void)target; (void)id; }

void metal_gl_buffer_data(GLenum target, GLsizeiptr size, const void *data, GLenum usage) {
    (void)target; (void)size; (void)data; (void)usage;
}

void* metal_gl_map_buffer(GLenum target, GLenum access) {
    (void)target; (void)access;
    return NULL;
}

void* metal_gl_map_buffer_range(GLenum target, int offset, unsigned length, unsigned access) {
    (void)target; (void)offset; (void)length; (void)access;
    return NULL;
}

void metal_gl_unmap_buffer(GLenum target) { (void)target; }

void metal_gl_bind_buffer_base(GLenum target, GLuint index, GLuint buffer) {
    (void)target; (void)index; (void)buffer;
}
