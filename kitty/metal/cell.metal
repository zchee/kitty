#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

namespace kitty {

constant uint BYTE_MASK = 0xffu;
constant uint SPRITE_INDEX_MASK = 0x7fffffffu;
constant uint SPRITE_COLORED_MASK = 0x80000000u;
constant uint SPRITE_COLORED_SHIFT = 31u;
constant uint BIT_MASK = 1u;
constant uint DECORATION_MASK = 0x7u;
constant uint MARK_MASK = 0x3u;
constant uint DECORATION_SHIFT = 0u;
constant uint REVERSE_SHIFT = 5u;
constant uint STRIKE_SHIFT = 6u;
constant uint DIM_SHIFT = 7u;
constant uint BLINK_SHIFT = 8u;
constant uint MARK_SHIFT [[maybe_unused]] = 9u;
constant uint COLOR_NOT_SET = 0u;
constant uint COLOR_IS_SPECIAL = 1u;
constant uint COLOR_IS_INDEX = 2u;
constant uint COLOR_IS_RGB = 3u;

constant uint CELL_CURSOR_SHAPE_NONE [[maybe_unused]] = 0u;
constant uint CELL_CURSOR_SHAPE_BLOCK = 1u;
constant uint CELL_CURSOR_SHAPE_BEAM = 2u;
constant uint CELL_CURSOR_SHAPE_UNDERLINE = 3u;
constant uint CELL_CURSOR_SHAPE_UNFOCUSED = 4u;

constant uint MetalCellNumColors = 256u;
constant uint MetalCellColorTableEntries = MetalCellNumColors + MARK_MASK + MARK_MASK + 2u;

struct MetalCellUniformData {
    float use_cell_bg_for_selection_fg;
    float use_cell_fg_for_selection_color;
    float use_cell_for_selection_bg;

    uint default_fg;
    uint highlight_fg;
    uint highlight_bg;
    uint main_cursor_fg;
    uint main_cursor_bg;
    uint url_color;
    uint url_style;
    uint inverted;
    uint extra_cursor_fg;
    uint extra_cursor_bg;

    uint columns;
    uint lines;
    uint sprites_xnum;
    uint sprites_ynum;
    uint cursor_shape;
    uint cell_width;
    uint cell_height;
    uint cursor_x1;
    uint cursor_x2;
    uint cursor_y1;
    uint cursor_y2;
    float cursor_opacity;
    float inactive_text_alpha;
    float dim_opacity;
    float blink_opacity;

    uint bg_colors0;
    uint bg_colors1;
    uint bg_colors2;
    uint bg_colors3;
    uint bg_colors4;
    uint bg_colors5;
    uint bg_colors6;
    uint bg_colors7;
    float bg_opacities0;
    float bg_opacities1;
    float bg_opacities2;
    float bg_opacities3;
    float bg_opacities4;
    float bg_opacities5;
    float bg_opacities6;
    float bg_opacities7;
    uint color_table[MetalCellColorTableEntries];
};

struct GPUCell {
    uint fg;
    uint bg;
    uint decoration_fg;
    uint sprite_idx;
    uint attrs;
};

static_assert(sizeof(GPUCell) == 20, "GPUCell layout mismatch");

struct ColorPair {
    float3 bg;
    float3 fg;
};

struct MetalDrawParams {
    float text_contrast;
    float text_gamma_adjustment;
    uint decorations_count;
    uint draw_background_mask;
    uint draw_foreground;
    float extra_alpha;
    float viewport_scale_x;
    float viewport_scale_y;
    float viewport_origin_x;
    float viewport_origin_y;
};

struct VertexOut {
    float4 position [[position]];
    float3 background;
    float4 effective_background_premul;
    float effective_text_alpha;
    float3 sprite_pos;
    float3 underline_pos;
    float3 cursor_pos;
    float3 strike_pos;
    uint underline_exclusion_pos;
    float3 cell_foreground;
    float4 cursor_color_premult;
    float3 decoration_fg;
    float colored_sprite;
};

constant float gamma_lut[256] = {
    #include "../srgb_gamma_values.inc"
};

inline float zero_or_one(float value) {
    return value == 0.f ? 1.f : 0.f;
}

inline uint zero_or_one(uint value) {
    return value == 0u ? 1u : 0u;
}

inline float one_if_equal_zero_otherwise(float a, float b) {
    return zero_or_one(fabs(a - b));
}

inline uint one_if_equal_zero_otherwise(uint a, uint b) {
    return zero_or_one(a - b);
}

inline uint is_cursor(uint x, uint y, constant MetalCellUniformData &u) {
    uint clamped_x = clamp(x, u.cursor_x1, u.cursor_x2);
    uint clamped_y = clamp(y, u.cursor_y1, u.cursor_y2);
    return one_if_equal_zero_otherwise(x, clamped_x) * one_if_equal_zero_otherwise(y, clamped_y);
}

inline float3 color_to_vec(uint c) {
    uint r = (c >> 16) & BYTE_MASK;
    uint g = (c >> 8) & BYTE_MASK;
    uint b = c & BYTE_MASK;
    return float3(gamma_lut[r], gamma_lut[g], gamma_lut[b]);
}

inline uint resolve_color(uint c, uint defval, constant MetalCellUniformData &u) {
    uint t = uint(c & BYTE_MASK);
    uint is_one = one_if_equal_zero_otherwise(t, 1u);
    uint is_two = one_if_equal_zero_otherwise(t, 2u);
    uint is_neither = 1u - is_one - is_two;
    uint table_index = (c >> 8) & BYTE_MASK;
    uint col_from_table = u.color_table[table_index];
    return is_one * col_from_table + is_two * (c >> 8) + is_neither * defval;
}

inline float3 to_color(uint c, uint defval, constant MetalCellUniformData &u) {
    return color_to_vec(resolve_color(c, defval, u));
}

inline float3 resolve_dynamic_color(uint c, float3 special_val, float3 defval, constant MetalCellUniformData &u) {
    float type = float((c >> 24) & BYTE_MASK);
    float3 color_rgb = color_to_vec(c);
    float3 index_rgb = color_to_vec(u.color_table[c & BYTE_MASK]);
    float3 special_rgb = special_val;
    float3 not_set_rgb = defval;
    float3 result = zero_or_one(type - float(COLOR_IS_RGB)) * color_rgb;
    result += zero_or_one(type - float(COLOR_IS_INDEX)) * index_rgb;
    result += zero_or_one(type - float(COLOR_IS_SPECIAL)) * special_rgb;
    result += zero_or_one(type - float(COLOR_NOT_SET)) * not_set_rgb;
    return result;
}

inline float background_opacity_for(uint bg, uint colorval, float opacity_if_matched) {
    float not_matched = step(1.f, fabs(float(colorval - bg)));
    return not_matched + opacity_if_matched * (1.f - not_matched);
}

inline float calc_background_opacity(uint bg, constant MetalCellUniformData &u) {
    return background_opacity_for(bg, u.bg_colors0, u.bg_opacities0) *
           background_opacity_for(bg, u.bg_colors1, u.bg_opacities1) *
           background_opacity_for(bg, u.bg_colors2, u.bg_opacities2) *
           background_opacity_for(bg, u.bg_colors3, u.bg_opacities3) *
           background_opacity_for(bg, u.bg_colors4, u.bg_opacities4) *
           background_opacity_for(bg, u.bg_colors5, u.bg_opacities5) *
           background_opacity_for(bg, u.bg_colors6, u.bg_opacities6) *
           background_opacity_for(bg, u.bg_colors7, u.bg_opacities7);
}

inline ColorPair if_one_then_pair(float flag, ColorPair a, ColorPair b) {
    return flag > 0.5f ? a : b;
}

inline float4 vec4_premul(float3 rgb, float alpha) {
    return float4(rgb * alpha, alpha);
}

inline float4 alpha_blend_premul(float4 over, float4 under) {
    float one_minus_a = 1.f - over.a;
    return float4(over.rgb + under.rgb * one_minus_a, over.a + under.a * one_minus_a);
}

inline float4 alpha_blend_premul(float4 over, float3 under_rgb) {
    return alpha_blend_premul(over, float4(under_rgb, 1.f));
}

inline float4 foreground_contrast(float4 over, float3 under, float text_contrast, float text_gamma_adjustment) {
    float under_luminance = dot(under, float3(0.2126f, 0.7152f, 0.0722f));
    float over_luminance = dot(over.rgb, float3(0.2126f, 0.7152f, 0.0722f));
    float adjustment = (1.f - over_luminance + under_luminance) * 0.5f;
    float adjusted = mix(over.a, pow(over.a, text_gamma_adjustment), clamp(adjustment, 0.f, 1.f));
    over.a = clamp(adjusted * text_contrast, 0.f, 1.f);
    return over;
}

inline float3 mix_if(float flag, float3 a, float3 b) {
    return flag > 0.5f ? a : b;
}

inline float4 mix_if(float flag, float4 a, float4 b) {
    return flag > 0.5f ? a : b;
}

inline ColorPair resolve_extra_cursor_colors(float3 cell_bg, float3 cell_fg, ColorPair main_cursor, constant MetalCellUniformData &u) {
    uint raw_fg = u.extra_cursor_fg;
    uint raw_bg = u.extra_cursor_bg;
    float3 special_bg = cell_bg;
    float3 special_fg = cell_fg;
    ColorPair ans;
    ans.bg = resolve_dynamic_color(raw_bg, special_bg, main_cursor.bg, u);
    ans.fg = resolve_dynamic_color(raw_fg, special_fg, main_cursor.fg, u);
    return ans;
}

inline float3 sprite_coord(uint sprite, uint2 pos, constant MetalCellUniformData &u) {
    uint layer = sprite & SPRITE_INDEX_MASK;
    uint column = layer % u.sprites_xnum;
    uint row = layer / u.sprites_xnum;
    float sx = (float(column) + float(pos.x)) / float(u.sprites_xnum);
    float sy_full = float(row) * (float(u.cell_height + 1u) / float(u.sprites_ynum));
    float sy = sy_full + (float(pos.y) * float(u.cell_height) / float(u.cell_height + 1u));
    return float3(sx, sy, float(layer));
}

inline uint decorations_index(uint sprite_idx, device const uint *decorations_buffer, uint count) {
    if (!decorations_buffer || sprite_idx >= count) {
        return 0u;
    }
    return decorations_buffer[sprite_idx];
}

vertex VertexOut cell_vertex(
    uint vertex_id [[vertex_id]],
    uint instance_id [[instance_id]],
    device const GPUCell *cells [[buffer(0)]],
    device const uchar *selection_buffer [[buffer(1)]],
    device const uint *decorations_buffer [[buffer(2)]],
    constant MetalCellUniformData &u [[buffer(3)]],
    constant MetalDrawParams &params [[buffer(4)]]
) {
    VertexOut out;
    GPUCell cell = cells[instance_id];
    uint selection_flags = selection_buffer ? uint(selection_buffer[instance_id]) : 0u;
    uint decoration_idx = decorations_index(cell.sprite_idx & SPRITE_INDEX_MASK, decorations_buffer, params.decorations_count);

    uint columns = u.columns;
    uint column = instance_id % columns;
    uint row = instance_id / columns;

    float dx = 2.f / float(u.columns);
    float dy = 2.f / float(u.lines);

    float left = -1.f + float(column) * dx;
    float top = 1.f - float(row) * dy;
    constexpr uint2 cell_pos_map[4] = {
        uint2(1u, 0u),
        uint2(1u, 1u),
        uint2(0u, 1u),
        uint2(0u, 0u),
    };
    uint2 pos = cell_pos_map[vertex_id & 3u];
    float x_local = mix(left, left + dx, float(pos.x));
    float y_local = mix(top, top - dy, float(pos.y));
    float x = params.viewport_origin_x + params.viewport_scale_x * x_local;
    float y = params.viewport_origin_y + params.viewport_scale_y * y_local;
    out.position = float4(x, y, 0.f, 1.f);

    uint fg_as_uint = resolve_color(cell.fg, u.default_fg, u);
    uint bg_as_uint = resolve_color(cell.bg, u.bg_colors0, u);
    float has_mark = step(1.f, float((selection_flags >> 5) & MARK_MASK));
    uint mark = (selection_flags >> 5) & MARK_MASK;
    bg_as_uint = uint(has_mark) * u.color_table[MetalCellNumColors + mark - 1u] + uint(1.f - has_mark) * bg_as_uint;
    fg_as_uint = uint(has_mark) * u.color_table[MetalCellNumColors + MARK_MASK + mark] + uint(1.f - has_mark) * fg_as_uint;

    float3 bg = color_to_vec(bg_as_uint);
    float3 fg = color_to_vec(fg_as_uint);
    float3 deco_fg = to_color(cell.decoration_fg, fg_as_uint, u);

    uint attrs = cell.attrs;
    uint is_reversed = (attrs >> REVERSE_SHIFT) & BIT_MASK;
    uint is_selected = selection_flags & BIT_MASK;

    float has_dim = float((attrs >> DIM_SHIFT) & BIT_MASK);
    float has_blink = float((attrs >> BLINK_SHIFT) & BIT_MASK);
    out.effective_text_alpha = u.inactive_text_alpha * mix(1.f, u.dim_opacity, has_dim) * mix(1.f, u.blink_opacity, has_blink);

    uint cursor_shape = u.cursor_shape;
    uint sprite_index = cell.sprite_idx & SPRITE_INDEX_MASK;
    uint cursor_fg_sprite_idx = 0u;
    switch (cursor_shape) {
        case CELL_CURSOR_SHAPE_BEAM: cursor_fg_sprite_idx = 2u; break;
        case CELL_CURSOR_SHAPE_UNDERLINE: cursor_fg_sprite_idx = 3u; break;
        case CELL_CURSOR_SHAPE_UNFOCUSED: cursor_fg_sprite_idx = 4u; break;
        default: cursor_fg_sprite_idx = 0u; break;
    }
    float has_cursor_flag = float(is_cursor(column, row, u));
    float has_block_cursor = has_cursor_flag * one_if_equal_zero_otherwise(cursor_shape, CELL_CURSOR_SHAPE_BLOCK);
    ColorPair main_cursor = { color_to_vec(u.main_cursor_bg), color_to_vec(u.main_cursor_fg) };
    ColorPair cursor_pair = resolve_extra_cursor_colors(bg, fg, main_cursor, u);
    cursor_pair = if_one_then_pair(has_cursor_flag, main_cursor, cursor_pair);

    float draw_cursor_sprite = has_cursor_flag * zero_or_one(cursor_shape - CELL_CURSOR_SHAPE_BLOCK);
    uint final_cursor_sprite = uint(cursor_fg_sprite_idx * draw_cursor_sprite);

    float3 selection_color = mix_if(u.use_cell_bg_for_selection_fg, bg, color_to_vec(u.highlight_fg));
    selection_color = mix_if(u.use_cell_fg_for_selection_color, fg, selection_color);
    fg = mix_if(float(is_selected), selection_color, fg);
    deco_fg = mix_if(float(is_selected), selection_color, deco_fg);

    float in_url = float((selection_flags >> 1) & BIT_MASK);
    deco_fg = mix_if(in_url, color_to_vec(u.url_color), deco_fg);

    float cursor_opacity = u.cursor_opacity;
    out.cursor_color_premult = float4(cursor_pair.bg * cursor_opacity, cursor_opacity);
    float3 final_cursor_text_color = mix(fg, cursor_pair.fg, cursor_opacity);
    fg = mix_if(has_block_cursor, final_cursor_text_color, fg);
    deco_fg = mix_if(has_block_cursor, final_cursor_text_color, deco_fg);

    float colored_sprite = float((cell.sprite_idx & SPRITE_COLORED_MASK) >> SPRITE_COLORED_SHIFT);
    out.colored_sprite = colored_sprite;

    out.sprite_pos = float3(
        (float(sprite_index % u.sprites_xnum) + float(pos.x)) / float(u.sprites_xnum),
        (float(sprite_index / u.sprites_xnum) * float(u.cell_height + 1u) + float(pos.y) * float(u.cell_height)) /
        (float(u.sprites_ynum) * float(u.cell_height + 1u)),
        float(sprite_index)
    );

    out.cursor_pos = float3(
        (float(final_cursor_sprite % u.sprites_xnum) + float(pos.x)) / float(u.sprites_xnum),
        (float(final_cursor_sprite / u.sprites_xnum) * float(u.cell_height + 1u) + float(pos.y) * float(u.cell_height)) /
        (float(u.sprites_ynum) * float(u.cell_height + 1u)),
        float(final_cursor_sprite)
    );

    uint underline_style = ((attrs >> DECORATION_SHIFT) & DECORATION_MASK);
    underline_style = uint(in_url) * u.url_style + (1u - uint(in_url)) * underline_style;
    uint has_underline = underline_style > 0u ? 1u : 0u;
    uint decorations_idx = decoration_idx;
    uint strike_style = ((attrs >> STRIKE_SHIFT) & BIT_MASK);
    uint strike_idx = decorations_idx * strike_style;
    uint underline_idx = has_underline ? (decorations_idx + underline_style) : 0u;

    out.strike_pos = sprite_coord(strike_idx, pos, u);
    out.underline_pos = sprite_coord(underline_idx, pos, u);

    uint cell_top_px = (sprite_index / u.sprites_xnum) * (u.cell_height + 1u);
    out.underline_exclusion_pos = cell_top_px + u.cell_height;

    float bg_alpha = calc_background_opacity(bg_as_uint, u);
    float is_special_cell = has_block_cursor + float(is_selected) + float(is_reversed);
    is_special_cell = clamp(is_special_cell, 0.f, 1.f);
    float cell_has_default_bg = zero_or_one(float(bg_as_uint - u.bg_colors0));
    cell_has_default_bg = mix(0.f, cell_has_default_bg, 1.f - is_special_cell);
    bg_alpha = mix(1.f, bg_alpha, 1.f - is_special_cell);
    bg_alpha = mix(bg_alpha, max(cursor_opacity, bg_alpha), has_block_cursor);
    float3 background_rgb = mix(bg, mix(bg, cursor_pair.bg, cursor_opacity), has_block_cursor);
    background_rgb = mix(background_rgb, mix(fg, color_to_vec(u.highlight_bg), u.use_cell_for_selection_bg), float(is_selected));

    out.background = background_rgb;
    float cell_has_non_default_bg = 1.f - cell_has_default_bg;
    uint draw_bg_mask = uint(2.f * cell_has_non_default_bg + cell_has_default_bg);
    float draw_bg = step(0.5f, float(params.draw_background_mask & draw_bg_mask));
    out.effective_background_premul = vec4_premul(background_rgb, bg_alpha * draw_bg);
    out.cell_foreground = fg;
    out.decoration_fg = deco_fg;
    out.effective_text_alpha *= float(params.draw_foreground);

    return out;
}

fragment float4 cell_fragment(
    VertexOut in [[stage_in]],
    texture2d_array<float> sprites [[texture(0)]],
    sampler atlas_sampler [[sampler(0)]],
    constant MetalCellUniformData &u [[buffer(0)]],
    constant MetalDrawParams &params [[buffer(1)]]
) {
    float4 background = in.effective_background_premul;
    float draw_foreground = float(params.draw_foreground);
    float4 text_sample = sprites.sample(atlas_sampler, in.sprite_pos.xy, uint(in.sprite_pos.z));
    float4 text_fg = float4(mix(in.cell_foreground, text_sample.rgb, in.colored_sprite), text_sample.a * in.effective_text_alpha * draw_foreground);
    text_fg = foreground_contrast(text_fg, in.background, params.text_contrast, params.text_gamma_adjustment);

    float strike_alpha = sprites.sample(atlas_sampler, in.strike_pos.xy, uint(in.strike_pos.z)).a * in.effective_text_alpha * draw_foreground;
    float underline_alpha = sprites.sample(atlas_sampler, in.underline_pos.xy, uint(in.underline_pos.z)).a * in.effective_text_alpha * draw_foreground;
    float cursor_alpha = sprites.sample(atlas_sampler, in.cursor_pos.xy, uint(in.cursor_pos.z)).a * draw_foreground;

    float4 cursor_color = in.cursor_color_premult;
    float4 decorations = float4(in.decoration_fg * underline_alpha, underline_alpha);
    float4 text_premul = vec4_premul(text_fg.rgb, text_fg.a);
    text_premul.rgb += in.cell_foreground * strike_alpha;

    float4 blended = alpha_blend_premul(text_premul, background);
    blended = mix(blended, alpha_blend_premul(cursor_color, blended), cursor_alpha);
    blended = alpha_blend_premul(decorations, blended);
    return blended;
}

struct MetalBorderRect {
    float rect[4];
    uint color;
    uint _pad0;
    uint _pad1;
    uint _pad2;
};

struct MetalBorderUniforms {
    uint colors[9];
    float background_opacity;
    float _pad0;
    float _pad1;
};

struct BorderVertexOut {
    float4 position [[position]];
    float4 color_premul;
};

constant uint DEFAULT_BG [[maybe_unused]] = 0u;
constant uint ACTIVE_BORDER_COLOR = 1u;
constant uint INACTIVE_BORDER_COLOR = 2u;
constant uint WINDOW_BACKGROUND_PLACEHOLDER = 3u;
constant uint BELL_BORDER_COLOR = 4u;

vertex BorderVertexOut border_vertex(
    uint vertex_id [[vertex_id]],
    uint instance_id [[instance_id]],
    const device MetalBorderRect *rects [[buffer(0)]],
    constant MetalBorderUniforms &uniforms [[buffer(1)]]
) {
    BorderVertexOut out;
    MetalBorderRect rect = rects[instance_id];
    float left = rect.rect[0];
    float top = rect.rect[1];
    float right = rect.rect[2];
    float bottom = rect.rect[3];
    const float2 positions[4] = {
        float2(right, top),
        float2(right, bottom),
        float2(left, bottom),
        float2(left, top)
    };
    float2 pos = positions[vertex_id & 3u];
    out.position = float4(pos, 0.0, 1.0);

    uint rc = rect.color & 0xffu;
    uint color_index = rc < 9u ? rc : 0u;
    uint32_t packed_window_bg = rect.color >> 8;
    uint window_r = (packed_window_bg >> 16) & 0xffu;
    uint window_g = (packed_window_bg >> 8) & 0xffu;
    uint window_b = packed_window_bg & 0xffu;
    float3 window_bg = float3(gamma_lut[window_r], gamma_lut[window_g], gamma_lut[window_b]);
    uint32_t packed_color = uniforms.colors[color_index];
    uint cr = (packed_color >> 16) & 0xffu;
    uint cg = (packed_color >> 8) & 0xffu;
    uint cb = packed_color & 0xffu;
    float3 color_rgb = float3(gamma_lut[cr], gamma_lut[cg], gamma_lut[cb]);
    if (rc == WINDOW_BACKGROUND_PLACEHOLDER) {
        color_rgb = window_bg;
    }
    bool is_border = (rc == ACTIVE_BORDER_COLOR) || (rc == INACTIVE_BORDER_COLOR) || (rc == BELL_BORDER_COLOR);
    float final_opacity = is_border ? 1.0f : uniforms.background_opacity;
    out.color_premul = float4(color_rgb * final_opacity, final_opacity);
    return out;
}

fragment float4 border_fragment(BorderVertexOut in [[stage_in]]) {
    return in.color_premul;
}

struct MetalTrailUniforms {
    float x_coords[4];
    float y_coords[4];
    float cursor_edge_x[2];
    float cursor_edge_y[2];
    uint color;
    float opacity;
    float _pad0;
    float _pad1;
};

struct TrailVertexOut {
    float4 position [[position]];
    float2 frag_pos;
};

vertex TrailVertexOut trail_vertex(
    uint vertex_id [[vertex_id]],
    constant MetalTrailUniforms &uniforms [[buffer(0)]]
) {
    TrailVertexOut out;
    float2 pos = float2(uniforms.x_coords[vertex_id & 3u], uniforms.y_coords[vertex_id & 3u]);
    out.position = float4(pos, 1.0, 1.0);
    out.frag_pos = pos;
    return out;
}

fragment float4 trail_fragment(
    TrailVertexOut in [[stage_in]],
    constant MetalTrailUniforms &uniforms [[buffer(0)]]
) {
    float opacity = uniforms.opacity;
    float in_x = step(uniforms.cursor_edge_x[0], in.frag_pos.x) * step(in.frag_pos.x, uniforms.cursor_edge_x[1]);
    float in_y = step(uniforms.cursor_edge_y[1], in.frag_pos.y) * step(in.frag_pos.y, uniforms.cursor_edge_y[0]);
    opacity *= 1.0f - in_x * in_y;
    uint color_raw = uniforms.color;
    uint r = (color_raw >> 16) & 0xffu;
    uint g = (color_raw >> 8) & 0xffu;
    uint b = color_raw & 0xffu;
    float3 color_rgb = float3(gamma_lut[r], gamma_lut[g], gamma_lut[b]);
    return float4(color_rgb * opacity, opacity);
}

struct GraphicsVertexOut {
    float4 position [[position]];
    float2 texcoord;
};

struct MetalGraphicsUniforms {
    float4 src_rect;
    float4 dest_rect;
    float extra_alpha;
    float _pad[3];
};

struct MetalGraphicsAlphaUniforms {
    float4 src_rect;
    float4 dest_rect;
    float3 foreground_rgb;
    float _pad0;
    float4 background_premul;
};

vertex GraphicsVertexOut
graphics_vertex(uint vertex_id [[vertex_id]], constant MetalGraphicsUniforms &uniforms [[buffer(0)]]) {
    const float2 dest_points[4] = {
        float2(uniforms.dest_rect.x, uniforms.dest_rect.y),
        float2(uniforms.dest_rect.x, uniforms.dest_rect.w),
        float2(uniforms.dest_rect.z, uniforms.dest_rect.w),
        float2(uniforms.dest_rect.z, uniforms.dest_rect.y)
    };
    const float2 src_points[4] = {
        float2(uniforms.src_rect.x, uniforms.src_rect.y),
        float2(uniforms.src_rect.x, uniforms.src_rect.w),
        float2(uniforms.src_rect.z, uniforms.src_rect.w),
        float2(uniforms.src_rect.z, uniforms.src_rect.y)
    };
    GraphicsVertexOut out;
    uint idx = vertex_id & 3u;
    out.position = float4(dest_points[idx], 0.0f, 1.0f);
    out.texcoord = src_points[idx];
    return out;
}

fragment float4
graphics_fragment(GraphicsVertexOut in [[stage_in]], texture2d<float> image [[texture(0)]], sampler smp [[sampler(0)]], constant MetalGraphicsUniforms &uniforms [[buffer(1)]]) {
    float4 color = image.sample(smp, in.texcoord);
    color.a *= uniforms.extra_alpha;
    color.rgb *= color.a;
    return color;
}

fragment float4
graphics_premult_fragment(GraphicsVertexOut in [[stage_in]], texture2d<float> image [[texture(0)]], sampler smp [[sampler(0)]], constant MetalGraphicsUniforms &uniforms [[buffer(1)]]) {
    float4 color = image.sample(smp, in.texcoord);
    color *= uniforms.extra_alpha;
    return color;
}

struct GraphicsAlphaVertexOut {
    float4 position [[position]];
    float2 texcoord;
};

vertex GraphicsAlphaVertexOut
graphics_alpha_vertex(uint vertex_id [[vertex_id]], constant MetalGraphicsAlphaUniforms &uniforms [[buffer(0)]]) {
    const float2 dest_points[4] = {
        float2(uniforms.dest_rect.x, uniforms.dest_rect.y),
        float2(uniforms.dest_rect.x, uniforms.dest_rect.w),
        float2(uniforms.dest_rect.z, uniforms.dest_rect.w),
        float2(uniforms.dest_rect.z, uniforms.dest_rect.y)
    };
    const float2 src_points[4] = {
        float2(uniforms.src_rect.x, uniforms.src_rect.y),
        float2(uniforms.src_rect.x, uniforms.src_rect.w),
        float2(uniforms.src_rect.z, uniforms.src_rect.w),
        float2(uniforms.src_rect.z, uniforms.src_rect.y)
    };
    GraphicsAlphaVertexOut out;
    uint idx = vertex_id & 3u;
    out.position = float4(dest_points[idx], 0.0f, 1.0f);
    out.texcoord = src_points[idx];
    return out;
}

fragment float4
graphics_alpha_fragment(GraphicsAlphaVertexOut in [[stage_in]], texture2d<float> image [[texture(0)]], sampler smp [[sampler(0)]], constant MetalGraphicsAlphaUniforms &uniforms [[buffer(1)]]) {
    float mask = image.sample(smp, in.texcoord).r;
    float4 fg = vec4_premul(uniforms.foreground_rgb, mask);
    return alpha_blend_premul(fg, uniforms.background_premul);
}

struct OverlayTintUniforms {
    float4 edges;
    float4 color;
};

struct OverlayVertexOut {
    float4 position [[position]];
};

vertex OverlayVertexOut
overlay_tint_vertex(uint vertex_id [[vertex_id]], constant OverlayTintUniforms &uniforms [[buffer(0)]]) {
    const float2 positions[4] = {
        float2(uniforms.edges.x, uniforms.edges.y),
        float2(uniforms.edges.x, uniforms.edges.w),
        float2(uniforms.edges.z, uniforms.edges.w),
        float2(uniforms.edges.z, uniforms.edges.y)
    };
    OverlayVertexOut out;
    out.position = float4(positions[vertex_id & 3], 0.0, 1.0);
    return out;
}

fragment float4
overlay_tint_fragment(constant OverlayTintUniforms &uniforms [[buffer(0)]]) {
    return uniforms.color;
}

struct OverlayRoundedUniforms {
    float2 size;
    float thickness;
    float radius;
    float3 padding;
    float4 color;
};

struct OverlayRoundedVertexOut {
    float4 position [[position]];
    float2 local;
};

vertex OverlayRoundedVertexOut
overlay_rounded_vertex(uint vertex_id [[vertex_id]], constant OverlayRoundedUniforms &uniforms [[buffer(0)]]) {
    const float2 corners[4] = {
        float2(0.0, uniforms.size.y),
        float2(0.0, 0.0),
        float2(uniforms.size.x, 0.0),
        float2(uniforms.size.x, uniforms.size.y)
    };
    const float2 positions[4] = {
        float2(-1.0,  1.0),
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2( 1.0,  1.0)
    };
    OverlayRoundedVertexOut out;
    uint idx = vertex_id & 3;
    out.position = float4(positions[idx], 0.0, 1.0);
    out.local = corners[idx];
    return out;
}

fragment float4
overlay_rounded_fragment(OverlayRoundedVertexOut in [[stage_in]], constant OverlayRoundedUniforms &uniforms [[buffer(1)]]) {
    float2 half_size = uniforms.size * 0.5f;
    float2 center = float2(half_size.x, half_size.y);
    float2 p = in.local - center;
    float2 b = half_size - uniforms.radius;
    float2 d = fabs(p) - b;
    float dist = length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - uniforms.radius;
    float outer_edge = -dist;
    float inner_edge = outer_edge - uniforms.thickness;
    const float step_size = 1.0;
    float alpha = smoothstep(-step_size, step_size, outer_edge) - smoothstep(-step_size, step_size, inner_edge);
    float4 color = uniforms.color;
    color.rgb *= alpha;
    color.a *= alpha;
    return color;
}

struct OverlayTextureUniforms {
    float2 tex_scale;
};

struct OverlayTextureVertexOut {
    float4 position [[position]];
    float2 texcoord;
};

vertex OverlayTextureVertexOut
overlay_texture_vertex(uint vertex_id [[vertex_id]], constant OverlayTextureUniforms &uniforms [[buffer(0)]]) {
    const float2 positions[4] = {
        float2(-1.0,  1.0),
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2( 1.0,  1.0)
    };
    const float2 texcoords[4] = {
        float2(0.0, 0.0),
        float2(0.0, uniforms.tex_scale.y),
        float2(uniforms.tex_scale.x, uniforms.tex_scale.y),
        float2(uniforms.tex_scale.x, 0.0)
    };
    OverlayTextureVertexOut out;
    uint idx = vertex_id & 3;
    out.position = float4(positions[idx], 0.0, 1.0);
    out.texcoord = texcoords[idx];
    return out;
}

fragment float4
overlay_texture_fragment(OverlayTextureVertexOut in [[stage_in]], texture2d<float> tex [[texture(0)]], sampler smp [[sampler(0)]]) {
    return tex.sample(smp, in.texcoord);
}

struct OverlayAlphaUniforms {
    float2 tex_scale;
    float4 color;
};

struct OverlayAlphaVertexOut {
    float4 position [[position]];
    float2 texcoord;
};

vertex OverlayAlphaVertexOut
overlay_alpha_vertex(uint vertex_id [[vertex_id]], constant OverlayAlphaUniforms &uniforms [[buffer(0)]]) {
    const float2 positions[4] = {
        float2(-1.0,  1.0),
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2( 1.0,  1.0)
    };
    const float2 texcoords[4] = {
        float2(0.0, 0.0),
        float2(0.0, uniforms.tex_scale.y),
        float2(uniforms.tex_scale.x, uniforms.tex_scale.y),
        float2(uniforms.tex_scale.x, 0.0)
    };
    OverlayAlphaVertexOut out;
    uint idx = vertex_id & 3;
    out.position = float4(positions[idx], 0.0, 1.0);
    out.texcoord = texcoords[idx];
    return out;
}

fragment float4
overlay_alpha_fragment(OverlayAlphaVertexOut in [[stage_in]], constant OverlayAlphaUniforms &uniforms [[buffer(1)]], texture2d<float> mask [[texture(0)]], sampler smp [[sampler(0)]]) {
    float alpha = mask.sample(smp, in.texcoord).r;
    float4 color = uniforms.color;
    color.rgb *= alpha;
    color.a *= alpha;
    return color;
}


} // namespace kitty
