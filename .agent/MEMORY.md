# Metal Renderer Execution Memory
_Last updated: 2025-10-18_

Canonical scratchpad capturing the authoritative state of the macOS Metal renderer bring-up. **Always overwrite this file** with the latest truth; do not append.

---

## Guardrails
1. Respect repo rules: no code duplication, no dead code, consistent naming, ASCII unless file already uses UTF-8.
2. Error handling: fail fast on renderer init/device/pipeline failures; log-and-continue for recoverable sprite/uniform reallocations; gracefully degrade to OpenGL when Metal preflight or resource acquisition fails.
3. Every new or refactored function ships with meaningful, non-cheating tests that exercise the real code path.
4. Keep GLSL↔MSL feature parity; when data structures change, update all backends and shaders in lockstep.
5. Prefer existing shared helpers (`renderer_shared_*`, font atlas utilities) before introducing new abstractions.

---

## Current Knowledge Snapshot (2025-10-18)
- **Renderer selection:** macOS auto-select still tries Metal first, falling back to OpenGL on preflight/init failure. `register_metal_renderer_backend` installs the Metal ops table; fallback path remains intact.
- **Global state:** `g_metal` retains device, queue, shader library, pipeline states (cells, borders, cursor trail), sampler, swap-interval flags. Display sync toggles via `set_display_sync_for_all_layers`.
- **Window state:** `MetalWindowState` owns `CAMetalLayer`, drawable/command buffer, cell/selection/uniform/border buffers, shared frame metadata, and background bookkeeping.
- **Viewport handling:** `metal_compute_viewport_params` passes geometry to the MSL vertex shader; Python tests cover its math once fast data types are rebuilt.
- **Rendering passes:** `metal_render_pass_for_render_data` mirrors OpenGL composition (tab bar + windows) via `renderer_shared_prepare_frame`, populates uniforms, encodes instanced draws when buffers are ready. Metal now renders window/tab borders and cursor trails using dedicated pipelines; graphics layers and screenshots are still pending.
- **Shaders:** `kitty/metal/cell.metal` now ships additional entry points `border_vertex/fragment` and `trail_vertex/fragment`, reusing the shared gamma LUT for color conversion.
- **Build pipeline:** `compile_metal_shaders` routes all `xcrun` invocations through `metal_tool_cmd`, ensuring both `metal` and `metallib` run with `--sdk macosx`. Any failure logs once and leaves OpenGL as the active backend.
- **Testing:** Added `kitty_tests/test_metal_helpers.py` to validate border and cursor trail uniform packing via the exported C helpers. Existing geometry/fallback tests still require rebuilt `fast_data_types` and a valid `cell.metallib`.
- **Packaging:** macOS packaging whitelists `.metallib`; compiled assets must be present in `kitty/metal/`. Rebuilds remain manual until CI gains a Metal-capable runner.
- **Toolchain:** Xcode 26.1 beta remains in use. With the SDK flag fix, `xcrun metallib` succeeds when the toolchain is consistent. If the `metallib` step fails, setup.py logs the failure and leaves the old artifacts untouched.

---

## Active Milestones

### Phase 1.1 – Stabilize Multi-Pass Metal Rendering (Ongoing)
- ✅ Shared viewport math helper + Python unit tests.
- ✅ Metal render loop splits tab bar/windows and streams shared buffers.
- ✅ `metal_tool_cmd` ensures deterministic `xcrun` invocations; build logs now highlight Metal failures without crashing setup.
- ✅ Implemented Metal border rendering with dedicated pipelines and shared buffer uploads.
- ✅ Implemented Metal cursor trail rendering (vertex/fragment programs + command encoder).
- ⏳ Rebuild `fast_data_types` against current Python toolchain and re-enable the Metal geometry/fallback tests.
- ⏳ Audit buffer lifetimes when windows close or resize rapidly (ensure no stale CAMetalLayer drawables).

### Phase 1.2 – Resource Packaging & Fallbacks (Next)
- ⏳ Produce reproducible `cell.metallib` via CI or documented local steps (note Xcode version requirements).
- ⏳ Document environment variables needed by developers to rebuild Metal assets (SDK path, `DEVELOPER_DIR`, etc.).

### Phase 2 – Graphics Layers & Screenshots (Pending)
- Reimplement graphics-layer rendering, window logos, tint overlays, and screenshot capture using Metal encoders and transient textures.
- Add GPU trace hooks (Metal equivalents of GL debug labels) gated by `RendererInitConfig.enable_debug_labels`.

---

## Open Issues / Risks
- **Feature gaps:** Graphics layers, window logos, tint passes, and screenshot capture remain absent on Metal.
- **Test coverage:** Rendering tests depend on compiled extensions and metallib artifacts; tooling is still brittle on fresh machines.
- **Toolchain variance:** Developers using non-standard Xcode paths must ensure `xcrun` resolves correctly; helper currently assumes default SDK names.
- **Performance unknowns:** No profiling yet comparing Metal vs OpenGL for large scrollback or image-heavy workloads.

---

## Next Actions
1. Regenerate `cell.metallib` with the fixed SDK invocation; confirm `setup.py build` emits no Metal warnings on macOS 13+ and that packaging picks up the artifact.
2. Rebuild `kitty/fast_data_types` (Python 3.13 target) and re-enable the Metal geometry/fallback tests to cover the shared buffer path.
3. Extend Metal backend to cover graphics layers (images/overlays) and window logos, reusing data produced by `renderer_shared_prepare_frame`.
4. Implement Metal screenshot path (`capture_framebuffer`), ensuring parity with OpenGL behavior.
5. Once rendering parity is closer, integrate Metal-specific logging/perf instrumentation and plan CI coverage with Metal-capable runners.
