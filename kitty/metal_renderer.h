#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "compiler.h"
#include "renderer_backend_types.h"

#ifdef __cplusplus
extern "C" {
#endif

EXPORTED bool register_metal_renderer_backend(void);
EXPORTED bool metal_renderer_preflight(const char **failure_reason);
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

#ifdef __cplusplus
}
#endif
