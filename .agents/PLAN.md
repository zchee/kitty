# Metal Migration Status — Detailed (2025-11-06)

## Current Knowledge
- Metal backend now covers surface creation, atlas management, buffer staging, and the primary text grid draw loop; OpenGL still handles layered effects (background tint, logos, borders).
- Uniform preparation is centralized in `populate_cell_uniforms`, ensuring GL and Metal consume identical layout data and color tables.
- Render orchestration branches early in `render_os_window`, invoking `metal_begin_frame`, shared buffer prep, and `metal_draw_cells`, which binds Metal pipeline states and issues instanced draws.
- Resource lifetimes: `MetalSurfaceState` owns reusable cell/selection/uniform buffers, cached samplers, and retains an encoder per frame; cleanup handles encoder/buffer release to avoid leaks.

## Implementation Roadmap
1. **Backend-Neutral API Layer**
   - Refactor Python/C bindings (`fast_data_types`, shaders module) to call backend-agnostic hooks for buffer prep and draw submission.
   - Expose Metal/GL implementations through a shared dispatch table, removing ad-hoc backend checks in higher-level code.

2. **Diagnostics & Robustness**
   - Instrument Metal begin/end frame paths with logging for drawable acquisition, command buffer errors, and pipeline failures.
   - Consider surfacing fallback paths or warnings when Metal resources are unavailable.

3. **Testing & CI Enablement**
   - Build a headless Metal smoke test that renders a small grid offscreen and validates output (hash/pixel comparison).
   - Extend existing test harness to run key suites under `KITTY_GPU_BACKEND=metal` on macOS runners.

4. **Layered Rendering Parity**
   - Port background tint, window logos, border drawing, and cursor trails to Metal.
   - Abstract GL-centric helpers (`draw_borders`, `draw_window_logo`, tint pipeline) so Metal can reuse logic or provide equivalents.

5. **Documentation & Communication**
   - Update `docs/metal_migration_design_doc.md` with completed milestones, current capabilities, and remaining gaps.
   - Prepare notes for maintainers describing migration progress, testing requirements, and risk areas.

## Next Actions
- Prototype backend-neutral binding layer and update Python callers.
- Add Metal logging around resource allocation and frame submission.
- Draft initial Metal smoke test harness.
- Document current Metal coverage and TODOs in the design doc.

## Open Risks / Considerations
- CI availability of Metal-capable hardware is required for automated tests.
- Uniform buffer alignment and synchronization must remain correct when additional passes (layered rendering) are introduced.
- Need to ensure fallback behavior when users force Metal on unsupported systems.

## Saved Timestamp
- 2025-11-06
