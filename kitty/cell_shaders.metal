/*
 * cell_shaders.metal
 * Copyright (C) 2024 Kovid Goyal <kovid at kovidgoyal.net>
 *
 * Distributed under terms of the GPL3 license.
 *
 * MSL translation of cell_vertex.glsl + cell_fragment.glsl (and the parts of
 * utils.glsl / alpha_blend.glsl / linear2srgb.glsl they use). Structure and
 * naming deliberately mirror the GLSL sources 1:1 so that upstream shader
 * changes can be diffed across. The GLSL {PLACEHOLDER} defines from
 * cell_defines.glsl are baked below from their C definitions (CellAttrs in
 * kitty/line.h, color type enum in kitty/data-types.h); the per-program
 * variants (CELL / CELL_FG / CELL_BG and the fg-override options resolved in
 * Python's resolve_cell_defines) become Metal function constants set at
 * pipeline creation in metal.m.
 */

#include <metal_stdlib>
#include "metal_uniforms.h"
using namespace metal;

// ---- Baked cell_defines.glsl values ----
// Bit positions from union CellAttrs in kitty/line.h
constant constexpr uint DECORATION_SHIFT = 0u;
constant constexpr uint REVERSE_SHIFT = 5u;
constant constexpr uint STRIKE_SHIFT = 6u;
constant constexpr uint DIM_SHIFT = 7u;
constant constexpr uint BLINK_SHIFT = 8u;
constant constexpr uint MARK_SHIFT = 9u;
constant constexpr uint MARK_MASK_C = 3u;
constant constexpr uint DECORATION_MASK = 7u;
constant constexpr uint NUM_COLORS = 256u;
// enum from kitty/data-types.h: COLOR_NOT_SET, COLOR_IS_SPECIAL, COLOR_IS_INDEX, COLOR_IS_RGB
constant constexpr uint COLOR_NOT_SET = 0u;
constant constexpr uint COLOR_IS_SPECIAL = 1u;
constant constexpr uint COLOR_IS_INDEX = 2u;
constant constexpr uint COLOR_IS_RGB = 3u;

constant constexpr uint BYTE_MASK = 0xFFu;
constant constexpr uint SPRITE_INDEX_MASK = 0x7fffffffu;
constant constexpr uint SPRITE_COLORED_MASK = 0x80000000u;
constant constexpr uint SPRITE_COLORED_SHIFT = 31u;
constant constexpr uint BIT_MASK = 1u;

// Linear space luminance values
constant constexpr float3 Y = float3(0.2126f, 0.7152f, 0.0722f);

// Scaling factor for the extra text-alpha adjustment for luminance-difference.
constant constexpr float text_gamma_scaling = 0.5f;

// ---- Program-variant function constants (set in metal.m build_pso) ----
constant bool ONLY_FOREGROUND [[function_constant(0)]];
constant bool ONLY_BACKGROUND [[function_constant(1)]];
constant bool DO_FG_OVERRIDE [[function_constant(2)]];
constant int FG_OVERRIDE_ALGO [[function_constant(3)]];
constant float FG_OVERRIDE_THRESHOLD [[function_constant(4)]];
constant bool TEXT_NEW_GAMMA [[function_constant(5)]];
// C1: set on the opaque path (drawable is a plain BGRA8Unorm, no sRGB view) so
// the fragment encodes linear->sRGB itself, exactly as the old sRGB drawable
// view did on write. Unset on the layered path (output stays linear in the
// RGBA16Unorm working surface; the resolve draw encodes).
constant bool SRGB_ENCODE_OUTPUT [[function_constant(6)]];

// ---- utils.glsl ----
static inline float zero_or_one(float x) { return step(1.0f, x); }
static inline float if_one_then(float c, float thenval, float elseval) { return mix(elseval, thenval, c); }
static inline float3 if_one_then(float c, float3 thenval, float3 elseval) { return mix(elseval, thenval, c); }
static inline float4 if_one_then(float c, float4 thenval, float4 elseval) { return mix(elseval, thenval, c); }
static inline float3 if_less_than(float a, float b, float3 thenval, float3 elseval) { return mix(thenval, elseval, step(b, a)); }
static inline float4 vec4_premul(float3 rgb, float a) { return float4(rgb * a, a); }

// ---- Triangle strip vertex mapping ----
// GLSL draws a 4-vertex GL_TRIANGLE_FAN quad; Metal has no fan primitive, so
// draw_quad() uses a triangle strip and the corner LUT is reordered:
// strip[0]=fan[2], strip[1]=fan[1], strip[2]=fan[3], strip[3]=fan[0].
// Corner semantics (uvec2(x_right, y_bottom)) are unchanged.
constant uint2 cell_pos_map[4] = {
    uint2(0u, 1u),  // left, bottom  (fan 2)
    uint2(1u, 1u),  // right, bottom (fan 1)
    uint2(0u, 0u),  // left, top     (fan 3)
    uint2(1u, 0u),  // right, top    (fan 0)
};

constant int fg_index_map[3] = {0, 1, 0};
constant uint cursor_shape_map[5] = {  // maps cursor shape to foreground sprite index
    0u,  // NO_CURSOR
    0u,  // BLOCK (rendered as background)
    2u,  // BEAM
    3u,  // UNDERLINE
    4u   // UNFOCUSED
};

// ---- Vertex input / output ----
struct CellVertexIn {
    uint3 colors [[attribute(0)]];      // fg, bg, decoration_fg
    uint2 sprite_idx [[attribute(1)]];  // sprite index, text_attrs
    uint is_selected [[attribute(2)]];
};

struct CellVertexOut {
    float4 position [[position]];
    float3 background;
    float4 effective_background_premul;
    float effective_text_alpha;
    float3 sprite_pos;
    float3 underline_pos;
    float3 cursor_pos;
    float3 strike_pos;
    uint underline_exclusion_pos [[flat]];
    float3 cell_foreground;
    float4 cursor_color_premult;
    float3 decoration_fg;
    float colored_sprite;
    float use_color_atlas [[flat]];  // F1: sample the text texel from color_sprites when >0.5
};

// ---- Utility functions (cell_vertex.glsl) ----

static inline float3 color_to_vec(uint c, constant float *gamma_lut) {
    uint r = (c >> 16) & BYTE_MASK;
    uint g = (c >> 8) & BYTE_MASK;
    uint b = c & BYTE_MASK;
    return float3(gamma_lut[r], gamma_lut[g], gamma_lut[b]);
}

static inline float one_if_equal_zero_otherwise(float a, float b) { return 1.0f - zero_or_one(abs(a - b)); }
static inline uint one_if_equal_zero_otherwise(uint a, uint b) { return 1u - uint(zero_or_one(abs(float(a) - float(b)))); }
static inline uint one_if_equal_zero_otherwise(int a, int b) { return 1u - uint(zero_or_one(abs(float(a) - float(b)))); }

static inline uint resolve_color(uint c, uint defval, constant uint32 *color_table) {
    // Convert a cell color to an actual color based on the color table
    int t = int(c & BYTE_MASK);
    uint is_one = one_if_equal_zero_otherwise(t, 1);
    uint is_two = one_if_equal_zero_otherwise(t, 2);
    uint is_neither_one_nor_two = 1u - is_one - is_two;
    return is_one * color_table[(c >> 8) & BYTE_MASK] + is_two * (c >> 8) + is_neither_one_nor_two * defval;
}

static inline float3 to_color(uint c, uint defval, constant uint32 *color_table, constant float *gamma_lut) {
    return color_to_vec(resolve_color(c, defval, color_table), gamma_lut);
}

static inline float3 resolve_dynamic_color(uint c, float3 special_val, float3 defval, constant uint32 *color_table, constant float *gamma_lut) {
    float type = float((c >> 24) & BYTE_MASK);
#define q(which, val) one_if_equal_zero_otherwise(type, float(which)) * (val)
    return (
        q(COLOR_IS_RGB, color_to_vec(c, gamma_lut)) + q(COLOR_IS_INDEX, color_to_vec(color_table[c & BYTE_MASK], gamma_lut)) +
        q(COLOR_IS_SPECIAL, special_val) + q(COLOR_NOT_SET, defval)
    );
#undef q
}

static inline float contrast_ratio(float under_luminance, float over_luminance) {
    return clamp((max(under_luminance, over_luminance) + 0.05f) / (min(under_luminance, over_luminance) + 0.05f), 1.f, 21.f);
}

static inline float contrast_ratio_v(float3 a, float3 b) {
    return contrast_ratio(dot(a, Y), dot(b, Y));
}

struct ColorPair {
    float3 bg, fg;
};

static inline float contrast_ratio_p(ColorPair a) { return contrast_ratio_v(a.bg, a.fg); }

static inline ColorPair if_less_than_pair(float a, float b, ColorPair thenval, ColorPair elseval) {
    ColorPair r;
    r.bg = if_less_than(a, b, thenval.bg, elseval.bg);
    r.fg = if_less_than(a, b, thenval.fg, elseval.fg);
    return r;
}

static inline ColorPair if_one_then_pair(float condition, ColorPair thenval, ColorPair elseval) {
    ColorPair r;
    r.bg = if_one_then(condition, thenval.bg, elseval.bg);
    r.fg = if_one_then(condition, thenval.fg, elseval.fg);
    return r;
}

static inline ColorPair resolve_extra_cursor_colors_for_special_cursor(
        float3 cell_bg, float3 cell_fg, constant MetalCellRenderData& rd, constant float *gamma_lut) {
    ColorPair cell = {cell_fg, cell_bg};
    ColorPair base = {color_to_vec(rd.default_fg, gamma_lut), color_to_vec(rd.bg_colors0, gamma_lut)};
    float cr = contrast_ratio_p(cell), br = contrast_ratio_p(base);
    ColorPair higher_contrast_pair = if_less_than_pair(cr, br, base, cell);
    return if_less_than_pair(cr, 2.5f, higher_contrast_pair, cell);
}

static inline ColorPair resolve_extra_cursor_colors(
        float3 cell_bg, float3 cell_fg, ColorPair main_cursor,
        constant MetalCellRenderData& rd, constant uint32 *color_table, constant float *gamma_lut) {
    ColorPair ans;
    ans.bg = resolve_dynamic_color(rd.extra_cursor_bg, main_cursor.bg, main_cursor.bg, color_table, gamma_lut);
    ans.fg = resolve_dynamic_color(rd.extra_cursor_fg, cell_bg, main_cursor.fg, color_table, gamma_lut);
    ColorPair special = resolve_extra_cursor_colors_for_special_cursor(cell_bg, cell_fg, rd, gamma_lut);
    return if_one_then_pair(zero_or_one(abs(float(rd.extra_cursor_bg & BYTE_MASK) - float(COLOR_IS_SPECIAL))), ans, special);
}

// F1: xnum/ynum/cell_height passed explicitly so the same math serves both the
// mono atlas (rd.sprites_xnum/ynum) and the colored atlas (rd.color_sprites_*).
static inline uint3 to_sprite_coords(uint idx, uint xnum, uint ynum) {
    uint sprites_per_page = xnum * ynum;
    uint z = idx / sprites_per_page;
    uint num_on_last_page = idx - sprites_per_page * z;
    uint y = num_on_last_page / xnum;
    uint x = num_on_last_page - xnum * y;
    return uint3(x, y, z);
}

static inline float3 to_sprite_pos(uint2 pos, uint idx, uint xnum, uint ynum, uint cell_height) {
    uint3 c = to_sprite_coords(idx, xnum, ynum);
    float2 s_xpos = float2(c.x, float(c.x) + 1.0f) * (1.0f / float(xnum));
    float2 s_ypos = float2(c.y, float(c.y) + 1.0f) * (1.0f / float(ynum));
    uint texture_height_px = (cell_height + 1u) * ynum;
    float row_height = 1.0f / float(texture_height_px);
    s_ypos[1] -= row_height;  // skip the decorations_exclude row
    return float3(s_xpos[pos.x], s_ypos[pos.y], c.z);
}

static inline uint to_underline_exclusion_pos(uint sprite_idx0, uint xnum, uint ynum, uint cell_height) {
    uint3 c = to_sprite_coords(sprite_idx0, xnum, ynum);
    uint cell_top_px = c.y * (cell_height + 1u);
    return cell_top_px + cell_height;
}

static inline uint read_sprite_decorations_idx(uint sprite_idx0, texture2d<uint, access::read> sprite_decorations_map) {
    int idx = int(sprite_idx0 & SPRITE_INDEX_MASK);
    int width = int(sprite_decorations_map.get_width());
    int y = idx / width;
    int x = idx - y * width;
    return sprite_decorations_map.read(uint2(x, y)).r;
}

static inline uint2 get_decorations_indices(
        uint in_url /* [0, 1] */, uint text_attrs, uint sprite_idx0,
        texture2d<uint, access::read> sprite_decorations_map, constant MetalCellRenderData& rd) {
    uint decorations_idx = read_sprite_decorations_idx(sprite_idx0, sprite_decorations_map);
    // decorations_idx == 0 means no decorations, for example, for a blank line
    // when drawing fractionally scaled text
    uint has_decorations = uint(zero_or_one(float(decorations_idx)));
    uint strike_style = ((text_attrs >> STRIKE_SHIFT) & BIT_MASK); // 0 or 1
    uint strike_idx = decorations_idx * strike_style;
    uint underline_style = ((text_attrs >> DECORATION_SHIFT) & DECORATION_MASK);
    underline_style = in_url * rd.url_style + (1u - in_url) * underline_style; // [0, 5]
    uint has_underline = uint(step(0.5f, float(underline_style)));  // [0, 1]
    return has_decorations * uint2(strike_idx, has_underline * (decorations_idx + underline_style));
}

static inline uint is_cursor(uint x, uint y, constant MetalCellRenderData& rd) {
    uint clamped_x = clamp(x, rd.cursor_x1, rd.cursor_x2);
    uint clamped_y = clamp(y, rd.cursor_y1, rd.cursor_y2);
    return one_if_equal_zero_otherwise(x, clamped_x) * one_if_equal_zero_otherwise(y, clamped_y);
}

static inline float background_opacity_for(uint bg, uint colorval, float opacity_if_matched) {
    // opacity_if_matched if bg == colorval else 1
    float not_matched = step(1.f, abs(float(colorval) - float(bg)));
    return not_matched + opacity_if_matched * (1.f - not_matched);
}

static inline float calc_background_opacity(uint bg, constant MetalCellRenderData& rd) {
    return (
        background_opacity_for(bg, rd.bg_colors0, rd.bg_opacities0) *
        background_opacity_for(bg, rd.bg_colors1, rd.bg_opacities1) *
        background_opacity_for(bg, rd.bg_colors2, rd.bg_opacities2) *
        background_opacity_for(bg, rd.bg_colors3, rd.bg_opacities3) *
        background_opacity_for(bg, rd.bg_colors4, rd.bg_opacities4) *
        background_opacity_for(bg, rd.bg_colors5, rd.bg_opacities5) *
        background_opacity_for(bg, rd.bg_colors6, rd.bg_opacities6) *
        background_opacity_for(bg, rd.bg_colors7, rd.bg_opacities7)
    );
}

// Overriding of foreground colors for contrast requirements.
// Only FG_OVERRIDE_ALGO 1 is implemented; algo 2 needs the hsluv color space
// (hsluv.glsl) and falls back to algo 1 until it is ported.
static inline float3 fg_override(float under_luminance, float over_luminance, float3 over, float colored_sprite) {
    float diff_luminance = abs(under_luminance - over_luminance);
    float override_level = (1.f - colored_sprite) * step(diff_luminance, FG_OVERRIDE_THRESHOLD);
    float original_level = 1.f - override_level;
    return original_level * over + override_level * float3(step(under_luminance, 0.5f));
}

static inline float3 override_foreground_color(float3 over, float3 under, float colored_sprite) {
    float under_luminance = dot(under, Y);
    float over_luminance = dot(over, Y);
    return fg_override(under_luminance, over_luminance, over, colored_sprite);
}

// ---- Cell Vertex Shader ----
// Mirrors main() in cell_vertex.glsl.

vertex CellVertexOut cell_vertex(
    CellVertexIn in [[stage_in]],
    uint vid [[vertex_id]],
    uint iid [[instance_id]],
    constant MetalCellRenderData& rd [[buffer(1)]],
    constant MetalCellDrawUniforms& du [[buffer(2)]],
    constant float *gamma_lut [[buffer(3)]],
    constant uint32 *color_table [[buffer(4)]],
    texture2d<uint, access::read> sprite_decorations_map [[texture(2)]],
    texture2d<uint, access::read> color_sprite_decorations_map [[texture(3)]]  // F1
) {
    CellVertexOut out;
    out.effective_background_premul = float4(0.f);
    out.effective_text_alpha = 0.f;
    out.sprite_pos = float3(0.f);
    out.underline_pos = float3(0.f);
    out.cursor_pos = float3(0.f);
    out.strike_pos = float3(0.f);
    out.underline_exclusion_pos = 0u;
    out.cell_foreground = float3(0.f);
    out.cursor_color_premult = float4(0.f);
    out.decoration_fg = float3(0.f);
    out.colored_sprite = 0.f;
    out.use_color_atlas = 0.f;

    // set cell color indices {{{
    uint2 default_colors = uint2(rd.default_fg, rd.bg_colors0);
    uint text_attrs = in.sprite_idx[1];
    uint is_reversed = ((text_attrs >> REVERSE_SHIFT) & BIT_MASK);
    uint is_inverted = is_reversed + rd.inverted;
    int fg_index = fg_index_map[is_inverted];
    int bg_index = 1 - fg_index;
    int mark = int(text_attrs >> MARK_SHIFT) & int(MARK_MASK_C);
    uint has_mark = uint(step(1.f, float(mark)));
    uint bg_as_uint = resolve_color(in.colors[bg_index], default_colors[bg_index], color_table);
    bg_as_uint = has_mark * color_table[NUM_COLORS + uint(mark) - 1u] + (BIT_MASK - has_mark) * bg_as_uint;
    float cell_has_default_bg = 1.f - step(1.f, abs(float(bg_as_uint) - float(rd.bg_colors0))); // 1 if has default bg else 0
    float3 bg = color_to_vec(bg_as_uint, gamma_lut);
    uint fg_as_uint = resolve_color(in.colors[fg_index], default_colors[fg_index], color_table);
    fg_as_uint = has_mark * color_table[NUM_COLORS + MARK_MASK_C + uint(mark)] + (1u - has_mark) * fg_as_uint;
    float3 foreground = color_to_vec(fg_as_uint, gamma_lut);
    // }}}

    // set_vertex_position() {{{
    float dx = 2.0f / float(rd.columns);
    float dy = 2.0f / float(rd.lines);
    uint row = iid / rd.columns;
    uint column = iid - row * rd.columns;
    float left = -1.0f + float(column) * dx;
    float top = 1.0f - (float(row) + du.row_offset) * dy;
    uint2 pos = cell_pos_map[vid];
    out.position = float4(float2(left, left + dx)[pos.x], float2(top, top - dy)[pos.y], 0.f, 1.f);
    // The character sprite being rendered
    if (!ONLY_BACKGROUND) {
        out.colored_sprite = float((in.sprite_idx[0] & SPRITE_COLORED_MASK) >> SPRITE_COLORED_SHIFT);
        // F1: colored sprites only live in the separate atlas when the split is
        // active; under the kill switch (color_atlas_active==0) everything is mono.
        out.use_color_atlas = out.colored_sprite * float(rd.color_atlas_active);
        uint text_sprite_idx = in.sprite_idx[0] & SPRITE_INDEX_MASK;
        if (out.use_color_atlas > 0.5f) out.sprite_pos = to_sprite_pos(pos, text_sprite_idx, rd.color_sprites_xnum, rd.color_sprites_ynum, rd.cell_height);
        else out.sprite_pos = to_sprite_pos(pos, text_sprite_idx, rd.sprites_xnum, rd.sprites_ynum, rd.cell_height);
    }
    // Cursor shape and colors
    float has_main_cursor = float(is_cursor(column, row, rd));
    float multicursor_shape = float((in.is_selected >> 2) & 3u);
    float multicursor_uses_main_cursor_shape = float((in.is_selected >> 4) & BIT_MASK);
    multicursor_shape = if_one_then(multicursor_uses_main_cursor_shape, float(rd.cursor_shape), multicursor_shape);
    float final_cursor_shape = if_one_then(has_main_cursor, float(rd.cursor_shape), multicursor_shape);
    float has_cursor = zero_or_one(final_cursor_shape);
    float has_block_cursor = has_cursor * one_if_equal_zero_otherwise(final_cursor_shape, 1.0f);
    ColorPair main_cursor = {color_to_vec(rd.main_cursor_bg, gamma_lut), color_to_vec(rd.main_cursor_fg, gamma_lut)};
    ColorPair extra_cursor = resolve_extra_cursor_colors(bg, foreground, main_cursor, rd, color_table, gamma_lut);
    ColorPair cursor = if_one_then_pair(has_main_cursor, main_cursor, extra_cursor);
    uint cursor_fg_sprite_idx = cursor_shape_map[int(final_cursor_shape)];
    // }}}

    // Foreground {{{
    if (!ONLY_BACKGROUND) { // background does not depend on foreground
        float has_dim = float((text_attrs >> DIM_SHIFT) & BIT_MASK), has_blink = float((text_attrs >> BLINK_SHIFT) & BIT_MASK);
        out.effective_text_alpha = rd.inactive_text_alpha * if_one_then(has_dim, rd.dim_opacity, 1.0f) * if_one_then(
                has_blink, rd.blink_opacity, 1.0f);
        float in_url = float((in.is_selected >> 1) & BIT_MASK);
        out.decoration_fg = if_one_then(in_url, color_to_vec(rd.url_color, gamma_lut), to_color(in.colors[2], fg_as_uint, color_table, gamma_lut));
        // Selection
        float3 selection_color = if_one_then(rd.use_cell_bg_for_selection_fg, bg, color_to_vec(rd.highlight_fg, gamma_lut));
        selection_color = if_one_then(rd.use_cell_fg_for_selection_fg, foreground, selection_color);
        foreground = if_one_then(float(in.is_selected & BIT_MASK), selection_color, foreground);
        out.decoration_fg = if_one_then(float(in.is_selected & BIT_MASK), selection_color, out.decoration_fg);
        // Underline and strike through (rendered via sprites)
        // Read the decoration index from the atlas namespace this cell's text
        // sprite belongs to; the stored value is always a mono-namespace sprite
        // index, so the strike/underline positions use the mono layout.
        uint2 decs = (out.use_color_atlas > 0.5f)
            ? get_decorations_indices(uint(in_url), text_attrs, in.sprite_idx[0], color_sprite_decorations_map, rd)
            : get_decorations_indices(uint(in_url), text_attrs, in.sprite_idx[0], sprite_decorations_map, rd);
        out.strike_pos = to_sprite_pos(pos, decs[0], rd.sprites_xnum, rd.sprites_ynum, rd.cell_height);
        out.underline_pos = to_sprite_pos(pos, decs[1], rd.sprites_xnum, rd.sprites_ynum, rd.cell_height);
        // The exclusion mask lives in the text glyph's own cell, so use the atlas
        // the text sprite is in.
        uint excl_idx = in.sprite_idx[0] & SPRITE_INDEX_MASK;
        if (out.use_color_atlas > 0.5f) out.underline_exclusion_pos = to_underline_exclusion_pos(excl_idx, rd.color_sprites_xnum, rd.color_sprites_ynum, rd.cell_height);
        else out.underline_exclusion_pos = to_underline_exclusion_pos(excl_idx, rd.sprites_xnum, rd.sprites_ynum, rd.cell_height);

        // Cursor
        out.cursor_color_premult = float4(cursor.bg * rd.cursor_opacity, rd.cursor_opacity);
        float3 final_cursor_text_color = mix(foreground, cursor.fg, rd.cursor_opacity);
        foreground = if_one_then(has_block_cursor, final_cursor_text_color, foreground);
        out.decoration_fg = if_one_then(has_block_cursor, final_cursor_text_color, out.decoration_fg);
        out.cursor_pos = to_sprite_pos(pos, cursor_fg_sprite_idx * uint(has_cursor), rd.sprites_xnum, rd.sprites_ynum, rd.cell_height);
    }
    // }}}

    // Background {{{
    float bg_alpha = calc_background_opacity(bg_as_uint, rd);
    // we use max so that opacity of the block cursor cell background goes from bg_alpha to 1
    float effective_cursor_opacity = max(rd.cursor_opacity, bg_alpha);
    // is_special_cell is either 0 or 1
    float is_special_cell = has_block_cursor + float(in.is_selected & BIT_MASK);
    is_special_cell += float(is_reversed);  // reverse video cells should be opaque as well
    is_special_cell = zero_or_one(is_special_cell);
    cell_has_default_bg = if_one_then(is_special_cell, 0.f, cell_has_default_bg);

    // special cells must always be fully opaque, otherwise leave bg_alpha untouched
    bg_alpha = if_one_then(is_special_cell, 1.f, bg_alpha);
    // Selection and cursor
    bg_alpha = if_one_then(has_block_cursor, effective_cursor_opacity, bg_alpha);
    bg = if_one_then(float(in.is_selected & BIT_MASK),
            if_one_then(rd.use_cell_for_selection_bg, color_to_vec(fg_as_uint, gamma_lut), color_to_vec(rd.highlight_bg, gamma_lut)), bg);
    float3 background_rgb = if_one_then(has_block_cursor, mix(bg, cursor.bg, rd.cursor_opacity), bg);
    out.background = background_rgb;
    // }}}

    if (!ONLY_BACKGROUND && DO_FG_OVERRIDE) {
        out.decoration_fg = override_foreground_color(out.decoration_fg, background_rgb, out.colored_sprite);
        foreground = override_foreground_color(foreground, background_rgb, out.colored_sprite);
    }

    if (!ONLY_FOREGROUND) {
        float4 bgpremul = vec4_premul(background_rgb, bg_alpha);
        // draw_bg_bitfield has bit 0 set to draw default bg cells and bit 1 set to draw non-default bg cells
        float cell_has_non_default_bg = 1.f - cell_has_default_bg;
        uint draw_bg_mask = uint(2.f * cell_has_non_default_bg + cell_has_default_bg); // 1 if has default bg else 2
        float draw_bg = step(0.5f, float(du.draw_bg_bitfield & draw_bg_mask));
        bgpremul *= draw_bg;
        out.effective_background_premul = bgpremul;
    }

    if (!ONLY_BACKGROUND) {
        out.cell_foreground = foreground;
    }
    return out;
}

// ---- Fragment shader helpers (linear2srgb.glsl / alpha_blend.glsl) ----

static inline float srgb2linear(float x) {
    float lower = x / 12.92f;
    float upper = pow((x + 0.055f) / 1.055f, 2.4f);
    return mix(lower, upper, step(0.04045f, x));
}

static inline float linear2srgb(float x) {
    float lower = 12.92f * x;
    float upper = 1.055f * pow(x, 1.0f / 2.4f) - 0.055f;
    return mix(lower, upper, step(0.0031308f, x));
}

static inline float4 alpha_blend(float4 over, float4 under) {
    // Alpha blend two colors returning the resulting color pre-multiplied by
    // its alpha and its alpha.
    float alpha = mix(under.a, 1.0f, over.a);
    float3 combined_color = mix(under.rgb * under.a, over.rgb, over.a);
    return float4(combined_color, alpha);
}

static inline float4 alpha_blend_premul(float4 over, float4 under) {
    float inv_over_alpha = 1.0f - over.a;
    float alpha = over.a + under.a * inv_over_alpha;
    return float4(over.rgb + under.rgb * inv_over_alpha, alpha);
}

static inline float clamp_to_unit_float(float x) { return clamp(x, 0.0f, 1.0f); }

static inline float4 foreground_contrast(float4 over, float3 under, constant MetalCellDrawUniforms& du) {
    float under_luminance = dot(under, Y);
    float over_luminance = dot(over.rgb, Y);
    if (TEXT_NEW_GAMMA) {
        // Apply additional gamma-adjustment scaled by the luminance difference,
        // the darker the foreground the more adjustment we apply.
        // A multiplicative contrast is also available to increase saturation.
        over.a = clamp_to_unit_float(mix(over.a, pow(over.a, du.text_gamma_adjustment), (1.f - over_luminance + under_luminance) * text_gamma_scaling) * du.text_contrast);
    } else {
        // Simulation of gamma-incorrect blending
        over.a = clamp_to_unit_float((srgb2linear(linear2srgb(over_luminance) * over.a + linear2srgb(under_luminance) * (1.0f - over.a)) - under_luminance) / (over_luminance - under_luminance));
    }
    return over;
}

// ---- Cell Fragment Shader ----
// Mirrors main() in cell_fragment.glsl.

constexpr sampler sprite_sampler(coord::normalized, address::clamp_to_edge, filter::nearest);

fragment float4 cell_fragment(
    CellVertexOut in [[stage_in]],
    constant MetalCellDrawUniforms& du [[buffer(2)]],
    texture2d_array<float> sprites [[texture(0)]],
    texture2d_array<float> color_sprites [[texture(1)]]  // F1: colored (RGBA) atlas
) {
    float4 ans_premul = float4(0.f);
    if (!ONLY_FOREGROUND) {
        ans_premul = in.effective_background_premul;
    }

    if (!ONLY_BACKGROUND) {
        uint sprite_layer = uint(in.sprite_pos.z + 0.5f);
        // load_text_foreground_color(): for colored sprites use the color from
        // the sprite rather than the text foreground (non-premultiplied). F1:
        // colored text lives in the RGBA color atlas; mono glyphs (and everything
        // under the kill switch) stay in the R8 mono atlas (swizzled coverage->.a).
        float4 sprite_texel = (in.use_color_atlas > 0.5f)
            ? color_sprites.sample(sprite_sampler, in.sprite_pos.xy, sprite_layer)
            : sprites.sample(sprite_sampler, in.sprite_pos.xy, sprite_layer);
        float4 text_fg = float4(mix(in.cell_foreground, sprite_texel.rgb, in.colored_sprite), sprite_texel.a);
        // adjust_foreground_contrast_with_background()
        text_fg = foreground_contrast(text_fg, in.background, du);
        // calculate_premul_foreground_from_sprites()
        float underline_alpha = sprites.sample(sprite_sampler, in.underline_pos.xy, uint(in.underline_pos.z + 0.5f)).a;
        // Exclusion mask lives in the text glyph's own atlas (color or mono).
        uint sz_x = (in.use_color_atlas > 0.5f) ? color_sprites.get_width() : sprites.get_width();
        float underline_exclusion = (in.use_color_atlas > 0.5f)
            ? color_sprites.read(uint2(uint(in.sprite_pos.x * float(sz_x)), in.underline_exclusion_pos), sprite_layer).a
            : sprites.read(uint2(uint(in.sprite_pos.x * float(sz_x)), in.underline_exclusion_pos), sprite_layer).a;
        underline_alpha *= 1.0f - underline_exclusion;
        float strike_alpha = sprites.sample(sprite_sampler, in.strike_pos.xy, uint(in.strike_pos.z + 0.5f)).a;
        float cursor_alpha = sprites.sample(sprite_sampler, in.cursor_pos.xy, uint(in.cursor_pos.z + 0.5f)).a;
        // Since strike and text are the same color, we simply add the alpha values
        float combined_alpha = min(text_fg.a + strike_alpha, 1.0f);
        // Underline color might be different, so alpha blend
        float4 text_fg_premul = alpha_blend(
            float4(text_fg.rgb, combined_alpha * in.effective_text_alpha),
            float4(in.decoration_fg, underline_alpha * in.effective_text_alpha));
        text_fg_premul = mix(text_fg_premul, in.cursor_color_premult, cursor_alpha * in.cursor_color_premult.a);

        if (ONLY_FOREGROUND) {
            ans_premul = text_fg_premul;
        } else {
            ans_premul = alpha_blend_premul(text_fg_premul, ans_premul);
        }
    }
    if (SRGB_ENCODE_OUTPUT) {
        // Blend is disabled for the opaque cell draw, so the written
        // premultiplied channels are sRGB-encoded 1:1 here, matching what a
        // BGRA8Unorm_sRGB attachment would do on write. Clamp first (the unorm
        // sRGB ROP clamps to [0,1] before encoding) so pow() never sees a
        // negative operand.
        float3 c = clamp(ans_premul.rgb, 0.0f, 1.0f);
        ans_premul.rgb = float3(linear2srgb(c.r), linear2srgb(c.g), linear2srgb(c.b));
    }
    return ans_premul;
}
