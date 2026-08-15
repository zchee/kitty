/*
 * blit_shaders.metal
 * Copyright (C) 2024 Kovid Goyal <kovid at kovidgoyal.net>
 *
 * Distributed under terms of the GPL3 license.
 *
 * The layers-resolve pass (M1 single-pass layered rendering). The blit and
 * screenshot entries this file once carried both migrated to generated MSL
 * (kitty/shaders/blit_fork.slang, kitty/shaders/screenshot.slang).
 */

#include <metal_stdlib>
using namespace metal;

// W27 P3.4: the sRGB transfer pair and the target-space vocabulary now live in
// one place, shared with the C side and the generated shader modules.
#include "color_transfer.metal.h"

// The blit vertex+fragment pair now comes from kitty/shaders/blit_fork.slang
// (the tenth migration -- generated MSL entries blit_fork_vertex/_fragment).
// The wrapper carries the fork deltas the retired pair encoded: the texcoord
// y-flip (Metal writes source textures top-down), the alpha==0 unpremultiply
// guard, and nearest sampling (now a runtime sampler from metal.m's cache).
// MetalBlitUniforms (metal_uniforms.h) is pinned against the generated
// entry-params block in metal.m.

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
