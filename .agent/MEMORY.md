# Metal Renderer Knowledge Base (Updated 2025-10-22)

This document is the ground-truth reference for the macOS Metal migration. Overwrite it entirely whenever the state of the project changes in a meaningful way.

---

## Current Platform & Build Status

- Builds succeed on macOS via `python3.13 setup.py build`. The build system automatically links `PythonT.framework` when `Py_GIL_DISABLED` headers are detected (`kitty/python_build_helpers.py`, consumed by `setup.py:get_python_flags`).
- Metal shader interface structs (`MetalTrailUniforms`, `MetalGraphicsUniforms`, `MetalGraphicsAlphaUniforms`) are layout-validated across Objective‑C and MSL.
- Rendering passes (background, tab bar, window cells, graphics overlays, visual bell, scrollbar, hyperlink highlights, window numbers) execute entirely through the Metal backend with shared state cached per window.
- Background rendering is now backend-neutral: OpenGL texture IDs are no longer required on macOS. Detection uses `background_image_ready()` (Metal texture pointer or GL id), and the Metal backend manages uploads through `metal_background_image_uploaded`.
- Added regression coverage (`kitty_tests.test_metal_background.TestMetalBackgroundUpload`) that ensures Metal background uploads succeed even when `texture_id == 0`.
- Metallib artifacts (`kitty/metal/cell.metallib`) are now generated automatically by `setup.py`'s `compile_metal_shaders`; stale or missing outputs cause the build to abort with a clear failure message.
- `metal_renderer_preflight()` now checks for the packaged `cell.metallib` and reports a descriptive failure when the artifact is missing, ensuring fallback logic actually triggers.
- The build now links against `Python.framework` when `Py_GIL_DISABLED` reports false, preventing the previous `python3.13` unittest segfaults. Kitty’s bundled test runner is stable again on the local toolchain.
- All Metal-focused Python suites (`test_metal_background`, `test_metal_geometry`, `test_metal_resources`, `test_metal_helpers`, `test_metal_fallback`) execute successfully under `./.venv/bin/python3.13 test.py`.

---

## Implementation Snapshot

- Renderer backend registration is two-path (OpenGL + Metal). macOS defaults obey `metal_renderer = auto|metal|opengl`, with CAMetalLayer creation handled in `metal_backend_attach_window`.
- Metal state hoists per-window buffers (cell, selection, uniform, border), sprite atlases, and capture buffers with explicit teardown in `destroy_window_state`.
- Sprite uploads and window logos use Metal textures through the shared graphics texture table; background image uploads mirror this flow.
- Shared renderer utilities (`renderer_shared_prepare_frame`, scrollbar metrics, glyph caches) are fully consumed by the Metal backend.

---

## Immediate Roadmap (highest priority first)

1. **Metallib Build Enforcement (DONE 2025-10-22)**
   - `compile_metal_shaders` now invokes `xcrun metal` / `xcrun metallib`, copies outputs into `kitty/metal/`, and raises on stale or failed builds.
   - Follow-up: surface the new failure mode in CI logs (no code work pending here).

2. **Stabilize Test Execution (DONE 2025-10-22)**
   - Updated Python linking logic to respect disabled-GIL toolchains without forcing `PythonT.framework`; unittest runner no longer crashes.
   - Restored Metal helper exports (`renderer_shared_visual_bell_alpha_scale_for_tests` et al.) so `kitty_tests/test_metal_helpers` runs end-to-end.
   - Verified all Metal test modules via `./.venv/bin/python3.13 test.py --module test_metal_*`.

3. **Capture & Teardown Audit**
   - Verify `metal_capture_framebuffer`, `metal_finalize_capture`, and shutdown paths release command buffers, textures, and copied pixel buffers in all edge cases (resize, layer loss, capture cancellation).
   - Confirm `metal_backend_shutdown` cleans sprite atlases, background resources, and global caches without leaking autoreleased state.

4. **Windowing & Resize Parity**
   - Double-check CAMetalLayer configuration (`contentsScale`, `drawableSize`, `displaySyncEnabled`) against macOS resize/content-scale notifications.
   - Validate that live-resize and layer-shell paths preserve swapchain integrity and avoid redundant buffer churn.

5. **Documentation & Onboarding**
   - Update developer docs to call out: required toolchain (macOS 13+, Xcode CLI tools, `python3.13`), Metal build pipeline, and known runtime limitations (unittest crash, helper suite skip).
   - Document Metal debugging toggles, profiling hooks, and fallback behavior for operators.

---

## Short-to-Medium Term Backlog

- Integrate metallib compilation into CI (Apple Silicon + Intel runners) and cache artifacts for test reuse.
- Expand acceptance testing with image-diff comparisons between OpenGL and Metal to guard against visual regressions.
- Provide Metal-specific logging and GPU capture toggles analogous to existing OpenGL debug flags.
- Finalize fallback logic: when Metal initialization fails, confirm graceful downgrade to OpenGL and add negative tests.
- Review sprite-atlas growth policies and buffer eviction to ensure parity with OpenGL’s GPU memory management.

---

## Testing Strategy

- **Unit / Component Tests**: Metal helper suite is active again; extend it with additional coverage for sampler caches, geometry helpers, capture flows, and font sprite hooks.
- **Integration**: Continue running the Metal modules (`test_metal_background`, `test_metal_geometry`, `test_metal_resources`, `test_metal_helpers`, `test_metal_fallback`) under `./.venv/bin/python3.13 test.py` and track results in CI artifacts.
- **Manual QA**: Exercise macOS live-resize, background image toggles, window logo rendering, capture workflows, and fallback selection.
- **Regression Monitoring**: Track metallib timestamps and include them in release builds to prevent stale shader binaries.

---

## Tooling & Dependencies

- macOS 13 or newer with Metal-supported GPU.
- Xcode Command Line Tools (`xcrun metal`, `xcrun metallib`).
- Python 3.13 (pending interpreter stability fixes for unittest execution).
- Go toolchain 1.24+ (unchanged), clang/LLVM for C/C++ components.

---

Keep this file synchronized with reality. The next engineer should be able to pick up Metal work using the information captured here without spelunking elsewhere.***
