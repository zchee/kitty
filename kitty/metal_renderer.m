#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#import <simd/simd.h>

#include <math.h>
#include <stdbool.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

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
#include "animation.h"
#include "graphics.h"
#include "data-types.h"
#include "line.h"
#include "state.h"
#include "monotonic.h"

static bool metal_debug_events_enabled(void);

extern void log_error(const char *fmt, ...);

static inline float
srgb_channel_to_linear(uint8_t c) {
    float f = (float)c / 255.f;
    if (f <= 0.04045f) {
        return f / 12.92f;
    }
    return powf((f + 0.055f) / 1.055f, 2.4f);
}

static inline vector_float4
color_to_linear_premult(color_type color, float alpha) {
    float r = srgb_channel_to_linear((color >> 16) & 0xFF);
    float g = srgb_channel_to_linear((color >> 8) & 0xFF);
    float b = srgb_channel_to_linear(color & 0xFF);
    vector_float4 result = { r * alpha, g * alpha, b * alpha, alpha };
    return result;
}

static inline vector_float3
color_to_linear_rgb(color_type color) {
    return (vector_float3){
        srgb_channel_to_linear((color >> 16) & 0xFF),
        srgb_channel_to_linear((color >> 8) & 0xFF),
        srgb_channel_to_linear(color & 0xFF)
    };
}

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
    uint32_t draw_background_mask;
    uint32_t draw_foreground;
    float extra_alpha;
    float viewport_scale_x;
    float viewport_scale_y;
    float viewport_origin_x;
    float viewport_origin_y;
} MetalDrawParams;

typedef struct {
    vector_float4 src_rect;
    vector_float4 dest_rect;
    float extra_alpha;
    float _pad[3];
} MetalGraphicsUniforms;

typedef struct {
    float x;
    float y;
    float z;
} MetalPackedFloat3;

typedef struct {
    vector_float4 src_rect;
    vector_float4 dest_rect;
    MetalPackedFloat3 foreground_rgb;
    float _pad0;
    vector_float4 background_premul;
} MetalGraphicsAlphaUniforms;

typedef struct {
    float rect[4];
    uint32_t color;
    uint32_t _pad[3];
} MetalBorderRect;

typedef struct {
    vector_float2 size;
    float thickness;
    float radius;
    vector_float4 color;
} MetalRoundedRectUniforms;

typedef struct {
    vector_float2 tex_scale;
} MetalOverlayTextureUniforms;

typedef struct {
    vector_float2 tex_scale;
    vector_float4 color;
} MetalOverlayAlphaUniforms;

_Static_assert(sizeof(MetalTrailUniforms) == 64, "MetalTrailUniforms layout mismatch");
_Static_assert(sizeof(MetalGraphicsUniforms) == 48, "MetalGraphicsUniforms layout mismatch");
_Static_assert(sizeof(MetalGraphicsAlphaUniforms) == 64, "MetalGraphicsAlphaUniforms layout mismatch");

static inline MetalTintUniforms
metal_make_tint_uniforms(vector_float4 edges, vector_float4 color) {
    MetalTintUniforms uniforms = {0};
    memcpy(uniforms.edges, &edges, sizeof(uniforms.edges));
    memcpy(uniforms.color, &color, sizeof(uniforms.color));
    return uniforms;
}

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
    if (metal_debug_events_enabled()) {
        timed_debug_print("metal_event=%s %s\n", event, detail);
    }
    log_error("metal_event=%s %s", event, detail);
}

static void
metal_debug_event(const char *event, const char *fmt, ...) {
    if (!metal_debug_events_enabled()) {
        return;
    }
    va_list args;
    va_start(args, fmt);
    char detail[256];
    vsnprintf(detail, sizeof(detail), fmt, args);
    va_end(args);
    timed_debug_print("metal_event=%s %s\n", event, detail);
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

uint32_t
metal_cell_draw_flag_defaults(void) {
    enum {
        METAL_CELL_DRAW_FLAG_DRAW_BACKGROUND = 1u << 0,
        METAL_CELL_DRAW_FLAG_DRAW_FOREGROUND = 1u << 1,
        METAL_CELL_DRAW_FLAG_ALLOW_EFFECTS   = 1u << 2,
    };
    return METAL_CELL_DRAW_FLAG_DRAW_BACKGROUND |
           METAL_CELL_DRAW_FLAG_DRAW_FOREGROUND |
           METAL_CELL_DRAW_FLAG_ALLOW_EFFECTS;
}

enum {
    METAL_DRAW_BG_DEFAULT = 1u,
    METAL_DRAW_BG_NON_DEFAULT = 2u,
    METAL_DRAW_BG_BOTH = 3u,
};

static inline void
metal_apply_draw_flags(MetalDrawParams *params, uint32_t draw_bg_mask, bool draw_foreground) {
    if (!params) {
        return;
    }
    uint32_t preserved = params->draw_background_mask & ~METAL_DRAW_BG_BOTH;
    params->draw_background_mask = preserved | (draw_bg_mask & METAL_DRAW_BG_BOTH);
    params->draw_foreground = draw_foreground ? 1u : 0u;
}

bool
metal_compute_background_geometry(
    unsigned int framebuffer_width,
    unsigned int framebuffer_height,
    unsigned int image_width,
    unsigned int image_height,
    BackgroundImageLayout layout,
    MetalBackgroundGeometry *out_geometry
) {
    if (!out_geometry) {
        return false;
    }
    if (!framebuffer_width || !framebuffer_height || !image_width || !image_height) {
        memset(out_geometry, 0, sizeof(*out_geometry));
        return false;
    }

    float vwidth = (float)framebuffer_width;
    float vheight = (float)framebuffer_height;
    float iwidth = (float)image_width;
    float iheight = (float)image_height;

    if (layout == CENTER_SCALED && iwidth > 0.f && iheight > 0.f) {
        const float image_ratio = iwidth / iheight;
        const float viewport_ratio = vwidth / vheight;
        if (image_ratio > viewport_ratio) {
            iwidth = vwidth;
            iheight = vwidth / image_ratio;
        } else {
            iheight = vheight;
            iwidth = vheight * image_ratio;
        }
    }

    float left = -1.0f, right = 1.0f, top = 1.0f, bottom = -1.0f;
    float tiled = 0.0f;

    switch (layout) {
        case TILING:
        case MIRRORED:
        case CLAMPED:
            tiled = 1.0f;
            break;
        case SCALED:
            break;
        case CENTER_CLAMPED:
        case CENTER_SCALED: {
            const float wfrac = (vwidth - iwidth) / vwidth;
            const float hfrac = (vheight - iheight) / vheight;
            left += wfrac;
            right -= wfrac;
            top -= hfrac;
            bottom += hfrac;
        } break;
    }

    MetalBackgroundGeometry result = {
        .tiled = tiled,
    };
    result.positions[0] = left;
    result.positions[1] = top;
    result.positions[2] = right;
    result.positions[3] = bottom;
    result.sizes[0] = vwidth;
    result.sizes[1] = vheight;
    result.sizes[2] = iwidth;
    result.sizes[3] = iheight;
    *out_geometry = result;
    return true;
}

typedef struct {
    id<MTLDevice> device;
    id<MTLCommandQueue> command_queue;
    id<MTLLibrary> library;
    id<MTLRenderPipelineState> cell_pipeline;
    id<MTLRenderPipelineState> border_pipeline;
    id<MTLRenderPipelineState> trail_pipeline;
    id<MTLRenderPipelineState> tint_pipeline;
    id<MTLRenderPipelineState> rounded_rect_pipeline;
    id<MTLRenderPipelineState> overlay_texture_pipeline;
    id<MTLRenderPipelineState> alpha_mask_pipeline;
    id<MTLRenderPipelineState> graphics_pipeline;
    id<MTLRenderPipelineState> graphics_premult_pipeline;
    id<MTLRenderPipelineState> graphics_alpha_pipeline;
    id<MTLSamplerState> atlas_sampler;
    bool initialized;
    bool prefer_low_latency;
    bool debug_labels;
    bool debug_events;
    bool capture_frames;
    bool display_sync_enabled;
} MetalGlobalState;

static MetalGlobalState g_metal = {
    .device = nil,
    .command_queue = nil,
    .library = nil,
    .cell_pipeline = nil,
    .border_pipeline = nil,
    .trail_pipeline = nil,
    .tint_pipeline = nil,
    .rounded_rect_pipeline = nil,
    .overlay_texture_pipeline = nil,
    .alpha_mask_pipeline = nil,
    .graphics_pipeline = nil,
    .graphics_premult_pipeline = nil,
    .graphics_alpha_pipeline = nil,
    .atlas_sampler = nil,
    .initialized = false,
    .prefer_low_latency = false,
    .debug_labels = false,
    .debug_events = false,
    .capture_frames = false,
    .display_sync_enabled = true,
};

static bool
metal_zero_texture(id<MTLTexture> texture, NSUInteger width, NSUInteger height, NSUInteger layers) {
    if (!texture || width == 0 || height == 0 || layers == 0) {
        return true;
    }
    const NSUInteger bytes_per_row = width * sizeof(pixel);
    const NSUInteger bytes_per_image = bytes_per_row * height;
    id<MTLBuffer> zero_buffer = [g_metal.device newBufferWithLength:bytes_per_image options:MTLResourceStorageModeShared];
    if (!zero_buffer) {
        metal_log("sprite_texture_clear_failed", "length=%lu", (unsigned long)bytes_per_image);
        return false;
    }
    memset([zero_buffer contents], 0, bytes_per_image);
    const void *zeros = [zero_buffer contents];
    for (NSUInteger slice = 0; slice < layers; slice++) {
        [texture replaceRegion:MTLRegionMake3D(0, 0, 0, width, height, 1)
                   mipmapLevel:0
                         slice:slice
                     withBytes:zeros
                   bytesPerRow:bytes_per_row
                 bytesPerImage:bytes_per_image];
    }
    return true;
}

static inline void
metal_zero_buffer(id<MTLBuffer> buffer, size_t length) {
    if (!buffer || length == 0) {
        return;
    }
    void *dst = [buffer contents];
    if (!dst) {
        return;
    }
    memset(dst, 0, length);
    if ([buffer respondsToSelector:@selector(storageMode)] && [buffer storageMode] == MTLStorageModeManaged) {
        [buffer didModifyRange:NSMakeRange(0, (NSUInteger)length)];
    }
}

enum {
    MetalSpriteIndexMask = 0x7fffffffu,
    MetalMissingGlyphIndex = 1u,
};

static inline bool
metal_debug_events_enabled(void) {
    return g_metal.debug_events;
}

typedef struct {
    uint32_t width;
    uint32_t height;
    uint32_t bytes_per_row;
    const uint8_t *pixels;
    size_t length;
    bool owns_memory;
} MetalCapturedFrameState;

static MetalCapturedFrameState g_metal_capture = {0};

typedef struct {
    id<MTLTexture> texture;
    void *pixels;
    size_t length;
    unsigned int width;
    unsigned int height;
    bool linear_filter;
    BackgroundImageLayout layout;
} MetalBackgroundTexture;

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
static bool metal_blank_stub_for_tests = false;

@interface MetalGraphicsTexture : NSObject
@property (nonatomic, strong) id<MTLTexture> texture;
@property (nonatomic) uint32_t width;
@property (nonatomic) uint32_t height;
@property (nonatomic) BOOL linearFilter;
@property (nonatomic) BOOL isOpaque;
@property (nonatomic) RepeatStrategy repeat;
@end

@implementation MetalGraphicsTexture
@end

static uint32_t next_graphics_texture_id = 1;

static TextureRef metal_window_number_texture = {0};
static TextureRef metal_hyperlink_texture = {0};

static NSMapTable<NSNumber *, MetalGraphicsTexture *> *
graphics_texture_table(void) {
    static NSMapTable<NSNumber *, MetalGraphicsTexture *> *table = nil;
    static dispatch_once_t once_token;
    dispatch_once(&once_token, ^{
        table = [NSMapTable strongToStrongObjectsMapTable];
    });
    return table;
}

static NSMutableDictionary<NSNumber *, id<MTLSamplerState>> *
graphics_sampler_cache(void) {
    static NSMutableDictionary<NSNumber *, id<MTLSamplerState>> *cache = nil;
    static dispatch_once_t once_token;
    dispatch_once(&once_token, ^{
        cache = [[NSMutableDictionary alloc] init];
    });
    return cache;
}

static NSNumber*
graphics_sampler_key(bool linear_filter, RepeatStrategy repeat) {
    uint32_t key = (uint32_t)(linear_filter ? 1u : 0u) << 16;
    key |= (uint32_t)repeat & 0xFFFFu;
    return @(key);
}

static id<MTLSamplerState>
graphics_sampler_for(bool linear_filter, RepeatStrategy repeat) {
    NSMutableDictionary<NSNumber *, id<MTLSamplerState>> *cache = graphics_sampler_cache();
    NSNumber *key = graphics_sampler_key(linear_filter, repeat);
    id<MTLSamplerState> sampler = cache[key];
    if (sampler) {
        return sampler;
    }
    MTLSamplerDescriptor *descriptor = [[MTLSamplerDescriptor alloc] init];
    descriptor.minFilter = linear_filter ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
    descriptor.magFilter = linear_filter ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
    descriptor.mipFilter = MTLSamplerMipFilterNotMipmapped;
    descriptor.normalizedCoordinates = YES;
    switch (repeat) {
        case REPEAT_MIRROR:
            descriptor.sAddressMode = MTLSamplerAddressModeMirrorRepeat;
            descriptor.tAddressMode = MTLSamplerAddressModeMirrorRepeat;
            break;
        case REPEAT_CLAMP:
            descriptor.sAddressMode = MTLSamplerAddressModeClampToEdge;
            descriptor.tAddressMode = MTLSamplerAddressModeClampToEdge;
            break;
        case REPEAT_DEFAULT:
        default:
            descriptor.sAddressMode = MTLSamplerAddressModeRepeat;
            descriptor.tAddressMode = MTLSamplerAddressModeRepeat;
            break;
    }
    sampler = [g_metal.device newSamplerStateWithDescriptor:descriptor];
    if (sampler) {
        cache[key] = sampler;
    }
    return sampler;
}

@interface MetalWindowState : NSObject
@property (nonatomic, strong) CAMetalLayer *layer;
@property (nonatomic, strong) id<CAMetalDrawable> drawable;
@property (nonatomic, strong) id<MTLCommandBuffer> commandBuffer;
@property (nonatomic, assign) id<CAMetalDrawable> lastTintDrawable;
@property (nonatomic) BOOL frameHasContent;
@property (nonatomic) BOOL hasEncodedPass;
@property (nonatomic) MTLLoadAction lastTintLoadAction;
@property (nonatomic) MTLClearColor clearColor;
@property (nonatomic) float backgroundOpacity;
@property (nonatomic) color_type fallbackBackground;
@property (nonatomic, assign) NSView *attachedView;
@property (nonatomic) CGSize lastDrawableSize;
@property (nonatomic) CGFloat lastContentsScale;
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
@property (nonatomic, strong) id<MTLBuffer> captureBuffer;
@property (nonatomic) NSUInteger captureWidth;
@property (nonatomic) NSUInteger captureHeight;
@property (nonatomic) NSUInteger captureBytesPerRow;
@property (nonatomic) BOOL captureValid;
@end

static inline void
metal_record_layer_metrics(MetalWindowState *state, CAMetalLayer *layer) {
    if (!state) return;
    if (layer) {
        state.lastContentsScale = layer.contentsScale;
        state.lastDrawableSize = layer.drawableSize;
    } else {
        state.lastContentsScale = 0.0;
        state.lastDrawableSize = CGSizeZero;
    }
}

static inline void
metal_detach_layer_from_view(MetalWindowState *state) {
    if (!state) return;
    NSView *view = state.attachedView;
    if (view && view.layer == state.layer) {
        view.layer = nil;
    }
    state.attachedView = nil;
}

static bool ensure_command_primitives(GLFWwindow *window, MetalWindowState *state);
static void encode_draw_end(id<MTLRenderCommandEncoder> encoder);
static void set_preflight_failure(const char *reason);
static MTLClearColor clear_color_from(color_type color, float alpha);
static bool metal_encode_cell_pass(GLFWwindow *window, MetalWindowState *state, MetalSpriteAtlas *atlas, size_t instance_count, uint32_t draw_bg_mask, bool draw_foreground, bool allow_clear);
static bool metal_encode_background(GLFWwindow *window, MetalWindowState *state, OSWindow *os_window, color_type fallback_bg);
static bool metal_encode_background_tint(GLFWwindow *window, MetalWindowState *state, color_type background_color);
static bool metal_prepare_window_logo_image(Window *window, unsigned int screen_width, unsigned int screen_height, float inactive_alpha, ImageRenderData *out_image, float *out_extra_alpha);
static bool metal_encode_visual_bell(GLFWwindow *window, MetalWindowState *state, Screen *screen);
static bool metal_encode_scrollbar(GLFWwindow *window, MetalWindowState *state, OSWindow *os_window, Window *render_window, Screen *screen, const WindowGeometry *geometry, unsigned int screen_width_px, unsigned int screen_height_px);
static bool metal_encode_hyperlink_target(GLFWwindow *window, MetalWindowState *state, OSWindow *os_window, Window *render_window, Screen *screen, const WindowGeometry *geometry, unsigned int screen_width_px, unsigned int screen_height_px);
static bool metal_encode_window_number(GLFWwindow *window, MetalWindowState *state, OSWindow *os_window, Window *render_window, Screen *screen, const WindowGeometry *geometry, unsigned int screen_width_px, unsigned int screen_height_px);
static inline void mark_frame_has_content(MetalWindowState *state);
static inline void clear_frame_content(MetalWindowState *state);
static inline void initialize_frame_state(MetalWindowState *state);
static bool encode_clear_pass(GLFWwindow *window, MetalWindowState *state, MTLClearColor clear_color);
static MetalBackgroundTexture* metal_background_texture(BackgroundImage *bgimage);
static bool metal_background_texture_ensure_ready(MetalBackgroundTexture *background);
static void metal_background_texture_dispose(MetalBackgroundTexture *background);
static void metal_clear_last_capture(void);
static void metal_set_last_capture(const uint8_t *pixels, size_t length, uint32_t width, uint32_t height, uint32_t bytes_per_row, bool owns_memory);
static bool metal_capture_framebuffer(MetalWindowState *state);
static void metal_finalize_capture(MetalWindowState *state);
static bool metal_backend_upload_graphics_image(TextureRef *ref, const RendererGraphicsImageUpload *upload);
static void metal_backend_destroy_graphics_image(TextureRef *ref);

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
                metal_zero_buffer(state.cellBuffer, required);
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
                metal_zero_buffer(state.selectionBuffer, required);
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
    if (!metal_zero_texture(newTexture, width, height, layers)) {
        PyErr_SetString(PyExc_RuntimeError, "Metal failed to clear sprite texture");
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
    metal_zero_buffer(newBuffer, newCapacity * sizeof(uint32_t));
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

static MetalBackgroundTexture*
metal_background_texture(BackgroundImage *bgimage) {
    if (!bgimage || !bgimage->metal_texture) {
        return NULL;
    }
    return (MetalBackgroundTexture *)bgimage->metal_texture;
}

static bool
metal_background_texture_ensure_ready(MetalBackgroundTexture *background) {
    if (!background) {
        return false;
    }
    if (background->texture) {
        return true;
    }
    if (!g_metal.device) {
        return false;
    }
    if (!background->pixels || !background->length || !background->width || !background->height) {
        PyErr_SetString(PyExc_RuntimeError, "Metal background texture missing pixel data");
        return false;
    }
    @autoreleasepool {
        MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:background->width height:background->height mipmapped:NO];
        descriptor.usage = MTLTextureUsageShaderRead;
        descriptor.storageMode = MTLStorageModeManaged;
        id<MTLTexture> texture = [g_metal.device newTextureWithDescriptor:descriptor];
        if (!texture) {
            PyErr_SetString(PyExc_RuntimeError, "Failed to allocate Metal background texture");
            return false;
        }
        const NSUInteger bytes_per_row = (NSUInteger)background->width * sizeof(uint32_t);
        MTLRegion region = MTLRegionMake2D(0, 0, background->width, background->height);
        [texture replaceRegion:region mipmapLevel:0 withBytes:background->pixels bytesPerRow:bytes_per_row];
        background->texture = texture;
    }
    free(background->pixels);
    background->pixels = NULL;
    background->length = 0;
    return true;
}

static void
metal_background_texture_dispose(MetalBackgroundTexture *background) {
    if (!background) {
        return;
    }
    @autoreleasepool {
        background->texture = nil;
    }
    if (background->pixels) {
        free(background->pixels);
        background->pixels = NULL;
    }
    background->length = 0;
    free(background);
}

static void
metal_clear_last_capture(void) {
    if (g_metal_capture.owns_memory && g_metal_capture.pixels) {
        free((void *)g_metal_capture.pixels);
    }
    g_metal_capture = (MetalCapturedFrameState){0};
}

static void
metal_reset_capture_state(MetalWindowState *state, bool release_buffer) {
    if (!state) {
        if (release_buffer) {
            metal_clear_last_capture();
        }
        return;
    }
    if (release_buffer && state.captureBuffer) {
        state.captureBuffer = nil;
    }
    clear_frame_content(state);
    state.lastTintLoadAction = MTLLoadActionDontCare;
    state.captureValid = NO;
    state.captureWidth = 0;
    state.captureHeight = 0;
    state.captureBytesPerRow = 0;
    if (release_buffer) {
        metal_clear_last_capture();
    }
}

static void
metal_set_last_capture(const uint8_t *pixels, size_t length, uint32_t width, uint32_t height, uint32_t bytes_per_row, bool owns_memory) {
    metal_clear_last_capture();
    g_metal_capture.width = width;
    g_metal_capture.height = height;
    g_metal_capture.bytes_per_row = bytes_per_row;
    g_metal_capture.pixels = pixels;
    g_metal_capture.length = length;
    g_metal_capture.owns_memory = owns_memory;
}

static void
metal_record_failure(const char *reason) {
    metal_unregister_sprite_hooks();
    g_metal.cell_pipeline = nil;
    g_metal.border_pipeline = nil;
    g_metal.trail_pipeline = nil;
    g_metal.tint_pipeline = nil;
    g_metal.rounded_rect_pipeline = nil;
    g_metal.overlay_texture_pipeline = nil;
    g_metal.alpha_mask_pipeline = nil;
    g_metal.graphics_pipeline = nil;
    g_metal.graphics_premult_pipeline = nil;
    g_metal.graphics_alpha_pipeline = nil;
    g_metal.library = nil;
    g_metal.atlas_sampler = nil;
    g_metal.command_queue = nil;
    g_metal.device = nil;
    g_metal.initialized = false;
    metal_clear_last_capture();
    set_preflight_failure(reason);
}

static NSString *
metal_library_path(void) {
    NSString *result = nil;
    PyGILState_STATE gil = PyGILState_Ensure();
    PyObject *metal_module = PyImport_ImportModule("kitty.metal");
    if (!metal_module) {
        PyErr_Clear();
        PyGILState_Release(gil);
        return result;
    }
    PyObject *path_obj = PyObject_CallMethod(metal_module, "get_cell_metallib_path", NULL);
    Py_DECREF(metal_module);
    if (!path_obj) {
        PyErr_Clear();
        PyGILState_Release(gil);
        return result;
    }
    if (PyUnicode_Check(path_obj)) {
        const char *fs = PyUnicode_AsUTF8(path_obj);
        if (fs) {
            result = [NSString stringWithUTF8String:fs];
        } else {
            PyErr_Clear();
        }
    } else {
        PyErr_Clear();
    }
    Py_DECREF(path_obj);
    PyGILState_Release(gil);
    return result;
}

static bool
metal_ensure_resources(void) {
    if (!g_metal.device) {
        PyErr_SetString(PyExc_RuntimeError, "Metal device unavailable");
        metal_record_failure("Metal device unavailable; Metal renderer cannot continue");
        return false;
    }
    if (!g_metal.library) {
        NSString *path = metal_library_path();
        if (!path) {
            PyErr_SetString(PyExc_RuntimeError, "Unable to locate Metal shader library");
            metal_log("library_path_failed", "reason=not_found");
            metal_record_failure("Metal shader library missing; Metal renderer cannot continue");
            return false;
        }
        NSError *error = nil;
        NSURL *url = [NSURL fileURLWithPath:path isDirectory:NO];
        id<MTLLibrary> library = [g_metal.device newLibraryWithURL:url error:&error];
        if (!library) {
            const char *utf8 = error.localizedDescription ? error.localizedDescription.UTF8String : "unknown";
            PyErr_Format(PyExc_RuntimeError, "Failed to load Metal shader library: %s", utf8);
            metal_log("library_load_failed", "path=%s", path.UTF8String);
            metal_record_failure("Failed to load Metal shader library; Metal renderer cannot continue");
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
            metal_record_failure("Required Metal shader functions missing; Metal renderer cannot continue");
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
            metal_record_failure("Failed to create Metal pipeline state; Metal renderer cannot continue");
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
            metal_record_failure("Required Metal border shader functions missing; Metal renderer cannot continue");
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
            metal_record_failure("Failed to create Metal border pipeline; Metal renderer cannot continue");
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
            metal_record_failure("Required Metal trail shader functions missing; Metal renderer cannot continue");
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
            metal_record_failure("Failed to create Metal trail pipeline; Metal renderer cannot continue");
            return false;
        }
        g_metal.trail_pipeline = pipeline;
    }
    if (!g_metal.tint_pipeline) {
        id<MTLFunction> vertex = [g_metal.library newFunctionWithName:@"kitty::overlay_tint_vertex"];
        if (!vertex) {
            vertex = [g_metal.library newFunctionWithName:@"overlay_tint_vertex"];
        }
        id<MTLFunction> fragment = [g_metal.library newFunctionWithName:@"kitty::overlay_tint_fragment"];
        if (!fragment) {
            fragment = [g_metal.library newFunctionWithName:@"overlay_tint_fragment"];
        }
        if (!vertex || !fragment) {
            PyErr_SetString(PyExc_RuntimeError, "Metal tint shader functions missing from library");
            metal_record_failure("Required Metal tint shader functions missing; Metal renderer cannot continue");
            return false;
        }
        MTLRenderPipelineDescriptor *descriptor = [[MTLRenderPipelineDescriptor alloc] init];
        descriptor.label = @"kitty-tint";
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
            PyErr_Format(PyExc_RuntimeError, "Failed to create Metal tint pipeline state: %s", utf8);
            metal_record_failure("Failed to create Metal tint pipeline; Metal renderer cannot continue");
            return false;
        }
        g_metal.tint_pipeline = pipeline;
    }
    if (!g_metal.rounded_rect_pipeline) {
        id<MTLFunction> vertex = [g_metal.library newFunctionWithName:@"kitty::overlay_rounded_vertex"];
        if (!vertex) {
            vertex = [g_metal.library newFunctionWithName:@"overlay_rounded_vertex"];
        }
        id<MTLFunction> fragment = [g_metal.library newFunctionWithName:@"kitty::overlay_rounded_fragment"];
        if (!fragment) {
            fragment = [g_metal.library newFunctionWithName:@"overlay_rounded_fragment"];
        }
        if (!vertex || !fragment) {
            PyErr_SetString(PyExc_RuntimeError, "Metal rounded-rect shader functions missing from library");
            metal_record_failure("Required Metal rounded-rect shader functions missing; Metal renderer cannot continue");
            return false;
        }
        MTLRenderPipelineDescriptor *descriptor = [[MTLRenderPipelineDescriptor alloc] init];
        descriptor.label = @"kitty-rounded-rect";
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
            PyErr_Format(PyExc_RuntimeError, "Failed to create Metal rounded-rect pipeline state: %s", utf8);
            metal_record_failure("Failed to create Metal rounded-rect pipeline; Metal renderer cannot continue");
            return false;
        }
        g_metal.rounded_rect_pipeline = pipeline;
    }
    if (!g_metal.overlay_texture_pipeline) {
        id<MTLFunction> vertex = [g_metal.library newFunctionWithName:@"kitty::overlay_texture_vertex"];
        if (!vertex) {
            vertex = [g_metal.library newFunctionWithName:@"overlay_texture_vertex"];
        }
        id<MTLFunction> fragment = [g_metal.library newFunctionWithName:@"kitty::overlay_texture_fragment"];
        if (!fragment) {
            fragment = [g_metal.library newFunctionWithName:@"overlay_texture_fragment"];
        }
        if (!vertex || !fragment) {
            PyErr_SetString(PyExc_RuntimeError, "Metal overlay texture shader functions missing from library");
            metal_record_failure("Required Metal overlay texture shader functions missing; Metal renderer cannot continue");
            return false;
        }
        MTLRenderPipelineDescriptor *descriptor = [[MTLRenderPipelineDescriptor alloc] init];
        descriptor.label = @"kitty-overlay-texture";
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
            PyErr_Format(PyExc_RuntimeError, "Failed to create Metal overlay texture pipeline state: %s", utf8);
            metal_record_failure("Failed to create Metal overlay texture pipeline; Metal renderer cannot continue");
            return false;
        }
        g_metal.overlay_texture_pipeline = pipeline;
    }
    if (!g_metal.alpha_mask_pipeline) {
        id<MTLFunction> vertex = [g_metal.library newFunctionWithName:@"kitty::overlay_alpha_vertex"];
        if (!vertex) {
            vertex = [g_metal.library newFunctionWithName:@"overlay_alpha_vertex"];
        }
        id<MTLFunction> fragment = [g_metal.library newFunctionWithName:@"kitty::overlay_alpha_fragment"];
        if (!fragment) {
            fragment = [g_metal.library newFunctionWithName:@"overlay_alpha_fragment"];
        }
        if (!vertex || !fragment) {
            PyErr_SetString(PyExc_RuntimeError, "Metal overlay alpha shader functions missing from library");
            metal_record_failure("Required Metal overlay alpha shader functions missing; Metal renderer cannot continue");
            return false;
        }
        MTLRenderPipelineDescriptor *descriptor = [[MTLRenderPipelineDescriptor alloc] init];
        descriptor.label = @"kitty-overlay-alpha";
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
            PyErr_Format(PyExc_RuntimeError, "Failed to create Metal overlay alpha pipeline state: %s", utf8);
            metal_record_failure("Failed to create Metal overlay alpha pipeline; Metal renderer cannot continue");
            return false;
        }
        g_metal.alpha_mask_pipeline = pipeline;
    }

    if (!g_metal.graphics_pipeline) {
        id<MTLFunction> vertex = [g_metal.library newFunctionWithName:@"kitty::graphics_vertex"];
        if (!vertex) {
            vertex = [g_metal.library newFunctionWithName:@"graphics_vertex"];
        }
        id<MTLFunction> fragment = [g_metal.library newFunctionWithName:@"kitty::graphics_fragment"];
        if (!fragment) {
            fragment = [g_metal.library newFunctionWithName:@"graphics_fragment"];
        }
        if (!vertex || !fragment) {
            PyErr_SetString(PyExc_RuntimeError, "Metal graphics shader functions missing from library");
            metal_record_failure("Required Metal graphics shader functions missing; Metal renderer cannot continue");
            return false;
        }
        MTLRenderPipelineDescriptor *descriptor = [[MTLRenderPipelineDescriptor alloc] init];
        descriptor.label = @"kitty-graphics";
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
        id<MTLRenderPipelineState> pipeline =
            [g_metal.device newRenderPipelineStateWithDescriptor:descriptor error:&error];
        if (!pipeline) {
            const char *utf8 = error.localizedDescription ? error.localizedDescription.UTF8String : "unknown";
            PyErr_Format(PyExc_RuntimeError, "Failed to create Metal graphics pipeline state: %s", utf8);
            metal_record_failure("Failed to create Metal graphics pipeline; Metal renderer cannot continue");
            return false;
        }
        g_metal.graphics_pipeline = pipeline;
    }

    if (!g_metal.graphics_premult_pipeline) {
        id<MTLFunction> vertex = [g_metal.library newFunctionWithName:@"kitty::graphics_vertex"];
        if (!vertex) {
            vertex = [g_metal.library newFunctionWithName:@"graphics_vertex"];
        }
        id<MTLFunction> fragment = [g_metal.library newFunctionWithName:@"kitty::graphics_premult_fragment"];
        if (!fragment) {
            fragment = [g_metal.library newFunctionWithName:@"graphics_premult_fragment"];
        }
        if (!vertex || !fragment) {
            PyErr_SetString(PyExc_RuntimeError, "Metal graphics premult shader functions missing from library");
            metal_record_failure("Required Metal graphics premult shader functions missing; Metal renderer cannot continue");
            return false;
        }
        MTLRenderPipelineDescriptor *descriptor = [[MTLRenderPipelineDescriptor alloc] init];
        descriptor.label = @"kitty-graphics-premult";
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
        id<MTLRenderPipelineState> pipeline =
            [g_metal.device newRenderPipelineStateWithDescriptor:descriptor error:&error];
        if (!pipeline) {
            const char *utf8 = error.localizedDescription ? error.localizedDescription.UTF8String : "unknown";
            PyErr_Format(PyExc_RuntimeError, "Failed to create Metal graphics premult pipeline state: %s", utf8);
            metal_record_failure("Failed to create Metal graphics premult pipeline; Metal renderer cannot continue");
            return false;
        }
        g_metal.graphics_premult_pipeline = pipeline;
    }

    if (!g_metal.graphics_alpha_pipeline) {
        id<MTLFunction> vertex = [g_metal.library newFunctionWithName:@"kitty::graphics_alpha_vertex"];
        if (!vertex) {
            vertex = [g_metal.library newFunctionWithName:@"graphics_alpha_vertex"];
        }
        id<MTLFunction> fragment = [g_metal.library newFunctionWithName:@"kitty::graphics_alpha_fragment"];
        if (!fragment) {
            fragment = [g_metal.library newFunctionWithName:@"graphics_alpha_fragment"];
        }
        if (!vertex || !fragment) {
            PyErr_SetString(PyExc_RuntimeError, "Metal graphics alpha shader functions missing from library");
            metal_record_failure("Required Metal graphics alpha shader functions missing; Metal renderer cannot continue");
            return false;
        }
        MTLRenderPipelineDescriptor *descriptor = [[MTLRenderPipelineDescriptor alloc] init];
        descriptor.label = @"kitty-graphics-alpha";
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
        id<MTLRenderPipelineState> pipeline =
            [g_metal.device newRenderPipelineStateWithDescriptor:descriptor error:&error];
        if (!pipeline) {
            const char *utf8 = error.localizedDescription ? error.localizedDescription.UTF8String : "unknown";
            PyErr_Format(PyExc_RuntimeError, "Failed to create Metal graphics alpha pipeline state: %s", utf8);
            metal_record_failure("Failed to create Metal graphics alpha pipeline; Metal renderer cannot continue");
            return false;
        }
        g_metal.graphics_alpha_pipeline = pipeline;
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
            metal_record_failure("Failed to create Metal sampler state; Metal renderer cannot continue");
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
        metal_zero_buffer(state.uniformBuffer, required);
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
    params.draw_background_mask = metal_cell_draw_flag_defaults();
    params.draw_foreground = 1u;
    params.extra_alpha = 1.0f;
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
    const bool has_background_image = os_window && metal_background_texture(os_window->bgimage);
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
    mark_frame_has_content(state);
    return true;
}

static inline MetalGraphicsUniforms
metal_pack_graphics_uniforms(const ImageRenderData *rd, float extra_alpha) {
    MetalGraphicsUniforms uniforms = {
        .src_rect = { rd->src_rect.left, rd->src_rect.top, rd->src_rect.right, rd->src_rect.bottom },
        .dest_rect = { rd->dest_rect.left, rd->dest_rect.top, rd->dest_rect.right, rd->dest_rect.bottom },
        .extra_alpha = extra_alpha,
        ._pad = {0.f, 0.f, 0.f},
    };
    return uniforms;
}

static inline MetalGraphicsAlphaUniforms
metal_pack_graphics_alpha_uniforms(
    const ImageRenderData *rd,
    MetalPackedFloat3 foreground_rgb,
    vector_float4 background_premul
) {
    MetalGraphicsAlphaUniforms uniforms = {
        .src_rect = { rd->src_rect.left, rd->src_rect.top, rd->src_rect.right, rd->src_rect.bottom },
        .dest_rect = { rd->dest_rect.left, rd->dest_rect.top, rd->dest_rect.right, rd->dest_rect.bottom },
        .foreground_rgb = foreground_rgb,
        ._pad0 = 0.f,
        .background_premul = background_premul,
    };
    return uniforms;
}

static id<MTLRenderPipelineState>
metal_pipeline_for_graphics_texture(const MetalGraphicsTexture *texture) {
    if (!texture) {
        return nil;
    }
    if (texture.isOpaque) {
        return g_metal.graphics_premult_pipeline ? g_metal.graphics_premult_pipeline : g_metal.graphics_pipeline;
    }
    return g_metal.graphics_pipeline;
}

static bool
metal_encode_graphics_bucket(
    GLFWwindow *window,
    MetalWindowState *state,
    const GraphicsRenderData *grd,
    size_t start,
    size_t count,
    float extra_alpha
) {
    if (!grd || count == 0) {
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

    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    if (!pass) {
        PyErr_SetString(PyExc_RuntimeError, "Failed to allocate Metal render pass descriptor for graphics bucket");
        return false;
    }
    pass.colorAttachments[0].texture = state.drawable.texture;
    pass.colorAttachments[0].loadAction = state.frameHasContent ? MTLLoadActionLoad : MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = state.clearColor;

    id<MTLRenderCommandEncoder> encoder = [state.commandBuffer renderCommandEncoderWithDescriptor:pass];
    if (!encoder) {
        PyErr_SetString(PyExc_RuntimeError, "Failed to create Metal graphics bucket encoder");
        return false;
    }
    if (g_metal.debug_labels) {
        encoder.label = @"kitty-inline-graphics";
    }

    id<MTLRenderPipelineState> current_pipeline = nil;
    id<MTLSamplerState> current_sampler = nil;

    size_t index = 0;
    while (index < count) {
        const ImageRenderData *rd = grd->images + start + index;
        size_t group = rd->group_count ? MIN((size_t)rd->group_count, count - index) : 1;
        MetalGraphicsTexture *texture = [graphics_texture_table() objectForKey:@(rd->texture_id)];
        if (!texture || !texture.texture) {
            index += group;
            continue;
        }
        id<MTLRenderPipelineState> pipeline = metal_pipeline_for_graphics_texture(texture);
        if (!pipeline) {
            index += group;
            continue;
        }
        if (pipeline != current_pipeline) {
            [encoder setRenderPipelineState:pipeline];
            current_pipeline = pipeline;
        }
        id<MTLSamplerState> sampler = graphics_sampler_for(texture.linearFilter, texture.repeat);
        if (sampler && sampler != current_sampler) {
            [encoder setFragmentSamplerState:sampler atIndex:0];
            current_sampler = sampler;
        }
        [encoder setFragmentTexture:texture.texture atIndex:0];

        for (size_t i = 0; i < group && index + i < count; ++i) {
            const ImageRenderData *item = grd->images + start + index + i;
            MetalGraphicsUniforms uniforms = metal_pack_graphics_uniforms(item, extra_alpha);
            [encoder setVertexBytes:&uniforms length:sizeof(MetalGraphicsUniforms) atIndex:0];
            [encoder setFragmentBytes:&uniforms length:sizeof(MetalGraphicsUniforms) atIndex:1];
            [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        }

        index += group;
    }

    encode_draw_end(encoder);
    mark_frame_has_content(state);
    return true;
}

static bool
metal_encode_graphics_alpha_bucket(
    GLFWwindow *window,
    MetalWindowState *state,
    const ImageRenderData *images,
    size_t start,
    size_t count,
    vector_float3 foreground_rgb,
    vector_float4 background_premul,
    float extra_alpha
) {
    if (!images || count == 0) {
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

    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    if (!pass) {
        PyErr_SetString(PyExc_RuntimeError, "Failed to allocate Metal render pass descriptor for graphics alpha bucket");
        return false;
    }
    pass.colorAttachments[0].texture = state.drawable.texture;
    pass.colorAttachments[0].loadAction = state.frameHasContent ? MTLLoadActionLoad : MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = state.clearColor;

    id<MTLRenderCommandEncoder> encoder = [state.commandBuffer renderCommandEncoderWithDescriptor:pass];
    if (!encoder) {
        PyErr_SetString(PyExc_RuntimeError, "Failed to create Metal graphics alpha bucket encoder");
        return false;
    }
    if (g_metal.debug_labels) {
        encoder.label = @"kitty-inline-graphics-alpha";
    }
    [encoder setRenderPipelineState:g_metal.graphics_alpha_pipeline];

    id<MTLSamplerState> current_sampler = nil;
    size_t index = 0;
    while (index < count) {
        const ImageRenderData *rd = images + start + index;
        size_t group = rd->group_count ? MIN((size_t)rd->group_count, count - index) : 1;
        MetalGraphicsTexture *texture = [graphics_texture_table() objectForKey:@(rd->texture_id)];
        if (!texture || !texture.texture) {
            index += group;
            continue;
        }
        id<MTLSamplerState> sampler = graphics_sampler_for(texture.linearFilter, texture.repeat);
        if (sampler && sampler != current_sampler) {
            [encoder setFragmentSamplerState:sampler atIndex:0];
            current_sampler = sampler;
        }
        [encoder setFragmentTexture:texture.texture atIndex:0];

        for (size_t i = 0; i < group && index + i < count; ++i) {
            const ImageRenderData *item = images + start + index + i;
            vector_float3 fg_vec = foreground_rgb * extra_alpha;
            MetalPackedFloat3 fg = { fg_vec.x, fg_vec.y, fg_vec.z };
            vector_float4 bg = background_premul * extra_alpha;
            MetalGraphicsAlphaUniforms uniforms = metal_pack_graphics_alpha_uniforms(item, fg, bg);
            [encoder setVertexBytes:&uniforms length:sizeof(MetalGraphicsAlphaUniforms) atIndex:0];
            [encoder setFragmentBytes:&uniforms length:sizeof(MetalGraphicsAlphaUniforms) atIndex:1];
            [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        }

        index += group;
    }

    encode_draw_end(encoder);
    mark_frame_has_content(state);
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
    mark_frame_has_content(state);
    return true;
}

static bool
metal_render_pass_for_render_data(
    GLFWwindow *window,
    MetalWindowState *state,
    OSWindow *os_window,
    WindowRenderData *render_data,
    Window *render_window,
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
    bool should_clear_missing_cells = false;
    if (state.cellBuffer) {
        const GPUCell *cells = (const GPUCell *)state.cellBuffer.contents;
        if (cells) {
            size_t sample_count = instance_count < (size_t)64 ? instance_count : (size_t)64;
            bool all_missing = sample_count > 0;
            for (size_t i = 0; i < sample_count; i++) {
                if ((cells[i].sprite_idx & MetalSpriteIndexMask) != MetalMissingGlyphIndex) {
                    all_missing = false;
                    break;
                }
            }
            if (all_missing) {
                should_clear_missing_cells = true;
            }
        } else if (!state.frameHasContent) {
            should_clear_missing_cells = true;
        }
    }
    if (should_clear_missing_cells) {
        if (state.frameHasContent) {
            clear_frame_content(state);
        }
        return encode_clear_pass(window, state, state.clearColor);
    }
    if (!frame_result.cell_data_changed && !state.frameHasContent) {
        return encode_clear_pass(window, state, state.clearColor);
    }

    const WindowGeometry *geometry = &render_data->geometry;
    const unsigned int screen_width_px = geometry->right - geometry->left;
    const unsigned int screen_height_px = geometry->bottom - geometry->top;
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
    GraphicsManager *grman = screen->paused_rendering.expires_at && screen->paused_rendering.grman
        ? screen->paused_rendering.grman
        : screen->grman;
    GraphicsRenderData grd = grman_render_data(grman);
    const size_t graphics_below = grd.num_of_below_refs;
    const size_t graphics_negative = grd.num_of_negative_refs;
    const size_t graphics_positive = grd.num_of_positive_refs;
    const bool has_background_image = os_window && metal_background_texture(os_window->bgimage);
    ImageRenderData window_logo_image = {0};
    float window_logo_alpha = 0.f;
    bool has_window_logo = false;
    if (render_window) {
        has_window_logo = metal_prepare_window_logo_image(
            render_window,
            screen_width_px,
            screen_height_px,
            inactive_alpha,
            &window_logo_image,
            &window_logo_alpha
        );
    }
    const bool has_between_content = has_window_logo || graphics_below > 0 || graphics_negative > 0;

    bool allow_clear = !state.frameHasContent;

    if (has_between_content) {
        if (!has_background_image) {
            if (!metal_encode_cell_pass(window, state, atlas, instance_count, METAL_DRAW_BG_DEFAULT, false, allow_clear)) {
                return false;
            }
            allow_clear = false;
        }
        if (has_window_logo) {
            GraphicsRenderData logo_data = {
                .count = 1,
                .images = &window_logo_image,
            };
            if (!metal_encode_graphics_bucket(window, state, &logo_data, 0, 1, window_logo_alpha)) {
                return false;
            }
            allow_clear = false;
        }
        if (!metal_encode_graphics_bucket(window, state, &grd, 0, graphics_below, inactive_alpha)) {
            return false;
        }
        if (!metal_encode_cell_pass(window, state, atlas, instance_count, METAL_DRAW_BG_NON_DEFAULT, false, allow_clear)) {
            return false;
        }
        allow_clear = false;
        if (!metal_encode_graphics_bucket(window, state, &grd, graphics_below, graphics_negative, inactive_alpha)) {
            return false;
        }
        if (!metal_encode_cell_pass(window, state, atlas, instance_count, 0u, true, false)) {
            return false;
        }
    } else {
        uint32_t draw_mask = has_background_image ? METAL_DRAW_BG_NON_DEFAULT : METAL_DRAW_BG_BOTH;
        if (!metal_encode_cell_pass(window, state, atlas, instance_count, draw_mask, true, allow_clear)) {
            return false;
        }
        if (has_window_logo) {
            GraphicsRenderData logo_data = {
                .count = 1,
                .images = &window_logo_image,
            };
            if (!metal_encode_graphics_bucket(window, state, &logo_data, 0, 1, window_logo_alpha)) {
                return false;
            }
        }
    }

    if (!metal_encode_graphics_bucket(
            window,
            state,
            &grd,
            graphics_below + graphics_negative,
            graphics_positive,
            inactive_alpha)) {
        return false;
    }
    if (!metal_encode_visual_bell(window, state, screen)) {
        return false;
    }
    if (!metal_encode_scrollbar(window, state, os_window, render_window, screen, geometry, screen_width_px, screen_height_px)) {
        return false;
    }
    if (!metal_encode_hyperlink_target(window, state, os_window, render_window, screen, geometry, screen_width_px, screen_height_px)) {
        return false;
    }
    if (!metal_encode_window_number(window, state, os_window, render_window, screen, geometry, screen_width_px, screen_height_px)) {
        return false;
    }
    return true;
}

static bool
metal_encode_cell_pass(
    GLFWwindow *window,
   MetalWindowState *state,
    MetalSpriteAtlas *atlas,
    size_t instance_count,
    uint32_t draw_bg_mask,
    bool draw_foreground,
    bool allow_clear
) {
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
    bool should_clear = !state.frameHasContent && allow_clear;
    pass.colorAttachments[0].loadAction = should_clear ? MTLLoadActionClear : MTLLoadActionLoad;
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

    MetalDrawParams params = state.drawParams;
    metal_apply_draw_flags(&params, draw_bg_mask, draw_foreground);

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
    [encoder setVertexBytes:&params length:sizeof(MetalDrawParams) atIndex:4];
    [encoder setFragmentBuffer:state.uniformBuffer offset:0 atIndex:0];
    [encoder setFragmentBytes:&params length:sizeof(MetalDrawParams) atIndex:1];
    [encoder setFragmentTexture:atlas->spriteTexture atIndex:0];
    if (g_metal.atlas_sampler) {
        [encoder setFragmentSamplerState:g_metal.atlas_sampler atIndex:0];
    }

    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4 instanceCount:(NSUInteger)instance_count];
    encode_draw_end(encoder);
    mark_frame_has_content(state);
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
        initialize_frame_state(state);
        [table setObject:state forKey:key];
    }
    return state;
}

static void
remove_state_for_window(GLFWwindow *window) {
    [window_state_table() removeObjectForKey:window_key(window)];
}

static inline void
mark_frame_has_content(MetalWindowState *state) {
    if (!state) return;
    state.frameHasContent = YES;
    state.hasEncodedPass = YES;
}

static inline void
clear_frame_content(MetalWindowState *state) {
    if (!state) return;
    state.frameHasContent = NO;
    state.hasEncodedPass = NO;
    state.lastTintDrawable = nil;
}

static inline void
initialize_frame_state(MetalWindowState *state) {
    clear_frame_content(state);
    state.lastTintLoadAction = MTLLoadActionDontCare;
}

static inline void
reset_command_primitives(MetalWindowState *state) {
    if (!state) return;
    state.commandBuffer = nil;
    state.drawable = nil;
    clear_frame_content(state);
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
        metal_log(
            "command_primitives_layer_missing",
            "state=%p layer=%p",
            state,
            state ? state.layer : nil
        );
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
        if (g_metal.debug_labels || g_metal.debug_events) {
            metal_debug_event("command_primitives_ready", "drawable=%p command_buffer=%p", state.drawable, state.commandBuffer);
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
        if (g_metal.debug_events) {
            metal_debug_event(
                "clear_pass",
                "drawable=%p load_action=%u frame_has_content=%d clear_alpha=%.3f",
                state.drawable,
                pass.colorAttachments[0].loadAction,
                state.frameHasContent ? 1 : 0,
                (double)pass.colorAttachments[0].clearColor.alpha
            );
        }

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
    mark_frame_has_content(state);
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
    metal_reset_capture_state(state, true);
    metal_detach_layer_from_view(state);
    state.layer = nil;
    metal_record_layer_metrics(state, nil);
    remove_state_for_window(window);
}

static void
update_layer_properties(MetalWindowState *state, CAMetalLayer *layer, const RendererResizeParams *params) {
    if (!layer) {
        metal_record_layer_metrics(state, nil);
        return;
    }
    if (params) {
        layer.contentsScale = params->framebuffer_scale > 0.f ? params->framebuffer_scale : 1.f;
        const int width = params->framebuffer_width > 0 ? params->framebuffer_width : 0;
        const int height = params->framebuffer_height > 0 ? params->framebuffer_height : 0;
        CGSize drawable_size = CGSizeMake((CGFloat)width, (CGFloat)height);
        layer.drawableSize = drawable_size;
    } else {
        layer.contentsScale = layer.contentsScale > 0.0 ? layer.contentsScale : 1.0;
        if (layer.superlayer) {
            layer.frame = layer.superlayer.bounds;
        }
    }
    metal_record_layer_metrics(state, layer);
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
                NSString *library_path = metal_library_path();
                if (!library_path || ![[NSFileManager defaultManager] fileExistsAtPath:library_path]) {
                    set_preflight_failure("Metal shader library missing; Metal renderer cannot continue.");
                } else {
                    preflight_success = true;
                    preflight_failure_reason = NULL;
                }
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
                metal_record_failure("Metal device creation failed; Metal renderer cannot continue");
                return false;
            }
            id<MTLCommandQueue> queue = [device newCommandQueue];
            if (!queue) {
                PyErr_SetString(PyExc_RuntimeError, "Failed to create Metal command queue");
                metal_log("command_queue_create_failed", "device=%p", device);
                metal_record_failure("Metal command queue creation failed; Metal renderer cannot continue");
                return false;
            }
            g_metal.device = device;
            g_metal.command_queue = queue;
            g_metal.initialized = true;
        }
    }
    if (cfg) {
        g_metal.prefer_low_latency = cfg->prefer_low_latency;
        g_metal.debug_labels = cfg->enable_debug_labels;
        g_metal.debug_events = cfg->enable_debug_logging;
        g_metal.capture_frames = cfg->enable_frame_capture;
    }
    metal_log(
        "init_config",
        "prefer_low_latency=%d debug_labels=%d debug_logging=%d frame_capture=%d",
        g_metal.prefer_low_latency ? 1 : 0,
        g_metal.debug_labels ? 1 : 0,
        g_metal.debug_events ? 1 : 0,
        g_metal.capture_frames ? 1 : 0
    );
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
    metal_backend_destroy_graphics_image(&metal_window_number_texture);
    metal_window_number_texture = (TextureRef){0};
    metal_backend_destroy_graphics_image(&metal_hyperlink_texture);
    metal_hyperlink_texture = (TextureRef){0};
    metal_unregister_sprite_hooks();
    g_metal.cell_pipeline = nil;
    g_metal.border_pipeline = nil;
    g_metal.trail_pipeline = nil;
    g_metal.tint_pipeline = nil;
    g_metal.rounded_rect_pipeline = nil;
    g_metal.overlay_texture_pipeline = nil;
    g_metal.alpha_mask_pipeline = nil;
    g_metal.library = nil;
    g_metal.atlas_sampler = nil;
    g_metal.command_queue = nil;
    g_metal.device = nil;
    g_metal.initialized = false;
    metal_clear_last_capture();
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
    metal_detach_layer_from_view(state);

    CAMetalLayer *layer = state.layer;
    @autoreleasepool {
        if (!layer) {
            layer = [CAMetalLayer layer];
            if (!layer) {
                PyErr_SetString(PyExc_RuntimeError, "Failed to create CAMetalLayer");
                destroy_window_state(window);
                return false;
            }
            state.layer = layer;
        }
        layer.device = g_metal.device;
        layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        layer.framebufferOnly = YES;
        layer.allowsNextDrawableTimeout = NO;
        layer.presentsWithTransaction = NO;
        layer.opaque = config ? !config->wants_transparency : YES;
        layer.displaySyncEnabled = g_metal.display_sync_enabled;
        const CGFloat backing_scale = ns_window.backingScaleFactor;
        const CGFloat contents_scale = backing_scale > 0.0 ? backing_scale : 1.0;
        layer.contentsScale = contents_scale;
        CGSize bounds_size = content_view.bounds.size;
        CGSize drawable_size = CGSizeMake(bounds_size.width * contents_scale,
                                          bounds_size.height * contents_scale);
        layer.drawableSize = drawable_size;

        content_view.wantsLayer = YES;
        content_view.layer = layer;
        state.attachedView = content_view;
        state.layer = layer;
        initialize_frame_state(state);

        RendererResizeParams initial_params = {
            .framebuffer_width = (int)lround(drawable_size.width),
            .framebuffer_height = (int)lround(drawable_size.height),
            .framebuffer_scale = (float)contents_scale,
        };
        update_layer_properties(state, layer, &initial_params);
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
    metal_log(
        "render_begin",
        "window=%p os_window=%p command_buffer=%p drawable=%p",
        window,
        os_window,
        state.commandBuffer,
        state.drawable
    );
    if (!os_window) {
        metal_log("render_no_os_window", "window=%p", window);
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

    if (!metal_encode_background(window, state, os_window, fallback_bg)) {
        return false;
    }

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
        if (!metal_render_pass_for_render_data(window, state, os_window, &os_window->tab_bar_render_data, NULL, false, true, is_single_window)) {
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
            if (!metal_render_pass_for_render_data(window, state, os_window, &w->render_data, w, is_active, false, is_single_window)) {
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
    if (!state.commandBuffer || !state.drawable) {
        metal_debug_event("present_retry", "cause=missing_primitives command_buffer=%p drawable=%p", state.commandBuffer, state.drawable);
        if (!encode_clear_pass(window, state, state.clearColor)) {
            return false;
        }
    }
    const bool wants_capture = g_metal.capture_frames || (params && params->capture_framebuffer);
    if (wants_capture) {
        if (!metal_capture_framebuffer(state)) {
            return false;
        }
    }
    @autoreleasepool {
        [state.commandBuffer presentDrawable:state.drawable];
        [state.commandBuffer commit];
        const bool blocking = params ? params->blocking : true;
        if (wants_capture || blocking) {
            [state.commandBuffer waitUntilCompleted];
        } else {
            [state.commandBuffer waitUntilScheduled];
        }
    }
    if (wants_capture) {
        metal_finalize_capture(state);
    }
    if (g_metal.debug_labels || g_metal.debug_events) {
        const bool blocking = wants_capture ? true : (params ? params->blocking : true);
        metal_debug_event("present", "drawable=%p blocking=%d", state.drawable, blocking ? 1 : 0);
    }
    reset_command_primitives(state);
    return true;
}

static void
metal_backend_on_resize(GLFWwindow *window, const RendererResizeParams *params) {
    MetalWindowState *state = state_for_window(window);
    if (!state) return;
    metal_reset_capture_state(state, false);
    reset_command_primitives(state);
    initialize_frame_state(state);
    if (params) {
        state.lastContentsScale = params->framebuffer_scale > 0.f ? params->framebuffer_scale : 1.f;
        const int width = params->framebuffer_width > 0 ? params->framebuffer_width : 0;
        const int height = params->framebuffer_height > 0 ? params->framebuffer_height : 0;
        state.lastDrawableSize = CGSizeMake((CGFloat)width, (CGFloat)height);
    }
    if (!state.layer) return;
    @autoreleasepool {
        update_layer_properties(state, state.layer, params);
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

static inline bool
metal_should_clear_tint(bool has_encoded_pass, bool frame_has_content, bool drawable_changed) {
    return drawable_changed || !(has_encoded_pass && frame_has_content);
}

static bool
metal_encode_background_tint(GLFWwindow *window, MetalWindowState *state, color_type background_color) {
    (void)window;
    if (!state || OPT(background_tint) <= 0.f) {
        metal_log(
            "background_tint_skip",
            "state=%p tint=%f",
            state,
            OPT(background_tint)
        );
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
    const bool drawable_changed = state.lastTintDrawable != state.drawable;
    const bool should_clear = metal_should_clear_tint(
        state.hasEncodedPass,
        state.frameHasContent,
        drawable_changed
    );
    @autoreleasepool {
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        if (!pass) {
            PyErr_SetString(PyExc_RuntimeError, "Failed to allocate Metal render pass descriptor for background tint");
            return false;
        }
        pass.colorAttachments[0].texture = state.drawable.texture;
        pass.colorAttachments[0].loadAction = should_clear ? MTLLoadActionClear : MTLLoadActionLoad;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].clearColor = state.clearColor;
        if (g_metal.debug_events) {
            metal_debug_event(
                "background_tint_pass",
                "drawable=%p last_drawable=%p drawable_changed=%d has_encoded_pass=%d frame_has_content=%d load_action=%u should_clear=%d",
                state.drawable,
                state.lastTintDrawable,
                drawable_changed ? 1 : 0,
                state.hasEncodedPass ? 1 : 0,
                state.frameHasContent ? 1 : 0,
                pass.colorAttachments[0].loadAction,
                should_clear ? 1 : 0
            );
        }
        id<MTLRenderCommandEncoder> encoder = [state.commandBuffer renderCommandEncoderWithDescriptor:pass];
        if (!encoder) {
            PyErr_SetString(PyExc_RuntimeError, "Failed to create Metal command encoder for background tint");
            return false;
        }
        if (g_metal.debug_labels) {
            encoder.label = @"kitty-background-tint";
        }
        state.lastTintLoadAction = pass.colorAttachments[0].loadAction;
        state.lastTintDrawable = state.drawable;
        [encoder setViewport:(MTLViewport){
            .originX = 0.0,
            .originY = 0.0,
            .width = state.drawable.texture.width,
            .height = state.drawable.texture.height,
            .znear = 0.0,
            .zfar = 1.0
        }];
        [encoder setRenderPipelineState:g_metal.tint_pipeline];
        vector_float4 tint_edges = { -1.f, 1.f, 1.f, -1.f };
        vector_float4 tint_color = color_to_linear_premult(background_color, (float)OPT(background_tint));
        MetalTintUniforms uniforms = metal_make_tint_uniforms(tint_edges, tint_color);
        [encoder setVertexBytes:&uniforms length:sizeof uniforms atIndex:0];
        [encoder setFragmentBytes:&uniforms length:sizeof uniforms atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        encode_draw_end(encoder);
    }
    mark_frame_has_content(state);
    return true;
}

static bool
metal_encode_background(
    GLFWwindow *window,
    MetalWindowState *state,
    OSWindow *os_window,
    color_type fallback_bg
) {
    if (!state || !os_window) {
        metal_log(
            "background_skip_state",
            "state=%p os_window=%p",
            state,
            os_window
        );
        return true;
    }
    BackgroundImage *bgimage = os_window->bgimage;
    MetalBackgroundTexture *background = metal_background_texture(bgimage);
    if (background) {
        if (!metal_background_texture_ensure_ready(background)) {
            if (PyErr_Occurred()) {
                return false;
            }
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
        const unsigned int fb_width = (unsigned int)state.drawable.texture.width;
        const unsigned int fb_height = (unsigned int)state.drawable.texture.height;
        MetalBackgroundGeometry geometry = {0};
        if (!metal_compute_background_geometry(
                fb_width,
                fb_height,
                background->width,
                background->height,
                background->layout,
                &geometry)) {
            return true;
        }
        const float left = geometry.positions[0];
        const float right = geometry.positions[2];
        const float top = geometry.positions[1];
        const float bottom = geometry.positions[3];
        if (left == right || top == bottom) {
            return true;
        }
        @autoreleasepool {
            MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
            if (!pass) {
                PyErr_SetString(PyExc_RuntimeError, "Failed to allocate Metal render pass descriptor for background image");
                return false;
            }
            pass.colorAttachments[0].texture = state.drawable.texture;
            pass.colorAttachments[0].loadAction = state.frameHasContent ? MTLLoadActionLoad : MTLLoadActionClear;
            pass.colorAttachments[0].storeAction = MTLStoreActionStore;
            pass.colorAttachments[0].clearColor = state.clearColor;
            if (g_metal.debug_events) {
                metal_debug_event(
                    "background_image_pass",
                    "drawable=%p load_action=%u frame_has_content=%d clear_alpha=%.3f",
                    state.drawable,
                    pass.colorAttachments[0].loadAction,
                    state.frameHasContent ? 1 : 0,
                    (double)pass.colorAttachments[0].clearColor.alpha
                );
            }
            id<MTLRenderCommandEncoder> encoder = [state.commandBuffer renderCommandEncoderWithDescriptor:pass];
            if (!encoder) {
                PyErr_SetString(PyExc_RuntimeError, "Failed to create Metal command encoder for background image");
                return false;
            }
            if (g_metal.debug_labels) {
                encoder.label = @"kitty-background-image";
            }
            const double pixel_left = ((double)left + 1.0) * 0.5 * (double)fb_width;
            const double pixel_right = ((double)right + 1.0) * 0.5 * (double)fb_width;
            const double pixel_bottom = ((double)bottom + 1.0) * 0.5 * (double)fb_height;
            const double pixel_top = ((double)top + 1.0) * 0.5 * (double)fb_height;
            const double origin_x = MIN(pixel_left, pixel_right);
            const double origin_y = MIN(pixel_bottom, pixel_top);
            const double viewport_width = fabs(pixel_right - pixel_left);
            const double viewport_height = fabs(pixel_top - pixel_bottom);
            if (viewport_width <= 0.0 || viewport_height <= 0.0) {
                encode_draw_end(encoder);
                return true;
            }
            MTLViewport viewport = {
                .originX = origin_x,
                .originY = origin_y,
                .width = viewport_width,
                .height = viewport_height,
                .znear = 0.0,
                .zfar = 1.0,
            };
            [encoder setViewport:viewport];
            [encoder setRenderPipelineState:g_metal.overlay_texture_pipeline];
            const bool is_tiled = geometry.tiled != 0.f;
            const float scale_x = (is_tiled && geometry.sizes[2] > 0.f)
                ? geometry.sizes[0] / geometry.sizes[2]
                : 1.f;
            const float scale_y = (is_tiled && geometry.sizes[3] > 0.f)
                ? geometry.sizes[1] / geometry.sizes[3]
                : 1.f;
            MetalOverlayTextureUniforms uniforms = {
                .tex_scale = { scale_x, scale_y },
            };
            [encoder setVertexBytes:&uniforms length:sizeof uniforms atIndex:0];
            [encoder setFragmentTexture:background->texture atIndex:0];
            MTLSamplerDescriptor *sampler_desc = [[MTLSamplerDescriptor alloc] init];
            sampler_desc.minFilter = background->linear_filter ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
            sampler_desc.magFilter = background->linear_filter ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
            sampler_desc.mipFilter = MTLSamplerMipFilterNotMipmapped;
            switch (background->layout) {
                case MIRRORED:
                    sampler_desc.sAddressMode = MTLSamplerAddressModeMirrorRepeat;
                    sampler_desc.tAddressMode = MTLSamplerAddressModeMirrorRepeat;
                    break;
                case TILING:
                    sampler_desc.sAddressMode = MTLSamplerAddressModeRepeat;
                    sampler_desc.tAddressMode = MTLSamplerAddressModeRepeat;
                    break;
                default:
                    sampler_desc.sAddressMode = MTLSamplerAddressModeClampToEdge;
                    sampler_desc.tAddressMode = MTLSamplerAddressModeClampToEdge;
                    break;
            }
            id<MTLSamplerState> sampler = [g_metal.device newSamplerStateWithDescriptor:sampler_desc];
            if (sampler) {
                [encoder setFragmentSamplerState:sampler atIndex:0];
            }
            [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
            encode_draw_end(encoder);
        }
        mark_frame_has_content(state);
    }
    if (OPT(background_tint) > 0.f) {
        if (!metal_encode_background_tint(window, state, fallback_bg)) {
            return false;
        }
    }
    if (!background && OPT(background_tint) <= 0.f && g_metal.debug_events) {
        metal_debug_event(
            "background_skip",
            "drawable=%p frame_has_content=%d",
            state.drawable,
            state.frameHasContent ? 1 : 0
        );
    }
    return true;
}

EXPORTED void
metal_background_image_uploaded(BackgroundImage *bgimage, BackgroundImageLayout layout, bool linear_filter) {
    if (!bgimage) {
        return;
    }
    MetalBackgroundTexture *existing = metal_background_texture(bgimage);
    if (existing) {
        metal_background_texture_dispose(existing);
        bgimage->metal_texture = NULL;
    }
    MetalBackgroundTexture *background = calloc(1, sizeof(*background));
    if (!background) {
        PyErr_NoMemory();
        return;
    }
    background->width = bgimage->width;
    background->height = bgimage->height;
    background->layout = layout;
    background->linear_filter = linear_filter;
    const size_t length = (size_t)background->width * background->height * sizeof(uint32_t);
    if (length && bgimage->bitmap) {
        const size_t delta = bgimage->mmap_size ? bgimage->mmap_size - length : 0;
        const uint8_t *source = (const uint8_t *)bgimage->bitmap + delta;
        void *copy = malloc(length);
        if (!copy) {
            free(background);
            PyErr_NoMemory();
            return;
        }
        memcpy(copy, source, length);
        background->pixels = copy;
        background->length = length;
    }
    bgimage->metal_texture = background;
    if (background->pixels && g_metal.device) {
        if (!metal_background_texture_ensure_ready(background)) {
            // Leave pixel data intact so we can retry later if device not available.
            if (PyErr_Occurred()) {
                PyErr_Clear();
            }
        }
    }
}

EXPORTED void
metal_background_image_release(BackgroundImage *bgimage) {
    if (!bgimage) {
        return;
    }
    MetalBackgroundTexture *background = metal_background_texture(bgimage);
    if (background) {
        metal_background_texture_dispose(background);
        bgimage->metal_texture = NULL;
    }
}

EXPORTED bool
metal_renderer_blank_drawable(GLFWwindow *window, color_type color, float background_opacity) {
    if (metal_blank_stub_for_tests) {
        MetalWindowState *state = ensure_state_for_window(window);
        if (!state) {
            PyErr_SetString(PyExc_RuntimeError, "Metal blank drawable called on unknown window");
            return false;
        }
        state.backgroundOpacity = background_opacity;
        state.fallbackBackground = color;
        state.clearColor = clear_color_from(color, background_opacity);
        mark_frame_has_content(state);
        state.commandBuffer = nil;
        state.drawable = nil;
        return true;
    }
    if (!window) {
        PyErr_SetString(PyExc_ValueError, "Metal blank drawable requires window handle");
        return false;
    }
    MetalWindowState *state = ensure_state_for_window(window);
    if (!state) {
        PyErr_SetString(PyExc_RuntimeError, "Metal blank drawable called on unknown window");
        return false;
    }
    state.backgroundOpacity = background_opacity;
    state.fallbackBackground = color;
    state.clearColor = clear_color_from(color, background_opacity);
    clear_frame_content(state);
    return encode_clear_pass(window, state, state.clearColor);
}

static bool
metal_capture_framebuffer(MetalWindowState *state) {
    if (!state || !state.commandBuffer || !state.drawable) {
        metal_reset_capture_state(state, false);
        PyErr_SetString(PyExc_RuntimeError, "Metal capture called with incomplete window state");
        return false;
    }
    id<MTLTexture> texture = state.drawable.texture;
    if (!texture) {
        metal_reset_capture_state(state, false);
        PyErr_SetString(PyExc_RuntimeError, "Metal drawable texture unavailable for capture");
        return false;
    }
    const NSUInteger width = texture.width;
    const NSUInteger height = texture.height;
    if (width == 0 || height == 0) {
        metal_reset_capture_state(state, false);
        return true;
    }
    const size_t bytes_per_row = (size_t)width * 4u;
    const size_t required_length = bytes_per_row * height;
    if (!state.captureBuffer || state.captureBuffer.length < required_length) {
        state.captureBuffer = [g_metal.device newBufferWithLength:required_length options:MTLResourceStorageModeShared];
        if (!state.captureBuffer) {
            metal_reset_capture_state(state, false);
            PyErr_SetString(PyExc_RuntimeError, "Metal failed to allocate capture buffer");
            metal_log("capture_buffer_alloc_failed", "length=%zu", required_length);
            return false;
        }
    }
    id<MTLBlitCommandEncoder> blit = [state.commandBuffer blitCommandEncoder];
    if (!blit) {
        metal_reset_capture_state(state, false);
        PyErr_SetString(PyExc_RuntimeError, "Metal failed to create blit encoder for capture");
        return false;
    }
    state.captureWidth = width;
    state.captureHeight = height;
    state.captureBytesPerRow = (NSUInteger)bytes_per_row;
    state.captureValid = YES;

    MTLOrigin origin = MTLOriginMake(0, 0, 0);
    MTLSize size = MTLSizeMake(width, height, 1);
    const size_t bytes_per_image = bytes_per_row * height;
    [blit copyFromTexture:texture
              sourceSlice:0
              sourceLevel:0
             sourceOrigin:origin
               sourceSize:size
                toBuffer:state.captureBuffer
       destinationOffset:0
      destinationBytesPerRow:bytes_per_row
    destinationBytesPerImage:bytes_per_image];
    [blit endEncoding];
    return true;
}

static void
metal_finalize_capture(MetalWindowState *state) {
    if (!state || !state.captureValid || !state.captureBuffer) {
        return;
    }
    uint8_t *bytes = state.captureBuffer.contents;
    if (!bytes) {
        metal_reset_capture_state(state, false);
        return;
    }
    const size_t bytes_per_row = (size_t)state.captureBytesPerRow;
    const size_t height = state.captureHeight;
    const size_t length = bytes_per_row * height;
    for (size_t offset = 0; offset + 3 < length; offset += 4) {
        uint8_t b = bytes[offset];
        bytes[offset] = bytes[offset + 2];
        bytes[offset + 2] = b;
    }
    metal_set_last_capture(bytes, length, (uint32_t)state.captureWidth, (uint32_t)state.captureHeight, (uint32_t)bytes_per_row, false);
}

static bool
metal_window_logo_ensure_texture(WindowLogo *logo) {
    if (!logo || !g_metal.device) {
        return false;
    }
    id<MTLTexture> texture = logo->metal_texture ? (__bridge id<MTLTexture>)logo->metal_texture : nil;
    const size_t pixel_count = (size_t)logo->width * (size_t)logo->height;
    const size_t byte_count = pixel_count * 4u;
    const size_t delta = logo->mmap_size ? logo->mmap_size - byte_count : 0;
    const void *pixels = logo->bitmap ? (const void *)(logo->bitmap + delta) : NULL;

    if (!texture) {
        if (!pixels) {
            PyErr_SetString(PyExc_RuntimeError, "Window logo pixel buffer unavailable for Metal upload");
            return false;
        }
        MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm_sRGB
                                                                                              width:logo->width
                                                                                             height:logo->height
                                                                                          mipmapped:NO];
        descriptor.storageMode = MTLStorageModeManaged;
        descriptor.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> new_texture = [g_metal.device newTextureWithDescriptor:descriptor];
        if (!new_texture) {
            PyErr_NoMemory();
            return false;
        }
        [new_texture replaceRegion:MTLRegionMake2D(0, 0, logo->width, logo->height)
                        mipmapLevel:0
                          withBytes:pixels
                        bytesPerRow:4u * (size_t)logo->width];
        if (logo->metal_texture) {
            CFRelease(logo->metal_texture);
        }
        logo->metal_texture = (void *)CFBridgingRetain(new_texture);
        texture = new_texture;
        [new_texture release];
        if (logo->bitmap) {
            if (logo->mmap_size) {
                munmap(logo->bitmap, logo->mmap_size);
            } else {
                free(logo->bitmap);
            }
            logo->bitmap = NULL;
            logo->mmap_size = 0;
        }
    } else if (pixels) {
        [texture replaceRegion:MTLRegionMake2D(0, 0, logo->width, logo->height)
                    mipmapLevel:0
                      withBytes:pixels
                    bytesPerRow:4u * (size_t)logo->width];
        if (logo->bitmap) {
            if (logo->mmap_size) {
                munmap(logo->bitmap, logo->mmap_size);
            } else {
                free(logo->bitmap);
            }
            logo->bitmap = NULL;
            logo->mmap_size = 0;
        }
    }
    return texture != nil;
}

static bool
metal_register_window_logo_texture(WindowLogo *logo) {
    if (!logo) {
        return false;
    }
    if (!metal_window_logo_ensure_texture(logo)) {
        return false;
    }
    if (!logo->texture_id) {
        uint32_t new_id = 0;
        do {
            new_id = next_graphics_texture_id++;
        } while (new_id == 0);
        logo->texture_id = new_id;
    }
    MetalGraphicsTexture *holder = [graphics_texture_table() objectForKey:@(logo->texture_id)];
    if (!holder) {
        holder = [[MetalGraphicsTexture alloc] init];
        [graphics_texture_table() setObject:holder forKey:@(logo->texture_id)];
    }
    holder.texture = logo->metal_texture ? (__bridge id<MTLTexture>)logo->metal_texture : nil;
    holder.width = logo->width;
    holder.height = logo->height;
    holder.linearFilter = YES;
    holder.isOpaque = NO;
    holder.repeat = REPEAT_CLAMP;
    return holder.texture != nil;
}

static bool
metal_prepare_window_logo_image(
    Window *window,
    unsigned int screen_width,
    unsigned int screen_height,
    float inactive_alpha,
    ImageRenderData *out_image,
    float *out_extra_alpha
) {
    if (!window || !out_image || !out_extra_alpha) {
        return false;
    }
    WindowLogoRenderData *wl = &window->window_logo;
    if (!wl->id) {
        return false;
    }
    wl->instance = find_window_logo(global_state.all_window_logos, wl->id);
    if (!wl->instance || !wl->instance->load_from_disk_ok) {
        return false;
    }
    if (!metal_register_window_logo_texture(wl->instance)) {
        return false;
    }

    struct {
        unsigned width;
        unsigned height;
        int left;
        int top;
    } geom = {
        .width = wl->instance->width,
        .height = wl->instance->height,
        .left = 0,
        .top = 0,
    };
    if (OPT(window_logo_scale.width) > 0.0 || OPT(window_logo_scale.height) > 0.0) {
        unsigned scaled_width = screen_width;
        unsigned scaled_height = screen_height;
        if (OPT(window_logo_scale.height) < 0.0) {
            if (screen_height < screen_width) {
                scaled_height = (unsigned)(screen_height * OPT(window_logo_scale.width) / 100.0);
                scaled_width = wl->instance->width * scaled_height / wl->instance->height;
            } else {
                scaled_width = (unsigned)(screen_width * OPT(window_logo_scale.width) / 100.0);
                scaled_height = wl->instance->height * scaled_width / wl->instance->width;
            }
        } else if (OPT(window_logo_scale.width) == 0.0) {
            scaled_height = (unsigned)(scaled_height * OPT(window_logo_scale.height) / 100.0);
            scaled_width = wl->instance->width;
        } else if (OPT(window_logo_scale.height) == 0.0) {
            scaled_width = (unsigned)(scaled_width * OPT(window_logo_scale.width) / 100.0);
            scaled_height = wl->instance->height;
        } else {
            scaled_height = (unsigned)(scaled_height * OPT(window_logo_scale.height) / 100.0);
            scaled_width = (unsigned)(scaled_width * OPT(window_logo_scale.width) / 100.0);
        }
        geom.width = scaled_width;
        geom.height = scaled_height;
    }

    geom.left = (int)((double)screen_width * wl->position.canvas_x - (double)geom.width * wl->position.image_x);
    geom.top = (int)((double)screen_height * wl->position.canvas_y - (double)geom.height * wl->position.image_y);

    float left = gl_pos_x(geom.left, screen_width);
    float top = gl_pos_y(geom.top, screen_height);
    float right = left + gl_size(geom.width, screen_width);
    float bottom = top - gl_size(geom.height, screen_height);

    memset(out_image, 0, sizeof(*out_image));
    out_image->texture_id = wl->instance->texture_id;
    out_image->group_count = 1;
    gpu_data_for_image(out_image, left, top, right, bottom);
    *out_extra_alpha = inactive_alpha * (float)OPT(window_logo_alpha);
    return true;
}

static Animation *metal_default_visual_bell_animation = NULL;

static float
metal_visual_bell_intensity(Screen *screen) {
    if (screen && screen->start_visual_bell_at > 0) {
        if (!metal_default_visual_bell_animation) {
            metal_default_visual_bell_animation = alloc_animation();
            if (!metal_default_visual_bell_animation) {
                PyErr_NoMemory();
                return 0.0f;
            }
            add_cubic_bezier_animation(metal_default_visual_bell_animation, 0.0, 1.0, EASE_IN_OUT);
            add_cubic_bezier_animation(metal_default_visual_bell_animation, 1.0, 0.0, EASE_IN_OUT);
        }
        const monotonic_t progress = monotonic() - screen->start_visual_bell_at;
        const monotonic_t duration = OPT(visual_bell_duration) / 2;
        if (progress <= duration) {
            Animation *animation = animation_is_valid(OPT(animation.visual_bell))
                ? OPT(animation.visual_bell)
                : metal_default_visual_bell_animation;
            double t = progress / (double)duration;
            return (float)apply_easing_curve(animation, t, duration);
        }
        screen->start_visual_bell_at = 0;
    }
    return 0.0f;
}

static bool
metal_encode_visual_bell(GLFWwindow *window, MetalWindowState *state, Screen *screen) {
    if (!screen) {
        return true;
    }
    float intensity = metal_visual_bell_intensity(screen);
    if (intensity <= 0.f) {
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
    color_type flash = 0;
#define METAL_IS_SPECIAL_COLOR(field) \
    (screen->color_profile->overridden.field.type == COLOR_IS_SPECIAL || \
    (screen->color_profile->overridden.field.type == COLOR_NOT_SET && \
     screen->color_profile->configured.field.type == COLOR_IS_SPECIAL))
#define METAL_COLOR(field, fallback) \
    colorprofile_to_color_with_fallback(screen->color_profile, \
        screen->color_profile->overridden.field, \
        screen->color_profile->configured.field, \
        screen->color_profile->overridden.fallback, \
        screen->color_profile->configured.fallback)
    if (!METAL_IS_SPECIAL_COLOR(highlight_bg)) {
        flash = METAL_COLOR(visual_bell_color, highlight_bg);
    } else {
        flash = METAL_COLOR(visual_bell_color, default_fg);
    }
#undef METAL_COLOR
#undef METAL_IS_SPECIAL_COLOR

    float attenuation = 0.4f;
    float r = srgb_channel_to_linear((flash >> 16) & 0xFF);
    float g = srgb_channel_to_linear((flash >> 8) & 0xFF);
    float b = srgb_channel_to_linear(flash & 0xFF);
    float max_channel = fmaxf(r, fmaxf(g, b));
    if (max_channel > 0.45f) {
        attenuation = 0.6f;
    }
    float alpha = intensity * attenuation;
    vector_float4 color = { r * alpha, g * alpha, b * alpha, alpha };

    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    if (!pass) {
        PyErr_SetString(PyExc_RuntimeError, "Failed to allocate Metal render pass descriptor for visual bell");
        return false;
    }
    pass.colorAttachments[0].texture = state.drawable.texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = state.clearColor;

    id<MTLRenderCommandEncoder> encoder = [state.commandBuffer renderCommandEncoderWithDescriptor:pass];
    if (!encoder) {
        PyErr_SetString(PyExc_RuntimeError, "Failed to create Metal encoder for visual bell");
        return false;
    }
    if (g_metal.debug_labels) {
        encoder.label = @"kitty-visual-bell";
    }
    [encoder setViewport:(MTLViewport){
        .originX = 0.0,
        .originY = 0.0,
        .width = state.drawable.texture.width,
        .height = state.drawable.texture.height,
        .znear = 0.0,
        .zfar = 1.0
    }];
    [encoder setRenderPipelineState:g_metal.tint_pipeline];
    vector_float4 tint_edges = { -1.f, 1.f, 1.f, -1.f };
    MetalTintUniforms uniforms = metal_make_tint_uniforms(tint_edges, color);
    [encoder setVertexBytes:&uniforms length:sizeof uniforms atIndex:0];
    [encoder setFragmentBytes:&uniforms length:sizeof uniforms atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    encode_draw_end(encoder);
    mark_frame_has_content(state);
    return true;
}

static bool
metal_encode_scrollbar(
    GLFWwindow *window,
    MetalWindowState *state,
    OSWindow *os_window,
    Window *render_window,
    Screen *screen,
    const WindowGeometry *geometry,
    unsigned int screen_width_px,
    unsigned int screen_height_px
) {
    if (!os_window || !os_window->fonts_data || !render_window || !screen || !geometry) {
        return true;
    }
    RendererSharedScrollbarMetrics metrics = {0};
    if (!renderer_shared_prepare_scrollbar_metrics(
            screen,
            render_window,
            &render_window->render_data,
            geometry->left,
            geometry->top,
            screen_width_px,
            screen_height_px,
            os_window->fonts_data->fcm.cell_width,
            os_window->fonts_data->fcm.cell_height,
            os_window->viewport_height,
            &metrics) || !metrics.visible) {
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
    const unsigned int viewport_width = os_window->viewport_width;
    const unsigned int viewport_height = os_window->viewport_height;

    float track_left = gl_pos_x(metrics.left_px, viewport_width);
    float track_right = gl_pos_x(metrics.left_px + metrics.width_px, viewport_width);
    float track_top = gl_pos_y(metrics.top_px, viewport_height);
    float track_bottom = gl_pos_y(metrics.top_px + metrics.height_px, viewport_height);

    if (metrics.track_opacity > 0.f) {
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        if (!pass) {
            PyErr_SetString(PyExc_RuntimeError, "Failed to allocate Metal pass descriptor for scrollbar track");
            return false;
        }
        pass.colorAttachments[0].texture = state.drawable.texture;
        pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].clearColor = state.clearColor;
        id<MTLRenderCommandEncoder> encoder = [state.commandBuffer renderCommandEncoderWithDescriptor:pass];
        if (!encoder) {
            PyErr_SetString(PyExc_RuntimeError, "Failed to create Metal encoder for scrollbar track");
            return false;
        }
        if (g_metal.debug_labels) {
            encoder.label = @"kitty-scrollbar-track";
        }
        [encoder setViewport:(MTLViewport){
            .originX = 0.0,
            .originY = 0.0,
            .width = state.drawable.texture.width,
            .height = state.drawable.texture.height,
            .znear = 0.0,
            .zfar = 1.0
        }];
        [encoder setRenderPipelineState:g_metal.tint_pipeline];
        vector_float4 track_edges = { track_left, track_top, track_right, track_bottom };
        vector_float4 track_color = color_to_linear_premult(metrics.track_color, metrics.track_opacity);
        MetalTintUniforms tint_uniforms = metal_make_tint_uniforms(track_edges, track_color);
        [encoder setVertexBytes:&tint_uniforms length:sizeof tint_uniforms atIndex:0];
        [encoder setFragmentBytes:&tint_uniforms length:sizeof tint_uniforms atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        encode_draw_end(encoder);
        mark_frame_has_content(state);
    }

    if (metrics.handle_opacity <= 0.f) {
        return true;
    }

    if (metrics.corner_radius_px > 0u) {
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        if (!pass) {
            PyErr_SetString(PyExc_RuntimeError, "Failed to allocate Metal pass descriptor for scrollbar handle");
            return false;
        }
        pass.colorAttachments[0].texture = state.drawable.texture;
        pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].clearColor = state.clearColor;
        id<MTLRenderCommandEncoder> encoder = [state.commandBuffer renderCommandEncoderWithDescriptor:pass];
        if (!encoder) {
            PyErr_SetString(PyExc_RuntimeError, "Failed to create Metal encoder for rounded scrollbar handle");
            return false;
        }
        if (g_metal.debug_labels) {
            encoder.label = @"kitty-scrollbar-handle-rounded";
        }
        double origin_y = (double)viewport_height - (double)(metrics.thumb_top_px + metrics.thumb_height_px);
        [encoder setViewport:(MTLViewport){
            .originX = metrics.left_px,
            .originY = origin_y,
            .width = metrics.width_px,
            .height = metrics.thumb_height_px,
            .znear = 0.0,
            .zfar = 1.0
        }];
        [encoder setRenderPipelineState:g_metal.rounded_rect_pipeline];
        MetalRoundedRectUniforms uniforms = {
            .size = (vector_float2){ (float)metrics.width_px, (float)metrics.thumb_height_px },
            .thickness = (float)MAX((int)metrics.width_px, (int)metrics.thumb_height_px),
            .radius = (float)metrics.corner_radius_px,
            .color = color_to_linear_premult(metrics.handle_color, metrics.handle_opacity),
        };
        [encoder setVertexBytes:&uniforms length:sizeof uniforms atIndex:0];
        [encoder setFragmentBytes:&uniforms length:sizeof uniforms atIndex:1];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        encode_draw_end(encoder);
        mark_frame_has_content(state);
    } else {
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        if (!pass) {
            PyErr_SetString(PyExc_RuntimeError, "Failed to allocate Metal pass descriptor for scrollbar handle");
            return false;
        }
        pass.colorAttachments[0].texture = state.drawable.texture;
        pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].clearColor = state.clearColor;
        id<MTLRenderCommandEncoder> encoder = [state.commandBuffer renderCommandEncoderWithDescriptor:pass];
        if (!encoder) {
            PyErr_SetString(PyExc_RuntimeError, "Failed to create Metal encoder for scrollbar handle");
            return false;
        }
        if (g_metal.debug_labels) {
            encoder.label = @"kitty-scrollbar-handle";
        }
        [encoder setViewport:(MTLViewport){
            .originX = 0.0,
            .originY = 0.0,
            .width = state.drawable.texture.width,
            .height = state.drawable.texture.height,
            .znear = 0.0,
            .zfar = 1.0
        }];
        float thumb_top_gl = 1.f - 2.f * metrics.thumb_top_fraction;
        float thumb_bottom_gl = 1.f - 2.f * metrics.thumb_bottom_fraction;
        vector_float4 handle_edges = { track_left, thumb_top_gl, track_right, thumb_bottom_gl };
        vector_float4 handle_color = color_to_linear_premult(metrics.handle_color, metrics.handle_opacity);
        MetalTintUniforms tint_uniforms = metal_make_tint_uniforms(handle_edges, handle_color);
        [encoder setVertexBytes:&tint_uniforms length:sizeof tint_uniforms atIndex:0];
        [encoder setFragmentBytes:&tint_uniforms length:sizeof tint_uniforms atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        encode_draw_end(encoder);
        mark_frame_has_content(state);
    }
    return true;
}

static bool
metal_encode_window_number(
    GLFWwindow *window,
    MetalWindowState *state,
    OSWindow *os_window,
    Window *render_window,
    Screen *screen,
    const WindowGeometry *geometry,
    unsigned int screen_width_px,
    unsigned int screen_height_px
) {
    if (!os_window || !render_window || !screen || !geometry || !os_window->fonts_data) {
        return true;
    }
    unsigned int title_bar_height = 0;
    if (render_window->title && PyUnicode_Check(render_window->title) &&
        screen_height_px > (os_window->fonts_data->fcm.cell_height + 1u) * 2u) {
        RendererSharedBarSurface surface = {0};
        if (renderer_shared_prepare_bar_surface(
                screen,
                os_window,
                &render_window->title_bar_data,
                render_window->title,
                screen_width_px,
                screen_height_px,
                os_window->fonts_data->fcm.cell_height,
                false,
                &surface) && surface.visible) {
            title_bar_height = surface.height_px + 2u * surface.border_width_px;
        }
    }

    RendererSharedWindowNumber info = {0};
    if (!renderer_shared_prepare_window_number(
            screen,
            screen_width_px,
            screen_height_px,
            geometry->left,
            geometry->top,
            os_window->viewport_height,
            os_window->fonts_data->fcm.cell_width,
            os_window->fonts_data->fcm.cell_height,
            title_bar_height,
            &info) || !info.visible || !info.pixels) {
        return true;
    }
    RendererGraphicsImageUpload upload = {
        .pixels = info.pixels,
        .width = (int32_t)info.width_px,
        .height = (int32_t)info.height_px,
        .is_opaque = false,
        .is_4byte_aligned = true,
        .linear_filter = true,
        .repeat = REPEAT_CLAMP,
    };
    if (!metal_backend_upload_graphics_image(&metal_window_number_texture, &upload)) {
        return false;
    }
    if (!state.commandBuffer || !state.drawable) {
        if (!ensure_command_primitives(window, state)) {
            return false;
        }
    }
    if (!metal_ensure_resources()) {
        return false;
    }
    float left = gl_pos_x(info.offset_x_px, os_window->viewport_width);
    float top = gl_pos_y(info.offset_y_px, os_window->viewport_height);
    float right = left + gl_size(info.width_px, os_window->viewport_width);
    float bottom = top - gl_size(info.height_px, os_window->viewport_height);

    ImageRenderData image = {0};
    image.texture_id = metal_window_number_texture.id;
    image.group_count = 1;
    gpu_data_for_image(&image, left, top, right, bottom);

    vector_float3 fg = color_to_linear_rgb(info.glyph_color);
    vector_float4 bg = {0.f, 0.f, 0.f, 0.f};
    return metal_encode_graphics_alpha_bucket(window, state, &image, 0, 1, fg, bg, 1.f);
}

static bool
metal_encode_hyperlink_target(
    GLFWwindow *window,
    MetalWindowState *state,
    OSWindow *os_window,
    Window *render_window,
    Screen *screen,
    const WindowGeometry *geometry,
    unsigned int screen_width_px,
    unsigned int screen_height_px
) {
    if (!os_window || !render_window || !screen || !geometry || !os_window->fonts_data) {
        return true;
    }
    bool along_bottom = false;
    PyObject *title = renderer_shared_get_hyperlink_title(screen, render_window, os_window, &along_bottom);
    if (!title) {
        return true;
    }
    RendererSharedBarSurface surface = {0};
    bool surface_ok = renderer_shared_prepare_bar_surface(
        screen,
        os_window,
        &render_window->title_bar_data,
        title,
        screen_width_px,
        screen_height_px,
        os_window->fonts_data->fcm.cell_height,
        along_bottom,
        &surface
    );
    Py_DECREF(title);
    if (!surface_ok || !surface.visible || !surface.pixels) {
        return true;
    }

    unsigned int border = surface.border_width_px;
    unsigned int total_width = surface.width_px + 2u * border;
    unsigned int total_height = surface.height_px + 2u * border;
    int rect_left = geometry->left;
    int rect_top = geometry->top;
    if (along_bottom) {
        rect_top += screen_height_px - (int)total_height;
    }
    int inner_left = rect_left + (int)border;
    int inner_top = rect_top + (int)border;

    if (!state.commandBuffer || !state.drawable) {
        if (!ensure_command_primitives(window, state)) {
            return false;
        }
    }
    if (!metal_ensure_resources()) {
        return false;
    }

    const unsigned int viewport_height = os_window->viewport_height;

    if (border > 0) {
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        if (!pass) {
            PyErr_SetString(PyExc_RuntimeError, "Failed to allocate Metal pass descriptor for hyperlink border");
            return false;
        }
        pass.colorAttachments[0].texture = state.drawable.texture;
        pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].clearColor = state.clearColor;
        id<MTLRenderCommandEncoder> encoder = [state.commandBuffer renderCommandEncoderWithDescriptor:pass];
        if (!encoder) {
            PyErr_SetString(PyExc_RuntimeError, "Failed to create Metal encoder for hyperlink border");
            return false;
        }
        if (g_metal.debug_labels) {
            encoder.label = @"kitty-hyperlink-border";
        }
        double origin_y = (double)viewport_height - (double)(rect_top + (int)total_height);
        [encoder setViewport:(MTLViewport){
            .originX = rect_left,
            .originY = origin_y,
            .width = total_width,
            .height = total_height,
            .znear = 0.0,
            .zfar = 1.0
        }];
        [encoder setRenderPipelineState:g_metal.tint_pipeline];
        vector_float4 border_edges = { -1.f, 1.f, 1.f, -1.f };
        vector_float4 border_color = color_to_linear_premult(surface.foreground_color, 1.f);
        MetalTintUniforms tint_uniforms = metal_make_tint_uniforms(border_edges, border_color);
        [encoder setVertexBytes:&tint_uniforms length:sizeof tint_uniforms atIndex:0];
        [encoder setFragmentBytes:&tint_uniforms length:sizeof tint_uniforms atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        encode_draw_end(encoder);
        mark_frame_has_content(state);
    }

    {
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        if (!pass) {
            PyErr_SetString(PyExc_RuntimeError, "Failed to allocate Metal pass descriptor for hyperlink background");
            return false;
        }
        pass.colorAttachments[0].texture = state.drawable.texture;
        pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].clearColor = state.clearColor;
        id<MTLRenderCommandEncoder> encoder = [state.commandBuffer renderCommandEncoderWithDescriptor:pass];
        if (!encoder) {
            PyErr_SetString(PyExc_RuntimeError, "Failed to create Metal encoder for hyperlink background");
            return false;
        }
        if (g_metal.debug_labels) {
            encoder.label = @"kitty-hyperlink-background";
        }
        double origin_y = (double)viewport_height - (double)(inner_top + (int)surface.height_px);
        [encoder setViewport:(MTLViewport){
            .originX = inner_left,
            .originY = origin_y,
            .width = surface.width_px,
            .height = surface.height_px,
            .znear = 0.0,
            .zfar = 1.0
        }];
        [encoder setRenderPipelineState:g_metal.tint_pipeline];
        vector_float4 background_edges = { -1.f, 1.f, 1.f, -1.f };
        vector_float4 background_color = color_to_linear_premult(surface.background_color, 1.f);
        MetalTintUniforms tint_uniforms = metal_make_tint_uniforms(background_edges, background_color);
        [encoder setVertexBytes:&tint_uniforms length:sizeof tint_uniforms atIndex:0];
        [encoder setFragmentBytes:&tint_uniforms length:sizeof tint_uniforms atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        encode_draw_end(encoder);
        mark_frame_has_content(state);
    }

    RendererGraphicsImageUpload upload = {
        .pixels = surface.pixels,
        .width = (int32_t)surface.width_px,
        .height = (int32_t)surface.height_px,
        .is_opaque = false,
        .is_4byte_aligned = true,
        .linear_filter = true,
        .repeat = REPEAT_CLAMP,
    };
    if (!metal_backend_upload_graphics_image(&metal_hyperlink_texture, &upload)) {
        return false;
    }

    float tex_left = gl_pos_x(inner_left, os_window->viewport_width);
    float tex_top = gl_pos_y(inner_top, os_window->viewport_height);
    float tex_right = gl_pos_x(inner_left + (int)surface.width_px, os_window->viewport_width);
    float tex_bottom = gl_pos_y(inner_top + (int)surface.height_px, os_window->viewport_height);

    ImageRenderData image = {0};
    image.texture_id = metal_hyperlink_texture.id;
    image.group_count = 1;
    gpu_data_for_image(&image, tex_left, tex_top, tex_right, tex_bottom);
    GraphicsRenderData grd = {
        .count = 1,
        .images = &image,
    };
    return metal_encode_graphics_bucket(window, state, &grd, 0, 1, 1.f);
}

static bool
validate_graphics_upload_args(TextureRef *ref, const RendererGraphicsImageUpload *upload) {
    if (!ref || !upload) {
        PyErr_SetString(PyExc_RuntimeError, "Metal graphics upload received invalid arguments");
        return false;
    }
    if (!g_metal.device) {
        PyErr_SetString(PyExc_RuntimeError, "Metal device unavailable; cannot upload graphics textures");
        return false;
    }
    if (upload->width <= 0 || upload->height <= 0) {
        PyErr_SetString(PyExc_ValueError, "Metal graphics upload requires positive width and height");
        return false;
    }
    if (!upload->pixels) {
        PyErr_SetString(PyExc_ValueError, "Metal graphics upload requires pixel data");
        return false;
    }
    return true;
}

static bool
metal_backend_upload_graphics_image(TextureRef *ref, const RendererGraphicsImageUpload *upload) {
    if (!validate_graphics_upload_args(ref, upload)) {
        return false;
    }
    if (ref->backend_handle && ref->id) {
        [graphics_texture_table() removeObjectForKey:@(ref->id)];
        ref->backend_handle = NULL;
    }

    const uint32_t width = (uint32_t)upload->width;
    const uint32_t height = (uint32_t)upload->height;
    const size_t pixel_count = (size_t)width * (size_t)height;
    if (pixel_count == 0) {
        PyErr_SetString(PyExc_ValueError, "Metal graphics upload computed zero-sized texture");
        return false;
    }

    const uint8_t *source = (const uint8_t *)upload->pixels;
    if (!source) {
        PyErr_SetString(PyExc_ValueError, "Metal graphics upload received null pixel buffer");
        return false;
    }

    void *temp_buffer = NULL;
    const void *pixels = source;
    const size_t target_bpp = 4;
    const size_t target_row_bytes = target_bpp * (size_t)width;

    if (upload->is_opaque) {
        temp_buffer = malloc(target_row_bytes * (size_t)height);
        if (!temp_buffer) {
            PyErr_NoMemory();
            return false;
        }
        uint8_t *dest = (uint8_t *)temp_buffer;
        const size_t src_row_bytes = (size_t)width * 3u;
        for (uint32_t y = 0; y < height; y++) {
            const uint8_t *src_row = source + y * src_row_bytes;
            uint8_t *dst_row = dest + y * target_row_bytes;
            for (uint32_t x = 0; x < width; x++) {
                dst_row[0] = src_row[0];
                dst_row[1] = src_row[1];
                dst_row[2] = src_row[2];
                dst_row[3] = 0xFF;
                src_row += 3;
                dst_row += 4;
            }
        }
        pixels = temp_buffer;
    }

    MTLTextureDescriptor *descriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm_sRGB
                                                           width:width
                                                          height:height
                                                       mipmapped:NO];
    descriptor.usage = MTLTextureUsageShaderRead;
    descriptor.storageMode = MTLStorageModePrivate;

    id<MTLTexture> texture = [g_metal.device newTextureWithDescriptor:descriptor];
    if (!texture) {
        if (temp_buffer) {
            free(temp_buffer);
        }
        PyErr_NoMemory();
        return false;
    }

    MTLRegion region = MTLRegionMake2D(0, 0, width, height);
    [texture replaceRegion:region mipmapLevel:0 withBytes:pixels bytesPerRow:target_row_bytes];

    if (temp_buffer) {
        free(temp_buffer);
    }

    MetalGraphicsTexture *holder = [[MetalGraphicsTexture alloc] init];
    holder.texture = texture;
    holder.width = width;
    holder.height = height;
    holder.linearFilter = upload->linear_filter;
    holder.isOpaque = upload->is_opaque;
    RepeatStrategy repeat = upload->repeat;
    if (repeat < REPEAT_MIRROR || repeat > REPEAT_DEFAULT) {
        repeat = REPEAT_DEFAULT;
    }
    holder.repeat = repeat;

    if (ref->id == 0) {
        uint32_t new_id = 0;
        do {
            new_id = next_graphics_texture_id++;
        } while (new_id == 0);
        ref->id = new_id;
    }

    [graphics_texture_table() setObject:holder forKey:@(ref->id)];
    ref->backend_handle = (void *)holder;
    [holder release];
    return true;
}

static void
metal_backend_destroy_graphics_image(TextureRef *ref) {
    if (!ref) {
        return;
    }
    if (ref->backend_handle || ref->id) {
        [graphics_texture_table() removeObjectForKey:@(ref->id)];
        ref->backend_handle = NULL;
    }
    ref->id = 0;
}

EXPORTED bool
metal_renderer_debug_get_graphics_texture(
    uint32_t texture_id,
    MetalGraphicsTextureDebugInfo *out_info
) {
    if (!out_info) {
        PyErr_SetString(PyExc_ValueError, "metal_renderer_debug_get_graphics_texture requires output struct");
        return false;
    }
    MetalGraphicsTexture *texture = [graphics_texture_table() objectForKey:@(texture_id)];
    if (!texture) {
        return false;
    }
    out_info->width = texture.width;
    out_info->height = texture.height;
    out_info->linear_filter = texture.linearFilter;
    out_info->is_opaque = texture.isOpaque;
    out_info->repeat = texture.repeat;
    return true;
}

EXPORTED bool
metal_renderer_copy_captured_frame_for_tests(MetalCapturedFrameDebugInfo *out_info) {
    if (!out_info) {
        PyErr_SetString(PyExc_ValueError, "metal_renderer_copy_captured_frame_for_tests requires output struct");
        return false;
    }
    if (!g_metal_capture.pixels) {
        memset(out_info, 0, sizeof(*out_info));
        return false;
    }
    out_info->width = g_metal_capture.width;
    out_info->height = g_metal_capture.height;
    out_info->bytes_per_row = g_metal_capture.bytes_per_row;
    out_info->pixels = g_metal_capture.pixels;
    return true;
}

EXPORTED bool
metal_renderer_debug_set_captured_frame_for_tests(
    const uint8_t *pixels,
    uint32_t width,
    uint32_t height,
    uint32_t bytes_per_row,
    bool pixels_are_bgra
) {
    if (!pixels) {
        PyErr_SetString(PyExc_ValueError, "metal_renderer_debug_set_captured_frame_for_tests requires pixel data");
        return false;
    }
    if (width == 0 || height == 0) {
        PyErr_SetString(PyExc_ValueError, "metal_renderer_debug_set_captured_frame_for_tests requires non-zero dimensions");
        return false;
    }
    if (bytes_per_row == 0 || (size_t)bytes_per_row < (size_t)width * 4u) {
        PyErr_SetString(PyExc_ValueError, "metal_renderer_debug_set_captured_frame_for_tests received invalid row stride");
        return false;
    }
    size_t length = (size_t)bytes_per_row * height;
    uint8_t *copy = malloc(length);
    if (!copy) {
        PyErr_NoMemory();
        return false;
    }
    memcpy(copy, pixels, length);
    if (pixels_are_bgra) {
        for (uint32_t y = 0; y < height; y++) {
            uint8_t *row = copy + (size_t)y * bytes_per_row;
            for (uint32_t x = 0; x < width; x++) {
                size_t idx = (size_t)x * 4u;
                uint8_t b = row[idx];
                row[idx] = row[idx + 2];
                row[idx + 2] = b;
            }
        }
    }
    metal_set_last_capture(copy, length, width, height, bytes_per_row, true);
    return true;
}

EXPORTED void
metal_renderer_debug_clear_captured_frame_for_tests(void) {
    metal_clear_last_capture();
}

EXPORTED void
metal_renderer_debug_seed_window_state_for_tests(GLFWwindow *window) {
    (void)ensure_state_for_window(window);
}

EXPORTED bool
metal_renderer_debug_get_window_state_for_tests(GLFWwindow *window, MetalWindowDebugState *out_state) {
    if (!out_state) {
        PyErr_SetString(PyExc_ValueError, "metal_renderer_debug_get_window_state_for_tests requires output struct");
        return false;
    }
    MetalWindowState *state = state_for_window(window);
    if (!state) {
        memset(out_state, 0, sizeof(*out_state));
        return false;
    }
    out_state->frame_has_content = state.frameHasContent ? true : false;
    out_state->has_encoded_pass = state.hasEncodedPass ? true : false;
    out_state->capture_valid = state.captureValid ? true : false;
    out_state->capture_width = (uint32_t)state.captureWidth;
    out_state->capture_height = (uint32_t)state.captureHeight;
    out_state->capture_bytes_per_row = (uint32_t)state.captureBytesPerRow;
    out_state->contents_scale = (float)state.lastContentsScale;
    out_state->drawable_width = (uint32_t)lround(state.lastDrawableSize.width);
    out_state->drawable_height = (uint32_t)lround(state.lastDrawableSize.height);
    out_state->layer_attached = (state.layer != nil) && (state.attachedView != nil);
    out_state->last_tint_load_action = (uint32_t)state.lastTintLoadAction;
    return true;
}

EXPORTED void
metal_renderer_debug_set_window_state_for_tests(GLFWwindow *window, const MetalWindowDebugState *state_info) {
    if (!state_info) {
        PyErr_SetString(PyExc_ValueError, "metal_renderer_debug_set_window_state_for_tests requires state data");
        return;
    }
    MetalWindowState *state = ensure_state_for_window(window);
    state.frameHasContent = state_info->frame_has_content ? YES : NO;
    state.hasEncodedPass = state_info->has_encoded_pass ? YES : NO;
    state.captureValid = state_info->capture_valid ? YES : NO;
    state.captureWidth = state_info->capture_width;
    state.captureHeight = state_info->capture_height;
    state.captureBytesPerRow = state_info->capture_bytes_per_row;
    state.lastContentsScale = state_info->contents_scale;
    state.lastDrawableSize = CGSizeMake((CGFloat)state_info->drawable_width, (CGFloat)state_info->drawable_height);
    state.lastTintLoadAction = (MTLLoadAction)state_info->last_tint_load_action;
    if (!state_info->layer_attached) {
        metal_detach_layer_from_view(state);
        state.layer = nil;
    }
}

EXPORTED void
metal_renderer_debug_reset_capture_state_for_tests(GLFWwindow *window, bool release_buffer) {
    MetalWindowState *state = state_for_window(window);
    metal_reset_capture_state(state, release_buffer);
}

EXPORTED bool
metal_renderer_debug_should_clear_tint_for_tests(
    bool has_encoded_pass,
    bool frame_has_content,
    bool drawable_changed
) {
    return metal_should_clear_tint(has_encoded_pass, frame_has_content, drawable_changed);
}

EXPORTED void
metal_renderer_debug_get_runtime_flags_for_tests(MetalRuntimeDebugFlags *out_flags) {
    if (!out_flags) {
        PyErr_SetString(PyExc_ValueError, "metal_renderer_debug_get_runtime_flags_for_tests requires output struct");
        return;
    }
    MetalRuntimeDebugFlags flags = {
        .debug_labels = g_metal.debug_labels,
        .debug_events = g_metal.debug_events,
        .capture_frames = g_metal.capture_frames,
        .display_sync_enabled = g_metal.display_sync_enabled,
    };
    *out_flags = flags;
}

EXPORTED void
metal_renderer_debug_enable_blank_stub_for_tests(bool enabled) {
    metal_blank_stub_for_tests = enabled;
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

EXPORTED void
metal_renderer_prepare_tint_uniforms_for_tests(
    color_type background_color,
    float tint_amount,
    MetalTintUniforms *out_uniforms
) {
    if (!out_uniforms) {
        PyErr_SetString(PyExc_ValueError, "metal_renderer_prepare_tint_uniforms_for_tests requires output struct");
        return;
    }
    float clamped = tint_amount;
    if (clamped < 0.f) clamped = 0.f;
    if (clamped > 1.f) clamped = 1.f;
    vector_float4 edges = { -1.f, 1.f, 1.f, -1.f };
    vector_float4 color = color_to_linear_premult(background_color, clamped);
    *out_uniforms = metal_make_tint_uniforms(edges, color);
}

EXPORTED void
metal_renderer_pack_graphics_uniforms_for_tests(
    const ImageRenderData *data,
    float extra_alpha,
    MetalGraphicsUniforms *out_uniforms
) {
    if (!data || !out_uniforms) {
        PyErr_SetString(PyExc_ValueError, "metal_renderer_pack_graphics_uniforms_for_tests requires data and output");
        return;
    }
    *out_uniforms = metal_pack_graphics_uniforms(data, extra_alpha);
}

EXPORTED void
metal_renderer_pack_graphics_alpha_uniforms_for_tests(
    const ImageRenderData *data,
    float fg_r,
    float fg_g,
    float fg_b,
    float bg_r,
    float bg_g,
    float bg_b,
    float bg_a,
    float extra_alpha,
    MetalGraphicsAlphaUniforms *out_uniforms
) {
    if (!data || !out_uniforms) {
        PyErr_SetString(PyExc_ValueError, "metal_renderer_pack_graphics_alpha_uniforms_for_tests requires data and output");
        return;
    }
    MetalPackedFloat3 fg = { fg_r * extra_alpha, fg_g * extra_alpha, fg_b * extra_alpha };
    vector_float4 bg = { bg_r * extra_alpha, bg_g * extra_alpha, bg_b * extra_alpha, bg_a * extra_alpha };
    *out_uniforms = metal_pack_graphics_alpha_uniforms(data, fg, bg);
}

EXPORTED void
metal_renderer_apply_draw_params_for_tests(
    MetalDrawParams *params,
    uint32_t draw_bg_mask,
    bool draw_foreground
) {
    if (!params) {
        PyErr_SetString(PyExc_ValueError, "metal_renderer_apply_draw_params_for_tests requires params");
        return;
    }
    metal_apply_draw_flags(params, draw_bg_mask, draw_foreground);
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
        .upload_graphics_image = metal_backend_upload_graphics_image,
        .destroy_graphics_image = metal_backend_destroy_graphics_image,
    };
    return renderer_backend_register(RENDERER_BACKEND_METAL, &metal_ops);
}
