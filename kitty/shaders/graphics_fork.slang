#language slang 2026
// Copyright (C) 2026 Kovid Goyal <kovid at kovidgoyal.net>
// Distributed under terms of the GPLv3 license.
//
// FORK-OWNED wrapper (W3h, ADR-0032 §3 / ADR-0033): the Metal backend's
// graphics shader, generated from slang like the rest of the campaign, but
// carrying the two structures upstream's graphics.slang cannot express:
//
//  - the G2 instanced vertex (W27): upstream draws one quad per image ref
//    with a single uniform rect pair; this fork batches same-texture groups
//    as instanced quads over per-instance rect arrays (shaders.c chunks to
//    MAX_IMAGE_INSTANCES, kill switch KITTY_NO_INSTANCED_IMAGE_DRAWS). The
//    degenerate path (chunk 1, instance 0) is upstream-shaped by design —
//    that equivalence is this wrapper's vertex parity gate.
//  - the W27 P4.2 HDR tone-map epilogue (ADR-0022 decision 5), applied to
//    the LINEAR colour before premultiplication and only for f=3232 sources.
//
// The fragment logic below otherwise mirrors upstream fragment_main
// (alpha-mask compose, extra_alpha, premult) through the same imported
// helpers; the specialization axes carry upstream's names so the variant
// set stays recognizable. Entry points are renamed by the build to
// graphics_fork_* — a namespace upstream never occupies, which is what
// makes this landable while hand-written files still exist (the flat
// metallib rejects duplicate entry names; measured, ADR-0032 §8 F6).
//
// This file must NOT be edited to track upstream mechanically: upstream
// math arrives through the imported modules, and behaviour parity is owned
// by the golden gates (graphics/hdr-ramp configs).
import alpha_blend;
import utils;

extern static const bool is_alpha_mask = false;
extern static const bool texture_is_not_premultiplied = false;

// Must match MAX_IMAGE_INSTANCES in state.h / shaders.c; the generated
// binding size (16 * 16 bytes per array) is pinned against
// MetalGraphicsUniforms by static asserts in metal.m.
static const int MAX_IMAGE_INSTANCES = 16;

struct VSOutput {
    float2 texcoord : TEXCOORD;
    float4 position : SV_Position;
};

[shader("vertex")]
VSOutput vertex_main(
    uint vertex_id : SV_VertexID,
    uint instance_id : SV_InstanceID,
    uniform float4 src_rects[MAX_IMAGE_INSTANCES],
    uniform float4 dest_rects[MAX_IMAGE_INSTANCES],
) {
    // blit-common's fan table (RT, RB, LB, LT), reproduced here because
    // get_coords_for_blit takes a single rect pair and this vertex indexes
    // per-instance arrays. Fan order: the C side draws through the
    // fan->strip index remap with instanceCount (the composition BORDERS
    // has shipped since W3b).
    static const int2 pos_map[4] = { {2,1}, {2,3}, {0,3}, {0,1} };
    int2 pos = pos_map[vertex_id];
    float4 src_rect = src_rects[instance_id];
    float4 dest_rect = dest_rects[instance_id];
    return { float2(src_rect[pos.x], src_rect[pos.y]),
             float4(dest_rect[pos.x], dest_rect[pos.y], 0.0, 1.0) };
}

uniform Sampler2D image;

// W27 P4.2 tone map (ADR-0022 decision 5). `c` is linear extended-sRGB,
// `hr` the screen's current EDR headroom, `src_max` the image's largest
// component. Policy (b) soft knee when the source exceeds the headroom
// (piecewise-linear shoulder hinged at k = 0.8*hr, monotone by
// construction); policy (a) hard clamp when it already fits. The final
// min() is the ceiling in both branches. Ported verbatim from the retired
// hand-written MSL; slang emits the identical select() form.
float3 tone_map_hdr(float3 c, float hr, float src_max) {
    if (src_max > hr) {
        const float k = 0.8f * hr;
        const float denom = src_max - k;
        // denom > 0 whenever src_max > hr >= k/0.8 > k; the guard covers a
        // degenerate hr <= 0 that should be impossible.
        if (denom > 0.0f) {
            const float slope = (hr - k) / denom;
            c = select(c > float3(k), k + (c - k) * slope, c);
        }
    }
    return min(c, float3(hr));
}

[shader("fragment")]
float4 fragment_main(
    float2 texcoord : TEXCOORD,
    uniform float extra_alpha,
    uniform float3 amask_fg,
    uniform float4 amask_bg_premult,
    uniform float edr_headroom,
    uniform float src_is_hdr,
    uniform float src_max_component,
) : SV_Target {
    float4 color = image.Sample(texcoord);
    if (is_alpha_mask) {
        color = float4(amask_fg, color.r);
        color = vec4_premul(color);
        color = alpha_blend_premul(color, amask_bg_premult);
    } else {
        color.a *= extra_alpha;
        if (src_is_hdr > 0.5f)
            color.rgb = tone_map_hdr(color.rgb, edr_headroom, src_max_component);
        if (texture_is_not_premultiplied) color = vec4_premul(color);
    }
    return color;
}
