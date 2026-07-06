/*
 * border_shaders.metal
 * Copyright (C) 2024 Kovid Goyal <kovid at kovidgoyal.net>
 *
 * Distributed under terms of the GPL3 license.
 *
 * MSL port of border_vertex.glsl + border_fragment.glsl
 */

#include <metal_stdlib>
using namespace metal;

// C1: set on the opaque path so the fragment encodes linear->sRGB itself (the
// drawable is a plain BGRA8Unorm with no sRGB view). Unset on the layered path
// (output stays linear in the working surface; the resolve draw encodes).
constant bool SRGB_ENCODE_OUTPUT [[function_constant(0)]];

inline float linear2srgb(float x) {
    float lower = 12.92f * x;
    float upper = 1.055f * pow(x, 1.0f / 2.4f) - 0.055f;
    return mix(lower, upper, step(0.0031308f, x));
}

inline float zero_or_one(float x) { return step(1.0f, x); }
inline float if_one_then(float cond, float t, float e) { return mix(e, t, cond); }
inline float3 if_one_then(float cond, float3 t, float3 e) { return mix(e, t, cond); }
inline float4 vec4_premul(float3 rgb, float a) { return float4(rgb * a, a); }

struct BorderUniforms {
    uint colors[9];
    float background_opacity;
    float gamma_lut[256];
};

// The C-side BorderRect (kitty/state.h) is 56 bytes with natural C
// alignment; an MSL struct containing float4 is padded to a 64-byte stride
// and 56 is not 16-aligned, so neither struct indexing nor float4 loads may
// be used on the instance array. Instances are addressed with an explicit
// byte stride and read as 4-byte scalars (offset 0: rect floats, offset 32:
// color).
#define BORDER_RECT_C_STRIDE 56u

struct BorderVertexOut {
    float4 position [[position]];
    float4 color_premul;
};

// Vertex mapping: Fan(RT,RB,LB,LT) → Strip(LB,RB,LT,RT)
constant uint2 border_pos_map[4] = {
    uint2(0, 3),  // LEFT, BOTTOM → fan[2]
    uint2(2, 3),  // RIGHT, BOTTOM → fan[1]
    uint2(0, 1),  // LEFT, TOP → fan[3]
    uint2(2, 1),  // RIGHT, TOP → fan[0]
};

inline float to_color_f(uint c, constant float *gamma_lut) {
    return gamma_lut[c & 0xFFu];
}

inline float3 as_color_vector(uint c, int shift, constant float *gamma_lut) {
    return float3(to_color_f(c >> shift, gamma_lut),
                  to_color_f(c >> (shift - 8), gamma_lut),
                  to_color_f(c >> (shift - 16), gamma_lut));
}

inline float is_integer_value(uint c, int x) {
    return 1.0f - step(0.5f, abs(float(c) - float(x)));
}

vertex BorderVertexOut border_vertex(
    uint vid [[vertex_id]],
    uint iid [[instance_id]],
    constant uchar *rects_raw [[buffer(0)]],
    constant BorderUniforms& uniforms [[buffer(1)]]
) {
    BorderVertexOut out;
    constant float *rf = (constant float*)(rects_raw + iid * BORDER_RECT_C_STRIDE);
    float4 rect = float4(rf[0], rf[1], rf[2], rf[3]);
    uint rect_color = ((constant uint*)rf)[8]; // offsetof(BorderRect, color) == 32

    uint2 pos = border_pos_map[vid];
    out.position = float4(rect[pos.x], rect[pos.y], 0, 1);

    float3 window_bg = as_color_vector(rect_color, 24, uniforms.gamma_lut);
    uint rc = rect_color & 0xFFu;
    float3 color3 = as_color_vector(uniforms.colors[rc], 16, uniforms.gamma_lut);

    float is_window_bg = is_integer_value(rc, 3); // WINDOW_BACKGROUND_PLACEHOLDER
    color3 = if_one_then(is_window_bg, window_bg, color3);

    // border quads and tab bar edge strips draw opaque (GL parity:
    // ACTIVE=1, INACTIVE=2, BELL=4, TAB_BAR_EDGE_LEFT=7, TAB_BAR_EDGE_RIGHT=8)
    float is_not_a_border = zero_or_one(abs(
        (float(rc) - 1.0f) * (float(rc) - 2.0f) * (float(rc) - 4.0f) *
        (float(rc) - 7.0f) * (float(rc) - 8.0f)
    ));
    float final_opacity = if_one_then(is_not_a_border, uniforms.background_opacity, 1.0f);
    out.color_premul = vec4_premul(color3, final_opacity);

    return out;
}

fragment float4 border_fragment(BorderVertexOut in [[stage_in]]) {
    float4 c = in.color_premul;
    if (SRGB_ENCODE_OUTPUT) {
        // Opaque borders draw with blend disabled, so encode the premultiplied
        // channels 1:1 (matching a BGRA8Unorm_sRGB attachment write).
        float3 lin = clamp(c.rgb, 0.0f, 1.0f);
        c.rgb = float3(linear2srgb(lin.r), linear2srgb(lin.g), linear2srgb(lin.b));
    }
    return c;
}
