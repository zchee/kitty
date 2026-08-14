/*
 * graphics_shaders.metal
 * Copyright (C) 2024 Kovid Goyal <kovid at kovidgoyal.net>
 *
 * Distributed under terms of the GPL3 license.
 *
 * MSL port of graphics_vertex.glsl + graphics_fragment.glsl (3 variants)
 * (bgimage lived here too until W3e moved it to generated MSL)
 */

#include <metal_stdlib>
using namespace metal;
// W27 GLSL-freezeout stage 1 (D4): pins GraphicsUniforms (below) against the
// C-side MetalGraphicsUniforms (metal.m/metal_uniforms.h) at compile time.
#include "metal_uniforms.h"

inline float4 vec4_premul(float3 rgb, float a) { return float4(rgb * a, a); }
inline float4 vec4_premul(float4 rgba) { return float4(rgba.rgb * rgba.a, rgba.a); }

inline float4 alpha_blend_premul(float4 over, float4 under) {
    float inv = 1.0f - over.a;
    return float4(over.rgb + under.rgb * inv, over.a + under.a * inv);
}

// ==== GRAPHICS SHADER (IMAGE / PREMULT / ALPHA_MASK) ====

// Function constants for variant selection
constant bool IS_ALPHA_MASK [[function_constant(0)]];
constant bool IS_PREMULTIPLIED [[function_constant(1)]];

// G2: per-instance rect arrays (one image ref per instance), indexed by
// instance_id. MAX_IMAGE_INSTANCES must match graphics_vertex.glsl / shaders.c.
constant constexpr int MAX_IMAGE_INSTANCES = 16;
struct GraphicsUniforms {
    float4 src_rects[MAX_IMAGE_INSTANCES];
    float4 dest_rects[MAX_IMAGE_INSTANCES];
    float extra_alpha;
    float3 amask_fg;
    float4 amask_bg_premult;
    // W27 P4.2 tone-map inputs (see MetalGraphicsUniforms).
    float edr_headroom;
    float src_is_hdr;
    float src_max_component;
};
static_assert(sizeof(GraphicsUniforms) == sizeof(MetalGraphicsUniforms),
              "GraphicsUniforms drifted from MetalGraphicsUniforms");

// W27 P4.2 tone map (ADR-0022 decision 5). `c` is linear extended-sRGB, `hr` is
// the screen's current EDR headroom, `src_max` the image's largest component.
//
//   policy (b), soft knee -- taken iff the source actually exceeds the headroom:
//     a piecewise-linear shoulder hinged at k = 0.8*hr. Below k the mapping is
//     the identity, so the whole SDR range and the bottom of the EDR range are
//     reproduced exactly; above k the remaining source range [k, src_max] is
//     compressed linearly onto [k, hr]. Monotone by construction (both segments
//     have positive slope and they meet at k), which is what the ramp gate
//     checks -- a knee that inverted anywhere would read as banding.
//   policy (a), hard clamp -- when the source already fits, nothing is gained by
//     compressing it, so it passes through and only the ceiling applies.
//
// The final min() is the ceiling in both branches: correct-beyond-clamp. Values
// are clamped to kitty's own idea of the headroom rather than left for the
// system's screen-wide clamp, so behaviour at the limit is kitty-defined.
inline float3 tone_map_hdr(float3 c, float hr, float src_max) {
    if (src_max > hr) {
        const float k = 0.8f * hr;
        const float denom = src_max - k;
        // denom > 0 whenever src_max > hr >= k/0.8 > k, so the divide is safe;
        // the guard covers a degenerate hr <= 0 that should be impossible.
        if (denom > 0.0f) {
            const float slope = (hr - k) / denom;
            c = select(c, k + (c - k) * slope, c > float3(k));
        }
    }
    return min(c, float3(hr));
}

struct GraphicsVertexOut {
    float4 position [[position]];
    float2 texcoord;
};

// Same blit vertex mapping
constant int2 gfx_pos_map[4] = {
    int2(0, 3),  // left, bottom
    int2(2, 3),  // right, bottom
    int2(0, 1),  // left, top
    int2(2, 1),  // right, top
};

vertex GraphicsVertexOut graphics_vertex(
    uint vid [[vertex_id]],
    uint iid [[instance_id]],
    constant GraphicsUniforms& uniforms [[buffer(0)]]
) {
    GraphicsVertexOut out;
    int2 pos = gfx_pos_map[vid];
    float4 src_rect = uniforms.src_rects[iid];
    float4 dest_rect = uniforms.dest_rects[iid];
    out.texcoord = float2(src_rect[pos.x], src_rect[pos.y]);
    out.position = float4(dest_rect[pos.x], dest_rect[pos.y], 0, 1);
    return out;
}

fragment float4 graphics_fragment(
    GraphicsVertexOut in [[stage_in]],
    texture2d<float> image [[texture(0)]],
    constant GraphicsUniforms& uniforms [[buffer(0)]]
) {
    constexpr sampler s(mag_filter::nearest, min_filter::nearest);
    float4 color = image.sample(s, in.texcoord);

    if (IS_ALPHA_MASK) {
        color = float4(uniforms.amask_fg, color.r);
        color = vec4_premul(color);
        color = alpha_blend_premul(color, uniforms.amask_bg_premult);
    } else {
        color.a *= uniforms.extra_alpha;
        // W27 P4.2 tone map (ADR-0022 decision 5), applied to the LINEAR colour
        // BEFORE premultiplication and only for f=3232 sources -- an SDR image
        // takes the identical path it always did, byte for byte.
        if (uniforms.src_is_hdr > 0.5f) {
            color.rgb = tone_map_hdr(color.rgb, uniforms.edr_headroom, uniforms.src_max_component);
        }
        if (!IS_PREMULTIPLIED) {
            color = vec4_premul(color);
        }
    }
    return color;
}

// W3e: bgimage's two stages now come from kitty/shaders/bgimage.slang. Its
// hand-written fragment sampled through a constexpr clamp-to-edge sampler, so
// tiled background images never tiled on this fork's Metal; the generated
// fragment takes a runtime sampler bound from the recorded GL wrap state.
