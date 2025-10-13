# Metal Renderer Execution Memory  
_Updated on 2025-10-13_

Authoritative roadmap for delivering Metal rendering support on macOS with full OpenGL feature parity. Maintain this file aggressively; overwrite or expand it after every significant discovery or implementation change so future sessions can resume without rediscovery.

---

## Directive Snapshot
- Follow project guardrails: no code duplication, no dead code, no mocks, no over-engineering, no resource leaks, consistent naming.
- Honor error-handling philosophy: fail fast for critical configuration (renderer selection), log-and-continue for optional features, degrade gracefully for external service failures, present friendly messages via resilience layer.
- Tests: every function requires accurate, verbose tests; never rely on mock services. Run real integration paths where feasible.
- Implementation increments must ship production-ready—avoid partial implementations and placeholders.
- Prefer reuse of existing helpers; read current modules before adding new utilities.

## Current State (2025-10-13)
- `renderer_backend_*` dispatch infrastructure exists; `child-monitor.c` orchestrates begin→render→present for whichever backend is registered.
- OpenGL backend remains the only functional renderer. Helper declarations were moved behind `opengl_renderer_priv.h`, but the implementations still live in `kitty/shaders.c`, leaving Metal unable to reuse them without duplication.
- `metal_renderer.mm` is a stub: preflight always fails, and no device, command queue, CAMetalLayer, or encoder lifecycle is present.
- Tests in `kitty_tests/renderer_backend.py` cover dispatcher behavior (including ensuring GL helpers stay private). Metal paths are untested because initialization fails immediately.
- Python environment mismatch: running `python3 test.py renderer_backend` with Python 3.9 fails due to typing annotations; Python 3.11 run crashes because `fast_data_types.so` was compiled for 3.9. We cannot execute renderer tests until the extension is rebuilt against 3.11 (or an appropriate ABI).
- GLFW integration (e.g., live resize, `cocoa_out_of_sequence_render`) still calls OpenGL-specific routines and swap buffers directly.
- Build system already links Metal-related frameworks but has no pipeline for compiling `.metal` shaders or packaging `metallib` artifacts.

## Immediate Blockers
1. GL helper code needs extraction into OpenGL-exclusive translation units before Metal can implement alternate draw paths without violating “no duplication.”
2. `RendererBackendOps` in `renderer_backend.h` lacks an explicit `swap_buffers` hook even though `renderer_backend.c` still references it—abstraction must be tidied up before additional backends.
3. Test environment requires a Python 3.11-compatible `fast_data_types.so` to enable meaningful regression testing post-changes.
4. GLFW/Cocoa plumbing currently assumes an OpenGL context; Metal will need CAMetalLayer ownership and present-style pacing integrated into these paths.

## Phase Roadmap

### Phase 1 – Backend Abstraction Completion (In Progress)
**Goals**
- Finish isolating OpenGL-only helpers and ensure `RendererBackendOps` cleanly represents lifecycle hooks shared across backends.

**Key Tasks**
- Move `setup_os_window_for_rendering`, `draw_cells`, `draw_borders`, `blank_canvas`, cursor trail, background image, scrollbar, and indirect framebuffer logic from `kitty/shaders.c` into OpenGL-specific source files (e.g., `opengl_renderer_draw.c`).
- Resolve `swap_buffers` pointer mismatch and confirm whether an explicit `end_frame` hook is required.
- Ensure `child-monitor.c`, live resize, and screenshot paths interact exclusively through backend-agnostic hooks.
- Rebuild `fast_data_types.so` for Python 3.11 and get `python3.11 test.py renderer_backend` passing.
- Expand resize / on_resize tests to confirm backend dispatch routes correctly after refactor.

**Exit Criteria**
- No OpenGL helper symbols accessible outside OpenGL translation units.
- Renderer dispatcher compiles without unused hooks and all tests in `python3.11 test.py renderer_backend` pass.

### Phase 2 – Metal Bootstrap
**Goals**
- Provide a functioning Metal backend skeleton capable of clearing a drawable and presenting a frame.

**Key Tasks**
- Implement `metal_renderer_preflight` to check OS/hardware support and surface actionable errors.
- Initialize `MTLDevice`, `MTLCommandQueue`, and per-thread command pools respecting fail-fast policy.
- Attach `CAMetalLayer` to windows (`glfw.c`/Cocoa) with correct drawable sizing, pixel formats, and vsync configuration. Integrate with existing swap-interval logic.
- Implement `begin_frame`, `present`, `on_resize`, and suspension/resume handling that manage drawable acquisition/release.
- Provide high-signal logging for device/command failures.

**Tests**
- Add integration tests ensuring Metal selection succeeds on supported hosts and falls back to OpenGL otherwise (using ctypes harness).
- Extend renderer backend tests to cover Metal begin/present call order and failure paths.

### Phase 3 – Metal Feature Parity
**Goals**
- Recreate all OpenGL rendering features (glyph cache, borders, background images, cursor trails, graphics protocol) using Metal pipelines.

**Key Tasks**
- Select or build GLSL→MSL translation workflow; generate and cache `.metallib` assets during build.
- Map uniform/state data structures to Metal pipeline descriptors and argument buffers.
- Implement texture/buffer allocation routines that mirror OpenGL helpers without duplication (fonts, sprites, graphics protocol textures).
- Ensure color management, sRGB handling, and transparency match OpenGL output.
- Rework draw-pass emission in `graphics.c` to produce backend-neutral render pass descriptions consumed by both OpenGL and Metal implementations.

**Tests**
- Snapshot/image-diff regression tests comparing OpenGL vs Metal output for representative scenes.
- Stress tests for glyph atlas growth, dynamic resizing, and graphics protocol usage on Metal.

### Phase 4 – Performance & Robustness
**Goals**
- Achieve comparable (or better) performance, frame pacing, and stability on Metal.

**Key Tasks**
- Integrate Metal System Trace and GPU counters to profile frame latency vs OpenGL.
- Implement device-loss recovery, display sleep handling, and app nap awareness.
- Tune command buffer submission (triple buffering vs present-after-commit) based on profiling.
- Add logging/metrics hooks to detect stalls or memory pressure conditions.

**Tests**
- Automated long-run tests exercising suspend/resume, monitor changes, and high-throughput workloads.
- Performance benchmarks comparing FPS and latency versus OpenGL baseline.

### Phase 5 – Release Hardening & CI
**Goals**
- Ship Metal support confidently with CI coverage and fallbacks.

**Key Tasks**
- Provision macOS CI runners with Metal-capable GPUs; integrate Metal-focused test suites.
- Package metallib artifacts inside app bundles and standalone builds; ensure notarization steps include them.
- Finalize fallback strategy: user-configurable preference (`auto|always|never`), telemetry/logging for automatic fallback events.
- Update documentation, migration guides, and release notes.

**Tests**
- Full regression suite across both backends in CI.
- Manual smoke tests on Intel and Apple Silicon macOS versions >=13.

## Supporting Infrastructure & Dependencies
- Python ≥3.11 required to run renderer tests; rebuild `fast_data_types.so` using `python3.11 setup.py build`.
- macOS 13+ with Metal-compatible GPU (Apple Silicon or supported Intel) for development and CI.
- Xcode command line tools providing `xcrun metal` / `metallib` for shader compilation.
- Ensure `docs/metal_renderer_architecture.md` remains the canonical design reference; update alongside code changes.

## Risk Register
| Risk | Impact | Mitigation |
| --- | --- | --- |
| Shader translation incompatibilities between GLSL and MSL | Rendering defects or build failures | Prototype translation early; maintain automated shader signature tests; prefer officially supported transpilers where possible |
| Performance regression on Metal | User-visible latency increases | Profile during Phase 3/4; adjust pipeline state objects, command queue usage, and surface sync options |
| Build complexity due to Metallib assets | Longer builds, brittle CI | Cache compiled metallibs, document reproducible toolchain steps, integrate into `setup.py` with incremental checks |
| GLFW/Cocoa integration bugs when switching backends | Window creation/rendering failures | Add comprehensive integration tests for backend selection, maintain fallback to OpenGL with clear error logging |
| ABI mismatch for `fast_data_types.so` | Tests blocked | Rebuild extension promptly whenever Python version changes; document command in this file |

## File & Responsibility Map
- Backend core: `kitty/renderer_backend.{h,c}`, `kitty/renderer_backend_types.h`
- OpenGL backend: `kitty/opengl_renderer.c`, `kitty/opengl_renderer_priv.h`, (planned) `kitty/opengl_renderer_draw.c`
- Metal backend: `kitty/metal_renderer.mm`, future `.metal` shader sources
- Windowing glue: `kitty/glfw.c`, `glfw/nsgl_context.m`, `glfw/cocoa_window.m`
- Rendering helpers pending extraction: `kitty/shaders.c`, `kitty/graphics.c`
- Tests: `kitty_tests/renderer_backend.py`, future Metal image comparison harness
- Design docs: `docs/metal_renderer_architecture.md`

## Working Protocol
1. Before coding, re-read this memory file and relevant source ownership notes.
2. After completing any milestone or significant discovery, update this file immediately—overwrite the relevant section with current facts (no append-only logs).
3. Record new risks, decisions, or environment changes so later sessions inherit accurate context.
4. Keep roadmap and phase status synchronized with actual progress; avoid stale “in progress” markers.
5. When tests or builds fail due to toolchain issues, document exact commands and resolutions here.

Maintaining this document is part of the deliverable. Treat it as the ground truth for project state and next actions.
