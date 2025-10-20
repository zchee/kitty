# Metal Renderer Execution Memory
_Last updated: 2025-10-20 (Overlay roadmap rewrite, capture & lifecycle staging)_

Canonical working log for macOS Metal backend work. Treat this file as the single source of truth—rewrite it whenever major progress lands.

---

## Guardrails & Principles
1. **Feature parity before optimisations** – Metal rendering must match OpenGL visuals, timing, and behaviour before we even think about Metal-only tricks.
2. **Robust fallback** – any Metal init or runtime failure must log context, release state, and fall back to OpenGL cleanly without leaving mutated globals.
3. **Shared plumbing** – all high-level decisions flow through `renderer_shared`, `graphics.c`, and existing buffers. No duplicated overlay logic; extend shared helpers first.
4. **Tests per touchpoint** – every helper or pipeline we add ships with a targeted unit/integration test that would fail on regression (Metal + cross-backend diff where possible).
5. **Tight lifetimes** – acquire → encode → commit → release. Command buffers, drawables, textures, and observers must not leak between frames.
6. **Single shader source** – keep GLSL ↔ MSL aligned. Regenerate metallibs via build tooling; never hand-edit generated artifacts.
7. **House style** – follow kitty naming, strict typing, and minimal, self-evident code. Update stubs/type hints as we extend C APIs.
8. **Logging discipline** – lifecycle edges (drawable acquire, device loss, overlays) should emit structured logs or counters guarded by debug toggles.

---

## Current Capability Snapshot
- **Backend lifecycle** fully registered (init/attach/render/present/resize/upload/destroy) with OpenGL parity hooks.
- **Global state (`g_metal`)** tracks device, queue, shader library, pipelines (cell/border/trail/background/tint/graphics variants), atlas sampler, graphics texture caches, debug flags.
- **Window state** stores per-frame buffers, draw params, frame flags, and autorelease observers tied to `CAMetalLayer`.
- **Layered cell rendering** honours draw-flag sequencing for background/foreground buckets and graphics ranges matching OpenGL ordering.
- **Backgrounds & tint** share helpers for texture upload, sampler reuse, and background tint passes.
- **Visual bell** uses `renderer_shared_compute_visual_bell()` and the Metal tint pipeline for timing parity.
- **Graphics uploads** manage sampler cache keyed by repeat/filter and dispose textures via central registry.
- **Tests**: `kitty_tests.test_metal_helpers` covers draw-flag defaults, border/trail uniforms, visual-bell attenuation.

> Missing today: UI overlays (scrollbar, hyperlink bubble, window numbers), framebuffer capture, enhanced logging/diagnostics, cache eviction, metallib documentation.

---

## Immediate Priorities (P0)
1. **Overlay parity** – implement scrollbars, hyperlink bubble, window numbers on Metal using shared geometry helpers and new Metal pipelines.
2. **Shared helper expansion** – extend `renderer_shared` to compute overlay geometry/state so both backends stay in sync.
3. **Test coverage** – add Metal-specific ctypes hooks + Python tests for overlays (geometry, uniforms, failure paths).
4. **Documentation refresh** – capture metallib regeneration steps, required toolchains, and update this file after each milestone.

---

## Milestones & Tasks

### Milestone A – Overlay Feature Parity
- [ ] Extend `renderer_shared` with overlay structs (scrollbar geometry, prepared bars, window-number info, hyperlink sanitisation helper).
- [ ] Refactor OpenGL overlay code to consume the shared helpers (ensures single source of truth).
- [ ] Add Metal pipelines for tint + rounded-rect + alpha-mask overlays (reusing existing shaders where possible; add Metal rounded-rect shader if needed).
- [ ] Implement Metal overlay encoding sequence (scrollbar → hyperlink bar → window number) respecting draw order after visual bell.
- [ ] Write helper exports for Metal tests (scrollbar geometry, prepared bar, window number) and corresponding Python tests.

### Milestone B – Capture & Diagnostics
- [ ] Implement framebuffer capture via `MTLBlitCommandEncoder` to shared CPU buffer; expose through renderer backend API.
- [ ] Hook capture path into CLI/tests (e.g. screenshot diff harness) with fallback to OpenGL when unsupported.
- [ ] Wire `RendererInitConfig` debug toggles to enable GPU validation layers, command buffer debugging, and overlay logging.
- [ ] Add structured logging for drawable lifecycle, present timing, and overlay rendering (guarded behind debug flag).

### Milestone C – Resource Lifecycle & Tooling
- [ ] Track Metal texture memory consumption and enforce cache eviction/LRU for graphics/background textures; surface stats via diagnostics.
- [ ] Handle `CAMetalLayer` device loss, display sleep, and surface resize notifications gracefully with automatic resource rebuild.
- [ ] Document metallib regeneration (invocation, cache directories, packaging) and ensure build scripts fail fast if Xcode toolchain missing.
- [ ] Ensure metallib artifacts are included in app bundle + wheels with deterministic hashes.

### Milestone D – Testing & CI Expansion
- [ ] Add regression tests covering backend selection, overlay toggles, capture path, and failure fallback.
- [ ] Build image diff harness comparing Metal vs OpenGL frames for key scenarios (overlays, backgrounds, graphics).
- [ ] Extend CI matrix with macOS 13+ (Apple Silicon) runners executing Metal tests; archive metallibs and captured frames as artifacts.
- [ ] Update release checklist to verify both backends and metallib artifacts per platform.

---

## Supporting Work Items
- **Performance & latency**: evaluate swap interval handling vs. low-latency mode once overlays land; profile overlay command buffer costs.
- **Logging hooks**: add counters/metrics for overlay draw frequency, capture triggers, cache evictions.
- **Docs**: keep developer docs aligned (architecture page, README sections on Metal requirements).
- **Options exposure**: ensure new debug toggles/config values get CLI + config documentation automatically via generator.

---

## Testing Strategy
- Python: expand `kitty_tests.test_metal_helpers` (overlay geometry, bar prep, window number, capture fallbacks).
- Integration: capture-based diff tests once framebuffer capture exists.
- Cross-backend: ensure overlay helpers are exercised by OpenGL path to avoid divergence.
- CI gating: require Metal overlay tests on macOS runners before merging overlay work.

---

## CI & Tooling Notes
- Metallib regeneration must run as part of `setup.py` on macOS; cache compiled outputs in `build/` and bundle directories.
- CI jobs should upload metallibs + captured frames for triage, and fail loudly if Metal device unavailable.
- Keep fast path for developers: helper script to regenerate metallibs and run overlay test suite locally.

---

## Backlog Ledger
- [x] Draw-flag sequencing for layered cells + graphics.
- [x] Background image/tint parity via shared helpers.
- [x] Visual bell parity through Metal tint pass.
- [x] Graphics upload/destroy parity (sampler cache + cleanup).
- [ ] Overlay feature parity (scrollbar, hyperlink bubble, window numbers).
- [ ] Framebuffer capture & diagnostics plumbing.
- [ ] Texture cache eviction + instrumentation.
- [ ] Metallib tooling/CI updates + Metal-specific integration tests.
- [ ] Capture-based regression suite + diff harness.

---

## Update Triggers
- Complete overlay milestones, capture work, or resource lifecycle changes.
- Modify build tooling or metallib packaging.
- Add or adjust Metal-focused tests/CI lanes.
- Discover regressions or adjust guardrails; update this file immediately when priorities shift.
