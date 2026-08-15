#language slang 2026
// Copyright (C) 2026 Kovid Goyal <kovid at kovidgoyal.net>
// Distributed under terms of the GPLv3 license.
//
// FORK-OWNED wrapper: upstream padding.slang (the neighboring-cell padding
// fill) through the generated pipeline, for the Metal backend. The vertex
// math mirrors upstream 1:1; the fork deltas are:
// 1. The cell attributes come from the LIVE cell/selection buffers, fetched
//    by the true grid index (real_id) the upstream shader already computes,
//    instead of stage_in attributes over GPU-packed padding buffers. The
//    fenced Metal buffer rings cannot express upstream's vao region copies
//    (copy_vao_buffer_region fatals on this backend), and the fetch makes
//    them unnecessary: no packing, no attribute repointing, no extra
//    buffers. The C side pushes the SAME uniforms as the GL arm.
// 2. The colour comes from background_fork (the wide-threaded fork module),
//    so a padding strip matches its neighboring cell exactly even when that
//    cell's background is a P3.5b wide-table carrier.
// 3. The colour epilogue (cell_fork's): the four (transfer, primaries)
//    target variants, because the strip draws into the same attachments as
//    the cell passes.
import utils;
import background_fork;
import linear2srgb;
import color_fork_generated;

// The fork epilogue axes (border_fork.slang's, ADR-0034 §2).
extern static const int target_color_space = 0;
extern static const bool target_primaries_is_p3 = false;
static const int TARGET_SPACE_ENCODE_SRGB = 0;

// GPUCell as the C side lays it out (kitty/line.h; the same records the cell
// vertex descriptor reads as instanced attributes -- five 4-byte words).
struct PaddingGPUCell {
    uint fg, bg, decoration_fg, sprite_idx, attrs;
};

// The live per-cell streams the cell passes render from, bound whole.
StructuredBuffer<PaddingGPUCell> cells;
// One byte per cell; bound as words, the byte is extracted below.
StructuredBuffer<uint> selection_words;

// Corner indicator per quad vertex, matching cell_pos_map in background.slang.
// .x: 0 -> left, 1 -> right ; .y: 0 -> top, 1 -> bottom
static const uint2 pad_pos_map[4] = {
    uint2(1u, 0u), // right, top
    uint2(1u, 1u), // right, bottom
    uint2(0u, 1u), // left, bottom
    uint2(0u, 0u)  // left, top
};

struct VertexOutput {
    float4 color_premul : COLOR_PREMUL;
    float4 position : SV_Position;
};

[shader("vertex")]
VertexOutput
vertex_main(
    uint vertex_id: SV_VertexID,
    uint instance_id: SV_InstanceID,
    // The true cell index (into the cell grid) for strip 0's first instance.
    uniform uint base_instance,
    uniform uint instance_step,
    // 1 for the top/bottom strips (the strip runs along x), 0 for left/right.
    uniform uint is_horizontal,
    // Number of cells per strip (== instance count for a single-strip draw;
    // total instances == along_count * num_strips).
    uniform uint along_count,
    // The two NDC values of the thin (across) dimension for strip 0.
    uniform float2 across,
    // NDC of the along dimension for the first cell's near corner, and the step
    // per cell (signed; negative for the vertical strips as NDC y decreases
    // downwards).
    uniform float along_start,
    uniform float along_step,
    // NDC bounds used to extend the first/last cell so the strip fills the
    // corners (shared by both strips of a combined draw).
    uniform float2 along_clamp,
    // Strip-1 parameters. Equal to strip-0 values for single-strip draws so
    // the lerp below is always correct regardless of strip count.
    uniform uint base_instance2,
    uniform float2 across2, ) {
    VertexOutput vo;

    // Branchless strip selector: 0.0 for strip 0, 1.0 for strip 1.
    float strip_f = float(instance_id / along_count);
    uint strip_i = instance_id % along_count;

    // Select the base cell and across extents for whichever strip this
    // instance belongs to, using lerp so no divergent branch is emitted.
    float fbase = lerp(float(base_instance), float(base_instance2), strip_f);
    uint real_id = uint(fbase) + strip_i * instance_step;
    float2 chosen_across = lerp(across, across2, strip_f);

    // fork delta 1: fetch the cell record and selection byte by real_id.
    PaddingGPUCell cell = cells[real_id];
    uint3 colors = uint3(cell.fg, cell.bg, cell.decoration_fg);
    uint2 sprite_idx = uint2(cell.sprite_idx, cell.attrs);
    uint is_selected = (selection_words[real_id >> 2] >> ((real_id & 3u) * 8u)) & 0xFFu;

    vo.color_premul = padding_background_premul(colors, sprite_idx, is_selected, real_id);

    uint2 p = pad_pos_map[vertex_id];
    float along_lo = along_start + float(strip_i) * along_step;
    float along_hi = along_lo + along_step;

    // Branch-free selection via lerp(). h selects the strip orientation, s is the
    // corner component along the strip axis and a the component across it.
    float h = float(is_horizontal);
    float s = lerp(float(p.y), float(p.x), h);
    float a = lerp(float(p.x), float(p.y), h);
    // 1 when this is the first/last instance within its strip, else 0.
    float is_first = 1.0 - min(float(strip_i), 1.0);
    float is_last = 1.0 - min(float(along_count - 1u - strip_i), 1.0);

    float along = lerp(along_lo, along_hi, s);
    // Extend the first cell's near corner and the last cell's far corner out to
    // along_clamp so the strip fills the corners.
    along = lerp(along, along_clamp.x, is_first * (1.0 - s));
    along = lerp(along, along_clamp.y, is_last * s);
    float across_v = lerp(chosen_across.x, chosen_across.y, a);

    // Horizontal strip -> position is (along, across); vertical -> (across, along).
    vo.position = float4(lerp(across_v, along, h), lerp(along, across_v, h), 0.0, 1.0);
    return vo;
}

[shader("fragment")]
float4
fragment_main(float4 color_premul: COLOR_PREMUL)
    : SV_Target {
    float4 ans_premul = color_premul;
    // The fork epilogue (cell_fork's exit, ADR-0034): primaries before
    // transfer -- the matrix operates on linear values and commutes with the
    // premultiplied alpha and with the ROP's linear blend.
    if (target_primaries_is_p3) ans_premul.rgb = srgb_to_p3(ans_premul.rgb);
    if (target_color_space == TARGET_SPACE_ENCODE_SRGB) {
        float3 c = clamp(ans_premul.rgb, 0.0f, 1.0f);
        ans_premul.rgb = float3(linear2srgb(c.r), linear2srgb(c.g), linear2srgb(c.b));
    }
    return ans_premul;
}
