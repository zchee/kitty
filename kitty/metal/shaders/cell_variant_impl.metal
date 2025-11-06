#ifndef KITTY_METAL_CELL_COMMON_DEFINED
#include <metal_stdlib>
using namespace metal;
#endif

#include "../../metal_text_shared.h"

namespace kitty::metal {

#ifndef KITTY_METAL_CELL_COMMON_DEFINED
#define KITTY_METAL_CELL_COMMON_DEFINED

namespace detail {

constant int FG_INDEX_MAP[3] = {0, 1, 0};

struct ColorPair {
    float3 bg;
    float3 fg;
};

struct CellData {
    float has_cursor;
    float has_block_cursor;
    uint2 pos;
    uint cursor_fg_sprite_idx;
    ColorPair cursor;
};

inline float zero_or_one(float x) {
    return step(1.0f, x);
}

inline float if_one_then(float condition, float thenval, float elseval) {
    return mix(elseval, thenval, condition);
}

inline float3 if_one_then(float condition, float3 thenval, float3 elseval) {
    return mix(elseval, thenval, condition);
}

inline float if_less_than(float a, float b, float thenval, float elseval) {
    return mix(thenval, elseval, step(b, a));
}

inline float3 if_less_than(float a, float b, float3 thenval, float3 elseval) {
    return mix(thenval, elseval, step(b, a));
}

inline uint one_if_equal_zero_otherwise(float a, float b) {
    return 1u - uint(zero_or_one(fabs(a - b)));
}

inline uint one_if_equal_zero_otherwise(int a, int b) {
    return 1u - uint(zero_or_one(fabs(float(a - b))));
}

inline uint one_if_equal_zero_otherwise(uint a, uint b) {
    return 1u - uint(zero_or_one(fabs(float(int(a) - int(b)))));
}

inline float srgb_lookup(const constant KittyCellUniforms& uniforms, uint index) {
    return uniforms.gamma_lut[index & KITTY_BYTE_MASK];
}

inline float3 color_to_vec(const constant KittyCellUniforms& uniforms, uint c) {
    uint r = (c >> 16u) & KITTY_BYTE_MASK;
    uint g = (c >> 8u) & KITTY_BYTE_MASK;
    uint b = c & KITTY_BYTE_MASK;
    return float3(srgb_lookup(uniforms, r), srgb_lookup(uniforms, g), srgb_lookup(uniforms, b));
}

inline uint resolve_color(const constant KittyCellUniforms& uniforms, uint c, uint defval) {
    int t = int(c & KITTY_BYTE_MASK);
    uint is_one = one_if_equal_zero_otherwise(t, 1);
    uint is_two = one_if_equal_zero_otherwise(t, 2);
    uint is_neither = 1u - is_one - is_two;
    uint table_idx = (c >> 8u) & KITTY_BYTE_MASK;
    uint from_table = uniforms.color_table[table_idx];
    uint direct = (c >> 8u);
    return is_one * from_table + is_two * direct + is_neither * defval;
}

inline float3 to_color(const constant KittyCellUniforms& uniforms, uint c, uint defval) {
    return color_to_vec(uniforms, resolve_color(uniforms, c, defval));
}

inline float3 resolve_dynamic_color(const constant KittyCellUniforms& uniforms,
                                    uint c,
                                    float3 special_val,
                                    float3 defval) {
    float type = float((c >> 24u) & KITTY_BYTE_MASK);
    float3 ans = float3(0.0f);
    ans += float(one_if_equal_zero_otherwise(type, float(KITTY_COLOR_IS_RGB))) * color_to_vec(uniforms, c);
    ans += float(one_if_equal_zero_otherwise(type, float(KITTY_COLOR_IS_INDEX))) *
           color_to_vec(uniforms, uniforms.color_table[c & KITTY_BYTE_MASK]);
    ans += float(one_if_equal_zero_otherwise(type, float(KITTY_COLOR_IS_SPECIAL))) * special_val;
    ans += float(one_if_equal_zero_otherwise(type, float(KITTY_COLOR_NOT_SET))) * defval;
    return ans;
}

inline float contrast_ratio(float under_luminance, float over_luminance) {
    return clamp((max(under_luminance, over_luminance) + 0.05f) /
                 (min(under_luminance, over_luminance) + 0.05f), 1.0f, 21.0f);
}

inline float contrast_ratio(float3 a, float3 b) {
    constexpr float3 Y = float3(0.2126f, 0.7152f, 0.0722f);
    return contrast_ratio(dot(a, Y), dot(b, Y));
}

inline ColorPair if_less_than_pair(float a, float b, ColorPair thenval, ColorPair elseval) {
    return ColorPair {
        if_less_than(a, b, thenval.bg, elseval.bg),
        if_less_than(a, b, thenval.fg, elseval.fg)
    };
}

inline ColorPair if_one_then_pair(float condition, ColorPair thenval, ColorPair elseval) {
    return ColorPair {
        if_one_then(condition, thenval.bg, elseval.bg),
        if_one_then(condition, thenval.fg, elseval.fg)
    };
}

inline ColorPair resolve_extra_cursor_colors_for_special_cursor(float3 cell_bg,
                                                                float3 cell_fg,
                                                                const constant KittyCellUniforms& uniforms) {
    ColorPair cell = { cell_fg, cell_bg };
    ColorPair base = { color_to_vec(uniforms, uniforms.default_fg),
                       color_to_vec(uniforms, uniforms.bg_colors[0]) };
    float cr = contrast_ratio(cell.fg, cell.bg);
    float br = contrast_ratio(base.fg, base.bg);
    ColorPair higher = if_less_than_pair(cr, br, base, cell);
    return if_less_than_pair(cr, 2.5f, higher, cell);
}

inline ColorPair resolve_extra_cursor_colors(float3 cell_bg,
                                             float3 cell_fg,
                                             ColorPair main_cursor,
                                             const constant KittyCellUniforms& uniforms) {
    ColorPair ans = {
        resolve_dynamic_color(uniforms, uniforms.extra_cursor_bg, main_cursor.bg, main_cursor.bg),
        resolve_dynamic_color(uniforms, uniforms.extra_cursor_fg, cell_bg, main_cursor.fg)
    };
    float type_is_special = float(one_if_equal_zero_otherwise(
        int((uniforms.extra_cursor_bg >> 24u) & KITTY_BYTE_MASK), int(KITTY_COLOR_IS_SPECIAL)));
    ColorPair special = resolve_extra_cursor_colors_for_special_cursor(cell_bg, cell_fg, uniforms);
    return if_one_then_pair(type_is_special, ans, special);
}

inline uint3 to_sprite_coords(const constant KittyCellUniforms& uniforms, uint idx) {
    uint sprites_per_page = uniforms.sprites_xnum * uniforms.sprites_ynum;
    uint z = idx / sprites_per_page;
    uint num_on_last_page = idx - sprites_per_page * z;
    uint y = num_on_last_page / uniforms.sprites_xnum;
    uint x = num_on_last_page - uniforms.sprites_xnum * y;
    return uint3(x, y, z);
}

inline float3 to_sprite_pos(const constant KittyCellUniforms& uniforms, uint2 pos, uint idx) {
    uint3 coord = to_sprite_coords(uniforms, idx);
    float2 s_xpos = float2(float(coord.x), float(coord.x + 1u)) *
                    (1.0f / float(uniforms.sprites_xnum));
    float2 s_ypos = float2(float(coord.y), float(coord.y + 1u)) *
                    (1.0f / float(uniforms.sprites_ynum));
    uint texture_height_px = (uniforms.cell_height + 1u) * uniforms.sprites_ynum;
    float row_height = 1.0f / float(texture_height_px);
    s_ypos.y -= row_height;
    return float3(s_xpos[pos.x], s_ypos[pos.y], float(coord.z));
}

inline uint to_underline_exclusion_pos(const constant KittyCellUniforms& uniforms, uint sprite_idx) {
    uint3 coord = to_sprite_coords(uniforms, sprite_idx & KITTY_SPRITE_INDEX_MASK);
    uint cell_top_px = coord.y * (uniforms.cell_height + 1u);
    return cell_top_px + uniforms.cell_height;
}

inline uint read_sprite_decorations_idx(texture2d<uint> decorations_map,
                                        sampler decorations_sampler,
                                        uint sprite_idx) {
    uint idx = sprite_idx & KITTY_SPRITE_INDEX_MASK;
    uint width = decorations_map.get_width();
    uint y = idx / width;
    uint x = idx - y * width;
    return decorations_map.read(uint2(x, y), 0).r;
}

inline uint2 get_decorations_indices(texture2d<uint> decorations_map,
                                     sampler decorations_sampler,
                                     bool in_url,
                                     uint text_attrs,
                                     const constant KittyCellUniforms& uniforms,
                                     uint sprite_idx) {
    uint decorations_idx = read_sprite_decorations_idx(decorations_map, decorations_sampler, sprite_idx);
    uint strike_style = (text_attrs >> KITTY_STRIKE_SHIFT) & KITTY_BIT_MASK;
    uint strike_idx = decorations_idx * strike_style;
    uint underline_style = (text_attrs >> KITTY_DECORATION_SHIFT) & ((1u << 3u) - 1u);
    underline_style = in_url ? uniforms.url_style : underline_style;
    uint has_underline = uint(step(0.5f, float(underline_style)));
    return uint2(strike_idx, has_underline ? (decorations_idx + underline_style) : 0u);
}

inline uint is_cursor(uint x, uint y, const constant KittyCellUniforms& uniforms) {
    uint clamped_x = clamp(x, uniforms.cursor_x1, uniforms.cursor_x2);
    uint clamped_y = clamp(y, uniforms.cursor_y1, uniforms.cursor_y2);
    return one_if_equal_zero_otherwise(x, clamped_x) *
           one_if_equal_zero_otherwise(y, clamped_y);
}

inline float background_opacity_for(uint bg, uint colorval, float opacity_if_matched) {
    float not_matched = step(1.0f, fabs(float(int(colorval) - int(bg))));
    return not_matched + opacity_if_matched * (1.0f - not_matched);
}

inline float calc_background_opacity(uint bg, const constant KittyCellUniforms& uniforms) {
    float ans = 1.0f;
    for (uint i = 0; i < KITTY_NUM_BG_SLOTS; i++) {
        ans *= background_opacity_for(bg, uniforms.bg_colors[i], uniforms.bg_opacities[i]);
    }
    return ans;
}

inline CellData compute_cell_data(uint vertex_id,
                                  uint instance_id,
                                  const constant KittyCellUniforms& uniforms,
                                  uint is_selected_mask,
                                  uint sprite_idx,
                                  float3 cell_fg,
                                  float3 cell_bg) {
    float dx = 2.0f / float(uniforms.columns);
    float dy = 2.0f / float(uniforms.lines);
    uint row = instance_id / uniforms.columns;
    uint column = instance_id - row * uniforms.columns;
    constexpr uint2 cell_pos_map[4] = {
        uint2(1u, 0u),
        uint2(1u, 1u),
        uint2(0u, 1u),
        uint2(0u, 0u)
    };
    uint2 pos = cell_pos_map[vertex_id & 3u];
    float left = -1.0f + float(column) * dx;
    float top = 1.0f - float(row) * dy;
    (void)left;
    (void)top;
    float has_main_cursor = float(is_cursor(column, row, uniforms));
    float multicursor_shape = float((is_selected_mask >> 2) & 3u);
    float multicursor_uses_main_cursor_shape = float((is_selected_mask >> 4) & KITTY_BIT_MASK);
    multicursor_shape = if_one_then(multicursor_uses_main_cursor_shape, float(uniforms.cursor_shape), multicursor_shape);
    float final_cursor_shape = if_one_then(has_main_cursor, float(uniforms.cursor_shape), multicursor_shape);
    float has_cursor = zero_or_one(final_cursor_shape);
    float is_block_cursor = has_cursor * float(one_if_equal_zero_otherwise(final_cursor_shape, 1.0f));

    ColorPair main_cursor = {
        color_to_vec(uniforms, uniforms.main_cursor_bg),
        color_to_vec(uniforms, uniforms.main_cursor_fg)
    };
    ColorPair extra_cursor = resolve_extra_cursor_colors(cell_bg, cell_fg, main_cursor, uniforms);
    ColorPair cursor = if_one_then_pair(has_main_cursor, main_cursor, extra_cursor);

    constexpr uint cursor_shape_map[5] = { 0u, 0u, 2u, 3u, 4u };
    uint cursor_fg_sprite_idx = cursor_shape_map[min(4u, uint(final_cursor_shape))];

    return CellData { has_cursor, is_block_cursor, pos, cursor_fg_sprite_idx, cursor };
}

inline float4 vec4_premul(float3 rgb, float a) {
    return float4(rgb * a, a);
}

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

inline float4 alpha_blend_premul(float4 over, float3 under) {
    float inv_over_alpha = 1.0f - over.a;
    return float4(over.rgb + under * inv_over_alpha, 1.0f);
}

} // namespace detail

#endif // KITTY_METAL_CELL_COMMON_DEFINED

#ifdef CELL_VARIANT_SUFFIX

namespace detail {

#if !defined(ONLY_BACKGROUND)
#define CELL_NEEDS_FOREGROUND 1
#else
#define CELL_NEEDS_FOREGROUND 0
#endif

#if !defined(ONLY_FOREGROUND)
#define CELL_NEEDS_BACKGROUND 1
#else
#define CELL_NEEDS_BACKGROUND 0
#endif

#define CAT2(a, b) a##b
#define CAT(a, b) CAT2(a, b)
#define CELL_VERTEX_NAME(name) CAT(name, CAT(_, CELL_VARIANT_SUFFIX))
#define CELL_FRAGMENT_NAME(name) CAT(name, CAT(_, CELL_VARIANT_SUFFIX))
#define CELL_VARYINGS_STRUCT CAT(CellVaryings_, CELL_VARIANT_SUFFIX)

#if defined(ONLY_BACKGROUND)
struct CELL_VARYINGS_STRUCT {
    float4 position [[position]];
    float3 background;
    float4 effective_background_premul;
};
#elif defined(ONLY_FOREGROUND)
struct CELL_VARYINGS_STRUCT {
    float4 position [[position]];
    float3 sprite_pos;
    float3 underline_pos;
    float3 cursor_pos;
    float3 strike_pos;
    uint underline_exclusion_pos [[flat]];
    float3 cell_foreground;
    float4 cursor_color_premult;
    float3 decoration_fg;
    float colored_sprite;
    float effective_text_alpha;
};
#else
struct CELL_VARYINGS_STRUCT {
    float4 position [[position]];
    float3 background;
    float4 effective_background_premul;
    float3 sprite_pos;
    float3 underline_pos;
    float3 cursor_pos;
    float3 strike_pos;
    uint underline_exclusion_pos [[flat]];
    float3 cell_foreground;
    float4 cursor_color_premult;
    float3 decoration_fg;
    float colored_sprite;
    float effective_text_alpha;
};
#endif

} // namespace detail

#undef CELL_NEEDS_FOREGROUND
#undef CELL_NEEDS_BACKGROUND

vertex detail::CELL_VARYINGS_STRUCT CELL_VERTEX_NAME(cell_vertex)(
    uint vertex_id [[vertex_id]],
    uint instance_id [[instance_id]],
    const device KittyGPUCell* gpu_cells [[buffer(0)]],
    const device uint8_t* selection_buffer [[buffer(1)]],
    constant KittyCellUniforms& uniforms [[buffer(2)]],
    texture2d<uint> decorations_map [[texture(1)]],
    sampler decorations_sampler [[sampler(1)]]
) {
    detail::CELL_VARYINGS_STRUCT out = {};

    KittyGPUCell cell = gpu_cells[instance_id];
    uint is_selected = uint(selection_buffer[instance_id]);
    uint text_attrs = cell.attrs;

    uint default_fg = uniforms.default_fg;
    uint default_bg = uniforms.bg_colors[0];

    uint is_reversed = (text_attrs >> KITTY_REVERSE_SHIFT) & KITTY_BIT_MASK;
    uint is_inverted = is_reversed + uniforms.inverted;
    int fg_index = detail::FG_INDEX_MAP[min(2u, is_inverted)];
    int bg_index = 1 - fg_index;

    uint2 default_colors = uint2(default_fg, default_bg);
    uint colors_arr[3] = { cell.fg, cell.bg, cell.decoration_fg };

    uint bg_as_uint = detail::resolve_color(uniforms, colors_arr[bg_index], default_colors[bg_index]);
    uint mark = (text_attrs >> KITTY_MARK_SHIFT) & KITTY_MARK_MASK;
    float has_mark = step(1.0f, float(mark));
    if (has_mark > 0.5f && mark > 0u) {
        bg_as_uint = uniforms.color_table[KITTY_NUM_COLORS + mark - 1u];
    }
    float cell_has_default_bg = 1.0f - step(1.0f, fabs(float(int(bg_as_uint) - int(default_bg))));
    float3 bg = detail::color_to_vec(uniforms, bg_as_uint);

    uint fg_as_uint = detail::resolve_color(uniforms, colors_arr[fg_index], default_colors[fg_index]);
    if (has_mark > 0.5f) {
        fg_as_uint = uniforms.color_table[KITTY_NUM_COLORS + KITTY_MARK_MASK + mark];
    }
#if CELL_NEEDS_FOREGROUND
    float3 foreground = detail::color_to_vec(uniforms, fg_as_uint);
#endif

    float dx = 2.0f / float(uniforms.columns);
    float dy = 2.0f / float(uniforms.lines);
    uint row = instance_id / uniforms.columns;
    uint column = instance_id - row * uniforms.columns;
    float left = -1.0f + float(column) * dx;
    float top = 1.0f - float(row) * dy;
    constexpr uint2 cell_pos_map_arr[4] = {
        uint2(1u, 0u),
        uint2(1u, 1u),
        uint2(0u, 1u),
        uint2(0u, 0u)
    };
    uint2 pos = cell_pos_map_arr[vertex_id & 3u];
    float x = mix(left, left + dx, float(pos.x));
    float y = mix(top, top - dy, float(pos.y));
    out.position = float4(x, y, 0.0f, 1.0f);

#if CELL_NEEDS_FOREGROUND
    detail::CellData cell_data = detail::compute_cell_data(vertex_id, instance_id, uniforms,
                                           is_selected, cell.sprite_idx, foreground, bg);
#endif

#if CELL_NEEDS_FOREGROUND
    out.sprite_pos = detail::to_sprite_pos(uniforms, pos, cell.sprite_idx & KITTY_SPRITE_INDEX_MASK);
    out.colored_sprite = float((cell.sprite_idx & KITTY_SPRITE_COLORED_MASK) >> KITTY_SPRITE_COLORED_SHIFT);
#endif

#if CELL_NEEDS_FOREGROUND
    float has_dim = float((text_attrs >> KITTY_DIM_SHIFT) & KITTY_BIT_MASK);
    float has_blink = float((text_attrs >> KITTY_BLINK_SHIFT) & KITTY_BIT_MASK);
    out.effective_text_alpha = uniforms.inactive_text_alpha *
        detail::if_one_then(has_dim, uniforms.dim_opacity, 1.0f) *
        detail::if_one_then(has_blink, uniforms.blink_opacity, 1.0f);

    float in_url = float((is_selected >> 1u) & KITTY_BIT_MASK);
    float3 decoration_fg = detail::if_one_then(in_url,
        detail::color_to_vec(uniforms, uniforms.url_color),
        detail::to_color(uniforms, colors_arr[2], fg_as_uint));

    float is_selected_primary = float(is_selected & KITTY_BIT_MASK);
    float3 selection_color = detail::if_one_then(uniforms.use_cell_bg_for_selection_fg, bg,
        detail::color_to_vec(uniforms, uniforms.highlight_fg));
    selection_color = detail::if_one_then(uniforms.use_cell_fg_for_selection_fg, foreground, selection_color);
    foreground = detail::if_one_then(is_selected_primary, selection_color, foreground);
    decoration_fg = detail::if_one_then(is_selected_primary, selection_color, decoration_fg);

    uint2 decs = detail::get_decorations_indices(decorations_map, decorations_sampler,
                                         in_url > 0.5f, text_attrs, uniforms, cell.sprite_idx);
    out.strike_pos = detail::to_sprite_pos(uniforms, pos, decs.x);
    out.underline_pos = detail::to_sprite_pos(uniforms, pos, decs.y);
    out.underline_exclusion_pos = detail::to_underline_exclusion_pos(uniforms, cell.sprite_idx);

    out.cursor_color_premult = float4(cell_data.cursor.bg * uniforms.cursor_opacity,
                                      uniforms.cursor_opacity);
    float3 final_cursor_text_color = mix(foreground, cell_data.cursor.fg, uniforms.cursor_opacity);
    foreground = detail::if_one_then(cell_data.has_block_cursor, final_cursor_text_color, foreground);
    decoration_fg = detail::if_one_then(cell_data.has_block_cursor, final_cursor_text_color, decoration_fg);
    out.cursor_pos = detail::to_sprite_pos(uniforms, cell_data.pos,
                                   cell_data.cursor_fg_sprite_idx * uint(cell_data.has_cursor));
    out.decoration_fg = decoration_fg;
    out.cell_foreground = foreground;
#endif

    float bg_alpha = detail::calc_background_opacity(bg_as_uint, uniforms);
#if CELL_NEEDS_FOREGROUND
    float effective_cursor_opacity = max(uniforms.cursor_opacity, bg_alpha);
#endif
    float is_special_cell = float(
#if CELL_NEEDS_FOREGROUND
        cell_data.has_block_cursor
#else
        0.0f
#endif
    ) + float(is_selected & KITTY_BIT_MASK) + float(is_reversed);
    is_special_cell = detail::zero_or_one(is_special_cell);
    cell_has_default_bg = detail::if_one_then(is_special_cell, 0.0f, cell_has_default_bg);
    bg_alpha = detail::if_one_then(is_special_cell, 1.0f, bg_alpha);

#if CELL_NEEDS_FOREGROUND
    bg_alpha = detail::if_one_then(cell_data.has_block_cursor, effective_cursor_opacity, bg_alpha);
#endif

    float3 background_rgb = bg;
    background_rgb = detail::if_one_then(float(is_selected & KITTY_BIT_MASK),
        detail::if_one_then(uniforms.use_cell_for_selection_bg, detail::color_to_vec(uniforms, fg_as_uint),
                    detail::color_to_vec(uniforms, uniforms.highlight_bg)),
        background_rgb);
#if CELL_NEEDS_FOREGROUND
    background_rgb = detail::if_one_then(cell_data.has_block_cursor,
        mix(background_rgb, cell_data.cursor.bg, uniforms.cursor_opacity), background_rgb);
#endif

#if CELL_NEEDS_BACKGROUND
    out.background = background_rgb;
    float cell_has_non_default_bg = 1.0f - cell_has_default_bg;
    uint draw_bg_mask = uint(2.0f * cell_has_non_default_bg + cell_has_default_bg);
    float draw_bg = float((uniforms.draw_bg_bitfield & draw_bg_mask) != 0u);
    out.effective_background_premul = detail::vec4_premul(background_rgb, bg_alpha) * draw_bg;
#endif

    return out;
}

fragment float4 CELL_FRAGMENT_NAME(cell_fragment)(
    detail::CELL_VARYINGS_STRUCT in [[stage_in]],
    texture2d_array<float> glyph_atlas [[texture(0)]],
    sampler glyph_sampler [[sampler(0)]]
) {
#if defined(ONLY_FOREGROUND)
    float4 ans_premul;
#else
    float4 ans_premul = in.effective_background_premul;
#endif

#if !defined(ONLY_BACKGROUND)
    float4 text_fg = glyph_atlas.sample(glyph_sampler, in.sprite_pos.xy, in.sprite_pos.z);
    text_fg.rgb = mix(in.cell_foreground, text_fg.rgb, in.colored_sprite);

    float underline_alpha = glyph_atlas.sample(glyph_sampler, in.underline_pos.xy, in.underline_pos.z).a;
    uint width = glyph_atlas.get_width();
    uint array_index = uint(in.sprite_pos.z);
    uint2 fetch_coord = uint2(uint(in.sprite_pos.x * float(width)), in.underline_exclusion_pos);
    float underline_exclusion = glyph_atlas.read(fetch_coord, array_index, 0).a;
    underline_alpha *= 1.0f - underline_exclusion;

    float strike_alpha = glyph_atlas.sample(glyph_sampler, in.strike_pos.xy, in.strike_pos.z).a;
    float cursor_alpha = glyph_atlas.sample(glyph_sampler, in.cursor_pos.xy, in.cursor_pos.z).a;

    float combined_alpha = min(text_fg.a + strike_alpha, 1.0f);
    float4 text_premul = float4(in.cell_foreground, combined_alpha * in.effective_text_alpha);
    float4 decoration = detail::alpha_blend(float4(in.decoration_fg, underline_alpha * in.effective_text_alpha),
                                    text_premul);
    float4 text_fg_premul = mix(decoration, in.cursor_color_premult,
                                cursor_alpha * in.cursor_color_premult.a);

#if defined(ONLY_FOREGROUND)
    ans_premul = text_fg_premul;
#else
    ans_premul = detail::alpha_blend_premul(text_fg_premul, ans_premul);
#endif
#else
    (void)glyph_atlas;
    (void)glyph_sampler;
#endif

    return ans_premul;
}

#undef CELL_VERTEX_NAME
#undef CELL_FRAGMENT_NAME
#undef CAT
#undef CAT2
#undef CELL_VARYINGS_STRUCT

#endif // CELL_VARIANT_SUFFIX

} // namespace kitty::metal
