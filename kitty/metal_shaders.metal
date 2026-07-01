/*
 * metal_shaders.metal
 * Copyright (C) 2024 Kovid Goyal <kovid at kovidgoyal.net>
 *
 * Distributed under terms of the GPL3 license.
 *
 * Shared Metal Shading Language utilities — ports of:
 *   utils.glsl, alpha_blend.glsl, linear2srgb.glsl
 */

#include <metal_stdlib>
using namespace metal;

// ---- utils.glsl ----

// Return 0 if x < 1 otherwise 1
#define zero_or_one(x) step(1.f, (x))
// condition must be zero or one. When 1 thenval is returned otherwise elseval
#define if_one_then(condition, thenval, elseval) mix((elseval), (thenval), (condition))
// a < b ? thenval : elseval
#define if_less_than(a, b, thenval, elseval) mix((thenval), (elseval), step((b), (a)))

inline float4 vec4_premul(float3 rgb, float a) {
    return float4(rgb * a, a);
}

inline float4 vec4_premul(float4 rgba) {
    return float4(rgba.rgb * rgba.a, rgba.a);
}

// ---- alpha_blend.glsl ----

inline float4 alpha_blend(float4 over, float4 under) {
    // Alpha blend two colors returning the resulting color pre-multiplied by its alpha.
    // See https://en.wikipedia.org/wiki/Alpha_compositing
    float alpha = mix(under.a, 1.0f, over.a);
    float3 combined_color = mix(under.rgb * under.a, over.rgb, over.a);
    return float4(combined_color, alpha);
}

inline float4 alpha_blend_premul(float4 over, float4 under) {
    // Same as alpha_blend() except both over and under are premultiplied.
    float inv_over_alpha = 1.0f - over.a;
    float alpha = over.a + under.a * inv_over_alpha;
    return float4(over.rgb + under.rgb * inv_over_alpha, alpha);
}

inline float4 alpha_blend_premul(float4 over, float3 under) {
    // alpha_blend_premul with under_alpha = 1
    float inv_over_alpha = 1.0f - over.a;
    return float4(over.rgb + under.rgb * inv_over_alpha, 1.0);
}

// ---- linear2srgb.glsl ----

inline float srgb2linear(float x) {
    float lower = x / 12.92f;
    float upper = pow((x + 0.055f) / 1.055f, 2.4f);
    return mix(lower, upper, step(0.04045f, x));
}

inline float linear2srgb(float x) {
    float lower = 12.92f * x;
    float upper = 1.055f * pow(x, 1.0f / 2.4f) - 0.055f;
    return mix(lower, upper, step(0.0031308f, x));
}

inline float3 linear2srgb(float3 x) {
    float3 lower = 12.92f * x;
    float3 upper = 1.055f * pow(x, float3(1.0f / 2.4f)) - 0.055f;
    return mix(lower, upper, step(0.0031308f, x));
}

inline float3 srgb2linear(float3 c) {
    return float3(srgb2linear(c.r), srgb2linear(c.g), srgb2linear(c.b));
}

// ---- Shared vertex structure for simple quad rendering ----

struct QuadVertexOut {
    float4 position [[position]];
    float2 texcoord;
};

// Quad vertex positions for triangle strip (fan vertex order 0,1,2,3 → strip order 3,0,2,1)
// Maps gl_VertexID to NDC positions for a full-screen quad
constant float2 quad_positions[4] = {
    float2(-1.0, -1.0),  // bottom-left  (strip vertex 0)
    float2( 1.0, -1.0),  // bottom-right (strip vertex 1)
    float2(-1.0,  1.0),  // top-left     (strip vertex 2)
    float2( 1.0,  1.0),  // top-right    (strip vertex 3)
};

constant float2 quad_texcoords[4] = {
    float2(0.0, 1.0),  // bottom-left
    float2(1.0, 1.0),  // bottom-right
    float2(0.0, 0.0),  // top-left
    float2(1.0, 0.0),  // top-right
};
