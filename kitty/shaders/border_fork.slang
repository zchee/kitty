#language slang 2026
// Copyright (C) 2026 Kovid Goyal <kovid at kovidgoyal.net>
// Distributed under terms of the GPLv3 license.
//
// FORK-OWNED wrapper (W3i, ADR-0034): border's FRAGMENT stage, generated
// from slang like the rest of the campaign, carrying the one structure
// upstream's border.slang cannot express — the colour epilogue this fork
// applies at every direct-to-drawable exit (upstream's fragment_main is a
// bare `return color_premul`). The vertex stage is NOT here: it stays
// generated from upstream border.slang (border_vertex, W3b), and this file
// is the campaign's first fragment-only METAL_SHADERS entry.
//
// The epilogue's two Metal function constants (TARGET_COLOR_SPACE,
// TARGET_PRIMARIES_IS_P3) become the two specialization axes below. Only
// the four (transfer, primaries) pairs metal.m's resolvers can produce are
// compiled (default / linear / linear_p3 / rop_p3); the unreachable pairs
// fail loud at the PSO site. rop_p3 compiles byte-identical to linear_p3
// today — the shader branches only on "does the fragment encode" — and is
// kept distinct so the C-side selection stays a transcription of
// target_color_space_for() (ADR-0034 §2).
//
// The transfer scalars and the P3 matrix are DUPLICATED from
// kitty/color_transfer.metal.h (slang cannot include MSL headers). The
// duplication is build-pinned: slang.py refuses to emit MSL if these
// literals drift from the header's (the golden gate cannot own that pin —
// goldens exercise only the ENCODE_SRGB variant via the BGRA8 capture
// offscreen). The encode uses the SCALAR linear2srgb triple, mirroring the
// retired hand-written call site: the header warns the scalar and vector
// forms are the same maths but not necessarily the same codegen, and the
// default arm must stay byte-identical.

// Mirrors TARGET_SPACE_* in kitty/color_transfer.metal.h: ENCODE_SRGB 0,
// LINEAR 1, ROP_ENCODES 2. Only the ENCODE comparison is branched on —
// LINEAR and ROP_ENCODES both mean "emit linear" here.
extern static const int target_color_space = 0;
extern static const bool target_primaries_is_p3 = false;

static const int TARGET_SPACE_ENCODE_SRGB = 0;

float linear2srgb(float x) {
    float lower = 12.92f * x;
    float upper = 1.055f * pow(x, 1.0f / 2.4f) - 0.055f;
    return lerp(lower, upper, step(0.0031308f, x));
}

// Linear sRGB-primaries -> linear Display-P3-primaries; max(0) is the P3
// gamut floor for extended-range input. This function and linear2srgb above
// are a CHECKED RENDERING of slang.py's canonical_epilogue_functions()
// (matrix rows read from kitty/color_transfer.metal.h) -- the build fails
// with the expected block printed if this text deviates in ANY way (W3j
// Lane 0, closing W3i F9's swizzle/assembly/floor blindness).
float3 srgb_to_p3(float3 c) {
    float3 r = float3(
        dot(float3(0.8224621512240581, 0.17753784877594204, 0.0), c),
        dot(float3(0.03319409290511077, 0.9668059070948892, 0.0), c),
        dot(float3(0.017085122152083325, 0.07240728088998424, 0.9105075969579324), c));
    return max(r, float3(0.0));
}

[shader("fragment")]
float4 fragment_main(float4 color_premul : COLOR_PREMUL) : SV_Target {
    float4 c = color_premul;
    // Primaries before transfer (linear-space matrix; commutes with premul).
    if (target_primaries_is_p3) c.rgb = srgb_to_p3(c.rgb);
    if (target_color_space == TARGET_SPACE_ENCODE_SRGB) {
        // Opaque borders draw with blend disabled, so encode the
        // premultiplied channels 1:1 (matching a BGRA8Unorm_sRGB
        // attachment write).
        float3 lin = clamp(c.rgb, 0.0f, 1.0f);
        c.rgb = float3(linear2srgb(lin.r), linear2srgb(lin.g), linear2srgb(lin.b));
    }
    return c;
}
