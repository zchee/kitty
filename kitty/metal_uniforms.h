/*
 * metal_uniforms.h
 * Copyright (C) 2024 Kovid Goyal <kovid at kovidgoyal.net>
 *
 * Distributed under terms of the GPL3 license.
 */

#pragma once

// Struct definitions shared between the C shim (metal.m) and the Metal
// shaders (cell_shaders.metal). Every member is a 4-byte scalar, so the C
// natural layout, the MSL layout and the GLSL std140 layout (which packs
// consecutive scalars without padding) are all identical. Do NOT add vector
// types or manual padding here: the authoritative layout is the C writer
// struct GPUCellRenderData in kitty/shaders.c — keep field-for-field parity
// with it and with the CellRenderData UBO block in kitty/cell_vertex.glsl.

#ifdef __METAL_VERSION__
#include <metal_stdlib>
typedef metal::uint uint32;
#else
#include <stdint.h>
#include <stddef.h>
typedef uint32_t uint32;
#endif

typedef struct MetalCellRenderData {
    float use_cell_bg_for_selection_fg, use_cell_fg_for_selection_fg, use_cell_for_selection_bg;

    uint32 default_fg, highlight_fg, highlight_bg, main_cursor_fg, main_cursor_bg, url_color, url_style, inverted, extra_cursor_fg, extra_cursor_bg;

    uint32 columns, lines, sprites_xnum, sprites_ynum, cursor_shape, cell_width, cell_height;
    uint32 cursor_x1, cursor_x2, cursor_y1, cursor_y2;
    float cursor_opacity, inactive_text_alpha, dim_opacity, blink_opacity;

    uint32 bg_colors0, bg_colors1, bg_colors2, bg_colors3, bg_colors4, bg_colors5, bg_colors6, bg_colors7;
    float bg_opacities0, bg_opacities1, bg_opacities2, bg_opacities3, bg_opacities4, bg_opacities5, bg_opacities6, bg_opacities7;

    // F1: R8 mask sprite atlas. color_sprites_xnum/ynum are the colored-atlas
    // layout (mono layout stays in sprites_xnum/ynum); color_atlas_active is 1
    // when the split R8-mono + RGBA-color atlases are in use and 0 under the
    // KITTY_NO_R8_SPRITE_ATLAS kill switch. Appended at the end so all existing
    // std140/MSL offsets are unchanged.
    uint32 color_sprites_xnum, color_sprites_ynum, color_atlas_active;
} MetalCellRenderData;

// Per-draw uniforms for the cell programs, marshalled by draw_quad() in
// metal.m from the plain glUniform* value store.
typedef struct MetalCellDrawUniforms {
    uint32 draw_bg_bitfield;
    float row_offset;
    float text_contrast;
    float text_gamma_adjustment;
} MetalCellDrawUniforms;

// C5: per-draw uniform structs for the remaining frame-path programs, hoisted
// out of the metal.m draw dispatch (were anonymous inline structs) so the C
// filler writes MSL-layout memory directly and the _Static_asserts below pin the
// padding-sensitive offsets against the per-program .metal declarations. Each
// mirrors a struct in its shader: MetalBorderUniforms<->BorderUniforms
// (border_*.metal), MetalGraphicsUniforms<->GraphicsUniforms
// (graphics_shaders.metal), etc. MSL aligns float3 to 16 bytes, hence the pads.
// The byte-identical golden set is the cross-check that these match the shaders.
typedef struct MetalBorderUniforms {
    uint32 colors[9];         // colors[9] multi-element array (packs, no padding)
    float background_opacity;
    float gamma_lut[256];
} MetalBorderUniforms;

typedef struct MetalGraphicsUniforms {
    float src_rects[16 * 4];  // 16 == MAX_IMAGE_INSTANCES (state.h); asserted in metal.m
    float dest_rects[16 * 4];
    float extra_alpha;
    float _pad0[3];           // float3 amask_fg is 16-byte aligned in MSL
    float amask_fg[3];
    float _pad1;
    float amask_bg_premult[4];
    // W27 P4.2 tone-map inputs, appended so every offset above is unchanged.
    // edr_headroom is the window's screen headroom this frame; src_is_hdr is the
    // GL-uniform-style bool for "this image was transmitted as f=3232"; and
    // src_max_component is that image's largest R/G/B, which the soft knee's
    // shoulder is fitted against.
    float edr_headroom;
    float src_is_hdr;
    float src_max_component;
    // MSL rounds a struct's size up to its alignment, and the float4 members
    // above make that 16. The three floats land at 560..571, so MSL pads to 576
    // — spell that padding out here or the static_assert in
    // graphics_shaders.metal (sizeof parity) fails.
    float _pad2;
} MetalGraphicsUniforms;

typedef struct MetalBgimageUniforms {
    float sizes[4];
    float positions[4];
    float background[4];
    float tiled;
    float _pad[3];
} MetalBgimageUniforms;

typedef struct MetalTintUniforms {
    float tint_color[4];
    float edges[4];
} MetalTintUniforms;

typedef struct MetalTrailUniforms {
    float x_coords[4];
    float y_coords[4];
    float cursor_edge_x[2];
    float cursor_edge_y[2];
    float trail_color[3];     // float3 -> 16-byte slot, so trail_opacity lands at 64
    float _pad0;
    float trail_opacity;
    float _pad1[3];
} MetalTrailUniforms;

typedef struct MetalBlitUniforms {
    float src_rect[4];
    float dest_rect[4];
} MetalBlitUniforms;

typedef struct MetalScreenshotUniforms {
    float src_rect[4];
    float dest_rect[4];
    float src_size[2];
    float _pad[2];
} MetalScreenshotUniforms;

typedef struct MetalRoundedRectUniforms {
    float color[4];
    float background_color[4];
    float rect[4];
    float params[2];
    float _pad[2];
} MetalRoundedRectUniforms;

#ifndef __METAL_VERSION__
_Static_assert(sizeof(MetalCellRenderData) == 188, "MetalCellRenderData must match the GPUCellRenderData layout in shaders.c");
_Static_assert(offsetof(MetalCellRenderData, default_fg) == 12, "selection flags must occupy bytes 0-11");
_Static_assert(offsetof(MetalCellRenderData, columns) == 52, "color block must occupy bytes 12-51");
_Static_assert(offsetof(MetalCellRenderData, cursor_x1) == 80, "geometry block must occupy bytes 52-79");
_Static_assert(offsetof(MetalCellRenderData, cursor_opacity) == 96, "cursor rect must occupy bytes 80-95");
_Static_assert(offsetof(MetalCellRenderData, bg_colors0) == 112, "opacity block must occupy bytes 96-111");
_Static_assert(offsetof(MetalCellRenderData, bg_opacities0) == 144, "bg colors must occupy bytes 112-143");
_Static_assert(offsetof(MetalCellRenderData, color_sprites_xnum) == 176, "R8-atlas block must occupy bytes 176-187");
_Static_assert(sizeof(MetalCellDrawUniforms) == 16, "MetalCellDrawUniforms layout drifted");

// C5: pin the frame-path uniform structs to their MSL layouts.
_Static_assert(sizeof(MetalBorderUniforms) == 1064, "MetalBorderUniforms layout drifted");
_Static_assert(offsetof(MetalBorderUniforms, background_opacity) == 36, "border colors[9] must occupy bytes 0-35");
_Static_assert(offsetof(MetalBorderUniforms, gamma_lut) == 40, "border gamma_lut must start at 40");

_Static_assert(sizeof(MetalGraphicsUniforms) == 576, "MetalGraphicsUniforms layout drifted");
_Static_assert(offsetof(MetalGraphicsUniforms, edr_headroom) == 560, "graphics edr_headroom must follow amask_bg_premult at 560");
_Static_assert(offsetof(MetalGraphicsUniforms, dest_rects) == 256, "graphics src_rects[16] must occupy bytes 0-255");
_Static_assert(offsetof(MetalGraphicsUniforms, extra_alpha) == 512, "graphics dest_rects[16] must occupy bytes 256-511");
_Static_assert(offsetof(MetalGraphicsUniforms, amask_fg) == 528, "graphics amask_fg (float3) must be 16-aligned at 528");
_Static_assert(offsetof(MetalGraphicsUniforms, amask_bg_premult) == 544, "graphics amask_bg_premult must start at 544");

_Static_assert(sizeof(MetalBgimageUniforms) == 64, "MetalBgimageUniforms layout drifted");
_Static_assert(offsetof(MetalBgimageUniforms, tiled) == 48, "bgimage tiled must land at 48");

_Static_assert(sizeof(MetalTintUniforms) == 32, "MetalTintUniforms layout drifted");
_Static_assert(offsetof(MetalTintUniforms, edges) == 16, "tint edges must start at 16");

_Static_assert(sizeof(MetalTrailUniforms) == 80, "MetalTrailUniforms layout drifted");
_Static_assert(offsetof(MetalTrailUniforms, trail_opacity) == 64, "trail_opacity must land at 64 (float3 trail_color 16-aligned)");

_Static_assert(sizeof(MetalBlitUniforms) == 32, "MetalBlitUniforms layout drifted");

_Static_assert(sizeof(MetalScreenshotUniforms) == 48, "MetalScreenshotUniforms layout drifted");
_Static_assert(offsetof(MetalScreenshotUniforms, src_size) == 32, "screenshot src_size must start at 32");

_Static_assert(sizeof(MetalRoundedRectUniforms) == 64, "MetalRoundedRectUniforms layout drifted");
_Static_assert(offsetof(MetalRoundedRectUniforms, params) == 48, "rounded_rect params must start at 48");
#endif
