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
import linear2srgb;
import color_fork_generated;

extern static const int target_color_space = 0;
extern static const bool target_primaries_is_p3 = false;

static const int TARGET_SPACE_ENCODE_SRGB = 0;

// Colour maths comes from modules, never from local copies (W3j round-1 F2:
// every textual pin over a live copy lost -- the copy must not exist):
// linear2srgb from upstream's module, srgb_to_p3 from the fork's generated
// module (rendered from kitty/color_transfer.metal.h at every build).

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
