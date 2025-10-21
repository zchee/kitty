# Metal Renderer Execution Memory  
_Last updated: 2025-10-21 (cell pass flag clamp + ctypes helpers)_

This memo replaces prior notes. Use it as the authoritative snapshot of the Metal renderer migration before resuming work.

---

## Ground Rules
1. **Parity-first:** Match OpenGL output pixel-for-pixel across cells, inline graphics, overlays, diagnostics before enabling Metal by default.  
2. **Shared data flow:** Consume draw data exclusively via `renderer_shared`; no Metal-only forks for geometry or colour sources.  
3. **Fail-fast fallback:** Any Metal init/encode failure must drop back to OpenGL without leaking layers, command buffers, or textures.  
4. **Metallib source of truth:** Regenerate `kitty/metal/cell.metallib` whenever Metal shaders change; never hand-edit binaries.  
5. **Per-function tests:** Every exported helper/encoder touched must gain Python ctypes coverage, gated on macOS + Metal availability.  
6. **Resource hygiene:** Mirror every allocation with explicit teardown (textures, buffers, samplers, observers).  
7. **Debug noise control:** Route new logging through existing debug flags only.

---

## Current Implementation Snapshot
- ✅ **Cell pass background/foreground control**  
  - Added `metal_apply_draw_flags` so per-pass background masks clamp to `METAL_DRAW_BG_{DEFAULT,NON_DEFAULT}` while keeping effect bits.  
  - `metal_encode_cell_pass` now copies `MetalDrawParams`, applies the helper, and passes the adjusted struct to the encoder.  
  - Exported `metal_renderer_apply_draw_params_for_tests` for ctypes verification.
- ✅ **Inline graphics + overlays parity**  
  - `metal_render_pass_for_render_data` sequences background, inline graphics, foreground, logos, and overlays to match OpenGL ordering.  
  - Graphics encoders (`metal_encode_graphics_bucket`, `metal_encode_graphics_alpha_bucket`) handle straight alpha & premult pipelines.  
  - Scrollbar, hyperlink target, visual bell, window number, and window logos render via dedicated Metal encoders, sharing texture caches.
- ⚠️ **Build/test gaps**  
  - `setup.py` still treats metallib outputs as static—no change detection or rebuild.  
  - `python3.13` triggers a `fast_data_types` segfault in this sandbox, preventing execution of the ctypes suite (new tests included but unsatisfied).

---

## Detailed Roadmap
1. **Tooling & Packaging**  
   - Add timestamp/hash tracking in `setup.py` so `kitty/metal/cell.metallib` rebuilds when `.metal` sources change.  
   - Ensure regenerated metallib is packaged in wheels/app bundles and add runtime version stamping/mismatch warnings.
2. **Runtime Stability**  
   - Investigate `fast_data_types` crash under Python 3.13 (align wheel build, guard with informative error, or enforce supported interpreter).  
   - Once stable, rerun `python3.13 test.py --module test_metal_helpers` to exercise the new draw-flag tests.
3. **Validation Enhancements**  
   - Extend ctypes coverage to any remaining overlay helpers (scrollbar metrics, hyperlink bars) when runtime permits.  
   - Consider automated GL↔Metal image diff harness after overlay parity is confirmed.
4. **Logging & Fallback Review**  
   - Audit new codepaths for `metal_log` spam.  
   - Verify `metal_record_failure` clears all pipeline references (graphics, premult, alpha) after recent additions.

---

## Known Issues / TODO Anchors
- Metallib rebuild automation pending.  
- `fast_data_types` segfault persists under Python 3.13 (blocks Metal ctypes tests in this environment).  
- Need to document minimum supported Python version/interpreter expectations for contributors until crash resolved.

---

## Quick Reference
- Cell pass helper: `metal_apply_draw_flags` (`kitty/metal_renderer.m`).  
- Renderer pass sequencing: `metal_render_pass_for_render_data`.  
- Graphics encoders: `metal_encode_graphics_bucket`, `metal_encode_graphics_alpha_bucket`.  
- Test hooks: `kitty_tests/test_metal_helpers.py` (now includes draw flag + graphics uniform coverage).  
- Metal shaders: `kitty/metal/cell.metal`.

Keep this memo current after each substantive Metal renderer change so future sessions resume with minimal rediscovery.
