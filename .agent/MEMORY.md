# Metal Renderer Migration Playbook (Updated 2025-10-22)

This file is the authoritative state of the Metal bring-up. After each major milestone, overwrite it completely with the new ground truth.

---

## Current Build & Runtime Status

- ✅ `python3.13 setup.py build` succeeds on macOS by auto-linking `PythonT.framework` whenever headers indicate `Py_GIL_DISABLED`. The logic lives in `kitty/python_build_helpers.py` and is consumed by `setup.py:get_python_flags`.
- ✅ Metal shader structures (`MetalTrailUniforms`, `MetalGraphicsUniforms`, `MetalGraphicsAlphaUniforms`) are layout-checked between MSL and Objective-C.
- ✅ Background, graphics, visual-bell, scrollbar, hyperlink, and window-number passes encode through the Metal backend with shared draw params and sampler caching.
- ✅ `kitty/metal/cell.metallib` is regenerated manually via `xcrun metal` + `xcrun metallib` (automation still pending).
- ⚠️ `python3.13 -m unittest` currently segfaults on this environment; test execution must use a stable interpreter or container until resolved.
- ⚠️ `kitty_tests/test_metal_helpers` remains skipped because the module still assumes an OpenGL-linked shared object. Needs reactivation now that the Metal shared library links.
- ⚠️ Metallib build is manual: stale binaries remain a risk until scripted.

---

## Immediate Engineering Roadmap

1. **Automate metallib generation**
   - Add build steps (likely in `setup.py`) to run:
     ```
     xcrun metal -c kitty/metal/cell.metal -o build/metal/cell.air -mmacosx-version-min=13.0
     xcrun metallib build/metal/cell.air -o kitty/metal/cell.metallib
     ```
   - Track dependencies so regeneration happens when sources change.
   - Fail the build if metallib timestamp predates its source.

2. **Restore Metal helper tests**
   - Ensure the rebuilt shared library loads for tests.
   - Expand coverage: sampler cache keying, `metal_compute_background_geometry`, capture helpers (BGRA/RGBA).
   - Investigate the Python 3.13 unittest crash; use alternative runtime if necessary to unblock testing.

3. **Audit capture & teardown paths**
   - Review `metal_backend_present`, `metal_capture_framebuffer`, `metal_finalize_capture`, shutdown handling.
   - Verify parity with OpenGL capture semantics and absence of leaks (textures, command buffers, capture storage).

4. **Windowing integration**
   - Confirm Cocoa layer creation (`CAMetalLayer`) is fully wired in `glfw/cocoa_window.m` and `metal_renderer.m`.
   - Ensure resize/content-scale notifications rebalance swapchain attachments.

5. **Resource lifetime review**
   - Double-check texture/sampler/buffer caches for proper release.
   - Verify no lingering autorelease pools or retained command encoders.

6. **Documentation & onboarding**
   - Update developer docs with Metal prerequisites: macOS 13+, `python3.13`, Xcode toolchain, metallib workflow.
   - Note known issues (unittest instability, pending capture audit) for the next engineer.

---

## Longer-Term Items

- Integrate metallib build into CI on macOS runners with Metal support.
- Add image-diff regression tests comparing OpenGL vs Metal output.
- Implement Metal-specific logging / profiling toggles (akin to OpenGL debug flags).
- Evaluate fallback logic between Metal and OpenGL backends once Metal achieves parity.

Maintain this checklist as the single source of truth for Metal migration progress. Update after every significant change.***
