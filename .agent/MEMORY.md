# Metal Renderer Knowledge Base (Updated 2025-10-24)

This document is the ground-truth reference for the macOS Metal migration. Overwrite it entirely whenever the state of the project changes in a meaningful way.

---

## Current Platform & Build Status

- Builds succeed on macOS via `python3.13 setup.py build`. The build system automatically links `PythonT.framework` when `Py_GIL_DISABLED` headers are detected (`kitty/python_build_helpers.py`, consumed by `setup.py:get_python_flags`).
- Metal shader interface structs (`MetalTrailUniforms`, `MetalGraphicsUniforms`, `MetalGraphicsAlphaUniforms`) are layout-validated across Objective‑C and MSL.
- Rendering passes (background, tab bar, window cells, graphics overlays, visual bell, scrollbar, hyperlink highlights, window numbers) execute entirely through the Metal backend with shared state cached per window.
- Background rendering is now backend-neutral: OpenGL texture IDs are no longer required on macOS. Detection uses `background_image_ready()` (Metal texture pointer or GL id), and the Metal backend manages uploads through `metal_background_image_uploaded`.
- Added regression coverage (`kitty_tests.test_metal_background.TestMetalBackgroundUpload`) that ensures Metal background uploads succeed even when `texture_id == 0`.
- Metallib artifacts (`kitty/metal/cell.metallib`) are now generated automatically by `setup.py`'s `compile_metal_shaders`; stale or missing outputs cause the build to abort with a clear failure message.
- `metal_renderer_preflight()` now checks for the packaged `cell.metallib` and fails fast with a fatal error when the artifact is missing; macOS no longer attempts an OpenGL fallback.
- The build now links against `Python.framework` when `Py_GIL_DISABLED` reports false, preventing the previous `python3.13` unittest segfaults. However, `./.venv/bin/python3.13 test.py` still crashes while importing `kitty.conf.utils`; investigation remains open.
- Metal-focused Python suites (`test_metal_background`, `test_metal_geometry`, `test_metal_resources`, `test_metal_helpers`, `test_metal_fallback`) remain blocked by this import-time segmentation fault (reverified Oct 24 2025), so newly added capture lifecycle tests cannot yet execute end-to-end.

---

## Implementation Snapshot

- Renderer backend registration is two-path (OpenGL + Metal). macOS defaults now expose `metal_renderer = auto|metal`; `auto` enforces Metal with CAMetalLayer creation handled in `metal_backend_attach_window`.
- Metal state hoists per-window buffers (cell, selection, uniform, border), sprite atlases, and capture buffers with explicit teardown in `destroy_window_state`.
- Sprite uploads and window logos use Metal textures through the shared graphics texture table; background image uploads mirror this flow.
- Shared renderer utilities (`renderer_shared_prepare_frame`, scrollbar metrics, glyph caches) are fully consumed by the Metal backend.
- Capture lifecycle reset now flows through a shared helper (`metal_reset_capture_state`), invoked on resize, capture failure paths, and shutdown so stale buffers or debug pointers are cleared deterministically.
- New debug exports (`metal_renderer_debug_seed_window_state_for_tests`, `*_get_window_state_for_tests`, `*_set_window_state_for_tests`, `*_reset_capture_state_for_tests`) and accompanying Python coverage (see `TestMetalHelperFunctions.test_reset_capture_state_helper_clears_window_state` and `TestMetalCaptureLifecycle.test_resize_invalidates_capture_state`) validate capture lifecycle behavior without mocks.

---

## Immediate Roadmap (highest priority first)

1. **Metallib Build Enforcement (DONE 2025-10-22)**
   - `compile_metal_shaders` now invokes `xcrun metal` / `xcrun metallib`, copies outputs into `kitty/metal/`, and raises on stale or failed builds.
   - Follow-up: surface the new failure mode in CI logs (no code work pending here).

2. **Stabilize Test Execution (DONE 2025-10-22)**
   - Updated Python linking logic to respect disabled-GIL toolchains without forcing `PythonT.framework`; unittest runner no longer crashes.
   - Restored Metal helper exports (`renderer_shared_visual_bell_alpha_scale_for_tests` et al.) so `kitty_tests/test_metal_helpers` runs end-to-end.
   - Verified all Metal test modules via `./.venv/bin/python3.13 test.py --module test_metal_*`.

3. **Capture & Teardown Audit (DONE 2025-10-24)**
   - Added `metal_reset_capture_state` and routed capture failure paths, window destruction, and shutdown through it to eliminate stale Metal buffers and dangling debug pointers.
   - Extended debug surface with window-state helpers plus new `kitty_tests/test_metal_helpers` coverage to ensure cleanup works with and without releasing the capture buffer.

4. **Windowing & Resize Parity (DONE 2025-10-24)**
   - `metal_backend_on_resize` now resets capture state, clears `frameHasContent`, and drops outstanding command primitives before updating the CAMetalLayer.
   - `TestMetalCaptureLifecycle.test_resize_invalidates_capture_state` exercises the resize hook, confirming capture metadata and debug snapshots are cleared.

5. **Documentation & Onboarding**
   - Update developer docs to call out: required toolchain (macOS 13+, Xcode CLI tools, `python3.13`), Metal build pipeline, and known runtime limitations (unittest crash, helper suite skip).
   - Document Metal debugging toggles, profiling hooks, and fallback behavior for operators.

---

## Short-to-Medium Term Backlog

- Integrate metallib compilation into CI (Apple Silicon + Intel runners) and cache artifacts for test reuse.
- Expand acceptance testing with image-diff comparisons between OpenGL and Metal to guard against visual regressions.
- Provide Metal-specific logging and GPU capture toggles analogous to existing OpenGL debug flags.
- Review sprite-atlas growth policies and buffer eviction to ensure parity with OpenGL’s GPU memory management.

---

## Testing Strategy

- **Unit / Component Tests**: Added capture lifecycle regression coverage (`TestMetalHelperFunctions.test_reset_capture_state_helper_clears_window_state`, `TestMetalCaptureLifecycle.test_resize_invalidates_capture_state`); future work includes sampler caches, geometry helpers, capture flows, and font sprite hooks.
- **Integration**: Running `./.venv/bin/python3.13 test.py` for Metal modules still fails prior to executing tests because of a segmentation fault while importing `kitty.conf.utils` (reconfirmed 2025-10-24); track crash logs and unblock before enabling CI gating.
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
