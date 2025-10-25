# Renderer & Backend Knowledge Base (Updated 2025-10-25)

Authoritative snapshot of the macOS Metal migration, OpenGL stubs, and gating issues. Refresh this file whenever policy, behaviour, or test expectations change.

---

## Platform & Backend Policy

- **macOS (Darwin) ships Metal-only.** Build scripts define `KITTY_DISABLE_NSGL=1`, drop `-framework OpenGL`, and exclude NSGL source files. OpenGL symbols remain available only via stub object files.
- Attempting to register or select the OpenGL backend on macOS must raise a descriptive `RuntimeError`/`ValueError`. Tests `TestRendererBackend.test_macos_register_opengl_backend_returns_false` and `test_macos_rejects_opengl_selection` enforce this.
- Non-macOS builds continue to provide the full OpenGL backend; cross-platform behaviour remains unchanged and must be validated by existing tests.

---

## Current Implementation State (Metal Phase 2)

- **Shared shader metadata:** New header `kitty/shader_shared.h` centralises shader program IDs, GL constants, and exported helper method lists. The OpenGL implementation (`shaders.c`) and the Metal/OpenGL stubs now pull definitions from the same source.
- **OpenGL stubs aligned:** `kitty/opengl_disabled.c` exports the same constants and stubbed helpers as the legacy OpenGL module, raising structured `RuntimeError`s when invoked on macOS.
- **Metal tests expanded:** Added `kitty_tests/test_opengl_disabled.py` to ensure shader program constants are present via `fast_data_types` and that stub helpers fail loudly when OpenGL is disabled.
- **OpenGL registration guard returns cleanly:** macOS implementation of `register_opengl_renderer_backend` now reports `False` without surfacing a Python exception, and exposes `opengl_renderer_disabled_reason()` so ctypes callers can fetch the message.

---

## Known Regressions / Open Issues

1. **Metal feature completeness (OPEN):**
   - Sprite uploads, blank canvas handling, and layered rendering still rely on placeholder Metal implementations. Full parity with OpenGL not yet reached.

2. **fast_data_types parity guard (WATCH):**
   - Although shared headers align constants today, any addition to `shaders.c` requires corresponding updates to the shared header and stub exporters. Add regression coverage when new exports appear.

---

## Immediate Roadmap

1. **Harden minimal macOS bundle tooling:**
   - Monitor the new `Resources/kitty` development symlink for regressions; add follow-up coverage if additional assets (fonts, shell integration) require inclusion.

2. **Metal renderer functionality parity:**
   - Incrementally replace remaining no-op Metal paths (`blank_os_window`, `screen_needs_rendering_in_layers`, sprite atlas management).
   - Ensure Metal resource creation/destroy hooks match OpenGL semantics and add regression tests where feasible.

---

## Longer-Term Backlog

- Implement Metal sprite atlas growth & eviction mirroring OpenGL behaviour, with unit/integration coverage.
- Provide remote-control toggles and logging hooks for Metal GPU capture/debug (parity with OpenGL debug flags).
- Develop automated visual-diff tooling comparing Metal output to archived OpenGL frames.
- Bring Metal-capable CI runners online; cache metallib outputs for faster builds.

---

## Operational Notes

 - After any change to renderer C/ObjC sources, rebuild via `./.venv/bin/python3.13 setup.py build` and rerun targeted tests to ensure the developer bundle stays healthy.
- Keep error messaging in `renderer_backend_select()` and registration paths in sync with test expectations; macOS-specific strings are asserted in the test suite.
- When adding new shader programs or GL constants, update `kitty/shader_shared.h`, both backends, and tests simultaneously to keep parity.
