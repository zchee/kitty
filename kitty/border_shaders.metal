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

inline float zero_or_one(float x) { return step(1.0f, x); }
inline float if_one_then(float cond, float t, float e) { return mix(e, t, cond); }
inline float3 if_one_then(float cond, float3 t, float3 e) { return mix(e, t, cond); }
inline float4 vec4_premul(float3 rgb, float a) { return float4(rgb * a, a); }

struct BorderUniforms {
    uint colors[9];
    float background_opacity;
    float gamma_lut[256];
};

// Must match C struct BorderRect layout exactly (56 bytes)
struct BorderRect {
    float4 rect;           // left, top, right, bottom (offset 0, 16 bytes)
    uint4 px;              // px.left, px.top, px.right, px.bottom (offset 16, 16 bytes)
    uint color;            // offset 32, 4 bytes
    uint _pad0;            // offset 36, 4 bytes (alignment padding)
    uint2 border_type;     // long long = 8 bytes (offset 40)
    uint horizontal;       // bool = 1 byte but aligned to 4 (offset 48)
    uint _pad1;            // padding to 56 bytes
};

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
    constant BorderRect *rects [[buffer(0)]],
    constant BorderUniforms& uniforms [[buffer(1)]]
) {
    BorderVertexOut out;
    constant BorderRect& r = rects[iid];

    uint2 pos = border_pos_map[vid];
    out.position = float4(r.rect[pos.x], r.rect[pos.y], 0, 1);

    float3 window_bg = as_color_vector(r.color, 24, uniforms.gamma_lut);
    uint rc = r.color & 0xFFu;
    float3 color3 = as_color_vector(uniforms.colors[rc], 16, uniforms.gamma_lut);

    float is_window_bg = is_integer_value(rc, 3); // WINDOW_BACKGROUND_PLACEHOLDER
    float is_default_bg = is_integer_value(rc, 0); // DEFAULT_BG
    color3 = if_one_then(is_window_bg, window_bg, color3);

    float is_not_a_border = zero_or_one(abs(
        (float(rc) - 1.0f) * (float(rc) - 2.0f) * (float(rc) - 4.0f)
    ));
    float final_opacity = if_one_then(is_not_a_border, uniforms.background_opacity, 1.0f);
    out.color_premul = vec4_premul(color3, final_opacity);

    return out;
}

fragment float4 border_fragment(BorderVertexOut in [[stage_in]]) {
    return in.color_premul;
}
