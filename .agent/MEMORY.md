# Renderer & Backend Knowledge Base (Updated 2025-10-24)

This file tracks the authoritative state of kitty’s renderer architecture, current stability, and forthcoming work. Update it whenever implementation or testing commitments change materially.

---

## Platform & Backend Policy

- **macOS runs Metal only.** The OpenGL backend is no longer registered or selectable on macOS. `register_opengl_renderer_backend()` hard-fails under `__APPLE__`, and `renderer_backend_select()` rejects `opengl` with a macOS-specific error.
- Linux/other UNIX platforms continue to ship OpenGL. The pluggable backend registry remains intact for cross-platform builds.
- Backend selection always emits `state_on_renderer_backend_selected()` to rehydrate VAO state when switching away from Metal (mainly for non-macOS tests).
- `renderer_backend_type_from_name()` resolves both canonical names and backend-provided aliases so user-facing error messages remain descriptive after the policy change.

---

## Stability Fixes (2025-10-25)

- `send_cell_data_to_gpu()` now returns early when passed a null `Screen*` or `OSWindow*`, closing the crash in `render_os_window` when Metal state is converted to OpenGL structures for tests.
- `prepare_to_render_os_window()` re-fetches `tab_bar_render_data.screen` after the boss callback repopulates layout. This prevents stale pointers from being uploaded.
- Added `state_debug_upload_tab_bar_for_tests()` so tests can explicitly exercise tab-bar uploads without hand-building VAOs.
- Renderer backend tests expanded with `test_tab_bar_upload_without_screen_returns_false`, `test_macos_reports_only_metal_backend`, and `test_macos_rejects_opengl_selection` to guard the new behaviour.
- Full rebuild via `./.venv/bin/python3.13 setup.py build` followed by `./.venv/bin/python3.13 test.py --module renderer_backend` verifies the crash fix and macOS-only backend policy.

---

## Current Testing Status

- `test.py --module renderer_backend` (post-change) passes on macOS, with Metal-only tests running and OpenGL-focused ones auto-skipping due to backend absence.
- Tab-bar upload helper test skips when both backends are unavailable (e.g., CI hosts without Metal).
- Additional suites to monitor: `test_metal_*`, `test_glfw`, renderer integration tests.

---

## Active Implementation Roadmap

1. **Metal Stability**
   - Keep collecting crash reports around interpreter imports (`kitty.conf.utils`). Owner TBD.
   - Expand automated coverage for Metal sprite atlas growth/eviction parity with legacy OpenGL.

2. **Renderer Cleanup**
   - Remove any lingering macOS code paths that assume OpenGL contexts (window sharing hints, etc.).
   - Evaluate whether to compile the OpenGL backend at all on macOS, or guard entire translation units with `#ifndef __APPLE__` to reduce binary size further.

3. **Testing Enhancements**
   - Add regression tests ensuring renderer backend lists are platform-appropriate (Metal-only macOS; OpenGL on others).
   - Introduce headless validation that launching the app without a GUI emits a friendly error instead of crashing.

4. **Tooling & CI**
   - Provide Metal-enabled macOS runners in CI; cache metallib artifacts to shorten incremental builds.
   - Investigate headless smoke tests using `open -n kitty.app` with automation for GUI availability.

---

## Longer-Term Backlog

- Remote-control toggles for Metal debug logging and GPU capture.
- Visual diff harness comparing Metal output against historical OpenGL captures once fixtures stabilize.
- Metal runtime telemetry (frame pacing, capture success) exported via debug commands.
- Continuous stress tests for capture buffers and sprite atlas rebuilds.

---

## Operational Notes

- Keep `renderer_backend_select()` code in sync with tests; macOS policy relies on ValueError text for user-facing messaging.
- When adding new tests that touch renderer state, prefer the existing debug helpers (`state_debug_*`) instead of bespoke ctypes plumbing.
- Always rebuild C extensions (`setup.py build`) after touching renderer C files, then rerun focused tests before committing.

