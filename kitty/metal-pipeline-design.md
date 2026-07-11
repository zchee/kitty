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

**CALayer host (2026-07-08).** The layer receiving these contents swaps is no
longer a `CAMetalLayer`: in IOSurface mode `_glfwCreateContextMetal`
(glfw/metal_context.m) creates `KittyIOSurfaceLayer`, a plain-`CALayer`
subclass. Manually setting `contents` on a CAMetalLayer bypasses its
drawable-pool contract, and Core Animation logged an error-level ``changing
`contents' on CAMetalLayer may result in undefined behavior`` on EVERY present
(measured 1:1 — a 45 s flood produced 91 presents and 91 log lines); on a
plain CALayer the assignment is a supported operation (the shape of Ghostty's
`IOSurfaceLayer`), and the same run logs zero. The CAMetalLayer-typed state
flags shared code reads/writes — `presentsWithTransaction` (resize signal),
`displaySyncEnabled` (vsync flag), `drawableSize` (ring sizing) — survive as
same-named MIRROR properties on the subclass: pure stored flags (no drawable
presents exist on this path, so they carry no CA-side behavior), resolved at
runtime by selector dispatch, so every `(CAMetalLayer*)` site in glfw and
kitty/metal.m works unchanged. `metal_set_current_layer` fatals if the layer
class ever disagrees with `metal_iosurface_enabled()` (the env check lives in
two copies). Verified: warnings 0 (from 1:1 with presents), `KITTY_METAL_DUMP_FRAME`
goldens byte-identical pre/post in BOTH arms, on-glass `screencapture` md5-identical
(composite/colorspace parity — closes item 2 below), pace attribution unchanged,
test suite at the known pre-existing baseline. The legacy path
(`KITTY_METAL_IOSURFACE=0`) still creates a real CAMetalLayer (its flood
SIGSEGV predates this change — `.omc/.scratch/legacy-drawable-flood-crash/`).

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
2. **Colorspace decision** — DONE (2026-07-08, with the CALayer host change
   above): no colorspace is attached to the surfaces, and composite parity is
   now VERIFIED rather than plausible — `screencapture -l` of identical golden
   content is md5-IDENTICAL between the CAMetalLayer host (pre-change) and the
   plain-CALayer host (`KittyIOSurfaceLayer`), so Core Animation applies the
   same (absent) color matching to manually assigned IOSurface contents on
   both layer classes. Never attach a colorspace to the ring surfaces (same
   rationale as the legacy layer's intentionally-nil `colorspace`).
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

## Phase 8 (Wave 8): parser/decode throughput & the pipeline decomposition

Goal: close the devlog-006 gap to Alacritty (~15–17% at phase start).
Discipline: measure-first — a sample(1) decomposition gates every lever
(≥10% of flood-busy to act, else numbers-backed reject; harness at
`.omc/verify/phase8/profile_split.py`, findings in `P8-0-FINDINGS.md` and
`P8-LEVERS.md`).

### P8-0 decomposition (devlog-006 flood, main-thread busy shares)

`draw_text` self **42.0%** (char_props/wcwidth/grapheme inlined there),
scroll copy **~25%** (memmove ← `historybuf_add_line`, memset ←
`screen_index` new-line clear), `utf8_decode_to_esc_256` **19.1%**,
render-shape 6.1%, escape dispatch 0.2%. The main thread was only **59%
busy** during floods — the tell that the wall was not parse-CPU-bound,
which US-402d later proved out.

### Landed: batched width-2 run fill (US-402a, 8b90ec273)

`draw_wide_run()` in `kitty/screen.c` — the `draw_ascii_run` analog for
CJK/emoji floods: line-confined (never wraps: the scalar path owns the
DECAWM wrap and its segmentation-state re-derivation and multicell-nuke
semantics), stop-early at anything it cannot replicate exactly, chunked
stores (one GPUCell `memset_array` broadcast + a tight CPUCell pair
loop). A **plain-wide fast class** (kana/CJK/fullwidth ranges) skips the
per-char `char_props_for` + `grapheme_segmentation_step` chain — the
serial state-machine dependency that dominates the scalar loop — via a
steady-state theorem: once the segmentation state equals the plain
constant, stepping any fast-class char returns that constant.

The theorem is enforced by an **exhaustive checker**
(`test_wide_runfill_fast_class` in fast_data_types, asserted by the
fuzz): every admitted codepoint × every raw segmentation state must (a)
never join, (b) land on `GBP_None`, and (c) be a steady-state fixpoint
from the plain constant. During development it caught three real
hazards — `step(AtStart, ·)` returns `add_to_current_cell=1` (synthetic
pre-start state), emoji-context flag carry (an unconditional
constant-write diverges on `[ExtPic][kanji][ZWJ][ExtPic]`), and
U+3030/U+303D being Extended_Pictographic — which is the pattern to
reuse: declare generous ranges, let the checker shrink them.

Levers: `KITTY_DISABLE_WIDE_RUNFILL=1` (process) /
`set_wide_runfill_enabled()` (in-process, differential fuzz). Fuzz
extended with CJK-run corpora + wrap-parity/joiner adversarial cases,
all arms compared against the both-fills-off scalar reference.

Numbers (interleaved medians): `kitten __benchmark__` unicode **121.5 →
129.8 MB/s (+6.8%)**, ascii unchanged (−0.6%, noise); `draw_text`
self-time **−53%**; devlog-006 wall **1.0089× ≈ nil** (see US-402d).
Goldens byte-identical both backends; suites at baseline both backends;
MTL_DEBUG_LAYER clean.

### Deferred / rejected with numbers (US-402b / US-402c)

- **utf8 decoder (19.1% share): DEFER.** Isolated: scalar 0.32 /
  simd-128 0.79 / simd-256 **0.96 GB/s** on Japanese (matches in-flood
  effective ~1.0; the "avx2-emulated beats native-128 on ARM" upstream
  note holds). ~2.5–3× headroom exists (ESC pre-scan via the existing
  SIMD `find_either_of_two_bytes`, then a NEON-native UTF-8→UTF-32
  kernel for the ESC-free span) but the goal metric is pipeline-bound
  and the movable axis (`__benchmark__` unicode, where kitty already
  leads ~2×) gains an estimated +8–12% for a high-risk rewrite of
  upstream-hardened decode code.
- **historybuf line steal/swap (~25% share): REJECT.** `LineBuf` and
  `HistoryBuf` both use flat contiguous cell storage (line_map offsets /
  ring arithmetic); swapping line buffers between them requires
  per-line heap indirection in BOTH containers (resize / pagerhist /
  serialization redesign) — fails the bounded-blast-radius bar, and the
  goal metric is unaffected anyway.

### The pipeline decomposition (US-402d — the phase's key finding)

Three-way same-load-window devlog-006 interleave (medians): Alacritty
**0.425 s** < kitty `input_delay=0` **0.470 s** < kitty default
**0.498 s**. The default-config gap to Alacritty (**17.2%**) decomposes
as:

- **6.0% — the `input_delay` batching policy** (deliberate
  energy/latency trade; fair to measure at defaults, wrong to silently
  change).
- **10.6% — structural**: kitty multiplexes parse+render on the main
  thread (render-shape ≈ 6% of flood busy, plus io-thread→main-tick
  handoff); Alacritty parses on a dedicated thread. Parse-CPU cuts
  provably do not move this (US-402a: −53% draw self → 1.0089× wall;
  vt-parser BUF_SZ is already 1 MiB).

Consequences: (1) pipeline-bound axes are **backend-insensitive** —
fresh same-window measurement has kitty-Metal 0.496 ≈ kitty-GL 0.500 on
devlog-006, which retracts the earlier "Metal ~13% over GL on devlog"
claim (load-window confounding; the backend's real wins are the
latency / CPU-per-frame / memory axes, all same-binary anchored);
(2) the named lever for the residual is the **render-thread split**
(promoted in Future work); (3) adaptive input batching (skip the delay
when saturated) would change flood-time energy policy — upstream/user
decision, not a unilateral default flip.

### vtebench (captured 2026-07-06, subset, median ms/sample)

Alacritty 7 / 26 / 6, Ghostty 8 / 20 / 8, kitty-Metal **15 / 69 / 9**
(dense_cells / scrolling / unicode). kitty trails on SGR-dense and
scrolling patterns; the scrolling gap aligns with the profiled
scroll-machinery share and is queued in Future work. Harness:
`.omc/verify/phase8/p8_vtebench.py` (payload to the tty, results via
`--dat --silent`).

## Phase 9 (Wave 9): render/parse de-multiplex — measured, and rejected

Goal: the structural 10.6% devlog residual (US-402d) and the vtebench
scrolling gap (69 ms vs Ghostty 20 / Alacritty 26). Method: before any
threading work, a test-only suppression lever
(`KITTY_TEST_SUPPRESS_RENDER=1`, early-return in `render_os_window()`)
puts an upper bound on what ANY render offload could buy — parse, io and
timers run identically, rendering costs exactly zero.

### The gate numbers (`.omc/verify/phase9/P9-0-FINDINGS.md`)

devlog-006, 4 interleaved arms (LOAD-DEGRADED 8.8): render share of the
wall = **0.58%** at default config, **2.97%** at `input_delay 0`; the
delay share (5.74%) reproduces the US-402d policy split. The
pure-pipeline bound is the decisive number: render OFF + delay 0 drains
at **45.4 ms/pass vs Alacritty's end-to-end 42.5 ms** — kitty's
io-thread→main-tick handoff alone costs more than Alacritty's whole
read+parse+render loop.

vtebench `scrolling` (sample, main thread 96% busy — this workload IS
main-CPU-bound, unlike the cat-flood): memmove **44.5%** (93% under
`historybuf_add_line` — the evicted-line copy into the scrollback ring)
+ memset **25.4%** (`screen_index` recycled-row clear) = **the
scroll-copy machinery is ~70%**; draw_text 6.9%; render-encode +
render-shape **0.36%**.

**Verdict: the render-thread split is dead on both measured throughput
axes** — a perfect split buys ≤0.6% on devlog and ≤0.4% on scrolling,
and the suppression lever OVER-estimates a real split (which still pays
main-thread snapshot/handoff and drives the display link), so the true
ceiling is lower still. Interactive-latency and animation-pacing effects
were not measured (outside this phase's throughput charter). Rejected
with numbers, closing the Future-work #1 hypothesis. The de-multiplex
framing was wrong: kitty's main thread is not render-starved; on floods
it is 41% idle (pipeline-bound) and on scrolling it is copy-bound.

### Every alternative lever, dispositioned

- **Drop GPUCells from history storage** (−62% copy width): impossible —
  the SGR color spec lives only in GPUCell; losing it loses colors.
- **Batch scrolled lines into one copy**: impossible — the recycled row
  is cleared and rewritten immediately, so each line must be saved (or
  pointer-swapped) at scroll time.
- **Non-temporal/faster memcpy**: platform memmove already streams
  optimally; the cost is byte volume (~32 B/cell × cols × every scrolled
  line through a >L2 ring).
- **Lazy clear of the recycled row** (the memset 25%): needs
  cleared-state tracking checked by every line reader — too much radius
  for one benchmark.
- **io→main handoff micro-levers**: input_delay already coalesces
  wakeups at defaults; BUF_SZ is already 1 MiB; the remaining 6.8-point
  pure-pipeline residual is the reader/parser thread model itself.

### What Phase 9 establishes

The two remaining competitive gaps share one root each, both
architectural: (1) the devlog residual is the **reader/parser thread
model** (a dedicated parser thread à la Alacritty — not a render
thread); (2) the scrolling gap is the **grid container** (Alacritty's
visible screen is a window over the scrollback ring: O(1) scroll, zero
copy; kitty copies every scrolled line into a separate history ring).
Both are Screen-level redesigns (resize/rewrap, serialization,
pagerhist, multicell interplay) queued at the top of Future work with
these numbers. Landed artifact: the suppression lever (standing tool for
render-cost upper bounds).

## Phase 10 (Wave 10): O(1) scroll via a shared line-slot pool

Status: LANDED (design-gate approved with 7 amendments, all applied;
stages 1–3 at 4f8487cd0 / 811b7e5d3 / df474d5ca + the shift+mask fix
b2ce4562f). Target was the Phase-9-attributed scroll-copy machinery
(~70% of vtebench-scrolling CPU: memmove 44.5% under
`historybuf_add_line` + memset 25.4% under `screen_index`).

### Results (before/after interleaved binaries, LOAD-DEGRADED 7–8)

- **vtebench scrolling: 63 → 38 ms median (−40%)**, with 1.7× more
  samples completing per fixed-time run (52 → 90); the fresh
  three-terminal capture puts kitty at **38 ms vs Ghostty 20 /
  Alacritty 24**, down from 69 ms (2.9× behind → 1.6–1.9×). The
  Phase-9 amended prediction — "the honest floor is ≈38–40 ms because
  the recycled-row memset survives" — landed exactly: **the ≤35 ms PRD
  wording was NOT met**, as forecast, and the residual is the memset +
  draw path, with dense_cells (15 vs 6–9 ms, unattributed) now the
  largest vtebench deficit.
- devlog-006: neutral (0.494 vs 0.493 A/B; fresh competitive round
  0.484 ≈ kitty-GL 0.485) — exactly as the Phase-8/9 pipeline-bound
  model predicts for a parse-side CPU cut.
- `kitten __benchmark__`: neutral after the shift+mask fix (ascii
  143.5 vs 143.6, unicode 130.1 vs 130.4 across 3 interleaved rounds).
  The first A/B caught a REAL ~2% draw-throughput regression from a
  runtime division in the hot slot→address math — fixed by rounding
  slab capacities to powers of two (shift+mask), re-measured neutral.
- Two latent-behavior finds along the way, both caught by the
  phase's own harnesses: `history_buf_endswith_wrap` read position 0
  with no count guard (pre-pool it returned false only because cleared
  storage was freshly zeroed; the stale wrap flag broke mouse
  triple-click line continuation — count guard added), and the
  division cost above. Suites at baseline on BOTH backends at every
  stage boundary; scroll-semantics snapshots byte-identical throughout;
  MTL_DEBUG_LAYER clean on a scroll flood.
- Deliberate behavior change (final-review note): ED3 / clear on the
  SHARED pool retains cell memory as spares (count-only reset) instead
  of releasing segments as the pre-pool clear did — bounded by the
  design's memory envelope (lb.ynum + history capacity), and required
  because the slots belong to the pool's lifetime, not the clear.
  Private/standalone containers keep the release behavior.

### The audit finding that shapes the design

`cpu_lineptr`/`gpu_lineptr` never escape line-buf.c / history.c (zero
external references). The complete raw-member escape list (design-gate
review closed it at exactly two): `remap_hyperlink_ids`
(hyperlink.c:102-103) walks both linebufs' `cpu_cell_buf` as one flat
array — the one true cross-line contiguity consumer, rewritten per-line
in stage 1 (cold GC path) — and the same-dims resize fast path
(resize.c:258-261) whose map/attrs/cell block memcpys become per-line
copies into the dest's own slots (slot ids must not cross pools). Every
other consumer goes through index-addressed view APIs (`*_init_line`
and friends: screen.c ×39, resize.c ×14, shaders.c ×2, lineops.h ×3),
Line views are short-lived, paused_rendering holds a deep clone,
selection tracks coordinates. LineBuf already has per-line index
indirection (`line_map[visual] = physical`). Storage addressing is
therefore already encapsulated: the containers' internals can change
without touching the 58 call sites.
(Full enumeration: `.omc/verify/phase10/P10-0-AUDIT.md`.)

### Selected design: shared line-slot pool ("a-prime")

One pool per Screen: line slots (cpu[xnum]+gpu[xnum]) in 2048-line
slabs with stable addresses (history's existing segment allocation
pattern); slot id (u32) → (slab, offset). `LineBuf.line_map[y]` holds a
pool slot id instead of a block-local index — same semantics, wider
domain. HistoryBuf replaces its segments with a ring of slot ids (+
attrs by value, as today). Scroll eviction becomes a **slot handover**
(new internal API used by INDEX_UP; the copy-based `historybuf_add_line`
remains for rewrap-style callers):

- forward push where the ring position holds an allocated spare slot
  (left by a prior reverse-scroll pop, or the recycled tail after
  `pagerhist_push` when full): SWAP — 1:1 exchange, no free-list,
  count-only shrink.
- forward push onto a never-allocated position: the pool provides a
  fresh slot for linebuf (slab growth, monotone up to lb.ynum + history
  capacity — today's memory envelope).
- reverse scroll keeps today's COPY semantics (verified: `_reverse_scroll`
  pops a view, the slot stays owned by history as the spare, the content
  is copied out) — cold path, zero ownership transfer, zero leaks.
- Zero cell memmove on every scroll path. The recycled-row memset stays
  in ANY design (a new row must read blank; Alacritty clears too) — the
  honest floor is therefore ≈38–40 ms on vtebench scrolling (memset
  ≈17.5 ms survives), below the PRD's ≤35 ms wording; the shortfall
  will be recorded plainly. Cat-flood wall: −4–6% expected.

Pool ownership: one pool per (main_linebuf, historybuf) group — the
only pair exchanging slots. Alt linebuf, the paused_rendering clone,
resize temporaries, and standalone Python containers use private pools;
resize frees the old pool with the old containers; main↔alt toggle
never crosses pools.

Rejected alternative: full ring-grid unification (visible screen as a
window over one ring) — identical payoff (the memset survives there
too) at 3–4× the radius (scrollback y-semantics leak into as_text/
pager/selection; rewrap loses container symmetry; the standalone
Python LineBuf/HistoryBuf test surface breaks).

### Identity strategy and staging

A kill switch is infeasible (container layout is one-or-the-other), so
behavior identity rests on (1) a differential scroll-semantics harness
committed BEFORE any container change, with pre-change-binary behavior
snapshots (scroll regions/margins, rewrap grow/shrink, pager +
pagerhist, multicell across the scroll boundary, selection tracking,
ring-wrap eviction, reverse scroll, ED2/ED3); (2) staged landing —
pool module → LineBuf on pool → HistoryBuf on pool (still copying) →
handover switch → resize fast-path adaptation — with the harness, full
suites, and goldens green at every stage boundary; before/after binary
A/B for the numbers.

## Phase 11 (Wave 11): three measure-first tracks — all pointed at one root

Goal: attack the vtebench dense_cells deficit (15 ms vs Ghostty 9 /
Alacritty 6), land off-thread image decode, and audit a parser thread.
All three converged on the same root — kitty's threading model — and all
three resolved as measure-first with the audit/finding as the
deliverable rather than a lever landed this phase. Nothing was forced.

### Track 1 — dense_cells is LOCK contention, not render (P11-0-FINDINGS.md)

dense_cells main-thread render is 0.6%. Its busy CPU is **~55% lock
operations** (all-thread, results/dense-symbol-histogram.json; the
contended kernel waits within that — `__psynch_mutexwait`/`drop`, 9.3%
of all samples — are load-sensitive, captured at loadavg 7.38, so the
idle-machine figure is lower; the uncontended lock calls are load-robust
CPU shares). A load-independent cross-check: io-thread busy is **19.9%
on dense_cells vs 3.27% on the Phase-9 scrolling profile, ~6×**. Root
cause: the
vt-parser's single `self->lock` ping-pongs between the IO thread
(`read_bytes` takes it twice per read — create + commit write buffer)
and the main parse tick, and vtebench writes the SGR-per-cell payload in
tiny per-char chunks → maximal lock-acquisition frequency. Verified
workload-specific: the devlog cat-flood (large chunks) shows lock =
0.1%. No bounded ≥10% small lever exists; the fix is a lock-free
buffer handoff → folded into Track 3.

### Track 2 — off-thread image decode: DEFER, reframed (P11-2-DECODE-DESIGN.md)

`inflate_png_inner` is pure/thread-safe, but its graphics.c wrappers
mutate shared LoadData + call `set_command_failed_response`, and
`handle_add_command` couples decode with disk-cache + GPU upload + the
APC response, runs in parse-worker context, and uses a SINGLE
`currently_loading` slot. Design A (worker-decode, synchronous handoff)
moves CPU not wall — worthless. Design B (deferred decode + deferred
response) is a REAL win — and because icat sets quiet=2
(`GRT_quiet_silent`; `finish_command_response` returns NULL on BOTH
success and error at quiet>1, graphics.c:880) it does NOT wait on any
response, so the win plausibly includes the icat wall, not just the
other-window hitch (an earlier "win ≈ 0" reading was retracted). The
out-of-band error-response constraint applies to quiet≤1 clients, not
icat. But Design B needs an async image-load-QUEUE rewrite
(in-flight queue, out-of-band error protocol, placement ordering,
delete-during-decode races) whose blast radius rivals the parser-thread
work and needs a heavy contention harness — its own phase. Deferred;
what moves the icat WALL specifically is faster decode (libdeflate /
SIMD unfilter), a separate optimization from decode LOCATION.

### Track 3 — parser-thread feasibility audit: Design 2 GO, Design 1 NO-GO (P11-3-PARSER-AUDIT.md)

The load-bearing fact: kitty's Screen is single-writer-BY-THREAD, not by
lock — parse, render, and every Python Screen call are serialized on the
main thread (`process_global_state`: resize→parse→render,
child-monitor.c:1537-1549). No lock guards Screen; the ~55%-of-busy
`self->lock` guards only the IO→main byte buffer. Render is not a pure
reader
(`screen_update_cell_data` clears is_dirty / marks lines clean,
screen.c:3920-3957), and grman is read-modify-written by BOTH parse and
render (screen.c:1826 vs 3835) — so any design that de-serializes
inherits an unlocked dual-writer Screen whose torn/dropped-frame races
are INVISIBLE to the converged-state harness (`scroll_semantics` via
`as_text`).

- **Design 1 (dedicated parser thread): NO-GO / DEFER.** Massive
  multi-subsystem blast radius; behavior-identity UNPROVABLE (the
  decisive races are golden-invisible; TSan proves race-freedom, not
  frame-level identity); relocates the lock cost onto the GIL (the parser
  thread would `PyGILState_Ensure` around ~25 callback sites, contending
  the main thread's Python) — may not even recover the win. Revisit only
  after a deterministic intermediate-frame differential harness exists.
- **Design 2 (lock-free SPSC IO→parser byte ring, parse stays
  main-thread): GO — Phase 12.** ~200-400 lines in vt-parser.c +
  read_bytes; zero change to Screen/render/Python/grman/GIL, so
  parse/render/Python stay serialized and Screen ordering is byte-for-
  byte identical → scroll_semantics + full suite PROVE identity. The one
  new invariant (SPSC in-order, lossless, back-pressured) is local +
  fuzz/TSan-testable. Directly deletes the measured dense_cells lock
  fraction (the contended psynch waits alone = 19.5% of all-thread
  busy); the gain is capped at the lock share since the real parse work
  stays main-thread, but it is the largest PROVABLE lever. Architect
  audit APPROVED.

Phase 11 landed no product code (three numbers-backed measure-first
verdicts); its deliverables are the three analyses + the Phase-12 plan
(Design 2 SPSC handoff), which now carries a concrete, quantified
motivation (~55% of dense_cells busy is the parser-lock ping-pong) and a
proven-safe shape.

## Phase 12 (Wave 12): lock-free SPSC IO→parser handoff

Status: LANDED (design gate: codex critic DESIGN-APPROVED with 4
majors, all folded pre-implementation; ring + standalone proof harness
at 2370c5899; swap at e856793ff; final-review REJECTED verdicts fixed
by the FR-1..FR-4 amendments below and re-measured).

### Results (same-machine before/after interleave, 3 full rounds on the final FR-hardened binary, loadavg 4.3–7.7 — elevated, flagged per protocol)

- **dense_cells 15.0 → 11.0 ms (−27%)** — the phase target (the
  pre-hardening prototype measured 10.0 ms at loadavg ≈ 4; the
  final protocol's fences cost ≤ 1 ms under elevated load). The
  re-profile confirms the mechanism, not just the number: contended
  psynch mutex waits **9.3% of all samples → 0.0%**, total lock ops
  **~55% → 0.1% of busy** (committed histograms:
  `.omc/verify/phase11/results/dense-symbol-histogram.json` before,
  `.omc/verify/phase12/results/dense-symbol-histogram-after.json`
  after). What remains on the profile is real parse work.
- **`kitten __benchmark__` ascii 141 → 238 MB/s (+69%), unicode 127 →
  195 MB/s (+54%)** — unexpected magnitude, same-window verified in
  every round (`.omc/verify/phase12/results/ab-*.json`; the earlier
  quiet-machine capture read 145 → 245 / 131 → 202 — identical ratios,
  ambient load shifted both arms): the create/commit/has_space mutex
  round-trips were throttling ingestion on the flood path itself, not
  just dense_cells.
- **vtebench scrolling 39 → 35 ms (−10%)** — the same lock overhead
  removed from the scroll workload.
- **devlog-006 neutral** — the 3-round A/B read after 0.586 vs before
  0.515 s (+14%), but a devlog-only alternating-order recheck
  (`results/devlog-recheck.json`) FLIPPED the direction (before 0.699
  vs after 0.498 median at loadavg 12–14) and the matched-load rounds
  are equal (0.466 vs 0.465 s): the apparent delta is load
  confounding, exactly as the pipeline-bound model predicts
  (suppressing the entire render path moves this wall 0.6%).
- **Input pacing unchanged on the final binary**: under a 150 ms
  typing pattern both binaries present exactly once per keystroke with
  identical p50 gap (150.0 ms) — input_delay batching semantics
  preserved. Zero-present (occluded) captures now fail the proxy run
  and are quarantined under `results/failed/`, so the cited artifacts
  are all valid (`.omc/verify/phase12/results/latency-proxy-*.json`).
- Identity: both backends at suite baseline at the swap boundary AND
  re-run on the final FR-hardened binary with raw logs committed
  (`results/suite-{metal,gl}-postfix.log`: Ran 356, the only failures
  are the documented environmental zsh/ssh ones; Go green;
  scroll_semantics and ascii_runfill pass in-suite); scroll-semantics
  snapshots (goldens from the pre-ring binary) byte-identical; Metal
  dump golden byte-identical before-vs-after on the final binary with
  the rendered content visually confirmed
  (`results/dump-golden-postfix.log`, `-after.png`); MTL_DEBUG_LAYER
  pure-render run clean (`results/mtl-debug-layer-postfix.log`); the
  standalone ring harness (incl. the small-ring TSan variant with
  full-ring transitions) race-free. Two tests that encoded the old linear
  buffer's transport granularity (full-write capacity single-window,
  OSC 52 pending split offsets) were updated to assert the actual
  contracts (exact byte accounting; flag pattern + reassembled
  payload) — sanctioned at the design gate, since window granularity
  was never child-observable behavior.
- Functional contention evidence: the dense_cells re-profile hammers
  the real IO-vs-main interleaving at maximal tiny-write frequency with
  correct output (whole-kitty TSan is not supported by setup.py, whose
  sanitize flags are ASan/UBSan; the PRD's synthetic-contention
  alternative applies).

### The design (as landed)

Target: the
vt-parser single-mutex byte handoff — ~55% of dense_cells busy, with
the IO thread taking the lock 2×/read (create+commit) plus once per
child per poll iteration (the POLLIN gate), ping-ponging against the
main parse tick (P11-0-FINDINGS.md; full invariant enumeration in
`.omc/verify/phase12/P12-0-INVARIANTS.md`).

### The design in one sentence

Insert a lock-free SPSC byte ring between the IO thread and the main
thread, drain it into the EXISTING `PS.buf` parse arena at the top of
each parse tick, and delete the mutex from the hot path — parse stays
on the main thread, so Screen mutation ordering is byte-for-byte
identical and `scroll_semantics` + the full suite remain a valid
identity proof.

### Ring layout and memory orders

```c
typedef struct VTInputRing {           // one per Parser, transport only
    uint8_t buf[VT_RING_SZ];           // 1 MiB, power of two
    alignas(64) _Atomic size_t head;   // producer-owned, monotonically increasing
    alignas(64) _Atomic size_t tail;   // consumer-owned, monotonically increasing
    alignas(64) _Atomic monotonic_t new_input_at;  // first-unabsorbed timestamp
    alignas(64) _Atomic bool writer_parked;        // back-pressure waiter flag (FR-2)
    alignas(64) size_t reserved_sz; bool reserve_active;  // producer-private
} VTInputRing;                          // static_assert 64-byte separation
```

Indices are free-running (masked with `VT_RING_SZ-1` on access);
`used = head - tail` is overflow-safe for size_t. Producer publishes
with `store(head, release)` after the bytes are written; consumer reads
`load(head, acquire)` before touching them (and symmetrically
tail/release ↔ acquire for space). `new_input_at` follows the FR-1
covered-or-fail-open protocol below (the original "rides the
acquire-release edges" formulation was rejected at the final review as
unprovable). Precedent for the atomic style: the L5
`last_local_key_input_at` (child-monitor.c:29-30).

### Protocol mapping (1:1 onto the enumerated invariants)

- `vt_parser_create_write_buffer` → RESERVE: contiguous span
  `min(free, ring_end - (head & mask))`; hands the caller a pointer
  into the ring. Zero space → same as today's zero-size window
  (read_bytes returns without reading; POLLIN gate stalls the reader).
  Wrap-around simply yields a shorter window; the next read continues
  at the ring start — no memmove, ever. Double-reserve stays a fatal
  assertion.
- `read()` runs into the reserved span with no lock and no relocation
  hazard: the consumer NEVER moves ring bytes (it only advances tail),
  so the in-flight window cannot go stale — the entire
  compaction/relocation machinery (the multi-word coupling that made
  atomics-on-the-shared-arena unsafe) disappears rather than being
  ported.
- `vt_parser_commit_write(sz)` → PUBLISH: `head += sz` (release);
  commit(0) publishes nothing. Sets `new_input_at` if 0.
- `vt_parser_has_space_for_input` → `head - tail < VT_RING_SZ`,
  acquire loads, lock-free — the per-poll-iteration lock acquisition
  becomes two atomic loads.
- `run_worker` absorb → DRAIN: while ring non-empty and
  `read.sz < BUF_SZ`: memcpy the contiguous ring segment into
  `PS.buf + read.sz`, advance `read.sz` and `tail` (release). Then the
  existing parse loop runs on `PS.buf` exactly as today — and since the
  producer no longer touches PS state, `read.*`/compaction become
  MAIN-THREAD-PRIVATE: the parse side needs no lock at all. The
  mid-parse absorb becomes a mid-parse re-drain (same loop shape as
  today's re-absorb, preserving the consume-while-arriving behavior).
  `write.offset/sz/pending` die; `self->lock` leaves the hot path
  entirely (init/destroy only, or deleted outright).
- `write_space_created` → space-created: true when the drain freed
  ring space from a full ring — feeding the existing
  `wakeup_io_loop` re-arm (child-monitor.c:516) unchanged.
- input_delay batching, the nearly-full parse override
  (`read.sz + 16 KiB > BUF_SZ` — now also `ring nearly full`), the
  WAKEUP pacing, and the L5 echo path are untouched (all already
  outside the parser lock).

### Honest costs and bounds (stated up front)

- **+1 memcpy/byte** (ring → PS.buf) where today's steady state does
  0–1 copies (commit relocation + compaction). Bulk memcpy runs at
  tens of GB/s: on the devlog corpus that is ~0.2 ms per 5.4 MB pass
  (~0.4%) — gated by the devlog non-regression A/B.
- **Worst-case buffered bytes double**: ring (1 MiB) + PS.buf backlog
  (< 1 MiB) vs today's single 1 MiB arena. Steady state is similar
  (the drain empties the ring into the arena each tick); the bound is
  a transient. Recorded as a deliberate envelope change.
- The dense_cells gain is capped at the lock share (~55% of busy, part
  load-sensitive): the real parse work (~30%) stays on the main
  thread by design.

### Rejected alternative

Atomics over the existing shared linear buffer: the producer window
offset is derived from consumer state and relocated by the consumer's
compaction — a multi-word protocol with cross-thread memmoves that has
no safe lock-free formulation. The ring removes the coupling instead
of synchronizing it (P11-3 audit conclusion, reconfirmed by the
invariant enumeration).

### Design-gate amendments (codex critic, DESIGN-APPROVED with 4 MAJORs — all folded)

1. **Timestamp ordering**: the draft published `head` before stamping
   `new_input_at`, admitting "bytes visible with zero timestamp" (early
   parse) and a stale-stamp leak. Fixed with **stamp-publish-stamp**:
   CAS-if-zero BEFORE the head release, and again AFTER it to cover the
   consumer's clear-on-empty landing between stamp and publish. The
   harness asserts `used > 0 ⇒ new_input_at ≠ 0` at every drain.
   (Superseded by FR-1 below: the SHIPPED contract is
   covered-or-fail-open - the absolute invariant described this draft
   protocol only; the hardened harness proves each racy resolution path
   deterministically instead of asserting it.)
2. **Lost wakeup at the parse gate**: today `write_space_created` is
   only consumed when the tick actually parsed (`pd.input_read`,
   child-monitor.c:515). With the ring, a top-of-tick drain can free a
   full ring while the input_delay gate declines parsing → POLLIN would
   stay off. THE SWAP MUST make the space-created wakeup fire
   independent of `input_read` (a do_parse change) + a slow-parser test.
3. **Reserve bookkeeping kept**: stateless reserve dropped the old
   fatal-on-double-create guard; the ring now tracks
   `reserved_sz/reserve_active` (producer-private) and asserts on
   double-reserve and commit-larger-than-reserved (harness/debug
   builds; NDEBUG compiles them out).
4. **Placement**: the 1 MiB ring is heap-allocated as a
   `VTInputRing *input_ring` next to PS (which is a separate
   posix_memalign block behind a pointer in the Parser PyObject) —
   never embedded by value (would double per-parser resident memory),
   and PS.buf is NOT replaced (the scanners depend on the contiguous
   arena). The resident-memory envelope change (+1 MiB per parser) is
   deliberate and recorded.

### Final-review amendments (two independent codex lanes, both REJECTED the first cut — converging findings, all fixed)

1. **FR-1 — `new_input_at` was not linearized with byte publication.**
   The first cut cleared with a used()==0 check followed by a blind
   store(0): a publish landing between them left visible bytes with a
   zero stamp, and the unconditional post-publish re-stamp could park a
   stale value in an already-drained ring. Fix (vt-input-ring.h): the
   consumer clears with a **CAS against the value it observed** while
   the ring was observably empty, then **re-covers fail-open**
   (stamp = now) if bytes became visible across the clear; the
   producer's post-publish re-stamp is now behind a **seq_cst fence and
   conditional on unconsumed bytes remaining** (fence-paired with the
   clear, so exactly one side resolves each race: either the producer
   sees the full drain and skips, or the consumer sees the re-stamp and
   clears it). The contract is restated honestly: in every quiescent
   state with pending bytes the stamp is non-zero and ≤ the oldest
   byte's arrival; the only reachable transients are zero/older stamps,
   which **open the input_delay gate early** — a missing stamp can
   never delay parsing or lose bytes. The 150 ms pacing proxy re-run on
   the fixed binary is unchanged (p50 150.0 both arms).
2. **FR-2 — the full-ring POLLIN re-arm could lose its wakeup.** The
   first cut set `write_space_created` from a pre-drain
   `was_full` snapshot; a producer filling the ring after that snapshot
   could park the IO thread (POLLIN off) while the consumer advanced
   tail without waking it. Fix: a **`writer_parked` waiter flag with a
   Dekker-style seq_cst fence pair** — the io thread parks via
   `vt_ring_writer_arm_or_park` (publish flag → fence → re-check
   space) before dropping POLLIN (child-monitor.c), and `run_worker`
   unparks once per tick after all tail advances (fence → claim flag →
   `write_space_created`). Either the parker's re-check sees the new
   space, or the unpark sees the flag: a sleeping reader with freeable
   space is unreachable. The unpark is per-tick, not per-drain, so no
   fence lands in the per-escape consume loop.
3. **FR-3 — release builds had lost the misuse guards.** The
   double-reserve / over-commit checks were `assert()` (compiled out by
   the macOS `-DNDEBUG` build); they are now unconditional
   `VT_RING_MISUSE` (fprintf+abort), restoring the mutex-era fatal()
   contract. The stale "thread safe, using an internal lock" comment on
   the producer API (vt-parser.h) now states the SPSC contract.
4. **FR-4 — evidence gaps.** `kitten __benchmark__` now runs in ALL
   three A/B rounds (the first capture skipped round 2); zero-present
   latency-proxy captures fail the run and are quarantined under
   `results/failed/` instead of being written as normal data; the
   US-805 identity gates (both-backend suites, dump golden,
   MTL_DEBUG_LAYER) have raw logs committed under
   `.omc/verify/phase12/results/`; and the numbers above are re-measured
   on the final FR-hardened binary. `suite-metal-postfix.log` carries
   one failure beyond the errors=2 zsh baseline
   (`test_ssh_shell_integration`): proven environmental -- the machine's
   PATH-first zsh is a zsh-master dev build that emits OSC 133
   semantic-prompt marks natively (reproduced outside kitty in a
   sandboxed probe; the assertion reads raw child bytes upstream of the
   parser, and the branch touches nothing on that surface). Forensics:
   `results/ssh-test-env-failure.md`. The dump golden is a
   secondary indicator (its log flags the PNG as suspiciously small);
   the suites, ring harness, and parser-level evidence carry the
   identity gate.

**Deterministic interleaving coverage** (kitty_tests/spsc_ring_check.c,
demanded by both lanes): `VT_RING_TEST_HOOKS` step points in the header
let a single-threaded test run the peer role's steps at an exact
protocol boundary. Five proofs run before the stress suite in every
variant (plain/small/TSan×2): clear-races-publish (fail-open re-cover),
clear-between-stamp-and-publish (fenced conditional re-stamp),
no-stale-stamp-in-emptied-ring (re-stamp skip), park/unpark basics
(claim-once, refuse-while-full), and fill-races-park (lost-wakeup
impossibility, both resolutions). The stress consumer counts
covered-or-fail-open transients instead of hard-asserting the
(unprovable) absolute invariant — 0 observed across all variants.

### Staging and evidence plan

1. Ring header + STANDALONE harness commit: real producer/consumer
   threads; in-order/lossless (checksums), back-pressure without loss,
   wrap-around, partial writes, 256 KiB drains; seeded fuzz; **TSan
   clean**, including a small-ring (`-DVT_RING_SZ=4096`) TSan variant
   that forces full-ring transitions under TSan slowdown — before any
   parser change lands. (DONE pre-commit: 4/4 variants pass, evidence
   in `.omc/verify/phase12/P12-1-RING-VALIDATION.md`.)
2. The swap commit (vt-parser.c + read_bytes + the amendment-2 wakeup
   fix), suites green on BOTH backends at the boundary, goldens
   byte-identical, plus a kitty-level TSan/synthetic-contention run
   over the real IO-vs-main interleaving.
3. Re-profile (psynch waits demonstrably gone, histogram committed) +
   before/after interleaved A/B (dense_cells primary; devlog,
   `__benchmark__`, scrolling non-regression) + input_delay-default
   latency check + docs.

## Phase 13A (Wave 13): arithmetic & gating quick wins

Status: LANDED (plan `.omc/plans/2026-07-07-wave13-residual-optimization.md`;
verify `.omc/verify/wave13a/VERIFY-REPORT.md` — gate PASS, no regressions,
goldens byte-identical, Metal+GL suites baseline-equivalent). Four S-effort
levers in one env-switched binary; all A/Bs same-binary interleaved under
LOAD-DEGRADED conditions (load 4.6–12.6/16, launchservicesd ~1 core;
ratios valid, absolutes flagged).

- **P1 — CSI parse: no divide per parameter** (31ef4d3e0).
  `csi_add_digit` accumulated high-end-first through a 10^n table and
  `commit_csi_param` paid a 64-bit divide per committed parameter; now
  plain `acc*10+d` with a multiply-by-sign commit. Bit-identical output
  proven — an 8160-case dual-scheme model (including the legacy table's
  16th-digit ×100 quirk) plus parser/screen suites identical in both
  arms. End-to-end throughput within ±2% noise (expected: ~20–40
  cyc/param is sub-noise on MB/s benches); the win is strictly-less CPU
  per parameter at zero risk. Kill-switch `KITTY_VTP_LEGACY_CSI_PARSE=1`.
- **FN1 — ligature-name memo** (f61b01478). `group_normal` called
  `hb_font_glyph_to_string` (sfnt name lookup + strcmp) for every glyph
  of every dirty run; LigatureType is now memoized in 3 spare
  GlyphProperties bits, riding the per-font glyph_properties_hash_table
  lifecycle (rebuilt on size/DPI/config change — no new invalidation
  paths). Iosevka path untouched. Shaping groups byte-identical cached
  vs uncached (test_shaping differential on Cascadia/Fira). Value is
  per-glyph main-thread shaping CPU — deliberately off the async-render
  bench axis. Kill-switch `KITTY_DISABLE_LIGNAME_CACHE=1` (+ in-process
  `set_ligature_name_cache_enabled`).
- **L1 — sync-present on input-immediate frames** (3b2dd70b3; default
  flipped OFF at a388cd461). Mechanism: an input-immediate frame
  (`!link_driven && displaySyncEnabled && !presentsWithTransaction`) may
  skip the async completed-handler→main-queue double hop and swap
  synchronously through the same per-layer generation guard
  (reorder-safe). The 60 Hz A/B found no reliable ≥0.5 ms p99 typing win
  (p50 24.99 vs 24.25 ms slightly favoring async; p99 swings 33–64 ms
  symmetric in both arms; only 3–12/40 keystrokes take pace=immediate)
  with zero flood-cadence change — so per the pre-agreed gate rule the
  lever is opt-in: `KITTY_METAL_SYNC_IMMEDIATE=1`. ProMotion/quiet-box
  re-eval queued in Future work. Measurement honesty: the first L1
  capture was superseded — the v1 driver mixed clock domains (system
  python `monotonic()` vs `presentedTime`'s mach timebase) and used an
  intermittent-cat flood whose cat-boundary link idles admitted
  immediate frames, faking an A-only p99 spike; the corrected
  sustained-flood v2 shows symmetric p99 (`results/superseded/`).
- **L6 — refresh-derived immediate floor** (de0d1e662). The
  immediate-encode gate's hard-coded 8 ms floor is now ~0.5× the
  window's monitor refresh period (min 3 ms, 8 ms fallback when
  unknown), cached on OSWindow and recomputed only on cold input when
  >1 s stale — never per-frame, never during flood; `#ifdef
  KITTY_BACKEND_METAL`. At 60 Hz the derived 8.33 ms ≈ the old 8 ms:
  measured byte-unchanged (typing + flood identical within noise). The
  ProMotion payoff (~4.2 ms floor @120 Hz) is unmeasurable on this
  60 Hz LCD and reserved for a high-refresh check. Kill-switch
  `KITTY_METAL_IMMEDIATE_FLOOR_MS=<n>`.

Exit gate: typing p99 unchanged; flood presents refresh-capped with
cadence p50=p90=16.6667 ms in every arm (p99=33.33 ms symmetric
load-induced drops in both arms); Metal+GL suites Ran 357 with only the
documented environmental zsh errors; golden all-default vs
all-levers-off byte-identical and content-verified. dense_cells read
10.0 ms in both P1 arms (= the pre-13A baseline on this machine under
load): the ≤9 ms absolute is LOAD-BLOCKED here and owned by Phase 13B
(scroll-memset), not by any 13A lever.

## Phase 13B (Wave 13): the scroll-memset campaign — pacing-blocked

Status: LANDED as a MEASURE-FIRST VERDICT (plan
`.omc/plans/2026-07-07-wave13-residual-optimization.md` §4.1/§Phase 13B;
verify `.omc/verify/wave13b/VERIFY-REPORT.md` — scrolling exit gate NOT
MET, correctness PASS everywhere; the root-cause finding below IS the
deliverable). Commit arc: 21c12a07a (pre-overwrite semantics tests,
red-able first) → 38984db8d (S1) → ca7a334c6 (S3) → 2de5b2647 (S1
default-OFF) → ec8448ed5 (S2, opt-in). Defaults ship EAGER = phase-total
neutral: final cross-binary trio scrolling before 34 / head 33 ms
(**0.97**), dense_cells/unicode ratios 1.00 everywhere; Metal + GL suites
both Ran 359 with only the two documented dev-zsh errors; scroll_semantics
goldens byte-identical in every arm. All timing LOAD-DEGRADED (loadavg
5.5–16.3, launchservicesd ~1 core; interleaved same-window arms, ratios
valid, absolutes flagged).

- **Profile gate (P13B-0, plan pre-mortem #1) — PASS.** Fresh sample(1) of
  vtebench scrolling on the pre-lever build: the recycled-row clear is
  **37.9% of main-thread busy** (2283/6027 samples; 39.7% incl. bzero
  variants; ≥35% under all four denominator readings), split ~1315 GPUCell
  (20 B) : ~967 CPUCell (12 B) samples. Below the plan's renormalized ~49%
  estimate — exactly why the fresh capture was gated — but clearing the
  bar (`.omc/verify/wave13b/P13B-0-PROFILE.md`).
- **S1 — `is_blank` lazy GPUCell clear** (38984db8d; default flipped OFF
  at 2de5b2647). `linebuf_clear_line` keeps the 12 B CPUCell clear eager
  in every arm (every text reader keys off CPUCells) and defers the 20 B
  GPUCell clear behind a new `is_blank` LineAttrs bit; render routes blank
  rows via `update_line_data_blank[_diff]`; the one direct GPU reader
  (`get_line_edge_colors_at_row`) gates to default bg; writers clear
  is_blank only through materialize chokes that leave GPUCells fully
  defined. Direct headline win ~0 BY DESIGN (draw_ascii_run re-covers
  drawn GPUCells, so a whole-row materialize is a relocate — the plan's
  recorded counter-finding); the deliverable is the S2-ready substrate.
  Mid-gate verdict: same-binary env A/B eager 33 vs lazy 47 ms
  (**1.42×**), bimodal (low mode ~35–36 ≈ eager, high mode ~55–57 = +1
  60 Hz frame exactly; cross-binary trio concurred at 1.59–1.62) with NO
  work amplification anywhere (D2 bytes/frame 66156=66156, passes 1=1,
  presents 0.87× — FEWER): a pure pacing-phase effect, the intermittent
  knife-edge version of the S2 coupling below. → opt-in diagnostic arm.
- **S3 — circular line_map/line_attrs** (ca7a334c6) — **KEEP, neutral.**
  The marginless `linebuf_index`/`reverse_index` memmove pair (393
  samples, 6.5% of busy) becomes an O(1) head bump; every access goes
  through the branchless `lb_phys` accessor (head + conditional subtract,
  ~1 predictable cycle); regions/insert/delete normalize to head==0
  first, so the tested physical memmove internals are unchanged (that
  normalize + reorder zone is banner-marked as the only sanctioned
  physical-index path). No runtime lever (structural): identity proven by
  byte-identical goldens + datatypes/screen/layout/multicell suites both
  arms of S1. Verdict: head/s1only 1.02 mid-gate, head/before 0.97 final
  — the per-access cmov ≈ cancels the deleted per-scroll memmove; the
  O(1) structure is retained for free.
- **S2 — high-water-mark tail-clear** (ec8448ed5) — the real lever,
  **OPT-IN pending the pacing fix**. GPU-only-first cut: the CPU 12 B
  clear stays eager in every arm (CPU readers never see stale, no reader
  gate), the scroll-time GPU clear is skipped entirely, and the stale
  tail `[xlimit, xnum)` — xlimit derived from the clean CPUCells — is
  zeroed parse-side at line finalize (screen_index / eviction / the
  init_line choke), 0 work for full-width lines; render clips the
  in-progress cursor line in the ring slot only (render-owned, no
  cross-thread state). Regions/reverse/insert/delete/resize pass
  allow_lazy=false → eager, correct by construction. A latent
  colored-blank bug was caught during implementation (erase-to-bg writes
  a cpu-blank row whose xlimit==0 finalize would zero the erase color)
  and fixed by making init_line authoritative BEFORE the writer runs;
  regression test landed. Correctness: hwm-vs-eager golden frames **4/4
  byte-identical** incl. partial_scroll/partial_cursor; suites green in
  all three arms. Perf gate FAIL: eager 34 / hwm 48 (**1.41×**) /
  relocate 36 ms — the governor coupling below, not the mechanism.
- **S2b (further/aggressive tail-clear variants): CONTRAINDICATED.** S2
  already proves the memset approach is capped by the governor coupling;
  S2b amplifies the same cadence regression without touching the root.

Root cause (code-confirmed; the phase's chief deliverable): the S1/S2
regressions are neither CPU nor upload — they are a **parse↔render pacing
coupling in the iosurface flood governor's immediate-encode floor**
(child-monitor.c:1099-1122). The input-driven immediate-encode fast path
requires `now − last_gpu_present_at ≥ immediate_encode_floor` (L6: ~0.5×
refresh ≈ 8 ms @60 Hz). Removing the recycled-row clear speeds the parse
so each scroll frame's damage completes **inside** the floor → the fast
path is disqualified → the frame defers → the request path falls to the
250 ms `no_render_frame_received_recently` fallback → presents collapse
(hwm 6.6× fewer presents; median present gap 377 vs 57 ms; 0% of gaps in
the normal 40–80 ms request-loop band vs eager's 70%; per-frame
bytes/passes/encode identical) → main-loop wakeups slow → PTY
backpressure. The eager memset had been slowing the parse just enough to
keep the fast path qualified. vtebench's per-sample sync waits on a
present, and the rival captures use the same vsync-synced method, so the
cadence legitimately counts against the headline. Fix candidate (next
phase): a floor-disqualified frame with pending damage must resync the
link promptly instead of falling to the 250 ms fallback. Step-0
confirmation instrumentation is spec'd in
`.omc/verify/wave13b/VERIFY-REPORT.md` §4 (immediate_encode true/false
counts, now−last_present distribution at the gate, fallback-branch rate,
per-tick dirty fraction). [Phase 14 ran that Step-0: the fallback-tail
collapse was CONFIRMED and fixed (stall-rescue, default-ON), but the
floor mechanism was REFUTED — floor_blocked ≈ 0 in both arms, and the
immediate-encode path is off the flood critical path. See Phase 14.]

Scroll-clear arm ledger (`scroll_clear_mode()`, line-buf.c — resolved
once from the environment, precedence top-down):
- `KITTY_DISABLE_LAZY_ROW_CLEAR` set & ≠0 → **EAGER** (escape hatch, wins).
- `KITTY_DISABLE_LAZY_ROW_CLEAR=0` → **RELOCATE** (S1 diagnostic arm).
- `KITTY_ENABLE_HWM_CLEAR=1` → **HWM** (S2; re-test after the pacing fix).
- unset → **EAGER**, the shipping default until the S2 acceptance gate
  (stable hwm/eager < 1.0, no bimodal mode, scrolling ≤ 26 ms) passes.

Reader/writer contract (binding on future scroll-model edits): a row with
`is_blank` set has **zeroed CPUCells** (the 12 B clear is eager in every
arm) — every text reader (xlimit_for_line, line_is_empty, line_length,
unicode_in_range, line_as_ansi, selection/as_text) is safe ungated — but
**stale GPUCells**: GPU readers must gate (edge colors → default bg;
render → blank[_diff] or the hwm tail clip). Any writer clearing is_blank
must leave the GPUCells fully defined — that is the
`linebuf_materialize_blank_line` / `linebuf_finalize_hwm_line` /
`linebuf_make_authoritative_cold` chokes (init_cells stays a no-op under
HWM so the render clip keeps covering plain draws). History never holds
is_blank (rows are made authoritative before the slot swap). [Phase 15
L2 INVERTS this clause: with `KITTY_ENABLE_CONSUMER_TAIL_CLIP=1`,
history MAY hold deferred is_blank rows — the render clip covers them
and every cross-buffer copy is made authoritative on copy. Interior
gaps are materialized on cursor-jump (S1-lite, 6304909f5). See
Phase 15.] Under S3,
all line_map/line_attrs indexing goes through `lb_phys`; the banner-marked
normalize + reorder functions are the only sanctioned physical-index zone
(they run at head==0).

Exit gate: scrolling ≤ 26 ms **NOT MET** (default eager = 34 ms = the
pre-13B baseline; the block is the governor coupling, chartered as the
next phase — Future work item 12). All other gates MET: goldens
byte-identical every arm; the 10-scenario pre-overwrite battery
(reverse-scroll/ED2/ED3/ring-wrap) green every arm; dense_cells/unicode
1.00 across arms and binaries; suites at baseline both backends; every
lever kill-switched and A/B'd same-binary.

## Phase 14 (Wave 14): the pacing decouple — governor fixed and exonerated

Status: LANDED + MEASURE-FIRST CLOSE (charter
`.omc/handoffs/wave14-pacing-decouple-KICKOFF.md`; ADR
`.omc/plans/2026-07-07-wave14-pacing-decouple.md`; verify
`.omc/verify/wave14/{STEP0-CONFIRMATION,VERIFY-REPORT,SWEEP-REPORT}.md`).
Commit arc: 0a4d9b9c5 (Step-0 gate instrumentation) → 3d28473a6
(stall-rescue, default-ON, kill-switched) → 029ae4310 (harness
metal_present parse fix) → 8edd417db (stall-bound sweep knob). The wave
fully adjudicates the Phase 13B pacing hypothesis: the floor mechanism
is REFUTED, the 250 ms-tail pathology is REAL and FIXED, and the hwm
scrolling regression is proven pacing-INDEPENDENT — the governor is
exonerated and the ≤26 ms target re-chartered on a non-pacing root
cause (Future work item 13). Suites Ran 359 both backends at baseline
throughout; scroll_semantics goldens byte-identical in every arm.

- **Step 0 — runtime confirmation (BLOCKING GATE, verdict REFRAMED).**
  `KITTY_PACING_DEBUG=1` counters at the encode gate (zero-cost cached
  bool; one "pacing:" record per 512 gate evals + at teardown;
  cumulative, so the teardown line = run totals). REFUTED the 13B
  trigger: floor_blocked = 0.36%/0.60% of ticks (eager/hwm) — the
  immediate-encode path, floor included, is off the sustained-scroll
  critical path entirely (its RENDER_FRAME_NOT_REQUESTED precondition
  is ~never true while the link paces); the sub-floor gate-gap share
  was LOWER under hwm (12.7% vs 18.0%), the opposite of "the faster
  parse lands damage inside the floor". CONFIRMED the tail: hwm defers
  hit the 250 ms fallback 6.7× more (38.4% vs 5.7% of defers), presents
  2.6× fewer, and the 40–80 ms request-loop band went 65% → 0%.
- **The real mechanism (code-grounded, runtime-arbitrated).** The pace
  link is an NSWindow-vended CADisplayLink on the [NSApp run] main
  runloop; requestRenderFrame always (idempotently) resumes it, and the
  link callback stamps last_render_frame_received_at unconditionally —
  so "stale" ⟺ an IN-RUNLOOP link unserviced for the bound: main-thread
  starvation by the parse-hot tick loop (H1; stall_link_in_runloop
  share = 1.0 in EVERY run, all arms and loads — H2 paused-desync and
  H3 bookkeeping-loss are dead). The 250 ms fallback re-request is a
  NO-OP for an in-runloop link (H4) — recovery waited on main-thread
  yield, which is why hwm's present medians were a variable 88–252 ms
  rather than a clean 250 ms spike.
- **The fix (3d28473a6) — bounded-staleness stall-rescue, default-ON.**
  In the stale defer sub-branch (Metal-only): staleness bound 250 ms →
  clamp(3×refresh, 24–60 ms); on stall, render the pending damage
  inline THIS tick (the same render-through the immediate-encode path
  uses) and re-arm the link, refresh-capped by a separate 1×refresh
  present floor (13A L6 intact — a fully starved link cannot exceed
  refresh); when the cap defers the rescue, set_maximum_wait(1×refresh)
  re-ticks the loop. immediate_encode_floor and the immediate path are
  untouched. Result: gap_ge250 collapses 59.4 → 2.0 per run (**96.6%**),
  the 16–40/40–80 ms bands return from 0%, goldens byte-identical, idle
  = 1 present/20 s (== HEAD, no wakeup storm), flood cap held
  structurally + empirically (min present gap 19.3 ms ≥ refresh,
  sub-refresh count 0). Typing is guarded structurally (the rescue
  requires render_state == REQUESTED; cold typing rides the untouched
  NOT_REQUESTED edge) — a real p99 awaits an Accessibility-granted
  session (CGEventPost is blocked for python3.14 on this machine).
- **The decisive negative — pacing and scrolling are DECOUPLED.** The
  cleanest A/B (same hwm memset): fix ON 47 ms vs OFF 48 ms — the fix
  moves vtebench scrolling by ≈0 while collapsing the tail 96.6%. The
  stall-bound sweep (8edd417db knob, KITTY_PACING_RESYNC_STALL_MS ∈
  {17,24,33,50}) is FLAT: scrolling 47–49 ms at every bound, and the
  cadence itself is bound-invariant (hwm gap_16_40 stays 1–2% vs
  eager's 31% at EVERY bound — the rescue can only present when the
  main loop runs render(), and that interval, not the bound, is the
  quantum). Relocate corroborates: eager-like healthy cadence yet the
  slowest arm (53 ms). hwm completes ~66 vtebench samples/5 s vs
  eager's ~99, bound-invariant, at 13B-identical per-frame bytes and
  passes — the residual is per-sample frame-readiness cost in the
  deferred-clear scroll model, not the governor (item 13).
- **Pacing lever ledger (all resolve-once, Metal-only):**
  - `KITTY_PACING_DEBUG=1` → encode-gate counters, one-line "pacing:"
    records (teardown totals; trailing `stall_bound_eff_ms` — integer
    truncation makes the refresh-derived default report 49 @60 Hz).
  - `KITTY_DISABLE_PACING_RESYNC` set & ≠0 → HEAD 250 ms-defer behavior
    (kill switch, byte-identical; proven to reproduce the 13B
    pathology: defer_fallback250 43.3% of defers).
  - `KITTY_PACING_RESYNC_STALL_MS=<int>` → replaces the 3×refresh
    bound, clamp [8,250] (diagnostic; inert while the kill switch is
    on; the 1×refresh present floor is NOT overridable).
- **Corrections to the record.** Phase 13B's root-cause paragraph
  stands corrected (marked in place): right about the fallback-tail
  signature and that the coupling deserved its own phase; wrong about
  the floor — and its "the eager memset kept the fast path qualified"
  story dies with it. Harness: the shared PRESENTED_RE had rotted
  against the pace= suffix (silent 0-frame parses) — fixed at
  029ae4310. Build: `make`'s devel path runs a destructive
  `git rebase origin/master`; the dev build command is
  `KITTY_USE_METAL=1 python3.14 setup.py build` (now a CLAUDE.md hard
  rule).

Exit: hwm/eager < 1.0 and scrolling ≤ 26 ms **NOT MET** (best 1.42–1.45×
across all bounds; eager 33 ms under light load) — closed measure-first
per the charter, with the residual root cause localized and chartered
(item 13). The stall-rescue ships default-ON behind its kill switch: it
fixes a real interactive-latency pathology (250 ms+ present tails under
any main-thread stall) at zero measured cost to eager, idle, or flood.

## Phase 15 (Wave 15): frame-readiness — the metric was parse, and hwm now wins it

Status: LANDED, GATE PASSED (charter
`.omc/handoffs/wave15-frame-readiness-KICKOFF.md`; ADR
`.omc/plans/2026-07-07-wave15-frame-readiness.md`; verify
`.omc/verify/wave15/{STEP0-TIMELINE,VERIFY-REPORT}.md` + `s1lite/`).
Commit arc: a06489c57 (KITTY_FRAME_TRACE per-tick probe) → f9e89de46
(sparse-cursor guard, strict xfail) → 035f80117 (L1 O(1) finalize) →
77b6033be (L2 render-clip defer) → 6304909f5 (S1-lite interior-gap fix;
guard flipped to a plain PASS). Headline: **hwm+L2 scrolling parse
18.45 ms/MiB = 0.66× eager's 27.85, sample ≈24 ms ≤ the 26 ms target**
(load-flagged absolute; ratios rule); fullscreen 0.66×; dense 0.99×
no-harm; D2 upload ≤ eager on every axis; pacing telemetry and idle
unregressed; pixel goldens byte-identical. The hwm+L2 default-flip
packet is ASSEMBLED and unblocked — the flip itself is a user decision
(typing evidence remains structural-proxy-grade).

- **Step 0 — the metric reframe (source + trace, two-way).** A vtebench
  scrolling sample times `write_all(1 MiB "y\n")+flush` — PTY write
  backpressure = kitty's parse drain rate; there is NO present-sync
  anywhere (bench.rs:181-186). The per-tick trace concurs: each sample
  drains in ~one main-loop tick; parse_ms ≈ the sample; render_ms
  0.01–0.03; wakeup/present gaps ≈0. 13B's "the sample waits on a
  present" premise is dead, and Wave-14's bound anomaly closed: bounds
  move rescue cadence, never the parse wall. The benchmark never
  measured presentation at all.
- **Step 0b — the delta named to a source line.** hwm−eager = +13.96 ms
  of parse wall per MiB (96% of the sample delta), localized by
  sample(1) to the O(xnum) backward xlimit scan in
  `linebuf_finalize_hwm_line` (line-buf.c:470, inlined into
  screen_index): +13.81 ms of screen_index self-time, with the memset
  primitive FLAT between arms. Geometry: on "y\n" (xlimit=1) the
  finalize scanned ~99 cells and zeroed ~99 per line — S2's "0 work for
  full-width lines" premise INVERTS on sparse lines. On full-width
  lines the scan is O(1) and the tail-zero skips entirely — hwm's
  structural win case (scrolling_fullscreen); dense_cells never scrolls
  (alt-screen in-place rewrite) and is a no-harm axis only.
- **L1 (035f80117) — O(1) finalize.** `line_xlimit` = per-row
  write-extent UPPER BOUND (exact on the plain-ASCII fast store;
  non-append writers — IRM shift, multicell nuke, wide/grapheme cache
  stores, TAB — mark XLIMIT_UNTRACKED → full rescan). A fuzz + the live
  verify killed the ADR's exact-tracking sketch with 5 concrete holes;
  the bound design is never worse than the old scan and O(1) on the
  flood. Escape hatch `KITTY_DISABLE_XLIMIT_TRACK`. hwm parse 42.1 →
  32.4 ms/MiB — still 1.16× eager: **L1 alone does not win**; the
  residual is deferred-model bookkeeping.
- **L2 (77b6033be) — the actual win: clear per visible row, not per
  scrolled line.** The consumer-side clip already existed for visible
  rows (screen.c:3999 clips is_blank rows to xlimit IN THE RING); L2
  deletes the parse-side tail-zero at scroll/eviction and extends the
  clip to history rows — per-scrolled-line work (~5000 rows/MiB)
  becomes per-visible-row-per-frame work (~30). History now holds
  deferred rows — the 13B "history never holds is_blank" contract is
  INVERTED (marked at the 13B section) — and every cross-buffer copy of
  a deferred row is made authoritative on copy (fast_rewrap,
  copy_line_to, paused-render snapshot, resize). Opt-in
  `KITTY_ENABLE_CONSUMER_TAIL_CLIP=1` (HWM-only), backend-agnostic
  shared C. Result: scrolling 18.45 (0.66×), fullscreen 23.43 (0.66×),
  dense 4.58≈4.61 (0.99×), samples/5 s 145 vs eager's 99; D2
  bytes/frame ≤ eager everywhere (fullscreen 3.6× FEWER, pixel-proven).
- **S1-lite (6304909f5) — the interior-gap fix the guard caught.** The
  mandated sparse-cursor-address-then-scroll golden (f9e89de46, judged
  vs EAGER ground truth) exposed a PRE-EXISTING S2 defect: the tail
  clear covers [xlimit,xnum) only, so interior gaps between
  cursor-addressed writes displayed stale GPU cells (identical with L1
  off; eager/relocate unaffected; off the flood path; L2's clip is also
  tail-only). Fix per ADR §10c: a cursor-positioning command
  (CUP/CUU/CUD/CUF/CHA/HPA/TAB — 5 entry points) into a deferred row
  materializes the WHOLE row (RELOCATE-zero + drop is_blank) — correct
  independent of the tracking (never consults line_xlimit), and the
  append flood never jumps → ZERO flood cost (post-fix smoke 19.11 /
  24.61, unchanged). The guard is now a plain assertion, green in every
  arm on both backends; pixel goldens byte-identical on both scenes
  (fullscreen_scroll, sparse_jump).
- **Verification discipline that paid.** `KITTY_XLIMIT_VERIFY=1` — a
  runtime env-gated bound-vs-scan cross-check with abort() (NOT
  assert(): setup.py appends -DNDEBUG) — ran live through full suites
  and caught **8 real would-be corruptions** during development (5 L1
  tracking holes + 3 L2 copy-path holes), ending clean in every arm on
  both backends. Suites Ran 360 baseline-green throughout;
  scroll_semantics goldens byte-identical across
  eager/hwm/hwm+L2/kill-switch arms at every commit.
- **Scroll-clear lever ledger (updated; defaults as of the 2026-07-07
  flip, commit 8545ca3d7).**
  `KITTY_DISABLE_LAZY_ROW_CLEAR` (set≠0 → EAGER hatch, wins; =0 →
  RELOCATE diagnostic) · HWM is the DEFAULT (unset; also
  `KITTY_ENABLE_HWM_CLEAR=1`; `=0` → EAGER opt-out) — with the L1 O(1)
  finalize + S1-lite gap materialize · the L2 consumer clip is
  DEFAULT-ON under HWM (`KITTY_ENABLE_CONSUMER_TAIL_CLIP=0` → back to
  the L1 finalize tail-zero) ·
  `KITTY_DISABLE_XLIMIT_TRACK≠0` → L1 escape (old scan) ·
  `KITTY_XLIMIT_VERIFY=1` → debug cross-check. Measurement policy (user
  directive, standing): test kitties spawn NO-ACTIVATE
  (KITTY_NO_INITIAL_ACTIVATE=1, the harness default) — take_focus only
  for a render-telemetry run, at most one per battery; parse metrics
  are focus-independent (calibration ratio 0.989).
- **The flip packet (assembled; decision = user's).** FOR: 0.66× on
  both scroll axes, ≤26 ms met (24 ms, load-flagged; edges the
  alacritty 26 ms reference under light load), dense no-harm, D2 clean,
  pacing/idle clean, the interior-gap defect found AND fixed with a
  permanent guard, pixel-identical rendering, every lever
  kill-switched with the eager hatch retained. CAVEATS: typing p99 is
  structural-proxy-grade (the deferred paths never touch the
  cold-typing NOT_REQUESTED edge; a real p99 needs Accessibility for
  python3.14); the L2 ring clip is suite + CPU-golden + 2-scene
  pixel-golden validated, not exhaustively GPU-ring asserted. Flip
  mechanics when approved: scroll_clear_mode unset → HWM + consumer
  clip default-ON (eager hatch stays; relocate stays diagnostic).
  **[EXECUTED 2026-07-07 at commit 8545ca3d7 — user-approved with the
  proxy-grade-typing caveat. Post-flip verification: Metal + GL suites
  Ran 360 baseline-green with KITTY_XLIMIT_VERIFY live; scroll golden
  battery green in all four arms; no-activate smoke default 19.2
  ms/MiB ≡ explicit hwm+L2, eager hatch 28.0.]**

Exit: the ≤26 ms scrolling target is MET on this wave's evidence (the
first arm to beat eager on every scroll axis). Remaining charter: item
14 — the eager/shared draw-path re-segmentation cost
(init_segmentation_state, 9.1 ms/MiB) — orthogonal, and it would stack
with hwm+L2.

## Phase 16 (Wave 16): the draw bucket — measured, diffuse, demoted

Status: MEASURE-FIRST CLOSE at Step 0 (charter
`.omc/handoffs/wave16-draw-segmentation-KICKOFF.md`; evidence
`.omc/verify/wave16/{STEP0a-SYMBOLS,STEP0-ATTRIBUTION}.md` +
`STEP19-PREP-NOTES.md`). No product code was changed — the Step-0 gate
fired exactly as designed: no lever was picked because no coherent
target survived measurement.

- **Attribution** (sample(1) on post-LTO symbols — init_segmentation
  survived as a distinct symbol, no instrument needed; 3 rounds/arm,
  share spreads ≤2%, eager AND hwm+L2): the ~9.1–9.6 ms/MiB draw
  bucket splits draw_text 43% / init_segmentation_state 31% /
  draw_control_char 26% (+ selection ~0.9 ms/MiB) — DIFFUSE, no ≥40%
  content-general term.
- **The family hypothesis INVERTED** by the fullscreen discriminator:
  seg/lf/sel RISE per MiB on full-width content (×1.3–1.4 —
  per-OCCUPIED-CELL, ∝ written width) while draw_text COLLAPSES
  (×0.33 — the per-line CALL dispatch term). On "y\n" (xlimit=1)
  per-cell ≡ per-line, which is what made the bucket read as fixed
  overhead. Item 14's premise — "init_segmentation_state
  re-segmentation dominates" — is REFUTED: on the bench it is a bare
  RESET (stepping skipped), and where stepping actually runs
  (wide/unicode content) it is REQUIRED for correctness.
- **The honest best lever (recorded, NOT chartered):** a provable
  probe elision — `next_char_was_wrapped` is set ONLY by
  continue_to_next_line (DECAWM auto-wrap, screen.c:719), never by a
  bare LF, so the explicit-LF path's prev-cell probe (a scattered read
  of the previous line's last CPUCell) and the second
  init_text_loop_line re-init per line are pure waste there. Bounded
  at ~1.5–3 ms/MiB on EAGER scrolling only (5–10% of parse), less on
  hwm+L2, ~zero on wide content. Below the campaign's action
  threshold; mechanism + call sites preserved in
  `.omc/verify/wave16/STEP19-PREP-NOTES.md` if ever wanted.
- **The true remaining heavy hitters are OUTSIDE the draw bucket**:
  the memset row-clear 11.4 ms/MiB (~40% of eager's parse wall) +
  scroll bookkeeping 5.7 — the clear/scroll path Phase 15 already
  halved via hwm+L2 (0.66×). The economic answer to eager's memset is
  the PENDING hwm+L2 default flip (Phase 15 packet), not a new eager
  lever.
- **Reference baselines recorded** (parse ms/MiB, eager / hwm+L2):
  scrolling 28.2 / 18.85 · fullscreen 37.1 / 24.25 · unicode
  3.37 / 3.34 (draw_text 93% with inlined steppers); kitten
  __benchmark__ ascii 240.6 / unicode 199.1 MB/s.

Exit: item 14 resolved as MEASURED-AND-REFUTED; no new charter opened.
The scrolling campaign's remaining lever is the user's default-flip
decision (Phase 15 packet). [Executed 2026-07-07 at 8545ca3d7 — see
item 5; the scrolling campaign is CLOSED with hwm+L2 as the shipping
default.]

## Phase 17 (Wave 17): the post-flip survey — plateau on-turf, one new gap

Status: SURVEY CLOSE (charter
`.omc/handoffs/wave17-rebaseline-survey-KICKOFF.md`; report
`.omc/verify/wave17/SURVEY-REPORT.md`; measurement-only — no product
code). The first full-matrix baseline under the shipped hwm+L2
default: ALL 12 vtebench benchmarks × (default / eager hatch /
alacritty reference) × 3 interleaved rounds, plus kitten __benchmark__
and idle/cold spot checks. Coverage 30/36 cells with 2 arm-uniform
generator skips listed (cursor_motion and light_cells emit empty
payloads under every arm including alacritty — their generators, not
kitty). The alacritty arm ran sanitized-env and was probe-verified
NOT to steal focus (direct-binary launch does not activate).

- **P0 flip-regression check: REFUTED.** default ≤ eager hatch on
  every measured bench. The one candidate (scrolling_top_region,
  median ratio 1.083) is integer/load noise — rounds [39,39,37] vs
  [36,36,39] overlap, parse_ms/MiB identical (~21.6 both), and the
  other three region benches are default == hatch exactly. The flip
  is safe to soak.
- **Flip wins held at survey scale**: scrolling 24|34|23 ms
  (default|hatch|alacritty — parity with the reference);
  scrolling_fullscreen 52|74|31 (the 0.70× flip win holds;
  parse-bound residual 1.68× vs alacritty on the already-optimized
  axis).
- **Ranked residual gaps (all on previously-unmeasured axes):**
  ① alt-screen/DECSTBM region scroll **3.7×** (37 vs 10 ms across
  scrolling_bottom_region + both small_regions) — attribution:
  frame-pacing / PTY-drain coupling, NOT parse (20 ≈ plain's
  19 ms/MiB), NOT render (~0.03 ms/MiB), NOT present count (LOWER
  than plain, 0.19–0.23 vs 0.57/sample); the discriminator is the
  waiting-for-pace-tick gate share 0.74–0.76 vs plain's 0.50. hwm+L2
  is inert on this path (alt screen, no scrollback; default == hatch
  exactly). ② sync_medium_cells (escape-heavy vim replay) **2.73×**
  (30 vs 11), same pacing signature (waiting 0.66). ③ dense_cells
  1.67× (draw-bound) · unicode 1.5× (glyph raster) · medium_cells
  1.13× · plain scrolling 1.04× — recorded below threshold.
- **Drift check clean**: all four campaign axes within noise of the
  wave-15/16 references (scrolling 19.2/18.85, fullscreen 24.8/24.25,
  unicode 3.35/3.34 parse ms/MiB; dense no-harm); kitten ascii
  235.9 / unicode 200.1 MB/s ≈ ref; idle 2 presents/20 s.
  Accessibility remains ungranted → typing evidence stays
  structural-proxy.
- **Verdict: CONDITIONAL CHARTER, not a bare plateau.** Wave 18 is a
  scoped INVESTIGATION of the region/vim pacing-drain coupling,
  Step-0-gated on a drain-vs-present decouple A/B — the Phase-9
  suppression lever (`KITTY_TEST_SUPPRESS_RENDER`,
  child-monitor.c:1327) still exists, so the discriminating probe is
  nearly free: if region sample_ms collapses toward its ~20 ms/MiB
  parse wall with rendering suppressed, the lever family is confirmed
  and the prize sized (suppression over-estimates a real fix — the
  Phase-9 caveat rides along); if not, the gap is
  structural/benchmark-artifact and the wave closes measure-first.
  Wave-14's governor exoneration is NOT contradicted: it covered
  main-screen scrolling where parse ≈ sample; on these axes parse ≠
  sample, so pacing is back on the table for THIS path only. Honest
  caveats carried into the charter: synthetic-flood risk (the vim
  2.7× argues real apps see some of it), hypothesis-not-root-cause,
  load-degraded absolutes (ratios ruled throughout).

Exit: the scroll-clear campaign is confirmed plateaued-and-winning on
its own axes with zero regressions; Future work item 15 charters
Wave 18 (`.omc/handoffs/wave18-region-pacing-KICKOFF.md`).

## Phase 18 (Wave 18): the region-pacing kill test — lever family refuted

Status: MEASURE-FIRST CLOSE at Step 0 (charter
`.omc/handoffs/wave18-region-pacing-KICKOFF.md`; evidence
`.omc/verify/wave18/STEP0-DECOUPLE.md`, 24 clean runs). No product
code — the kill test did its job before a line was written, the
second time this campaign's Step-0 discipline has retired a
plausible-but-wrong lever (the first: the Phase-16 draw bucket).

- **The test.** KITTY_TEST_SUPPRESS_RENDER=1 (the Phase-9 lever,
  semantics verified: the early-return sits at the very top of
  render_os_window — it deletes the gate, defer, request, AND present
  entirely, while parse/io/timers run byte-identical; parse fidelity
  ON/OFF 0.999–1.007) vs OFF, same-binary, ≥3 interleaved rounds each
  on scrolling_bottom_region, sync_medium_cells, and plain scrolling.
- **The verdict.** Deleting 100% of the render half moved the drain
  by 0.0 ms: region 37.0 → 37.0, vim 30.0 → 30.0, control 23.25 →
  24.0 (ON marginally slower); total bytes drained in the fixed 5 s
  window equal OFF↔ON (~235/245 MiB). **The prize for the
  drain-vs-present decouple family is ~0 — there is no coupling to
  break.** Main-screen parity untouched.
- **Why the Wave-17 discriminator misled.** The waiting-gate share
  (0.74 vs 0.50) is a SYMPTOM, not a cost: WAITING ticks are cheap
  no-ops (return at the defer without set_maximum_wait) that never
  block the next tick's parse_input, which runs BEFORE render in
  process_global_state. Driving the gate share to 0.0 changed
  nothing; render itself had only 0.03–0.06 ms/MiB to reclaim against
  a ~20 ms/MiB parse wall.
- **The residual, honestly re-attributed (recorded, NOT chartered).**
  Region drains ~4 ms/MiB and vim ~9 ms/MiB above their parse walls
  and this SURVIVES suppression — non-render. Leading candidates: the
  I/O-thread input_delay coalescing policy (io_loop batches main-loop
  wakeups for bulk output — cross-reference Phase 8's finding that
  6.0% of the devlog gap is input_delay POLICY, a deliberate
  latency/efficiency tradeoff) and the vtebench back-pressure
  measurement model itself (drain totals are ~axis-invariant, so
  per-sample ms partly reflects payload shape — survey §10.1's
  caveat). Policy tradeoffs and artifacts, below the action
  threshold.
- **Program verdict: PLATEAU — maintenance mode.** Every coherent
  lever family the surveys produced has now been landed (hwm+L2
  shipping at 0.66×, plain scrolling at alacritty parity),
  measured-and-refuted (the Phase-16 draw bucket), or killed at
  Step 0 (this phase). The guard tests (sparse-cursor, pre-overwrite,
  the xlimit verify mode) watch the shipped model; the record
  contains everything a future input_delay probe would need.

Exit: item 15 resolved REFUTED-AS-LEVER; no new charter opened.
Standing user items: the ff-merge of metal-fable-5-fast and the
optional Accessibility grant for a measured typing p99.

## Phase 19 (Wave 19): the founding competitive bar — measured; kitty is 3rd/4th

The wave that finally cashed the campaign's founding claim: 4 competitors
(Ghostty, Alacritty, iTerm2 nightly, Terminal.app) × 3 axes (throughput,
typing keypress→photon, energy), same machine, parity config (Menlo 11pt,
AA on, ligatures off, 100×30, shell integration off), sanitized env, kitty
interleaved in the same measurement block. Plan
`.omc/plans/2026-07-08-wave19-worlds-fastest-bar.md` (Option C′); artifacts
under `.omc/verify/wave19/` — `MATRIX-BLOCK.md` (cells),
`MATRIX-FINAL.md` (adjudication), `GATE-ADJUDICATION.md` (probe gates).

**Step-0 probes first (zero product code), and two of three trace-lane
mechanisms died on contact**: Probe A (render-suppress) returned r≈0.93–1.0
— the dark residual on unicode/dense is NOT raster (render_ms ≈ 0.09); the
follow-up io-side decomposition (L3) found the real wall: a hard macOS
kernel ceiling of **1024 B per PTY read** (all idioms, content-independent,
`pty_ceiling_probe.py`) times kitty's 11–22 µs io-wakeup round-trip → 45–93
MB/s inflow vs a 173–240 MB/s blocking-loop bound; drain-until-EAGAIN
refuted (queue is empty after one read). Probe B: `input_delay=0` moved the
region axis only partially (D=0.304, prize ~2.7% < 5%) and vim/unicode/dense
not at all — **L2 (adaptive/default input_delay) is dead on four axes**,
with the flood side-benefit confirmed by direct evidence (delay=0 explodes
flood render prep 0.01→~10 ms/MiB — the batching does real work). Probe C:
survival 1.0 — the vim-axis excess attributes entirely to DECSET-2026, and
the L4 decomposition showed the 3.2× sync headline is vtebench
measurement-model amplification of a real **1.43×** cost, the per-BSU
full-grid snapshot (~2.3 µs/pair); fix = per-line generation tracking (COW
snapshot), architecture-level → Wave-20. The one lever landed stays landed:
the do_parse input-cadence pause bound (8d47ab2da, goldens 4/4).

**The matrix.** Throughput (7-bench vtebench subset × 3 interleaved
rounds, lead-app rotation): **kitty is 3rd on all seven benches** — Ghostty
wins 6/7, Alacritty 1/7 (bottom_region), iTerm2/Terminal.app trail
everywhere. kitty÷best: dense 1.67×, unicode 1.60×, scrolling 1.92×,
bottom_region 3.60×, sync 6.00×, medium 1.80×, fullscreen 2.81× — the worst
two sit exactly on the L4 (BSU snapshot) and L3 (PTY ceiling) mechanisms.
Typing (new app-agnostic instrument `typing_photon.py`: CGEventPost
rotating-digit injection, CGDisplayStream dirty-rect photon detection, 300
samples/arm, all arms same display, zero focus warnings): **Ghostty and
Terminal.app tie for 1st at p50 7.9/8.2 ms; Alacritty 3rd at 33.5; kitty
tied-4th with iTerm2 at 38.9 ms p50 / 60.9 p99**. kitty's own
`metal_present` cross-validation (n=300) decomposes the cell: ~32.4 ms of
the 38.9 accrues BEFORE present (the keypress→present p50 itself) — the
input→parse-admission→render-schedule pipeline, ≈2 frames at 60 Hz — and
only ~6.5 ms (38.9 − 32.4) is compositor/scan-out.
L1 (gate-2 echo-bypass) was left unlanded by the net-of-matrix charter
gate: its ~3 ms input_delay slice cannot change kitty's typing rank.
Energy (powermetrics, idle/scroll/vim × 60 s × 5 apps): recorded as an
explicit limitation — powermetrics needs root and the operator deferred
the sudo session; the driver/analyzer (`p2b_energy.py`) is built and
validated, so the five cells are replaceable later without disturbing
the other axes. A limitation-only cell fails the victory declaration
closed — moot here, the rule already failed on throughput and typing.

**Instrument findings worth keeping** (they invalidated real data this
wave): (1) windows created in an AppleEvent-launched, never-activated app
are NEVER composited on macOS 27 — AppleScript reports `visible: false`,
CGWindowList shows nothing, and AppleScript `activate` from a background
osascript is ignored under cooperative activation (NSRunningApplication
activation + frontmost verification is the reliable path); Terminal.app's
occlusion throttling had inflated its entire throughput column 2.8–4.6×
(corrected by a visible-window re-run; iTerm2 measured insensitive; ranks
unchanged). (2) CGDisplayStream dirty rects are in the output buffer's
coordinate space — watch the display that actually hosts the window and
intersect in display-local points (windows on this machine open on a
non-main display). (3) A mid-block `mediaanalysisd`+Raycast load storm
(1-min load 151) forced one full matrix re-run; the quiet-gate's 120 s cap
is not a guarantee — per-row loadavg recording is what made the
contamination adjudicable.

**Verdict (P4.2, mechanical): no declaration.** kitty is not 1st or
tied-1st on any measured axis. The ranked Wave-20 gap list
(`MATRIX-FINAL.md`): (1) typing input→present decomposition (~32.4 ms
pre-present, ≈2 frames — pacing/admission, not raster); (2) select-free
PTY reader hot path (L3, flood 1.6–1.9×); (3) per-line-generation COW
snapshot for DECSET-2026 (L4, sync 6× cell); (4) region-scroll residual
folded into the reader work (L2 policy lane closed). "No lever fires" was
pre-registered as a valid, complete outcome — this wave is the measurement
that makes Wave-20's engineering falsifiable.

Exit: matrix complete and adjudicated; verdict = ranked gap list, no
victory claim; Wave-20 charter auto-generated from the gap list.
Standing operator item: `kill -CONT` the SIGSTOP-frozen mediaanalysisd
(pid 17320; see QUIET-GATE-NOTE.md).

## Phase 20 (Wave 20): both losing axes decomposed — typing NO-CHARTER ×2, reader CHARTERED

The wave that executed Wave-19's top-2 gap list under the consensus plan
(`.omc/plans/ralplan-wave20-typing-l3-l4.md` v2.1): Track T = typing
input→present stage decomposition, Track R = L3 select-free reader
adjudication. Artifacts under `.omc/verify/wave20/` — `T1-TYPING-DECOMP.md`,
`R1-READER-ADJUDICATION.md`, `GATE-ADJUDICATION.md`, `L-TYPING.md`,
`P0-PREFLIGHT.md`. Preflight fixed a real build defect en route: the
launcher-bundle rebuild deleted `default.metallib` AFTER the shader step
installed it (silent GL fallback; the launcher symlink defeats NSBundle so
the runtime loads the LOOSE launcher-dir copy) — `setup.py` now reinstalls
both copies at the end of bundle creation. Golden driver hardened (focus
pin, cursor pin, non-black gate, vacuous-compare guard) + reference
recaptured at 701×391.

**Track T (typing)**: `KITTY_FRAME_TRACE` gained per-keypress `ktrace:`
S1–S5 stage stamps (zero behavior unset; goldens max_diff=0, idle 0.0%).
The n=300 decomposition (AC1 reconciliation 0.0%/0.0%) split kitty's
keypress→photon into S1 3.4 (OS delivery) / S2 11.2 (io wake + echo
turnaround) / S3 3.4 (input_delay batch floor, measured to 0.05 at
delay=0) / S4 ≈0 / **S5 18.4 (pace-link wait — the dominant kitty-owned
stage; 197/300 echoes gate=waiting)** / S6 6.8 (compositor floor). P2.1
round 1: SYNC_IMMEDIATE recovers ~0 (scope excludes link-driven echo
frames — W13A reproduced at stage level), input_delay=0 recovers 8.3/1.2
(refuted family, component-sized only) → NO-CHARTER; structural charter =
extend immediate-encode eligibility to echo frames. **P3 built that lever**
(`KITTY_METAL_ECHO_IMMEDIATE`, echo frames encode inline from the
REQUESTED/waiting state within the 50 ms key-recency window; W14
stall-rescue mechanics; floor preserved; FRAME_TRACE gate class
`echo_imm`). The re-adjudication A/B (n=300/arm, fresh same-block arms) is
the wave's sharpest result: **the lever fully works mechanically —
gate=waiting extinct (echo_imm 245/297), S5 16.68 → 9.40 ms p50 = the
vsync-quantization physical floor (IOSurface `presented_time` stamps at the
first refresh after the contents swap) — and still clears neither band**
(Δp50 5.96 < 9.32*, Δp99 1.67 < 2.90 ABS floor): **NO-CHARTER, S5 is
exhausted as a lever surface at 60 Hz.** The residual kitty−Alacritty gap
(6.35 ms p50) lives in S2 — the per-poll io-wakeup round-trip. Lever stays
in-tree default-OFF as a measurement/reproduction switch (byte-identical
unset, guards green); no matrix change (P4.1 no-op).

**Track R (reader)**: both pre-registered P2.2 preconditions adjudicated.
(1) Inflow: the bare-PTY probe's **dedicated blocking-read thread idiom
sustains 157.9 MB/s ≥ 150 at CPU 1.23× ≤ 1.5×** (hotpoll expected-fail
confirmed — poll(0) re-reads always find an empty queue; the bounded
`read_bytes` rework family is dead at the harness level). (2) Comparative:
Alacritty @ bdb72b3, source-instrumented with the mirror io counters
(`ALACRITTY_IO_TRACE`, observer-effect −0.57%/+4.58% ≤ 5%), on the
identical PTY workload beats kitty **2.78× (unicode) / 1.53× (dense_cells)
MB/s at the SAME ~1 KiB kernel read quantum** (99.8%+ of its reads ≤ 1024 B)
via wakeup economics alone: its read→parse→read loop coalesces 3.6–17.4
reads per wakeup (parse time lets the kernel queue refill) at 6–16%
pollwait vs kitty's 1.0 read/wakeup at 86–90% pollwait → **band (b)
WAKEUP-ECONOMICS CONFIRMED; charter = per-child reader-thread architecture**
(design-first, Wave 21; mandatory: per-fd fairness, EAGAIN-vs-EINTR
discipline, busy-spin guard). R1.4 Ghostty kill-veto never armed (band (a)
never read). Zero reader-path kitty code landed this wave.

**Convergence**: Track T's terminal finding (residual = S2 io-wake hop) and
Track R's charter (reader thread eliminates the poll round-trip) are the
same mechanism — Wave 21's reader-thread design carries BOTH the flood
inflow prize (1.6–1.9× vs Ghostty) and the remaining typing-rank prize.

Harness: typing arms now pin to the LG UltraFine center (operator
directive; `typing_photon.py _measurement_display`, `TYPING_PHOTON_DISPLAY`
override) after a slot survey found the main-display/top-left bands under
the operator's ambient UI recomposite at ~59 hits/s while the secondary's
center idles at ~0.7/s. Energy sidebar (S1) remains operator-gated
(deferred again; no lever landed, so the conditional-default rule was not
exercised). 60 Hz single-machine external-validity caveat rides every
claim; kitty-arm absolute drift vs W19 (±5–11 ms across display/reboot
changes) is recorded — same-block arithmetic only.

Exit: both gates adjudicated with pre-registered arithmetic; no victory
language anywhere; Wave-21 charter = L4 per-line-generation COW (from W19)
+ the per-child reader-thread design, now doubly-chartered.

## Phase 21 (Wave 21): COW refuted at mechanism level; reader design ACCEPTED, W22 skeleton chartered

Executed the consensus plan (`.omc/plans/ralplan-wave21-reader-l4.md` v3,
Option A: one product-code lane = L4, design-only reader track). Artifacts
under `.omc/verify/wave21/` — `L4-COW.md`, `L4-REVIEW.md`,
`L-READER-DESIGN.md` (rev.2), `GATE-ADJUDICATION.md`, `P0-PREFLIGHT.md`;
ADR-0006. Commits `8e2e7ea58` (L4 dormant trace) + `f5c538279` (harness).
Two operator directives applied mid-wave: all measurement launches pin the
operator's real font (MonoLisaCode + features; goldens re-baselined at
901×601, old set archived) and every vtebench run emits a gnuplot PNG.

**Track L4 (pause-snapshot COW)**: P2.L4 = **NO-LAND via the pre-registered
L4.2 cheap-kill — R̂ = 0.1273 < 0.2**, three clean rounds identical to four
decimals, so the 0.5 LAND bar was unreachable by ~4× (R ≤ R̂) and the
behavioral skip was NEVER wired. The refutation is mechanistic, not
implementational: sync_medium_cells' row invalidation is scroll-dominated —
402 bytes/pair does NOT bound rows-invalidated/pair because a 3-byte LF
shifts every visual row beneath it (mean ≈26/30 rows differ between
consecutive BSU snapshots; 50/462 pairs carry DECSTBM+IL/DL) — so a
per-VISUAL-row skip can never elide moved content. W19's "~400 bytes/pair →
a few rows" expectation is thereby corrected. The gated plumbing
(`KITTY_PAUSE_SNAPSHOT_COW`, one-shot cached getenv, per-phys-row uint32
generation lane + allocation serial + snapshot key array) stays compiled-in
**switch-dormant default-OFF**: goldens 4/4 max_diff=0 unset AND ON, idle
0.0% 8/8 both arms, OFF ticks emit cow_copied=0, ON/OFF parse cost
0.987×/1.012× (noise floor). Separate-lane review APPROVE-DORMANT; its
three no-bump windows (eager clear_line on the head-bump path, hyperlink GC
remap, TAB space-fill) all inflate R̂ — the kill stands a fortiori — and
are scoped in-comment as must-bump-before-any-wiring. A slot-anchored
refcounted-line COW (scroll-surviving) is recorded as an open question,
unchartered.

**Track D (reader design)**: P2.D = **ACCEPTED (with recorded conditions)**
after the full two-lane loop — Architect SOUND-WITH-CHANGES ×2 (both
ITERATE rounds consumed: F1–F12, then N1/F4-residual) → Architect FINAL
SOUND → Critic ACCEPTED. The review process strengthened the protocol
itself: **clear-before-drain** for the process-wide main-wakeup CAS (cased
lost-final-bytes proof), the **flush-wakeup-before-park** liveness rule (a
reader never blocks on a full ring without a wakeup in flight),
**EVFILT_USER single-owner teardown** (close-only-after-join), the
**kqueue availability-count** wait primitive (no trailing EAGAIN probe),
and the finding that the reads/consumer-wakeup prize is a property of
reader + **batching window** (eager consumer: 30.7k–43.3k wakeups/64 MiB at
1.5–2.1 reads/wakeup; 1 ms window: 658–688 at 95–100 — a ~45–65× cut),
matching R1.3's Alacritty evidence at the consumer, not the kernel poll.
D4 harness (`r21_reader_proto.py`, bare PTY, zero kitty code): 6/7
pre-registered scenarios PASS (idle 0.046%, 512 park cycles byte-exact,
echo 0.52× under an actively-batched flood — the L5 bypass cuts through,
0 shared-OFD flips, 50 teardown cycles 0 leaks, twofloods 50/50 no
starvation); the flood ≥150 MB/s absolute MISSED and is reconciled
(same-run single baseline itself 96–124; GIL-serialized mock; the
product-legal poll+nonblocking shape cannot inherit R1.1's blocking-read
number). **Consequence: the Wave-22 reader skeleton is chartered against
the pre-registered D5 gate** (MB/s ≥1.3× same-block; PTY-servicing
wakeups/s ≤0.5× the io_polls baseline; reads/PTY-wakeup ≥2; the
baseline-must-fail discrimination clause; per-reader ftrace counters,
RLIMIT_NOFILE raise, EVFILT_USER apple-docs verification and the other
Critic conditions carried in ADR-0006). NO-LAND remains a valid outcome.

Exit: both gates adjudicated with pre-registered arithmetic; zero default-ON
behavior change (MATRIX cells untouched); no victory language; 60 Hz
single-machine caveat everywhere; next action = Wave-22 plan re-pinning the
D5 gate with the ten carried conditions.

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
| 5 | throughput ≥ 2× Phase-0 AND ≥ kitty-GL AND vtebench ≥ Ghostty −10% AND devlog-006 first | MIXED (measured) | 2×: documented shortfall (lever A/B 1.30×/1.20×; Phase-0 binary unrunnable). ≥ kitty-GL: **MET** (Phase-8 same-window: devlog 0.496 vs 0.500, churn 52 vs 51 MB/s — backend-equal on this pipeline-bound axis; the earlier 13% Metal-over-GL devlog delta retracted as load-confounded). devlog-006 first: **NOT MET** — Alacritty 0.435 < Ghostty 0.484 < kitty 0.496 (2026-07-06 interleave); gap decomposed in Phase 8: 6.0% input_delay policy + 10.6% structural (parse/render multiplex), NOT parser CPU. vtebench: captured 2026-07-06 — **NOT MET** vs Ghostty (dense_cells 15 vs 8 ms, scrolling 69 vs 20 ms, unicode 9 vs 8 ms); gap analysis queued in Future work |
| 6 | pixel goldens ≤ 1 LSB vs GL reference | PARTIAL (characterized) | Cross-backend capture landed (.omc/verify/phase7/xbackend_golden.py, occlusion-immune; Metal via DUMP — the Metal thumbnail read is racy, a known pre-existing screenshot-path issue — GL via thumbnail): same scene visually, backgrounds and sampled solid interiors byte-identical, but glyph/edge composition differs up to 89/255 on ~12% of pixels (delta spectrum 1→89, ink-mask flicker 4% at thr=8; a black-vs-33 sample rules out a pure transfer-function mismatch). Root-cause (text composition/AA curve vs subpixel placement) queued as follow-up; not adjudicable as ≤1 LSB today and not yet documented as a deliberate policy exception |
| 7 | idle: blink-only presents, CPU < 0.3%, link paused | **PASS (formal)** | 60 s focused-idle capture: CPU 0.0% mean and max, presents beyond blink = 0 |
| 8 | stability: suites, DEBUG_LAYER, 10-min flood soak RSS < 5% | **PASS** | 10-min visible churn soak: RSS +0.35% (117.9→118.3 MB), 35,248 presents at 16.67 ms median cadence, 4 frames > 2× median in 35 k (none alloc-attributable; max interval is the teardown artifact), LOAD-DEGRADED noted |
| 9 | energy ≤ GL baseline | BLOCKED | powermetrics (operator sudo) + visibility |
| 10 | 1-line edit ≤ 8 KB | PASS | D2: ≈ 2.2 KB/frame typing capture |

## Future work (consolidated queue)

1. ~~Lock-free SPSC IO→parser handoff~~ — **DONE in Phase 12**
   (dense_cells 15 → 11 ms, `__benchmark__` ascii +69% / unicode +54%,
   scrolling 39 → 35 ms, psynch waits 9.3% → 0.0%, pacing unchanged).
2. ~~Dedicated parser/reader thread (Design 1)~~ — **NO-GO / DEFER**
   (Phase-11 audit): behavior-identity is UNPROVABLE — the decisive
   parse/render races (dirty-flag lost update, torn rows, grman
   dual-writer) are invisible to the converged-state harness, and the
   change relocates the lock cost onto the GIL. Revisit only after a
   deterministic intermediate-frame differential harness exists. (The
   render-thread split variant is separately DEAD: ≤0.6% devlog / ≤0.4%
   scrolling, Phase-9 gate.)
3. **Off-thread image decode = async image-load QUEUE** (Phase-11 audit,
   P11-2-DECODE-DESIGN.md) — removes the main-thread HITCH during a large
   decode (and plausibly the icat wall, since icat is quiet=2 and does
   not wait on any response). Requires an in-flight-load queue +
   out-of-band error protocol + placement ordering + delete-during-decode
   safety (a graphics-subsystem state-machine rewrite) — its own phase.
   SEPARATELY, what moves the icat WALL specifically is a **faster decode**
   (libdeflate / SIMD PNG unfilter) — decode speed, not decode location.
4. **utf8 decoder NEON kernel** — 0.96 GB/s today on Japanese, ~2.5–3×
   headroom via ESC-prescan + dedicated UTF-8→UTF-32 kernel (US-402b
   defer, numbers in P8-LEVERS.md).
5. **~~vtebench dense_cells~~ ATTRIBUTED** (Phase 11): it is the
   vt-parser lock contention above, not render or per-cell SGR cost —
   fixed by item 1. The recycled-row memset lazy-clear follow-up is
   COMPLETE as of Phase 15: hwm+L2 (O(1) finalize + consumer tail clip
   + S1-lite gap materialize) beats eager 0.66× on both scroll axes
   with dense no-harm and the interior-gap defect fixed. **DEFAULT
   FLIPPED 2026-07-07 (user-approved, commit 8545ca3d7)**: unset env →
   HWM + consumer clip; opt-outs `KITTY_ENABLE_HWM_CLEAR=0` /
   `KITTY_ENABLE_CONSUMER_TAIL_CLIP=0`; the
   `KITTY_DISABLE_LAZY_ROW_CLEAR` eager hatch still wins (=0 →
   relocate diagnostic). Verified at flip: both suites Ran 360
   baseline-green with the verify cross-check live, golden battery
   green in all four arms, default ≡ explicit hwm+L2 (19.2 ms/MiB) and
   the hatch reproduces eager's 28.0 exactly.
6. **Cross-backend composition difference** — §7 #6, tracked in
   .omc/.scratch/metal-gl-composition-diff/.
7. **icat-GIF animation failure** — pre-existing, all configs; tracked in
   .omc/.scratch/icat-gif-animation/.
8. **Keypress→photon latency capture** — needs the Accessibility grant
   (§7 #4); PTY proxy stands in meanwhile.
9. **Energy (powermetrics)** — operator sudo + a quiet machine (§7 #9;
   vtebench columns landed in Phase 8).

10. **L1 sync-on-immediate re-eval** — the mechanism is landed, proven
    reorder-safe, and opt-in (`KITTY_METAL_SYNC_IMMEDIATE=1`, Phase 13A);
    re-measure on a ProMotion/quiet machine, where the two async present
    hops are a larger fraction of the shorter frame budget (the 60 Hz
    verdict was "no reliable p99 win"). Also re-run the LOAD-BLOCKED
    absolutes (dense_cells ≤9 ms, flood p99=16.67 ms) on a quiesced box
    via `.omc/verify/wave13a/w13_vtebench_ab.py` / `w13_latency_ab.py`.
11. **pagerhist serialization cost (S5, documented)** —
    `scrollback_pager_history_size` defaults to 0: `alloc_pagerhist`
    returns NULL (history.c:64) and `pagerhist_push` early-returns
    (history.c:284), so the pager history is ZERO-cost on the default
    scroll path. When a user enables it, every ring eviction pays
    `line_as_ansi` + UTF-8 re-encode on the scroll hot path
    (history.c:282-296); lazy/batched serialization is the lever if that
    configuration ever becomes a target.
12. **~~Governor pacing decouple~~ DONE** (Phase 14): the 13B floor
    framing did not survive runtime confirmation (floor_blocked ≈ 0 in
    both arms; the immediate-encode path is off the flood critical
    path). The real pathology — an in-runloop pace link starved by the
    main thread, with the 250 ms fallback as the only (and no-op)
    re-arm — was fixed by the bounded-staleness stall-rescue
    (3d28473a6, default-ON, `KITTY_DISABLE_PACING_RESYNC` kill switch):
    gap_ge250 −96.6%, flood cap + idle + goldens intact. The bound
    sweep then proved the hwm scrolling regression pacing-INDEPENDENT →
    item 13.
13. **~~hwm frame-readiness residual~~ DONE** (Phase 15): the "47 ms
    render() quantum" framing dissolved on contact with the source —
    vtebench samples time PTY drain (no present-sync), so the residual
    was pure parse wall, named to the line-buf.c:470 finalize scan and
    removed (L1), then beaten outright by moving the clear to the
    render clip (L2, 0.66× eager) with the interior-gap defect found
    and fixed (S1-lite). The ≤26 ms target is met; the default flip
    awaits the user (item 5).
14. **~~Draw-path re-segmentation cost~~ MEASURED & REFUTED**
    (Phase 16): the bucket is diffuse (draw_text 43% /
    init_segmentation_state 31% / draw_control_char 26%, spreads ≤2%)
    and its components are per-OCCUPIED-CELL, not per-line — the
    re-segmentation premise inverted (the bench cost is a bare reset;
    real stepping only runs on wide/unicode content where it is
    correctness-required). Best available lever (the explicit-LF
    probe elision, provable via the next_char_was_wrapped invariant)
    bounds at ~1.5–3 ms/MiB eager-only — below action threshold,
    recorded in Phase 16 / STEP19-PREP-NOTES.md. The remaining
    scrolling cost lives in the clear/scroll path already solved by
    hwm+L2 — see item 5 (flipped 2026-07-07).
15. **~~Alt-screen/region-scroll pacing gap~~ REFUTED AS A LEVER
    FAMILY** (Phase 18): the decouple kill test deleted 100% of
    render/present/gate and moved the drain 0.0 ms on both target
    axes — the waiting-gate discriminator was a symptom (cheap no-op
    ticks; parse runs before render), not a cost; render had
    0.03–0.06 ms/MiB to reclaim against a ~20 ms/MiB wall. Prize ~0;
    main-screen parity untouched. The non-render residual (region
    +4 / vim +9 ms/MiB above the parse wall, surviving suppression)
    is re-attributed to the input_delay coalescing POLICY (Phase-8
    cross-ref: 6.0% of devlog = policy) and/or vtebench
    back-pressure measurement shape — recorded in Phase 18, NOT
    chartered (policy tradeoff / artifact, below threshold).

## Known deviations (tracked, intentional)

- Cell/graphics MSL shader *logic* is still the opus-era port; semantic drift
  against current GLSL (attr bit shifts, fg_override fix, bgimage preload) is
  Phase 3 (gates G2–G7 golden diffs).
- `presentsWithTransaction` live-resize sequencing landed in Phase 4/L1 (above);
  CVDisplayLink pacing is replaced by CAMetalDisplayLink on the Metal path (the
  CVDisplayLink code remains for the GL backend). L2/L3/L5 (immediate-encode,
  `sync_to_monitor`→`displaySyncEnabled`, adaptive `input_delay`, `pace=` tag)
  are the following Phase-4 task.

## Phase 22 (Wave 22): reader skeleton built and guarded; wakeup-economics gate NO-LAND — dormant default-OFF

Executed the consensus plan (`.omc/plans/ralplan-wave22-reader-skeleton.md`
v2, Option A: one product-code lane = the per-child reader-thread skeleton
behind `KITTY_READER_THREADS`, instrument-first ordering). Artifacts under
`.omc/verify/wave22/` — `R22-EVFILT-USER.md`, `R22-B2-RESTATEMENT.md`
(rev.2) + `R22-B2-REVIEW.md` (CONFIRMED-SOUND), `R22-GUARDS.md`,
`R22-OBLIGATIONS.md`, `GATE-ADJUDICATION.md`; ADR-0007. Commits
`9b3c2f024` (rd_* instrument + kill switch), `0b0c14ff6` (skeleton),
`e61ebd5a8` (M3.5 MAJOR-1 signal-tick re-arm).

**M0 (zero product code)**: EVFILT_USER PRIMARY CONFIRMED by an
out-of-tree micro-probe (cross-thread NOTE_TRIGGER wake; trigger-before-
wait retained; 50 stop→trigger→join→close cycles, zero blocked threads;
×2 runs) after the honest negatives were recorded (apple-docs does not
index kqueue BSD constants; this macOS ships no kevent man page and the
SDK kqueue.2 omits EVFILT_USER — authority = SDK `sys/event.h`). Pipe
fallback never activated; fd budget stayed 2/child.

**Skeleton (all 15 obligations O1–O15 traced in `R22-OBLIGATIONS.md`)**:
one reader/child (256 KiB stacks, "KittyReader"), kqueue avail-count drain
(CAP=64, no trailing EAGAIN probe), per-reader `OPT(input_delay)` batch
window + timed-kevent deferred flush, process-wide `main_wakeup_pending`
CAS with clear-before-drain + seq_cst bracketing per the proof-carrying
spec (drafted at M2 entry BEFORE the CAS code; review found 1 MAJOR — a
signal tick clears the flag while draining zero rings, fixed by an ON-arm
re-arm — plus 5 MINOR spec amendments; discharge CONFIRMED-SOUND), L5 echo
bypass preserved with per-reader totals, kt_* stamping migrated into the
reader epilogue, O15 unpark via children_mutex-held load+trigger with
retire-before-join (Critic condition 1 conforming shape; exercised at
runtime: rd_park_cycles 4045 > 0 across 150 teardowns).

**Guards (final binary, all green)**: goldens 4/4 max_diff=0 unset AND ON;
idle 0.0% 8/8 both arms; busy-spin (idle reader: rd_kevent_wakeups=0,
rd_wake_timer=0); teardown battery 50×3 windows EOF-byte-exact and
leak-free; kill-switch demo (OFF ticks: all rd_* frozen at 0); unit tests
arm-parity (2 pre-existing zsh-environment errors reproduce at pre-wave
HEAD); **OFF-arm cost 0.9825 ≤ 1.02** on interleaved dense_cells ftrace
parse_ms/MiB medians vs the preserved pre-skeleton binary (Critic
condition 2 statistic) — the dead-when-off claim holds, no revert.

**Gate (P2.SKEL)**: **NO-LAND** — discrimination clause live (baseline
reads/wakeup 1.0 < 2; baseline 90.5k/62.4k io_polls/s recorded), then t1
MB/s 1.2217× dense (miss) / 1.4979× unicode; t2 arm wakeups/s 1.1824×/
1.4239× vs the ≤0.5× target; t3 reads/wakeup 1.0 vs ≥2. Attribution via
the pinned cause decomposition: 99.97% rd_wake_data, parks 0 (dense) — the
C-speed parser (~5.6 ms/MiB ≈ 180 MB/s) outruns the ~91–176 MB/s PTY, so
backpressure never arises and kernel queue depth stays ≈1 quantum: both
named reduction mechanisms never engage, and no in-design parameter moves
data-cause wakeups (ITERATE declined as futile within the band's own
terms). Context recorded, never gate inputs: the io thread went idle
(io_polls ≈2/5 s vs 90k/s) and main-loop wakeups coalesced to ≈398 reads
per wakeup — but the gate was deliberately pinned to the PTY-servicing-
thread counter (F4-RESIDUAL) and is not re-pinned post hoc. S2 re-check
ran through the migrated instrument (120/120 paired; kt_l5_miss 0/120 on
the per-reader denominator; S2 p50 9.81 ms — annotation only).
Disposition: **switch-dormant default-OFF skeleton stays in-tree**; full
revert not triggered. 60 Hz single machine; same-block arithmetic only; no
victory language — the wakeup-economics prize, as pinned, is refuted at
product scale on these workloads.

## Phase 23 (Wave 23): inherited-maintenance lane landed; wakeup-economics family CLOSED by the parks probe

Executed the consensus plan (`.omc/plans/ralplan-wave23-maintenance-and-parks-probe.md`
v3.1, both recorded conditions honored). Artifacts under
`.omc/verify/wave23/` — `R23-SIGTICK-VERIFICATION.md`, `R23-GUARDS.md`,
`W23-ADJUDICATION.md`; ADR-0008. Commits `4ed24e8c2` (F-A),
`9c54fde7e` (F-B), `f35689f45` (F-C).

**Maintenance lane (three independent commits, kitty/child-monitor.c)**:
F-A widens the W22 signal-tick re-arm to the legacy arm (Metal build;
probe evidence: 100 phase-scanned reload signals under ring-full flood
could not reach the stall end-to-end — the io thread's signal-delivery
pass re-arms its own wakeup chain — so the fix lands on the
pre-registered mechanism-identity floor with severity revised DOWN, not
as a demonstrated user-visible stall). F-B replaces the upstream
`revents && POLLIN` logical-AND on the wakeup/signal fd branches with
the explicit `& (POLLIN|POLLHUP|POLLERR)` superset (behavior-identical
on reachable events; upstream-reportable). F-C adds the test-only
KITTY_READER_SPAWN_FAIL injection lever, converting the W22 F1
fallback-unpark leg from inspection-verified to battery-verified
(25/25 flood cycles: parks present, EOF byte-exact, zero leaks).

**Measurement lane — parks probe (zero product code): FAMILY-CLOSED.**
Three concurrent sync_medium_cells windows constructed exactly the
consumer-bottleneck regime the W22 NO-LAND attribution said the reader
design's mechanisms needed (P1: sustained 74 parks/s, live unparks,
every round) — and the reader arm STILL generated 1.643x the
PTY-servicing wakeups of the io-thread baseline (1.579x per MiB),
with throughput parity (1.0405x). The wakeup-reduction mechanisms
engage and do not pay on this machine's PTY quantum physics. Per the
pre-registered bands the wakeup-economics family is closed absent new
evidence; the dormant KITTY_READER_THREADS skeleton stays in-tree
(guards all green, OFF-arm cost 0.9828 <= 1.02 vs pre-W23).

**Verification-integrity findings (recorded for future waves)**: the
live fast_data_types.so was found silently reverted to a pre-W23 build
mid-wave (caught by the per-row live-sha256 discipline the W23 plan
carried; every affected block re-run on the verified binary with
identical verdicts); test.py REBUILDS fast_data_types.so with its own
flags, so any measurement after a test run must rebuild+hash-verify;
builds are bit-deterministic per source+flags (hash = identity); the
W22 absolute idle bar (0.0% x8) is unattainable on this machine as of
2026-07-11 (a real ~1.2% cputime drift affecting pre-W23 binaries
equally — idle guard moved to a four-cell parity form, ratios <= 1.10);
the ON-arm ssh test failure was root-caused to a pre-existing ssh-kitten
KITTY_* env-forwarding sensitivity (KITTY_FOO_THREADS=1 fails
identically; FOO_READER_THREADS=1 passes). 60 Hz single machine.
