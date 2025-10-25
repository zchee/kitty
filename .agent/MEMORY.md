# Renderer & Backend Knowledge Base (Updated 2025-10-25)

Authoritative snapshot of the macOS Metal migration state, OpenGL stubs, and validation expectations. Refresh this file whenever behavior or test intent changes.

---

## Platform & Backend Policy

- **macOS (Darwin) is Metal-only.** Build scripts set `KITTY_DISABLE_NSGL=1`, drop `-framework OpenGL`, and only ship the Metal backend. The OpenGL API surface remains available as stubs for non-macOS platforms and for tests that assert failure paths.
- Registering or selecting the OpenGL backend on macOS must fail cleanly. `renderer_backend_select("opengl")` returns `False` and exposes the reason via `opengl_renderer_disabled_reason()`. Tests cover these expectations.
- Non-macOS builds continue to provide the full OpenGL backend; cross-platform behavior is verified by existing suites.

---

## Current Implementation Highlights (Metal Phase 2.1)

1. **Drawable clearing path**  
   - `metal_renderer_blank_drawable()` performs CAMetalLayer clears via `encode_clear_pass()` and is used by `blank_os_window()` whenever the active backend is Metal.  
   - A debug stub is available through `metal_renderer_debug_enable_blank_stub_for_tests(bool)` so unit tests can validate state mutation without creating real windows.

2. **Shared shader metadata**  
   - `kitty/shader_shared.h` remains the single source of shader constants. Both the Metal module and the OpenGL stubs consume it to guarantee parity.

3. **Metal background & sprites**  
   - Background image uploads populate Metal textures with retry semantics if the device is unavailable at load time.  
   - Sprite atlas management mirrors the OpenGL flow; hooks are registered only when the Metal backend is initialized.

4. **Debug & capture helpers**  
   - Tests interact with the renderer via `MetalWindowDebugState`, capture helpers, and the new blank-drawable stub to assert lifecycle invariants without mocks.

---

## Test Coverage Mandates

- `kitty_tests/test_metal_helpers.py` covers:  
  - Drawable blanking (new stub path).  
  - Capture lifecycle, uniform packing, and texture bookkeeping.  
  - Regression that Metal windows do not allocate OpenGL VAOs.  
- `kitty_tests/test_metal_background.py` validates geometry calculations and ensures Metal uploads do not depend on GL IDs.  
- `kitty_tests/test_metal_resources.py` verifies metallib presence and caching.
- When new Metal functions are added, extend the helper suite with deterministic assertions; do not depend on live windows or GUI state in CI.

---

## Known Gaps / Open Issues

1. **Manual verification still required**  
   - Automated tests cannot validate live CAMetalLayer behavior (e.g., window creation, live resize). Manual smoke tests on macOS must be part of release candidates.

2. **Sprite atlas parity**  
   - Growth/eviction logic mirrors the OpenGL path but still lacks stress tests for extreme resizing or font churn. Add targeted cases once profiler output is available.

3. **Visual-diff infrastructure**  
   - No automated comparison between historical OpenGL renders and current Metal output exists yet. Long-term goal remains to integrate a visual diff harness.

---

## Immediate Roadmap

1. **Manual smoke checklist for macOS (post-build)**  
   - Launch kitty, create multiple windows, trigger live resize, and observe clears.  
   - Enable `--debug-metal --metal-gpu-capture` to confirm command submission and capture toggles work.

2. **Extend regression coverage**  
   - Add integration that exercises background tinting and layer rendering in Metal (currently only unit-level coverage).
   - Cover sprite atlas growth/eviction once deterministic data fixtures are available.

3. **Tooling hygiene**  
   - Ensure `setup.py` rebuilds metallibs when shaders change and fails fast if the toolchain is missing. Monitor CI logs for skipped metal tests.

---

## Longer-Term Backlog

- Implement automated visual diffing against archived OpenGL frames.
- Add remote-control toggles for Metal debugging (parity with OpenGL debug flags).
- Bring Metal-capable CI runners online; cache metallibs for faster builds.
- Explore image-based regression for cursor trails, background tint, and window logos under Metal.

---

## Operational Notes

- Always rebuild native components with `./.venv/bin/python3.13 setup.py build` after touching Metal C/ObjC sources; tests rely on freshly linked `fast_data_types`.
- macOS-only tests are guarded with `@unittest.skipUnless(sys.platform == 'darwin')`. Keep those decorators accurate when expanding coverage.
- When adding new renderer exports:  
  1. Declare in `metal_renderer.h`.  
  2. Implement in `metal_renderer.m` with proper Python error reporting.  
  3. Provide test hooks in `test_metal_helpers.py`.  
  4. Update docs or this memory file with behavioral notes.
- Do not introduce GL fallbacks in Metal paths; failing fast with descriptive errors is preferred.
