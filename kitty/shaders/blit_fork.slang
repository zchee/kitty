#language slang 2026
// Copyright (C) 2026 Kovid Goyal <kovid at kovidgoyal.net>
// Distributed under terms of the GPLv3 license.
//
// FORK-OWNED wrapper (the tenth and final migration of the slang
// convergence): upstream blit.slang through the generated pipeline,
// retiring the hand-written blit entries in kitty/blit_shaders.metal.
// Structure mirrors upstream blit.slang 1:1; the fork deltas are:
// 1. The texcoord v endpoints are SWAPPED relative to upstream: the C
//    callers bake GL's bottom-up texture orientation into src_rect, and
//    Metal render passes write the source textures top-down, so v must
//    read the OPPOSITE rect edge to cancel the flip (the retired MSL's
//    blit_tex_map). dest_rect (NDC) keeps upstream's mapping. Corner
//    order stays upstream's FAN (blit_common's vertex_pos_map); the
//    generated draw path replays it through the fan->strip index remap.
// 2. Separate Texture2D + SamplerState declarations (the defect-B
//    discipline, ADR-0035); metal.m binds nearest+clamp from the W3e
//    sampler cache, matching the retired constexpr sampler.
// 3. The unpremultiply guards alpha == 0 (upstream divides unguarded);
//    the retired MSL carried the same guard.
import utils;
import linear2srgb;

struct VSOutput {
    float2 texcoord : TEXCOORD;
    float4 position : SV_Position;
};

#define left 0
#define top 1
#define right 2
#define bottom 3

static const int2 vertex_pos_map[4] = { { right, top }, { right, bottom }, { left, bottom }, { left, top } };
// fork delta 1: v reads the opposite edge (a top corner samples src_rect's
// bottom and vice versa).
static const int2 vertex_tex_map[4] = { { right, bottom }, { right, top }, { left, top }, { left, bottom } };

[shader("vertex")]
VSOutput
vertex_main(uint vertex_id: SV_VertexID, uniform float4 src_rect, uniform float4 dest_rect, ) {
    int2 pos = vertex_pos_map[vertex_id];
    int2 tex = vertex_tex_map[vertex_id];
    return { float2(src_rect[tex.x], src_rect[tex.y]), float4(dest_rect[pos.x], dest_rect[pos.y], 0.0, 1.0) };
}

Texture2D image;
SamplerState image_sampler;

[shader("fragment")]
float4
fragment_main(float2 texcoord: TEXCOORD)
    : SV_Target {
    float4 color_premul = image.Sample(image_sampler, texcoord);
    float3 rgb = color_premul.a > 0.0f ? color_premul.rgb / color_premul.a : float3(0.0f);
    return vec4_premul(linear2srgb(rgb), color_premul.a);
}
