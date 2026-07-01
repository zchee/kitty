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

// Include shared utilities via header (compiled into same .metallib)
// Re-declare needed functions inline since Metal doesn't support cross-file includes

inline float srgb2linear_f(float x) {
    float lower = x / 12.92f;
    float upper = pow((x + 0.055f) / 1.055f, 2.4f);
    return mix(lower, upper, step(0.04045f, x));
}

inline float linear2srgb_f(float x) {
    float lower = 12.92f * x;
    float upper = 1.055f * pow(x, 1.0f / 2.4f) - 0.055f;
    return mix(lower, upper, step(0.0031308f, x));
}

inline float3 linear2srgb_v(float3 x) {
    float3 lower = 12.92f * x;
    float3 upper = 1.055f * pow(x, float3(1.0f / 2.4f)) - 0.055f;
    return mix(lower, upper, step(0.0031308f, x));
}

inline float3 srgb2linear_v(float3 c) {
    return float3(srgb2linear_f(c.r), srgb2linear_f(c.g), srgb2linear_f(c.b));
}

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
    float3 srgb = linear2srgb_v(rgb);
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
    float3 linear00 = s00.a > 0.0f ? srgb2linear_v(s00.rgb / s00.a) : float3(0.0f);
    float3 linear10 = s10.a > 0.0f ? srgb2linear_v(s10.rgb / s10.a) : float3(0.0f);
    float3 linear01 = s01.a > 0.0f ? srgb2linear_v(s01.rgb / s01.a) : float3(0.0f);
    float3 linear11 = s11.a > 0.0f ? srgb2linear_v(s11.rgb / s11.a) : float3(0.0f);

    float avg_alpha = (s00.a + s10.a + s01.a + s11.a) * 0.25f;

    // Weight colors by alpha for proper transparency-aware downsampling
    float3 weighted_sum = linear00 * s00.a + linear10 * s10.a + linear01 * s01.a + linear11 * s11.a;
    float total_weight = s00.a + s10.a + s01.a + s11.a;
    float3 avg_linear = total_weight > 0.0f ? weighted_sum / total_weight : float3(0.0f);

    float3 srgb_color = linear2srgb_v(avg_linear);
    return float4(srgb_color, avg_alpha);
}
