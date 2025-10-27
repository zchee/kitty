# Renderer & Backend Knowledge Base (Updated 2025-10-27)

Authoritative, always-current snapshot of the Metal migration state, helper exports, and validation mandates. Update immediately whenever renderer behavior or planned work changes.

---

## Platform & Backend Policy

- **macOS uses Metal exclusively.** Build flags keep `KITTY_DISABLE_NSGL=1`, drop `-framework OpenGL`, and ship only the Metal renderer on Darwin. OpenGL entry points remain for non-macOS targets and negative tests that assert failure modes.
- Selecting `"opengl"` on macOS must raise an informative error (`renderer_backend_select('opengl')` → `ValueError` mentioning the platform). Unit coverage exists in `kitty_tests/renderer_backend.py`.
- Non-macOS builds continue to expose both backends; skip decorators guard Metal-only expectations outside Darwin CI.

---

## Current Implementation Highlights (Metal Phase 2.2)

1. **Tint uniforms unified**  
   - `MetalTintUniforms` is now a shared C struct (edges + color arrays) declared in `kitty/metal_renderer.h`.  
   - `metal_make_tint_uniforms()` builds the packed data for both runtime rendering and tests.  
   - `metal_renderer_prepare_tint_uniforms_for_tests()` clamps tint input, converts sRGB→linear, premultiplies opacity, and returns the struct for Python validation.

2. **Renderer background capture**  
   - New integration harness (`TestMetalBackgroundTintRendering`) constructs an OS window, attaches the Metal backend, renders a tinted background, and captures the framebuffer for pixel assertions.  
   - Helper uses `_solid_rgba_png()` to generate a deterministic texture and guarantees cleanup by clearing background image and removing the window.  
   - Requires `renderer_backend_attach_window`, `renderer_backend_shutdown_active`, `get_os_window_struct_for_tests`, etc.; skips gracefully if any symbol is absent.

3. **State exposure for tests**  
   - `get_os_window_struct_for_tests()` exported from `kitty/state.c`, returning the raw `OSWindow *` for test use; stub typed in `fast_data_types.pyi`.  
   - `BackendFFI` in `kitty_tests/renderer_backend.py` now declares `RendererWindowConfig`, pointer-returning helpers, and shutdown hooks so ctypes signatures stay correct across Metal integration tests.

4. **Metal helper coverage**  
   - `TestMetalHelperFunctions` includes new tint uniform assertions (linear premultiplication, clamping) alongside previous trails/borders validations.  
   - Capture lifecycle tests ensure debug resets clear buffers and state.  
   - Metal windows confirmed not to allocate GL VAOs via state debug helpers.

---

## Test Coverage Requirements

- `kitty_tests/test_metal_helpers.py`
  - Drawable blanking, capture lifecycle, uniform packing, VAO regression, tint uniform math, and PNG-backed background capture (skips if helpers missing).  
  - Keep new helpers deterministic and GUI-free; rely on debug stubs and synthetic PNG data.
- `kitty_tests/renderer_backend.py`
  - Backend registration parity, macOS OpenGL fail-fast path, Metal preflight, VAO rebuild on backend switch.
- `kitty_tests/test_metal_background.py`, `test_metal_resources.py`
  - Continue to validate background geometry calculations and metallib availability.
- **Rule:** Every new Metal-exported function must acquire direct unit coverage in the helper suite or renderer_backend harness. No “cheater” tests—must fail on logic regressions.

---

## Operational Checklist

- Rebuild native artifacts with `./.venv/bin/python3.13 setup.py build` after touching C/ObjC. Python 3.13 inside `.venv` is the only supported interpreter.
- Use `./test.py --module test_metal_helpers` after Metal changes. On macOS hosts, ensure `TestMetalBackgroundTintRendering` executes instead of skipping (requires Metal debug helpers).
- When adding renderer exports:
  1. Declare in `metal_renderer.h`.
  2. Implement in `metal_renderer.m` with error handling, clamping, and resource cleanup.
  3. Expose Python wrapper (if needed) in `kitty/state.c` or related module and type it in `fast_data_types.pyi`.
  4. Extend helper tests with deterministic assertions.
  5. Update this memory file with behavior + coverage notes.
- Avoid GL fallbacks in Metal paths; fail fast with descriptive `PyErr_SetString`.

---

## Immediate Roadmap

1. **Run tint capture integration on real Metal hardware**  
   - Execute `./test.py --module test_metal_helpers` on a macOS host with full Metal build so `TestMetalBackgroundTintRendering` runs (currently skips off-host).  
   - Record pixel diffs and ensure cleanup (background image cleared, OS window removed) leaves no leaks.
2. **Extend capture diagnostics**  
   - Add assertions on tint application using multiple background colors and tint factors once Metal helpers expose raw float arrays to Python more broadly.
3. **Sprite atlas stress tests (deferred)**  
   - Requires deterministic fixtures; keep on backlog until pipeline instrumentation lands.

---

## Longer-Term Backlog

- Visual diff harness comparing archived OpenGL frames with Metal renders.
- Remote-control toggles for Metal debug flags (parity with GL debug options).
- CI runners with Metal capability; cache metallib outputs for fast builds.
- Automated coverage for cursor trails, window logos, and background tint via captured frames.

---

## Reference Links & Assets

- Architecture guide: `docs/metal_renderer_architecture.md`.
- Official Metal docs (Objective-C): scrape via firecrawl at `https://developer.apple.com/documentation/metal?language=objc`.
- Apple sample code: `/Users/zchee/src/github.com/zchee/apple-metal-samples/MigratingOpenGLCodeToMetal`.
- Always run code and tests using `.venv/bin/python3.13`.

---

## Notes for Future Iterations

- Whenever new ctypes bindings are required, update `BackendFFI` once and reuse across tests; avoid per-test redefinitions.  
- For additional renderer helpers, prefer returning POD structs so Python sees deterministic layouts (mirroring the `MetalTintUniforms` approach).  
- Maintain strict naming consistency between C exports and Python wrappers to satisfy mypy in `fast_data_types.pyi`.  
- Keep this file concise but exhaustive—list every active helper, associated tests, and follow-up tasks to prevent duplicate discovery in future sessions.
