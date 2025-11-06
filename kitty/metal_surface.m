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
#include "metal_text_shared.h"

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
} MetalRendererState;

static id<MTLDevice> metal_device = nil;
static MetalRendererState renderer_state = {0};

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

    renderer_state.ok = true;
    return true;
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
        if (state->command_buffer == nil || state->drawable == nil) return;

        MTLRenderPassDescriptor *descriptor = [MTLRenderPassDescriptor renderPassDescriptor];
        descriptor.colorAttachments[0].texture = state->drawable.texture;
        descriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
        descriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
        descriptor.colorAttachments[0].clearColor = state->clear_color;

        id<MTLRenderCommandEncoder> encoder = [state->command_buffer renderCommandEncoderWithDescriptor:descriptor];
        if (encoder != nil) {
            [encoder endEncoding];
        }

        [state->command_buffer presentDrawable:state->drawable];
        [state->command_buffer commit];

        [state->command_buffer release];
        [state->drawable release];
        state->command_buffer = nil;
        state->drawable = nil;
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
        if (state->command_queue != nil) {
            [state->command_queue release];
            state->command_queue = nil;
        }
        if (state->layer != nil) {
            [state->layer removeFromSuperlayer];
            [state->layer release];
            state->layer = nil;
        }
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
