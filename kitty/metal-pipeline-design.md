# Metal backend: render-pass and color-pipeline design

Status: implemented by `kitty/metal.m` (Phase 2 of the Metal port). Left column
cites the OpenGL semantics being reproduced; the GL call sites live in shared,
unmodified code (`kitty/shaders.c`, `kitty/gl.h` API).

## Frame lifecycle

- One `MTLCommandBuffer` per OS window per frame, created lazily at the first
  draw after `make_os_window_context_current` (`kitty/glfw.c`
  `metal_set_current_layer`).
- Present + commit happen in `metal_end_frame()` called from
  `swap_window_buffers` (`kitty/glfw.c`), gated by `glfwAreSwapsAllowed` —
  identical gating to the `glfwSwapBuffers` path. No work is committed for
  occluded windows.
- The drawable is acquired as late as possible (first encoder that targets the
  default framebuffer), and released at end-of-frame after present, per the
  CAMetalLayer drawable-pool guidance (drawables come from a small reusable
  pool; holding them starves `nextDrawable`).
- All per-window mutable state (layer, command buffer, drawable, encoder,
  pending clear, viewport/scissor) lives in a per-window `MetalWindowState`
  keyed by the CAMetalLayer pointer. Device, command queue, metallib, PSO
  cache, textures, buffers and VAOs are process-global — this reproduces the
  NSGL `globally_shared_context` semantics (`glfw/nsgl_context.m`): GPU
  resources (glyph atlas, images) survive window destruction.

## Encoders and load/store rules

| GL semantic | Metal implementation |
|---|---|
| Draws accumulate into the bound framebuffer | Encoder-per-(target,view-kind); `MTLLoadActionLoad`, `MTLStoreActionStore` |
| `glClear` | Deferred: recorded with the *current* clear color and sRGB flag; applied as `MTLLoadActionClear` on the next encoder for that target |
| `glBindFramebuffer` switch | Ends the current encoder; next draw opens an encoder on the new target |
| `GL_FRAMEBUFFER_SRGB` toggle between draws | No-op on the drawable (single `BGRA8Unorm` format; sRGB is encoded in-shader — C1). The toggle only ends the encoder on a real target/format change. |

An encoder is (re)created only when: no encoder is open, the render target
changed, or the required attachment format changed. Within such a run, draws
share one encoder.

## sRGB strategy (C1: single format, sRGB encoded in-shader)

OpenGL converts linear shader outputs to sRGB on write only when the attachment
has an sRGB format AND `GL_FRAMEBUFFER_SRGB` is enabled. kitty toggles the flag
around the cell/border final-output draws and leaves it off elsewhere. The Metal
backend reproduces this by encoding sRGB in the shaders, not with a drawable view:

- `CAMetalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm` (plain, non-sRGB) and
  `framebufferOnly = YES`. There is exactly ONE drawable format; **no sRGB
  texture view of the drawable is ever created** — that per-frame view creation
  was precisely what forbade `framebufferOnly = YES` (Wave-1 finding), so
  deleting it (C1) is what unblocks the compression win (C4a).
- **Opaque path** (cells/borders drawn straight to the drawable): the cell and
  border fragments encode linear→sRGB on their premultiplied output when the
  `SRGB_ENCODE_OUTPUT` function constant is set (`build_pso` sets it `= !layered`).
  These draws have blending disabled, so the encoded channels are written 1:1 —
  exactly what a `BGRA8Unorm_sRGB` attachment would do on write.
- **Layered path**: compositing draws output linear into the RGBA16Unorm working
  surface (`SRGB_ENCODE_OUTPUT` unset); the resolve draw encodes (see
  “Single-pass layered rendering”).
- The `GL_FRAMEBUFFER_SRGB` toggles in `kitty/shaders.c` are compiled out on the
  Metal backend (`#ifndef KITTY_BACKEND_METAL`); the shim still tracks the flag as
  vestigial GL state but no longer selects any drawable format from it.
- Offscreen (“FBO”) targets stay linear `MTLPixelFormatRGBA16Unorm`; the flag is
  irrelevant there. The screenshot path uses a real `RGBA16Unorm` render-target
  texture, and read-back (screenshot / golden dump) renders to a readable
  offscreen instead of the framebufferOnly drawable (`metal_capture_to_offscreen`).
- **Precision**: in-shader `linear2srgb` (fp32) matches the hardware sRGB ROP to
  within ≤1 LSB — measured ≤1 LSB on ~0.06% of opaque pixels, all at dark
  antialiased-text edges (sRGB-quantization rounding, not a curve difference).
  This also unifies the sRGB encode across the opaque and layered paths (the
  layered path already encoded in-shader, byte-identically to base).

## Pipeline-state cache

PSOs are cached by key `(program, blend, attachment format, layered)` and built
lazily. Formats in play: `BGRA8Unorm` (the single drawable format — C1 removed the
`BGRA8Unorm_sRGB` drawable-view variant) and `RGBA16Unorm` (the single-pass
layered working surface, M1 below). Blend state
mirrors `set_blending` (premultiplied `ONE, ONE_MINUS_SRC_ALPHA`; disabled =
opaque write). A PSO’s `colorAttachments[0].pixelFormat` always equals the
encoder’s target view format — mismatches are a Metal validation error and were
the prior implementation’s layered-path black screen (triage defect D1). The
`layered` key bit selects the **two-attachment** variant used inside the M1
single layered pass: `colorAttachments[0]` = the `RGBA16Unorm` working surface
(the program’s real output), `colorAttachments[1]` = the drawable
(`BGRA8Unorm`) with `writeMask = None` (only the resolve draw writes it). All
compositing programs run through this variant during a layered frame; the
resolve draw uses its own dedicated PSO (`layers_resolve_vertex/fragment`).

## Texture format map (GL internalformat → MTLPixelFormat)

| GL | Metal | Used by |
|---|---|---|
| `GL_SRGB8_ALPHA8` | `RGBA8Unorm_sRGB` | glyph atlas (`glTexStorage3D`, `kitty/shaders.c`) |
| `GL_SRGB_ALPHA` | `RGBA8Unorm_sRGB` | graphics-protocol images (`send_image_to_gpu`) |
| `GL_RGBA16` | `RGBA16Unorm` | layer FBO (`setup_texture_as_render_target`) |
| `GL_RGBA` | `RGBA8Unorm` | FBO fallback (#9068) |
| `GL_R32UI` | `R32Uint` | sprite decorations map |
| `GL_RED`/`GL_R8` | `R8Unorm` | — |

`GL_RGB` uploads (opaque images) are expanded to RGBA on the CPU at upload
time; Metal has no 3×8-bit format.

## Quad primitive

`draw_quad` (`kitty/gl.c:150`) draws a 4-vertex `GL_TRIANGLE_FAN`, instanced
for cells/borders/graphics. Metal has no fan. Mapping:
`MTLPrimitiveTypeTriangleStrip` with **reordered corner LUTs in every vertex
shader**: `strip[0..3] = fan[2], fan[1], fan[3], fan[0]`. The LUT lives next
to each shader’s `*_pos_map` constant (`cell_shaders.metal:145`,
`border_shaders.metal:41`, `graphics_shaders.metal:48`, `blit_shaders.metal:63`,
`effects_shaders.metal`). Corner *semantics* (which corner a vertex id means)
are preserved, so derived values (sprite coords, tex coords) stay correct.

## Coordinate conventions

- Vertex shaders emit the same NDC as the GLSL versions; Metal’s NDC differs
  from GL only in Z (0..1 vs −1..1), which kitty does not use (2D, z=0).
- Metal’s framebuffer origin is top-left vs GL’s bottom-left. kitty’s GL code
  already works in top-left window coordinates and flips where needed
  (`save_viewport_using_top_left_origin`, scissor helpers in `kitty/gl.c`);
  the shim implements those helpers natively in top-left, so no double flip.
- Texture sampling: uploads are top-down in both backends (kitty uploads
  row 0 = top); GLSL/MSL texcoords agree.

## Uniform staging

Plain `glUniform*` calls are captured per program into a value store. Draw-time
marshalling into each program’s argument struct resolves slots **by uniform
name** (cached after first lookup), never by numeric location, so the order of
`glGetUniformLocation` calls in generated `uniforms_generated.h` code cannot
skew the mapping. UBOs (`CellRenderData`, `ColorTable`) pass through as
`MTLBuffer`s bound to fixed indices:

| MSL buffer index | Content |
|---|---|
| 0 | instance/vertex attribute buffer (VAO buffer 0) |
| 1 | `CellRenderData` UBO (VAO buffer 2) |
| 2 | per-draw uniform struct (`setVertexBytes`) |
| 3 | `gamma_lut[256]` (`setVertexBytes`) |
| 4 | `ColorTable` UBO (VAO buffer 3, packed `uint[]`) |
| 5 | `is_selected` buffer (VAO buffer 1) |

The shim owns GL introspection: `block_index`/`block_size`/
`get_uniform_information` report **tightly packed** layouts (ColorTable:
offset 0, array stride 4), so the shared C writers (`copy_color_table_to_buffer`,
`cell_update_uniform_block`) produce exactly the bytes the MSL reads. No
hardcoded offsets are permitted anywhere in the shim (triage defect S4).

## Buffer lifecycle: the fenced ring (Phase 2 / D1 + D2)

Per-frame VAO buffers (cell instance data, `is_selected`, `CellRenderData` UBO,
`ColorTable` UBO) are backed by a small **ring of resident `MTLBuffer`s** rather
than a fresh allocation per frame. This keeps the GL waist API byte-for-byte
identical while removing all steady-state allocations (plan D1, acceptance §7.3).

| GL-waist entry point | Backing | Contents on map |
|---|---|---|
| `alloc_and_map_vao_buffer(frequently_updated=true)` (cell, selection) | ring slot | fresh (caller full-rewrites the whole buffer; **no** copy) |
| `map_vao_buffer_for_write_only(offset,size)` (uniform, color-table) | ring slot | **copy-forward** from the newest slot, so bytes outside `[offset,offset+size)` are preserved (GL `glMapBufferRange(INVALIDATE)` parity; D2's per-line partial uploads rely on this) |
| `alloc_and_map_vao_buffer(frequently_updated=false)` (borders) | single buffer, reused in place, hazard-**tracked** | unchanged (rare writes; not a steady-state allocation) |

- **Depth**: slots grow lazily on demand up to a small cap. With
  `maximumDrawableCount = 2` at most two frames reference a buffer concurrently,
  so the working set stabilizes at frames-in-flight + 1 (≤3); when the GPU keeps
  pace with the CPU only a single slot is reused.
- **Fence (never by luck)**: at draw time each bound ring slot is stamped with
  the exact `MTLCommandBuffer` that will read it. A slot is only handed back out
  once that command buffer reports `MTLCommandBufferStatusCompleted`. This is
  correct regardless of how command buffers from multiple OS windows interleave
  on the single command queue — it does **not** rely on the committed-CB retaining
  its buffers (the Wave-1 orphan-path accident, hazard H3).
- **Hazard tracking**: ring slots are `MTLResourceHazardTrackingModeUntracked`
  [C3b]. Safe because the ring never writes a slot the fence says is still in
  flight, and these buffers are only ever GPU-**read** — so there is no GPU-side
  hazard for Metal to track (verified clean under `MTL_DEBUG_LAYER` +
  `MTL_SHADER_VALIDATION`).
- **Observability**: the `metal_stats` line gains `allocs=<n>` — MTLBuffer
  allocations performed while encoding that frame (0 in steady state).

### Per-line dirty upload (D2)

Because the ring slot is persistent, it still holds the bytes it was last given.
`screen_update_cell_data()` exploits this: instead of memcpy-ing the whole grid
every dirty frame, it compares each render row's freshly-shaped `gpu_cells`
against the slot's current bytes (`update_line_data_diff`) and uploads only rows
that differ. A localized edit therefore uploads ~one row (e.g. 2,400 B at 120
columns) instead of the whole grid (~110 KB); a full scroll still uploads the
whole grid (plan D2, acceptance §7.10).

- **Correctness by comparison, not by flag**: a row is re-uploaded when it was
  re-shaped this frame (dirty / cursor / history) **or** when its bytes differ
  from the slot. The memcmp is what makes scroll safe — `linebuf_index()` moves a
  line to a new render position via a `line_map` rotation *without* marking it
  dirty, and multi-slot staleness (a row changed while a different ring slot was
  bound) is likewise caught because the comparison is against the actual slot the
  frame will draw from, not a global "last frame" state.
- **Full-rewrite triggers**: a freshly (re)allocated slot (`fresh` — resize/first
  use, contents are garbage so a memcmp is meaningless), the OpenGL backend
  (buffer is orphaned fresh every frame), an active overlay, and paused rendering.
  `metal_cell_ring_take_fresh()` reports (and consumes) the slot's `fresh` bit.
- **Selection / uniform / color-table**: left as full rewrites but already gated
  (selection only when `screen_is_selection_dirty`; uniform/color-table only when
  changed, D4) — a keystroke touches neither, so they add nothing to its budget.
- **Observability**: the `metal_stats` line also gains `bytes=<n>` — total VAO
  ring bytes uploaded that frame (cell dirty rows + selection + uniform +
  color-table); the ≤8 KB 1-line-edit probe. Harness parsers must tolerate the
  extra key (they already do).

### Metric fix: encode_ms vs drawable_wait_ms (worker-prof #16)

`encode_ms`'s start stamp used to be taken at command-buffer creation, which is
*before* `nextDrawable`. With `maximumDrawableCount = 2`, drawable-acquisition
blocking (~60 ms observed under plain typing) was therefore silently counted as
"encode" time. Fixed by stamping `metal_frame_encode_start` only after
`ensure_drawable()` succeeds and emitting the block separately:

- `encode_ms` = drawable-acquired → present-commit (command encoding only). For
  layered frames this excludes the pre-drawable offscreen-FBO pass encode (a minor
  known undercount; the opaque path — the measured case — is exact).
- `drawable_wait_ms=<float.3>` = time spent inside `nextDrawable` this frame (the
  real keypress-to-photon backpressure with a 2-deep drawable pool).

Not touched here: the encode path itself (never slow) and `maximumDrawableCount`
(a Phase-4 decision).

## Single-pass layered rendering (Phase 3 / M1)

Layered OS windows — `background_opacity < 1`, background image, graphics,
UI overlays, and the cursor trail (`kitty/child-monitor.c` `needs_layers`) —
previously rendered the whole window into a shared **RGBA16Unorm DRAM FBO**
(`layers_render_texture`) and then ran a second **BLIT pass** to sRGB-encode it
onto the drawable: 2 render passes and a full-screen RGBA16 store + re-read
(~123 MB/frame @ 3456×2234). On the Metal backend this is collapsed to **one
on-drawable pass** with an on-tile working surface; the opaque path (already one
pass) is unchanged.

- **Two-attachment pass.** `metal_begin_layered_frame()` (called from the
  `KITTY_BACKEND_METAL` branch of `start_os_window_rendering`, replacing the GL
  FBO setup) opens a single render pass with:
  - `colorAttachments[0]` = a **memoryless** `RGBA16Unorm` working surface
    (`StorageModeMemoryless`, `loadAction=Clear` to transparent — mirroring the
    old `clear_current_framebuffer()` — `storeAction=DontCare`). Memoryless means
    the surface lives only in tile memory for the duration of the pass and never
    touches DRAM, so it is created lazily, cached, grown to the drawable size,
    and costs no `MTLBuffer` allocation (the `allocs=` stat is unaffected).
  - `colorAttachments[1]` = the drawable (or the golden-dump offscreen in
    `KITTY_METAL_DUMP_FRAME` mode), `storeAction=Store`; `loadAction=DontCare`
    on the first drawable pass (M3), else `Load`.
- **Compositing draws are unchanged.** Every layered draw (bg image, cells with
  `for_final_output=false`, graphics, borders, trail, overlays) renders
  linear-premultiplied into att0 through the **existing** shaders and the
  **existing** hardware premultiplied blend (`ONE, ONE_MINUS_SRC_ALPHA`) — exactly
  as it rendered into the RGBA16Unorm DRAM FBO before. `wanted_attachment_format`
  returns the working-surface format for the whole pass so the encoder is never
  torn down by a `GL_FRAMEBUFFER_SRGB` toggle, and `draw_quad` selects the
  `layered` two-attachment PSO variant (att1 masked out).
- **In-pass resolve replaces the BLIT.** `metal_resolve_layered_frame()` (called
  from `stop_os_window_rendering`) issues one fullscreen draw with a dedicated PSO
  (`layers_resolve_vertex` / `layers_resolve_fragment`) that reads att0 via
  framebuffer fetch (`float4 [[color(0)]]`), performs the *same* unpremultiply →
  `linear2srgb_v` → premultiply the old `blit_fragment` did, and writes att1; then
  ends the pass. att0 is discarded (memoryless), att1 (drawable) is stored.
- **Precision.** The working surface is `RGBA16Unorm`, identical to the old DRAM
  FBO, so linear-blend precision (issue #8953) is preserved *exactly*: golden
  A/B vs the pre-M1 base is **byte-identical for every config** (opaque,
  `background_opacity 0.85`, bgimage, cursor_trail), so the #8953
  dark-AA-text-over-translucent case cannot band differently than base.
- **Platform.** Framebuffer fetch (`[[color(n)]]`) + memoryless render targets
  are Apple-GPU features, empirically verified on this machine
  (`[device supportsFamily:MTLGPUFamilyApple7]`, day-0 spike). The GL backend
  keeps the FBO + BLIT path verbatim under `#ifndef KITTY_BACKEND_METAL`.
- **Result.** `passes=1` for ALL configs including transparent / bgimage / trail
  (was 2 for layered); the RGBA16 DRAM round trip is eliminated. Validated clean
  under `MTL_DEBUG_LAYER=1` + `MTL_SHADER_VALIDATION=1` in both drawable and
  offscreen-dump modes.

## Known deviations (tracked, intentional)

- Cell/graphics MSL shader *logic* is still the opus-era port; semantic drift
  against current GLSL (attr bit shifts, fg_override fix, bgimage preload) is
  Phase 3 (gates G2–G7 golden diffs).
- `presentsWithTransaction` live-resize sequencing and CADisplayLink pacing are
  Phase 4.
