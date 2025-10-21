# Metal Renderer Execution Memory  
_Last updated: 2025-10-21 (Metal framebuffer capture + ctypes coverage refresh)_

This memo supersedes all prior notes. Treat it as the canonical roadmap when resuming Metal migration work.

---

## Ground Rules
1. **Parity-first:** Maintain pixel and behavioural parity with the OpenGL path (cells, inline graphics, overlays, screenshots) before promoting Metal to default.
2. **Shared data flow:** Continue sourcing all geometry + colour info via `renderer_shared`; avoid Metal-only forks.
3. **Fail-fast fallback:** Any Metal init/encode/capture failure must fall back to OpenGL without leaking command buffers, drawables, textures, or test fixtures.
4. **Metallib integrity:** Regenerate `kitty/metal/*.metallib` whenever `.metal` sources change; never hand-alter binaries.
5. **Per-function tests:** Every touched helper/encoder/export needs ctypes coverage (macOS + Metal gated) with deliberate assertions.
6. **Resource hygiene:** Pair every allocation (textures, buffers, observers, capture buffers) with explicit teardown.
7. **Debug discipline:** Funnel new logging through existing debug flags (`g_metal.debug_labels`, etc.).

---

## Current Implementation Snapshot
- ✅ **Draw flag + overlay parity**  
  Cell/overlay sequencing matches OpenGL; ctypes tests cover draw flag helper, graphics uniforms, and new capture helpers.
- ✅ **Window capture plumbing**  
  `RendererPresentParams.capture_framebuffer` now blits the drawable into a shared buffer, converts BGRA→RGBA, and caches the result for screenshots/tests. Debug APIs expose the captured bytes.
- ✅ **Helper coverage**  
  `kitty_tests/test_metal_helpers.py` now exercises capture conversions (BGRA swap, raw RGBA passthrough) alongside existing uniform checks.
- ⚠️ **Build still blocked on Metal shader + renderer_shared warnings**  
  `python3.13 setup.py build` fails earlier in `cell.metal` (“MetalTrailUniforms.extra_alpha”) and pedantic warnings in `renderer_shared.c`. These must be resolved before tests run.
- ⚠️ **fast_data_types unavailable under Python 3.13**  
  Build failure prevents ctypes harness from loading the extension; tests remain unexecuted in this sandbox.

---

## Next Actions
1. **Unblock build/test pipeline**
   - Fix `cell.metal` compile errors (ensure MetalTrailUniforms matches struct layout) and silence `renderer_shared.c` pedantic warnings.
   - Re-run `python3.13 setup.py build` and `python3.13 test.py --module test_metal_helpers`.
2. **Screenshot plumbing**
   - Identify call-sites that request framebuffer capture (screenshots, remote commands) and wire them to consume the new Metal capture buffer.
   - Verify PNG/IPC paths expect RGBA and honour stride.
3. **Metallib tooling**
   - Add timestamp/hash tracking in `setup.py` so `.metal` edits rebuild `.metallib`.
   - Ensure regenerated metallib ships in wheels/app bundles with version guardrails.
4. **Runtime stability**
   - Audit capture teardown paths (`destroy_window_state`, shutdown, failure) for leaks; add explicit tests if possible.
   - Confirm `metal_record_failure` clears capture buffers alongside pipelines.
5. **Extended validation**
   - Add ctypes coverage for other overlay helpers (scrollbar metrics, hyperlink background) and capture error cases once build is green.
   - Plan automated GL↔Metal image diff harness for regression detection post-capture parity.
6. **Documentation**
   - Update contributor docs with minimum Python/macOS versions until the Python 3.13 build is reliable.

---

## Quick Reference
- Capture helpers: `metal_renderer_copy_captured_frame_for_tests`, `_debug_set_...`, `_debug_clear_...`.
- Capture implementation: `metal_backend_present`, `metal_capture_framebuffer`, `metal_finalize_capture`, state fields on `MetalWindowState`.
- Tests: `kitty_tests/test_metal_helpers.py` (draw flags, graphics uniforms, capture conversions).
- Shader pipeline: `kitty/metal/cell.metal` (pending struct alignment fix).
- Build command: `python3.13 setup.py build` (currently failing prior to tests).

Keep this memo sync’d after every significant Metal renderer change to avoid rediscovery.
