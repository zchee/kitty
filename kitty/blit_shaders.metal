/*
 * blit_shaders.metal
 * Copyright (C) 2024 Kovid Goyal <kovid at kovidgoyal.net>
 *
 * Distributed under terms of the GPL3 license.
 *
 * MSL port of blit_vertex.glsl + blit_fragment.glsl + blit_common.glsl
 * Also includes screenshot_vertex.glsl + screenshot_fragment.glsl
 */

#include <metal_stdlib>
using namespace metal;

// W27 P3.4: the sRGB transfer pair and the target-space vocabulary now live in
// one place, shared with cell_shaders.metal, border_shaders.metal and the C
// side that specializes these fragments.
#include "color_transfer.metal.h"

// ---- Blit uniforms ----

struct BlitUniforms {
    float4 src_rect;   // left, top, right, bottom in texture coords
    float4 dest_rect;  // left, top, right, bottom in NDC
};

struct BlitVertexOut {
    float4 position [[position]];
    float2 texcoord;
};

// Vertex position mapping: GLSL uses GL_TRIANGLE_FAN with 4 verts
// Metal uses triangle strip. Reorder: fan(0,1,2,3) = (RT,RB,LB,LT) → strip(LT,RT,LB,RB)
//
// GLSL blit_common.glsl vertex_pos_map:
//   0: (right, top)
//   1: (right, bottom)
//   2: (left, bottom)
//   3: (left, top)
//
// For triangle strip we need: LB, RB, LT, RT → indices 2, 1, 3, 0
// Which maps to: (left,bottom), (right,bottom), (left,top), (right,top)

constant int2 blit_pos_map[4] = {
    int2(0, 3),  // left, bottom  → src_rect[left], src_rect[bottom]
    int2(2, 3),  // right, bottom → src_rect[right], src_rect[bottom]
    int2(0, 1),  // left, top     → src_rect[left], src_rect[top]
    int2(2, 1),  // right, top    → src_rect[right], src_rect[top]
};

// The C callers bake GL's bottom-up texture orientation into src_rect
// (e.g. stop_os_window_rendering passes top=sy, bottom=0). Metal render
// passes write the layers FBO and the drawable top-down, so the texcoord
// y endpoints must be swapped to cancel that flip. dest_rect (NDC) is
// orientation-independent and keeps the original mapping.
constant int2 blit_tex_map[4] = {
    int2(0, 1),  // left, bottom  → v from src_rect[top]
    int2(2, 1),  // right, bottom → v from src_rect[top]
    int2(0, 3),  // left, top     → v from src_rect[bottom]
    int2(2, 3),  // right, top    → v from src_rect[bottom]
};

// ---- Blit Vertex Shader ----

vertex BlitVertexOut blit_vertex(
    uint vid [[vertex_id]],
    constant BlitUniforms& uniforms [[buffer(0)]]
) {
    BlitVertexOut out;
    int2 pos = blit_pos_map[vid];
    int2 tex = blit_tex_map[vid];
    out.texcoord = float2(uniforms.src_rect[tex.x], uniforms.src_rect[tex.y]);
    out.position = float4(uniforms.dest_rect[pos.x], uniforms.dest_rect[pos.y], 0, 1);
    return out;
}

// ---- Blit Fragment Shader ----
// Converts from linear premultiplied → sRGB premultiplied for final output

fragment float4 blit_fragment(
    BlitVertexOut in [[stage_in]],
    texture2d<float> image [[texture(0)]]
) {
    constexpr sampler s(mag_filter::nearest, min_filter::nearest);
    float4 color_premul = image.sample(s, in.texcoord);
    // Unpremultiply, convert linear→sRGB, re-premultiply
    float3 rgb = color_premul.a > 0.0f ? color_premul.rgb / color_premul.a : float3(0.0f);
    float3 srgb = linear2srgb(rgb);
    return float4(srgb * color_premul.a, color_premul.a);
}

// ---- Screenshot uniforms ----

struct ScreenshotUniforms {
    float4 src_rect;
    float4 dest_rect;
    float2 src_size;
};

// ---- Screenshot Vertex Shader ----

vertex BlitVertexOut screenshot_vertex(
    uint vid [[vertex_id]],
    constant ScreenshotUniforms& uniforms [[buffer(0)]]
) {
    BlitVertexOut out;
    int2 pos = blit_pos_map[vid];
    int2 tex = blit_tex_map[vid];
    out.texcoord = float2(uniforms.src_rect[tex.x], uniforms.src_rect[tex.y]);
    out.position = float4(uniforms.dest_rect[pos.x], uniforms.dest_rect[pos.y], 0, 1);
    return out;
}

// ---- Screenshot Fragment Shader ----
// Proper downscaling with sRGB-aware 2×2 sampling

fragment float4 screenshot_fragment(
    BlitVertexOut in [[stage_in]],
    texture2d<float> image [[texture(0)]],
    constant ScreenshotUniforms& uniforms [[buffer(0)]]
) {
    constexpr sampler s(mag_filter::linear, min_filter::linear);
    float2 texel_size = 1.0f / uniforms.src_size;
    float2 tc = in.texcoord;

    // Sample a 2x2 grid for better quality downscaling
    float4 s00 = image.sample(s, tc + float2(-0.25f, -0.25f) * texel_size);
    float4 s10 = image.sample(s, tc + float2( 0.25f, -0.25f) * texel_size);
    float4 s01 = image.sample(s, tc + float2(-0.25f,  0.25f) * texel_size);
    float4 s11 = image.sample(s, tc + float2( 0.25f,  0.25f) * texel_size);

    // Unpremultiply and convert to linear for each sample
    float3 linear00 = s00.a > 0.0f ? srgb2linear(s00.rgb / s00.a) : float3(0.0f);
    float3 linear10 = s10.a > 0.0f ? srgb2linear(s10.rgb / s10.a) : float3(0.0f);
    float3 linear01 = s01.a > 0.0f ? srgb2linear(s01.rgb / s01.a) : float3(0.0f);
    float3 linear11 = s11.a > 0.0f ? srgb2linear(s11.rgb / s11.a) : float3(0.0f);

    float avg_alpha = (s00.a + s10.a + s01.a + s11.a) * 0.25f;

    // Weight colors by alpha for proper transparency-aware downsampling
    float3 weighted_sum = linear00 * s00.a + linear10 * s10.a + linear01 * s01.a + linear11 * s11.a;
    float total_weight = s00.a + s10.a + s01.a + s11.a;
    float3 avg_linear = total_weight > 0.0f ? weighted_sum / total_weight : float3(0.0f);

    float3 srgb_color = linear2srgb(avg_linear);
    return float4(srgb_color, avg_alpha);
}

// ---- Layers resolve (M1: single-pass layered rendering) ----
// The Metal backend renders layered windows (transparency, bg image, graphics,
// overlays, cursor trail) into a MEMORYLESS RGBA16Unorm working surface (color
// attachment 0, tile-memory only — never DRAM) using the existing linear-space
// premultiplied-blend draws, then this resolve draw reads that surface via
// framebuffer fetch ([[color(0)]]) and writes the final sRGB drawable (color
// attachment 1) — all in ONE render pass. It performs exactly the same
// linear->sRGB premultiplied conversion the old BLIT pass did (blit_fragment),
// but reads the tile surface directly instead of sampling a DRAM texture, so
// the ~123 MB/frame RGBA16 round trip and the second pass are eliminated. The
// att0 value is written back unchanged so both attachments have a defined write
// (att0 is storeAction=DontCare, so the write is discarded). Apple-GPU only.
// W27 P3.2/P3.4: att1's target space. ENCODE_SRGB when att1 is the plain 8-bit
// target (the default drawable, or the BGRA8 capture offscreen) and the resolve
// must apply the transfer itself; LINEAR or ROP_ENCODES for the wide drawable
// candidates, which both mean "write the linear value the working surface
// already holds". See kitty/color_transfer.metal.h.
constant int TARGET_COLOR_SPACE [[function_constant(0)]];

struct LayersResolveOut {
    float4 work [[color(0)]];   // working surface, passthrough (discarded)
    float4 drawable [[color(1)]];
};

vertex float4 layers_resolve_vertex(uint vid [[vertex_id]]) {
    // Fullscreen triangle covering the whole attachment; no vertex buffer.
    float2 pos[3] = { float2(-1.0f, -1.0f), float2(3.0f, -1.0f), float2(-1.0f, 3.0f) };
    return float4(pos[vid], 0.0f, 1.0f);
}

fragment LayersResolveOut layers_resolve_fragment(float4 work [[color(0)]]) {
    LayersResolveOut o;
    o.work = work;
    // work is linear premultiplied (same contents the RGBA16 layers FBO held).
    if (target_encodes_in_shader(TARGET_COLOR_SPACE)) {
        float3 rgb = work.a > 0.0f ? work.rgb / work.a : float3(0.0f);
        float3 srgb = linear2srgb(rgb);
        o.drawable = float4(srgb * work.a, work.a);
    } else {
        // Linear premultiplied straight through: that is what an
        // extended-LINEAR-tagged drawable stores, and what the _srgb XR ROP
        // expects to encode.
        o.drawable = work;
    }
    return o;
}
