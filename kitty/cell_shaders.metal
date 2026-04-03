/*
 * cell_shaders.metal
 * Copyright (C) 2024 Kovid Goyal <kovid at kovidgoyal.net>
 *
 * Distributed under terms of the GPL3 license.
 *
 * MSL port of cell_vertex.glsl + cell_fragment.glsl + cell_defines.glsl
 * Most complex shader — instanced cell rendering with cursor, selection,
 * decorations, fg override. 3 variants via function constants.
 */

#include <metal_stdlib>
using namespace metal;

// ---- Function constants (replaces GLSL compile-time #defines) ----
constant bool ONLY_FOREGROUND [[function_constant(0)]];
constant bool ONLY_BACKGROUND [[function_constant(1)]];
constant bool DO_FG_OVERRIDE_ENABLED [[function_constant(2)]];
constant int FG_OVERRIDE_ALGO_VAL [[function_constant(3)]];
constant float FG_OVERRIDE_THRESHOLD_VAL [[function_constant(4)]];
constant bool TEXT_NEW_GAMMA_ENABLED [[function_constant(5)]];

// ---- Compile-time constants from CellAttrs bitfield layout (line.h) ----
// CellAttrs: decoration(3):bold(1):italic(1):reverse(1):strike(1):dim(1):blink(1):mark(2)
// These must match the actual bitfield positions in GPUCell.attrs
constant uint DECORATION_SHIFT_C = 0;
constant uint REVERSE_SHIFT_C = 5;
constant uint STRIKE_SHIFT_C = 6;
constant uint DIM_SHIFT_C = 7;
constant uint BLINK_SHIFT_C = 8;
constant uint MARK_SHIFT_C = 9;
constant uint MARK_MASK_VAL = 3;
constant uint DECORATION_MASK_VAL = 7;
constant uint COLOR_NOT_SET_VAL = 0;
constant uint COLOR_IS_SPECIAL_VAL = 1;
constant uint COLOR_IS_INDEX_VAL = 2;
constant uint COLOR_IS_RGB_VAL = 3;
constant uint NUM_COLORS = 256;

// Linear space luminance values
constant float3 Y = float3(0.2126, 0.7152, 0.0722);
constant uint BYTE_MASK = 0xFFu;
constant uint SPRITE_INDEX_MASK = 0x7FFFFFFFu;
constant uint SPRITE_COLORED_MASK = 0x80000000u;
constant uint SPRITE_COLORED_SHIFT = 31u;
constant uint BIT_MASK = 1u;

// ---- Shared utility functions ----

inline float zero_or_one(float x) { return step(1.0f, x); }
inline float if_one_then(float condition, float thenval, float elseval) { return mix(elseval, thenval, condition); }
inline float3 if_one_then(float condition, float3 thenval, float3 elseval) { return mix(elseval, thenval, condition); }
inline float if_less_than(float a, float b, float thenval, float elseval) { return mix(thenval, elseval, step(b, a)); }
inline float3 if_less_than(float a, float b, float3 thenval, float3 elseval) { return mix(thenval, elseval, step(b, a)); }

inline float4 vec4_premul(float3 rgb, float a) { return float4(rgb * a, a); }
inline float4 vec4_premul(float4 rgba) { return float4(rgba.rgb * rgba.a, rgba.a); }

inline float4 alpha_blend(float4 over, float4 under) {
    float alpha = mix(under.a, 1.0f, over.a);
    float3 combined_color = mix(under.rgb * under.a, over.rgb, over.a);
    return float4(combined_color, alpha);
}

inline float4 alpha_blend_premul(float4 over, float4 under) {
    float inv_over_alpha = 1.0f - over.a;
    float alpha = over.a + under.a * inv_over_alpha;
    return float4(over.rgb + under.rgb * inv_over_alpha, alpha);
}

inline float srgb2linear(float x) {
    return mix(x / 12.92f, pow((x + 0.055f) / 1.055f, 2.4f), step(0.04045f, x));
}

inline float linear2srgb(float x) {
    return mix(12.92f * x, 1.055f * pow(x, 1.0f / 2.4f) - 0.055f, step(0.0031308f, x));
}

inline float3 linear2srgb(float3 x) {
    return mix(12.92f * x, 1.055f * pow(x, float3(1.0f / 2.4f)) - 0.055f, step(0.0031308f, x));
}

inline float3 srgb2linear(float3 c) {
    return float3(srgb2linear(c.r), srgb2linear(c.g), srgb2linear(c.b));
}

// ---- CellRenderData uniform buffer ----
// Must match C struct GPUCellRenderData layout exactly (no std140 padding)
struct CellRenderData {
    float use_cell_bg_for_selection_fg;
    float use_cell_fg_for_selection_fg;
    float use_cell_for_selection_bg;
    // NO padding here — C struct has 3 floats followed immediately by uint

    uint default_fg, highlight_fg, highlight_bg, main_cursor_fg;
    uint main_cursor_bg, url_color, url_style, inverted;
    uint extra_cursor_fg, extra_cursor_bg;
    // NO padding — C struct has 10 uints followed by more uints

    uint columns, lines, sprites_xnum, sprites_ynum;
    uint cursor_shape, cell_width, cell_height;
    // NO padding — C struct has 7 uints followed by 4 more uints
    uint cursor_x1, cursor_x2, cursor_y1, cursor_y2;
    float cursor_opacity, inactive_text_alpha, dim_opacity, blink_opacity;

    uint bg_colors0, bg_colors1, bg_colors2, bg_colors3;
    uint bg_colors4, bg_colors5, bg_colors6, bg_colors7;
    float bg_opacities0, bg_opacities1, bg_opacities2, bg_opacities3;
    float bg_opacities4, bg_opacities5, bg_opacities6, bg_opacities7;
};

// Per-draw uniforms
struct CellDrawUniforms {
    uint draw_bg_bitfield;
    float row_offset;
    float text_contrast;
    float text_gamma_adjustment;
};

// ---- Vertex input ----
struct CellVertexIn {
    uint3 colors [[attribute(0)]];       // fg, bg, decoration_fg packed
    uint2 sprite_idx [[attribute(1)]];   // sprite index + text_attrs
    uint is_selected [[attribute(2)]];
};

// ---- Vertex output / Fragment input ----
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
};

// ---- Triangle strip vertex mapping ----
// GLSL GL_TRIANGLE_FAN: 0=(R,T) 1=(R,B) 2=(L,B) 3=(L,T)
// Metal TriangleStrip: 0=(L,B) 1=(R,B) 2=(L,T) 3=(R,T)
// Map: strip[0]=fan[2], strip[1]=fan[1], strip[2]=fan[3], strip[3]=fan[0]
constant uint2 cell_pos_map[4] = {
    uint2(0u, 1u),  // strip 0: left, bottom (fan 2)
    uint2(1u, 1u),  // strip 1: right, bottom (fan 1)
    uint2(0u, 0u),  // strip 2: left, top (fan 3)
    uint2(1u, 0u),  // strip 3: right, top (fan 0)
};

constant uint cursor_shape_map[5] = { 0u, 0u, 2u, 3u, 4u };

// ---- Vertex shader helper functions ----

inline float3 color_to_vec(uint c, constant float *gamma_lut) {
    uint r = (c >> 16) & BYTE_MASK;
    uint g = (c >> 8) & BYTE_MASK;
    uint b = c & BYTE_MASK;
    return float3(gamma_lut[r], gamma_lut[g], gamma_lut[b]);
}

inline uint one_if_equal_zero_otherwise_f(float a, float b) {
    return 1u - uint(zero_or_one(abs(a - b)));
}

inline uint one_if_equal_zero_otherwise(uint a, uint b) {
    return 1u - uint(zero_or_one(abs(float(a) - float(b))));
}

inline uint one_if_equal_zero_otherwise(int a, int b) {
    return 1u - uint(zero_or_one(abs(float(a) - float(b))));
}

inline uint resolve_color(uint c, uint defval, constant uint *color_table) {
    int t = int(c & BYTE_MASK);
    uint is_one = one_if_equal_zero_otherwise(t, (int)1);
    uint is_two = one_if_equal_zero_otherwise(t, (int)2);
    uint is_neither = 1u - is_one - is_two;
    return is_one * color_table[(c >> 8) & BYTE_MASK] + is_two * (c >> 8) + is_neither * defval;
}

inline float3 to_color(uint c, uint defval, constant float *gamma_lut, constant uint *color_table) {
    return color_to_vec(resolve_color(c, defval, color_table), gamma_lut);
}

inline float3 resolve_dynamic_color(uint c, float3 special_val, float3 defval, constant float *gamma_lut, constant uint *color_table) {
    float type = float((c >> 24) & BYTE_MASK);
    float3 rgb_val = color_to_vec(c, gamma_lut);
    float3 idx_val = color_to_vec(color_table[c & BYTE_MASK], gamma_lut);
    return (
        one_if_equal_zero_otherwise_f(type, float(COLOR_IS_RGB_VAL)) * rgb_val +
        one_if_equal_zero_otherwise_f(type, float(COLOR_IS_INDEX_VAL)) * idx_val +
        one_if_equal_zero_otherwise_f(type, float(COLOR_IS_SPECIAL_VAL)) * special_val +
        one_if_equal_zero_otherwise_f(type, float(COLOR_NOT_SET_VAL)) * defval
    );
}

inline float contrast_ratio_f(float under_lum, float over_lum) {
    return clamp((max(under_lum, over_lum) + 0.05f) / (min(under_lum, over_lum) + 0.05f), 1.f, 21.f);
}

inline float contrast_ratio(float3 a, float3 b) {
    return contrast_ratio_f(dot(a, Y), dot(b, Y));
}

inline uint3 to_sprite_coords(uint idx, uint sprites_xnum, uint sprites_ynum) {
    uint sprites_per_page = sprites_xnum * sprites_ynum;
    uint z = idx / sprites_per_page;
    uint on_last = idx - sprites_per_page * z;
    uint y = on_last / sprites_xnum;
    uint x = on_last - sprites_xnum * y;
    return uint3(x, y, z);
}

inline float3 to_sprite_pos(uint2 pos, uint idx, uint sprites_xnum, uint sprites_ynum, uint cell_height) {
    uint3 c = to_sprite_coords(idx, sprites_xnum, sprites_ynum);
    float2 s_xpos = float2(c.x, float(c.x) + 1.0f) * (1.0f / float(sprites_xnum));
    float2 s_ypos = float2(c.y, float(c.y) + 1.0f) * (1.0f / float(sprites_ynum));
    uint texture_height_px = (cell_height + 1u) * sprites_ynum;
    float row_height = 1.0f / float(texture_height_px);
    s_ypos[1] -= row_height; // skip decorations_exclude row
    return float3(s_xpos[pos.x], s_ypos[pos.y], c.z);
}

// ---- HSLuv color space conversion (port of hsluv.glsl) ----
// Used by fg_override algorithm 2 for contrast-preserving color adjustment

inline float hsluv_divide(float num, float denom) {
    return num / (abs(denom) + 1e-15f) * sign(denom);
}

inline float3 hsluv_divide3(float3 num, float3 denom) {
    return num / (abs(denom) + 1e-15f) * sign(denom);
}

inline float3 hsluv_lengthOfRayUntilIntersect(float theta, float3 x, float3 y) {
    float3 len = hsluv_divide3(y, sin(theta) - x * cos(theta));
    return mix(len, float3(1000.0f), step(len, float3(0.0f)));
}

inline float3 hsluv_distanceFromPole(float3 px, float3 py) {
    return sqrt(px*px + py*py);
}

inline float hsluv_maxChromaForLH(float L, float H) {
    float hrad = H * M_PI_F / 180.0f;
    const float3x3 m2 = float3x3(
         3.2409699419045214f, -0.96924363628087983f,  0.055630079696993609f,
        -1.5373831775700935f,  1.8759675015077207f,  -0.20397695888897657f,
        -0.49861076029300328f, 0.041555057407175613f, 1.0569715142428786f
    );
    float sub1 = pow(L + 16.0f, 3.0f) / 1560896.0f;
    float sub2 = mix(L / 903.2962962962963f, sub1, step(0.0088564516790356308f, sub1));
    float3 top1 = (284517.0f * m2[0] - 94839.0f * m2[2]) * sub2;
    float3 bottom = (632260.0f * m2[2] - 126452.0f * m2[1]) * sub2;
    float3 top2 = (838422.0f * m2[2] + 769860.0f * m2[1] + 731718.0f * m2[0]) * L * sub2;
    float3 bound0x = top1 / bottom;
    float3 bound0y = top2 / bottom;
    float3 bound1x = top1 / (bottom + 126452.0f);
    float3 bound1y = (top2 - 769860.0f * L) / (bottom + 126452.0f);
    float3 lengths0 = hsluv_lengthOfRayUntilIntersect(hrad, bound0x, bound0y);
    float3 lengths1 = hsluv_lengthOfRayUntilIntersect(hrad, bound1x, bound1y);
    return min(lengths0.r, min(lengths1.r, min(lengths0.g, min(lengths1.g, min(lengths0.b, lengths1.b)))));
}

inline float3 hsluv_fromLinear(float3 c) {
    return mix(c * 12.92f, 1.055f * pow(max(c, float3(0)), float3(1.0f / 2.4f)) - 0.055f, step(0.0031308f, c));
}

inline float3 hsluv_toLinear(float3 c) {
    return mix(c / 12.92f, pow(max((c + 0.055f) / 1.055f, float3(0)), float3(2.4f)), step(0.04045f, c));
}

inline float hsluv_yToL(float Y_val) {
    return mix(Y_val * 903.2962962962963f, 116.0f * pow(max(Y_val, 0.0f), 1.0f / 3.0f) - 16.0f, step(0.0088564516790356308f, Y_val));
}

inline float hsluv_lToY(float L) {
    return mix(L / 903.2962962962963f, pow((max(L, 0.0f) + 16.0f) / 116.0f, 3.0f), step(8.0f, L));
}

inline float3 xyzToRgb(float3 t) {
    const float3x3 m = float3x3(
         3.2409699419045214f, -1.5373831775700935f, -0.49861076029300328f,
        -0.96924363628087983f, 1.8759675015077207f,  0.041555057407175613f,
         0.055630079696993609f,-0.20397695888897657f, 1.0569715142428786f);
    return hsluv_fromLinear(t * m);
}

inline float3 rgbToXyz(float3 t) {
    const float3x3 m = float3x3(
        0.41239079926595948f,  0.35758433938387796f, 0.18048078840183429f,
        0.21263900587151036f,  0.71516867876775593f, 0.072192315360733715f,
        0.019330818715591851f, 0.11919477979462599f, 0.95053215224966058f);
    return hsluv_toLinear(t) * m;
}

inline float3 xyzToLuv(float3 t) {
    float X = t.x, Y_val = t.y, Z = t.z;
    float L = hsluv_yToL(Y_val);
    float d = 1.0f / max(dot(t, float3(1, 15, 3)), 1e-15f);
    return float3(1.0f, 52.0f * (X * d) - 2.57179f, 117.0f * (Y_val * d) - 6.08816f) * L;
}

inline float3 luvToXyz(float3 t) {
    float L = t.x;
    float U = hsluv_divide(t.y, 13.0f * L) + 0.19783000664283681f;
    float V = hsluv_divide(t.z, 13.0f * L) + 0.468319994938791f;
    float Y_val = hsluv_lToY(L);
    float X = 2.25f * U * Y_val / V;
    float Z = (3.0f / V - 5.0f) * Y_val - (X / 3.0f);
    return float3(X, Y_val, Z);
}

inline float3 luvToLch(float3 t) {
    float C = length(t.yz);
    float H = atan2(t.z, t.y) * 180.0f / M_PI_F;
    H += 360.0f * step(H, 0.0f);
    return float3(t.x, C, H);
}

inline float3 lchToLuv(float3 t) {
    float hrad = t.b * M_PI_F / 180.0f;
    return float3(t.r, cos(hrad) * t.g, sin(hrad) * t.g);
}

inline float3 hsluvToLch(float3 t) {
    float3 r = t;
    r.g *= hsluv_maxChromaForLH(t.b, t.r) * 0.01f;
    return r.bgr;
}

inline float3 hsluvToRgb(float3 t) {
    return xyzToRgb(luvToXyz(lchToLuv(hsluvToLch(t))));
}

inline float3 lchToHsluv(float3 t) {
    float3 r = t;
    r.g = hsluv_divide(t.g, hsluv_maxChromaForLH(t.r, t.b) * 0.01f);
    return r.bgr;
}

inline float3 rgbToHsluv(float3 t) {
    return lchToHsluv(luvToLch(xyzToLuv(rgbToXyz(t))));
}

// ---- Foreground override functions ----

inline float3 fg_override_algo1(float under_lum, float over_lum, float3 under, float3 over, float threshold, float colored) {
    float diff = abs(under_lum - over_lum);
    float override_level = (1.0f - colored) * step(diff, threshold);
    float original_level = 1.0f - override_level;
    return original_level * over + override_level * float3(step(under_lum, 0.5f));
}

inline float3 fg_override_algo2(float under_lum, float over_lum, float3 under, float3 over, float min_cr) {
    float ratio = contrast_ratio_f(under_lum, over_lum);
    float3 diff = abs(under - over);
    float3 over_hsluv = rgbToHsluv(over);
    float target_lum_a = clamp((under_lum + 0.05f) * min_cr - 0.05f, 0.0f, 1.0f);
    float target_lum_b = clamp((under_lum + 0.05f) / min_cr - 0.05f, 0.0f, 1.0f);
    float3 result_a = clamp(hsluvToRgb(float3(over_hsluv.x, over_hsluv.y, target_lum_a * 100.0f)), 0.0f, 1.0f);
    float3 result_b = clamp(hsluvToRgb(float3(over_hsluv.x, over_hsluv.y, target_lum_b * 100.0f)), 0.0f, 1.0f);
    float ratio_a = contrast_ratio_f(under_lum, dot(result_a, Y));
    float ratio_b = contrast_ratio_f(under_lum, dot(result_b, Y));
    float3 result = mix(result_a, result_b, step(ratio_a, ratio_b));
    return mix(result, over, max(step(diff.r + diff.g + diff.b, 0.001f), step(min_cr, ratio)));
}

inline float3 override_foreground_color(float3 over, float3 under, float threshold, int algo, float colored) {
    float under_lum = dot(under, Y);
    float over_lum = dot(over, Y);
    if (algo == 1) {
        return fg_override_algo1(under_lum, over_lum, under, over, threshold, colored);
    } else {
        return fg_override_algo2(under_lum, over_lum, under, over, threshold);
    }
}

inline float background_opacity_for(uint bg, uint colorval, float opacity_if_matched) {
    float not_matched = step(1.f, abs(float(colorval) - float(bg)));
    return not_matched + opacity_if_matched * (1.f - not_matched);
}

// ---- Cell Vertex Shader ----
vertex CellVertexOut cell_vertex(
    CellVertexIn in [[stage_in]],
    uint vid [[vertex_id]],
    uint iid [[instance_id]],
    constant CellRenderData& rd [[buffer(1)]],
    constant CellDrawUniforms& du [[buffer(2)]],
    constant float *gamma_lut [[buffer(3)]],
    constant uint *color_table [[buffer(4)]],
    texture2d<uint, access::read> sprite_decorations_map [[texture(2)]]
) {
    CellVertexOut out;

    uint columns = rd.columns;
    uint lines = rd.lines;
    float dx = 2.0f / float(columns);
    float dy = 2.0f / float(lines);
    uint row = iid / columns;
    uint column = iid - row * columns;

    float left = -1.0f + float(column) * dx;
    float top = 1.0f - (float(row) + du.row_offset) * dy;
    uint2 pos = cell_pos_map[vid];
    float px = select(left, left + dx, pos.x == 1u);
    float py = select(top, top - dy, pos.y == 1u);
    out.position = float4(px, py, 0, 1);

    // Resolve colors
    uint2 default_colors = uint2(rd.default_fg, rd.bg_colors0);
    uint text_attrs = in.sprite_idx[1];
    uint is_reversed = (text_attrs >> REVERSE_SHIFT_C) & BIT_MASK;
    uint is_inverted = is_reversed + rd.inverted;
    const int fg_index_map[3] = {0, 1, 0};
    int fg_index = fg_index_map[is_inverted];
    int bg_index = 1 - fg_index;

    int mark = int(text_attrs >> MARK_SHIFT_C) & int(MARK_MASK_VAL);
    uint has_mark = uint(step(1.0f, float(mark)));
    uint bg_as_uint = resolve_color(in.colors[bg_index], default_colors[bg_index], color_table);
    bg_as_uint = has_mark * color_table[NUM_COLORS + uint(mark) - 1u] + (BIT_MASK - has_mark) * bg_as_uint;
    float cell_has_default_bg = 1.f - step(1.f, abs(float(bg_as_uint) - float(rd.bg_colors0)));
    float3 bg = color_to_vec(bg_as_uint, gamma_lut);

    uint fg_as_uint = resolve_color(in.colors[fg_index], default_colors[fg_index], color_table);
    fg_as_uint = has_mark * color_table[NUM_COLORS + MARK_MASK_VAL + uint(mark)] + (1u - has_mark) * fg_as_uint;
    float3 foreground = color_to_vec(fg_as_uint, gamma_lut);

    // Cursor
    uint clamped_x = clamp(column, rd.cursor_x1, rd.cursor_x2);
    uint clamped_y = clamp(row, rd.cursor_y1, rd.cursor_y2);
    float has_main_cursor = float(one_if_equal_zero_otherwise(column, clamped_x) * one_if_equal_zero_otherwise(row, clamped_y));

    float multicursor_shape = float((in.is_selected >> 2) & 3u);
    float multicursor_uses_main = float((in.is_selected >> 4) & BIT_MASK);
    multicursor_shape = if_one_then(multicursor_uses_main, float(rd.cursor_shape), multicursor_shape);
    float final_cursor_shape = if_one_then(has_main_cursor, float(rd.cursor_shape), multicursor_shape);
    float has_cursor = zero_or_one(final_cursor_shape);
    float is_block_cursor = has_cursor * float(one_if_equal_zero_otherwise_f(final_cursor_shape, 1.0f));

    float3 main_cursor_bg_color = color_to_vec(rd.main_cursor_bg, gamma_lut);
    float3 main_cursor_fg_color = color_to_vec(rd.main_cursor_fg, gamma_lut);

    // Sprite position
    if (!ONLY_BACKGROUND) {
        out.sprite_pos = to_sprite_pos(pos, in.sprite_idx[0] & SPRITE_INDEX_MASK, rd.sprites_xnum, rd.sprites_ynum, rd.cell_height);
        out.colored_sprite = float((in.sprite_idx[0] & SPRITE_COLORED_MASK) >> SPRITE_COLORED_SHIFT);

        // Text alpha
        float has_dim = float((text_attrs >> DIM_SHIFT_C) & BIT_MASK);
        float has_blink = float((text_attrs >> BLINK_SHIFT_C) & BIT_MASK);
        out.effective_text_alpha = rd.inactive_text_alpha * if_one_then(has_dim, rd.dim_opacity, 1.0f) * if_one_then(has_blink, rd.blink_opacity, 1.0f);

        // Decorations
        float in_url = float((in.is_selected >> 1) & BIT_MASK);
        out.decoration_fg = if_one_then(in_url, color_to_vec(rd.url_color, gamma_lut),
            to_color(in.colors[2], fg_as_uint, gamma_lut, color_table));

        // Selection
        float3 selection_color = if_one_then(rd.use_cell_bg_for_selection_fg, bg, color_to_vec(rd.highlight_fg, gamma_lut));
        selection_color = if_one_then(rd.use_cell_fg_for_selection_fg, foreground, selection_color);
        foreground = if_one_then(float(in.is_selected & BIT_MASK), selection_color, foreground);
        out.decoration_fg = if_one_then(float(in.is_selected & BIT_MASK), selection_color, out.decoration_fg);

        // Decorations sprite positions
        uint sprite_idx_0 = in.sprite_idx[0] & SPRITE_INDEX_MASK;
        int2 dm_sz = int2(sprite_decorations_map.get_width(), sprite_decorations_map.get_height());
        int dm_y = int(sprite_idx_0) / dm_sz[0];
        int dm_x = int(sprite_idx_0) - dm_y * dm_sz[0];
        uint decorations_idx = sprite_decorations_map.read(uint2(dm_x, dm_y)).r;

        uint has_decorations = uint(zero_or_one(float(decorations_idx)));
        uint strike_style = (text_attrs >> STRIKE_SHIFT_C) & BIT_MASK;
        uint strike_idx = decorations_idx * strike_style;
        uint underline_style = (text_attrs >> DECORATION_SHIFT_C) & DECORATION_MASK_VAL;
        underline_style = uint(in_url) * rd.url_style + (1u - uint(in_url)) * underline_style;
        uint has_underline = uint(step(0.5f, float(underline_style)));
        uint2 decs = has_decorations * uint2(strike_idx, has_underline * (decorations_idx + underline_style));

        out.strike_pos = to_sprite_pos(pos, decs[0], rd.sprites_xnum, rd.sprites_ynum, rd.cell_height);
        out.underline_pos = to_sprite_pos(pos, decs[1], rd.sprites_xnum, rd.sprites_ynum, rd.cell_height);

        // Underline exclusion pos
        uint3 exc_coords = to_sprite_coords(sprite_idx_0, rd.sprites_xnum, rd.sprites_ynum);
        out.underline_exclusion_pos = exc_coords.y * (rd.cell_height + 1u) + rd.cell_height;

        // Cursor
        out.cursor_color_premult = float4(main_cursor_bg_color * rd.cursor_opacity, rd.cursor_opacity);
        float3 final_cursor_text_color = mix(foreground, main_cursor_fg_color, rd.cursor_opacity);
        foreground = if_one_then(is_block_cursor, final_cursor_text_color, foreground);
        out.decoration_fg = if_one_then(is_block_cursor, final_cursor_text_color, out.decoration_fg);
        uint cursor_fg_sprite_idx = cursor_shape_map[int(final_cursor_shape)];
        out.cursor_pos = to_sprite_pos(pos, cursor_fg_sprite_idx * uint(has_cursor), rd.sprites_xnum, rd.sprites_ynum, rd.cell_height);

        out.cell_foreground = foreground;
    }

    // Background
    float bg_alpha = (
        background_opacity_for(bg_as_uint, rd.bg_colors0, rd.bg_opacities0) *
        background_opacity_for(bg_as_uint, rd.bg_colors1, rd.bg_opacities1) *
        background_opacity_for(bg_as_uint, rd.bg_colors2, rd.bg_opacities2) *
        background_opacity_for(bg_as_uint, rd.bg_colors3, rd.bg_opacities3) *
        background_opacity_for(bg_as_uint, rd.bg_colors4, rd.bg_opacities4) *
        background_opacity_for(bg_as_uint, rd.bg_colors5, rd.bg_opacities5) *
        background_opacity_for(bg_as_uint, rd.bg_colors6, rd.bg_opacities6) *
        background_opacity_for(bg_as_uint, rd.bg_colors7, rd.bg_opacities7)
    );

    float effective_cursor_opacity = max(rd.cursor_opacity, bg_alpha);
    float is_special_cell = is_block_cursor + float(in.is_selected & BIT_MASK) + float(is_reversed);
    is_special_cell = zero_or_one(is_special_cell);
    cell_has_default_bg = if_one_then(is_special_cell, 0.f, cell_has_default_bg);
    bg_alpha = if_one_then(is_special_cell, 1.f, bg_alpha);
    bg_alpha = if_one_then(is_block_cursor, effective_cursor_opacity, bg_alpha);
    float3 sel_bg = if_one_then(rd.use_cell_for_selection_bg,
        color_to_vec(fg_as_uint, gamma_lut), color_to_vec(rd.highlight_bg, gamma_lut));
    bg = if_one_then(float(in.is_selected & BIT_MASK), sel_bg, bg);
    float3 background_rgb = if_one_then(is_block_cursor, mix(bg, main_cursor_bg_color, rd.cursor_opacity), bg);
    out.background = background_rgb;

    // Foreground color override for contrast requirements (after background is known)
    if (DO_FG_OVERRIDE_ENABLED && !ONLY_BACKGROUND) {
        out.decoration_fg = override_foreground_color(out.decoration_fg, background_rgb, FG_OVERRIDE_THRESHOLD_VAL, FG_OVERRIDE_ALGO_VAL, out.colored_sprite);
        out.cell_foreground = override_foreground_color(out.cell_foreground, background_rgb, FG_OVERRIDE_THRESHOLD_VAL, FG_OVERRIDE_ALGO_VAL, out.colored_sprite);
    }

    if (!ONLY_FOREGROUND) {
        float4 bgpremul = vec4_premul(background_rgb, bg_alpha);
        float cell_has_non_default_bg = 1.f - cell_has_default_bg;
        uint draw_bg_mask = uint(2.f * cell_has_non_default_bg + cell_has_default_bg);
        float draw_bg = step(0.5f, float(du.draw_bg_bitfield & draw_bg_mask));
        bgpremul *= draw_bg;
        out.effective_background_premul = bgpremul;
    }

    return out;
}

// ---- Cell Fragment Shader ----
fragment float4 cell_fragment(
    CellVertexOut in [[stage_in]],
    constant CellDrawUniforms& du [[buffer(2)]],
    texture2d_array<float> sprites [[texture(0)]]
) {
    // DEBUG: show sprite RGB (ignoring alpha) to detect byte-swap issues
    {
        constexpr sampler ss(mag_filter::nearest, min_filter::nearest, coord::normalized);
        float4 spr = sprites.sample(ss, in.sprite_pos.xy, uint(in.sprite_pos.z));
        // Show max of all channels - if ANY channel has data, we'll see it
        float v = max(max(spr.r, spr.g), max(spr.b, spr.a));
        return float4(spr.r, spr.g, spr.b, 1.0); // Show RGB directly
    }

    float4 ans_premul;

    if (!ONLY_FOREGROUND) {
        ans_premul = in.effective_background_premul;
    }

    if (!ONLY_BACKGROUND) {
        constexpr sampler sprite_sampler(mag_filter::nearest, min_filter::nearest, coord::normalized);

        // Load text foreground
        float4 text_fg = sprites.sample(sprite_sampler, in.sprite_pos.xy, uint(in.sprite_pos.z));
        text_fg = float4(mix(in.cell_foreground, text_fg.rgb, in.colored_sprite), text_fg.a);

        // Contrast adjustment
        float under_luminance = dot(in.background, Y);
        float over_luminance = dot(text_fg.rgb, Y);
        if (TEXT_NEW_GAMMA_ENABLED) {
            text_fg.a = clamp(mix(text_fg.a, pow(text_fg.a, du.text_gamma_adjustment),
                (1.0f - over_luminance + under_luminance) * 0.5f) * du.text_contrast, 0.0f, 1.0f);
        } else {
            float srgb_over = linear2srgb(over_luminance);
            float srgb_under = linear2srgb(under_luminance);
            text_fg.a = clamp((srgb2linear(srgb_over * text_fg.a + srgb_under * (1.0f - text_fg.a)) - under_luminance) /
                (over_luminance - under_luminance + 1e-10f), 0.0f, 1.0f);
        }

        // Decorations
        int3 sz = int3(sprites.get_width(), sprites.get_height(), sprites.get_array_size());
        float underline_alpha = sprites.sample(sprite_sampler, in.underline_pos.xy, uint(in.underline_pos.z)).a;
        float underline_exclusion = sprites.read(uint2(uint(in.sprite_pos.x * float(sz.x)),
            in.underline_exclusion_pos), uint(in.sprite_pos.z)).a;
        underline_alpha *= 1.0f - underline_exclusion;
        float strike_alpha = sprites.sample(sprite_sampler, in.strike_pos.xy, uint(in.strike_pos.z)).a;
        float cursor_alpha = sprites.sample(sprite_sampler, in.cursor_pos.xy, uint(in.cursor_pos.z)).a;

        float combined_alpha = min(text_fg.a + strike_alpha, 1.0f);
        float4 fg_premul = alpha_blend(
            float4(text_fg.rgb, combined_alpha * in.effective_text_alpha),
            float4(in.decoration_fg, underline_alpha * in.effective_text_alpha));
        fg_premul = mix(fg_premul, in.cursor_color_premult, cursor_alpha * in.cursor_color_premult.a);

        if (ONLY_FOREGROUND) {
            ans_premul = fg_premul;
        } else {
            ans_premul = alpha_blend_premul(fg_premul, ans_premul);
        }
    }

    return ans_premul;
}
