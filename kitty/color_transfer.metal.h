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

// W27 P3.5: TARGET PRIMARIES, the second half of the attachment vocabulary.
// The transfer above answers "who encodes"; this answers "which primaries the
// attachment's colourspace tag declares". The render pipeline works in linear
// sRGB primaries end to end (every colour admission point — gamma_lut decode,
// config colours, image decode — produces sRGB-primaries values, and the
// blending/contrast heuristics were tuned in that space), so a P3-tagged
// drawable needs exactly one primaries conversion, applied to linear values at
// the same per-attachment exit where the transfer is decided:
//
//   cell_fragment / border_fragment   direct-to-drawable draws
//   layers_resolve_fragment           the whole layered stack, once per pixel
//   drawable_clear_color()            the C-side consumer (kitty/metal.m)
//
// The layered working surface itself stays sRGB-primaries (LINEAR transfer,
// primaries conversion OFF for layered draws): graphics/tint/trail composite
// there and only the resolve faces the tagged drawable.
//
// The conversion is a plain 3x3 on linear values, so it commutes with
// premultiplication and with linear blending — converting each fragment before
// the ROP blend equals converting the blended result. sRGB and Display P3
// share the D65 white point, so no chromatic adaptation is involved and white
// maps to white exactly (each row sums to 1).
//
// Matrix values: CSS Color Module 4 / ColorSync reference values, derived by
// exact rational arithmetic from the shared primaries (sRGB R(.64,.33)
// G(.30,.60) B(.15,.06); P3 R(.680,.320) G(.265,.690) B(.150,.060); D65
// (.3127,.3290)). Independently re-derived in float for W27
// (.omc scratch derive_p3_matrix.py): agreement 1.2e-5, roundtrip 2e-16.
// sRGB gamut is a subset of P3, so in-range sRGB input yields in-range P3
// output (all forward coefficients are non-negative); extended-range input
// (the P3.5b wide-colour carrier) may exit [0,1] and is clamped only at the
// P3 gamut floor (negative light does not exist; >1.0 is EDR headroom).
#define KITTY_SRGB_TO_P3_R0 0.8224621512240581, 0.17753784877594204, 0.0
#define KITTY_SRGB_TO_P3_R1 0.03319409290511077, 0.9668059070948892, 0.0
#define KITTY_SRGB_TO_P3_R2 0.017085122152083325, 0.07240728088998424, 0.9105075969579324
#define KITTY_P3_TO_SRGB_R0 1.2249401762805587, -0.2249401762805597, 0.0
#define KITTY_P3_TO_SRGB_R1 -0.04205695470968816, 1.0420569547096878, 0.0
#define KITTY_P3_TO_SRGB_R2 -0.019637554590334432, -0.07863604555063188, 1.0982735931979283

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

// Linear sRGB-primaries -> linear Display-P3-primaries (see the matrix note
// above). Applied to linear values BEFORE any transfer encode; gated per
// attachment by the TARGET_PRIMARIES_IS_P3 function constant at each call
// site, so the bgra8 control arm's codegen is untouched. max(0) is the P3
// gamut floor for extended-range input; in-range input never trips it.
inline float3
srgb_to_p3(float3 c) {
    float3 r = float3(
        metal::dot(float3(KITTY_SRGB_TO_P3_R0), c),
        metal::dot(float3(KITTY_SRGB_TO_P3_R1), c),
        metal::dot(float3(KITTY_SRGB_TO_P3_R2), c));
    return metal::max(r, 0.0f);
}

#endif  // __METAL_VERSION__
