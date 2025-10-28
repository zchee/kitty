# Metal Migration Knowledge Base (Updated 2025-10-28)

Authoritative snapshot of the Metal renderer status, helper exports, diagnostics, and remaining work. Update immediately after any functional or planning change.

---

## Platform Policy
- macOS builds ship **Metal-only** (`KITTY_DISABLE_NSGL=1`, no OpenGL frameworks). Selecting `opengl` on macOS must raise `ValueError`; negative tests live in `kitty_tests/renderer_backend.py`.
- Non-macOS builds still expose both backends; Metal-only expectations remain skip-guarded outside Darwin.

---

## Current Implementation Highlights
1. **Unified Tint Uniforms**
   - `MetalTintUniforms` struct shared via `kitty/metal_renderer.h`.
   - `metal_make_tint_uniforms()` + `metal_renderer_prepare_tint_uniforms_for_tests()` clamp tint, convert sRGB→linear, premultiply alpha, and return deterministic data.

2. **Background Capture Harness**
   - `TestMetalBackgroundTintRendering` creates an actual OS window, attaches the Metal backend, renders a tinted background, and captures the framebuffer.
   - Uses `_solid_rgba_png()` to feed deterministic pixels; cleanup clears background image and removes the OS window.
   - Requires native helpers: `handle_for_window_id()`, `get_os_window_struct_for_tests()`, `state_debug_add_os_window_for_tests()`, `renderer_backend_attach_window()`, `renderer_backend_begin_frame()`, `renderer_backend_render()`, `renderer_backend_present()`, `renderer_backend_shutdown_active()`, `metal_renderer_copy_captured_frame_for_tests()`.
   - Runs `NSApplicationLoad`, checks `metal_renderer_preflight()`, and gracefully skips if any stage fails or the framebuffer is empty.
   - Opt-in via `KITTY_ENABLE_METAL_GUI_TESTS=1`; without a live GUI session the test skips instead of crashing.
   - When enabled, diagnostics now iterate multiple background colors and tint strengths, verifying that captured pixels move toward the expected dominant channel with monotonic channel reductions.

3. **State Exposure for Tests**
   - Native exports (`kitty/state.c` + `state.h`): `handle_for_window_id(id_type)` and `get_os_window_struct_for_tests(id_type)` return raw Cocoa handle / `OSWindow*` without Python wrappers.
   - `kitty_tests/renderer_backend.py` `BackendFFI` defines window config structs and function signatures for the Metal debug helpers.

4. **Helper Suite Coverage**
   - `TestMetalHelperFunctions` covers border, trail, tint uniform math (strict sRGB→linear assertions), graphics uniform packing, visual bell alpha scaling, and ensures Metal paths never allocate OpenGL VAOs.
   - Runtime debug helpers expose `display_sync_enabled` for parity checks.

---

## Test Coverage Expectations
- `kitty_tests/test_metal_helpers.py`
  - Must stay deterministic; avoid real GUI dependencies except for `TestMetalBackgroundTintRendering` (handled via skip guards).
  - New multi-background, multi-tint capture assertions check channel deltas and enforce monotonic behaviour.
- `kitty_tests/renderer_backend.py`
  - Validates backend registration, Metal preflight, and macOS OpenGL fail-fast behaviour; updated ctypes bindings must remain in sync with native exports.
- `kitty_tests/test_metal_background.py`, `test_metal_resources.py`
  - Continue to cover background geometry math and metallib presence.
- Rule: every new Metal export or helper requires direct unit coverage; “cheater” tests are forbidden.

---

## Operational Checklist
1. Rebuild native artifacts with `./.venv/bin/python3.13 setup.py build` after touching C/ObjC sources.
2. Run `./test.py --module test_metal_helpers` after Metal changes.
3. For GUI capture tests:
   - Ensure macOS GUI session (physical log-in, Screen Sharing, or GUI CI runner).
   - Export `KITTY_ENABLE_METAL_GUI_TESTS=1` before invoking the suite.
4. When adding Metal exports:
   - Declare in `metal_renderer.h`.
   - Implement in `metal_renderer.m` with full error checks and cleanup.
   - Expose via `kitty/state.c` (or relevant module) and type in `fast_data_types.pyi`.
   - Extend helper tests deterministically.
   - Update this memory file.

---

## Immediate Roadmap (Metal Migration)
1. **Capture Verification on Hardware**
   - On a GUI-enabled macOS host, run `KITTY_ENABLE_METAL_GUI_TESTS=1 ./test.py --module test_metal_helpers`.
   - Record per-background/tint pixel tuples produced by `_render_and_capture_pixel` for regression tracking.
   - Confirm dominant-channel assertions hold on real hardware; adjust tolerances if necessary.
2. **Baseline Consolidation**
   - Archive captured pixel baselines (prefer JSON fixture) once validated; integrate regression comparison into the test to detect future drift.
3. **Future Diagnostics Enhancements**
   - Once raw float tint data is exposed beyond helper tests, replace per-channel int assertions with float comparisons to remove reliance on PNG preload.

---

## Backlog (Post-Phase)
- Build image-diff harness comparing archived OpenGL frames with Metal renders.
- Implement remote-control toggles for Metal debug flags (parity with GL tooling).
- Provision Metal-capable CI runners and cache metallib outputs for faster builds.
- Extend automated capture coverage to cursor trails, window logos, and other graphical elements.
- Develop sprite atlas stress tests once deterministic fixtures are available.

---

## Reference Assets
- Architecture: `docs/metal_renderer_architecture.md`.
- Official Metal docs (Objective-C): scrape with `firecrawl` at <https://developer.apple.com/documentation/metal?language=objc>.
- Apple sample: `/Users/zchee/src/github.com/zchee/apple-metal-samples/MigratingOpenGLCodeToMetal`.
- Always run tooling with `.venv/bin/python3.13`.

---

## Notes for Future Iterations
- Update `BackendFFI` a single time per new native helper; reuse shared structs/functions across tests.
- Prefer POD structs when exposing additional state to Python for deterministic layout.
- Maintain naming parity between C exports and Python wrappers to satisfy mypy.
- Keep this file comprehensive yet concise—document every active helper, associated tests, and pending action items to avoid rediscovery.
