/*
 * metal_surface.mm
 * Prototype scaffolding for the macOS Metal renderer.
 *
 * Copyright (C) 2025
 *
 * Distributed under terms of the GPL3 license.
 */

#include "metal_surface.h"

#ifdef __APPLE__

#include "state.h"
#include "fonts.h"
#include "data-types.h"
#include "metal_text_shared.h"
#include "colors.h"
#include "srgb_gamma.h"

#include <math.h>
#include <limits.h>
#include <unistd.h>

#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

typedef struct {
    CAMetalLayer *layer;
    id<MTLCommandQueue> command_queue;
    id<CAMetalDrawable> drawable;
    id<MTLCommandBuffer> command_buffer;
    MTLClearColor clear_color;
    id<MTLBuffer> cell_buffer;
    id<MTLBuffer> selection_buffer;
    id<MTLBuffer> uniform_buffer;
    id<MTLRenderCommandEncoder> encoder;
    NSUInteger cell_buffer_length;
    NSUInteger selection_buffer_length;
    NSUInteger uniform_buffer_length;
    bool buffers_are_managed;
    bool has_active_encoder;
} MetalSurfaceState;

typedef enum {
    MetalCellPipelineFull = 0,
    MetalCellPipelineBackground = 1,
    MetalCellPipelineForeground = 2,
    MetalCellPipelineCount = 3
} MetalCellPipelineKind;

typedef struct {
    bool attempted;
    bool ok;
    id<MTLLibrary> library;
    id<MTLRenderPipelineState> cell_pipelines[MetalCellPipelineCount];
    MTLVertexDescriptor *vertex_descriptor;
    id<MTLSamplerState> glyph_sampler;
    id<MTLSamplerState> decorations_sampler;
} MetalRendererState;

static id<MTLDevice> metal_device = nil;
static MetalRendererState renderer_state = {0};
static NSMapTable *atlas_table = nil;

static inline size_t
align_up(size_t value, size_t alignment) {
    return (value + alignment - 1) & ~(alignment - 1);
}

enum {
    MetalDrawFlagNeither = 0,
    MetalDrawFlagDefault = 1,
    MetalDrawFlagNonDefault = 2,
    MetalDrawFlagBoth = 3,
};

static inline MTLStorageMode
default_storage_mode(void) {
    if (metal_device && [metal_device respondsToSelector:@selector(hasUnifiedMemory)] && [metal_device hasUnifiedMemory]) {
        return MTLStorageModeShared;
    }
    return MTLStorageModeManaged;
}

@interface MetalAtlasStateWrapper : NSObject
@property (nonatomic, strong) id<MTLTexture> glyphTexture;
@property (nonatomic, strong) id<MTLTexture> decorationsTexture;
@property (nonatomic, assign) unsigned glyphWidth;
@property (nonatomic, assign) unsigned glyphHeight;
@property (nonatomic, assign) unsigned glyphLayers;
@property (nonatomic, assign) unsigned spritesX;
@property (nonatomic, assign) unsigned spritesY;
@property (nonatomic, assign) unsigned cellWidth;
@property (nonatomic, assign) unsigned cellHeightPlus1;
@property (nonatomic, assign) unsigned decorationsWidth;
@property (nonatomic, assign) unsigned decorationsHeight;
@end

@implementation MetalAtlasStateWrapper
@end

static NSString*
find_cell_metallib_path(void) {
    NSString *path = [[NSBundle mainBundle] pathForResource:@"cell" ofType:@"metallib" inDirectory:@"kitty/metal"];
    if (!path) path = [[NSBundle mainBundle] pathForResource:@"cell" ofType:@"metallib"];
    if (path) return path;
    const char *env = getenv("KITTY_METAL_LIB");
    if (env && access(env, R_OK) == 0) return [NSString stringWithUTF8String:env];
    const char *fallback = "kitty/metal/cell.metallib";
    if (access(fallback, R_OK) == 0) {
        char resolved[PATH_MAX];
        if (realpath(fallback, resolved)) return [NSString stringWithUTF8String:resolved];
        return [NSString stringWithUTF8String:fallback];
    }
    return nil;
}

static id<MTLFunction>
new_function(id<MTLLibrary> library, NSString *name) {
    id<MTLFunction> fn = [library newFunctionWithName:name];
    if (!fn) log_error("Metal: failed to load function %s from metallib", name.UTF8String);
    return fn;
}

static NSMapTable*
get_atlas_table(void) {
    if (!atlas_table) {
        atlas_table = [[NSMapTable alloc] initWithKeyOptions:NSPointerFunctionsOpaqueMemory | NSPointerFunctionsOpaquePersonality
                                                valueOptions:NSPointerFunctionsStrongMemory
                                                    capacity:0];
    }
    return atlas_table;
}

static MetalAtlasStateWrapper*
atlas_state_for(FONTS_DATA_HANDLE fg, bool create) {
    if (!fg) return nil;
    NSMapTable *table = get_atlas_table();
    NSValue *key = [NSValue valueWithPointer:fg];
    MetalAtlasStateWrapper *wrapper = [table objectForKey:key];
    if (!wrapper && create) {
        wrapper = [[MetalAtlasStateWrapper alloc] init];
        [table setObject:wrapper forKey:key];
        [wrapper release];
    }
    return wrapper;
}

static void
atlas_state_remove(FONTS_DATA_HANDLE fg) {
    if (!atlas_table || !fg) return;
    NSValue *key = [NSValue valueWithPointer:fg];
    [atlas_table removeObjectForKey:key];
}

static inline MTLResourceOptions
buffer_resource_options(const MetalSurfaceState *state) {
    return state->buffers_are_managed ? MTLResourceStorageModeManaged : MTLResourceStorageModeShared;
}

static void*
acquire_metal_buffer(MetalSurfaceState *state, id<MTLBuffer> *slot, NSUInteger *capacity, size_t size, NSString *label) {
    if (!state || !slot || size == 0 || !metal_device) return NULL;
    NSUInteger required = (NSUInteger)size;
    if (*slot == nil || *capacity < required) {
        if (*slot) {
            [*slot release];
            *slot = nil;
        }
        MTLResourceOptions options = buffer_resource_options(state);
        id<MTLBuffer> buffer = [metal_device newBufferWithLength:required options:options];
        if (!buffer) {
            *capacity = 0;
            return NULL;
        }
        buffer.label = label;
        *slot = buffer;
        [buffer release];
        *capacity = required;
    }
    return (*slot).contents;
}

static void
commit_metal_buffer(MetalSurfaceState *state, id<MTLBuffer> buffer, size_t size) {
    if (!state || !buffer || size == 0) return;
    if (state->buffers_are_managed) {
        [buffer didModifyRange:NSMakeRange(0, (NSUInteger)size)];
    }
}

typedef struct {
    MetalSurfaceState *state;
} MetalCellBufferContext;

static void*
metal_acquire_cell_buffer(size_t size, void *user_data) {
    MetalCellBufferContext *ctx = user_data;
    if (!ctx) return NULL;
    return acquire_metal_buffer(ctx->state, &ctx->state->cell_buffer, &ctx->state->cell_buffer_length, size, @"kitty.cell.instances");
}

static void
metal_commit_cell_buffer(void *user_data, void *ptr, size_t size) {
    if (!ptr || size == 0) return;
    MetalCellBufferContext *ctx = user_data;
    commit_metal_buffer(ctx->state, ctx->state->cell_buffer, size);
}

static void*
metal_acquire_selection_buffer(size_t size, void *user_data) {
    MetalCellBufferContext *ctx = user_data;
    if (!ctx) return NULL;
    return acquire_metal_buffer(ctx->state, &ctx->state->selection_buffer, &ctx->state->selection_buffer_length, size, @"kitty.cell.selection");
}

static void
metal_commit_selection_buffer(void *user_data, void *ptr, size_t size) {
    if (!ptr || size == 0) return;
    MetalCellBufferContext *ctx = user_data;
    commit_metal_buffer(ctx->state, ctx->state->selection_buffer, size);
}

static void
destroy_metal_renderer_state(void) {
    for (size_t i = 0; i < MetalCellPipelineCount; i++) {
        if (renderer_state.cell_pipelines[i]) {
            [renderer_state.cell_pipelines[i] release];
            renderer_state.cell_pipelines[i] = nil;
        }
    }
    if (renderer_state.vertex_descriptor) {
        [renderer_state.vertex_descriptor release];
        renderer_state.vertex_descriptor = nil;
    }
    if (renderer_state.library) {
        [renderer_state.library release];
        renderer_state.library = nil;
    }
    if (atlas_table) {
        [atlas_table removeAllObjects];
        [atlas_table release];
        atlas_table = nil;
    }
    if (renderer_state.glyph_sampler) {
        [renderer_state.glyph_sampler release];
        renderer_state.glyph_sampler = nil;
    }
    if (renderer_state.decorations_sampler) {
        [renderer_state.decorations_sampler release];
        renderer_state.decorations_sampler = nil;
    }
    renderer_state.ok = false;
    renderer_state.attempted = false;
}

static bool
ensure_metal_renderer_state(id<MTLDevice> device) {
    if (renderer_state.ok) return true;
    if (renderer_state.attempted) return false;
    renderer_state.attempted = true;

    NSString *metallib_path = find_cell_metallib_path();
    if (!metallib_path) {
        log_error("Metal: could not locate cell.metallib");
        return false;
    }

    NSError *error = nil;
    renderer_state.library = [device newLibraryWithFile:metallib_path error:&error];
    if (!renderer_state.library) {
        log_error("Metal: failed to load metallib at %s (%s)", metallib_path.UTF8String, error.localizedDescription.UTF8String);
        destroy_metal_renderer_state();
        return false;
    }

    MTLVertexDescriptor *vertex_desc = [MTLVertexDescriptor vertexDescriptor];
    vertex_desc.attributes[0].format = MTLVertexFormatUInt3;
    vertex_desc.attributes[0].offset = offsetof(KittyGPUCell, fg);
    vertex_desc.attributes[0].bufferIndex = 0;

    vertex_desc.attributes[1].format = MTLVertexFormatUInt2;
    vertex_desc.attributes[1].offset = offsetof(KittyGPUCell, sprite_idx);
    vertex_desc.attributes[1].bufferIndex = 0;

    vertex_desc.attributes[2].format = MTLVertexFormatUChar;
    vertex_desc.attributes[2].offset = 0;
    vertex_desc.attributes[2].bufferIndex = 1;

    vertex_desc.layouts[0].stride = sizeof(KittyGPUCell);
    vertex_desc.layouts[0].stepRate = 1;
    vertex_desc.layouts[0].stepFunction = MTLVertexStepFunctionPerInstance;

    vertex_desc.layouts[1].stride = sizeof(uint8_t);
    vertex_desc.layouts[1].stepRate = 1;
    vertex_desc.layouts[1].stepFunction = MTLVertexStepFunctionPerInstance;

    renderer_state.vertex_descriptor = [vertex_desc retain];

    struct PipelineSpec {
        NSString *vertex;
        NSString *fragment;
        MetalCellPipelineKind kind;
    };
    const struct PipelineSpec specs[] = {
        { @"cell_vertex_full", @"cell_fragment_full", MetalCellPipelineFull },
        { @"cell_vertex_background", @"cell_fragment_background", MetalCellPipelineBackground },
        { @"cell_vertex_foreground", @"cell_fragment_foreground", MetalCellPipelineForeground },
    };

    for (size_t i = 0; i < arraysz(specs); i++) {
        id<MTLFunction> vertex_fn = new_function(renderer_state.library, specs[i].vertex);
        id<MTLFunction> fragment_fn = new_function(renderer_state.library, specs[i].fragment);
        if (!vertex_fn || !fragment_fn) {
            if (vertex_fn) [vertex_fn release];
            if (fragment_fn) [fragment_fn release];
            destroy_metal_renderer_state();
            return false;
        }

        MTLRenderPipelineDescriptor *descriptor = [[MTLRenderPipelineDescriptor alloc] init];
        descriptor.vertexFunction = vertex_fn;
        descriptor.fragmentFunction = fragment_fn;
        descriptor.vertexDescriptor = renderer_state.vertex_descriptor;
        descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
        descriptor.colorAttachments[0].blendingEnabled = YES;
        descriptor.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
        descriptor.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
        descriptor.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
        descriptor.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        descriptor.label = [NSString stringWithFormat:@"kitty.cell.%@", specs[i].vertex];

        id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
        [descriptor release];
        [vertex_fn release];
        [fragment_fn release];

        if (!pipeline) {
            log_error("Metal: failed to create pipeline %s (%s)", specs[i].vertex.UTF8String, error.localizedDescription.UTF8String);
            destroy_metal_renderer_state();
            return false;
        }
        renderer_state.cell_pipelines[specs[i].kind] = pipeline;
    }

    MTLSamplerDescriptor *glyph_sampler_desc = [[MTLSamplerDescriptor alloc] init];
    glyph_sampler_desc.minFilter = MTLSamplerMinMagFilterNearest;
    glyph_sampler_desc.magFilter = MTLSamplerMinMagFilterNearest;
    glyph_sampler_desc.sAddressMode = MTLSamplerAddressModeClampToEdge;
    glyph_sampler_desc.tAddressMode = MTLSamplerAddressModeClampToEdge;
    glyph_sampler_desc.rAddressMode = MTLSamplerAddressModeClampToEdge;
    glyph_sampler_desc.normalizedCoordinates = YES;
    glyph_sampler_desc.supportArgumentBuffers = YES;
    id<MTLSamplerState> glyph_sampler = [device newSamplerStateWithDescriptor:glyph_sampler_desc];
    [glyph_sampler_desc release];
    if (!glyph_sampler) {
        log_error("Metal: failed to create glyph sampler");
        destroy_metal_renderer_state();
        return false;
    }
    renderer_state.glyph_sampler = glyph_sampler;

    MTLSamplerDescriptor *decor_sampler_desc = [[MTLSamplerDescriptor alloc] init];
    decor_sampler_desc.minFilter = MTLSamplerMinMagFilterNearest;
    decor_sampler_desc.magFilter = MTLSamplerMinMagFilterNearest;
    decor_sampler_desc.sAddressMode = MTLSamplerAddressModeClampToEdge;
    decor_sampler_desc.tAddressMode = MTLSamplerAddressModeClampToEdge;
    decor_sampler_desc.normalizedCoordinates = YES;
    decor_sampler_desc.supportArgumentBuffers = YES;
    id<MTLSamplerState> decor_sampler = [device newSamplerStateWithDescriptor:decor_sampler_desc];
    [decor_sampler_desc release];
    if (!decor_sampler) {
        log_error("Metal: failed to create decorations sampler");
        destroy_metal_renderer_state();
        return false;
    }
    renderer_state.decorations_sampler = decor_sampler;

    renderer_state.ok = true;
    return true;
}

void
metal_sprite_map_resize(FONTS_DATA_HANDLE fg, unsigned int cell_width, unsigned int cell_height_plus1, unsigned int xnum, unsigned int ynum, unsigned int layers) {
    if (!metal_device || !renderer_state.ok) return;
    @autoreleasepool {
        unsigned width = cell_width * xnum;
        unsigned height = cell_height_plus1 * ynum;
        unsigned int layer_count = MAX(1u, layers);
        MetalAtlasStateWrapper *wrapper = atlas_state_for(fg, true);
        if (wrapper.glyphTexture &&
            wrapper.glyphWidth == width &&
            wrapper.glyphHeight == height &&
            wrapper.glyphLayers == layer_count) {
            wrapper.cellWidth = cell_width;
            wrapper.cellHeightPlus1 = cell_height_plus1;
            wrapper.spritesX = xnum;
            wrapper.spritesY = ynum;
            return;
        }
        MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm_sRGB
                                                                                        width:MAX(1u, width)
                                                                                       height:MAX(1u, height)
                                                                                    mipmapped:NO];
        desc.textureType = MTLTextureType2DArray;
        desc.arrayLength = layer_count;
        desc.storageMode = default_storage_mode();
        desc.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> texture = [metal_device newTextureWithDescriptor:desc];
        texture.label = @"kitty.cell.glyphAtlas";
        wrapper.glyphTexture = texture;
        [texture release];
        wrapper.glyphWidth = width;
        wrapper.glyphHeight = height;
        wrapper.glyphLayers = layer_count;
        wrapper.cellWidth = cell_width;
        wrapper.cellHeightPlus1 = cell_height_plus1;
        wrapper.spritesX = xnum;
        wrapper.spritesY = ynum;
    }
}

void
metal_sprite_decorations_resize(FONTS_DATA_HANDLE fg, unsigned int width, unsigned int height) {
    if (!metal_device || !renderer_state.ok) return;
    @autoreleasepool {
        MetalAtlasStateWrapper *wrapper = atlas_state_for(fg, true);
        if (wrapper.decorationsTexture &&
            wrapper.decorationsWidth == width &&
            wrapper.decorationsHeight == height) {
            return;
        }
        MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Uint
                                                                                        width:MAX(1u, width)
                                                                                       height:MAX(1u, height)
                                                                                    mipmapped:NO];
        desc.storageMode = default_storage_mode();
        desc.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> texture = [metal_device newTextureWithDescriptor:desc];
        texture.label = @"kitty.cell.decorations";
        wrapper.decorationsTexture = texture;
        [texture release];
        wrapper.decorationsWidth = width;
        wrapper.decorationsHeight = height;
    }
}

void
metal_sprite_upload(FONTS_DATA_HANDLE fg, sprite_index idx, const pixel *buf, sprite_index decoration_idx) {
    if (!metal_device || !renderer_state.ok) return;
    @autoreleasepool {
        MetalAtlasStateWrapper *wrapper = atlas_state_for(fg, false);
        if (!wrapper) return;

        unsigned int xnum = 0, ynum = 0, z_index = 0;
        sprite_tracker_current_layout(fg, &xnum, &ynum, &z_index);
        unsigned int requested_layers = z_index + 1;
        unsigned cell_width = wrapper.cellWidth ? wrapper.cellWidth : fg->fcm.cell_width;
        unsigned cell_height_plus1 = wrapper.cellHeightPlus1 ? wrapper.cellHeightPlus1 : (fg->fcm.cell_height + 1);
        if (!wrapper.glyphTexture ||
            wrapper.glyphWidth != cell_width * xnum ||
            wrapper.glyphHeight != cell_height_plus1 * ynum ||
            wrapper.glyphLayers < requested_layers) {
            metal_sprite_map_resize(fg, cell_width, cell_height_plus1, xnum, ynum, requested_layers);
            wrapper = atlas_state_for(fg, false);
            if (!wrapper || !wrapper.glyphTexture) return;
        }
        unsigned decorations_width = wrapper.decorationsWidth;
        if (!wrapper.decorationsTexture || decorations_width == 0) return;

        unsigned glyph_x = 0, glyph_y = 0, glyph_z = 0;
        sprite_index_to_pos(idx, xnum, ynum, &glyph_x, &glyph_y, &glyph_z);
        NSUInteger pixelX = (NSUInteger)glyph_x * wrapper.cellWidth;
        NSUInteger pixelY = (NSUInteger)glyph_y * wrapper.cellHeightPlus1;
        MTLRegion glyphRegion = MTLRegionMake3D(pixelX, pixelY, glyph_z, wrapper.cellWidth, wrapper.cellHeightPlus1, 1);
        NSUInteger bytesPerRow = wrapper.cellWidth * sizeof(pixel);
        NSUInteger bytesPerImage = bytesPerRow * wrapper.cellHeightPlus1;
        [wrapper.glyphTexture replaceRegion:glyphRegion
                                 mipmapLevel:0
                                      slice:glyph_z
                                   withBytes:buf
                                 bytesPerRow:bytesPerRow
                               bytesPerImage:bytesPerImage];

        div_t d = div((int)idx, (int)decorations_width);
        NSUInteger decorX = MAX(0, d.rem);
        NSUInteger decorY = MAX(0, d.quot);
        if (decorY >= wrapper.decorationsHeight) return;
        uint32_t deco = decoration_idx;
        MTLRegion decorRegion = MTLRegionMake2D(decorX, decorY, 1, 1);
        [wrapper.decorationsTexture replaceRegion:decorRegion mipmapLevel:0 withBytes:&deco bytesPerRow:sizeof(uint32_t)];
    }
}

void
metal_sprite_free(FONTS_DATA_HANDLE fg) {
    @autoreleasepool {
        atlas_state_remove(fg);
    }
}

bool
metal_prepare_cell_buffers(Screen *screen, OSWindow *window) {
    if (!screen || !window || !window->fonts_data || !metal_device || !renderer_state.ok) return false;
    MetalSurfaceState *state = get_surface_state(window);
    if (!state) return false;
    MetalCellBufferContext ctx = { .state = state };
    const CellBufferWriters writers = {
        .acquire_cell_buffer = metal_acquire_cell_buffer,
        .commit_cell_buffer = metal_commit_cell_buffer,
        .acquire_selection_buffer = metal_acquire_selection_buffer,
        .commit_selection_buffer = metal_commit_selection_buffer,
    };
    return cell_prepare_buffers_with_writers(screen, window->fonts_data, &writers, &ctx);
}

static id<MTLRenderCommandEncoder>
ensure_render_encoder(MetalSurfaceState *state) {
    if (!state || !state->command_buffer || !state->drawable) return nil;
    if (state->encoder == nil) {
        MTLRenderPassDescriptor *descriptor = [MTLRenderPassDescriptor renderPassDescriptor];
        descriptor.colorAttachments[0].texture = state->drawable.texture;
        descriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
        descriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
        descriptor.colorAttachments[0].clearColor = state->clear_color;
        id<MTLRenderCommandEncoder> encoder = [state->command_buffer renderCommandEncoderWithDescriptor:descriptor];
        if (!encoder) return nil;
        state->encoder = [encoder retain];
        state->has_active_encoder = true;
    }
    return state->encoder;
}

static inline bool
has_background_image(const OSWindow *os_window) {
    return os_window->bgimage && os_window->bgimage->texture_id > 0;
}

void
metal_draw_cells(const WindowRenderData *srd, OSWindow *os_window, bool is_active_window, bool is_tab_bar, bool is_single_window, Window *window) {
    (void)window;
    if (!srd || !os_window || !os_window->fonts_data) return;
    Screen *screen = srd->screen;
    if (!screen) return;

    MetalSurfaceState *state = get_surface_state(os_window);
    if (!state || !state->command_buffer || !state->drawable) return;

    MetalAtlasStateWrapper *atlas = atlas_state_for(os_window->fonts_data, false);
    if (!atlas || !atlas.glyphTexture || !atlas.decorationsTexture) return;

    NSUInteger instance_count = (NSUInteger)screen->lines * (NSUInteger)screen->columns;
    if (instance_count == 0) return;

    id<MTLRenderCommandEncoder> encoder = ensure_render_encoder(state);
    if (!encoder) return;

    size_t uniform_size = sizeof(KittyCellUniforms);
    size_t aligned_uniform_size = align_up(uniform_size, 256);
    KittyCellUniforms *uniforms = (KittyCellUniforms*)acquire_metal_buffer(state, &state->uniform_buffer, &state->uniform_buffer_length, aligned_uniform_size, @"kitty.cell.uniforms");
    if (!uniforms) return;

    float current_inactive_text_alpha = (is_tab_bar || (!is_single_window && is_active_window) || (is_single_window && screen->cursor_render_info.is_focused)) ? 1.0f : (float)OPT(inactive_text_alpha);
    float bg_alpha = effective_os_window_alpha(os_window);
    ColorProfile *cp = NULL;
    color_type default_bg = populate_cell_uniforms(screen, &screen->cursor_render_info, os_window, current_inactive_text_alpha, bg_alpha, uniforms, &cp);
    if (cp) {
        if (cp->dirty || screen->reload_all_gpu_data) copy_color_table_to_buffer(cp, (color_type*)uniforms->color_table, 0, 1);
        cp->dirty = false;
    }
    for (size_t i = 0; i < KITTY_GAMMA_LUT_SIZE; i++) uniforms->gamma_lut[i] = srgb_lut[i];
    uniforms->draw_bg_bitfield = has_background_image(os_window) ? MetalDrawFlagNonDefault : MetalDrawFlagBoth;
    uniforms->bg_colors[0] = default_bg;
    commit_metal_buffer(state, state->uniform_buffer, uniform_size);

    if (!state->cell_buffer || !state->selection_buffer) return;

    NSUInteger framebuffer_height = (NSUInteger)os_window->viewport_height;
    NSUInteger viewport_width = (NSUInteger)(srd->geometry.right - srd->geometry.left);
    NSUInteger viewport_height = (NSUInteger)(srd->geometry.bottom - srd->geometry.top);
    if (viewport_width == 0 || viewport_height == 0) return;
    NSUInteger origin_x = (NSUInteger)srd->geometry.left;
    NSUInteger origin_y = framebuffer_height - (NSUInteger)(srd->geometry.top + viewport_height);

    MTLViewport viewport = {
        .originX = origin_x,
        .originY = origin_y,
        .width = viewport_width,
        .height = viewport_height,
        .znear = 0.0,
        .zfar = 1.0,
    };
    [encoder setViewport:viewport];
    MTLScissorRect scissor = { origin_x, origin_y, viewport_width, viewport_height };
    [encoder setScissorRect:scissor];

    [encoder setRenderPipelineState:renderer_state.cell_pipelines[MetalCellPipelineFull]];
    [encoder setVertexBuffer:state->cell_buffer offset:0 atIndex:0];
    [encoder setVertexBuffer:state->selection_buffer offset:0 atIndex:1];
    [encoder setVertexBuffer:state->uniform_buffer offset:0 atIndex:2];
    [encoder setFragmentBuffer:state->uniform_buffer offset:0 atIndex:2];
    [encoder setFragmentTexture:atlas.glyphTexture atIndex:0];
    [encoder setFragmentSamplerState:renderer_state.glyph_sampler atIndex:0];
    [encoder setVertexTexture:atlas.decorationsTexture atIndex:1];
    [encoder setVertexSamplerState:renderer_state.decorations_sampler atIndex:1];

    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4 instanceCount:instance_count];

    screen->reload_all_gpu_data = false;
}

static inline MetalSurfaceState*
get_surface_state(OSWindow *window) {
    return window && window->metal_surface ? (MetalSurfaceState*)window->metal_surface : NULL;
}

static inline MTLClearColor
clear_color_from_srgb(unsigned int color_in_srgb, float background_opacity) {
    const double opacity = fmax(0.0, fmin((double)background_opacity, 1.0));
    const double scale = opacity / 255.0;
    const double r = ((color_in_srgb >> 16) & 0xFF) * scale;
    const double g = ((color_in_srgb >> 8) & 0xFF) * scale;
    const double b = (color_in_srgb & 0xFF) * scale;
    return MTLClearColorMake(r, g, b, opacity);
}

bool
metal_backend_available(void) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (device != nil) {
            [device release];
            return true;
        }
        return false;
    }
}

bool
metal_backend_init(OSWindow *window) {
    if (window == NULL) return false;
    @autoreleasepool {
        if (metal_device == nil) {
            metal_device = MTLCreateSystemDefaultDevice();
            if (metal_device == nil) {
                log_error("Metal backend unavailable: failed to acquire default Metal device.");
                return false;
            }
        }
        NSWindow *ns_window = (NSWindow *)glfwGetCocoaWindow(window->handle);
        if (ns_window == nil) {
            log_error("Metal backend unavailable: failed to obtain NSWindow.");
            return false;
        }
        NSView *content_view = [ns_window contentView];
        if (content_view == nil) {
            log_error("Metal backend unavailable: NSWindow has no content view.");
            return false;
        }

        metal_teardown_surface(window);

        MetalSurfaceState *state = (MetalSurfaceState*)calloc(1, sizeof(MetalSurfaceState));
        if (state == NULL) {
            log_error("Metal backend unavailable: failed to allocate surface state.");
            return false;
        }
        state->buffers_are_managed = default_storage_mode() == MTLStorageModeManaged;

        CAMetalLayer *layer = [CAMetalLayer layer];
        if (layer == nil) {
            free(state);
            log_error("Metal backend unavailable: failed to create CAMetalLayer.");
            return false;
        }
        [layer retain];
        layer.device = metal_device;
        layer.pixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
        layer.framebufferOnly = YES;
        layer.presentsWithTransaction = NO;
        layer.displaySyncEnabled = YES;
        layer.contentsScale = ns_window.backingScaleFactor;
        CGSize drawable_size = CGSizeMake(MAX(1, window->viewport_width ? window->viewport_width : window->window_width),
                                          MAX(1, window->viewport_height ? window->viewport_height : window->window_height));
        layer.drawableSize = drawable_size;

        content_view.wantsLayer = YES;
        content_view.layer = layer;

        id<MTLCommandQueue> queue = [metal_device newCommandQueue];
        if (queue == nil) {
            [layer removeFromSuperlayer];
            [layer release];
            free(state);
            log_error("Metal backend unavailable: failed to create command queue.");
            return false;
        }

        if (!ensure_metal_renderer_state(metal_device)) {
            [queue release];
            [layer removeFromSuperlayer];
            [layer release];
            free(state);
            log_error("Metal backend unavailable: failed to initialize render pipelines.");
            return false;
        }

        state->layer = layer;
        state->command_queue = queue;
        state->clear_color = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
        window->metal_surface = state;
        window->metal_backend_active = true;
        return true;
    }
}

void
metal_backend_shutdown(void) {
    @autoreleasepool {
        if (metal_device != nil) {
            [metal_device release];
            metal_device = nil;
        }
        destroy_metal_renderer_state();
    }
}

bool
metal_begin_frame(OSWindow *window, float background_opacity, unsigned int color_in_srgb) {
    MetalSurfaceState *state = get_surface_state(window);
    if (state == NULL) return false;
    @autoreleasepool {
        if (state->encoder != nil) {
            [state->encoder release];
            state->encoder = nil;
        }
        state->has_active_encoder = false;
        if (state->command_buffer != nil) {
            [state->command_buffer release];
            state->command_buffer = nil;
        }
        if (state->drawable != nil) {
            [state->drawable release];
            state->drawable = nil;
        }

        CGSize drawable_size = CGSizeMake(
            MAX(1, window->viewport_width ? window->viewport_width : window->window_width),
            MAX(1, window->viewport_height ? window->viewport_height : window->window_height)
        );
        state->layer.drawableSize = drawable_size;
        NSWindow *ns_window = (NSWindow *)glfwGetCocoaWindow(window->handle);
        if (ns_window != nil) {
            state->layer.contentsScale = ns_window.backingScaleFactor;
        }

        id<CAMetalDrawable> drawable = [state->layer nextDrawable];
        if (drawable == nil) {
            log_error("Metal backend failed to acquire drawable.");
            return false;
        }
        [drawable retain];
        state->drawable = drawable;

        id<MTLCommandBuffer> command_buffer = [state->command_queue commandBuffer];
        if (command_buffer == nil) {
            log_error("Metal backend failed to create command buffer.");
            [drawable release];
            state->drawable = nil;
            return false;
        }
        [command_buffer retain];
        state->command_buffer = command_buffer;
        state->clear_color = clear_color_from_srgb(color_in_srgb, background_opacity);
        return true;
    }
}

void
metal_end_frame(OSWindow *window) {
    MetalSurfaceState *state = get_surface_state(window);
    if (state == NULL) return;
    @autoreleasepool {
        if (state->encoder != nil) {
            [state->encoder endEncoding];
            [state->encoder release];
            state->encoder = nil;
        }
        state->has_active_encoder = false;
        if (state->command_buffer != nil && state->drawable != nil) {
            [state->command_buffer presentDrawable:state->drawable];
            [state->command_buffer commit];
        }
        if (state->command_buffer != nil) {
            [state->command_buffer release];
            state->command_buffer = nil;
        }
        if (state->drawable != nil) {
            [state->drawable release];
            state->drawable = nil;
        }
    }
}

void
metal_teardown_surface(OSWindow *window) {
    MetalSurfaceState *state = get_surface_state(window);
    if (state == NULL) return;
    @autoreleasepool {
        if (state->command_buffer != nil) {
            [state->command_buffer release];
            state->command_buffer = nil;
        }
        if (state->drawable != nil) {
            [state->drawable release];
            state->drawable = nil;
        }
        if (state->encoder != nil) {
            [state->encoder release];
            state->encoder = nil;
        }
        if (state->command_queue != nil) {
            [state->command_queue release];
            state->command_queue = nil;
        }
        if (state->layer != nil) {
            [state->layer removeFromSuperlayer];
            [state->layer release];
            state->layer = nil;
        }
        if (state->uniform_buffer != nil) {
            [state->uniform_buffer release];
            state->uniform_buffer = nil;
        }
        if (state->cell_buffer != nil) {
            [state->cell_buffer release];
            state->cell_buffer = nil;
        }
        if (state->selection_buffer != nil) {
            [state->selection_buffer release];
            state->selection_buffer = nil;
        }
        state->cell_buffer_length = 0;
        state->selection_buffer_length = 0;
        state->uniform_buffer_length = 0;
        state->has_active_encoder = false;
        free(state);
        window->metal_surface = NULL;
        window->metal_backend_active = false;
    }
}

#else

bool
metal_backend_available(void) { return false; }

bool
metal_backend_init(OSWindow *window) {
    (void)window;
    return false;
}

void
metal_backend_shutdown(void) {}

bool
metal_begin_frame(OSWindow *window) {
    (void)window;
    return false;
}

void
metal_end_frame(OSWindow *window) {
    (void)window;
}

void
metal_teardown_surface(OSWindow *window) {
    (void)window;
}

#endif
