# Metal Migration Roadmap — Detailed

## Current Knowledge
- **Rendering state**: Metal backend now handles glyph atlas creation, sprite uploads, instanced text rendering, and integrates with the main event loop. OpenGL still powers layered content (tab bar, background tint, borders, logos).
- **Shared data flow**: `populate_cell_uniforms` produces the uniform payload used by both GL and Metal. Buffer staging for cells and selection masks relies on `CellBufferWriters`, allowing either backend to supply GPU memory.
- **Command encoding**: `metal_draw_cells` binds cell, selection, and uniform buffers; sets atlas textures/samplers; and issues `drawPrimitives` with the prebuilt pipeline states. `render_os_window` now branches into a Metal-specific path that mirrors GL’s orchestration.
- **Resource management**: `MetalSurfaceState` owns reusable `MTLBuffer` objects (cell, selection, uniform) and lazily creates a render encoder per frame. Sampler states for glyph and decoration access are cached at renderer initialization.

## Detailed Plan
1. **Backend-neutral Python bindings**
   - Audit `kitty/fast_data_types` and associated CFFI interfaces for GL-specific entry points.
   - Introduce backend-agnostic helpers (e.g. `prepare_cells`, `draw_cells_backend`) that call into Metal/GL implementations without branching in Python.
   - Update Python code to use the new abstractions and ensure both backends receive identical parameters.

2. **Diagnostics & Logging**
   - Add structured logging around `metal_begin_frame`, drawable acquisition, command buffer commits, and pipeline failures.
   - Surface device-loss scenarios with actionable messages and potentially trigger GL fallback (if desired).

3. **Testing Strategy**
   - Implement a headless Metal smoke test: create an offscreen surface, upload a small atlas, render a test grid, and validate pixel hashes or buffer content.
   - Integrate Metal test execution into CI (gated for macOS runners).
   - Extend existing regression suite to run under `KITTY_GPU_BACKEND=metal` for key modules (fonts, rendering, cursor logic).

4. **Documentation Updates**
   - Refresh `docs/metal_migration_design_doc.md` with completed milestones and remaining tasks (layered rendering parity, diagnostics, tests).
   - Summarize progress and open issues for maintainers/user communication.

5. **Layered Rendering Parity (future milestone)**
   - Port background image, window logo, tinting, borders, and cursor trail effects to Metal.
   - Abstract GL-specific helpers (e.g. `draw_borders`, `draw_window_logo`) so they can be reimplemented or shared with Metal.

## Immediate Next Steps
- [ ] Prototype backend-neutral Python bindings for draw preparation.
- [ ] Add Metal logging around frame submission and resource allocation.
- [ ] Draft a headless Metal rendering test harness.
- [ ] Document current Metal coverage and gaps in the design doc.

## Blocking Issues / Risks
- Need macOS CI environment with Metal access for automated testing.
- Layered rendering port may require refactoring shared GL utilities.
- Ensure uniform buffers respect Metal alignment rules when reused in future passes.

## SAVED: 2025-11-06
