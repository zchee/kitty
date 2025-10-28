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

### 9. Metal background tint GUI tests (2025-10-28 snapshot)
* **Current blockers:** running `KITTY_ENABLE_METAL_GUI_TESTS=1 ./.venv/bin/python3.13 ./test.py --module test_metal_helpers` still crashes with `EXC_BAD_ACCESS`/segfault during teardown; direct invocation of `TestMetalBackgroundTintRendering.test_background_tint_captures_multiple_combinations()` inside a single test instance now succeeds.
* **Root-cause eliminated:** initial crash came from calling `fast_data_types.create_os_window` before GLFW initialization. The test fixture must call `fast_data_types.glfw_init(glfw_path("cocoa"), edge_spacing, ...)` and seed fonts via `set_font_family()` before creating Metal windows. Restoring `supports_window_occlusion()` after the tests prevents leaking global state.
* **Remaining hypothesis:** the full module segfault happens when Python unloads, likely due to repeated GLFW/Metal shutdown paths (suspect `glfw_terminate` and `free_font_data` interactions). We temporarily avoid `glfw_terminate` in the fixture; need structured shutdown sequencing or a reference-counted init/teardown in fast_data_types.
* **Regression expectations:** capture diffs now assert that the configured dominant channel remains strongest after tinting (rather than clamping to absolute maximum). Baseline/tint comparison data for 0x006400, 0x002874, 0x8A1B10 collected; see terminal capture from 2025-10-28 if further tuning needed.
* **Next actions:**
  - Inspect macOS crash reports (`~/Library/Logs/DiagnosticReports/`) to confirm teardown frame (look for font/GLFW cleanup symbol).
  - Audit Metal test fixture cleanup to ensure `renderer_backend_shutdown_active()` runs, and track outstanding windows via `state_debug_add_os_window_for_tests` vs `remove_os_window` pairs.
  - Consider gating Metal GUI tests behind single-process harness to avoid repeated init/terminate until cleanup ordering is fixed.
