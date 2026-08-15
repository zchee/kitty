#language slang 2026
// Copyright (C) 2026 Kovid Goyal <kovid at kovidgoyal.net>
// Distributed under terms of the GPLv3 license.
//
// FORK-OWNED wrapper (Phase C, ADR-0038/0035): the cell shader through the
// generated pipeline, retiring the hand-written kitty/cell_shaders.metal.
// Structure and naming deliberately mirror upstream cell.slang and the
// background module 1:1 so upstream changes can be diffed across — the same
// discipline the retired MSL carried, now in the same language.
//
// Why a self-contained wrapper instead of importing the upstream modules:
// 1. defect B (ADR-0035 §2): upstream's combined Sampler2D/Sampler2DArray
//    plus GetDimensions miscompiles to Metal; the proven route-around is
//    SEPARATE Texture2D/SamplerState declarations. Those live at module
//    scope in cell.slang/background.slang, so the functions that touch them
//    cannot be reused — and a wrapper importing an entry file hangs slangc
//    (upstream defect, filed at W3j). This file is Metal-only: the GL arm
//    compiles upstream cell.slang untouched, so the GL host contract never
//    sees the split (the in-tree split of cell.slang itself was the W3j
//    round-1 F1 revert).
// 2. The fork threads two carriers upstream has no notion of through the
//    colour resolution: the W27 P3.5b wide-gamut table (0x01000000|index
//    marks "the real value lives in the float4 table") and the F1 R8
//    colored-sprite atlas pair (mono R8 + colored RGBA, selected per cell).
//
// The colour epilogue axes mirror border_fork.slang: only the four
// (transfer, primaries) pairs metal.m's resolvers can produce are compiled.
// Colour maths comes from modules, never local copies (W3j): linear2srgb from
// upstream's module, srgb_to_p3 from the fork's generated module.

// https://github.com/shader-slang/slang/issues/11874
// warnings-disable: 41012

import utils;
import hsluv;
import alpha_blend;
import linear2srgb;
import color_fork_generated;

// Upstream cell.slang's specialization axes, same names, no defaults —
// every variant names all three (slang.py's cell_fork.slang case).
extern static const uint FG_OVERRIDE_ALGO;
extern static const bool TEXT_NEW_GAMMA;
extern static const uint RENDER_MODE;
// The fork epilogue axes (border_fork.slang's, ADR-0034 §2).
extern static const int target_color_space = 0;
extern static const bool target_primaries_is_p3 = false;

static const bool ONLY_FOREGROUND = RENDER_MODE == 2;
static const bool ONLY_BACKGROUND = RENDER_MODE == 1;
static const int TARGET_SPACE_ENCODE_SRGB = 0;



import background_fork;

Texture2DArray<float4> sprites;
Texture2DArray<float4> color_sprites; // F1: colored (RGBA) atlas
SamplerState sprite_sampler;          // nearest + clamp_to_edge (metal.m's cache)
Texture2D<uint4> sprite_decorations_map;
Texture2D<uint4> color_sprite_decorations_map; // F1

static const uint SPRITE_INDEX_MASK = 0x7fffffff;
static const uint SPRITE_COLORED_MASK = 0x80000000;
static const uint SPRITE_COLORED_SHIFT = 31u;


struct VertexOutput {
    float4 position : SV_Position;

    float3 background;
    float4 effective_background_premul;
    float effective_text_alpha;
    float3 sprite_pos;
    float3 underline_pos;
    float3 cursor_pos;
    float3 strike_pos;
    nointerpolation uint underline_exclusion_pos;
    float3 cell_foreground;
    float4 cursor_color_premult;
    float3 decoration_fg;
    float colored_sprite;
    // F1: sample the text texel from color_sprites when >0.5
    nointerpolation float use_color_atlas;
};

// Foreground utility functions (cell.slang's; xnum/ynum/cell_height passed
// explicitly so the same math serves both the mono atlas (crd.sprites_*) and
// the F1 colored atlas (crd.color_sprites_*)) {{{
uint3
to_sprite_coords(uint idx, uint xnum, uint ynum) {
    uint sprites_per_page = xnum * ynum;
    uint z = idx / sprites_per_page;
    uint num_on_last_page = idx - sprites_per_page * z;
    uint y = num_on_last_page / xnum;
    uint x = num_on_last_page - xnum * y;
    return uint3(x, y, z);
}

float3
to_sprite_pos(uint2 pos, uint idx, uint xnum, uint ynum) {
    uint3 c = to_sprite_coords(idx, xnum, ynum);
    float2 s_xpos = float2(float(c.x), float(c.x) + 1.0f) * (1.0f / float(xnum));
    float2 s_ypos = float2(float(c.y), float(c.y) + 1.0f) * (1.0f / float(ynum));
    uint texture_height_px = (crd.cell_height + 1u) * ynum;
    float row_height = 1.0f / float(texture_height_px);
    s_ypos[1] -= row_height; // skip the decorations_exclude row
    return float3(s_xpos[pos.x], s_ypos[pos.y], float(c.z));
}

uint
to_underline_exclusion_pos(uint2 sprite_idx, uint xnum, uint ynum) {
    uint3 c = to_sprite_coords(sprite_idx[0] & SPRITE_INDEX_MASK, xnum, ynum);
    uint cell_top_px = c.y * (crd.cell_height + 1u);
    return cell_top_px + crd.cell_height;
}

uint
read_sprite_decorations_idx(uint2 sprite_idx, Texture2D<uint4> deco_map) {
    int idx = int(sprite_idx[0] & SPRITE_INDEX_MASK);
    uint width, height;
    deco_map.GetDimensions(width, height);
    int2 sz = int2(int(width), int(height));
    int y = idx / sz[0];
    int x = idx - y * sz[0];
    return deco_map.Load(int3(x, y, 0)).r;
}

uint2
get_decorations_indices(uint2 sprite_idx, uint in_url /* [0, 1] */, uint text_attrs, Texture2D<uint4> deco_map) {
    uint decorations_idx = read_sprite_decorations_idx(sprite_idx, deco_map);
    uint has_decorations = uint(zero_or_one(float(decorations_idx)));
    uint strike_style = ((text_attrs >> STRIKE_SHIFT) & BIT_MASK); // 0 or 1
    uint strike_idx = decorations_idx * strike_style;
    uint underline_style = ((text_attrs >> DECORATION_SHIFT) & DECORATION_MASK);
    underline_style = in_url * crd.url_style + (1u - in_url) * underline_style; // [0, 5]
    uint has_underline = uint(step(0.5f, float(underline_style)));              // [0, 1]
    return has_decorations * uint2(strike_idx, has_underline * (decorations_idx + underline_style));
}
// }}}

// Override foreground colors (cell.slang's) {{{
float3
fg_override_luminance(float colored_sprite, float under_luminance, float over_lumininace, float3 under, float3 over) {
    // If the difference in luminance is too small,
    // force the foreground color to be black or white.
    float diff_luminance = abs(under_luminance - over_lumininace);
    float override_level = (1.f - colored_sprite) * step(diff_luminance, crd.fg_override_threshold);
    float original_level = 1.f - override_level;
    return original_level * over + override_level * float3(step(under_luminance, 0.5f));
}

float3
fg_override_contrast(float under_luminance, float over_luminance, float3 under, float3 over) {
    float ratio = contrast_ratio(under_luminance, over_luminance);
    float3 diff = abs(under - over);
    float3 over_hsluv = rgbToHsluv(over);
    const float min_contrast_ratio = crd.fg_override_threshold;
    float target_lum_a = clamp((under_luminance + 0.05) * min_contrast_ratio - 0.05, 0.0, 1.0);
    float target_lum_b = clamp((under_luminance + 0.05) / min_contrast_ratio - 0.05, 0.0, 1.0);
    float3 result_a = clamp(hsluvToRgb(float3(over_hsluv.x, over_hsluv.y, target_lum_a * 100.0)), 0.0, 1.0);
    float3 result_b = clamp(hsluvToRgb(float3(over_hsluv.x, over_hsluv.y, target_lum_b * 100.0)), 0.0, 1.0);
    float result_a_ratio = contrast_ratio(under_luminance, dot(result_a, Y));
    float result_b_ratio = contrast_ratio(under_luminance, dot(result_b, Y));
    float3 result = lerp(result_a, result_b, step(result_a_ratio, result_b_ratio));
    float fallback_condition = max(step(diff.x + diff.y + diff.z, 0.001), step(min_contrast_ratio, ratio));
    return lerp(result, over, fallback_condition);
}

float3
override_foreground_color(float3 over, float3 under, float colored_sprite) {
    float under_luminance = dot(under, Y);
    float over_lumininace = dot(over.rgb, Y);
    if (FG_OVERRIDE_ALGO == 1) return fg_override_luminance(colored_sprite, under_luminance, over_lumininace, under, over);
    return fg_override_contrast(under_luminance, over_lumininace, under, over);
}
// }}}

[shader("vertex")]
// ForceInline: without it slang outlines this large entry into a helper and
// leaves bogus [[stage_in]] annotations on the helper's pointer params, which
// the Metal compiler rejects (emitter defect; upstream-filing candidate).
[ForceInline]
VertexOutput
vertex_main(
    [[vk::location(0)]] uint3 colors,
    [[vk::location(1)]] uint2 sprite_idx,
    [[vk::location(2)]] uint is_selected,
    uint vertex_id: SV_VertexID,
    uint instance_id: SV_InstanceID,
    uniform uint draw_bg_bitfield, ) {
    VertexOutput vo;

    BackgroundOutput bo = compute_background(colors, sprite_idx, is_selected, instance_id, vertex_id);
    vo.position = bo.position;
    float3 background_rgb = bo.background_rgb;
    float3 foreground = bo.foreground;
    uint fg_as_uint = bo.fg_as_uint;
    uint text_attrs = bo.text_attrs;
    CellData cell_data = bo.cell_data;

    // Foreground {{{
    if (!ONLY_BACKGROUND) { // background does not depend on foreground
        // The character sprite being rendered
        vo.colored_sprite = float((sprite_idx[0] & SPRITE_COLORED_MASK) >> SPRITE_COLORED_SHIFT);
        // F1: colored sprites only live in the separate atlas when the split is
        // active; under the kill switch (color_atlas_active==0) everything is mono.
        vo.use_color_atlas = vo.colored_sprite * float(crd.color_atlas_active);
        uint text_sprite_idx = sprite_idx[0] & SPRITE_INDEX_MASK;
        if (vo.use_color_atlas > 0.5f) vo.sprite_pos = to_sprite_pos(cell_data.pos, text_sprite_idx, crd.color_sprites_xnum, crd.color_sprites_ynum);
        else vo.sprite_pos = to_sprite_pos(cell_data.pos, text_sprite_idx, crd.sprites_xnum, crd.sprites_ynum);

        float has_dim = float((text_attrs >> DIM_SHIFT) & BIT_MASK), has_blink = float((text_attrs >> BLINK_SHIFT) & BIT_MASK);
        vo.effective_text_alpha = crd.inactive_text_alpha * if_one_then(has_dim, crd.dim_opacity, 1.0) * if_one_then(has_blink, crd.blink_opacity, 1.0);
        float in_url = float((is_selected >> 1) & BIT_MASK);
        vo.decoration_fg = if_one_then(in_url, color_to_vec(crd.url_color), to_color(colors[2], fg_as_uint));
        // Selection
        float3 selection_color = if_one_then(crd.use_cell_bg_for_selection_fg, bo.bg, color_to_vec(crd.highlight_fg));
        selection_color = if_one_then(crd.use_cell_fg_for_selection_fg, foreground, selection_color);
        foreground = if_one_then(float(is_selected & BIT_MASK), selection_color, foreground);
        vo.decoration_fg = if_one_then(float(is_selected & BIT_MASK), selection_color, vo.decoration_fg);
        // Underline and strike through (rendered via sprites). Read the
        // decoration index from the atlas namespace this cell's text sprite
        // belongs to; the stored value is always a mono-namespace sprite index,
        // so the strike/underline positions use the mono layout.
        uint2 decs = (vo.use_color_atlas > 0.5f)
            ? get_decorations_indices(sprite_idx, uint(in_url), text_attrs, color_sprite_decorations_map)
            : get_decorations_indices(sprite_idx, uint(in_url), text_attrs, sprite_decorations_map);
        vo.strike_pos = to_sprite_pos(cell_data.pos, decs[0], crd.sprites_xnum, crd.sprites_ynum);
        vo.underline_pos = to_sprite_pos(cell_data.pos, decs[1], crd.sprites_xnum, crd.sprites_ynum);
        // The exclusion mask lives in the text glyph's own cell, so use the
        // atlas the text sprite is in.
        if (vo.use_color_atlas > 0.5f) vo.underline_exclusion_pos = to_underline_exclusion_pos(sprite_idx, crd.color_sprites_xnum, crd.color_sprites_ynum);
        else vo.underline_exclusion_pos = to_underline_exclusion_pos(sprite_idx, crd.sprites_xnum, crd.sprites_ynum);

        // Cursor
        vo.cursor_color_premult = float4(cell_data.cursor.bg * crd.cursor_opacity, crd.cursor_opacity);
        float3 final_cursor_text_color = lerp(foreground, cell_data.cursor.fg, crd.cursor_opacity);
        foreground = if_one_then(cell_data.has_block_cursor, final_cursor_text_color, foreground);
        vo.decoration_fg = if_one_then(cell_data.has_block_cursor, final_cursor_text_color, vo.decoration_fg);
        vo.cursor_pos = to_sprite_pos(cell_data.pos, cell_data.cursor_fg_sprite_idx * uint(cell_data.has_cursor), crd.sprites_xnum, crd.sprites_ynum);
    }
    // }}}

    vo.background = background_rgb;

    if (!ONLY_BACKGROUND && FG_OVERRIDE_ALGO > 0) {
        vo.decoration_fg = override_foreground_color(vo.decoration_fg, background_rgb, vo.colored_sprite);
        foreground = override_foreground_color(foreground, background_rgb, vo.colored_sprite);
    }

    if (!ONLY_FOREGROUND) {
        float4 bgpremul = vec4_premul(background_rgb, bo.bg_alpha);
        // draw_bg_bitfield has bit 0 set to draw default bg cells and bit 1 set to draw non-default bg cells
        float cell_has_non_default_bg = 1.f - bo.cell_has_default_bg;
        uint draw_bg_mask = uint(2.f * cell_has_non_default_bg + bo.cell_has_default_bg); // 1 if has default bg else 2
        float draw_bg = step(0.5, float(draw_bg_bitfield & draw_bg_mask));
        bgpremul *= draw_bg;
        vo.effective_background_premul = bgpremul;
    }

    if (!ONLY_BACKGROUND) vo.cell_foreground = foreground;

    return vo;
}

// Scaling factor for the extra text-alpha adjustment for luminance-difference.
static const float text_gamma_scaling = 0.5;

float
clamp_to_unit_float(float x) {
    // Clamp value to suitable output range
    return clamp(x, 0.0f, 1.0f);
}

float4
foreground_contrast_new(float4 over, float3 under, float text_contrast, float text_gamma_adjustment) {
    float under_luminance = dot(under, Y);
    float over_lumininace = dot(over.rgb, Y);
    // Apply additional gamma-adjustment scaled by the luminance difference, the darker the foreground the more adjustment we apply.
    // A multiplicative contrast is also available to increase saturation.
    over.a =
        clamp_to_unit_float(lerp(over.a, pow(over.a, text_gamma_adjustment), (1 - over_lumininace + under_luminance) * text_gamma_scaling) * text_contrast);
    return over;
}

float4
foreground_contrast_old(float4 over, float3 under) {
    // Simulation of gamma-incorrect blending
    float under_luminance = dot(under, Y);
    float over_lumininace = dot(over.rgb, Y);
    // This is the original gamma-incorrect rendering, it is the solution of the following equation:
    //
    // linear2srgb(over * overA2 + under * (1 - overA2)) = linear2srgb(over) * over.a + linear2srgb(under) * (1 - over.a)
    // ^ gamma correct blending with new alpha             ^ gamma incorrect blending with old alpha
    over.a = clamp_to_unit_float(
        (srgb2linear(linear2srgb(over_lumininace) * over.a + linear2srgb(under_luminance) * (1.0f - over.a)) - under_luminance) /
        (over_lumininace - under_luminance));
    return over;
}

float4
foreground_contrast(float4 over, float3 under, float text_contrast, float text_gamma_adjustment) {
    if (TEXT_NEW_GAMMA) return foreground_contrast_new(over, under, text_contrast, text_gamma_adjustment);
    return foreground_contrast_old(over, under);
}

float4
load_text_foreground_color(float3 sprite_pos, float colored_sprite, float use_color_atlas, float3 cell_foreground) {
    // For colored sprites use the color from the sprite rather than the text foreground
    // Return non-premultiplied foreground color. F1: colored text lives in the
    // RGBA color atlas; mono glyphs (and everything under the kill switch) stay
    // in the R8 mono atlas (swizzled coverage->.a at texture creation).
    float4 text_fg = (use_color_atlas > 0.5f) ? color_sprites.Sample(sprite_sampler, sprite_pos) : sprites.Sample(sprite_sampler, sprite_pos);
    return float4(lerp(cell_foreground, text_fg.xyz, colored_sprite), text_fg.w);
}

float4
calculate_premul_foreground_from_sprites(
    float3 sprite_pos,
    float3 underline_pos,
    float3 cursor_pos,
    float3 strike_pos,
    uint underline_exclusion_pos,
    float use_color_atlas,
    float4 text_fg,
    float3 decoration_fg,
    float4 cursor_color_premult,
    float effective_text_alpha, ) {
    // Return premul foreground color from decorations (cursor, underline, strikethrough)
    float underline_alpha = sprites.Sample(sprite_sampler, underline_pos).w;
    // The exclusion mask lives in the text glyph's own atlas (color or mono).
    uint width, height, layers;
    float underline_exclusion;
    if (use_color_atlas > 0.5f) {
        color_sprites.GetDimensions(width, height, layers);
        underline_exclusion = color_sprites.Load(int4(int(sprite_pos.x * float(width)), int(underline_exclusion_pos), int(sprite_pos.z), 0)).w;
    } else {
        sprites.GetDimensions(width, height, layers);
        underline_exclusion = sprites.Load(int4(int(sprite_pos.x * float(width)), int(underline_exclusion_pos), int(sprite_pos.z), 0)).w;
    }

    underline_alpha *= 1.0 - underline_exclusion;
    float strike_alpha = sprites.Sample(sprite_sampler, strike_pos).w;
    float cursor_alpha = sprites.Sample(sprite_sampler, cursor_pos).w;

    float combined_alpha = min(text_fg.w + strike_alpha, 1.0);

    float4 ans = alpha_blend(float4(text_fg.rgb, combined_alpha * effective_text_alpha), float4(decoration_fg, underline_alpha * effective_text_alpha));

    return lerp(ans, cursor_color_premult, cursor_alpha * cursor_color_premult.w);
}

float4
adjust_foreground_contrast_with_background(float4 text_fg, float3 bg, float text_contrast, float text_gamma_adjustment) {
    return foreground_contrast(text_fg, bg, text_contrast, text_gamma_adjustment);
}

[shader("fragment")]
float4
fragment_main(VertexOutput vo, uniform float text_contrast, uniform float text_gamma_adjustment,
              uniform float text_edr_boost, )
    : SV_Target {
    float4 ans_premul = 0;
    if (!ONLY_FOREGROUND) ans_premul = vo.effective_background_premul;

    if (!ONLY_BACKGROUND) {
        // blend in the foreground color
        float4 text_fg = load_text_foreground_color(vo.sprite_pos, vo.colored_sprite, vo.use_color_atlas, vo.cell_foreground);
        text_fg = adjust_foreground_contrast_with_background(text_fg, vo.background, text_contrast, text_gamma_adjustment);
        // The EDR text boost (fork lever): scale the RESOLVED foreground above
        // SDR reference white, so glyphs can use the display's extended range.
        // Deliberately confined to the two foreground COLOURS: alpha carries
        // glyph coverage, so boosting it would fight text_composition_strategy
        // rather than brighten anything; the cursor colour is a surface, not
        // text; and the background must stay put or the whole window glows.
        // The C side already clamps the multiplier to this frame's headroom
        // and hands over exactly 1.0 whenever EDR is not engaged, which is why
        // this needs no branch and no function constant -- it is arithmetic
        // that vanishes at 1.0, keeping every variant byte-identical when the
        // lever is unset.
        text_fg.rgb *= text_edr_boost;
        float4 text_fg_premul = calculate_premul_foreground_from_sprites(
            vo.sprite_pos,
            vo.underline_pos,
            vo.cursor_pos,
            vo.strike_pos,
            vo.underline_exclusion_pos,
            vo.use_color_atlas,
            text_fg,
            vo.decoration_fg * text_edr_boost,
            vo.cursor_color_premult,
            vo.effective_text_alpha);
        if (ONLY_FOREGROUND) ans_premul = text_fg_premul;
        else ans_premul = alpha_blend_premul(text_fg_premul, ans_premul);
    }

    // The fork epilogue (mirrors border_fork.slang / the retired MSL's exit):
    // primaries before transfer — the matrix operates on linear values and
    // commutes with the premultiplied alpha and with the ROP's linear blend.
    if (target_primaries_is_p3) ans_premul.rgb = srgb_to_p3(ans_premul.rgb);
    if (target_color_space == TARGET_SPACE_ENCODE_SRGB) {
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
