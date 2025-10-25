# Renderer & Backend Knowledge Base (Updated 2025-10-25 – Metal migration in progress)

This file captures the authoritative status of the Metal port, outstanding gaps, and the agreed path forward. Update whenever behaviour, build policy, or testing expectations change.

---

## Platform & Backend Policy

- **macOS is Metal-only at build time and runtime.** `setup.py` no longer links `-framework OpenGL` on Darwin, defines `KITTY_DISABLE_NSGL=1`, excludes OpenGL sources, and adds a Metal stub translation unit that supplies no-op OpenGL APIs to satisfy fast-data-types symbols.
- Registering or selecting the OpenGL backend on macOS hard-fails with a descriptive `RuntimeError`/`ValueError`. Tests `test_macos_register_opengl_backend_returns_false` and `test_macos_rejects_opengl_selection` assert this behaviour.
- Non-macOS platforms continue to ship the OpenGL backend. Cross-platform registry behaviour is unchanged, and tests must confirm OpenGL remains selectable where supported.

---

## Current Implementation State (Metal Phase 2)

- GLFW’s NSGL path is stubbed behind `KITTY_DISABLE_NSGL`, ensuring no Objective‑C OpenGL contexts are created when building for Metal.
- `kitty/state.c`, `kitty/fonts.c`, and dependent helpers avoid VAO/TBO manipulation when Metal is active, preventing unused OpenGL code from running on macOS.
- `kitty/opengl_renderer.c` now compiles to a minimal stub on macOS; the full backend remains available elsewhere.
- New Python unit test (`KittyEnvMetalTests.test_kitty_env_drops_opengl_framework`) validates that the build script omits the OpenGL framework while retaining Metal linkage.
- Renderer backend Python tests assert macOS-only failure modes for the OpenGL backend.

---

## Known Regressions / Outstanding Work

1. **Launcher Packaging Failure**
   - `./.venv/bin/python3.13 setup.py build` currently aborts during the app bundle phase: `kitty/launcher/kitty.app/Contents/Resources/kitty` is missing.
   - Action: Decide whether to restore the resource packaging step for Metal builds or conditionally skip app bundling during CLI-driven builds. Owner TBD.

2. **fast_data_types Shader Constants**
   - The Metal stub (`opengl_disabled.c`) now supplies no-op exports, but we must ensure every symbol expected by `kitty.fast_data_types` is implemented. Initial build failures cited missing GLSL program constants; confirm the stub exports remain exhaustive after future changes.
   - Action: Maintain parity between stub exports and the real OpenGL module. Add regression coverage if additional constants are introduced.

3. **Renderer Tests**
   - `./.venv/bin/python3.13 test.py --module renderer_backend` currently fails because `kitty.fast_data_types` lacks certain shader constants when OpenGL is stubbed. Need to reconcile stubbed constants with test expectations or gate the imports on macOS.

4. **Metal Feature Completeness**
   - Sprite uploads, blanking, and layered rendering are stubbed out in the Metal-only build. Implement Metal-native equivalents before enabling full macOS packaging.

---

## Immediate Roadmap

1. **fast_data_types parity**
   - Audit `kitty/shaders.c` exports vs. `kitty/opengl_disabled.c` stubs; add any missing constants/functions to prevent ImportError on macOS.
   - Extend renderer backend tests (or add new ones) to confirm stub exports exist when KITTY_DISABLE_NSGL is defined.

2. **Launcher build fix**
   - Determine minimal assets required for `kitty/launcher/kitty.app` during developer builds. Either restore packaging of `Resources/kitty` under Metal or gate the launcher build behind an explicit flag when not producing a distributable bundle.

3. **Re-enable renderer_backend test module**
   - Once stub exports are complete, rerun `test.py --module renderer_backend` and ensure it passes on macOS, skipping OpenGL-specific cases gracefully.

4. **Metal renderer functionality**
   - Replace no-op implementations (e.g., `blank_os_window`, `screen_needs_rendering_in_layers`) with real Metal versions as the port progresses.
   - Track shader-program parity and resource lifecycle (CAMetalLayer, pipelines) against the OpenGL reference.

---

## Longer-Term Backlog

- Integrate Metal sprite atlas growth/eviction logic and add parity tests against legacy OpenGL behaviour.
- Provide remote-control toggles for Metal debug logging and GPU capture.
- Build visual diff infrastructure comparing Metal output to archived OpenGL frames.
- Add CI runners with Metal capability; cache metallib artifacts for incremental builds.

---

## Operational Notes

- After editing renderer C/ObjC sources, always rebuild via `./.venv/bin/python3.13 setup.py build` and re-run targeted tests.
- Keep `renderer_backend_select()` error messaging synchronized with tests; macOS-specific messaging is asserted.
- Prefer existing debug helpers (`state_debug_*`, Metal debug APIs) when writing new tests that touch renderer state.
