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
#endif
