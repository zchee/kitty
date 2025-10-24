# Metal Renderer Knowledge Base (Updated 2025-10-24)

This document remains the single source of truth for kitty’s Metal migration. Update it whenever implementation or testing status changes materially.

---

## Current Platform & Build Status

- macOS builds succeed via `./.venv/bin/python3.13 setup.py build`. The build harness still auto-detects `Py_GIL_DISABLED` and links against the correct Python framework (`kitty/python_build_helpers.py` → `setup.py:get_python_flags`).
- `kitty.metal.get_cell_metallib_path()` continues to wrap `importlib.resources.as_file`, caching the extracted metallib, registering automatic cleanup, and supporting zip distributions.
- Metal shader interface structs (`MetalTrailUniforms`, `MetalGraphicsUniforms`, `MetalGraphicsAlphaUniforms`) keep validated layout parity across Objective-C, C, and MSL.
- All renderer passes (backgrounds, tab bar, terminals, graphics overlays, bells, scrollbars, hyperlink highlights, window numbers) execute exclusively through the Metal backend on macOS. Shared window state is cached per `CAMetalLayer`.
- Background image uploads are Metal-native (`metal_background_image_uploaded`), and `background_image_ready()` accepts either GL IDs or Metal texture handles without OpenGL dependencies.
- `setup.py` still compiles and packages metallibs via `xcrun metal` / `xcrun metallib`, failing fast when toolchains or outputs are stale.
- `metal_renderer_preflight()` remains fatal when packaged metallibs are missing; macOS no longer attempts OpenGL fallbacks.
- `fast_data_types` links against `Python.framework` (never `PythonT.framework`) on GIL-enabled builds, and the interpreter import crash last seen on 2025-10-21 remains resolved.
- All Metal-focused Python suites (`test_metal_*`) and mixed renderer suites pass when the project is imported from a zip bundle, verifying packaged metallib resolution.
- The OpenGL backend is no longer registered on macOS; CLI and option parsing reject `metal_renderer=opengl`.

---

## Implementation Snapshot

- Renderer backends are pluggable through `renderer_backend_register`. macOS selects `RENDERER_BACKEND_METAL`; `metal_backend_attach_window` owns `CAMetalLayer` creation and teardown.
- Window sharing semantics are now backend-aware: `share_window_for_backend()` ensures macOS Metal windows request a NULL share context while legacy OpenGL paths reuse the existing shared context. The logic is exported to Python for verification via `_share_window_hint_for_tests`.
- Per-window Metal state manages all drawable resources (cell, selection, uniform, border buffers, sprite atlases, capture buffers). `destroy_window_state()` continues to cleanly release them.
- Shared helpers (`renderer_shared_prepare_frame`, glyph caches, scrollbar math, etc.) stay backend-neutral; Metal consumes the same surface description used by the retired macOS OpenGL path.
- Capture lifecycle still flows through `metal_reset_capture_state()` on resize/failure/destroy, so no dangling capture buffers remain between frames.
- Diagnostics: `metal_record_failure()` and friends emit Metal-specific logs, and debug toggles (`--debug-metal`, `--metal-gpu-capture`) surface through `RendererInitConfig` and the debug helper API.
- Font sprite flows respect backend selection; OpenGL resources are never created when Metal drives rendering.
- OS window lifecycle skips OpenGL VAO allocation/destruction whenever the Metal backend is active; `state.c` now conditionally creates and frees GPU resources based on the selected renderer.
- Test helpers expose `state_debug_add_os_window_for_tests()` so Python Metal suites can instantiate OS windows without platform-specific glue.

---

## Recent Work Log (key dates)

| Date       | Update |
|------------|--------|
| 2025-10-20 | Renderer backend API finalized; initial Metal attach pipeline landed. |
| 2025-10-21 | Metal background/border passes implemented; metallib build integrated into `setup.py`. |
| 2025-10-22 | Graphics overlays, selection tinting, scrollbar passes, and Metal debug toggles completed. Interpreter crash mitigated. |
| 2025-10-23 | Capture lifecycle parity with OpenGL verified; debugger exports added. |
| 2025-10-24 | Metal debug toggles and GPU capture plumbing complete; metallib helper validated under zip import. | 
| 2025-10-24 | **New:** GLFW window creation now routes through `share_window_for_backend()`, preventing Metal from inheriting stale GL share contexts. `_share_window_hint_for_tests` exposes the decision to Python, and `kitty_tests.glfw.TestGLFW.test_share_window_hint` guards the behaviour. |
| 2025-10-24 | **New:** `state.c` no longer creates or destroys OpenGL VAOs when Metal drives rendering; helper exports added so tests can assert VAO-free state. |
| 2025-10-24 | **New:** `state_debug_add_os_window_for_tests()` returns stable OS window IDs, allowing Metal regression tests to instantiate windows via ctypes. |

---

## Active Roadmap (near term)

1. **Interpreter stability follow-up** (Owner: TBD) – keep monitoring `kitty.conf.utils` import crashes on Apple Silicon / Intel hosts; capture crash logs if they reappear.
2. **CI Metallib caching** (Owner: Build/CI) – add Apple Silicon + Intel Metal runners and cache metallib artifacts.
3. **Visual regression testing** (Owner: QA) – introduce Metal vs. OpenGL image comparisons when fixtures stabilize.
4. **Sprite atlas policy review** (Owner: Renderer) – align Metal atlas growth/eviction heuristics with historical OpenGL behaviour to avoid GPU memory bloat.

---

## Backlog / Longer-Term Ideas

- Metal remote-control commands for toggling debug logging and capture at runtime.
- User-facing configuration knobs (`kitty.conf`) mirroring CLI Metal debug/capture options.
- Broader automated coverage (sampler caches, geometry helpers, font sprite flows) once interpreter stability is fully validated.
- Integrate macOS GPU capture tooling (Quartz Debug, Xcode) for richer automated traces.
- Shader diffing harness to ensure future GLSL → MSL translations remain aligned.

---

## Testing Status

- **Automated**
  - `kitty_tests/test_metal_debug`, `test_metal_helpers`, `test_metal_background`, `test_metal_geometry`, `test_metal_resources`, `test_metal_fallback` all pass under `./.venv/bin/python3.13 test.py --module test_metal_*`.
  - `kitty_tests/glfw.py::TestGLFW.test_share_window_hint` now asserts correct share-context behaviour for Metal vs. OpenGL, using `_share_window_hint_for_tests` exported through `fast_data_types`.
- **Manual QA** – continue live resize, background image change, window logo, capture workflow, `--debug-metal`, and `--metal-gpu-capture` smoke checks.
- **Known gaps** – visual diffing framework, continuous capture stress tests, automatic interpreter stability monitoring remain open.

---

## Tooling & Dependencies

- macOS 13+ with Metal-capable GPU.
- Xcode Command Line Tools for `xcrun metal` / `xcrun metallib`.
- Python 3.13 (project virtualenv), Go 1.24+, clang/LLVM.
- Ensure `kitty/metal/cell.metallib` ships with every distribution artifact.

---

## Operational Notes

- CLI toggles are macOS-only; other platforms ignore them quietly.
- Metal debug logging routes through `timed_debug_print`, respecting global throttling.
- Captured framebuffers remain accessible via `metal_renderer_debug_*` helpers; tests should call `metal_renderer_debug_clear_captured_frame_for_tests` after large captures.
- Keep this knowledge base in sync with reality so the next engineer understands the Metal backend without trawling git history.
