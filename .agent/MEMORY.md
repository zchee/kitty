# Metal Renderer Execution Memory
_Last updated: 2025-10-16_

Canonical scratchpad for the macOS Metal bring-up. Always overwrite this file with the latest truth—do **not** append.

---

## Guardrails
1. Obey repository rules: no duplication, no dead code, no mocks, no over-engineering, no resource leaks, consistent naming, ASCII-only unless pre-existing data uses Unicode.
2. Error-handling policy: fail fast on critical configuration / backend init, log-and-continue for optional features, gracefully degrade on external service loss, surface friendly messages through the resilience layer.
3. Every new or refactored function ships with real (non-cheating) tests that execute production pathways.
4. Deliver complete increments—no TODO placeholders or partial implementations.
5. Favour existing helpers; audit relevant modules before introducing new utilities.

---

## Current Snapshot (2025-10-16)
- OpenGL backend is feature-complete and the active default.
- Metal backend now consumes `renderer_shared` frame prep to drive background clears and stages cell/selection data in CPU buffers, but still lacks cell/decorations rendering.
- `renderer_shared_prepare_frame` is implemented in shared C and feeds both GLSL and Metal, returning default background metadata for parity decisions.
- Build system lacks metallib compilation and Metal-specific packaging steps.
- Renderer backend test harness now exposes safe C helpers (`renderer_backend_register_stub_for_tests`, `renderer_backend_render_for_tests`, `renderer_backend_present_for_tests`), resolving prior Python 3.13 ctypes segfaults.

---

## Completed to Date
- ✅ Reworked renderer-backend test infrastructure to avoid null function-pointer registration via ctypes; Python unit tests now pass without segfaults.
- ✅ Centralised shared renderer frame preparation (`renderer_shared.c`), refactoring OpenGL to use the helpers and wiring Metal to capture shared buffers for future pipelines while matching OpenGL background colours.

---

## Implementation Roadmap

### Reliability Gate (Week 0)
- [x] Stabilise renderer backend tests (segfault fix via native helpers).
- [ ] Clean any experimental shader changes and rebaseline OpenGL rendering outputs.
- [ ] Capture reference render traces on macOS (OpenGL) and Linux for future Metal diffs.

### Phase 1 – Shared Infrastructure (Weeks 1-3)
- Finalise `RendererBackendOps` invariants and document lifecycle expectations (begin/render/present semantics, resize handling, error propagation).
- [x] Land `renderer_shared` buffer-management helpers (typed mapping/unmapping, lifetime guarantees) with strict tests.
- [x] Refactor OpenGL backend to consume `renderer_shared` outputs without behavioural change.
- Introduce renderer preference plumbing (`auto|metal|opengl`) in options/CLI, including persistence and tests.

### Phase 2 – Metal Core Skeleton (Weeks 3-5)
- Implement Metal device/queue/swapchain setup, command-buffer lifecycle, and CAMetalLayer management.
- Integrate presentation pacing (CVDisplayLink or equivalent) respecting low-latency preferences.
- Extend `setup.py` to compile `.metal` sources into metallib artefacts; ensure frameworks (`Metal`, `MetalKit`, `QuartzCore`) are linked for macOS builds.
- Add smoke tests covering Metal preflight success/failure and backend selection fallback.

### Phase 3 – Cell & Text Rendering (Weeks 5-9)
- Translate GLSL shaders (cell, bg, cursor) to MSL or build a translation pipeline.
- Establish Metal pipeline state cache mirroring GLSL uniform layouts.
- Map `renderer_shared` buffers into `MTLBuffer`s with proper synchronisation (managed vs shared storage).
- Build image-diff harness comparing Metal and OpenGL outputs for canonical traces.

### Phase 4 – Decorations & UI (Weeks 9-12)
- Implement underline/strike sprites, cursor variants, selections, tab bar, borders, rounded-rect, tint, visual bell, scrollbar, hyperlink highlighting.
- Support background image compositing and indirect framebuffer path (`needs_layers`).

### Phase 5 – Graphics Protocol & Capture (Weeks 12-14)
- Port graphics protocol texture uploads, alpha-mask shaders, and blit pipelines.
- Implement framebuffer capture/screenshot flows with parity to OpenGL.
- Add regression tests covering Metal rendering of graphics uploads and capture API.

### Phase 6 – Hardening & Release (Weeks 14-16)
- Perform Metal System Trace profiling, memory-leak audits, resize stress tests.
- Update documentation, CLI help, changelog, and fallback guidance.
- Ensure `auto` preference defaults to Metal on macOS 13+ with reliable fallback to OpenGL on failure.

---

## Cross-Cutting Needs
- **Testing/CI:** Provision macOS (Apple Silicon + Intel) runners with Metal support; expand `kitty_tests/renderer_backend.py` and future integration tests to exercise Metal paths; integrate image-diff tooling once rendering parity exists.
- **Tooling:** Metallib caching strategy, shader translation workflow, structured logging via `metal_log`.
- **Tooling:** Python 3.13 toolchain verified for building `fast_data_types` and running renderer shared-unit tests.
- **Ownership:** Assign leads for shared infra, Metal rendering, build/CI, QA automation; maintain weekly status updates here.
- **Risk Mitigation:** Maintain documented `--renderer-backend` toggle; instrument robust fallback to OpenGL on runtime errors; monitor post-release telemetry.

---

## Immediate Next Actions
1. Rebaseline OpenGL shaders/render outputs and remove lingering experimental edits.
2. Capture baseline render traces/screenshots (OpenGL) on macOS and Linux for future Metal comparison.
3. Draft and circulate `renderer_shared` API specification detailing buffer contracts and Metal consumption expectations.
4. Decide on shader translation approach (manual MSL port vs automated pipeline) and outline supporting tooling requirements.

---

## Testing Coverage
- Python: `python3.13 -m unittest kitty_tests.renderer_backend` (now stable).
- Future: add Metal-specific integration tests once rendering is implemented.
