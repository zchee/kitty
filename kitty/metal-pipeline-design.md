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

## Pacing: the CAMetalDisplayLink render driver (Phase 4 / L1)

On the Metal backend, per-window rendering is driven by a **`CAMetalDisplayLink`**
(macOS 14.0+, unconditional at the 15.3 build floor) instead of the legacy
CVDisplayLink render-frame gate. The CVDisplayLink machinery
(`glfw/cocoa_displaylink.m`) stays verbatim for the **GL/NSGL backend** — the two
paths branch on `window->context.metal.display_link` / `KITTY_BACKEND_METAL`.

### Topology — one link per window (per `CAMetalLayer`)

The link is created in `_glfwCreateContextMetal` via
`[[CAMetalDisplayLink alloc] initWithMetalLayer:layer]`, so it is bound to the
window's layer and **follows that layer's display automatically** across monitor
moves. This is strictly simpler than CVDisplayLink's per-`CGDirectDisplayID`
registry (no `displayLinks` table, no `displayIDForWindow` re-keying on screen
change) and handles multi-window / multi-display correctly by construction: each
window owns exactly one link. (Verified against apple-docs: `init(metalLayer:)`.)

### Callback → inline render → present

The link is added to the **main run loop** in `NSRunLoopCommonModes`, so its
delegate `metalDisplayLink:needsUpdate:` (`glfw/metal_context.m`,
`KittyMetalDisplayLinkDelegate`) fires **on the main thread**, interleaved with
kitty's `[NSApp run]` event loop — no CVDisplayLink-thread → `dispatch_async` →
`postEmptyEvent` double hop, and no stuck-link watchdog (both retired on the
Metal path). The delegate:

1. publishes `update.drawable` (a vsync-timed `CAMetalDrawable`) +
   `targetPresentationTimestamp` on the window context, then
2. invokes the kitty render callback `cocoa_metal_frame_callback` (`kitty/glfw.c`),
   which sets `render_state = RENDER_FRAME_READY`, hands the drawable to
   `metal_set_link_drawable()`, and calls **`render_os_window()` synchronously**
   — rendering + presenting THIS frame inside the callback (the precedent is
   `cocoa_out_of_sequence_render`).

This is safe because the **main thread holds the Python GIL for the entire
lifetime of `[NSApp run]`** (the I/O thread `io_loop` only fills the VT-parser
buffer under mutexes — it never touches Python — so there is no
`Py_BEGIN_ALLOW_THREADS` around the loop). The delegate therefore holds the GIL
and `render_os_window`'s `call_boss(...)` calls are legal.

`metal_end_frame` presents with a **plain** `[commandBuffer presentDrawable:]` —
timed present variants (`presentDrawable:atTime:` / `afterMinimumDuration:`)
assert under CAMetalDisplayLink (apple-docs). `preferredFrameLatency = 1.0`
(only 1.0/2.0 are valid; macOS windowed mode may raise the effective latency);
`preferredFrameRateRange = CAFrameRateRangeDefault` (== display max, ProMotion;
a `CAFrameRateRangeMake` with a 0 minimum throws `NSInvalidArgumentException` —
learned at runtime).

### Drawable hand-off — `drawable_wait_ms` redefined to 0

`ensure_drawable()` now uses the link-delivered drawable when
`metal_set_link_drawable()` set one, **short-circuiting `nextDrawable`
entirely**. The nextDrawable backpressure that Wave-2/3 measured
(`drawable_wait_ms`) is **structurally absorbed by the link scheduling its
callback**, so on the link path `drawable_wait_ms` is always **`0.000`**. The
field is KEPT in the `metal_stats` line (tolerant-parser stability) but its
meaning is redefined: it is 0 whenever a link drawable drove the frame, and
retains its old "time inside `nextDrawable`" meaning only on the non-link paths
(golden dump, live resize). The wire format is otherwise unchanged
(tail-appended keys only).

### Idle pause / resume — the render-frame state machine

The 3-state `render_state` machine is reused: **NOT_REQUESTED** ⇒ link paused
(removed from the runloop); **REQUESTED** ⇒ link running (set by
`request_frame_render`, which resumes the link in `requestRenderFrame`); **READY**
⇒ transient, set by the delegate before the inline render. Damage reaches
`render_os_window`'s gate with the link paused → `request_frame_render` resumes it →
the next tick renders. A link tick that finds nothing to draw pauses the link and
resets to NOT_REQUESTED, keeping a 60 s idle window at **presents == cursor-blink
frames only** (criterion 7). The `removeFromRunLoop`/`addToRunLoop` idle pause/resume
is **reliable** — a healthy session performs hundreds per run (~25 PAUSE/RESUME pairs
per run in the linktrace). It was NOT the source of any freeze.

### Live resize — and the Wave-4 once-then-freeze defect

The "renders once then freezes" defect was **NOT** the idle pause/resume and **NOT**
activation/occlusion throttling — both earlier hypotheses were falsified by the
linktrace. **ROOT CAUSE:** macOS emits a **spurious `viewWillStartLiveResize` when a
window becomes key at startup, with no matching `viewDidEndLiveResize`.** Trace-proven:
broken runs show `FIRST_TICK → RESIZE_START → link removed → (nothing)`; healthy runs
have zero resize events. Rate ~5–10%, clustered by activation timing.

Design (destroy/recreate, not pause):

- **`viewWillStartLiveResize` DESTROYS the link** (not pause). The drag renders via
  `cocoa_out_of_sequence_render`'s `nextDrawable`, and an attached link — even removed
  from the runloop — owns the drawable pool: `nextDrawable` returns nil, and a link
  resumed after the resize delivers a **dangling drawable** (SIGSEGV in
  `begin_render_pass_to_drawable`). Destroying detaches it (the proven
  `sync_to_monitor=no` path). `change_live_resize_state()` **EXIT recreates a fresh
  link** (a brand-new link has a clean pool; resuming/re-adding the resize-corrupted
  link crashed or stalled) and marks REQUESTED.
- **DEFECT 2:** `change_live_resize_state()` **ENTER destroys the link** (idempotent)
  before the inline render — a programmatic resize (`kitty @ resize-os-window`, any
  `setFrame`) enters with no AppKit `viewWillStartLiveResize`, so this pins the
  invariant "the layer is link-free wherever inline `nextDrawable` runs".
- **Recovery** for a spurious resize with no `viewDidEndLiveResize` is driven by
  `process_pending_resizes`'s debounce (it calls `change_live_resize_state(false)`),
  which runs before `render()` each loop; the **render()-loop backstop** in
  `child-monitor.c` is a defensive fallback for when the debounce cannot run.
- **The delegate MUST NOT guard on `w->ns.live_resize_in_progress`.** The debounce
  clears the kitty-side `w->live_resize.in_progress` but not the GLFW-side flag, and
  guarding on it froze a freshly-recreated link (it ticked but never called the
  callback). The **sole** resize guard is the kitty-side flag checked in
  `cocoa_metal_frame_callback`.
- **`requestRenderFrame` (Metal) never falls back to the CVDisplayLink** when the link
  is transiently absent: that path drives `cocoa_metal_frame_callback` into
  `nextDrawable`, and once the link is recreated `-[CAMetalLayer nextDrawable]` **RAISES
  an NSException** (attached-link conflict) → abort.
- **DEFECT 1:** `glfwCocoaResetLiveResizeGuards` (backstop) and the link-create
  `presentsWithTransaction` reset both **decline while the left mouse button is down**
  (`[NSEvent pressedMouseButtons] & 1`, a genuine paused drag) — dropping
  presentsWithTransaction or recreating the link mid-transaction would detach the
  content from the window chrome for the rest of the drag.

Verified: forced stuck-resize repro **10/10 sync=yes** (worker-pace, independently
re-verified 10/10 by the verify pass); **sync=no is structurally N/A** — with no
link there is no delegate, so the force hook cannot fire, and the linkless inline
path is the already-proven mode. Kill-switch runs (`KITTY_METAL_NO_RESIZE_RECOVERY=1`)
passed **7/7**: recovery came from the debounce path alone every time, so the
backstop is **implemented, code-reviewed, and unexercised** defense-in-depth.
Natural soak **34 runs** (0 triggers), programmatic resize **×20** (0 nil-spin, 0
crash, link delivering after), **0 crashes** across ~100 runs, both backends
`-Werror` clean, and
the **visible-but-inactive** experiment PASS (a visible, uncovered, app-inactive
window still renders — 37.9→27.7 presents/s, macOS's allowed background throttle, not
a stall; so no linkless fallback is needed). Repro/regression levers kept:
`KITTY_METAL_FORCE_STUCK_RESIZE` (dispatch_async, mirrors the AppKit event),
`KITTY_METAL_LINKTRACE_FILE`, `KITTY_METAL_NO_RESIZE_RECOVERY` (kill switch).

**Caveat (honest):** the natural trigger fired 0/34 times post-fix — acceptance rests
on FORCED fidelity, substantiated by the two extra defects the faithful dispatch_async
force exposed (the delegate ns-guard freeze and the CVDisplayLink-fallback NSException
crash) that a same-pass force masked. The DEFECT-1 mouse-button decline is implemented,
reviewed, and linktrace'd (`RESETGUARDS_DECLINE`/`ACCEPT`) but not empirically driven —
`CGEventPost` needs an Accessibility grant that is not present in CI; it is on the user
checklist (`.omc/verify/wave4/defect1_manual_checklist.md`). NOTE for #5: the spurious
`viewWillStartLiveResize` is ACTIVATION-clustered, so no-activate test launches may make
the natural trigger even rarer — test silence is NOT evidence the quirk is gone; the
forced repro (`KITTY_METAL_FORCE_STUCK_RESIZE`) remains the regression lever.

**Recovery residues (known, accepted):** a debounce-path recovery clears only the
kitty-side flag, so GLFW's `ns.live_resize_in_progress` stays latched until the next
real `viewDidEndLiveResize` — `windowDidResize` then routes subsequent resizes
through the live-resize render path (cosmetic; self-corrects on the next genuine
resize end). And because the link-create `presentsWithTransaction` reset declines
while a mouse button is down (DEFECT 1), a recovery that lands during an unrelated
drag leaves `presentsWithTransaction=YES` (synchronous present path) until the next
link create or real resize end.

**Timing verification status:** pacing structure (idle-pause, typing-pace,
keystroke-bytes, `MTL_DEBUG_LAYER`) is byte-identical across 5/5 trials even under
sustained load, and PTY-write→present p50 (62–66 ms) matches the pre-regression
baseline. The Wave-4 p99 captures (loadavg 6–9, LOAD-DEGRADED) were re-run in
Wave 5 at loadavg 3.2–6.2 with launchservicesd quiet (`pace_probe.py
--take-focus`, now required: no-activate test windows can spawn fully occluded —
as they did this session — and the occlusion gate then renders 0 frames): 3/5
trials valid (trials 4–5 hit an unrelated loadavg 10–20 spike and are
discarded), PTY-write→present p50 62.1–63.2 ms confirms the baseline, flood
cadence byte-identical (16.6667 ms p50=p99), idle presents 0 over 60 s. The
gpu_ms/encode_ms comparison against the Wave-3 closeout
(`stats-percentiles-wave3-result.json`: gpu 0.251/1.229 ms p50/p99, encode
0.078/0.185 ms) is CLOSED: gpu_ms 0.19–0.31 / 1.06–1.73 ms (within run-to-run
variance, no regression) and encode_ms ~0.024 / 0.049–0.059 ms (~3× better).
One honest surprise: the PTY-write→present p99 tail (179–271 ms, ~1/40 bursts)
persists at moderate load, so it was never load-caused — the Wave-5 IOSurface
spike (below) shows it is a link-resume artifact (it has no counterpart with
the link removed). A pristine sub-3-loadavg run remains open only as a
formality; the numbers above are the working reference.

### `maximumDrawableCount` = 2 — measured decision

With the link delivering a vsync-timed drawable to every callback there is no
CPU-side `nextDrawable` race, so a 2-deep pool is optimal. Measured under
flood + typing (M3 Max, 60 Hz session, `.omc/verify/wave4/pace_probe.py`):

| | count 2 | count 3 |
|---|---|---|
| flood present interval p50 / p99 / max | 16.6667 / 16.6668 / 16.6668 ms | 16.6667 / 16.6668 / 16.6668 ms |
| flood `drawable_wait_ms` (all pctiles) | 0.000 | 0.000 |
| flood fps | 58.0 | 57.7 |
| PTY-write→present p50 | **62.3 ms** | 64.3 ms |

Count 3 gives **byte-identical cadence and zero tail stalls** (no smoothness
gain) while adding ~2 ms of PTY-write→present latency (one more frame of queue
depth). The pre-Wave-4 "60 ms tail stall at count 2" was an artifact of the
old 2-pass pipeline; it is gone. **Verdict: keep 2** — shallowest presentation
queue == lowest latency, and pacing is already perfect at 2.

### Latency vs. smoothness (before/after) and the L2 follow-up

vs. the CVDisplayLink baseline (`.omc/verify/wave4/pace_baseline.json`):

| | baseline (CVDisplayLink) | CAMetalDisplayLink |
|---|---|---|
| flood fps | 33.7 | **58** |
| flood `drawable_wait_ms` p99 / max | 0.049 / 6.411 ms | **0.000 / 0.000** |
| PTY-write→present p50 | 31.1 ms | 62.3 ms |

The link **doubles sustained-scroll smoothness** (the baseline render-gate +
`displaySyncEnabled` collapsed flood to every-other-vsync ≈ 30 fps) and zeroes
drawable backpressure, but the **cold keypress path is ~1 frame slower**: the
link-delivered drawable is presented for a *future* vsync (windowed-mode frame
latency), so a keystroke that arrives while the link is paused pays a
resume + present-buffering beat. This is the CAMetalDisplayLink
latency-vs-smoothness tradeoff. The low-latency path is **`sync_to_monitor=no`**
(L3 below); the default-mode fix (**L2 immediate-encode**) is deferred — see below.

### `pace=` observability (Phase 4 step 6)

Both `metal_stats` and `metal_present` lines gain a **tail-appended `pace=`**
field attributing each frame's scheduling source, so verification can tell them
apart. Values (priority order, computed in `metal_end_frame`):

- `resize` — the `presentsWithTransaction` live-resize present.
- `unsynced` — `sync_to_monitor=no` (`displaySyncEnabled=NO`), immediate present.
- `link` — a CAMetalDisplayLink-delivered drawable drove the frame.
- `immediate` — an L2 input-driven `nextDrawable` render (see the deferral note).

Harness note: parsers must tolerate `pace=<string>` (it is NOT numeric). Existing
tolerant parsers already ignore unknown keys; the value is a bare token, never
`$`-anchored. `metal_ms_since_last_present()` is also exported (used by L2's gate).

### L3 — `sync_to_monitor=no` maps to `displaySyncEnabled=NO`

`sync_to_monitor=no` is kitty's documented low-latency (tearing) config. On the
GL backend it means swap-interval 0; on Metal it maps to `displaySyncEnabled=NO`
+ immediate present. But there is a hard constraint: **an attached
CAMetalDisplayLink — even paused, even removed from the runloop — owns the
layer's drawable pool and makes `nextDrawable` return `nil`**. `sync_to_monitor=no`
sets `USE_RENDER_FRAMES=false`, which bypasses the link gate and renders inline
via `nextDrawable`; with the link present that path rendered **0 frames** (a blank
window — a latent Metal-backend gap since L1 always used the link).

Fix: `sync_to_monitor=no` **destroys** the window's CAMetalDisplayLink
(`glfwCocoaSetRenderLinkEnabled(false)` → `destroy_metal_display_link`, factored
alongside `create_metal_display_link`); `=yes` keeps/recreates it. `swapIntervalMetal`
maps the swap interval onto `displaySyncEnabled` (0 → NO). Measured (M3 Max,
`pace_probe.py --sync no`): `sync_to_monitor=no` renders (105 frames, `pace=unsynced`),
PTY-write→present p50 **42.8 ms vs 62.5 ms** for `=yes` (link) — the intended
lower-latency mode. `=yes` (default) is unchanged (task L1 link, `pace=link`,
`drawable_wait_ms=0`); MTL_DEBUG_LAYER clean in both modes.

### L5 — adaptive `input_delay` (echo fast-path)

The I/O thread coalesces main-loop wakeups until `input_delay` (3 ms default)
elapses. L5 fast-paths the **echo of a keystroke**: `on_key_input` stamps
`last_local_key_input_at` (relaxed atomic, main thread); `io_loop` wakes the main
loop **immediately** when a SMALL read (`≤128 B`, via `read_bytes`'s new byte
count) arrives within 50 ms of a key press — skipping the batch so the first echo
renders ~`input_delay` sooner. Bulk output (large reads) keeps batching, avoiding
full-redraw flicker. Backend-agnostic (I/O path); `kitty_tests` green (data
integrity), no drawable interaction.

### L2 — immediate-encode-on-input: DEFERRED (documented)

L2 would render an input frame immediately via `nextDrawable` instead of waiting
for the next link tick, in the DEFAULT (`sync_to_monitor=yes`) mode. But that
requires `nextDrawable` while the link is active, which **corrupts the drawable
pool → SIGSEGV** (the link's `update.drawable` goes dangling in
`begin_render_pass_to_drawable`; confirmed via `KITTY_METAL_IMMEDIATE=1` A/B —
1-frame crash on, 100+ frames clean off). Same root cause as L3: the link and
`nextDrawable` cannot share a layer. Destroying/recreating the link per keystroke
(as L3 does per-window) is too costly on the input hot path. The correct fix is
the Ghostty-style **IOSurface-backed render target + `CALayer.contents`**
presentation model (plan Phase-4 step 7), which owns presentation without a
drawable pool — a separate spike (now priority-next, see the pFL result below).
The `pace=immediate` tag + `metal_ms_since_last_present` plumbing stay as
groundwork, but `KITTY_METAL_IMMEDIATE` is **neutered** — it logs one line
(`immediate-encode requires the IOSurface presentation model … ignored`) and does
nothing (never activates the crashing path), so there is no shippable landmine.
Until then the default mode's low-latency answer is `sync_to_monitor=no` (L3).

**Wave-5b update: GRADUATED.** The IOSurface presentation model shipped as the
default (see "Wave-5b: the flood pacing governor" below): there is no drawable
pool to corrupt, so `metal_immediate_encode_enabled()` is true on that path and
input-driven frames render immediately. `KITTY_METAL_IMMEDIATE` stays inert —
the fast path no longer needs a flag (it is intrinsic to the model), and the
env is only a logged no-op on the legacy (`KITTY_METAL_IOSURFACE=0`) path.

### `preferredFrameLatency` is a no-op for cold latency (measured)

Before deferring, we swept the one remaining default-mode knob. apple-docs:
`preferredFrameLatency` is "the amount of time, in frames, your app requests to
render a frame … The only acceptable values are **1.0 and 2.0**" — so 1.0 is the
documented floor (nothing below to try). It governs GPU-completion slack, not the
present target. Measured default-mode cold PTY-write→present (M3 Max, 3 runs each,
`pace_probe.py --sync yes`):

| preferredFrameLatency | best-min | median-p50 |
|---|---|---|
| 1.0 (shipped) | 54.0 ms | 63.4 ms |
| 2.0 | 54.0 ms | 62.7 ms |

**Statistically identical** (0.7 ms p50 delta = run-to-run noise). Our frames
complete in <1 ms GPU, so 1-vs-2 frames of completion slack is irrelevant; the
~54–63 ms cold latency is the link **cadence** (paused-link resume + wait for the
next vsync-timed callback + the windowed-mode present pipeline), which pFL does not
touch. Conclusion: default-mode cold latency is **not pFL-reducible**; 1.0 stays
(least requested latency). The honest tradeoff: default mode buys 2× flood
smoothness + `drawable_wait_ms=0` at ~+1 frame cold-keypress cost vs the old
CVDisplayLink baseline; `sync_to_monitor=no` (L3, ~42 ms) is the low-latency path;
closing the default-mode gap is the **IOSurface follow-up** (priority-next).

### Wave-5 spike: the IOSurface presentation model — ADOPT (now the DEFAULT; =0 is the kill switch)

`KITTY_METAL_IOSURFACE=1` (spike, default off) replaces drawable presentation
wholesale, following the Ghostty model the L2 deferral pointed at (plan Phase-4
step 7): frames render into IOSurface-backed BGRA8Unorm textures from a 3-deep
per-window ring (slots skipped while `IOSurfaceIsInUse`, i.e. held by the
window server) and present by assigning the surface to `layer.contents` inside
an explicit `CATransaction` (+`flush`, so an enclosing implicit AppKit
transaction cannot defer the swap) after `waitUntilCompleted` — no implicit
GPU→CA fence exists for manually assigned contents, and terminal frames encode
<1 ms of GPU work, so the inline wait is cheaper than a completed-handler
round trip (Ghostty's synchronous path makes the same call). No
CAMetalDisplayLink is created (`glfw/metal_context.m` no-ops link creation)
and `USE_RENDER_FRAMES` is off (`kitty/child-monitor.c`), so damage renders
inline on the next main-loop tick exactly as `sync_to_monitor=no` does — but
the composite stays vsync-clean because Core Animation picks the new contents
up at the next display refresh. The drawable pool does not exist on this path,
which dissolves the L2 blocker by construction: every input-driven frame IS an
immediate render+present.

Measurement semantics: `presentedTime` does not exist for a contents
assignment, so `metal_present … pace=iosurface` lines are stamped by a
CADisplayLink (macOS 14+, `NSScreen.mainScreen`, paused whenever no present is
pending) with the first display-refresh timestamp at/after the CA commit;
`commit_time=` is tail-appended for offline bounding. The stamp is a lower
bound within one refresh (16.7 ms at 60 Hz) of true glass time — optimistic
when the render server misses that refresh's deadline. Every conclusion below
survives the worst-case correction.

A/B: 60 Hz session, M3 Max, loadavg ~3.3–3.9, interleaved 3 runs per arm
(`pace_probe.py --take-focus --sync yes`, 40 bursts each;
`.omc/verify/wave5/ab_*.json`):

| PTY-write→present | link (default today) | iosurface |
|---|---|---|
| p50 | 78.5–79.3 ms | **13.6–15.5 ms** |
| p90 | 84.6–86.4 ms | 19.7–21.7 ms |
| p99 / max | 202–209 ms | **21.8–26.3 ms** |

Even with the full one-refresh pessimistic correction (+16.7 ms), iosurface
p50 ≤ 32 ms vs link ~79 ms. The link arm's 200 ms-class p99 tail (present in
every Wave-4/5 link capture, including the quiet re-runs above) has no
iosurface counterpart — so the tail is the link's idle→resume path
(removeFromRunLoop/addToRunLoop + first vsync-timed callback), not machine
load. Also verified in iosurface mode: `MTL_DEBUG_LAYER=1` clean, passes=1
(single-pass pipeline intact), steady-state allocs=0 and dirty-upload bytes
unchanged (D1/D2 intact), idle presents 0 (no link needed for idle-quiet: no
damage, no render).

The measured cost, exactly as the plan's pre-mortem predicted: flood renders
unpaced — ~185–186 fps encoded vs the link's vsync-locked 58 fps. CA coalesces
to the refresh rate on glass, so the extra ~128 fps is pure invisible work
(CPU/GPU/energy), and present-interval stats read differently under coalescing
(multiple frames share one refresh stamp).

**Verdict: ADOPT** — this is the architecture that closes the default-mode
cold-latency gap (§ "`preferredFrameLatency` is a no-op") and it also removes
the link's own resume tail. Productization prerequisites before it can replace
the link as the default:

1. **Flood pacing governor** — DONE (Wave-5b below): flood encodes at the
   refresh cadence (measured 59.3 fps, cadence p50=p99 16.6667 ms), settling
   the 186→58 fps waste and the energy criterion (§7 #9).
2. **Colorspace decision** — the spike attaches no colorspace to the surfaces;
   composite parity with the CAMetalLayer nil-colorspace policy is plausible
   but UNVERIFIED (the golden harness reads the pre-composite offscreen, and
   `screencapture` needs a Screen Recording grant — user checklist: eyeball a
   KITTY_METAL_IOSURFACE=1 window against a normal one).
3. **Resize / multi-display / occlusion soak** — live resize takes the same
   contents-swap path inside the resize transaction (structurally sound, only
   smoke-tested); the measurement stamper is `NSScreen.mainScreen`-bound.
4. **Ring lifecycle** — DONE (Wave-5b): `metal_forget_layer` frees the ring
   AND the per-window state slot from `destroy_os_window` (kitty/glfw.c), so
   the 3 × ~1–31 MB surfaces die with their window.
5. **L2/L5 groundwork subsumed** — DONE (Wave-5b): the immediate-encode gate
   is live on this path (`pace=immediate`), `KITTY_METAL_IMMEDIATE` is inert,
   and the per-window floor lives in `OSWindow.last_gpu_present_at`.

Keypress→presented (CGEvent) A/B remains blocked on the Accessibility grant
(`CGPreflightPostEventAccess()` returns false — the same user-checklist item
as the DEFECT-1 empirical drive); PTY-write→present is the decisive proxy
meanwhile.

### Wave-5b: the flood pacing governor, and the default flip

The governor is the Wave-4 render-frame architecture with the drawable pool
removed — not a new mechanism:

- **Pace link.** `create_metal_display_link` (glfw/metal_context.m) now vends
  a plain **CADisplayLink** (NSWindow-bound, macOS 14+) instead of a
  CAMetalDisplayLink: the same per-window vsync-timed callback cadence and the
  same lifecycle (created unpaused; idle pause = runloop removal; DESTROYED
  for live resize and `sync_to_monitor=no`; recreated on resize end by
  `change_live_resize_state`), but a pure timer that owns no drawable pool.
  Its tick publishes no drawable — `glfwGetCocoaPendingMetalDrawable()`
  returns NULL and `ensure_drawable()` takes the IOSurface ring.
  `USE_RENDER_FRAMES` is restored to its Wave-4 form, so the render gate
  defers sustained damage to link ticks: **flood encodes at the refresh rate,
  not the parse rate**.
- **Input fast path.** The L2 immediate-encode gate is live
  (`metal_immediate_encode_enabled()` == true on this path): input-driven
  damage arriving while the link is idle (`render_state NOT_REQUESTED`)
  renders + presents immediately (`pace=immediate`), then
  `render_prepared_os_window`'s `request_frame_render` resumes the link so a
  flood transitions to paced ticks after ONE immediate frame. The 8 ms floor
  is **per-window** (`OSWindow.last_gpu_present_at`, stamped at swap — the
  present is synchronous with the swap here), so one window's flood cannot
  starve another window's fast path.
- **Default flip.** `KITTY_METAL_IOSURFACE` unset (or any value but `0`) =
  the IOSurface model; `=0` = the legacy CAMetalDisplayLink + drawable path,
  kept intact as the kill switch (it also revives
  `KITTY_METAL_FORCE_STUCK_RESIZE`, which lives in the legacy link's
  delegate). Both env checks (kitty/metal.m and glfw/metal_context.m) must
  stay in agreement.
- **Ring lifecycle.** `metal_forget_layer` (called from `destroy_os_window`)
  releases the window's surface ring and its per-window state slot; CA retains
  whatever surface is still on glass, so the release is safe mid-composite.

Measured (no-focus arms, SAME conditions, M3 Max 60 Hz session, user-active
machine at loadavg ~3–5; `.omc/verify/wave5/gov_*.json`):

| PTY-write→present | legacy (=0) | default (governor) |
|---|---|---|
| typing p50 / p90 | 64.4 / 73.7 ms | **25.8 / 33.3 ms** |
| typing pace mix | link ×40 | iosurface ×38, immediate ×2 |
| flood fps / pace | 53.7 (all link) | 59.3 (all iosurface) |
| flood cadence p50 / p99 | 16.6667 / **66.7 ms** (4-frame stalls) | **16.6667 / 16.6667 ms** |
| idle presents (3 s) | 0 | 0 |
| worst single burst | 436.6 ms (link-resume tail) | 297.0 ms (ambient load; n=1) |

The governor closes the spike's one measured cost: flood encode collapsed
from ~186 fps to the refresh rate with a byte-perfect cadence — under load
where the LEGACY path dropped frames (cadence p99 66.7 ms). Cold typing is
2.5× faster than legacy under identical conditions.

**Honest nuance — why typing shows ~26 ms, not ~14 ms:** a lone PTY-write
burst is batched by `input_delay` (3 ms), so the render usually happens on a
LATER main-loop tick where `input_driven` is false — the burst takes the
paced path (one link tick, ~26 ms), not the immediate path. A real keyboard
echo does NOT hit this: the L5 fast path parses the echo on the arrival tick
(input_read true at render), which is exactly the immediate gate's condition
— the debug smokes show first-damage frames at `pace=immediate` with
presented−commit ≈ 2–15 ms. Empirical keypress→present percentiles still
await the Accessibility grant (CGEvent injection). If PTY-burst latency ever
matters in its own right, the follow-up is carrying an "input pending render"
flag across the input_delay boundary.

### Wave-5c: asynchronous present

The Wave-5b present stalled the main thread in `waitUntilCompleted` for
every frame (~0.3–2.5 ms GPU time each; ~30% of flood main-thread time in
the Phase-5 profile). Wave-5c moves the swap off that wait: the frame
commits, and the command buffer's completed handler dispatches the
`layer.contents` swap to the main queue (Ghostty's `setSurface` requires
the same main-thread affinity — `isMainThread ? direct : dispatch_async`;
we always dispatch, which also serializes the swap with resize-path layer
mutations and keeps the measurement stamper main-thread-only with no
locking). The swap block owns its references: the CF surface is explicitly
retained into the block and the layer is retained by the block copy (MRC),
so a window closing mid-flight cannot UAF — `metal_forget_layer` and ring
release stay safe.

Ring safety under async: the frame's GPU write is now in flight after
`metal_end_frame` returns, so acquire marks the chosen surface with
`IOSurfaceIncrementUseCount` (dropped after the swap, or in the end-frame
tail for frames that never hand off) — the existing `IOSurfaceIsInUse`
probe therefore skips slots held EITHER by the window server OR by an
uncompleted GPU write. Governor pacing keeps at most ~1 frame in flight +
1 on glass, so the 4-deep ring still always has a clean slot in steady
state; when none is clean (present burst), the frame is marked dirty and
presents synchronously rather than rendering into a surface someone still
reads. Three cases always swap synchronously: live resize
(`presentsWithTransaction` — the swap must land inside the resize
transaction), dirty ring slots, and the `KITTY_METAL_SYNC_PRESENT=1` kill
switch (restores Wave-5b behavior wholesale).

Measurement semantics update: `metal_present … commit_time=` now records
the SWAP time (post-GPU-completion, when contents was assigned on the main
queue), not the command-buffer commit; `presented_time` semantics are
unchanged (first refresh at/after the swap). `gpu_ms` was already emitted
from a completed handler, so it needed no change.

Measured (interleaved same-conditions arms, async vs KITTY_METAL_SYNC_PRESENT=1,
loadavg 5.0–5.4 NOT degraded; artifacts .omc/verify/phase5/w5c-*.json and
.omc/verify/wave5/w5c_async_probe.json):

| metric | sync (Wave-5b) | async (Wave-5c) |
|---|---|---|
| ASCII MB/s, default 100×30 window | 146.4 | 147.2 (no change) |
| ASCII MB/s, 2560×1440 window | 116.1 / 115.7 | **118.7 / 118.2 (+2.2%, both pairs)** |
| scroll-ASCII MB/s, default | 112.7 | 112.7 |
| cold typing p50 / p99 (pace_probe) | 25.8 / 46.1 ms (5b ref) | **14.7 / 38.0 ms** |
| typing pace mix | iosurface 38 / immediate 2 | iosurface 32 / immediate 8 |
| flood fps / cadence p50=p99 | 59.3 / 16.6667 ms | 59.7 / 16.6667 ms |
| idle presents (3 s) | 0 | 0 |

Review hardening (architect pre-review, 1 major + 2 minors, all fixed):
**(f) async→sync reorder** — a dirty-slot/resize frame swaps synchronously
while an older async frame's swap block may still sit on the main queue, so
the older contents could land after the newer (stale frame on glass, most
likely exactly under flood bursts). Fixed with a per-layer monotonic
**present-generation guard**: every swap (all main-thread) records the global
frame index; a swap older than the last recorded for that layer is dropped
(references still released). Entries are created at acquire, recycled in
metal_forget_layer — a pending block for a destroyed window misses its lookup
and skips. **(g)** ring depth 3→4 (async keeps encoding + GPU-in-flight +
queued-swap + on-glass alive at once) so the dirty-slot fallback — whose
blind pick can tear one refresh — becomes rare; the guard makes its sync swap
reorder-safe. **(a-leak)** metal_forget_layer now drops the GPU-in-flight
mark symmetrically for an acquired-but-never-presented frame. **(nit)**
KITTY_METAL_SYNC_PRESENT=1 skips the use-count marks entirely, keeping the
kill switch byte-identical to Wave-5b IsInUse semantics. Post-fix: smoke
async=2/sync=1 + kill-switch all-sync + MTL_DEBUG_LAYER clean; probe p50
15.4 ms / idle 0 / 59.7 fps (one 33.3 ms flood interval in 179 = a single
coalesced tick, p50 cadence exact).

Honest attribution: the throughput ceiling of async present is the per-frame
GPU wait itself (~gpu_ms × ~59 fps ≈ 2–9%), and the measurement matches — the
Phase-5 profile's "~30% render-side" bucket was dominated by encode + upload,
which remain synchronous by design (the next lever there would be a render
thread, out of scope). The real win is responsiveness: the main loop never
stalls on the GPU, which shows up as cold typing p50 dropping from ~26 ms to
~15 ms (the loop is free to parse the moment damage arrives) and a larger
immediate-path share. MTL_DEBUG_LAYER clean; kill-switch arm behaves
identically to Wave-5b (async=0, all swaps sync).

## Phase 5 (Wave 6): CPU throughput — the flood path

Plan items P1/P2/P4/F6a (.omc/plans/…-worlds-fastest-optimization.md §Phase 5),
measured on the Wave-5b (IOSurface+governor) build. Artifacts:
`.omc/verify/phase5/*.json`.

**P1 — batched ASCII run-fill (kitty/screen.c)**: inside the draw loop's
ASCII fast path, a printable-[0x20,0x7E] run is scanned once and filled in
bulk per line chunk — `memset_array` GPUCell template broadcast (the
linebuf_clear_lines pattern) plus register-built 12-byte CPUCell stores, one
cursor advance per chunk. Gate conditions: identity charset, no IRM, no
pending grapheme state; `draw_ascii_run` stops early (consumed count) at a
multicell cell in the span or a full line with DECAWM off, so the scalar
loop's nuke/clamp semantics take over exactly. Levers:
`KITTY_DISABLE_ASCII_RUNFILL=1` (process) and
`set_ascii_runfill_enabled()` (in-process, for the differential test).

Same-binary interleaved lever A/B (kitten `__benchmark__ --render`,
spawn_kitty, load 4.4–5.0 NOT degraded):

| MB/s | scalar (lever off) | bulk | ratio |
|---|---|---|---|
| ASCII | 110.8 / 110.9 | 144.0 / 143.7 | **1.30×** |
| ASCII + scrollback | 92.4 | 110.8 / 111.1 | **1.20×** |
| CSI (REP flows through the same path) | ~52 | ~60 | 1.15× |
| Unicode | ~121 | ~121 | 1.00× (no regression) |

Differential fuzz (`kitty_tests/ascii_runfill.py`): comparator self-check +
16 deterministic adversarial cases (wrap ±1, DECAWM off, IRM, charset
shifts, wide/emoji/ZWJ, combining, tabs, CSI REP, SGR, hyperlinks,
cursor-move overwrite) + 200 seeded random cases (KITTY_FUZZ_SEED) — bulk vs
scalar byte-identical on as_ansi + hyperlink_ids + continuation flags +
cursor. It also surfaced a PRE-EXISTING bug (out of scope, documented in the
test): `Line.width()` returns a bare C 0 instead of `PyLong_FromLong(0)`
for empty cells → SystemError at the CPython boundary.

**P2 — decoder run signal: satisfied by measurement, plumbing rejected.**
The draw side scans each char exactly once by construction (the plan's
re-scan concern does not exist in the implementation). A fair double-scan
experiment (register loop + asm sink, same-load pair) put the single scan at
**~5.6% of ASCII time / ~3.3% of scroll** — the ceiling any decoder-side run
plumbing could recover, at real cross-module complexity (the decoder would
pay the same boundary detection unless fused into its SIMD masks). Rejected
per the plan's own over-engineering guard; revisit only if the parser is
ever SIMD-fused end-to-end.

**P4 — SIMD width**: KITTY_SIMD=128 vs 256 (SIMDE over NEON), same-conditions
pairs (LOAD-DEGRADED marked, relative comparison consistent): 256 ≥ 128
everywhere (ASCII 142–143 vs 140.8; unicode ~121 vs 115–119). **Keep 256**
(the current default). No change.

**F6a — ASCII pre-raster (kitty/fonts.c)**: at sprite-map init (one-shot,
GPU context guaranteed), 94 glyphs 0x21–0x7E for the base font render
through the exact live miss path (render_run → shape → CoreText →
send_sprite); 0x20 is excluded by design (BLANK_FONT never renders a
glyph). Measured 1.9 ms; sprites byte-identical to live-miss output 94/94.
Note: the benchmark kitten pre-warms all chars itself, so F6a is
benchmark-invisible — its value is the first flood after startup/font-size
change never hitting the miss path mid-frame.

**Exit-gate honesty (the plan's "≥2× Phase-0 Metal baseline")**: no Phase-0
throughput artifact was ever captured, and the Phase-0-era binary
(b1f94df47, rebuilt today in a worktree) SIGABRTs at startup on the current
stack ("fragmentFunction border_fragment cannot be used to build a pipeline
state" — function-constants validation), so a same-day Phase-0 anchor is
impossible. Against the only clean anchor — the same binary with the
run-fill lever off — Phase 5 lands **1.30× ASCII / 1.20× scroll**, short of
2×. The shortfall is decomposed (flood `sample` profile, post-P1): the
remaining wall is ~30% render-side main-thread work at 60 fps (present's
`waitUntilCompleted` + upload/encode — the async-present follow-up already
identified in Wave-5b productization), ~20% control-char/scroll structural
cost (linefeed clears 3.2 KB/line that the very next fill overwrites — a
clear/fill fusion candidate), and ~30% parser/decode. Those are the
quantified next levers; none of them is a Phase-5 plan item.

## Phase 6 (Wave 7): Atlas & graphics protocol

Plan items F1 / G1+G3 / G2 / G4 / G6 / F5, on top of Wave-5c. Artifacts:
`.omc/verify/f1|g1|g2|g4/` (goldens, alloc counts, wall-time split).

**F1 — R8 mask atlas (e1e901106).** The shaders read only `.a` for
monochrome text and every decoration; `.rgb` is consumed solely by colored
emoji (bit31). Mono sprites now live in an R8Unorm atlas — alpha extracted
at upload, texture swizzled A←R (Metal: descriptor swizzle; GL: texture
swizzle parameters) so all sampling code kept its `.a` reads — with colored
emoji in a small separate RGBA atlas + its own decorations LUT, both
selected by bit31. Two sprite trackers (mono keeps the F3 growth tuning;
colored is small, index 0 reserved). Measured: mono atlas exactly 1/4 the
bytes, −72% total on the golden content; goldens byte-identical (delta 0,
md5-equal) across ASCII+emoji+decorations+box on BOTH backends;
KITTY_NO_R8_SPRITE_ATLAS=1 restores the single-RGBA world. The golden
caught a real bug the suites could not: colored-atlas index 0 collided
with the `!idx` failure sentinel — first emoji rendered blank. Index 0 is
now reserved, mirroring the mono blank-at-0 invariant.

**G1+G3-lite — persistent animation textures + delta rects (1e3106dc8).**
Every frame advance re-specified the image texture (a full MTLTexture
release+realloc on Metal) and re-uploaded the whole coalesced frame. Frames
now update the persistent texture in place when dims are unchanged —
steady-state animation performs ZERO texture allocations per frame (was
one; proven by the new tex_allocs= stat) — and a non-blended delta frame
whose base is GPU-resident uploads only its rect (100× fewer bytes on a
synthetic partial-delta client). Honest scope note: icat transmits FULL
frames, so gif playback gains the realloc fix, not the byte win; the delta
path serves partial-delta protocol clients. is_opaque flips do NOT force
reallocs (internal format is uniformly SRGB_ALPHA; opacity only selects
the SubImage source format). Kill switches:
KITTY_NO_PERSISTENT_IMAGE_TEXTURE=1, KITTY_NO_DELTA_IMAGE_UPLOAD=1.

**G2 — instanced image draws (08daadff2).** Refs were already sorted into
same-texture group runs but drew one non-instanced quad each. Rects now
travel as vec4[16] uniform arrays (reusing the Metal array-uniform store
stride; GL 4.1 limits trivially satisfied) and each group draws as
16-instance chunks — blend order inside chunks and the
below/negative/positive z-split boundaries are exactly preserved
(kitty_tests/graphics.py locks the grouping). A 10-ref, 3-split, 2-texture
scene: 10 draws → 5 (gfx_draws= counter). Goldens byte-identical on BOTH
backends — the GL golden is a new capability (the backend-agnostic
thumbnail path reads the fully-rendered frame pre-swap and bypasses the
occlusion gate; GLSL only compiles at runtime, so this closes a
verification gap a clean build cannot). KITTY_NO_INSTANCED_IMAGE_DRAWS=1.

**G4 — async upload ring: DESCOPED on a measure-first gate.** The icat
large-image (24MB RGBA) main-thread wall splits: decode (inflate_png)
91.6%, upload (replaceRegion) 7.1%, cache 1.1%, parse 0.1% (median of 12,
tight ranges; .omc/verify/g4/FINDINGS.md). An async ring removes at most
the 2.63 ms upload from a ~37 ms hitch — the plan's own over-engineering
guard applies. The real lever is off-thread DECODE, deliberately out of
this phase; queued as follow-up. **G6 (zero-copy decode targets):
defer** — MTLBuffer-backed textures are genuinely zero-copy but Apple
documents they may forgo tiling optimization; trading a one-time 2.6 ms
upload for a recurring per-frame sampling penalty on long-lived images is
likely net negative today. **F5 (buffer-backed atlas): reject** — the
atlas is sampling-hot and write-cold; a linear layout would tax the
hottest read in the cell shader to speed a rare, tiny write. F1 already
captured the actual atlas win (memory).

**Exit-gate status (Phase 6):** atlas memory −72% (target ~−70%: PASS);
steady-state animation allocs 0/frame (PASS); goldens across
text/emoji/decorations/z-order configs byte-identical both backends
(PASS); suites at documented baseline both backends (PASS);
MTL_DEBUG_LAYER clean (PASS). PENDING VISIBILITY (recorded when a screen
window allows real rendering): animated-gif main-thread CPU% A/B
(fps is governor-capped at refresh by design since Wave-5b, so CPU% is
the meaningful axis) and the icat wall-time number for the doc table —
its verdict is already determined by the split above (decode-bound;
unchanged by this phase, documented shortfall vs the original gate
wording, with the analysis that G4 could never have moved it).

### Phase 7 evaluations

**D5 (GPUCell SoA/shrink): REJECT** — the struct is already 20 bytes with
no padding (5×uint32, static_asserted), and cell-buffer traffic does not
show on any realistic profile: GPU-side reads are 0.03% of M3 Max
bandwidth at 1440p/120Hz and 0.7% even at a deliberately pessimistic
6K-retina/240Hz/3-pass corner; D2 dirty-row uploads measure ~2.2 KB/frame
typing and ~42 KB/frame full-flood at 100×30. An AoSoA hot/cold split
would trim only the transparent bg-pass fetch (~0.006% of bandwidth) at
the cost of a second buffer, second dirty tracking, and per-variant VAOs;
bit-packing below 20 B adds shader unpack ALU and screen.c hot-path pack
cost on both backends to shave 30% of a 0.03% number. The plan's own gate
("implement only if bandwidth still shows") fails cleanly. Reconsider
only if a future profile at 8K-class geometry actually surfaces
cell-buffer bandwidth. (.omc/verify/us302/FINDINGS.md)

**G1 in-place-upload race (Phase-6 review finding, FIXED 2ef2e3462)** —
under async present a committed frame can still be sampling an image
texture while the next animation advance replaceRegions it; the per-frame
realloc that G1 removed had been an accidental guard. An ungated
completion watermark plus per-texture last-drawn frame tags now detect
in-flight use; both mutation sites (delta and in-place) fall back to the
fresh-texture path with a full coalesced upload that keeps the delta
chain resumable. Steady state remains zero-alloc; the racy fallback is
exercised by the KITTY_METAL_TEST_FORCE_INFLIGHT lever (alloc spike →
delta recovery, byte-identical output). Note for verification honesty:
synchronous/occluded goldens structurally cannot exercise async-present
races (the dump path waits for completion), so race coverage rests on
the watermark logic, the contention lever, and validation-layer stress —
not on golden parity.

## Final architecture (post-Phase-7 consolidation)

The frame path is native end to end; the GL-name shim survives only where
it is cheap and cold:

- **Presentation**: IOSurface ring (4-deep, use-count-guarded) presented by
  assigning `layer.contents` from the completed handler via the main queue
  (Wave-5c), ordered by the per-layer generation guard; paced by a plain
  CADisplayLink render gate + the intrinsic immediate-encode input path
  (Wave-5b governor). Kill switches: KITTY_METAL_IOSURFACE=0 (legacy
  CAMetalDisplayLink + drawable pool), KITTY_METAL_SYNC_PRESENT=1
  (synchronous swap).
- **Sprites**: dual atlas — R8Unorm mono (swizzled A←R) + small RGBA
  colored — with per-namespace decorations LUTs, selected by the cell's
  bit31 (F1). KITTY_NO_R8_SPRITE_ATLAS=1 reverts.
- **Images**: persistent textures updated in place (G1) with delta-rect
  uploads for resident non-blended bases (G3-lite), instanced same-texture
  group draws (G2), all guarded against in-flight sampling by the
  completion watermark (US-307).
- **Uniforms**: per-program C structs pinned to MSL layouts by
  _Static_assert, filled through slot caches resolved once per program
  lifetime (C5); the name-keyed store remains only as the value hop from
  the shared GL-shim setters, measured ~free (encode_ms 0.056 ms median).
- **Shim surface**: after the US-305 audit, the Metal build's shim exports
  only what shared code actually calls; 22 dead entry points (viewport /
  scissor / FBO-binding / raw draws / VAO / buffer ops the backend does
  natively) were deleted with grep proofs. The FBO surface is deliberately
  split: id + attachment tracking stay in the shim, binding is native.
  Kill-switch and test-lever paths (legacy present, FORCE_STUCK_RESIZE,
  TEST_FORCE_INFLIGHT, the neutered KITTY_METAL_IMMEDIATE logger) are
  policy, not dead code, and remain.

## §7 acceptance criteria — adjudication (living table)

Current verdicts with evidence; BLOCKED items name their unblocking
condition. Updated as captures land.

| # | criterion | verdict | evidence / blocker |
|---|---|---|---|
| 1 | baseline artifact, reruns <5% | PARTIAL | harness + artifacts exist (.omc/verify/*); a one-shot `make metal-baseline` JSON emission not re-validated on HEAD |
| 2 | passes/frame == 1 all configs, tile-load ≈ 0 | PASS | M1 single-pass layered; passes=1 in every stats capture since Wave 3 |
| 3 | zero steady-state allocs | PASS (counters) / PARTIAL (formal) | D1 allocs=0 + tex_allocs=0 across captures; the formal 5-min Instruments soak not run (sanitized-env Instruments session pending) |
| 4 | keypress→present p50 ≤ 9 ms (120 Hz), p99 ≤ 17 ms; sync=no p50 ≤ 3 ms | BLOCKED (Accessibility) | CGPreflightPostEventAccess=false; PTY proxy on 60 Hz: p50 ≈ 15 ms incl. input_delay+refresh. Also tracked: icat-transmitted GIF animations do not animate in ANY config (incl. legacy/kill-switch arms — pre-existing, not a phase regression; synthetic APC animation works) |
| 5 | throughput ≥ 2× Phase-0 AND ≥ kitty-GL AND vtebench ≥ Ghostty −10% AND devlog-006 first | MIXED (measured) | 2×: documented shortfall (lever A/B 1.30×/1.20×; Phase-0 binary unrunnable). ≥ kitty-GL: **MET** (devlog-006 0.50–0.52 s vs 0.58; churn 52 vs 47 MB/s, same commit). devlog-006 first: **NOT MET** — Alacritty 0.436–0.443 < Ghostty 0.445–0.463 < kitty 0.504–0.516 (LOAD-DEGRADED 14–15.6, grids equalized; gap ≈ the profiled parser share). vtebench: not captured this batch |
| 6 | pixel goldens ≤ 1 LSB vs GL reference | PARTIAL (characterized) | Cross-backend capture landed (.omc/verify/phase7/xbackend_golden.py, occlusion-immune; Metal via DUMP — the Metal thumbnail read is racy, a known pre-existing screenshot-path issue — GL via thumbnail): same scene visually, backgrounds and sampled solid interiors byte-identical, but glyph/edge composition differs up to 89/255 on ~12% of pixels (delta spectrum 1→89, ink-mask flicker 4% at thr=8; a black-vs-33 sample rules out a pure transfer-function mismatch). Root-cause (text composition/AA curve vs subpixel placement) queued as follow-up; not adjudicable as ≤1 LSB today and not yet documented as a deliberate policy exception |
| 7 | idle: blink-only presents, CPU < 0.3%, link paused | **PASS (formal)** | 60 s focused-idle capture: CPU 0.0% mean and max, presents beyond blink = 0 |
| 8 | stability: suites, DEBUG_LAYER, 10-min flood soak RSS < 5% | **PASS** | 10-min visible churn soak: RSS +0.35% (117.9→118.3 MB), 35,248 presents at 16.67 ms median cadence, 4 frames > 2× median in 35 k (none alloc-attributable; max interval is the teardown artifact), LOAD-DEGRADED noted |
| 9 | energy ≤ GL baseline | BLOCKED | powermetrics (operator sudo) + visibility |
| 10 | 1-line edit ≤ 8 KB | PASS | D2: ≈ 2.2 KB/frame typing capture |

## Future work (consolidated queue)

1. **Off-thread image decode** — the real icat-hitch lever (decode = 91.6%
   of the 24 MB wall; .omc/verify/g4/FINDINGS.md).
2. **Parser/decode throughput** — the devlog-006 gap to Alacritty (~15%)
   lives here (~30% of flood time profiled); candidate levers: SIMD-fused
   decode→draw, render thread for encode+upload.
3. **Cross-backend composition difference** — §7 #6, tracked in
   .scratch/metal-gl-composition-diff/.
4. **icat-GIF animation failure** — pre-existing, all configs; tracked in
   .scratch/icat-gif-animation/.
5. **Keypress→photon latency capture** — needs the Accessibility grant
   (§7 #4); PTY proxy stands in meanwhile.
6. **Energy (powermetrics) + vtebench columns** — operator sudo + a quiet
   machine (§7 #9, performance.rst table).

## Known deviations (tracked, intentional)

- Cell/graphics MSL shader *logic* is still the opus-era port; semantic drift
  against current GLSL (attr bit shifts, fg_override fix, bgimage preload) is
  Phase 3 (gates G2–G7 golden diffs).
- `presentsWithTransaction` live-resize sequencing landed in Phase 4/L1 (above);
  CVDisplayLink pacing is replaced by CAMetalDisplayLink on the Metal path (the
  CVDisplayLink code remains for the GL backend). L2/L3/L5 (immediate-encode,
  `sync_to_monitor`→`displaySyncEnabled`, adaptive `input_delay`, `pace=` tag)
  are the following Phase-4 task.
