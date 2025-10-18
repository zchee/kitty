#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#import <simd/simd.h>

#include <math.h>
#include <stdbool.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>

#ifdef MAX
#undef MAX
#endif
#ifdef MIN
#undef MIN
#endif

#include "glfw-wrapper.h"
#include "metal_renderer.h"
#include "renderer_backend.h"
#include "renderer_backend_types.h"
#include "renderer_shared.h"
#include "fonts.h"
#include "data-types.h"
#include "line.h"
#include "state.h"

extern void log_error(const char *fmt, ...);

enum {
    MetalCellNumColors = 256,
    MetalCellColorTableEntries = MetalCellNumColors + MARK_MASK + MARK_MASK + 2,
};

typedef struct {
    float use_cell_bg_for_selection_fg;
    float use_cell_fg_for_selection_color;
    float use_cell_for_selection_bg;

    unsigned int default_fg;
    unsigned int highlight_fg;
    unsigned int highlight_bg;
    unsigned int main_cursor_fg;
    unsigned int main_cursor_bg;
    unsigned int url_color;
    unsigned int url_style;
    unsigned int inverted;
    unsigned int extra_cursor_fg;
    unsigned int extra_cursor_bg;

    unsigned int columns;
    unsigned int lines;
    unsigned int sprites_xnum;
    unsigned int sprites_ynum;
    unsigned int cursor_shape;
    unsigned int cell_width;
    unsigned int cell_height;
    unsigned int cursor_x1;
    unsigned int cursor_x2;
    unsigned int cursor_y1;
    unsigned int cursor_y2;
    float cursor_opacity;
    float inactive_text_alpha;
    float dim_opacity;
    float blink_opacity;

    unsigned int bg_colors0;
    unsigned int bg_colors1;
    unsigned int bg_colors2;
    unsigned int bg_colors3;
    unsigned int bg_colors4;
    unsigned int bg_colors5;
    unsigned int bg_colors6;
    unsigned int bg_colors7;
    float bg_opacities0;
    float bg_opacities1;
    float bg_opacities2;
    float bg_opacities3;
    float bg_opacities4;
    float bg_opacities5;
    float bg_opacities6;
    float bg_opacities7;
    unsigned int color_table[MetalCellColorTableEntries];
} MetalCellUniformData;

typedef struct {
    float text_contrast;
    float text_gamma_adjustment;
    uint32_t decorations_count;
    uint32_t padding;
    float viewport_scale_x;
    float viewport_scale_y;
    float viewport_origin_x;
    float viewport_origin_y;
} MetalDrawParams;

typedef struct {
    float rect[4];
    uint32_t color;
    uint32_t _pad[3];
} MetalBorderRect;

static inline size_t
metal_aligned_buffer_length(size_t size) {
    const size_t alignment = 0x100;
    return ((size + alignment - 1) / alignment) * alignment;
}

@class MetalWindowState;

static void
metal_log(const char *event, const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    char detail[256];
    vsnprintf(detail, sizeof(detail), fmt, args);
    va_end(args);
    log_error("metal_event=%s %s", event, detail);
}

bool
metal_compute_viewport_params(
    unsigned int framebuffer_width,
    unsigned int framebuffer_height,
    unsigned int left,
    unsigned int top,
    unsigned int right,
    unsigned int bottom,
    float *out_scale_x,
    float *out_scale_y,
    float *out_origin_x,
    float *out_origin_y
) {
    if (!out_scale_x || !out_scale_y || !out_origin_x || !out_origin_y) {
        return false;
    }
    if (!framebuffer_width || !framebuffer_height) {
        return false;
    }
    if (left >= right || top >= bottom) {
        return false;
    }
    const float fb_w = (float)framebuffer_width;
    const float fb_h = (float)framebuffer_height;
    const float left_ndc = (2.0f * (float)left / fb_w) - 1.0f;
    const float right_ndc = (2.0f * (float)right / fb_w) - 1.0f;
    const float top_ndc = 1.0f - (2.0f * (float)top / fb_h);
    const float bottom_ndc = 1.0f - (2.0f * (float)bottom / fb_h);
    const float scale_x = (right_ndc - left_ndc) * 0.5f;
    const float scale_y = (top_ndc - bottom_ndc) * 0.5f;
    if (scale_x == 0.f || scale_y == 0.f) {
        return false;
    }
    *out_scale_x = scale_x;
    *out_scale_y = scale_y;
    *out_origin_x = (right_ndc + left_ndc) * 0.5f;
    *out_origin_y = (top_ndc + bottom_ndc) * 0.5f;
    return true;
}

typedef struct {
    id<MTLDevice> device;
    id<MTLCommandQueue> command_queue;
    id<MTLLibrary> library;
    id<MTLRenderPipelineState> cell_pipeline;
    id<MTLRenderPipelineState> border_pipeline;
    id<MTLRenderPipelineState> trail_pipeline;
    id<MTLSamplerState> atlas_sampler;
    bool initialized;
    bool prefer_low_latency;
    bool debug_labels;
    bool display_sync_enabled;
} MetalGlobalState;

static MetalGlobalState g_metal = {
    .device = nil,
    .command_queue = nil,
    .library = nil,
    .cell_pipeline = nil,
    .border_pipeline = nil,
    .trail_pipeline = nil,
    .atlas_sampler = nil,
    .initialized = false,
    .prefer_low_latency = false,
    .debug_labels = false,
    .display_sync_enabled = true,
};

typedef struct {
    id<MTLTexture> spriteTexture;
    id<MTLBuffer> decorationsBuffer;
    NSUInteger spriteWidth;
    NSUInteger spriteHeight;
    NSUInteger spriteLayers;
    NSUInteger decorationsCapacity;
    NSUInteger decorationsCount;
} MetalSpriteAtlas;

static bool sprite_hooks_registered = false;

@interface MetalWindowState : NSObject
@property (nonatomic, strong) CAMetalLayer *layer;
@property (nonatomic, strong) id<CAMetalDrawable> drawable;
@property (nonatomic, strong) id<MTLCommandBuffer> commandBuffer;
@property (nonatomic) BOOL frameHasContent;
@property (nonatomic) MTLClearColor clearColor;
@property (nonatomic) float backgroundOpacity;
@property (nonatomic) color_type fallbackBackground;
@property (nonatomic, strong) id closeObserver;
@property (nonatomic) RendererSharedFrameResult sharedFrame;
@property (nonatomic, strong) id<MTLBuffer> cellBuffer;
@property (nonatomic) size_t cellBufferCapacity;
@property (nonatomic) size_t cellBufferLength;
@property (nonatomic, strong) id<MTLBuffer> selectionBuffer;
@property (nonatomic) size_t selectionBufferCapacity;
@property (nonatomic) size_t selectionBufferLength;
@property (nonatomic, strong) id<MTLBuffer> uniformBuffer;
@property (nonatomic) size_t uniformBufferCapacity;
@property (nonatomic) size_t uniformBufferLength;
@property (nonatomic, strong) id<MTLBuffer> borderBuffer;
@property (nonatomic) size_t borderBufferCapacity;
@property (nonatomic) size_t borderCount;
@property (nonatomic) MetalDrawParams drawParams;
@end

static bool ensure_command_primitives(GLFWwindow *window, MetalWindowState *state);
static void encode_draw_end(id<MTLRenderCommandEncoder> encoder);
static void set_preflight_failure(const char *reason);
static MTLClearColor clear_color_from(color_type color, float alpha);
static bool metal_encode_cells(GLFWwindow *window, MetalWindowState *state, MetalSpriteAtlas *atlas, size_t instance_count);
static bool encode_clear_pass(GLFWwindow *window, MetalWindowState *state, MTLClearColor clear_color);

static void *
metal_shared_buffer_map(RendererSharedBufferType type, size_t size, void *user) {
    MetalWindowState *state = (__bridge MetalWindowState *)user;
    if (!state || size == 0 || !g_metal.device) {
        return NULL;
    }
    size_t required = metal_aligned_buffer_length(size);
    switch (type) {
        case RENDERER_SHARED_BUFFER_CELL_DATA: {
            if (!state.cellBuffer || state.cellBufferCapacity < required) {
                id<MTLBuffer> buffer = [g_metal.device newBufferWithLength:required options:MTLResourceStorageModeShared];
                if (!buffer) {
                    PyErr_SetString(PyExc_RuntimeError, "Metal failed to allocate shared buffer");
                    return NULL;
                }
                state.cellBuffer = buffer;
                state.cellBufferCapacity = required;
            }
            state.cellBufferLength = size;
            return state.cellBuffer.contents;
        }
        case RENDERER_SHARED_BUFFER_SELECTIONS: {
            if (!state.selectionBuffer || state.selectionBufferCapacity < required) {
                id<MTLBuffer> buffer = [g_metal.device newBufferWithLength:required options:MTLResourceStorageModeShared];
                if (!buffer) {
                    PyErr_SetString(PyExc_RuntimeError, "Metal failed to allocate shared buffer");
                    return NULL;
                }
                state.selectionBuffer = buffer;
                state.selectionBufferCapacity = required;
            }
            state.selectionBufferLength = size;
            return state.selectionBuffer.contents;
        }
        case RENDERER_SHARED_BUFFER_UNIFORMS:
            return NULL;
    }
    return NULL;
}

static void
metal_shared_buffer_unmap(RendererSharedBufferType type, void *ptr, size_t size, void *user) {
    (void)ptr;
    (void)size;
    MetalWindowState *state = (__bridge MetalWindowState *)user;
    if (!state) return;
    switch (type) {
        case RENDERER_SHARED_BUFFER_CELL_DATA:
            if (state.cellBuffer.storageMode == MTLStorageModeManaged) {
                [state.cellBuffer didModifyRange:NSMakeRange(0, state.cellBufferLength)];
            }
            break;
        case RENDERER_SHARED_BUFFER_SELECTIONS:
            if (state.selectionBuffer.storageMode == MTLStorageModeManaged) {
                [state.selectionBuffer didModifyRange:NSMakeRange(0, state.selectionBufferLength)];
            }
            break;
        case RENDERER_SHARED_BUFFER_UNIFORMS:
            break;
    }
}
static void metal_configure_border_uniforms(
    MetalBorderUniforms *uniforms,
    color_type default_bg,
    color_type active_border_color,
    color_type inactive_border_color,
    color_type bell_border_color,
    color_type tab_bar_background,
    color_type tab_bar_margin_color,
    color_type tab_bar_edge_left,
    color_type tab_bar_edge_right,
    float background_opacity
) {
    uniforms->colors[0] = default_bg;
    uniforms->colors[1] = active_border_color;
    uniforms->colors[2] = inactive_border_color;
    uniforms->colors[3] = 0;
    uniforms->colors[4] = bell_border_color;
    uniforms->colors[5] = tab_bar_background;
    uniforms->colors[6] = tab_bar_margin_color;
    uniforms->colors[7] = tab_bar_edge_left;
    uniforms->colors[8] = tab_bar_edge_right;
    uniforms->background_opacity = background_opacity;
    uniforms->_pad[0] = 0.f;
    uniforms->_pad[1] = 0.f;
}

static void
metal_set_trail_uniforms(
    MetalTrailUniforms *uniforms,
    const float corner_x[4],
    const float corner_y[4],
    const float cursor_edge_x[2],
    const float cursor_edge_y[2],
    color_type color,
    float opacity
) {
    for (int i = 0; i < 4; i++) {
        uniforms->x_coords[i] = corner_x[i];
        uniforms->y_coords[i] = corner_y[i];
    }
    uniforms->cursor_edge_x[0] = cursor_edge_x[0];
    uniforms->cursor_edge_x[1] = cursor_edge_x[1];
    uniforms->cursor_edge_y[0] = cursor_edge_y[0];
    uniforms->cursor_edge_y[1] = cursor_edge_y[1];
    uniforms->color = color;
    uniforms->opacity = opacity;
    uniforms->_pad[0] = 0.f;
    uniforms->_pad[1] = 0.f;
}

static MetalSpriteAtlas*
metal_font_atlas(FONTS_DATA_HANDLE fg) {
    MetalSpriteAtlas *atlas = (MetalSpriteAtlas *)fg->metal_sprite_map;
    if (!atlas) {
        atlas = calloc(1, sizeof(MetalSpriteAtlas));
        if (!atlas) {
            PyErr_NoMemory();
            return NULL;
        }
        fg->metal_sprite_map = atlas;
    }
    return atlas;
}

static void
metal_release_font_atlas(FONTS_DATA_HANDLE fg) {
    MetalSpriteAtlas *atlas = (MetalSpriteAtlas *)fg->metal_sprite_map;
    if (!atlas) return;
    atlas->spriteTexture = nil;
    atlas->decorationsBuffer = nil;
    atlas->decorationsCapacity = 0;
    atlas->decorationsCount = 0;
    free(atlas);
    fg->metal_sprite_map = NULL;
}

static bool
ensure_sprite_texture_capacity(MetalSpriteAtlas *atlas, NSUInteger width, NSUInteger height, NSUInteger layers) {
    if (atlas->spriteTexture && width <= atlas->spriteWidth && height <= atlas->spriteHeight && layers <= atlas->spriteLayers) {
        return true;
    }
    if (!g_metal.device || !g_metal.command_queue) {
        metal_log("sprite_texture_alloc_failed", "Metal device or command queue unavailable");
        return false;
    }
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:width height:height mipmapped:NO];
    descriptor.textureType = MTLTextureType2DArray;
    descriptor.arrayLength = layers;
    descriptor.storageMode = MTLStorageModeManaged;
    descriptor.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> newTexture = [g_metal.device newTextureWithDescriptor:descriptor];
    if (!newTexture) {
        metal_log("sprite_texture_alloc_failed", "width=%lu height=%lu layers=%lu", (unsigned long)width, (unsigned long)height, (unsigned long)layers);
        PyErr_SetString(PyExc_RuntimeError, "Metal failed to allocate sprite texture");
        return false;
    }
    if (atlas->spriteTexture) {
        NSUInteger copyWidth = MIN(width, atlas->spriteWidth);
        NSUInteger copyHeight = MIN(height, atlas->spriteHeight);
        NSUInteger sliceCount = MIN(layers, atlas->spriteLayers);
        if (copyWidth && copyHeight && sliceCount) {
            id<MTLCommandBuffer> cb = [g_metal.command_queue commandBuffer];
            id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
            MTLSize size = MTLSizeMake(copyWidth, copyHeight, 1);
            MTLOrigin origin = MTLOriginMake(0, 0, 0);
            for (NSUInteger slice = 0; slice < sliceCount; slice++) {
                [blit copyFromTexture:atlas->spriteTexture
                          sourceSlice:slice
                          sourceLevel:0
                         sourceOrigin:origin
                           sourceSize:size
                            toTexture:newTexture
                     destinationSlice:slice
                     destinationLevel:0
                    destinationOrigin:origin];
            }
            [blit endEncoding];
            [cb commit];
            [cb waitUntilCompleted];
        }
    }
    atlas->spriteTexture = newTexture;
    atlas->spriteWidth = width;
    atlas->spriteHeight = height;
    atlas->spriteLayers = layers;
    return true;
}

static bool
ensure_decorations_buffer_capacity(MetalSpriteAtlas *atlas, NSUInteger neededCapacity) {
    if (atlas->decorationsCapacity >= neededCapacity) {
        return true;
    }
    if (!g_metal.device) {
        metal_log("decorations_buffer_alloc_failed", "Metal device unavailable");
        return false;
    }
    NSUInteger newCapacity = neededCapacity + 256;
    id<MTLBuffer> newBuffer = [g_metal.device newBufferWithLength:newCapacity * sizeof(uint32_t) options:MTLResourceStorageModeShared];
    if (!newBuffer) {
        metal_log("decorations_buffer_alloc_failed", "capacity=%lu", (unsigned long)newCapacity);
        PyErr_SetString(PyExc_RuntimeError, "Metal failed to allocate decorations buffer");
        return false;
    }
    if (atlas->decorationsBuffer) {
        memcpy([newBuffer contents], [atlas->decorationsBuffer contents], atlas->decorationsCapacity * sizeof(uint32_t));
    }
    atlas->decorationsBuffer = newBuffer;
    atlas->decorationsCapacity = newCapacity;
    return true;
}

static void
metal_sprite_upload(FONTS_DATA_HANDLE fg, sprite_index idx, const pixel *buf, DecorationMetadata dec, FontCellMetrics metrics) {
    if (!g_metal.initialized) return;
    MetalSpriteAtlas *atlas = metal_font_atlas(fg);
    if (!atlas) return;
    unsigned xnum = 0, ynum = 0, zmax = 0;
    sprite_tracker_current_layout(fg, &xnum, &ynum, &zmax);
    NSUInteger layers = (NSUInteger)zmax + 1;
    if (!layers) return;
    const NSUInteger cellWidth = metrics.cell_width;
    const NSUInteger cellHeightPlusOne = metrics.cell_height + 1;
    if (!cellWidth || !cellHeightPlusOne) return;
    NSUInteger width = (NSUInteger)xnum * cellWidth;
    NSUInteger height = (NSUInteger)ynum * cellHeightPlusOne;
    if (!width || !height) return;
    if (!ensure_sprite_texture_capacity(atlas, width, height, layers)) return;
    unsigned x = 0, y = 0, z = 0;
    sprite_index_to_pos(idx, xnum, ynum, &x, &y, &z);
    if (z >= layers) return;
    MTLRegion region = MTLRegionMake3D((NSUInteger)x * cellWidth, (NSUInteger)y * cellHeightPlusOne, 0, cellWidth, cellHeightPlusOne, 1);
    NSUInteger bytesPerRow = cellWidth * sizeof(pixel);
    NSUInteger bytesPerImage = bytesPerRow * cellHeightPlusOne;
    @autoreleasepool {
        [atlas->spriteTexture replaceRegion:region mipmapLevel:0 slice:z withBytes:buf bytesPerRow:bytesPerRow bytesPerImage:bytesPerImage];
    }
    if (!ensure_decorations_buffer_capacity(atlas, (NSUInteger)idx + 1)) return;
    if (atlas->decorationsBuffer) {
        uint32_t *dest = (uint32_t *)[atlas->decorationsBuffer contents];
        dest[idx] = dec.start_idx;
        atlas->decorationsCount = MAX(atlas->decorationsCount, (NSUInteger)idx + 1);
    }
}

static void
metal_sprite_free(FONTS_DATA_HANDLE fg) {
    metal_release_font_atlas(fg);
}

static void
metal_release_all_font_atlases(void) {
    for (size_t i = 0; i < global_state.num_os_windows; i++) {
        OSWindow *w = global_state.os_windows + i;
        if (w->fonts_data) {
            metal_release_font_atlas(w->fonts_data);
        }
    }
}

static void
metal_register_sprite_hooks(void) {
    if (sprite_hooks_registered) return;
    set_extra_sprite_upload_hook(metal_sprite_upload);
    set_extra_sprite_free_hook(metal_sprite_free);
    sprite_hooks_registered = true;
}

static void
metal_unregister_sprite_hooks(void) {
    if (!sprite_hooks_registered) return;
    metal_release_all_font_atlases();
    set_extra_sprite_upload_hook(NULL);
    set_extra_sprite_free_hook(NULL);
    sprite_hooks_registered = false;
}

static void
metal_record_failure(const char *reason) {
    metal_unregister_sprite_hooks();
    g_metal.cell_pipeline = nil;
    g_metal.border_pipeline = nil;
    g_metal.trail_pipeline = nil;
    g_metal.library = nil;
    g_metal.atlas_sampler = nil;
    g_metal.command_queue = nil;
    g_metal.device = nil;
    g_metal.initialized = false;
    set_preflight_failure(reason);
}

static NSString *
metal_library_path(void) {
    NSString *result = nil;
    PyGILState_STATE gil = PyGILState_Ensure();
    PyObject *resources_mod = PyImport_ImportModule("importlib.resources");
    if (resources_mod) {
        PyObject *files_fn = PyObject_GetAttrString(resources_mod, "files");
        if (files_fn) {
            PyObject *package_name = PyUnicode_FromString("kitty.metal");
            if (package_name) {
                PyObject *files_obj = PyObject_CallFunctionObjArgs(files_fn, package_name, NULL);
                if (files_obj) {
                    PyObject *path_obj = PyObject_CallMethod(files_obj, "joinpath", "s", "cell.metallib");
                    if (path_obj) {
                        PyObject *fspath = PyObject_CallMethod(path_obj, "__fspath__", NULL);
                        if (fspath && PyUnicode_Check(fspath)) {
                            const char *fs = PyUnicode_AsUTF8(fspath);
                            if (fs) {
                                result = [NSString stringWithUTF8String:fs];
                            } else {
                                PyErr_Clear();
                            }
                        } else {
                            PyErr_Clear();
                        }
                        Py_XDECREF(fspath);
                        Py_DECREF(path_obj);
                    } else {
                        PyErr_Clear();
                    }
                    Py_DECREF(files_obj);
                } else {
                    PyErr_Clear();
                }
                Py_DECREF(package_name);
            } else {
                PyErr_Clear();
            }
            Py_DECREF(files_fn);
        } else {
            PyErr_Clear();
        }
        Py_DECREF(resources_mod);
    } else {
        PyErr_Clear();
    }
    PyGILState_Release(gil);
    return result;
}

static bool
metal_ensure_resources(void) {
    if (!g_metal.device) {
        PyErr_SetString(PyExc_RuntimeError, "Metal device unavailable");
        metal_record_failure("Metal device unavailable; falling back to OpenGL");
        return false;
    }
    if (!g_metal.library) {
        NSString *path = metal_library_path();
        if (!path) {
            PyErr_SetString(PyExc_RuntimeError, "Unable to locate Metal shader library");
            metal_log("library_path_failed", "reason=not_found");
            metal_record_failure("Metal shader library missing; falling back to OpenGL");
            return false;
        }
        NSError *error = nil;
        NSURL *url = [NSURL fileURLWithPath:path isDirectory:NO];
        id<MTLLibrary> library = [g_metal.device newLibraryWithURL:url error:&error];
        if (!library) {
            const char *utf8 = error.localizedDescription ? error.localizedDescription.UTF8String : "unknown";
            PyErr_Format(PyExc_RuntimeError, "Failed to load Metal shader library: %s", utf8);
            metal_log("library_load_failed", "path=%s", path.UTF8String);
            metal_record_failure("Failed to load Metal shader library; falling back to OpenGL");
            return false;
        }
        g_metal.library = library;
    }
    if (!g_metal.cell_pipeline) {
        id<MTLFunction> vertex = [g_metal.library newFunctionWithName:@"kitty::cell_vertex"];
        if (!vertex) {
            vertex = [g_metal.library newFunctionWithName:@"cell_vertex"];
        }
        id<MTLFunction> fragment = [g_metal.library newFunctionWithName:@"kitty::cell_fragment"];
        if (!fragment) {
            fragment = [g_metal.library newFunctionWithName:@"cell_fragment"];
        }
        if (!vertex || !fragment) {
            PyErr_SetString(PyExc_RuntimeError, "Metal shader functions missing from library");
            metal_log("shader_missing", "vertex=%p fragment=%p", vertex, fragment);
            metal_record_failure("Required Metal shader functions missing; falling back to OpenGL");
            return false;
        }
        MTLRenderPipelineDescriptor *descriptor = [[MTLRenderPipelineDescriptor alloc] init];
        descriptor.label = @"kitty-cell";
        descriptor.vertexFunction = vertex;
        descriptor.fragmentFunction = fragment;
        descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        descriptor.colorAttachments[0].blendingEnabled = YES;
        descriptor.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
        descriptor.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
        descriptor.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
        descriptor.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        NSError *error = nil;
        id<MTLRenderPipelineState> pipeline = [g_metal.device newRenderPipelineStateWithDescriptor:descriptor error:&error];
        if (!pipeline) {
            const char *utf8 = error.localizedDescription ? error.localizedDescription.UTF8String : "unknown";
            PyErr_Format(PyExc_RuntimeError, "Failed to create Metal pipeline state: %s", utf8);
            metal_log("pipeline_create_failed", "desc=%s", utf8);
            metal_record_failure("Failed to create Metal pipeline state; falling back to OpenGL");
            return false;
        }
        g_metal.cell_pipeline = pipeline;
    }
    if (!g_metal.border_pipeline) {
        id<MTLFunction> vertex = [g_metal.library newFunctionWithName:@"kitty::border_vertex"];
        if (!vertex) {
            vertex = [g_metal.library newFunctionWithName:@"border_vertex"];
        }
        id<MTLFunction> fragment = [g_metal.library newFunctionWithName:@"kitty::border_fragment"];
        if (!fragment) {
            fragment = [g_metal.library newFunctionWithName:@"border_fragment"];
        }
        if (!vertex || !fragment) {
            PyErr_SetString(PyExc_RuntimeError, "Metal border shader functions missing from library");
            metal_record_failure("Required Metal border shader functions missing; falling back to OpenGL");
            return false;
        }
        MTLRenderPipelineDescriptor *descriptor = [[MTLRenderPipelineDescriptor alloc] init];
        descriptor.label = @"kitty-border";
        descriptor.vertexFunction = vertex;
        descriptor.fragmentFunction = fragment;
        descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        descriptor.colorAttachments[0].blendingEnabled = YES;
        descriptor.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
        descriptor.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
        descriptor.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
        descriptor.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        NSError *error = nil;
        id<MTLRenderPipelineState> pipeline = [g_metal.device newRenderPipelineStateWithDescriptor:descriptor error:&error];
        if (!pipeline) {
            const char *utf8 = error.localizedDescription ? error.localizedDescription.UTF8String : "unknown";
            PyErr_Format(PyExc_RuntimeError, "Failed to create Metal border pipeline state: %s", utf8);
            metal_record_failure("Failed to create Metal border pipeline; falling back to OpenGL");
            return false;
        }
        g_metal.border_pipeline = pipeline;
    }
    if (!g_metal.trail_pipeline) {
        id<MTLFunction> vertex = [g_metal.library newFunctionWithName:@"kitty::trail_vertex"];
        if (!vertex) {
            vertex = [g_metal.library newFunctionWithName:@"trail_vertex"];
        }
        id<MTLFunction> fragment = [g_metal.library newFunctionWithName:@"kitty::trail_fragment"];
        if (!fragment) {
            fragment = [g_metal.library newFunctionWithName:@"trail_fragment"];
        }
        if (!vertex || !fragment) {
            PyErr_SetString(PyExc_RuntimeError, "Metal cursor trail shader functions missing from library");
            metal_record_failure("Required Metal trail shader functions missing; falling back to OpenGL");
            return false;
        }
        MTLRenderPipelineDescriptor *descriptor = [[MTLRenderPipelineDescriptor alloc] init];
        descriptor.label = @"kitty-trail";
        descriptor.vertexFunction = vertex;
        descriptor.fragmentFunction = fragment;
        descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        descriptor.colorAttachments[0].blendingEnabled = YES;
        descriptor.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
        descriptor.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
        descriptor.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
        descriptor.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        NSError *error = nil;
        id<MTLRenderPipelineState> pipeline = [g_metal.device newRenderPipelineStateWithDescriptor:descriptor error:&error];
        if (!pipeline) {
            const char *utf8 = error.localizedDescription ? error.localizedDescription.UTF8String : "unknown";
            PyErr_Format(PyExc_RuntimeError, "Failed to create Metal trail pipeline state: %s", utf8);
            metal_record_failure("Failed to create Metal trail pipeline; falling back to OpenGL");
            return false;
        }
        g_metal.trail_pipeline = pipeline;
    }
    if (!g_metal.atlas_sampler) {
        MTLSamplerDescriptor *sampler = [[MTLSamplerDescriptor alloc] init];
        sampler.label = @"kitty-atlas";
        sampler.minFilter = MTLSamplerMinMagFilterNearest;
        sampler.magFilter = MTLSamplerMinMagFilterNearest;
        sampler.sAddressMode = MTLSamplerAddressModeClampToEdge;
        sampler.tAddressMode = MTLSamplerAddressModeClampToEdge;
        sampler.mipFilter = MTLSamplerMipFilterNotMipmapped;
        id<MTLSamplerState> samplerState = [g_metal.device newSamplerStateWithDescriptor:sampler];
        if (!samplerState) {
            PyErr_SetString(PyExc_RuntimeError, "Failed to create Metal sampler state");
            metal_log("sampler_create_failed", "reason=unknown");
            metal_record_failure("Failed to create Metal sampler state; falling back to OpenGL");
            return false;
        }
        g_metal.atlas_sampler = samplerState;
    }
    return true;
}

static bool
metal_ensure_uniform_buffer(MetalWindowState *state) {
    if (!state || !g_metal.device) {
        PyErr_SetString(PyExc_RuntimeError, "Metal device unavailable during uniform buffer allocation");
        return false;
    }
    size_t required = metal_aligned_buffer_length(sizeof(MetalCellUniformData));
    if (!state.uniformBuffer || state.uniformBufferCapacity < required) {
        id<MTLBuffer> buffer = [g_metal.device newBufferWithLength:required options:MTLResourceStorageModeShared];
        if (!buffer) {
            PyErr_SetString(PyExc_RuntimeError, "Metal failed to allocate uniform buffer");
            metal_log("uniform_buffer_alloc_failed", "capacity=%zu", required);
            return false;
        }
        state.uniformBuffer = buffer;
        state.uniformBufferCapacity = required;
    }
    state.uniformBufferLength = required;
    return true;
}

static bool
metal_populate_uniforms(MetalWindowState *state, Screen *screen, OSWindow *os_window, float inactive_text_alpha) {
    if (!state || !screen || !os_window) {
        return false;
    }
    if (!metal_ensure_uniform_buffer(state)) {
        return false;
    }
    MetalCellUniformData *uniforms = (MetalCellUniformData *)state.uniformBuffer.contents;
    if (!uniforms) {
        PyErr_NoMemory();
        return false;
    }
    color_type default_bg = renderer_shared_populate_uniform_data(
        screen,
        &screen->cursor_render_info,
        os_window,
        inactive_text_alpha,
        effective_os_window_alpha(os_window),
        (RendererCellUniformData *)uniforms,
        offsetof(MetalCellUniformData, color_table),
        sizeof(unsigned int)
    );
    (void)default_bg;
    float text_contrast = 1.0f + OPT(text_contrast) * 0.01f;
    float text_gamma_adjustment = OPT(text_gamma_adjustment) < 0.01f ? 1.0f : 1.0f / OPT(text_gamma_adjustment);
    MetalDrawParams params = state.drawParams;
    params.text_contrast = text_contrast;
    params.text_gamma_adjustment = text_gamma_adjustment;
    MetalSpriteAtlas *atlas = NULL;
    if (os_window->fonts_data) {
        atlas = metal_font_atlas(os_window->fonts_data);
    }
    params.decorations_count = atlas ? (uint32_t)atlas->decorationsCount : 0u;
    params.padding = 0u;
    state.drawParams = params;
    return true;
}

static bool
metal_prepare_border_data(MetalWindowState *state, const BorderRects *rects) {
    if (!state || !rects) {
        return false;
    }
    const size_t count = rects->num_border_rects;
    state.borderCount = count;
    if (count == 0) {
        return true;
    }
    if (!g_metal.device) {
        PyErr_SetString(PyExc_RuntimeError, "Metal device unavailable while preparing border data");
        return false;
    }
    const size_t required = count * sizeof(MetalBorderRect);
    if (!state.borderBuffer || state.borderBufferCapacity < required) {
        id<MTLBuffer> buffer = [g_metal.device newBufferWithLength:required options:MTLResourceStorageModeShared];
        if (!buffer) {
            PyErr_SetString(PyExc_RuntimeError, "Metal failed to allocate border buffer");
            return false;
        }
        state.borderBuffer = buffer;
        state.borderBufferCapacity = required;
    }
    MetalBorderRect *dest = (MetalBorderRect *)state.borderBuffer.contents;
    if (!dest || !rects->rect_buf) {
        PyErr_SetString(PyExc_RuntimeError, "Metal border buffer mapping failed");
        return false;
    }
    for (size_t i = 0; i < count; i++) {
        const BorderRect src = rects->rect_buf[i];
        dest[i].rect[0] = src.left;
        dest[i].rect[1] = src.top;
        dest[i].rect[2] = src.right;
        dest[i].rect[3] = src.bottom;
        dest[i].color = src.color;
        dest[i]._pad[0] = 0;
        dest[i]._pad[1] = 0;
        dest[i]._pad[2] = 0;
    }
    return true;
}

static bool
metal_encode_borders(
    GLFWwindow *window,
    MetalWindowState *state,
    OSWindow *os_window,
    const RendererRenderParams *params,
    Tab *tab
) {
    if (!state || !tab) {
        return true;
    }
    const BorderRects *rects = &tab->border_rects;
    if (!rects || rects->num_border_rects == 0) {
        state.borderCount = 0;
        return true;
    }
    if (!state.commandBuffer || !state.drawable) {
        if (!ensure_command_primitives(window, state)) {
            return false;
        }
    }
    if (!metal_ensure_resources()) {
        return false;
    }
    if (!metal_prepare_border_data(state, rects)) {
        return false;
    }
    MetalBorderUniforms uniforms = {0};
    const bool has_background_image = os_window && os_window->bgimage && os_window->bgimage->texture_id > 0;
    float background_opacity = os_window ? effective_os_window_alpha(os_window) : 1.0f;
    if (has_background_image) {
        background_opacity = OPT(background_tint) * OPT(background_tint_gaps);
    }
    const color_type active_bg = params ? params->active_window_bg : state.fallbackBackground;
    const unsigned int num_visible_windows = params ? params->num_visible_windows : 0u;
    const bool all_same_bg = params ? params->all_windows_have_same_bg : true;
    const color_type default_bg =
        (num_visible_windows > 1u && !all_same_bg) ? OPT(background) : active_bg;
    metal_configure_border_uniforms(
        &uniforms,
        default_bg,
        OPT(active_border_color),
        OPT(inactive_border_color),
        OPT(bell_border_color),
        OPT(tab_bar_background),
        OPT(tab_bar_margin_color),
        os_window ? os_window->tab_bar_edge_color.left : 0,
        os_window ? os_window->tab_bar_edge_color.right : 0,
        background_opacity
    );
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    if (!pass) {
        PyErr_SetString(PyExc_RuntimeError, "Failed to allocate Metal render pass descriptor for borders");
        return false;
    }
    pass.colorAttachments[0].texture = state.drawable.texture;
    pass.colorAttachments[0].loadAction = state.frameHasContent ? MTLLoadActionLoad : MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = state.clearColor;

    id<MTLRenderCommandEncoder> encoder = [state.commandBuffer renderCommandEncoderWithDescriptor:pass];
    if (!encoder) {
        PyErr_SetString(PyExc_RuntimeError, "Failed to create Metal border command encoder");
        return false;
    }
    if (g_metal.debug_labels) {
        encoder.label = @"kitty-borders";
    }
    [encoder setRenderPipelineState:g_metal.border_pipeline];
    [encoder setVertexBuffer:state.borderBuffer offset:0 atIndex:0];
    [encoder setVertexBytes:&uniforms length:sizeof(MetalBorderUniforms) atIndex:1];
    [encoder setFragmentBytes:&uniforms length:sizeof(MetalBorderUniforms) atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4 instanceCount:(NSUInteger)state.borderCount];
    encode_draw_end(encoder);
    state.frameHasContent = YES;
    return true;
}

static bool
metal_encode_cursor_trail(
    GLFWwindow *window,
    MetalWindowState *state,
    OSWindow *os_window,
    Tab *tab,
    Window *active_window
) {
    if (!tab || !state) {
        return true;
    }
    (void)os_window;
    if (!OPT(cursor_trail) || !tab->cursor_trail.needs_render) {
        return true;
    }
    if (!state.commandBuffer || !state.drawable) {
        if (!ensure_command_primitives(window, state)) {
            return false;
        }
    }
    if (!metal_ensure_resources()) {
        return false;
    }
    MetalTrailUniforms uniforms = {0};
    color_type trail_color = OPT(cursor_trail_color);
    if (trail_color == 0) {
        trail_color = active_window && active_window->render_data.screen
            ? active_window->render_data.screen->last_rendered.cursor_bg
            : OPT(foreground);
    }
    metal_set_trail_uniforms(
        &uniforms,
        tab->cursor_trail.corner_x,
        tab->cursor_trail.corner_y,
        tab->cursor_trail.cursor_edge_x,
        tab->cursor_trail.cursor_edge_y,
        trail_color,
        tab->cursor_trail.opacity
    );
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    if (!pass) {
        PyErr_SetString(PyExc_RuntimeError, "Failed to allocate Metal render pass descriptor for cursor trail");
        return false;
    }
    pass.colorAttachments[0].texture = state.drawable.texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = state.clearColor;

    id<MTLRenderCommandEncoder> encoder = [state.commandBuffer renderCommandEncoderWithDescriptor:pass];
    if (!encoder) {
        PyErr_SetString(PyExc_RuntimeError, "Failed to create Metal cursor trail command encoder");
        return false;
    }
    if (g_metal.debug_labels) {
        encoder.label = @"kitty-cursor-trail";
    }
    [encoder setRenderPipelineState:g_metal.trail_pipeline];
    [encoder setVertexBytes:&uniforms length:sizeof(MetalTrailUniforms) atIndex:0];
    [encoder setFragmentBytes:&uniforms length:sizeof(MetalTrailUniforms) atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    encode_draw_end(encoder);
    state.frameHasContent = YES;
    return true;
}

static bool
metal_render_pass_for_render_data(
    GLFWwindow *window,
    MetalWindowState *state,
    OSWindow *os_window,
    WindowRenderData *render_data,
    bool is_active_window,
    bool is_tab_bar,
    bool is_single_window
) {
    if (!render_data) {
        return true;
    }
    Screen *screen = render_data->screen;
    if (!screen) {
        return true;
    }
    if (!state.commandBuffer || !state.drawable) {
        if (!ensure_command_primitives(window, state)) {
            return false;
        }
    }
    RendererSharedBufferOps ops = {
        .map = metal_shared_buffer_map,
        .unmap = metal_shared_buffer_unmap,
    };
    RendererSharedFrameParams frame_params = {
        .screen = screen,
        .os_window = os_window,
        .cursor_has_moved = false,
    };
    RendererSharedFrameResult frame_result = {0};
    if (!renderer_shared_prepare_frame(&frame_params, &ops, (__bridge void *)state, &frame_result)) {
        return false;
    }
    if (is_active_window) {
        state.sharedFrame = frame_result;
    }
    if (!state.frameHasContent && frame_result.default_bg) {
        state.clearColor = clear_color_from(frame_result.default_bg, state.backgroundOpacity);
    }
    float inactive_alpha = 1.0f;
    if (!(is_tab_bar || (!is_single_window && is_active_window) || (is_single_window && screen->cursor_render_info.is_focused))) {
        inactive_alpha = (float)OPT(inactive_text_alpha);
    }
    if (!metal_populate_uniforms(state, screen, os_window, inactive_alpha)) {
        return false;
    }
    MetalSpriteAtlas *atlas = NULL;
    if (os_window && os_window->fonts_data) {
        atlas = metal_font_atlas(os_window->fonts_data);
    }
    size_t instance_count = (size_t)screen->columns * screen->lines;
    if (!instance_count) {
        return true;
    }
    const WindowGeometry *geometry = &render_data->geometry;
    float scale_x = 0.f, scale_y = 0.f, origin_x = 0.f, origin_y = 0.f;
    const unsigned int fb_width = state.drawable ? (unsigned int)state.drawable.texture.width : 0u;
    const unsigned int fb_height = state.drawable ? (unsigned int)state.drawable.texture.height : 0u;
    if (!metal_compute_viewport_params(
            fb_width,
            fb_height,
            geometry->left,
            geometry->top,
            geometry->right,
            geometry->bottom,
            &scale_x,
            &scale_y,
            &origin_x,
            &origin_y)) {
        return true;
    }
    MetalDrawParams params = state.drawParams;
    params.viewport_scale_x = scale_x;
    params.viewport_scale_y = scale_y;
    params.viewport_origin_x = origin_x;
    params.viewport_origin_y = origin_y;
    state.drawParams = params;
    if (!atlas || !atlas->spriteTexture) {
        return encode_clear_pass(window, state, state.clearColor);
    }
    return metal_encode_cells(window, state, atlas, instance_count);
}

static bool
metal_encode_cells(GLFWwindow *window, MetalWindowState *state, MetalSpriteAtlas *atlas, size_t instance_count) {
    if (!state || !atlas || !instance_count) {
        return encode_clear_pass(window, state, state.clearColor);
    }
    if (!state.cellBuffer || !state.selectionBuffer || !state.uniformBuffer || !atlas->spriteTexture) {
        return encode_clear_pass(window, state, state.clearColor);
    }
    if (!state.commandBuffer || !state.drawable) {
        if (!ensure_command_primitives(window, state)) {
            return false;
        }
    }
    if (!metal_ensure_resources()) {
        return false;
    }
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    if (!pass) {
        PyErr_SetString(PyExc_RuntimeError, "Failed to allocate Metal render pass descriptor");
        return false;
    }
    pass.colorAttachments[0].texture = state.drawable.texture;
    pass.colorAttachments[0].loadAction = state.frameHasContent ? MTLLoadActionLoad : MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = state.clearColor;

    id<MTLRenderCommandEncoder> encoder = [state.commandBuffer renderCommandEncoderWithDescriptor:pass];
    if (!encoder) {
        PyErr_SetString(PyExc_RuntimeError, "Failed to create Metal render command encoder");
        return false;
    }
    if (g_metal.debug_labels) {
        encoder.label = @"kitty-cells";
    }

    MTLViewport viewport = {
        .originX = 0.0,
        .originY = 0.0,
        .width = state.drawable.texture.width,
        .height = state.drawable.texture.height,
        .znear = 0.0,
        .zfar = 1.0,
    };
    [encoder setViewport:viewport];
    [encoder setRenderPipelineState:g_metal.cell_pipeline];
    [encoder setVertexBuffer:state.cellBuffer offset:0 atIndex:0];
    [encoder setVertexBuffer:state.selectionBuffer offset:0 atIndex:1];
    if (atlas->decorationsBuffer) {
        [encoder setVertexBuffer:atlas->decorationsBuffer offset:0 atIndex:2];
    } else {
        [encoder setVertexBuffer:nil offset:0 atIndex:2];
    }
    [encoder setVertexBuffer:state.uniformBuffer offset:0 atIndex:3];
    MetalDrawParams params = state.drawParams;
    [encoder setVertexBytes:&params length:sizeof(MetalDrawParams) atIndex:4];
    [encoder setFragmentBuffer:state.uniformBuffer offset:0 atIndex:0];
    [encoder setFragmentBytes:&params length:sizeof(MetalDrawParams) atIndex:1];
    [encoder setFragmentTexture:atlas->spriteTexture atIndex:0];
    if (g_metal.atlas_sampler) {
        [encoder setFragmentSamplerState:g_metal.atlas_sampler atIndex:0];
    }

    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4 instanceCount:(NSUInteger)instance_count];
    encode_draw_end(encoder);
    state.frameHasContent = YES;
    return true;
}

@implementation MetalWindowState
@end

static NSMapTable<NSValue *, MetalWindowState *> *
window_state_table(void) {
    static NSMapTable<NSValue *, MetalWindowState *> *table = nil;
    static dispatch_once_t once_token;
    dispatch_once(&once_token, ^{
        table = [NSMapTable strongToStrongObjectsMapTable];
    });
    return table;
}

static NSValue*
window_key(GLFWwindow *window) {
    return [NSValue valueWithPointer:(const void *)window];
}

static MetalWindowState*
state_for_window(GLFWwindow *window) {
    return [window_state_table() objectForKey:window_key(window)];
}

static MetalWindowState*
ensure_state_for_window(GLFWwindow *window) {
    NSMapTable *table = window_state_table();
    NSValue *key = window_key(window);
    MetalWindowState *state = [table objectForKey:key];
    if (!state) {
        state = [[MetalWindowState alloc] init];
        [table setObject:state forKey:key];
    }
    return state;
}

static void
remove_state_for_window(GLFWwindow *window) {
    [window_state_table() removeObjectForKey:window_key(window)];
}

static inline void
reset_command_primitives(MetalWindowState *state) {
    if (!state) return;
    state.commandBuffer = nil;
    state.drawable = nil;
    state.frameHasContent = NO;
}

static MTLClearColor
clear_color_from(color_type color, float alpha) {
    const double r = ((color >> 16) & 0xFF) / 255.0;
    const double g = ((color >> 8) & 0xFF) / 255.0;
    const double b = (color & 0xFF) / 255.0;
    const double clamped_alpha = fmax(0.0, fmin((double)alpha, 1.0));
    return MTLClearColorMake(r, g, b, clamped_alpha);
}

static bool
ensure_command_primitives(GLFWwindow *window, MetalWindowState *state) {
    (void)window;
    if (!state || !state.layer) {
        PyErr_SetString(PyExc_RuntimeError, "Metal window state missing layer");
        return false;
    }
    reset_command_primitives(state);

    @autoreleasepool {
        id<CAMetalDrawable> drawable = [state.layer nextDrawable];
        if (!drawable) {
            PyErr_SetString(PyExc_RuntimeError, "Metal layer failed to supply drawable");
            metal_log("drawable_acquire_failed", "layer=%p", state.layer);
            return false;
        }
        state.drawable = drawable;

        id<MTLCommandBuffer> command_buffer = [g_metal.command_queue commandBuffer];
        if (!command_buffer) {
            PyErr_SetString(PyExc_RuntimeError, "Metal command queue failed to create command buffer");
            metal_log("command_buffer_create_failed", "command_queue=%p", g_metal.command_queue);
            return false;
        }
        if (g_metal.debug_labels) {
            command_buffer.label = @"kitty-frame";
        }
        state.commandBuffer = command_buffer;
        if (g_metal.debug_labels) {
            metal_log("command_primitives_ready", "drawable=%p command_buffer=%p", state.drawable, state.commandBuffer);
        }
    }
    return true;
}

static void
encode_draw_end(id<MTLRenderCommandEncoder> encoder) {
    if (encoder) {
        [encoder endEncoding];
    }
}

static bool
encode_clear_pass(GLFWwindow *window, MetalWindowState *state, MTLClearColor clear_color) {
    if (!state.commandBuffer || !state.drawable) {
        if (!ensure_command_primitives(window, state)) {
            return false;
        }
    }
    @autoreleasepool {
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        if (!pass) {
            PyErr_SetString(PyExc_RuntimeError, "Failed to allocate Metal render pass descriptor");
            return false;
        }
        pass.colorAttachments[0].texture = state.drawable.texture;
        pass.colorAttachments[0].loadAction = state.frameHasContent ? MTLLoadActionLoad : MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].clearColor = clear_color;

        id<MTLRenderCommandEncoder> encoder = [state.commandBuffer renderCommandEncoderWithDescriptor:pass];
        if (!encoder) {
            PyErr_SetString(PyExc_RuntimeError, "Failed to create Metal command encoder");
            return false;
        }
        if (g_metal.debug_labels) {
            encoder.label = @"kitty-clear";
        }
        encode_draw_end(encoder);
    }
    state.frameHasContent = YES;
    return true;
}

static void
destroy_window_state(GLFWwindow *window) {
    MetalWindowState *state = state_for_window(window);
    if (!state) return;
    if (state.closeObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:state.closeObserver];
        state.closeObserver = nil;
    }
    reset_command_primitives(state);
    state.cellBuffer = nil;
    state.cellBufferCapacity = 0;
    state.cellBufferLength = 0;
    state.selectionBuffer = nil;
    state.selectionBufferCapacity = 0;
    state.selectionBufferLength = 0;
    state.uniformBuffer = nil;
    state.uniformBufferCapacity = 0;
    state.uniformBufferLength = 0;
    state.borderBuffer = nil;
    state.borderBufferCapacity = 0;
    state.borderCount = 0;
    state.sharedFrame = (RendererSharedFrameResult){0};
    state.layer = nil;
    remove_state_for_window(window);
}

static void
update_layer_properties(CAMetalLayer *layer, const RendererResizeParams *params) {
    if (!layer) return;
    if (params) {
        layer.contentsScale = params->framebuffer_scale > 0.f ? params->framebuffer_scale : 1.f;
        CGSize drawable_size = CGSizeMake((CGFloat)params->framebuffer_width, (CGFloat)params->framebuffer_height);
        layer.drawableSize = drawable_size;
    } else {
        layer.contentsScale = layer.contentsScale > 0.0 ? layer.contentsScale : 1.0;
        if (layer.superlayer) {
            layer.frame = layer.superlayer.bounds;
        }
    }
}

static void
set_display_sync_for_all_layers(void) {
    NSEnumerator *enumerator = [window_state_table() objectEnumerator];
    MetalWindowState *state = nil;
    while ((state = [enumerator nextObject])) {
        if (state.layer) {
            state.layer.displaySyncEnabled = g_metal.display_sync_enabled;
        }
    }
}

static bool preflight_attempted = false;
static bool preflight_success = false;
static const char *preflight_failure_reason = NULL;

static inline void
set_preflight_failure(const char *reason) {
    preflight_success = false;
    preflight_failure_reason = reason;
    metal_log("preflight_failure", "reason=\"%s\"", reason ? reason : "unknown");
}

bool
metal_renderer_preflight(const char **failure_reason) {
    if (!preflight_attempted) {
        preflight_attempted = true;
        if (@available(macOS 13.0, *)) {
            id<MTLDevice> device = MTLCreateSystemDefaultDevice();
            if (device) {
                preflight_success = true;
                preflight_failure_reason = NULL;
            } else {
                set_preflight_failure("Metal renderer unavailable: no compatible GPU reported by Metal.");
            }
        } else {
            set_preflight_failure("Metal renderer requires macOS 13 or newer.");
        }
    }
    if (failure_reason && !preflight_success) {
        *failure_reason = preflight_failure_reason;
    }
    return preflight_success;
}

static bool
metal_backend_ensure_initialized(const RendererInitConfig *cfg) {
    const char *reason = NULL;
    if (!metal_renderer_preflight(&reason)) {
        PyErr_SetString(PyExc_RuntimeError, reason ? reason : "Metal preflight failed");
        return false;
    }
    if (!g_metal.initialized) {
        @autoreleasepool {
            id<MTLDevice> device = MTLCreateSystemDefaultDevice();
            if (!device) {
                PyErr_SetString(PyExc_RuntimeError, "Metal device creation failed after preflight success");
                metal_log("device_create_failed", "reason=MTLCreateSystemDefaultDevice_null");
                metal_record_failure("Metal device creation failed; falling back to OpenGL");
                return false;
            }
            id<MTLCommandQueue> queue = [device newCommandQueue];
            if (!queue) {
                PyErr_SetString(PyExc_RuntimeError, "Failed to create Metal command queue");
                metal_log("command_queue_create_failed", "device=%p", device);
                metal_record_failure("Metal command queue creation failed; falling back to OpenGL");
                return false;
            }
            g_metal.device = device;
            g_metal.command_queue = queue;
            g_metal.initialized = true;
        }
    }
    g_metal.prefer_low_latency = cfg ? cfg->prefer_low_latency : false;
    g_metal.debug_labels = cfg ? cfg->enable_debug_labels : false;
    g_metal.display_sync_enabled = !g_metal.prefer_low_latency;
    set_display_sync_for_all_layers();
    metal_register_sprite_hooks();
    return metal_ensure_resources();
}

static void
metal_backend_shutdown(void) {
    NSEnumerator *key_enumerator = [window_state_table() keyEnumerator];
    NSValue *key = nil;
    NSMutableArray<NSValue *> *keys = [NSMutableArray array];
    while ((key = [key_enumerator nextObject])) {
        [keys addObject:key];
    }
    for (NSValue *window_key_value in keys) {
        GLFWwindow *window = (GLFWwindow *)window_key_value.pointerValue;
        destroy_window_state(window);
    }
    metal_unregister_sprite_hooks();
    g_metal.cell_pipeline = nil;
    g_metal.border_pipeline = nil;
    g_metal.trail_pipeline = nil;
    g_metal.library = nil;
    g_metal.atlas_sampler = nil;
    g_metal.command_queue = nil;
    g_metal.device = nil;
    g_metal.initialized = false;
}

static void*
metal_backend_make_context_current(GLFWwindow *window) {
    (void)window;
    return NULL;
}

static void
metal_backend_restore_context(void *token) {
    (void)token;
}

static bool
metal_backend_attach_window(GLFWwindow *window, const RendererWindowConfig *config) {
    if (!metal_backend_ensure_initialized(NULL)) {
        return false;
    }

    NSWindow *ns_window = (__bridge NSWindow *)glfwGetCocoaWindow(window);
    if (!ns_window) {
        PyErr_SetString(PyExc_RuntimeError, "Failed to acquire NSWindow for Metal attachment");
        return false;
    }
    NSView *content_view = ns_window.contentView;
    if (!content_view) {
        PyErr_SetString(PyExc_RuntimeError, "Failed to acquire NSView for Metal attachment");
        return false;
    }

    MetalWindowState *state = ensure_state_for_window(window);
    if (state.closeObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:state.closeObserver];
        state.closeObserver = nil;
    }
    reset_command_primitives(state);
    if (state.layer) {
        [state.layer removeFromSuperlayer];
        state.layer = nil;
    }

    @autoreleasepool {
        CAMetalLayer *layer = [CAMetalLayer layer];
        if (!layer) {
            PyErr_SetString(PyExc_RuntimeError, "Failed to create CAMetalLayer");
            destroy_window_state(window);
            return false;
        }
        layer.device = g_metal.device;
        layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        layer.framebufferOnly = YES;
        layer.allowsNextDrawableTimeout = NO;
        layer.presentsWithTransaction = NO;
        layer.opaque = config ? !config->wants_transparency : YES;
        layer.displaySyncEnabled = g_metal.display_sync_enabled;
        const CGFloat backing_scale = ns_window.backingScaleFactor;
        layer.contentsScale = backing_scale > 0.0 ? backing_scale : 1.0;
        layer.drawableSize = CGSizeMake(content_view.bounds.size.width * layer.contentsScale,
                                        content_view.bounds.size.height * layer.contentsScale);

        content_view.wantsLayer = YES;
        content_view.layer = layer;
        state.layer = layer;
        state.frameHasContent = NO;
    }

    state.backgroundOpacity = config ? config->background_opacity : 1.0f;
    state.fallbackBackground = config ? config->background_color : 0;
    state.clearColor = clear_color_from(state.fallbackBackground, state.backgroundOpacity);

    id observer = [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowWillCloseNotification
                                                                   object:ns_window
                                                                    queue:nil
                                                               usingBlock:^(NSNotification *note) {
        (void)note;
        destroy_window_state(window);
    }];
    state.closeObserver = observer;

    return encode_clear_pass(window, state, state.clearColor);
}

static void
metal_backend_apply_swap_interval(int val) {
    int effective = val;
    if (val < 0) {
        effective = g_metal.prefer_low_latency ? 0 : 1;
    }
    g_metal.display_sync_enabled = effective != 0;
    set_display_sync_for_all_layers();
}

static bool
metal_backend_begin_frame(GLFWwindow *window, const RendererFrameParams *params) {
    (void)params;
    MetalWindowState *state = state_for_window(window);
    if (!state) {
        PyErr_SetString(PyExc_RuntimeError, "Metal backend begin_frame called on unknown window");
        return false;
    }
    return ensure_command_primitives(window, state);
}

static bool
metal_backend_render(GLFWwindow *window, const RendererRenderParams *params) {
    MetalWindowState *state = state_for_window(window);
    if (!state) {
        PyErr_SetString(PyExc_RuntimeError, "Metal backend render called on unknown window");
        return false;
    }
    OSWindow *os_window = params ? params->os_window : NULL;
    if (!os_window) {
        return encode_clear_pass(window, state, state.clearColor);
    }
    if (!state.commandBuffer || !state.drawable) {
        if (!ensure_command_primitives(window, state)) {
            return false;
        }
    }
    state.sharedFrame = (RendererSharedFrameResult){0};
    color_type fallback_bg = params && params->active_window_bg ? params->active_window_bg : state.fallbackBackground;
    state.clearColor = clear_color_from(fallback_bg, state.backgroundOpacity);

    Tab *tab = NULL;
    if (os_window->num_tabs > 0) {
        unsigned int tab_index = MIN(os_window->active_tab, os_window->num_tabs - 1u);
        tab = os_window->tabs + tab_index;
    }

    if (tab && tab->border_rects.num_border_rects > 0) {
        if (!metal_encode_borders(window, state, os_window, params, tab)) {
            return false;
        }
        tab->border_rects.is_dirty = false;
    } else {
        state.borderCount = 0;
    }

    unsigned int computed_visible = 0;
    if (tab) {
        for (unsigned int i = 0; i < tab->num_windows; i++) {
            Window *w = tab->windows + i;
            if (w->visible && w->render_data.screen) {
                computed_visible++;
            }
        }
    }
    unsigned int visible_windows = params && params->num_visible_windows ? params->num_visible_windows : computed_visible;
    bool is_single_window = visible_windows <= 1u;

    if (os_window->num_tabs >= OPT(tab_bar_min_tabs) && os_window->tab_bar_render_data.screen) {
        if (!metal_render_pass_for_render_data(window, state, os_window, &os_window->tab_bar_render_data, false, true, is_single_window)) {
            return false;
        }
    }

    if (tab) {
        Window *active_window_ptr = NULL;
        for (unsigned int i = 0; i < tab->num_windows; i++) {
            Window *w = tab->windows + i;
            if (!w->visible || !w->render_data.screen) {
                continue;
            }
            bool is_active = i == tab->active_window;
            if (is_active) {
                active_window_ptr = w;
            }
            if (!metal_render_pass_for_render_data(window, state, os_window, &w->render_data, is_active, false, is_single_window)) {
                return false;
            }
        }
        if (!metal_encode_cursor_trail(window, state, os_window, tab, active_window_ptr)) {
            return false;
        }
    } else {
        if (!metal_encode_cursor_trail(window, state, os_window, NULL, NULL)) {
            return false;
        }
    }

    if (!state.frameHasContent) {
        if (!encode_clear_pass(window, state, state.clearColor)) {
            return false;
        }
    }
    return true;
}

static bool
metal_backend_present(GLFWwindow *window, const RendererPresentParams *params) {
    MetalWindowState *state = state_for_window(window);
    if (!state) {
        PyErr_SetString(PyExc_RuntimeError, "Metal backend present called on unknown window");
        metal_log("present_failed", "reason=unknown_window window=%p", window);
        return false;
    }
    if (params && params->capture_framebuffer) {
        PyErr_SetString(PyExc_RuntimeError, "Metal framebuffer capture is not supported yet");
        metal_log("present_failed", "reason=capture_not_supported");
        return false;
    }
    if (!state.commandBuffer || !state.drawable) {
        metal_log("present_retry", "cause=missing_primitives command_buffer=%p drawable=%p", state.commandBuffer, state.drawable);
        if (!encode_clear_pass(window, state, state.clearColor)) {
            return false;
        }
    }
    @autoreleasepool {
        [state.commandBuffer presentDrawable:state.drawable];
        [state.commandBuffer commit];
        if (!params || params->blocking) {
            [state.commandBuffer waitUntilScheduled];
        }
    }
    if (g_metal.debug_labels) {
        const bool blocking = params ? params->blocking : true;
        metal_log("present", "drawable=%p blocking=%d", state.drawable, blocking ? 1 : 0);
    }
    reset_command_primitives(state);
    return true;
}

static void
metal_backend_on_resize(GLFWwindow *window, const RendererResizeParams *params) {
    MetalWindowState *state = state_for_window(window);
    if (!state || !state.layer) return;
    @autoreleasepool {
        update_layer_properties(state.layer, params);
    }
}

static void
metal_backend_on_suspend(void) {
    NSEnumerator *enumerator = [window_state_table() objectEnumerator];
    MetalWindowState *state = nil;
    while ((state = [enumerator nextObject])) {
        reset_command_primitives(state);
    }
}

static void
metal_backend_on_resume(void) {
    // Resources are recreated lazily per-frame.
}

EXPORTED void
metal_renderer_prepare_border_uniforms_for_tests(
    color_type default_bg,
    color_type active_border_color,
    color_type inactive_border_color,
    color_type bell_border_color,
    color_type tab_bar_background,
    color_type tab_bar_margin_color,
    color_type tab_bar_edge_left,
    color_type tab_bar_edge_right,
    float background_opacity,
    MetalBorderUniforms *out_uniforms
) {
    if (!out_uniforms) {
        return;
    }
    metal_configure_border_uniforms(
        out_uniforms,
        default_bg,
        active_border_color,
        inactive_border_color,
        bell_border_color,
        tab_bar_background,
        tab_bar_margin_color,
        tab_bar_edge_left,
        tab_bar_edge_right,
        background_opacity
    );
}

EXPORTED void
metal_renderer_prepare_trail_uniforms_for_tests(
    const float corner_x[4],
    const float corner_y[4],
    const float cursor_edge_x[2],
    const float cursor_edge_y[2],
    color_type color,
    float opacity,
    MetalTrailUniforms *out_uniforms
) {
    if (!out_uniforms) {
        return;
    }
    metal_set_trail_uniforms(
        out_uniforms,
        corner_x,
        corner_y,
        cursor_edge_x,
        cursor_edge_y,
        color,
        opacity
    );
}

bool
register_metal_renderer_backend(void) {
    static const RendererBackendOps metal_ops = {
        .name = "metal",
        .ensure_initialized = metal_backend_ensure_initialized,
        .shutdown = metal_backend_shutdown,
        .attach_window = metal_backend_attach_window,
        .make_context_current = metal_backend_make_context_current,
        .restore_context = metal_backend_restore_context,
        .apply_swap_interval = metal_backend_apply_swap_interval,
        .begin_frame = metal_backend_begin_frame,
        .render = metal_backend_render,
        .present = metal_backend_present,
        .on_resize = metal_backend_on_resize,
        .on_suspend = metal_backend_on_suspend,
        .on_resume = metal_backend_on_resume,
    };
    return renderer_backend_register(RENDERER_BACKEND_METAL, &metal_ops);
}
