# Metal Renderer Knowledge Base (Updated 2025-10-22)

This document is the ground-truth reference for the macOS Metal migration. Overwrite it entirely whenever the state of the project changes in a meaningful way.

---

## Current Platform & Build Status

- Builds succeed on macOS via `python3.13 setup.py build`. The build system automatically links `PythonT.framework` when `Py_GIL_DISABLED` headers are detected (`kitty/python_build_helpers.py`, consumed by `setup.py:get_python_flags`).
- Metal shader interface structs (`MetalTrailUniforms`, `MetalGraphicsUniforms`, `MetalGraphicsAlphaUniforms`) are layout-validated across Objective‑C and MSL.
- Rendering passes (background, tab bar, window cells, graphics overlays, visual bell, scrollbar, hyperlink highlights, window numbers) execute entirely through the Metal backend with shared state cached per window.
- Background rendering is now backend-neutral: OpenGL texture IDs are no longer required on macOS. Detection uses `background_image_ready()` (Metal texture pointer or GL id), and the Metal backend manages uploads through `metal_background_image_uploaded`.
- Added regression coverage (`kitty_tests.test_metal_background.TestMetalBackgroundUpload`) that ensures Metal background uploads succeed even when `texture_id == 0`.
- Metallib artifacts (`kitty/metal/cell.metallib`) are still produced manually using `xcrun metal` + `xcrun metallib`; automation remains outstanding.
- The local `python3.13` interpreter segfaults when running the bundled unittest runner (`python3.13 -m unittest ...`). Use an alternate runtime/container for automated test execution until the crash is resolved.
- `kitty_tests/test_metal_helpers` is still skipped because it assumes the OpenGL shared object. The Metal backend now provides the required symbols; the suite needs an updated loader plus a stable interpreter.

---

## Implementation Snapshot

- Renderer backend registration is two-path (OpenGL + Metal). macOS defaults obey `metal_renderer = auto|metal|opengl`, with CAMetalLayer creation handled in `metal_backend_attach_window`.
- Metal state hoists per-window buffers (cell, selection, uniform, border), sprite atlases, and capture buffers with explicit teardown in `destroy_window_state`.
- Sprite uploads and window logos use Metal textures through the shared graphics texture table; background image uploads mirror this flow.
- Shared renderer utilities (`renderer_shared_prepare_frame`, scrollbar metrics, glyph caches) are fully consumed by the Metal backend.

---

## Immediate Roadmap (highest priority first)

1. **Automate Metallib Generation**
   - Extend `setup.py` to invoke `xcrun metal` / `xcrun metallib` when `.metal` sources change.
   - Emit clear failures when the packaged `kitty/metal/*.metallib` is stale relative to source.
   - Ensure artifacts are copied into the Python package and app bundles.

2. **Stabilize Test Execution**
   - Re-run Metal suites inside a known-good interpreter (or container) to avoid the current macOS `python3.13` segfault.
   - Once stable, re-enable `kitty_tests/test_metal_helpers` and expand coverage for sampler caches, geometry helpers, capture flows, and font sprite hooks.
   - Integrate the new background upload regression into the standard continuous test set.

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

- **Unit / Component Tests**: Reactivate Metal helper tests once the segfault issue is mitigated. Ensure every exported helper (background uploads, sampler caches, capture routines) has direct coverage.
- **Integration**: Run targeted Metal test modules (`test_metal_background`, `test_metal_geometry`, `test_metal_resources`, `test_metal_helpers`) under a reliable interpreter. Record results in CI artifacts.
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
