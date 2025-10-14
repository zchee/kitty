# Metal Renderer Execution Memory
_Updated on 2025-10-14_

Single source of truth for the Metal renderer bring-up. Overwrite (do not append) after every significant decision, fix, or discovery so future sessions resume with zero rediscovery.

---

## Core Guardrails
- Follow repository rules: no duplication, no dead code, no mocks, no over-engineering, no resource leaks, consistent naming.
- Error policy: fail fast on critical configuration (backend selection/device init), log-and-continue on optional features, degrade gracefully on external failures, surface user-friendly errors via the resilience layer.
- Testing: every new or refactored function must ship with non-cheating tests that exercise real execution paths.
- Deliver shippable increments only—no placeholders or stubs left behind.
- Prefer reuse of existing helpers; study modules before introducing utilities.

## Snapshot (2025-10-14)
- **Dispatcher**: `kitty/renderer_backend.{h,c}` intact; OpenGL backend registered and functional.
- **Metal backend**: `kitty/metal_renderer.mm` still a stub—preflight hard-fails, lifecycle hooks raise `RuntimeError`.
- **OpenGL helpers**: Live in `kitty/shaders.c` and related files; extraction into GL-only units remains pending to avoid duplication when Metal arrives.
- **Tests**: `kitty_tests/renderer_backend.py` covers dispatcher semantics and enforces that `present()` must exist on each backend.
- **Python ABI / build**:
  1. ✅ (2025-10-14) `glfw/glfw.py` now emits `<stdbool.h>` and `<sys/types.h>`; regenerated `kitty/glfw-wrapper.h` is warning-clean for `pid_t`/`bool` under clang17 + `-Werror`
  2. ⛔ Objective-C++ build of `kitty/metal_renderer.mm` still collides with Foundation `MAX`/`MIN`
  3. ⛔ `-Werror` trips on GNU anonymous structs in `kitty/data-types.h` and unused symbols (Metal stubs, sprite helpers)
  Until 2–3 clear, rebuilding `fast_data_types.so` for Python 3.11 remains blocked.
- **GLFW/Cocoa**: `kitty/glfw.c` and `glfw/*.m` assume NSOpenGL contexts and call `glfwSwapBuffers` directly; backend-neutral hooks not yet threaded through.
- **Build system**: Links Metal frameworks but has no `.metal` shader compilation or metallib packaging.

## Immediate Priorities (in order)
1. **Objective-C++ macro hygiene**
   - Update `kitty/metal_renderer.mm` (and any Objective-C++ includes) to undefine or wrap `MAX`/`MIN` clashes.
   - Ensure new code uses kitty helpers or `std::max/min` equivalents to stay warning-clean.
2. **Warning audit for `-Werror`**
   - Resolve GNU anonymous struct usage in `kitty/data-types.h` (refactor or add portable wrappers).
   - Remove/annotate unused Metal stub functions and OpenGL sprite helpers so clang17 builds cleanly.
3. **Python 3.11 rebuild**
   - After 1–2, rebuild `fast_data_types.so` with Python 3.11, then run `python3.11 test.py renderer_backend` to verify dispatcher/tests.
4. **OpenGL helper extraction (Phase 1 goal)**
   - Move `setup_os_window_for_rendering`, `draw_cells`, `draw_borders`, `blank_canvas`, cursor trails, background image, scrollbar, etc., from `kitty/shaders.c` into GL-only translation units (e.g. `kitty/opengl_renderer_draw.c`).
   - Keep interfaces private to the OpenGL backend to prevent Metal coupling.
5. **GLFW/Cocoa neutrality**
   - Route window lifecycle through `renderer_backend_*` hooks (`attach_window`, `present`, `on_resize`, `on_suspend`, `on_resume`).
   - Prepare to swap NSOpenGL context creation with CAMetalLayer attachment once Metal backend exists.

## Roadmap

### Phase 1 – Backend Abstraction Completion (Active)
**Goals**: backend-neutral contract fully honored; OpenGL helpers isolated; Python 3.11 builds pass clean.

**Key Tasks**
- Complete helper extraction (see Immediate Priority #4).
- Keep generated GLFW headers in sync (already regenerated; re-run `python3 glfw/glfw.py` whenever upstream headers change).
- Resolve Objective-C++ macro collisions and clang warnings (Immediate Priorities #1–2).
- Rebuild `fast_data_types.so` under Python 3.11 and run `python3.11 test.py renderer_backend`.
- Extend tests to exercise resize/on_resize paths through the dispatcher post-extraction.

**Exit Criteria**
- No OpenGL-only helpers exposed outside GL backend units.
- `python3.11 test.py renderer_backend` passes with freshly built extension.
- macOS 13+/clang17 build is warning-clean with `-Werror`.

### Phase 2 – Metal Bootstrap
**Goals**: Metal backend clears + presents a frame.

**Key Tasks**
- Implement `metal_renderer_preflight` with OS/GPU checks and actionable errors.
- Create singleton `MTLDevice`, command queue, per-thread command buffers.
- Attach `CAMetalLayer` during window creation; honor swap-interval policy.
- Implement `begin_frame`, `present`, `on_resize`, suspend/resume handlers for drawable lifecycle.
- Add structured logging for device/command failures.

**Tests**
- Integration harness confirming Metal selection succeeds on supported hosts and falls back to OpenGL otherwise.
- Dispatcher tests verifying lifecycle hook call order and error propagation for Metal.

### Phase 3 – Metal Feature Parity
**Goals**: Match OpenGL output (glyphs, borders, graphics protocol, effects).

**Key Tasks**
- Establish GLSL→MSL pipeline, compile metallibs during build.
- Map uniform/state data to Metal pipeline descriptors/buffers.
- Implement texture/buffer allocators mirroring OpenGL helpers without duplication.
- Adjust `graphics.c` to emit backend-neutral render pass descriptions consumed by GL + Metal.
- Ensure sRGB/alpha semantics align across backends.

**Tests**
- Visual diff/image comparison across representative scenes.
- Stress tests for atlas growth, live resize, graphics protocol traffic.

### Phase 4 – Performance & Robustness
- Profile via Metal System Trace; tune command submission and frame pacing.
- Implement device-loss recovery, display sleep/app nap handling.
- Add telemetry for stalls, memory pressure, and fallback counts.
- Long-running tests covering suspend/resume, monitor topology changes, heavy workloads.

### Phase 5 – Release Hardening & CI
- Provision Metal-capable macOS CI runners (Apple Silicon + Intel >= macOS 13).
- Package metallibs into app bundles / standalone builds; ensure notarization/signature coverage.
- Finalize fallback policy (`auto|always|never`) and telemetry collection for failovers.
- Update docs, migration guides, release notes.
- Run full regression suite across both backends in CI; perform manual smoke tests on supported hardware.

## Risks & Mitigations
| Risk | Impact | Mitigation |
| --- | --- | --- |
| GLSL→MSL translation gaps | Rendering defects/build failures | Prototype translation early; add automated shader signature tests; prefer supported transpilers |
| Performance regressions on Metal | User-visible latency jumps | Profile in Phase 3/4; tune queues, buffering, pipeline states |
| Metallib build overhead | Longer builds, brittle CI | Cache compiled outputs; document toolchain steps; integrate incremental checks in `setup.py` |
| GLFW/Cocoa/Metal integration bugs | Window creation/render failures | Comprehensive backend-selection tests; robust OpenGL fallback with clear logging |
| Python ABI drift | Blocks tests/releases | Rebuild extension whenever Python version changes; document process |

## File & Ownership Map
- Backend core: `kitty/renderer_backend.{h,c}`, `kitty/renderer_backend_types.h`
- OpenGL backend: `kitty/opengl_renderer.c`, `kitty/opengl_renderer_priv.h`, (planned) `kitty/opengl_renderer_draw.c`
- Metal backend: `kitty/metal_renderer.mm`, future `.metal` sources
- Windowing glue: `kitty/glfw.c`, `glfw/nsgl_context.m`, `glfw/cocoa_window.m`
- Rendering helpers pending extraction: `kitty/shaders.c`, `kitty/graphics.c`
- Tests: `kitty_tests/renderer_backend.py`, planned Metal image comparison harness
- Docs: `docs/metal_renderer_architecture.md`
- Build system: `setup.py`, `Makefile`, metallib pipeline (to be added)

## Working Protocol
1. Read this file + `docs/metal_renderer_architecture.md` before coding.
2. After meaningful progress, overwrite relevant sections here immediately.
3. Document new risks/decisions/environment changes as they happen.
4. Keep roadmap status accurate—no stale "in progress" items.
5. When builds/tests fail, capture command, failure, and resolution steps here.
