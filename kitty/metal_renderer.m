#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

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
#include "state.h"

extern void log_error(const char *fmt, ...);

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

typedef struct {
    id<MTLDevice> device;
    id<MTLCommandQueue> command_queue;
    bool initialized;
    bool prefer_low_latency;
    bool debug_labels;
    bool display_sync_enabled;
} MetalGlobalState;

static MetalGlobalState g_metal = {
    .device = nil,
    .command_queue = nil,
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
} MetalSpriteAtlas;

static bool sprite_hooks_registered = false;

@interface MetalWindowState : NSObject
@property (nonatomic, strong) CAMetalLayer *layer;
@property (nonatomic, strong) id<CAMetalDrawable> drawable;
@property (nonatomic, strong) id<MTLCommandBuffer> commandBuffer;
@property (nonatomic) MTLClearColor clearColor;
@property (nonatomic) float backgroundOpacity;
@property (nonatomic) color_type fallbackBackground;
@property (nonatomic, strong) id closeObserver;
@property (nonatomic) RendererSharedFrameResult sharedFrame;
@property (nonatomic) void *cellBuffer;
@property (nonatomic) size_t cellBufferCapacity;
@property (nonatomic) size_t cellBufferLength;
@property (nonatomic) void *selectionBuffer;
@property (nonatomic) size_t selectionBufferCapacity;
@property (nonatomic) size_t selectionBufferLength;
@end

static void*
metal_shared_buffer_map(RendererSharedBufferType type, size_t size, void *user) {
    MetalWindowState *state = (__bridge MetalWindowState *)user;
    if (!state || size == 0) {
        return NULL;
    }
    switch (type) {
        case RENDERER_SHARED_BUFFER_CELL_DATA: {
            if (state.cellBufferCapacity < size) {
                void *new_buf = realloc(state.cellBuffer, size);
                if (!new_buf) {
                    return NULL;
                }
                state.cellBuffer = new_buf;
                state.cellBufferCapacity = size;
            }
            state.cellBufferLength = size;
            return state.cellBuffer;
        }
        case RENDERER_SHARED_BUFFER_SELECTIONS: {
            if (state.selectionBufferCapacity < size) {
                void *new_buf = realloc(state.selectionBuffer, size);
                if (!new_buf) {
                    return NULL;
                }
                state.selectionBuffer = new_buf;
                state.selectionBufferCapacity = size;
            }
            state.selectionBufferLength = size;
            return state.selectionBuffer;
        }
        case RENDERER_SHARED_BUFFER_UNIFORMS:
            return NULL;
    }
    return NULL;
}

static void
metal_shared_buffer_unmap(RendererSharedBufferType type, void *ptr, size_t size, void *user) {
    (void)type;
    (void)ptr;
    (void)size;
    (void)user;
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
    id<MTLBuffer> newBuffer = [g_metal.device newBufferWithLength:newCapacity * sizeof(uint32_t) options:MTLResourceStorageModeManaged];
    if (!newBuffer) {
        metal_log("decorations_buffer_alloc_failed", "capacity=%lu", (unsigned long)newCapacity);
        PyErr_SetString(PyExc_RuntimeError, "Metal failed to allocate decorations buffer");
        return false;
    }
    if (atlas->decorationsBuffer) {
        memcpy([newBuffer contents], [atlas->decorationsBuffer contents], atlas->decorationsCapacity * sizeof(uint32_t));
        [newBuffer didModifyRange:NSMakeRange(0, atlas->decorationsCapacity * sizeof(uint32_t))];
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
        if (atlas->decorationsBuffer.storageMode == MTLStorageModeManaged) {
            [atlas->decorationsBuffer didModifyRange:NSMakeRange((NSUInteger)idx * sizeof(uint32_t), sizeof(uint32_t))];
        }
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
    if (!ensure_command_primitives(window, state)) {
        return false;
    }
    @autoreleasepool {
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        if (!pass) {
            PyErr_SetString(PyExc_RuntimeError, "Failed to allocate Metal render pass descriptor");
            return false;
        }
        pass.colorAttachments[0].texture = state.drawable.texture;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
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
    if (state.cellBuffer) {
        free(state.cellBuffer);
        state.cellBuffer = NULL;
        state.cellBufferCapacity = 0;
        state.cellBufferLength = 0;
    }
    if (state.selectionBuffer) {
        free(state.selectionBuffer);
        state.selectionBuffer = NULL;
        state.selectionBufferCapacity = 0;
        state.selectionBufferLength = 0;
    }
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
                return false;
            }
            id<MTLCommandQueue> queue = [device newCommandQueue];
            if (!queue) {
                PyErr_SetString(PyExc_RuntimeError, "Failed to create Metal command queue");
                metal_log("command_queue_create_failed", "device=%p", device);
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
    return true;
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
    Screen *screen = NULL;
    if (os_window && os_window->num_tabs > 0) {
        unsigned int tab_index = MIN(os_window->active_tab, os_window->num_tabs - 1);
        Tab *tab = os_window->tabs + tab_index;
        if (tab && tab->num_windows > 0) {
            unsigned int window_index = MIN(tab->active_window, tab->num_windows - 1);
            Window *active_window = tab->windows + window_index;
            if (active_window) {
                screen = active_window->render_data.screen;
            }
        }
    }
    if (screen) {
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
        state.sharedFrame = frame_result;
        if (frame_result.default_bg) {
            state.clearColor = clear_color_from(frame_result.default_bg, state.backgroundOpacity);
        }
    }
    color_type bg = params && params->active_window_bg ? params->active_window_bg : state.fallbackBackground;
    if (state.sharedFrame.default_bg) {
        bg = state.sharedFrame.default_bg;
    }
    state.clearColor = clear_color_from(bg, state.backgroundOpacity);
    return encode_clear_pass(window, state, state.clearColor);
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
