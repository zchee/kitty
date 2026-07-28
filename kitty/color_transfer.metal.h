/*
 * color_transfer.metal.h
 * Copyright (C) 2026 Kovid Goyal <kovid at kovidgoyal.net>
 *
 * Distributed under terms of the GPL3 license.
 */

#pragma once

// W27 P3.4. Two things live here, and they are here together on purpose:
//
//   1. The sRGB transfer pair, which used to be copy-pasted into
//      cell_shaders.metal, border_shaders.metal and blit_shaders.metal.
//   2. The TARGET COLOR SPACE vocabulary shared by the MSL fragments and the C
//      side that specializes them (kitty/metal.m).
//
// The values are outside the __METAL_VERSION__ guard so kitty/metal.m can
// include this header and set the function constant from the SAME symbols the
// shaders branch on. Two copies plus a "keep in sync" comment is exactly the
// drift this campaign cannot afford: a mismatch here is a whole-gamma rendering
// error that still compiles.
//
// Who applies the linear -> sRGB transfer depends on the attachment, so it is a
// per-PSO function constant, never a process-wide mode (the KITTY_METAL_DUMP_
// FRAME / thumbnail capture path renders to a BGRA8 offscreen while the live
// drawable may be wide -- see drawable_attachment_format() in kitty/metal.m):
//
//   ENCODE_SRGB   the fragment applies it. Plain BGRA8Unorm targets: the
//                 default drawable, the capture offscreen, FBO targets.
//   LINEAR        nobody applies it; the target stores linear. The memoryless
//                 RGBA16Unorm layered working surface, and the linear-stored
//                 wide drawables (BGRA10_XR, RGBA16Float).
//   ROP_ENCODES   the raster op applies it on store. BGRA10_XR_sRGB.
//
// ROP_ENCODES and LINEAR take the same branch in the shader -- both mean "emit
// linear" -- but they are distinct states because they differ everywhere else:
// their ceilings differ (BGRA10_XR_sRGB's 1.25098 is an ENCODED-domain ceiling,
// decoding to ~1.66 linear; BGRA10_XR's 1.25098 is linear light), which is what
// P4's tone-map policy has to reason about. Collapsing them to a bool would
// throw away the distinction that decides EDR behaviour.
//
// NOTE the XR storage mapping (shader_float = (xr10 - 384) / 510) is the
// FORMAT's job, not the shader's: fragments emit ordinary linear floats and the
// hardware maps them into the extended range on write. Nothing here encodes it.

#define TARGET_SPACE_ENCODE_SRGB 0
#define TARGET_SPACE_LINEAR      1
#define TARGET_SPACE_ROP_ENCODES 2

#ifdef __METAL_VERSION__

#include <metal_stdlib>

// True when the fragment itself must apply the transfer. The two "emit linear"
// states are deliberately folded here and only here, so a shader can never
// accidentally treat ROP_ENCODES as "no transfer happens at all".
inline bool
target_encodes_in_shader(int target_space) {
    return target_space == TARGET_SPACE_ENCODE_SRGB;
}

// The sRGB transfer functions, scalar and vector. Both forms are kept because
// the call sites are not interchangeable for a byte-exact gate: the scalar
// triple and the vector form are the same maths per component but not
// necessarily the same code generation, and the default arm must stay
// byte-identical. Each call site keeps whichever form it used before P3.4.

inline float
srgb2linear(float x) {
    float lower = x / 12.92f;
    float upper = metal::pow((x + 0.055f) / 1.055f, 2.4f);
    return metal::mix(lower, upper, metal::step(0.04045f, x));
}

inline float
linear2srgb(float x) {
    float lower = 12.92f * x;
    float upper = 1.055f * metal::pow(x, 1.0f / 2.4f) - 0.055f;
    return metal::mix(lower, upper, metal::step(0.0031308f, x));
}

inline float3
srgb2linear(float3 c) {
    return float3(srgb2linear(c.r), srgb2linear(c.g), srgb2linear(c.b));
}

inline float3
linear2srgb(float3 x) {
    float3 lower = 12.92f * x;
    float3 upper = 1.055f * metal::pow(x, float3(1.0f / 2.4f)) - 0.055f;
    return metal::mix(lower, upper, metal::step(0.0031308f, x));
}

#endif  // __METAL_VERSION__
