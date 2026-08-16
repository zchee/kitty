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

// ---- Custom-end chain bridge passes (kitty-luv) ----
// The runtime-compiled custom_shaders chain keeps its intermediate textures in
// GL memory orientation (row 0 = screen bottom) so user shader code inherits
// upstream's bottom-left-origin coordinate contract unmodified (t.pos, the UV
// fields in KittyCustomShaderData, raw .Sample calls). Two hand-written passes
// bridge that orientation to the Metal world, which renders top-down:
//
//  - seed: stored layered working surface (top-down) -> the shared backbuffer
//    texture, vertically mirrored into GL orientation. Runs once per
//    custom-end frame, replacing nothing (the in-pass layers resolve is
//    skipped on these frames).
//  - resolve: the chain's final texture (GL orientation) -> the drawable /
//    capture offscreen, mirrored back AND carrying the same target-space
//    epilogue as layers_resolve above (in-shader sRGB encode for the plain
//    8-bit targets, linear + P3 primaries for the wide arms). This pass is
//    what replaces the layers resolve; the GL arm instead lets its last group
//    encode sRGB itself, which would be wrong on a linear-tagged drawable.
//
// Both sample with an exact nearest sampler: same-size mirroring must move
// rows, never filter them. Both reuse layers_resolve_vertex's fullscreen
// triangle and read raster position directly.

fragment float4 custom_end_seed_fragment(
    float4 pos [[position]],
    texture2d<float, access::sample> src [[texture(0)]],
    constant float4 &dims [[buffer(0)]])  // (vw, vh, src_w, src_h)
{
    // The work surface is DRAWABLE-sized, which during live resize is NOT the
    // viewport (the GL arm offsets for the same mismatch in its last-group
    // draw) — so the source is normalized by ITS OWN dims, never the
    // viewport's, and the y-mirror pivots on the vh-row content band that the
    // layered pass rendered at the top of the surface.
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::nearest);
    return src.sample(s, float2(pos.x / dims.z, (dims.y - pos.y) / dims.w));
}

fragment float4 custom_end_resolve_fragment(
    float4 pos [[position]],
    texture2d<float, access::sample> src [[texture(0)]],
    constant float4 &params [[buffer(0)]])  // (vw, vh, sx, sy): viewport size and
                                            // the occupied fraction of the shared texture
{
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::nearest);
    float2 uv = pos.xy / params.xy;
    float4 work = src.sample(s, float2(uv.x * params.z, (1.0f - uv.y) * params.w));
    if (TARGET_PRIMARIES_IS_P3) work.rgb = srgb_to_p3(work.rgb);
    if (target_encodes_in_shader(TARGET_COLOR_SPACE)) {
        float3 rgb = work.a > 0.0f ? work.rgb / work.a : float3(0.0f);
        return float4(linear2srgb(rgb) * work.a, work.a);
    }
    return work;
}
