#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "compiler.h"
#include "renderer_backend_types.h"

struct BackgroundImage;

#ifdef __cplusplus
extern "C" {
#endif

EXPORTED bool register_metal_renderer_backend(void);
EXPORTED bool metal_renderer_preflight(const char **failure_reason);
EXPORTED uint32_t metal_cell_draw_flag_defaults(void);
EXPORTED bool metal_compute_viewport_params(
    unsigned int framebuffer_width,
    unsigned int framebuffer_height,
    unsigned int left,
    unsigned int top,
    unsigned int right,
    unsigned int bottom,
    float *out_scale_x,
    float *out_scale_y,
    float *out_origin_x,
    float *out_origin_y);

typedef struct {
    uint32_t colors[9];
    float background_opacity;
    float _pad[2];
} MetalBorderUniforms;

typedef struct {
    float x_coords[4];
    float y_coords[4];
    float cursor_edge_x[2];
    float cursor_edge_y[2];
    uint32_t color;
    float opacity;
    float _pad[2];
} MetalTrailUniforms;

EXPORTED void metal_renderer_prepare_border_uniforms_for_tests(
    color_type default_bg,
    color_type active_border_color,
    color_type inactive_border_color,
    color_type bell_border_color,
    color_type tab_bar_background,
    color_type tab_bar_margin_color,
    color_type tab_bar_edge_left,
    color_type tab_bar_edge_right,
    float background_opacity,
    MetalBorderUniforms *out_uniforms);

EXPORTED void metal_renderer_prepare_trail_uniforms_for_tests(
    const float corner_x[4],
    const float corner_y[4],
    const float cursor_edge_x[2],
    const float cursor_edge_y[2],
    color_type color,
    float opacity,
    MetalTrailUniforms *out_uniforms);

typedef struct {
    float tiled;
    float positions[4];
    float sizes[4];
} MetalBackgroundGeometry;

EXPORTED bool metal_compute_background_geometry(
    unsigned int framebuffer_width,
    unsigned int framebuffer_height,
    unsigned int image_width,
    unsigned int image_height,
    unsigned int layout,
    MetalBackgroundGeometry *out_geometry);

EXPORTED void metal_background_image_uploaded(struct BackgroundImage *bgimage, unsigned int layout, bool linear_filter);
EXPORTED void metal_background_image_release(struct BackgroundImage *bgimage);

typedef struct MetalGraphicsTextureDebugInfo {
    uint32_t width;
    uint32_t height;
    bool linear_filter;
    bool is_opaque;
    RepeatStrategy repeat;
} MetalGraphicsTextureDebugInfo;

EXPORTED bool metal_renderer_debug_get_graphics_texture(
    uint32_t texture_id,
    MetalGraphicsTextureDebugInfo *out_info
);

typedef struct MetalCapturedFrameDebugInfo {
    uint32_t width;
    uint32_t height;
    uint32_t bytes_per_row;
    const uint8_t *pixels;
} MetalCapturedFrameDebugInfo;

_Static_assert(sizeof(MetalTrailUniforms) == 64, "MetalTrailUniforms layout mismatch");
_Static_assert(sizeof(MetalGraphicsUniforms) == 48, "MetalGraphicsUniforms layout mismatch");
_Static_assert(sizeof(MetalGraphicsAlphaUniforms) == 64, "MetalGraphicsAlphaUniforms layout mismatch");

EXPORTED bool metal_renderer_copy_captured_frame_for_tests(MetalCapturedFrameDebugInfo *out_info);
EXPORTED bool metal_renderer_debug_set_captured_frame_for_tests(
    const uint8_t *pixels,
    uint32_t width,
    uint32_t height,
    uint32_t bytes_per_row,
    bool pixels_are_bgra
);
EXPORTED void metal_renderer_debug_clear_captured_frame_for_tests(void);

#ifdef __cplusplus
}
#endif
