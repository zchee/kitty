## Kitty Metal Renderer Knowledge Base (updated 2025-10-29)

Authoritative playbook for diagnosing and fixing Metal rendering issues in kitty on macOS. This supersedes all earlier guidance—always follow these steps first.

---

### 1. Reproduction Checklist
1. Launch kitty with Metal debug logging enabled:  
   ```bash
   KITTY_ENABLE_METAL_GUI_TESTS=1 ./kitty.app/Contents/MacOS/kitty --debug-rendering 2>kitty-metal.log
   ```
2. When the bug concerns background tint or first-frame artifacts, ensure no background image is configured so the fallback tint path is exercised.
3. Capture a screenshot immediately after launch; compare for alternating stripes or unexpected colors.

---

### 2. Immediate Data Collection
1. Save `kitty-metal.log` alongside the screenshot; this log contains window geometry, drawable acquisition, and swap diagnostics.
2. Record the exact command line, git commit, and macOS build (run `sw_vers -productVersion`).
3. Archive relevant Metal capture data if `--metal-gpu-capture` was enabled; note whether command buffers finished (`waitUntilCompleted` vs `waitUntilScheduled`).

---

### 3. Diagnostic Workflow
1. Inspect `kitty-metal.log` for occlusion events or repeated drawable acquisition failures (`metal_event=drawable_acquire_failed`).
2. Use `rg --threads=6` to locate the active Metal pipeline in `kitty/metal_renderer.m`; prioritise passes that set `pass.colorAttachments[0].loadAction`.
3. Compare Metal pass ordering against OpenGL implementation (see `kitty/shaders.c`) to verify parity in clear/load semantics.
4. When investigating tint issues, focus on `metal_encode_background_tint` and confirm that the first frame clears the drawable when `frameHasContent` is false.

---

### 4. Known Fix Patterns
* **First-frame stripes without background image**: ensure tint pass sets `loadAction` to `MTLLoadActionClear` when no prior content exists (`state.frameHasContent == NO`).
* **Persistent dirty captures**: after every presentation, reset command primitives (`state.commandBuffer = nil; state.drawable = nil; state.frameHasContent = NO;`).
* **Sprite atlas corruption**: zero shared buffers via `metal_zero_buffer` whenever the allocation grows.

---

### 5. Regression Tests (Python 3.14)
All Metal tests must run under `.venv/bin/python3.14`.
1. Full module:
   ```bash
   KITTY_ENABLE_METAL_GUI_TESTS=1 ./.venv/bin/python3.14 ./test.py --module test_metal_helpers --verbose --failfast
   ```
2. Targeted regression:
   ```bash
   KITTY_ENABLE_METAL_GUI_TESTS=1 ./.venv/bin/python3.14 ./test.py \
     test_metal_helpers.TestMetalTintRendering.test_background_tint_without_image_uses_clear_load_action --verbose
   ```
3. If the environment lacks a Metal-capable display (common on CI), document the failure and request rerun on macOS hardware. Never mark the test as skipped locally without analysing the root cause.

---

### 6. Metal Debugging Tools
* Enable verbose event logging through renderer configuration (`global_state.debug_metal_events = True`).
* Use `metal_renderer_debug_*` helpers exposed via `kitty_tests.test_metal_helpers` for seeding window state, capturing frames, and validating buffer contents.
* For shader parity research, cross-reference `kitty/metal/cell.metal` with the corresponding GLSL definitions and keep `shader_metadata.json` in sync.

---

### 7. Step-by-Step Incident Response
1. Reproduce with `--debug-rendering`; capture log + screenshot.
2. Run regression tests listed above.
3. If tests fail, prioritise fixing `kitty/metal_renderer.m` before touching Python callers to avoid API drift.
4. After code changes, rerun the targeted test and confirm `kitty-metal.log` is regenerated.
5. Update this document if the workflow materially changes (new commands, logging flags, or modules).

---

### 8. Future Enhancements Backlog
1. Teach `kitty_tests/test_metal_helpers` to dump per-pass load actions, catching regressions earlier.
2. Add automated diffing between Metal and OpenGL frame captures for first-frame draw.
3. Expand capture helpers to assert `frameHasContent` transitions after every pass.
4. Investigate headless Metal CI runners or fallback simulation to unblock automated test execution.

---

### 9. Metal background tint GUI tests (2025-10-29 snapshot)
* **Current status:** `KITTY_ENABLE_METAL_GUI_TESTS=1 python3.13 ./test.py --module test_metal_helpers` now completes without crashes; tint coverage assertions pass for all backgrounds (0x006400, 0x002874, 0x8A1B10).
* **Root cause resolved:** `pyset_background_image` dereferenced a NULL layout string when no background image was configured, and the Metal path skipped tinting entirely when no texture existed. Guarding the layout check and allowing `metal_encode_background` to execute the tint-only path removed the teardown segfault.
* **Regression commands run (Oct 29 2025):**
  - `KITTY_ENABLE_METAL_GUI_TESTS=1 python3.13 ./test.py --module test_metal_helpers`
  - `KITTY_ENABLE_METAL_GUI_TESTS=1 python3.13 ./test.py --module test_metal_helpers background_tint_without_image_uses_clear_load_action`
* **Implementation roadmap:** mirror the fixes into any Python 3.14 build and schedule a full `.venv/bin/python3.14 ./test.py --module test_metal_helpers --verbose --failfast` run when Metal hardware is available; consider adding a regression to ensure layout-less calls remain safe.
* **Known risks:** broader regression suite has not yet been exercised post-fix (only Metal helper module); keep an eye on background image hot reload paths that may still assume layout strings are present.
