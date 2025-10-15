# Metal Renderer Execution Memory
_Last updated: 2025-10-15_

Canonical scratchpad for the macOS Metal bring-up. Always overwrite this file with the latest truth—no append-only notes.

---

## Guardrails
1. Follow repository rules: no duplication, no dead code, no mocks, no over-engineering, no resource leaks, consistent naming.
2. Error handling: fail fast on critical configuration and backend/device initialization; log-and-continue for optional features; gracefully degrade on external service failures; surface user-friendly messages via the resilience layer.
3. Every new or refactored function must ship with non-cheating tests that exercise the real execution path.
4. Ship only complete increments—leave no TODO placeholders or partial implementations.
5. Prefer reuse of existing helpers; audit relevant modules before introducing new utilities.

## Current Snapshot
- **Dispatcher exports** (`kitty/renderer_backend.{h,c}`, `kitty/data-types.c`, `kitty/fast_data_types.pyi`): Python now exposes `renderer_backend_current/select/backends_available`. Header and shared object use new `compiler.h`/`color_type.h` instead of `data-types.h` to minimize macro bleed.
- **Canonical backend names**: `renderer_backend_type_name` and `py_renderer_backends_available` now return stable enum-backed names (`opengl`, `metal`) while still accepting backend-specific aliases. Metal registration succeeds and `renderer_backend_select('metal')` works after stub registrations.
- **Metal backend logging** (`kitty/metal_renderer.m`): Structured log helper reports preflight failures, drawable acquisition issues, command buffer fallbacks, and present submissions when debug labels are enabled.
- **Build status**: `python3.13 setup.py build` completes successfully; new `fast_data_types.so` is generated.
- **Test status**:
  - `python3.13 -m unittest kitty_tests.renderer_backend` currently segfaults during `test_renderer_backend_present_missing_hook_sets_error` (likely stack corruption when nulling ctypes callbacks; needs investigation).
  - `python3.13 test.py` full suite fails early with Homebrew `python@3.13t` environment missing `_random` when spawning, and `TestRendererPreferenceOptions.test_metal_renderer_option_rejects_invalid_value` still passes unexpectedly (option parser not rejecting bogus value under unit harness).
- **Config plumbing**: `choices_for_metal_renderer` exists in generated options, but validation hook in tests still allows `'bogus'`; root cause pending (probable gap in `BaseTest.set_options` helper or enum handling).
- **Infrastructure**: No `.metal` shader toolchain yet; Metal backend still limited to clear-present loop (no draw parity).

## Immediate Priorities
1. **Stabilise renderer backend tests**
   - Debug ctypes segfault in `kitty_tests.renderer_backend` when registering stubs with `None` callbacks. Confirm `ctypes.cast(None, CFUNCTYPE)` across all optional hooks and ensure C side guards against null pointers.
   - Re-run targeted suite after fix.
2. **Option validation parity**
   - Trace `TestRendererPreferenceOptions.test_metal_renderer_option_rejects_invalid_value` failure path; ensure `set_options` enforces `choices_for_metal_renderer` and raises `ValueError` for invalid inputs.
3. **Documented Metal preference behaviour**
   - Update user-facing docs once validation and dispatcher exports are stable (defer until tests green).
4. **End-to-end test strategy**
   - Resolve environment dependency for `_random` in spawned interpreter (`python@3.13t`); either document requirement or adjust test harness to avoid mixing frameworks.

## Roadmap
### Phase 1 – Backend Abstraction Completion (in progress)
- ✅ Dispatcher now exposes backend state to Python with canonical naming.
- ☐ Split GL-only helpers out of common units to reduce coupling (pending).
- ☐ Ensure window lifecycle exclusively uses `renderer_backend_*` hooks (audit outstanding call sites).
**Exit criteria**: `python3.13 -m unittest kitty_tests.renderer_backend` passes without segfaults; GL helpers isolated.

### Phase 2 – Metal Bootstrap (polishing)
- ✅ Metal backend initialisation, swap control, suspend/resume, logging instrumentation.
- ☐ Expand beyond clear-present loop (deferred to Phase 3).

### Phase 3 – Metal Feature Parity (pending)
- GLSL → MSL translation and metallib build integration.
- Backend-neutral render graph, resource management, graphics protocol parity, UI features (cursor trail, background images, scrollbars).
- Visual regression and stress testing across both backends.

### Phase 4 – Performance & Robustness (pending)
- Profiling with Metal System Trace; tune command scheduling.
- Device loss handling, display sleep/app nap resilience.
- Telemetry for stalls/memory pressure; long-duration soak tests.

## Risks & Mitigations
| Risk | Impact | Mitigation |
| --- | --- | --- |
| Segfaults in renderer backend unit tests | Blocks automation, indicates ABI issues | Audit ctypes callback handling, add null-guard shims in C, add explicit regression test |
| Metal option validation gap | Incorrect configs accepted silently | Trace `set_options` path, enforce enums, add targeted unit test |
| Missing `_random` in spawned interpreter | `kitty_tests.tui` spawn test fails on macOS setup | Align test runner Python with build Python, document dependency, or adjust test to avoid mixing frameworks |
| Lack of metallib pipeline | Metal backend cannot progress past clear-pass | Plan build integration in Phase 3, evaluate `metal`/`metallib` invocation |
| Cocoa/Metal resource churn | Potential leaks or stale drawables | Maintain state cleanup on window destroy; keep logging in place and add leak checks |

## File Map
- Dispatcher core & exports: `kitty/renderer_backend.{h,c}`, `kitty/data-types.c`, `kitty/compiler.h`, `kitty/color_type.h`
- Metal backend: `kitty/metal_renderer.m`
- OpenGL backend reference: `kitty/opengl_renderer.c`, `kitty/opengl_renderer_priv.h`
- Window glue: `kitty/glfw.c`, `glfw/cocoa_window.m`, `glfw/nsgl_context.m`
- Tests: `kitty_tests/renderer_backend.py`, `kitty_tests/options.py`
- Docs: `docs/metal_renderer_architecture.md`
- Build tooling: `setup.py`, `Makefile`

## Working Protocol
1. Re-read this file and `docs/metal_renderer_architecture.md` before coding.
2. After meaningful progress, overwrite this file with updated truths (no append-only edits).
3. Record new risks, decisions, or environment changes immediately.
4. Keep roadmap statuses and immediate priorities current—retire completed items promptly.
5. Document failing commands and resolutions to avoid rediscovery.
