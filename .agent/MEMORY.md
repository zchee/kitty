# Metal Renderer Execution Memory  
_Last updated: 2025-10-15_

Canonical scratchpad for the macOS Metal bring-up. Always overwrite this file with the latest truth—no append-only notes.

---

## Guardrails
1. Follow repository rules: no duplication, no dead code, no mocks, no over-engineering, no resource leaks, consistent naming.
2. Error handling: fail fast on critical configuration and backend/device initialization; log-and-continue for optional features; gracefully degrade on external service failures; surface user-friendly messages via the resilience layer.
3. Every new or refactored function must ship with non-cheating tests that exercise the real execution path.
4. Ship only complete increments—leave no TODO placeholders or partial implementations.
5. Prefer reuse of existing helpers; audit relevant modules before introducing new utilities.

## Current Snapshot
- **Backend dispatcher** (`kitty/renderer_backend.{h,c}`): lifecycle hooks (`begin_frame`, `render`, `present`, etc.) route rendering through the selected backend; null-hook guards keep ctypes stubs from crashing and include backend-aware messaging.
- **OpenGL path** (`kitty/opengl_renderer.c`, `kitty/shaders.c`, `kitty/gl.c`): fully featured VAO/VBO rendering with layered compositing, graphics protocol, cursor trails, background images. Serves as parity target.
- **Metal path** (`kitty/metal_renderer.m`): device + command queue + CAMetalLayer creation works; clears + presents; new sprite upload hooks now mirror glyph atlas data into Metal-managed textures/buffers but no draw encoders exist yet.
- **Backend selection** (`kitty/glfw.c`): `select_metal_if_preferred()` honors `metal_renderer` option. First-window initialization skips GLSL compilation and GL sprite uploads when Metal is active.
- **Sprite pipeline**:
  - `kitty/fonts.c`: prerender routines call backend-neutral hooks; GL path still uses `send_sprite_to_gpu`.
  - `kitty/metal_renderer.m`: registers sprite upload/free hooks; maintains `MTLTexture` array and decorations `MTLBuffer` per `FontGroup` (stored in new `metal_sprite_map` field).
- **`FONTS_DATA_HEAD`** (`kitty/data-types.h`): now includes `metal_sprite_map` pointer so each font group carries Metal atlas state alongside GL sprite map.
- **State plumbing**: `send_prerendered_sprites_for_window` takes a flag to control GL resource allocation vs. Metal-only capture; callers in `glfw.c` and `state.c` pass `!using_metal` / backend checks accordingly.
- **Tests**: `python3.13 setup.py build`, `python3.13 -m unittest kitty_tests.renderer_backend`, and `python3.13 -m unittest kitty_tests.options.TestRendererPreferenceOptions` all pass. Multiprocessing spawn test still fails under Homebrew Python because `_random` module missing.

## Build & Test Status
- `python3.13 setup.py build` (2025-10-15) succeeds with the new Metal sprite hooks.
- `python3.13 -m unittest kitty_tests.renderer_backend` passes.
- `python3.13 -m unittest kitty_tests.options.TestRendererPreferenceOptions` passes.
- `kitty_tests.tui.TestTUI.test_multiprocessing_spawn` still errors on Homebrew `python@3.13t` (missing `_random`).
- No metallib/MSL build pipeline yet; Metal rendering remains unimplemented.

## Outstanding Defects & Blockers
1. **Environment dependency**: `_random` absent in Homebrew Python used for spawn test. Need policy (document requirement or guarded skip).
2. **Rendering parity**: Metal backend still lacks cell/border/graphics/cursor/background draw encoders.
3. **Resource parity**: Metal stores glyph atlases but draw code doesn’t consume them; border buffers, uniform data, and pipeline states outstanding.
4. **Shader toolchain**: No translation of GLSL to MSL, no metallib build integration.

## Architectural Work Breakdown
### Backend abstraction cleanup
- [x] Dispatcher null-hook guards and backend-aware errors.
- [x] Skip GL init (GLSL, sprite upload) when Metal active.
- [ ] Audit remaining direct GL usage (resize paths, suspend/resume, screenshot capture) and route through backend.

### Metal bootstrap (current focus)
- [x] Register Metal sprite atlas hooks, capture prerendered glyph data into `MTLTexture`/`MTLBuffer`.
- [ ] Define Metal equivalents for border rect buffers, uniform/argument buffers, per-frame constants.
- [ ] Choose shader translation approach (SPIRV-Cross, Tint, bespoke) and generate first MSL cell shader.
- [ ] Integrate metallib build + packaging into `setup.py` / install artifacts.

### Feature parity
- [ ] Implement Metal cell rendering pipeline (vertex/index buffers, uniform buffers, pipeline states).
- [ ] Port borders, cursor trail, background image passes to Metal encoders.
- [ ] Handle layered windows (offscreen texture + blit) similar to OpenGL `setup_os_window_for_rendering`.
- [ ] Integrate graphics protocol textures and decorations buffer lookup.
- [ ] Build backend-neutral render graph to feed both GL and Metal.
- [ ] Add image-diff or checksum regression tests comparing GL vs Metal output (skip when Metal unavailable).

### Performance & robustness
- [ ] Profile Metal path (Metal System Trace) once functional.
- [ ] Device-loss recovery, sleep/App Nap handling.
- [ ] Long-duration soak tests on Apple Silicon and Intel hardware.

## Roadmap Checklist
- **Phase 1 – Backend Abstraction Stabilisation**
  - [x] Guard dispatcher against null hooks.
  - [x] Enforce `metal_renderer` option validation.
  - [x] Gate OpenGL-only prerender routines.
  - [ ] Remove remaining GL leakage on Metal code paths.
- **Phase 2 – Metal Bootstrap Enhancements**
  - [x] Metal sprite atlas capture.
  - [ ] Metal buffer/texture wrappers for borders + uniforms.
  - [ ] Shader translation + metallib integration.
- **Phase 3 – Feature Parity**
  - [ ] Metal cell/border/graphics/cursor/background encoders.
  - [ ] Backend-neutral render graph.
  - [ ] Cross-backend comparison tests.
- **Phase 4 – Performance & Robustness**
  - [ ] Profiling, recovery flows, soak testing.

## Dependencies & Tooling
- Need decision on shader translation tool (SPIRV-Cross, Tint, custom).
- Metallib build steps required in `setup.py` and packaging.
- CI must run on Metal-capable macOS 13+ hosts.
- Python runtime must supply `_random` for multiprocessing spawn test or skip logic must document deficiency.

## Risks & Mitigations
| Risk | Impact | Mitigation |
| --- | --- | --- |
| Missing `_random` in spawned Python | Multiprocessing test fails | Document requirement or add explicit skip with warning |
| Lack of Metal render pipelines | Metal backend unusable | Implement encoders incrementally using new atlas data |
| Shader translation mismatch | Visual artifacts / crashes | Adopt automated GLSL↔MSL validation and shared metadata |
| Metal resource leaks | Long-running sessions degrade | Sprite hooks release resources; ensure encoder resources cleaned up |

## Pending Decisions / Questions
1. Choose shader translation workflow and related metadata pipeline.
2. Define backend-neutral render graph format to reduce duplicated draw logic.
3. Decide on metallib packaging strategy for builds/app bundle.

## Key Files & References
- Dispatcher: `kitty/renderer_backend.{h,c}`, `kitty/renderer_backend_types.h`
- OpenGL renderer: `kitty/opengl_renderer.c`, `kitty/shaders.c`, `kitty/gl.c`
- Metal renderer: `kitty/metal_renderer.m`
- Fonts/sprite pipeline: `kitty/fonts.c`, `kitty/fonts.h`, `kitty/shaders.c`
- Window glue: `kitty/glfw.c`, `glfw/cocoa_window.m`, `glfw/nsgl_context.m`
- Python bindings/tests: `kitty/data-types.c`, `kitty/fast_data_types.pyi`, `kitty_tests/renderer_backend.py`, `kitty_tests/options.py`
- Design doc: `docs/metal_renderer_architecture.md`

## Working Protocol
1. Re-read this file and `docs/metal_renderer_architecture.md` before working on renderer code.
2. After meaningful progress, overwrite (not append to) this file with updated facts, risks, and plans.
3. Log new failures, mitigations, or environment changes immediately.
4. Keep roadmap checkboxes accurate; mark completed tasks promptly.
5. Record unresolved decisions so they can be addressed before implementation continues.
