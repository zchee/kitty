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
// one place, shared with cell_shaders.metal and the C side (border_shaders.metal
// shared it too until its W3i retirement into generated border_fork variants).
#include "color_transfer.metal.h"
// W27 GLSL-freezeout stage 1 (D4): pins BlitUniforms/ScreenshotUniforms
// (below) against the C-side MetalBlitUniforms/MetalScreenshotUniforms
// (metal.m/metal_uniforms.h) at compile time.
#include "metal_uniforms.h"

// ---- Blit uniforms ----

struct BlitUniforms {
    float4 src_rect;   // left, top, right, bottom in texture coords
    float4 dest_rect;  // left, top, right, bottom in NDC
};
static_assert(sizeof(BlitUniforms) == sizeof(MetalBlitUniforms),
              "BlitUniforms drifted from MetalBlitUniforms");

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

// W3f: the screenshot vertex+fragment pair now comes from
// kitty/shaders/screenshot.slang (generated MSL keeps the same entry-point
// names, so the hand-written pair had to leave in the same commit -- the
// metallib rejects duplicate symbols). The hand-written fragment sampled a
// 2x2 grid of LINEAR taps at +/-0.25 texel (a tent over 3x3) and linearized
// AFTER blending; upstream Gathers the exact 2x2 texel quad and linearizes
// each texel first. Its uniforms struct and the ScreenshotUniforms
// static_assert went with it; the C-side MetalScreenshotUniforms now pins
// against the generated blocks in metal.m.
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
// W27 P3.5: ON when att1 is tagged Display P3 (wide drawable arms). The
// layered working surface holds linear sRGB-primaries premultiplied values;
// this resolve is the single primaries-conversion point for the whole layered
// stack. See kitty/color_transfer.metal.h.
constant bool TARGET_PRIMARIES_IS_P3 [[function_constant(1)]];

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
    // Primaries before transfer: one linear-space matrix for the whole layered
    // stack (commutes with the premultiplied alpha, so no unpremul needed).
    if (TARGET_PRIMARIES_IS_P3) work.rgb = srgb_to_p3(work.rgb);
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
