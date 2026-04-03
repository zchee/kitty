/*
 * metal.m
 * Copyright (C) 2024 Kovid Goyal <kovid at kovidgoyal.net>
 *
 * Distributed under terms of the GPL3 license.
 */

// Include system headers first to avoid macro conflicts
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>

// Undefine system MAX/MIN before data-types.h redefines them
#undef MAX
#undef MIN

#include "metal.h"
#include "state.h"
#include "png-reader.h"

#include <string.h>
#include <stddef.h>

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

// Pipeline state objects
static id<MTLRenderPipelineState> mtl_clear_pipeline UNUSED = nil;

// Clear color state
static float clear_r = 0, clear_g = 0, clear_b = 0, clear_a = 1;
static bool clear_pending = false;

// Forward declarations
static void end_current_encoder(void);
static bool ensure_command_buffer(void);
static bool ensure_drawable(void);
static id<MTLRenderCommandEncoder> begin_render_pass_to_drawable(bool clear);

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

// Blend state
static bool blend_enabled = false;

// Active texture unit tracking
static unsigned active_texture_unit = 0;
#define MAX_TEXTURE_UNITS 8
static GLuint bound_textures[MAX_TEXTURE_UNITS] = {0};  // texture ID bound per unit
static GLenum bound_texture_targets[MAX_TEXTURE_UNITS] = {0}; // GL_TEXTURE_2D or GL_TEXTURE_2D_ARRAY

// Output framebuffer tracking
static unsigned output_framebuffer = 0;

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
    bool dirty;
} uniform_stores[64];

// Gamma LUT — cached for binding to shaders
static const float *cached_gamma_lut = NULL;
static int cached_gamma_lut_count = 0;

// Current VAO binding for buffer access
static ssize_t current_bound_vao = -1;
static GLuint current_bound_uniform_block = 0;

// ----- Programs -----

static Program programs[64] = {{0}};
static int current_program = -1;

// Pipeline states indexed by program enum
#define NUM_PROGRAMS 14
static id<MTLRenderPipelineState> pipeline_states[NUM_PROGRAMS] = {nil};
static id<MTLRenderPipelineState> pipeline_states_blend[NUM_PROGRAMS] = {nil}; // with blending enabled

// Pipeline state creation helper
static id<MTLRenderPipelineState>
create_pipeline_state(NSString *vertex_fn, NSString *fragment_fn, bool enable_blend,
                      MTLVertexDescriptor *vertex_desc, MTLPixelFormat pixel_format,
                      MTLFunctionConstantValues *constants) {
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

// Create all pipeline states — called after metallib is loaded
static void
create_all_pipeline_states(void) {
    if (!mtl_default_library) return;
    MTLPixelFormat pfmt = MTLPixelFormatBGRA8Unorm_sRGB;

    // --- Blit program ---
    pipeline_states[11] = create_pipeline_state(@"blit_vertex", @"blit_fragment", false, nil, pfmt, nil);
    pipeline_states_blend[11] = pipeline_states[11]; // blit doesn't need blend variant

    // --- Screenshot program ---
    pipeline_states[12] = create_pipeline_state(@"screenshot_vertex", @"screenshot_fragment", false, nil, pfmt, nil);

    // --- Tint program ---
    pipeline_states[9] = create_pipeline_state(@"tint_vertex", @"tint_fragment", true, nil, pfmt, nil);
    pipeline_states_blend[9] = pipeline_states[9];

    // --- Trail program ---
    pipeline_states[10] = create_pipeline_state(@"trail_vertex", @"trail_fragment", true, nil, pfmt, nil);
    pipeline_states_blend[10] = pipeline_states[10];

    // --- Rounded rect program ---
    pipeline_states[13] = create_pipeline_state(@"rounded_rect_vertex", @"rounded_rect_fragment", true, nil, pfmt, nil);
    pipeline_states_blend[13] = pipeline_states[13];

    // --- Border program ---
    pipeline_states[4] = create_pipeline_state(@"border_vertex", @"border_fragment", false, nil, pfmt, nil);
    pipeline_states_blend[4] = create_pipeline_state(@"border_vertex", @"border_fragment", true, nil, pfmt, nil);

    // --- Graphics programs (IMAGE, PREMULT, ALPHA_MASK) ---
    for (int i = 0; i < 3; i++) {
        MTLFunctionConstantValues *fc = [[MTLFunctionConstantValues alloc] init];
        bool is_alpha_mask = (i == 2);
        bool is_premult = (i == 1);
        [fc setConstantValue:&is_alpha_mask type:MTLDataTypeBool atIndex:0];
        [fc setConstantValue:&is_premult type:MTLDataTypeBool atIndex:1];
        int prog_idx = 5 + i; // GRAPHICS_PROGRAM=5, GRAPHICS_PREMULT=6, GRAPHICS_ALPHA_MASK=7
        pipeline_states[prog_idx] = create_pipeline_state(@"graphics_vertex", @"graphics_fragment", true, nil, pfmt, fc);
        pipeline_states_blend[prog_idx] = pipeline_states[prog_idx];
    }

    // --- Bgimage program ---
    pipeline_states[8] = create_pipeline_state(@"bgimage_vertex", @"bgimage_fragment", false, nil, pfmt, nil);

    // --- Cell programs (3 variants) ---
    // Cell vertex descriptor for instanced rendering
    MTLVertexDescriptor *cell_vd = [[MTLVertexDescriptor alloc] init];
    // Buffer 0: GPUCell data (colors + sprite_idx)
    // attribute 0: colors (uvec3) — 3 x uint32
    cell_vd.attributes[0].format = MTLVertexFormatUInt3;
    cell_vd.attributes[0].offset = 0; // offsetof(GPUCell, fg)
    cell_vd.attributes[0].bufferIndex = 0;
    // attribute 1: sprite_idx (uvec2) — 2 x uint32
    cell_vd.attributes[1].format = MTLVertexFormatUInt2;
    cell_vd.attributes[1].offset = 12; // offsetof(GPUCell, sprite_idx)
    cell_vd.attributes[1].bufferIndex = 0;
    // Buffer layout 0: per-instance step
    cell_vd.layouts[0].stride = 20; // sizeof(GPUCell) — 5 x uint32 = 20 bytes
    cell_vd.layouts[0].stepFunction = MTLVertexStepFunctionPerInstance;
    cell_vd.layouts[0].stepRate = 1;
    // Buffer 1: selection data
    // attribute 2: is_selected (uint8)
    cell_vd.attributes[2].format = MTLVertexFormatUChar;
    cell_vd.attributes[2].offset = 0;
    cell_vd.attributes[2].bufferIndex = 5;
    cell_vd.layouts[5].stride = 1; // 1 byte per cell
    cell_vd.layouts[5].stepFunction = MTLVertexStepFunctionPerInstance;
    cell_vd.layouts[5].stepRate = 1;

    // CELL_PROGRAM=0, CELL_FG_PROGRAM=1, CELL_BG_PROGRAM=2
    for (int i = 0; i < 3; i++) {
        MTLFunctionConstantValues *fc = [[MTLFunctionConstantValues alloc] init];
        bool only_fg = (i == 1);
        bool only_bg = (i == 2);
        bool do_fg_override = false; // Will be set during recompile
        int fg_algo = 1;
        float fg_threshold = 0.0f;
        bool new_gamma = true;
        [fc setConstantValue:&only_fg type:MTLDataTypeBool atIndex:0]; // ONLY_FOREGROUND
        [fc setConstantValue:&only_bg type:MTLDataTypeBool atIndex:1]; // ONLY_BACKGROUND
        [fc setConstantValue:&do_fg_override type:MTLDataTypeBool atIndex:2]; // DO_FG_OVERRIDE_ENABLED
        [fc setConstantValue:&fg_algo type:MTLDataTypeInt atIndex:3]; // FG_OVERRIDE_ALGO_VAL
        [fc setConstantValue:&fg_threshold type:MTLDataTypeFloat atIndex:4]; // FG_OVERRIDE_THRESHOLD_VAL
        [fc setConstantValue:&new_gamma type:MTLDataTypeBool atIndex:5]; // TEXT_NEW_GAMMA_ENABLED
        pipeline_states[i] = create_pipeline_state(@"cell_vertex", @"cell_fragment", false, cell_vd, pfmt, fc);
        pipeline_states_blend[i] = create_pipeline_state(@"cell_vertex", @"cell_fragment", true, cell_vd, pfmt, fc);
    }

    if (global_state.debug_rendering) {
        int count = 0;
        for (int i = 0; i < NUM_PROGRAMS; i++) {
            if (pipeline_states[i]) count++;
        }
        NSLog(@"[Metal] Created %d pipeline states", count);
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

GLint
get_uniform_information(int program, const char *name, GLenum information_type) {
    // For Metal, return reasonable defaults that match the OpenGL std140 layout
    (void)program; (void)name;
    switch (information_type) {
        case GL_UNIFORM_SIZE: return 256; // color_table size
        case GL_UNIFORM_OFFSET: return 128; // offset past the main uniforms
        case GL_UNIFORM_ARRAY_STRIDE: return 16; // std140 stride for vec4
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
    (void)program; (void)name;
    return 0; // Metal uses buffer indices directly
}

GLint
block_size(int program, GLuint bidx) {
    (void)program; (void)bidx;
    return sizeof(MetalCellRenderData) + 256 * 16; // render data + color table
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

typedef struct {
    id<MTLBuffer> mtl_buffer;
    GLsizeiptr size;
    GLenum usage;
    void *mapped_ptr;
} MetalBuffer;

#define MAX_CHILDREN 512
static MetalBuffer buffers[MAX_CHILDREN * 6 + 4];
static size_t buffer_count = 0;

static ssize_t
create_buffer(GLenum usage) {
    for (size_t i = 0; i < sizeof(buffers)/sizeof(buffers[0]); i++) {
        if (!buffers[i].mtl_buffer && !buffers[i].mapped_ptr) {
            buffers[i].size = 0;
            buffers[i].usage = usage;
            buffers[i].mtl_buffer = nil;
            buffers[i].mapped_ptr = NULL;
            if (i >= buffer_count) buffer_count = i + 1;
            return i;
        }
    }
    fatal("Too many Metal buffers");
    return -1;
}

static void
delete_buffer(ssize_t buf_idx) {
    if (buffers[buf_idx].mtl_buffer) {
        buffers[buf_idx].mtl_buffer = nil;
    }
    // mapped_ptr points into MTLBuffer's memory — do NOT free() it
    buffers[buf_idx].mapped_ptr = NULL;
    buffers[buf_idx].size = 0;
}

static void
alloc_buffer_data(ssize_t idx, GLsizeiptr size) {
    MetalBuffer *b = &buffers[idx];
    if (b->size == size && b->mtl_buffer) return;
    b->size = size;
    // Release old buffer — mapped_ptr points into MTLBuffer's memory, NOT malloc'd
    if (b->mtl_buffer) b->mtl_buffer = nil;
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
static ssize_t current_vao = -1;

ssize_t
create_vao(void) {
    for (size_t i = 0; i < sizeof(vaos)/sizeof(vaos[0]); i++) {
        if (!vaos[i].in_use) {
            vaos[i].in_use = true;
            vaos[i].num_buffers = 0;
            current_vao = i;
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
    if (current_vao == vao_idx) current_vao = -1;
}

void
bind_vertex_array(ssize_t vao_idx) {
    current_vao = vao_idx;
    current_bound_vao = vao_idx;
}

void
unbind_vertex_array(void) {
    current_vao = -1;
    current_bound_vao = -1;
}

ssize_t
alloc_vao_buffer(ssize_t vao_idx, GLsizeiptr size, size_t bufnum, GLenum usage) {
    (void)usage;
    ssize_t buf_idx = vaos[vao_idx].buffers[bufnum];
    alloc_buffer_data(buf_idx, size);
    return buf_idx;
}

void*
alloc_and_map_vao_buffer(ssize_t vao_idx, GLsizeiptr size, size_t bufnum, bool frequently_updated) {
    (void)frequently_updated;
    ssize_t buf_idx = alloc_vao_buffer(vao_idx, size, bufnum, GL_STREAM_DRAW);
    return buffers[buf_idx].mapped_ptr;
}

void*
map_vao_buffer(ssize_t vao_idx, size_t bufnum, GLenum access) {
    (void)access;
    ssize_t buf_idx = vaos[vao_idx].buffers[bufnum];
    return buffers[buf_idx].mapped_ptr;
}

void*
map_vao_buffer_for_write_only(ssize_t vao_idx, size_t bufnum, int offset, unsigned size) {
    (void)size;
    ssize_t buf_idx = vaos[vao_idx].buffers[bufnum];
    MetalBuffer *b = &buffers[buf_idx];
    if (!b->mapped_ptr && b->mtl_buffer) b->mapped_ptr = b->mtl_buffer.contents;
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
    (void)bidx;
    current_bound_vao = vao_idx;
    current_bound_uniform_block = (GLuint)bufnum;
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
            if (mtl_default_library) break;
        }
    }
    if (!mtl_default_library) {
        mtl_default_library = [mtl_device newDefaultLibrary];
    }
    if (!mtl_default_library) {
        log_error("Metal: No shader library found. Searched: %s", [[searchPaths componentsJoinedByString:@", "] UTF8String]);
    }

    global_state.gl_version = (3 << 16) | 3; // Report as "3.3" for compatibility
    global_state.supports_framebuffer_srgb = true;

    // Create render pipeline states from the loaded metallib
    create_all_pipeline_states();

    initialized = true;

    if (global_state.debug_rendering) {
        log_error("[Metal] Initialized device: %s, library: %s, pipelines: %d",
            mtl_device ? [mtl_device.name UTF8String] : "nil",
            mtl_default_library ? "loaded" : "MISSING",
            pipeline_states[0] ? NUM_PROGRAMS : 0);
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
void
draw_quad(bool blend, unsigned instance_count) {
    blend_enabled = blend;
    if (!mtl_current_layer) return;
    if (dq_log_count < 20) {
        FILE *f = fopen("/tmp/kitty_metal_debug.log", "a");
        if (f) {
            CGSize ds = mtl_current_layer.drawableSize;
            fprintf(f, "draw_quad[%d]: prog=%d blend=%d inst=%u vao=%zd vp=(%.0f,%.0f,%.0f,%.0f) ds=%.0fx%.0f pso=%p\n",
                dq_log_count, current_program, blend, instance_count, current_bound_vao,
                mtl_viewport.originX, mtl_viewport.originY, mtl_viewport.width, mtl_viewport.height,
                ds.width, ds.height,
                current_program >= 0 && current_program < NUM_PROGRAMS ?
                    (__bridge void*)(blend ? pipeline_states_blend[current_program] : pipeline_states[current_program]) : NULL);
            fclose(f);
        }
        dq_log_count++;
    }

    // If there's a pending clear and no encoder yet, start a render pass with clear
    if (clear_pending && !mtl_current_encoder) {
        begin_render_pass_to_drawable(true);
        clear_pending = false;
        if (!instance_count) return; // clear-only call
    }

    // Ensure we have an encoder for actual drawing
    if (!mtl_current_encoder) {
        begin_render_pass_to_drawable(false);
    }
    if (!mtl_current_encoder) return;

    // Set viewport
    [mtl_current_encoder setViewport:mtl_viewport];

    // Set scissor if enabled
    if (scissor_enabled) {
        // Clamp scissor rect to drawable dimensions
        NSUInteger dw = mtl_current_drawable.texture.width;
        NSUInteger dh = mtl_current_drawable.texture.height;
        MTLScissorRect sr = mtl_scissor;
        if (sr.x + sr.width > dw) sr.width = dw > sr.x ? dw - sr.x : 0;
        if (sr.y + sr.height > dh) sr.height = dh > sr.y ? dh - sr.y : 0;
        if (sr.width > 0 && sr.height > 0) {
            [mtl_current_encoder setScissorRect:sr];
        }
    }

    // Bind the appropriate pipeline state for the current program
    if (current_program < 0 || current_program >= NUM_PROGRAMS) return;
    id<MTLRenderPipelineState> pso = blend ? pipeline_states_blend[current_program] : pipeline_states[current_program];
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
        // Gamma LUT → buffer index 3
        if (cached_gamma_lut) {
            [mtl_current_encoder setVertexBytes:cached_gamma_lut length:256 * sizeof(float) atIndex:3];
        }
        // Color table is part of the uniform block buffer, but we also pass it separately at index 4
        // The color table starts at offset cell_program_layouts[].color_table.offset in the uniform block
        // For now, pass the whole uniform block at both indices
        if (current_bound_vao >= 0) {
            MetalVAO *vao = &vaos[current_bound_vao];
            if (vao->num_buffers > 2) {
                ssize_t buf_idx = vao->buffers[2];
                if (buffers[buf_idx].mtl_buffer) {
                    // Pass color table portion at offset past CellRenderData
                    // This offset must match what get_uniform_information(GL_UNIFORM_OFFSET)
                    // returns for "color_table[0]" — currently 128 bytes (sizeof GPUCellRenderData)
                    // See shaders.c:378 where this is queried via get_uniform_information()
                    NSUInteger ct_offset = 128; // sizeof(GPUCellRenderData) rounded to std140
                    [mtl_current_encoder setVertexBuffer:buffers[buf_idx].mtl_buffer offset:ct_offset atIndex:4];
                }
            }
        }
        // Per-draw uniforms (draw_bg_bitfield, row_offset, etc.) → buffer index 2
        // Uniform locations from get_uniform_locations_cell() order in uniforms_generated.h:
        //   loc 0: text_contrast, loc 1: text_gamma_adjustment, loc 2: sprites (tex unit),
        //   loc 3: gamma_lut, loc 4: draw_bg_bitfield, loc 5: sprite_decorations_map (tex unit),
        //   loc 6: row_offset
        struct { uint32_t draw_bg_bitfield; float row_offset; float text_contrast; float text_gamma_adjustment; } cell_draw = {0};
        if (current_program >= 0 && current_program < 64) {
            cell_draw.text_contrast = uniform_stores[current_program].values[0].f[0];         // loc 0
            cell_draw.text_gamma_adjustment = uniform_stores[current_program].values[1].f[0]; // loc 1
            cell_draw.draw_bg_bitfield = uniform_stores[current_program].values[4].u[0];      // loc 4
            cell_draw.row_offset = uniform_stores[current_program].values[6].f[0];            // loc 6
        }
        [mtl_current_encoder setVertexBytes:&cell_draw length:sizeof(cell_draw) atIndex:2];
        [mtl_current_encoder setFragmentBytes:&cell_draw length:sizeof(cell_draw) atIndex:2];

        // Bind textures: unit 0 = sprite atlas (2D array), unit 2 = decorations map
        if (bound_textures[0] && bound_textures[0] < MAX_TEXTURES && textures[bound_textures[0]].texture) {
            [mtl_current_encoder setFragmentTexture:textures[bound_textures[0]].texture atIndex:0];
            [mtl_current_encoder setVertexTexture:textures[bound_textures[0]].texture atIndex:0];
        }
        if (bound_textures[2] && bound_textures[2] < MAX_TEXTURES && textures[bound_textures[2]].texture) {
            [mtl_current_encoder setVertexTexture:textures[bound_textures[2]].texture atIndex:2];
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
        // Border uniforms from uniforms_generated.h: colors=loc0, background_opacity=loc1, gamma_lut=loc2
        // glUniform1uiv(loc0, 9, colors) stores 9 values starting at values[0]
        // glUniform1f(loc1, bg_opacity) stores at values[1] — overlaps with colors[1]!
        // So we need to read colors BEFORE background_opacity is set, or track separately.
        // In practice, colors and bg_opacity are set in draw_borders() in sequence,
        // so we use a dedicated array for colors via the "large array" path.
        // Border uniform locs: colors=0, background_opacity=1, gamma_lut=2
        // colors array stored at ARRAY_UNIFORM_BASE + 0*16 = values[200..208]
        struct { uint32_t colors[9]; float background_opacity; float pad[2]; float gamma_lut[256]; } border_u = {0};
        for (int i = 0; i < 9; i++) {
            border_u.colors[i] = uniform_stores[current_program].values[ARRAY_UNIFORM_BASE + i].u[0];
        }
        border_u.background_opacity = uniform_stores[current_program].values[1].f[0]; // loc 1 (scalar)
        if (cached_gamma_lut) memcpy(border_u.gamma_lut, cached_gamma_lut, sizeof(border_u.gamma_lut));
        [mtl_current_encoder setVertexBytes:&border_u length:sizeof(border_u) atIndex:1];
    } else if (current_program >= 5 && current_program <= 7) {
        // Graphics uniform locs: image=0, amask_fg=1, amask_bg_premult=2, extra_alpha=3, src_rect=4, dest_rect=5
        struct { float src_rect[4]; float dest_rect[4]; float extra_alpha; float amask_fg[3]; float amask_bg_premult[4]; } gfx_u = {0};
        for (int i = 0; i < 4; i++) {
            gfx_u.src_rect[i] = uniform_stores[current_program].values[4].f[i];  // loc 4
            gfx_u.dest_rect[i] = uniform_stores[current_program].values[5].f[i]; // loc 5
        }
        gfx_u.extra_alpha = uniform_stores[current_program].values[3].f[0]; // loc 3
        for (int i = 0; i < 3; i++) gfx_u.amask_fg[i] = uniform_stores[current_program].values[1].f[i]; // loc 1
        for (int i = 0; i < 4; i++) gfx_u.amask_bg_premult[i] = uniform_stores[current_program].values[2].f[i]; // loc 2
        [mtl_current_encoder setVertexBytes:&gfx_u length:sizeof(gfx_u) atIndex:0];
        [mtl_current_encoder setFragmentBytes:&gfx_u length:sizeof(gfx_u) atIndex:0];
        // Bind image texture from unit 1 (GRAPHICS_UNIT)
        if (bound_textures[1] && bound_textures[1] < MAX_TEXTURES && textures[bound_textures[1]].texture) {
            [mtl_current_encoder setFragmentTexture:textures[bound_textures[1]].texture atIndex:0];
        }
    } else if (current_program == 8) {
        // Bgimage uniform locs: image=0, background=1, tiled=2, sizes=3, positions=4
        struct { float sizes[4]; float positions[4]; float background[4]; float tiled; float pad[3]; } bg_u = {0};
        for (int i = 0; i < 4; i++) bg_u.sizes[i] = uniform_stores[current_program].values[3].f[i];       // loc 3
        for (int i = 0; i < 4; i++) bg_u.positions[i] = uniform_stores[current_program].values[4].f[i];    // loc 4
        for (int i = 0; i < 4; i++) bg_u.background[i] = uniform_stores[current_program].values[1].f[i];   // loc 1
        bg_u.tiled = uniform_stores[current_program].values[2].f[0];                                        // loc 2
        [mtl_current_encoder setVertexBytes:&bg_u length:sizeof(bg_u) atIndex:0];
        [mtl_current_encoder setFragmentBytes:&bg_u length:sizeof(bg_u) atIndex:0];
        if (bound_textures[1] && bound_textures[1] < MAX_TEXTURES && textures[bound_textures[1]].texture) {
            [mtl_current_encoder setFragmentTexture:textures[bound_textures[1]].texture atIndex:0];
        }
    } else if (current_program == 9) {
        // Tint — tint_color + edges
        struct { float tint_color[4]; float edges[4]; } tint_u = {0};
        for (int i = 0; i < 4; i++) tint_u.tint_color[i] = uniform_stores[current_program].values[0].f[i];
        for (int i = 0; i < 4; i++) tint_u.edges[i] = uniform_stores[current_program].values[1].f[i];
        [mtl_current_encoder setVertexBytes:&tint_u length:sizeof(tint_u) atIndex:0];
        [mtl_current_encoder setFragmentBytes:&tint_u length:sizeof(tint_u) atIndex:0];
    } else if (current_program == 10) {
        // Trail uniform locs: cursor_edge_x=0, cursor_edge_y=1, trail_color=2, trail_opacity=3, x_coords=4, y_coords=5
        struct { float x_coords[4]; float y_coords[4]; float cursor_edge_x[2]; float cursor_edge_y[2];
                 float trail_color[3]; float trail_opacity; } trail_u = {0};
        for (int i = 0; i < 4; i++) trail_u.x_coords[i] = uniform_stores[current_program].values[4].f[i];    // loc 4
        for (int i = 0; i < 4; i++) trail_u.y_coords[i] = uniform_stores[current_program].values[5].f[i];    // loc 5
        trail_u.cursor_edge_x[0] = uniform_stores[current_program].values[0].f[0];                           // loc 0
        trail_u.cursor_edge_x[1] = uniform_stores[current_program].values[0].f[1];
        trail_u.cursor_edge_y[0] = uniform_stores[current_program].values[1].f[0];                           // loc 1
        trail_u.cursor_edge_y[1] = uniform_stores[current_program].values[1].f[1];
        for (int i = 0; i < 3; i++) trail_u.trail_color[i] = uniform_stores[current_program].values[2].f[i]; // loc 2
        trail_u.trail_opacity = uniform_stores[current_program].values[3].f[0];                               // loc 3
        [mtl_current_encoder setVertexBytes:&trail_u length:sizeof(trail_u) atIndex:0];
        [mtl_current_encoder setFragmentBytes:&trail_u length:sizeof(trail_u) atIndex:0];
    } else if (current_program == 11) {
        // Blit uniform locs: image=0, src_rect=1, dest_rect=2
        struct { float src_rect[4]; float dest_rect[4]; } blit_u = {0};
        for (int i = 0; i < 4; i++) blit_u.src_rect[i] = uniform_stores[current_program].values[1].f[i];  // loc 1
        for (int i = 0; i < 4; i++) blit_u.dest_rect[i] = uniform_stores[current_program].values[2].f[i]; // loc 2
        [mtl_current_encoder setVertexBytes:&blit_u length:sizeof(blit_u) atIndex:0];
        [mtl_current_encoder setFragmentBytes:&blit_u length:sizeof(blit_u) atIndex:0];
        if (bound_textures[1] && bound_textures[1] < MAX_TEXTURES && textures[bound_textures[1]].texture) {
            [mtl_current_encoder setFragmentTexture:textures[bound_textures[1]].texture atIndex:0];
        }
    } else if (current_program == 12) {
        // Screenshot uniform locs: image=0, src_size=1, src_rect=2, dest_rect=3
        struct { float src_rect[4]; float dest_rect[4]; float src_size[2]; float pad[2]; } ss_u = {0};
        for (int i = 0; i < 4; i++) ss_u.src_rect[i] = uniform_stores[current_program].values[2].f[i];  // loc 2
        for (int i = 0; i < 4; i++) ss_u.dest_rect[i] = uniform_stores[current_program].values[3].f[i]; // loc 3
        ss_u.src_size[0] = uniform_stores[current_program].values[1].f[0];                               // loc 1
        ss_u.src_size[1] = uniform_stores[current_program].values[1].f[1];
        [mtl_current_encoder setVertexBytes:&ss_u length:sizeof(ss_u) atIndex:0];
        [mtl_current_encoder setFragmentBytes:&ss_u length:sizeof(ss_u) atIndex:0];
        if (bound_textures[1] && bound_textures[1] < MAX_TEXTURES && textures[bound_textures[1]].texture) {
            [mtl_current_encoder setFragmentTexture:textures[bound_textures[1]].texture atIndex:0];
        }
    } else if (current_program == 13) {
        // RoundedRect uniform locs: rect=0, params=1, color=2, background_color=3
        struct { float color[4]; float background_color[4]; float rect[4]; float params[2]; float pad[2]; } rr_u = {0};
        for (int i = 0; i < 4; i++) rr_u.color[i] = uniform_stores[current_program].values[2].f[i];            // loc 2
        for (int i = 0; i < 4; i++) rr_u.background_color[i] = uniform_stores[current_program].values[3].f[i]; // loc 3
        for (int i = 0; i < 4; i++) rr_u.rect[i] = uniform_stores[current_program].values[0].f[i];             // loc 0
        rr_u.params[0] = uniform_stores[current_program].values[1].f[0];                                       // loc 1
        rr_u.params[1] = uniform_stores[current_program].values[1].f[1];
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
    // Switch rendering between the main drawable and an offscreen framebuffer
    if (fbid != output_framebuffer) {
        // End current render pass before switching targets
        end_current_encoder();
        output_framebuffer = fbid;
    }
    // If we switch to an offscreen framebuffer, the next draw call will
    // create a new render pass targeting that framebuffer's texture.
    // If fbid == 0, we render to the default drawable.
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

void
free_texture(GLuint *tex_id) {
    if (*tex_id && *tex_id < MAX_TEXTURES) {
        textures[*tex_id].texture = nil;
        textures[*tex_id].target = 0;
    }
    *tex_id = 0;
}

void
free_framebuffer(GLuint *fb_id) {
    if (*fb_id && *fb_id < MAX_FRAMEBUFFERS) {
        framebuffers[*fb_id].in_use = false;
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

    // Convert from linear premultiplied to sRGB straight alpha
    for (int i = 0; i < width * height; i++) {
        uint32_t px = data[i];
        uint8_t r = (px >> 0) & 0xFF, g = (px >> 8) & 0xFF, b = (px >> 16) & 0xFF, a = (px >> 24) & 0xFF;
        float alpha = a / 255.0f;
        float rf = 0, gf = 0, bf = 0;
        if (alpha > 0.0f) {
            rf = (r / 255.0f) / alpha; gf = (g / 255.0f) / alpha; bf = (b / 255.0f) / alpha;
        }
        // Linear to sRGB
        rf = (rf <= 0.0031308f) ? 12.92f * rf : 1.055f * powf(rf, 1.0f / 2.4f) - 0.055f;
        gf = (gf <= 0.0031308f) ? 12.92f * gf : 1.055f * powf(gf, 1.0f / 2.4f) - 0.055f;
        bf = (bf <= 0.0031308f) ? 12.92f * bf : 1.055f * powf(bf, 1.0f / 2.4f) - 0.055f;
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
    (void)shader_type; (void)count; (void)source;
    // In Metal, shaders are pre-compiled into .metallib files.
    // This function is called from the Python compile_program() path.
    // For now, return a dummy non-zero value to indicate success.
    static GLuint next_shader_id = 1;
    return next_shader_id++;
}

// ----- Metal Frame Management -----

// Set the current CAMetalLayer for rendering. Called when the OS window is made current.
void
metal_set_current_layer(void *layer) {
    mtl_current_layer = (__bridge CAMetalLayer *)layer;
}

// Get the current Metal device (for external use)
void*
metal_get_device(void) {
    return (__bridge void *)mtl_device;
}

static void
end_current_encoder(void) {
    if (mtl_current_encoder) {
        [mtl_current_encoder endEncoding];
        mtl_current_encoder = nil;
    }
}

static bool
ensure_command_buffer(void) {
    if (!mtl_current_command_buffer) {
        mtl_current_command_buffer = [mtl_command_queue commandBuffer];
        if (!mtl_current_command_buffer) return false;
    }
    return true;
}

static bool
ensure_drawable(void) {
    if (!mtl_current_drawable && mtl_current_layer) {
        CGSize ds = mtl_current_layer.drawableSize;
        if (ds.width < 1 || ds.height < 1) {
            if (mtl_viewport.width > 0 && mtl_viewport.height > 0) {
                mtl_current_layer.drawableSize = CGSizeMake(mtl_viewport.width, mtl_viewport.height);
            } else {
                return false;
            }
        }
        mtl_current_drawable = [mtl_current_layer nextDrawable];
    }
    return mtl_current_drawable != nil;
}

static id<MTLRenderCommandEncoder>
begin_render_pass_to_drawable(bool clear) {
    end_current_encoder();
    if (!ensure_command_buffer()) return nil;

    id<MTLTexture> target_texture = nil;

    // Determine render target: offscreen framebuffer or main drawable
    if (output_framebuffer && output_framebuffer < MAX_FRAMEBUFFERS &&
        framebuffers[output_framebuffer].in_use && framebuffers[output_framebuffer].render_target) {
        target_texture = framebuffers[output_framebuffer].render_target;
    } else {
        if (!ensure_drawable()) return nil;
        target_texture = mtl_current_drawable.texture;
    }
    if (!target_texture) return nil;

    MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
    rpd.colorAttachments[0].texture = target_texture;
    if (clear) {
        rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
        rpd.colorAttachments[0].clearColor = MTLClearColorMake(clear_r, clear_g, clear_b, clear_a);
    } else {
        rpd.colorAttachments[0].loadAction = MTLLoadActionLoad;
    }
    rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
    mtl_current_render_pass = rpd;

    mtl_current_encoder = [mtl_current_command_buffer renderCommandEncoderWithDescriptor:rpd];
    return mtl_current_encoder;
}

void
metal_begin_frame(void) {
    // End any in-progress frame before starting a new one
    end_current_encoder();
    if (mtl_current_command_buffer) {
        if (mtl_current_drawable) {
            [mtl_current_command_buffer presentDrawable:mtl_current_drawable];
        }
        [mtl_current_command_buffer commit];
    }
    mtl_current_command_buffer = nil;
    mtl_current_encoder = nil;
    mtl_current_drawable = nil;
    mtl_current_render_pass = nil;
    clear_pending = false;
}

void
metal_end_frame(void) {
    end_current_encoder();
    if (mtl_current_command_buffer) {
        if (mtl_current_drawable) {
            [mtl_current_command_buffer presentDrawable:mtl_current_drawable];
        }
        [mtl_current_command_buffer commit];
        mtl_current_command_buffer = nil;
        mtl_current_drawable = nil;
    }
    mtl_current_render_pass = nil;
}

// ----- GL Compatibility Functions (metal_gl_*) -----
// These are called via macros defined in metal.h

void metal_gl_enable(GLenum cap) {
    switch (cap) {
        case GL_BLEND: blend_enabled = true; break;
        case GL_FRAMEBUFFER_SRGB: framebuffer_srgb_enabled = true; break;
        case GL_SCISSOR_TEST: scissor_enabled = true; break;
        default: break;
    }
}

void metal_gl_disable(GLenum cap) {
    switch (cap) {
        case GL_BLEND: blend_enabled = false; break;
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
            params[0] = (GLint)output_framebuffer;
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
        bound_textures[active_texture_unit] = id;
        bound_texture_targets[active_texture_unit] = target;
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

void metal_gl_gen_textures(int n, GLuint *ids) {
    for (int i = 0; i < n; i++) {
        if (texture_id_counter < MAX_TEXTURES) {
            ids[i] = texture_id_counter++;
            memset(&textures[ids[i]], 0, sizeof(MetalTexture));
        } else {
            ids[i] = 0;
        }
    }
}

void metal_gl_delete_textures(int n, const GLuint *ids) {
    for (int i = 0; i < n; i++) {
        if (ids[i] && ids[i] < MAX_TEXTURES) {
            textures[ids[i]].texture = nil;
            textures[ids[i]].target = 0;
        }
    }
}

static MTLPixelFormat
pixel_format_for_gl(int internalformat) {
    switch (internalformat) {
        case GL_SRGB_ALPHA: case GL_SRGB8_ALPHA8: return MTLPixelFormatRGBA8Unorm_sRGB;
        case GL_RGBA: case GL_RGBA16: return MTLPixelFormatRGBA16Float;
        case GL_RED: case GL_R8: return MTLPixelFormatR8Unorm;
        case GL_R32UI: return MTLPixelFormatR32Uint;
        case GL_RGB32UI: return MTLPixelFormatRGBA32Uint; // Metal doesn't have RGB32UI
        default: return MTLPixelFormatRGBA8Unorm;
    }
}

void metal_gl_tex_image_2d(GLenum target, int level, int internalformat, int width, int height, int border, GLenum format, GLenum type, const void *data) {
    (void)level; (void)border; (void)format; (void)type;
    GLuint tex_id = get_bound_texture_for_target(target);
    if (tex_id == 0 || tex_id >= MAX_TEXTURES) return;
    MetalTexture *t = &textures[tex_id];

    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pixel_format_for_gl(internalformat)
                                                                                    width:width
                                                                                   height:height
                                                                                mipmapped:NO];
    desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
    desc.storageMode = MTLStorageModeShared;

    t->texture = [mtl_device newTextureWithDescriptor:desc];
    t->target = GL_TEXTURE_2D;
    t->width = width;
    t->height = height;
    t->depth = 1;

    if (data) {
        // Determine bytes per pixel based on format
        NSUInteger bpp = 4;
        if (internalformat == GL_RED || internalformat == GL_R8) bpp = 1;
        else if (internalformat == GL_R32UI) bpp = 4;
        [t->texture replaceRegion:MTLRegionMake2D(0, 0, width, height)
                      mipmapLevel:0
                        withBytes:data
                      bytesPerRow:width * bpp];
    }
}

void metal_gl_tex_sub_image_2d(GLenum target, int level, int x, int y, int width, int height, GLenum format, GLenum type, const void *data) {
    (void)level; (void)type;
    GLuint tex_id = get_bound_texture_for_target(target);
    MetalTexture *t = get_texture(tex_id);
    if (!t || !t->texture || !data) return;

    NSUInteger bpp = 4;
    if (format == GL_RED || format == GL_RED_INTEGER) bpp = 4; // R32UI is 4 bytes
    [t->texture replaceRegion:MTLRegionMake2D(x, y, width, height)
                  mipmapLevel:0
                    withBytes:data
                  bytesPerRow:width * bpp];
}

static int tex_sub_3d_log_count = 0;
void metal_gl_tex_sub_image_3d(GLenum target, int level, int x, int y, int z, int width, int height, int depth, GLenum format, GLenum type, const void *data) {
    (void)level; (void)format; (void)type; (void)depth;
    GLuint tex_id = get_bound_texture_for_target(target);
    MetalTexture *t = get_texture(tex_id);
    if (!t || !t->texture || !data) return;

    NSUInteger bpp = 4;
    [t->texture replaceRegion:MTLRegionMake2D(x, y, width, height)
                  mipmapLevel:0
                        slice:z
                    withBytes:data
                  bytesPerRow:width * bpp
                bytesPerImage:0];
    if (tex_sub_3d_log_count < 5) {
        uint32_t first_pixel = ((const uint32_t*)data)[0];
        FILE *f = fopen("/tmp/kitty_metal_debug.log", "a");
        if (f) { fprintf(f, "tex_sub_3d: id=%u pos=(%d,%d,%d) size=%dx%d first_px=0x%08x tex=%p\n", tex_id, x, y, z, width, height, first_pixel, (__bridge void*)t->texture); fclose(f); }
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

    t->texture = [mtl_device newTextureWithDescriptor:desc];
    t->target = GL_TEXTURE_2D_ARRAY;
    t->width = width;
    t->height = height;
    t->depth = depth;
    {
        FILE *f = fopen("/tmp/kitty_metal_debug.log", "a");
        if (f) { fprintf(f, "tex_storage_3d: id=%u %dx%dx%d fmt=%u tex=%p\n", tex_id, width, height, depth, (unsigned)internalformat, (__bridge void*)t->texture); fclose(f); }
    }
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
    t->texture = [mtl_device newTextureWithDescriptor:desc];
    t->target = GL_TEXTURE_2D;
    t->width = width;
    t->height = height;
    t->depth = 1;

    // Copy from current drawable/render target to the new texture
    id<MTLTexture> source = nil;
    if (output_framebuffer && output_framebuffer < MAX_FRAMEBUFFERS && framebuffers[output_framebuffer].render_target) {
        source = framebuffers[output_framebuffer].render_target;
    } else if (mtl_current_drawable) {
        source = mtl_current_drawable.texture;
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
    [cmd commit];
    [cmd waitUntilCompleted];
}

void metal_gl_gen_framebuffers(int n, GLuint *ids) {
    for (int i = 0; i < n; i++) {
        if (framebuffer_id_counter < MAX_FRAMEBUFFERS) {
            ids[i] = framebuffer_id_counter++;
            framebuffers[ids[i]].in_use = true;
            framebuffers[ids[i]].attached_texture_id = 0;
            framebuffers[ids[i]].render_target = nil;
        } else {
            ids[i] = 0;
        }
    }
}

void metal_gl_delete_framebuffers(int n, const GLuint *ids) {
    for (int i = 0; i < n; i++) {
        if (ids[i] && ids[i] < MAX_FRAMEBUFFERS) {
            framebuffers[ids[i]].in_use = false;
            framebuffers[ids[i]].render_target = nil;
        }
    }
}

void metal_gl_bind_framebuffer(GLenum target, GLuint id) {
    (void)target;
    output_framebuffer = id;
}

void metal_gl_framebuffer_texture_2d(GLenum target, GLenum attachment, GLenum textarget, GLuint texture, int level) {
    (void)target; (void)attachment; (void)textarget; (void)level;
    if (output_framebuffer && output_framebuffer < MAX_FRAMEBUFFERS) {
        framebuffers[output_framebuffer].attached_texture_id = texture;
        MetalTexture *t = get_texture(texture);
        if (t) framebuffers[output_framebuffer].render_target = t->texture;
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
    if (output_framebuffer && output_framebuffer < MAX_FRAMEBUFFERS && framebuffers[output_framebuffer].render_target) {
        source = framebuffers[output_framebuffer].render_target;
    } else if (mtl_current_drawable) {
        source = mtl_current_drawable.texture;
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

// ----- Uniform Stubs -----
// These store values that will be passed to shaders during draw calls.
// For Phase 1, they are no-ops.

void metal_gl_uniform1i(GLint loc, int v) {
    if (current_program >= 0 && loc >= 0 && loc < MAX_UNIFORMS_PER_PROGRAM) {
        uniform_stores[current_program].values[loc].i[0] = v;
        uniform_stores[current_program].dirty = true;
    }
}
void metal_gl_uniform1f(GLint loc, float v) {
    if (current_program >= 0 && loc >= 0 && loc < MAX_UNIFORMS_PER_PROGRAM) {
        uniform_stores[current_program].values[loc].f[0] = v;
        uniform_stores[current_program].dirty = true;
    }
}
void metal_gl_uniform2f(GLint loc, float x, float y) {
    if (current_program >= 0 && loc >= 0 && loc < MAX_UNIFORMS_PER_PROGRAM) {
        uniform_stores[current_program].values[loc].f[0] = x;
        uniform_stores[current_program].values[loc].f[1] = y;
        uniform_stores[current_program].dirty = true;
    }
}
void metal_gl_uniform3f(GLint loc, float x, float y, float z) {
    if (current_program >= 0 && loc >= 0 && loc < MAX_UNIFORMS_PER_PROGRAM) {
        uniform_stores[current_program].values[loc].f[0] = x;
        uniform_stores[current_program].values[loc].f[1] = y;
        uniform_stores[current_program].values[loc].f[2] = z;
        uniform_stores[current_program].dirty = true;
    }
}
void metal_gl_uniform4f(GLint loc, float x, float y, float z, float w) {
    if (current_program >= 0 && loc >= 0 && loc < MAX_UNIFORMS_PER_PROGRAM) {
        uniform_stores[current_program].values[loc].f[0] = x;
        uniform_stores[current_program].values[loc].f[1] = y;
        uniform_stores[current_program].values[loc].f[2] = z;
        uniform_stores[current_program].values[loc].f[3] = w;
        uniform_stores[current_program].dirty = true;
    }
}
void metal_gl_uniform1ui(GLint loc, unsigned v) {
    if (current_program >= 0 && loc >= 0 && loc < MAX_UNIFORMS_PER_PROGRAM) {
        uniform_stores[current_program].values[loc].u[0] = v;
        uniform_stores[current_program].dirty = true;
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
            uniform_stores[current_program].dirty = true;
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
        uniform_stores[current_program].dirty = true;
    }
}
void metal_gl_uniform2fv(GLint loc, int count, const float *v) {
    if (current_program >= 0 && loc >= 0 && loc < MAX_UNIFORMS_PER_PROGRAM) {
        for (int i = 0; i < count * 2 && i < 4; i++) {
            uniform_stores[current_program].values[loc].f[i] = v[i];
        }
        uniform_stores[current_program].dirty = true;
    }
}
void metal_gl_uniform4fv(GLint loc, int count, const float *v) {
    if (current_program >= 0 && loc >= 0 && loc < MAX_UNIFORMS_PER_PROGRAM) {
        for (int i = 0; i < count * 4 && i < 4; i++) {
            uniform_stores[current_program].values[loc].f[i] = v[i];
        }
        uniform_stores[current_program].dirty = true;
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
