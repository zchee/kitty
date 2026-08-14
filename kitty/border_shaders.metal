/*
 * border_shaders.metal
 * Copyright (C) 2024 Kovid Goyal <kovid at kovidgoyal.net>
 *
 * Distributed under terms of the GPL3 license.
 *
 * W3b: the vertex stage is no longer here -- it is generated from
 * kitty/shaders/border.slang (see slang.py's METAL_SHADERS) and linked into
 * default.metallib as border_vertex. What remains is the fragment, which is
 * fork-only: upstream's fragment_main returns color_premul unchanged, while
 * this one applies the primaries conversion and the linear->sRGB encode that
 * the CAMetalLayer drawable needs and that slang has no way to express.
 */

#include <metal_stdlib>
using namespace metal;

// W27 P3.4: the sRGB transfer pair and the target-space vocabulary are shared
// (kitty/color_transfer.metal.h), so this file no longer carries its own copy.
#include "color_transfer.metal.h"

// C1/P3.4: the target space of the attachment this PSO renders to. ENCODE_SRGB
// on the opaque path so the fragment applies the transfer itself (the default
// drawable is a plain BGRA8Unorm with no sRGB view); LINEAR on the layered path
// (output stays linear in the working surface; the resolve draw encodes) and on
// a linear-stored wide drawable; ROP_ENCODES when the raster op applies it.
constant int TARGET_COLOR_SPACE [[function_constant(0)]];
// W27 P3.5: ON when the attachment is tagged Display P3 (wide drawable arms);
// the one primaries conversion happens at the fragment exit, before any
// transfer encode. See kitty/color_transfer.metal.h.
constant bool TARGET_PRIMARIES_IS_P3 [[function_constant(1)]];

// Interstage linkage is by name, so COLOR_PREMUL has to match the semantic
// border.slang gives VertexOutput.color_premul; a mismatch is a pipeline
// creation failure, not a silent one.
struct BorderFragmentIn {
    float4 color_premul [[user(COLOR_PREMUL)]];
    float4 position [[position]];
};

fragment float4 border_fragment(BorderFragmentIn in [[stage_in]]) {
    float4 c = in.color_premul;
    // Primaries before transfer (linear-space matrix; commutes with premul).
    if (TARGET_PRIMARIES_IS_P3) c.rgb = srgb_to_p3(c.rgb);
    if (target_encodes_in_shader(TARGET_COLOR_SPACE)) {
        // Opaque borders draw with blend disabled, so encode the premultiplied
        // channels 1:1 (matching a BGRA8Unorm_sRGB attachment write).
        float3 lin = clamp(c.rgb, 0.0f, 1.0f);
        c.rgb = float3(linear2srgb(lin.r), linear2srgb(lin.g), linear2srgb(lin.b));
    }
    return c;
}
