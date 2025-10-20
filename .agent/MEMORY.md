# Metal Renderer Execution Memory  
_Last updated: 2025-10-20 (Investigation stalled pending cell pipeline refactor)_

Working scratchpad for the macOS Metal backend effort. Keep this authoritative so future sessions avoid repeating discovery.

---

## Guardrails & Principles
1. **Parity remains non-negotiable** – the Metal backend must match OpenGL output ordering (cells, inline graphics, overlays) before enabling by default.
2. **Renderer-shared first** – continue sourcing geometry, colour, and layering data exclusively from `renderer_shared` helpers; no ad-hoc recomputation in Metal.
3. **Fail-fast fallback** – any Metal init or encode error must drop back to OpenGL cleanly without leaking state.
4. **Single metallib truth** – regenerate `cell.metallib` when shader sources change; never hand-edit compiled blobs.
5. **Per-function tests** – each exported symbol touched by Metal must gain explicit ctypes coverage; avoid mock services.
6. **Resource hygiene** – pair allocations (textures, buffers, observers, command buffers, samplers) with deterministic teardown.
7. **Structured logging** – keep noisy logging behind debug flags so field telemetry stays actionable.

---

## Current Snapshot
- ✅ **Texture upload plumbing is in place**
  - `metal_backend_upload_graphics_image` / `destroy_graphics_image` work and are covered by ctypes tests.
  - Graphics textures cached via `MetalGraphicsTexture` keyed by `TextureRef.id`; samplers memoised by (filter, repeat).
  - Debug hook `metal_renderer_debug_get_graphics_texture` reports texture/sampler state for tests.
- ⚠️ **Inline graphics rendering is still missing**
  - Metal ignores `RendererSharedFrameResult.graphics_data_changed`; no encoder exists for `GraphicsRenderData`.
  - Layer ordering (below / negative / positive) cannot be honoured yet because Metal uses a single cell pass.
  - Alpha-mask and premultiplied quads lack shader/pipeline support.
- ⚠️ **Metal cell pipeline is monolithic**
  - `metal_encode_cells` combines background + foreground drawing. Unlike OpenGL’s BG/FG split, there’s no hook to insert inline graphics between phases.
  - Achieving parity requires either splitting the Metal pipeline or reworking the shader to composite images internally.
- ⚠️ **Scrollbars/overlays parity still open**
  - Background tint, borders, and cursor trail encode paths exist; scrollbar, hyperlink target, visual bell, window number parity still pending.
- ⚠️ **Build/test gaps**
  - Metallib rebuild automation not wired into `setup.py` yet.
  - Renderer backend tests crash on non-macOS hosts; Metal validation requires macOS + GPU hardware.

---

## Key Investigations (2025-10-20)
1. **OpenGL layering audit**
   - `draw_cells_with_layers` sequences: background tint → optional window logo → `GraphicsRenderData` buckets (below, negative) → remaining cell passes → positive overlays → visual bell → scrollbar → hyperlink target → window number.
   - Requires three shader variants: straight-alpha (`GRAPHICS_PROGRAM`), premultiplied (`GRAPHICS_PREMULT_PROGRAM`), alpha-mask (`GRAPHICS_ALPHA_MASK_PROGRAM`).
2. **Metal backend trace**
   - `metal_render_pass_for_render_data` preps buffers via `renderer_shared_prepare_frame`, but only uses the result for cells.
   - `state.sharedFrame` currently unused post-prepare; no path consumes graphics data.
   - `metal_ensure_resources` already initialises overlay/tint/alpha pipelines; new graphics pipelines can piggyback here once shader coverage exists.
3. **Blocker confirmation**
   - To interleave inline graphics we must either:
     a. Split Metal rendering into BG/FG passes analogous to OpenGL, or  
     b. Augment the cell shader to composite inline quads, which is complex and risks performance regressions.
   - Without that refactor, Metal cannot respect the required draw order.

---

## Immediate Guidance for Next Session
1. **Decide on pipeline strategy**
   - Secure approval to refactor Metal rendering into multiple passes (preferred for parity) *or* agree on interim scope (e.g., support only positive overlays with known visual compromises).
2. **Prototype cell pass split**
   - Sketch how to reuse current vertex buffers across BG and FG passes; confirm buffer binding reuse.
   - Evaluate command-buffer overhead when issuing multiple render encoders per frame.
3. **Outline shader deliverables**
   - Identify required MSL entry points mirroring `graphics_vertex/fragment` variants.
   - Determine uniform structures (src/dest rects, extra alpha, premult flag).
4. **Plan testing path**
   - Define macOS-only ctypes tests to validate draw order once implemented.
   - Ensure tests guard fallback to OpenGL when Metal fails to initialise.

Until Step 1 (pipeline strategy) is resolved, do **not** implement graphics encoding; doing so would be wasted effort.

---

## Staged Roadmap (On Hold pending pipeline refactor approval)
1. **Cell pipeline restructure**
   - Split Metal draw into BG + FG passes or design shader extension that allows injecting inline quads while preserving batching.
   - Update `MetalDrawParams` and encoder flow accordingly.
2. **Graphics pipeline enablement**
   - Add MSL programs + pipeline states for straight-alpha, premult, and alpha-mask.
   - Implement uniform packing helpers for src/dest rects and colours.
   - Encode `GraphicsRenderData` buckets respecting below/negative/positive order.
3. **Overlay parity**
   - Port scrollbar, hyperlink target, visual bell, window number logic.
   - Ensure renderer_shared outputs are consumed identically to OpenGL.
4. **Build & tooling**
   - Automate metallib rebuilds; bundle artifacts in app/wheel packaging.
   - Add runtime metallib compatibility checks.
5. **Validation**
   - Expand ctypes coverage; add macOS gating for Metal-specific tests.
   - Plan long-term visual diff harness comparing Metal vs OpenGL captures.

---

## Risks & Mitigations
- **Architectural gap:** Single-pass Metal pipeline blocks inline graphics.  
  _Mitigation:_ Prioritise pass split design review before further implementation.
- **Testing infrastructure:** No automated Metal CI.  
  _Mitigation:_ Mark Metal-only tests and document manual run steps.
- **Metallib drift:** Manual rebuild easy to miss.  
  _Mitigation:_ Wire into `setup.py` once shader work resumes.

---

## Update Triggers
Revise this memo when:
- Pipeline refactor plan is approved or implemented.
- New Metal shaders/pipelines land.
- Metallib build integration changes.
- Additional overlays achieve parity.
- Testing strategy evolves (e.g., new macOS CI coverage).
