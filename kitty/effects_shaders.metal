/*
 * effects_shaders.metal
 * Copyright (C) 2024 Kovid Goyal <kovid at kovidgoyal.net>
 *
 * Distributed under terms of the GPL3 license.
 *
 * MSL port of tint, trail, rounded_rect vertex/fragment shaders
 */

#include <metal_stdlib>
using namespace metal;

inline float4 vec4_premul(float3 rgb, float a) { return float4(rgb * a, a); }

inline float4 alpha_blend(float4 over, float4 under) {
    float alpha = mix(under.a, 1.0f, over.a);
    float3 combined_color = mix(under.rgb * under.a, over.rgb, over.a);
    return float4(combined_color, alpha);
}

// ==== TINT SHADER ====

struct TintUniforms {
    float4 tint_color;
    float4 edges;
};

struct TintVertexOut {
    float4 position [[position]];
};

// Strip mapping: fan(LT,LB,RB,RT) → strip(LB,RB,LT,RT)
vertex TintVertexOut tint_vertex(
    uint vid [[vertex_id]],
    constant TintUniforms& uniforms [[buffer(0)]]
) {
    TintVertexOut out;
    float l = uniforms.edges[0], t = uniforms.edges[1];
    float r = uniforms.edges[2], b = uniforms.edges[3];
    const float2 pos_map[4] = {
        float2(l, b),  // strip 0: LB
        float2(r, b),  // strip 1: RB
        float2(l, t),  // strip 2: LT
        float2(r, t),  // strip 3: RT
    };
    out.position = float4(pos_map[vid], 0, 1);
    return out;
}

fragment float4 tint_fragment(
    TintVertexOut in [[stage_in]],
    constant TintUniforms& uniforms [[buffer(0)]]
) {
    return uniforms.tint_color;
}

// ==== TRAIL SHADER ====

struct TrailUniforms {
    float4 x_coords;
    float4 y_coords;
    float2 cursor_edge_x;
    float2 cursor_edge_y;
    float3 trail_color;
    float trail_opacity;
};

struct TrailVertexOut {
    float4 position [[position]];
    float2 frag_pos;
};

vertex TrailVertexOut trail_vertex(
    uint vid [[vertex_id]],
    constant TrailUniforms& uniforms [[buffer(0)]]
) {
    TrailVertexOut out;
    float2 pos = float2(uniforms.x_coords[vid], uniforms.y_coords[vid]);
    out.position = float4(pos, 1.0, 1.0);
    out.frag_pos = pos;
    return out;
}

fragment float4 trail_fragment(
    TrailVertexOut in [[stage_in]],
    constant TrailUniforms& uniforms [[buffer(0)]]
) {
    float opacity = uniforms.trail_opacity;
    float in_x = step(uniforms.cursor_edge_x[0], in.frag_pos.x) * step(in.frag_pos.x, uniforms.cursor_edge_x[1]);
    float in_y = step(uniforms.cursor_edge_y[1], in.frag_pos.y) * step(in.frag_pos.y, uniforms.cursor_edge_y[0]);
    opacity *= 1.0f - in_x * in_y;
    return float4(uniforms.trail_color * opacity, opacity);
}

// ==== ROUNDED RECT SHADER ====

struct RoundedRectUniforms {
    float4 color;
    float4 background_color;
    float4 rect;     // x, y, w, h in pixels
    float2 params;   // thickness, corner_radius
};

struct RoundedRectVertexOut {
    float4 position [[position]];
};

vertex RoundedRectVertexOut rounded_rect_vertex(
    uint vid [[vertex_id]]
) {
    RoundedRectVertexOut out;
    const float4 dest_rect = float4(-1, 1, 1, -1);
    const int2 pos_map[4] = {
        int2(0, 3),  // left, bottom
        int2(2, 3),  // right, bottom
        int2(0, 1),  // left, top
        int2(2, 1),  // right, top
    };
    int2 pos = pos_map[vid];
    out.position = float4(dest_rect[pos.x], dest_rect[pos.y], 0, 1);
    return out;
}

float rounded_rectangle_sdf(float2 p, float2 b, float r) {
    float2 q = abs(p) - b;
    return length(max(q, 0.0f)) + min(max(q.x, q.y), 0.0f) - r;
}

fragment float4 rounded_rect_fragment(
    RoundedRectVertexOut in [[stage_in]],
    constant RoundedRectUniforms& uniforms [[buffer(0)]]
) {
    float2 size = uniforms.rect.ba;
    float2 origin = uniforms.rect.xy;
    float thickness = uniforms.params[0];
    float corner_radius = uniforms.params[1];
    float2 position = in.position.xy - size / 2.0f - origin;
    float dist = rounded_rectangle_sdf(position, size * 0.5f - corner_radius, corner_radius);

    float outer_edge = -dist, inner_edge = outer_edge - thickness;
    const float step_size = 1.0f;
    float al = smoothstep(-step_size, step_size, outer_edge) - smoothstep(-step_size, step_size, inner_edge);
    float4 ans = uniforms.color;
    ans.a *= al;
    return alpha_blend(ans, uniforms.background_color);
}
