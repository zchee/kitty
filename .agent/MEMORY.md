# Metal Renderer Knowledge Base (Updated 2025-10-24)

This document is the single source of truth for the Metal migration. Overwrite it whenever the project state changes in a meaningful way.

---

## Current Platform & Build Status

- macOS builds succeed via `./.venv/bin/python3.13 setup.py build`. The build system auto-detects `Py_GIL_DISABLED` and links against the correct Python framework (`kitty/python_build_helpers.py` → `setup.py:get_python_flags`).
- `kitty.metal.get_cell_metallib_path()` wraps `importlib.resources.as_file`, keeping the packaged `cell.metallib` available even when `kitty` ships from a zip archive. The helper caches the extracted path, registers automatic cleanup, and exposes a reset hook for tests.
- Metal shader interface structs (`MetalTrailUniforms`, `MetalGraphicsUniforms`, `MetalGraphicsAlphaUniforms`) have cross-language layout validation in Objective‑C and MSL.
- All renderer passes (background, tab bar, terminals, graphics overlays, bells, scrollbars, hyperlink highlights, window numbers) run exclusively through the Metal backend on macOS. Shared window state is cached per `CAMetalLayer`.
- Background images no longer depend on OpenGL texture IDs. `background_image_ready()` accepts either a GL id or a Metal texture pointer, and uploads on macOS funnel through `metal_background_image_uploaded`.
- `setup.py` compiles and packages `kitty/metal/cell.metallib` using `xcrun metal` / `xcrun metallib`. Missing or stale metallibs abort the build with actionable errors.
- `metal_renderer_preflight()` fails fast when the packaged metallib is absent; macOS never attempts an OpenGL fallback.
- `fast_data_types` links against `Python.framework` (not `PythonT.framework`) when GIL-enabled. The interpreter import crash that previously prevented Metal tests from running has not reappeared since 2025-10-22.
- Running `./.venv/bin/python3.13 test.py --module test_metal_*` succeeds on current machines; the earlier import-time segfault is still resolved.
- Verified Metal tests succeed when `kitty` is imported from a zip archive (`PYTHONPATH=/tmp/foo.zip:$(pwd)`), confirming the metallib helper covers packaged distributions.
- The OpenGL backend is no longer registered on macOS. CLI and option parsing reject `metal_renderer=opengl`.

---

## Implementation Snapshot

- Renderer backend selection is pluggable (`renderer_backend_register`). macOS defaults to `metal`, and `metal_backend_attach_window` owns `CAMetalLayer` creation.
- Per-window Metal state owns cell, selection, uniform, and border buffers, plus sprite atlases and capture buffers. `destroy_window_state()` tears these down.
- Shared renderer helpers (`renderer_shared_prepare_frame`, glyph caches, scrollbar math, etc.) are backend-neutral; Metal consumes the shared surface alongside the legacy OpenGL code.
- Capture lifecycle flows through `metal_reset_capture_state()` on resize, capture failure, or window destruction, ensuring no dangling buffers or debug pointers survive between frames.
- `metal_record_failure()` emits Metal-specific diagnostics without referencing OpenGL to avoid misleading operators.
- CLI toggles `--debug-metal` and `--metal-gpu-capture` map to `RendererInitConfig` fields. Debug logging routes through `metal_log`/`metal_debug_event`; GPU capture forces frame completion and exposes captured data through the debug API.
- `metal_renderer_debug_get_runtime_flags_for_tests` exposes toggle state; `metal_renderer_debug_*` helpers manage capture buffers for automated verification.
- Font sprite flows respect backend selection: OpenGL resources are only created when the active backend requires them, keeping Metal windows OpenGL-free.
- Resource helpers (`metal_compute_background_geometry`, `metal_renderer_prepare_*_uniforms_for_tests`, etc.) feed Metal buffers and have dedicated unit coverage.

---

## Recent Work Log (key dates)

| Date     | Update |
|----------|--------|
| Oct 20   | Renderer backend API finalized (ensure_initialized/begin_frame/present). Initial Metal attach pipeline created. |
| Oct 21   | Background rendering, border passes, and trail uniforms ported to Metal. Metallib build pipeline integrated into `setup.py`. |
| Oct 22   | Graphics overlays, selection tinting, scrollbar passes implemented. Initial Metal debug toggles landed. Interpreter crash mitigated by relinking `fast_data_types`. |
| Oct 23   | Capture lifecycle audit and resize parity completed; debugger exports added. |
| Oct 24   | Metal debug toggles and GPU capture plumbing implemented; `test_metal_debug` verifies runtime flag propagation. Metallib helper rewired to `kitty.metal` and validated under zip packaging. |

---

## Active Roadmap (near term)

1. **Interpreter stability follow-up** (Owner: TBD)  
   Continue monitoring for `kitty.conf.utils` import crashes on Apple Silicon and Intel hosts. Collect crash logs if regressions reappear.

2. **CI Metallib caching** (Owner: Build/CI)  
   Add Apple Silicon + Intel Metal runners. Cache metallib artifacts per build to speed tests.

3. **Visual regression testing** (Owner: QA)  
   Add Metal vs. OpenGL image comparisons to guard rendering changes once fixtures are reliable.

4. **Sprite atlas policy review** (Owner: Renderer)  
   Align Metal sprite atlas growth/eviction heuristics with historical OpenGL behavior to avoid GPU memory bloat.

---

## Backlog / Longer-Term

- Introduce Metal-specific remote-control commands for enabling debug logging or capture at runtime.
- Provide user-facing configuration options (`kitty.conf`) for the new debug logging and capture toggles, mirroring the CLI switches.
- Expand automated coverage to sampler caches, geometry helpers, and font sprite flows once the interpreter crash is definitively resolved.
- Investigate Metal GPU capture integration with macOS tooling (Quartz Debug, Xcode capture APIs) for richer diagnostics and automated traces.
- Explore shader diffing harness to ensure future GLSL → MSL translations remain aligned as additional passes are ported.

---

## Testing Status

- **Automated**  
  - `kitty_tests/test_metal_debug` validates renderer toggle propagation and capture path.  
  - `test_metal_helpers`, `test_metal_background`, `test_metal_geometry`, `test_metal_resources`, and `test_metal_fallback` run clean under `./.venv/bin/python3.13 test.py --module test_metal_*`.  
  - Metal suites documented above pass when `kitty` is imported from a zip archive, confirming distribution safety for metallib resolution.

- **Manual QA**  
  - Recommended scenarios: live window resize, background image changes, window logos, capture workflows, debug logging (`--debug-metal`), and capture toggles (`--metal-gpu-capture`).

- **Known gaps**  
  - No automated visual diffing yet.  
  - No dedicated stress testing for continuous capture mode.  
  - Interpreter stability monitoring still manual.

---

## Tooling & Dependencies

- macOS 13+ with Metal-capable GPU.
- Xcode Command Line Tools (`xcrun metal`, `xcrun metallib`).
- Python 3.13 (managed via project virtualenv).
- Go 1.24+, clang/LLVM for native components.
- Ensure `kitty/metal/cell.metallib` ships with every build artifact.

---

## Operational Notes

- CLI toggles are macOS-only; other platforms ignore them quietly.
- Metal debug logging uses `timed_debug_print`, so logs respect the global debug throttling infrastructure.
- Captured framebuffers remain available through the debug API for external tooling; ensure large captures are cleared via `metal_renderer_debug_clear_captured_frame_for_tests` to avoid memory leaks.
- Keep this knowledge base synchronized with reality—the next engineer should not need to spelunk the git history to understand the Metal backend state.
