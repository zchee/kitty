# Metal Backend Migration Playbook
_Last updated: 2025-10-21 (python3.13 link stalled at launcher step)_

This document is the canonical snapshot of what already works, what still breaks, and the exact next actions required to finish the Metal renderer bring-up. Treat it as source-of-truth for future sessions; overwrite it again after every major milestone.

---

## Current Understanding

### Build status
- ⚠️ `python3.13 setup.py build` compiles shaders, Objective-C, and C modules successfully, including the regenerated `kitty/metal/cell.metallib`. The link step fails when producing `launcher` because the Python 3.13 framework on this machine does not export `_Py_DecRefShared` / `_Py_MergeZeroLocalRefcount`.
- ✅ Metal shader struct layouts (`MetalTrailUniforms`, `MetalGraphicsUniforms`, `MetalGraphicsAlphaUniforms`) are now aligned across `cell.metal` and Objective-C, enforced with `_Static_assert` checks.
- ✅ `TextureRef` is exported unconditionally so Metal/OpenGL backends compile. `renderer_shared.c` unused-parameter warnings are silenced with `UNUSED`.
- ✅ Metal background textures, graphics textures, and helper pipelines compile after the assorted fixes. `kitty/metal/cell.metallib` at `kitty/metal/cell.metallib` is the freshly generated binary.
- ⚠️ `kitty_tests/test_metal_helpers` still skips everything because the shared library never links; once the Python symbols issue is solved the tests should exercise the helpers again.

### Behavioural snapshot
- Metal draw paths now encode background, graphics, visual-bell, scrollbar, hyperlink, and window-number passes using shared draw params and sampler caches. Property access on `MetalWindowState` avoids ivar privacy violations.
- Graphics uploads use plain Objective-C retain/release semantics (no ARC bridge macros) and keep the sampler cache keyed by repeat/linear filter.
- Metallib generation is manual (`xcrun metal` / `metallib`) and must be automated; stale binaries can silently regress behaviour.
- Capture helpers (`metal_renderer_copy_captured_frame_for_tests`, etc.) logically work but still rely on the yet-to-be-linked shared object for Python visibility.

---

## Immediate Roadmap

1. **Fix Python 3.13 linker symbols**
   - Investigate the macOS Python framework for `_Py_DecRefShared` and `_Py_MergeZeroLocalRefcount`.
   - Possible solutions: link against the correct `libpython3.13t.a` / `.dylib`, adjust `setup.py` to add `-undefined dynamic_lookup`, or vendor the CPython Objects/abstract refcount objects as the official build does.
   - Do not proceed to feature work until the launcher links cleanly.

2. **Automate metallib regeneration**
   - Add explicit build rules in `setup.py` or Makefile that call:
     ```
     xcrun metal -c kitty/metal/cell.metal -o build/metal/cell.air -mmacosx-version-min=13.0
     xcrun metallib build/metal/cell.air -o kitty/metal/cell.metallib
     ```
   - Ensure these commands run whenever `cell.metal` changes (dependency tracking).
   - Document the steps in developer docs, and add a validation step that fails the build if the metallib timestamp predates the shader source.

3. **Re-enable Metal helper tests**
   - Once the build produces the shared library, run `python3.13 test.py --module test_metal_helpers`.
   - Expand coverage:
     - Verify sampler cache repeat modes.
     - Confirm `metal_compute_background_geometry` edge cases.
     - Exercise capture helpers with BGRA and RGBA conversions.

4. **Audit capture & teardown paths**
   - Walk through `metal_backend_present`, `metal_capture_framebuffer`, `metal_finalize_capture`, and shutdown paths to ensure no leaks (buffers/textures, capture state).
   - Mirror OpenGL capture semantics, especially for screenshots and remote control features.

5. **Documentation / onboarding**
   - Update project docs with: minimum macOS (13+), `python3.13` requirement, metallib workflow, known skip conditions.
   - Summarise outstanding risks (Python link dependency, test skips) for the next engineer.

---

## Longer-Term Considerations

- Build automation: integrate Metal pipeline build into CI (macOS runner with Xcode toolchain).
- Parity tests: design an image-diff harness comparing Metal vs OpenGL output for regressions.
- Performance instrumentation: once functional, add toggles for Metal capture/logging akin to current OpenGL debug flags.

Keep this file authoritative. When any of the objectives above change status, overwrite this document with the new ground truth.***
