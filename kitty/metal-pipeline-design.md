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
| `GL_FRAMEBUFFER_SRGB` toggle between draws | Ends the current encoder; next encoder targets the other view kind (see below) |

An encoder is (re)created only when: no encoder is open, the render target
changed, or the required view kind changed. Within a target+kind run, draws
share one encoder.

## sRGB strategy (GL_FRAMEBUFFER_SRGB parity)

OpenGL converts linear shader outputs to sRGB on write only when the
attachment has an sRGB format AND `GL_FRAMEBUFFER_SRGB` is enabled. kitty
toggles the flag per draw (`kitty/shaders.c` around the cell and border draws)
and leaves it off for image/bgimage/blit output.

Metal implementation:

- `CAMetalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm` (non-sRGB base).
- Each drawable lazily gets an sRGB **texture view**
  (`newTextureViewWithPixelFormat: MTLPixelFormatBGRA8Unorm_sRGB`). sRGB/linear
  views of the same base format do not require `MTLTextureUsagePixelFormatView`.
- Flag ON → encoder targets the sRGB view (GPU converts on write, like GL).
  Flag OFF → encoder targets the base texture (raw writes, like GL).
- Deferred clears capture the flag at `glClear` time and force the applying
  encoder to that view kind, so clear colors round-trip exactly like GL.
- Offscreen (“FBO”) targets are linear `MTLPixelFormatRGBA16Unorm`; GL performs
  no sRGB conversion for non-sRGB attachments regardless of the flag, so the
  flag is ignored for FBO passes.

## Pipeline-state cache

PSOs are cached by key `(program, blend, attachment format)` and built lazily.
Formats in play: `BGRA8Unorm`, `BGRA8Unorm_sRGB` (drawable views) and
`RGBA16Unorm` (layer FBO). Blend state mirrors `set_blending`
(premultiplied `ONE, ONE_MINUS_SRC_ALPHA`; disabled = opaque write). A PSO’s
`colorAttachments[0].pixelFormat` always equals the encoder’s target view
format — mismatches are a Metal validation error and were the prior
implementation’s layered-path black screen (triage defect D1).

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

## Known deviations (tracked, intentional)

- Cell/graphics MSL shader *logic* is still the opus-era port; semantic drift
  against current GLSL (attr bit shifts, fg_override fix, bgimage preload) is
  Phase 3 (gates G2–G7 golden diffs).
- `presentsWithTransaction` live-resize sequencing and CADisplayLink pacing are
  Phase 4.
