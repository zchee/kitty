/*
 * graphics_shaders.metal
 * Copyright (C) 2024 Kovid Goyal <kovid at kovidgoyal.net>
 *
 * Distributed under terms of the GPL3 license.
 *
 * MSL port of graphics_vertex.glsl + graphics_fragment.glsl (3 variants)
 * Also includes bgimage_vertex.glsl + bgimage_fragment.glsl
 */

#include <metal_stdlib>
using namespace metal;
// W27 GLSL-freezeout stage 1 (D4): pins GraphicsUniforms/BgimageUniforms
// (below) against the C-side MetalGraphicsUniforms/MetalBgimageUniforms
// (metal.m/metal_uniforms.h) at compile time.
#include "metal_uniforms.h"

inline float4 vec4_premul(float3 rgb, float a) { return float4(rgb * a, a); }
inline float4 vec4_premul(float4 rgba) { return float4(rgba.rgb * rgba.a, rgba.a); }

inline float4 alpha_blend(float4 over, float4 under) {
    float alpha = mix(under.a, 1.0f, over.a);
    float3 combined_color = mix(under.rgb * under.a, over.rgb, over.a);
    return float4(combined_color, alpha);
}

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
};
static_assert(sizeof(GraphicsUniforms) == sizeof(MetalGraphicsUniforms),
              "GraphicsUniforms drifted from MetalGraphicsUniforms");

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
        if (!IS_PREMULTIPLIED) {
            color = vec4_premul(color);
        }
    }
    return color;
}

// ==== BGIMAGE SHADER ====

struct BgimageUniforms {
    float4 sizes;       // window_w, window_h, image_w, image_h
    float4 positions;   // left, top, right, bottom
    float4 background;  // r, g, b, a
    float tiled;
};
static_assert(sizeof(BgimageUniforms) == sizeof(MetalBgimageUniforms),
              "BgimageUniforms drifted from MetalBgimageUniforms");

struct BgimageVertexOut {
    float4 position [[position]];
    float2 texcoord;
};

vertex BgimageVertexOut bgimage_vertex(
    uint vid [[vertex_id]],
    constant BgimageUniforms& uniforms [[buffer(0)]]
) {
    BgimageVertexOut out;

    // Texture coordinate mapping
    const float2 tex_map[4] = {
        float2(0, 1),  // LB
        float2(1, 1),  // RB
        float2(0, 0),  // LT
        float2(1, 0),  // RT
    };

    // Position mapping using strip order
    float l = uniforms.positions[0], t = uniforms.positions[1];
    float r = uniforms.positions[2], b = uniforms.positions[3];
    const float2 pos_map[4] = {
        float2(l, b),
        float2(r, b),
        float2(l, t),
        float2(r, t),
    };

    float2 tex_coords = tex_map[vid];

    // Tiling factor
    float tiled = uniforms.tiled;
    float scale_x = tiled * (uniforms.sizes[0] / uniforms.sizes[2]) + (1.0f - tiled);
    float scale_y = tiled * (uniforms.sizes[1] / uniforms.sizes[3]) + (1.0f - tiled);
    out.texcoord = float2(tex_coords.x * scale_x, tex_coords.y * scale_y);
    out.position = float4(pos_map[vid], 0, 1);
    return out;
}

fragment float4 bgimage_fragment(
    BgimageVertexOut in [[stage_in]],
    texture2d<float> image [[texture(0)]],
    constant BgimageUniforms& uniforms [[buffer(0)]]
) {
    constexpr sampler s(mag_filter::linear, min_filter::linear);
    float4 color = image.sample(s, in.texcoord);
    return alpha_blend(color, uniforms.background);
}
