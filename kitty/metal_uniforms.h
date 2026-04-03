/*
 * metal_uniforms.h
 * Copyright (C) 2024 Kovid Goyal <kovid at kovidgoyal.net>
 *
 * Distributed under terms of the GPL3 license.
 */

#pragma once

// Shared struct definitions between C code and Metal shaders.
// These structs use std140-compatible layout for direct Metal buffer binding.
// In Metal shaders, include this file and use `constant StructName& [[buffer(N)]]`.

#ifdef __METAL_VERSION__
// Metal shading language
#include <metal_stdlib>
using namespace metal;
typedef float2 vec2;
typedef float3 vec3;
typedef float4 vec4;
typedef uint uint32;
#else
// C / Objective-C
#include <stdint.h>
#include <stdbool.h>
typedef struct { float x, y; } metal_vec2;
typedef struct { float x, y, z; } metal_vec3;
typedef struct { float x, y, z, w; } metal_vec4;
#define vec2 metal_vec2
#define vec3 metal_vec3
#define vec4 metal_vec4
#define uint32 uint32_t
#endif

// Cell rendering uniform data — maps to the CellRenderData UBO in GLSL
typedef struct {
    // Selection flags
    float use_cell_bg_for_selection_fg;
    float use_cell_fg_for_selection_color;
    float use_cell_for_selection_bg;
    float _pad0; // align to 16 bytes

    // Colors (stored as uint for bit manipulation in shaders)
    uint32 default_fg;
    uint32 highlight_fg;
    uint32 highlight_bg;
    uint32 main_cursor_fg;

    uint32 main_cursor_bg;
    uint32 url_color;
    uint32 url_style;
    uint32 inverted;

    uint32 extra_cursor_fg;
    uint32 extra_cursor_bg;
    uint32 _pad1;
    uint32 _pad2;

    // Grid layout
    uint32 columns;
    uint32 lines;
    uint32 sprites_xnum;
    uint32 sprites_ynum;

    uint32 cursor_shape;
    uint32 cell_width;
    uint32 cell_height;
    uint32 _pad3;

    // Cursor position
    uint32 cursor_x1;
    uint32 cursor_x2;
    uint32 cursor_y1;
    uint32 cursor_y2;

    // Opacity values
    float cursor_opacity;
    float inactive_text_alpha;
    float dim_opacity;
    float blink_opacity;

    // Background colors and opacities (8 layers)
    uint32 bg_colors0;
    uint32 bg_colors1;
    uint32 bg_colors2;
    uint32 bg_colors3;

    uint32 bg_colors4;
    uint32 bg_colors5;
    uint32 bg_colors6;
    uint32 bg_colors7;

    float bg_opacities0;
    float bg_opacities1;
    float bg_opacities2;
    float bg_opacities3;

    float bg_opacities4;
    float bg_opacities5;
    float bg_opacities6;
    float bg_opacities7;

    // Color table (256 entries, follows after the above fields)
    // In Metal, this is bound as a separate buffer
} MetalCellRenderData;

// Border rendering uniforms
typedef struct {
    uint32 colors[9]; // default_bg, active, inactive, 0, bell, tab_bg, tab_margin, left_edge, right_edge
    float background_opacity;
    float _pad0[2];
} MetalBorderUniforms;

// Graphics rendering uniforms
typedef struct {
    vec4 src_rect;
    vec4 dest_rect;
    float extra_alpha;
    float _pad0[3];
} MetalGraphicsUniforms;

// Background image uniforms
typedef struct {
    vec4 sizes;       // viewport_w, viewport_h, image_w, image_h
    vec4 positions;   // left, top, right, bottom
    vec4 background;  // r, g, b, a
    float tiled;
    float _pad0[3];
} MetalBgimageUniforms;

// Tint uniforms (visual bell, scrollbar)
typedef struct {
    vec4 tint_color;  // premultiplied RGBA
    vec4 edges;       // left, top, right, bottom in NDC
} MetalTintUniforms;

// Trail uniforms (cursor trail)
typedef struct {
    vec4 x_coords;
    vec4 y_coords;
    vec2 cursor_edge_x;
    vec2 cursor_edge_y;
    vec3 trail_color;
    float trail_opacity;
} MetalTrailUniforms;

// Blit uniforms (layer composition)
typedef struct {
    vec4 src_rect;
    vec4 dest_rect;
} MetalBlitUniforms;

// Screenshot uniforms
typedef struct {
    vec4 src_rect;
    vec4 dest_rect;
    vec2 src_size;
    vec2 _pad0;
} MetalScreenshotUniforms;

// Rounded rect uniforms
typedef struct {
    vec4 color;
    vec4 background_color;
    vec4 rect;        // x, y, w, h in pixels
    vec2 params;      // thickness, corner_radius
    vec2 _pad0;
} MetalRoundedRectUniforms;

#ifndef __METAL_VERSION__
#undef vec2
#undef vec3
#undef vec4
#undef uint32
#endif
