# Metal Migration Status — 2025-11-06

## Current Knowledge
- Metal bootstrap, atlas management, and text grid rendering are implemented; GL path remains for layered/border effects.
- Shared uniform packing now lives in `populate_cell_uniforms`, reused by both GL and Metal.
- Render loop branches early for Metal, encoding draws through `metal_draw_cells` with instanced quads and managed buffers.

## Plan
- [x] Restate constraints for Metal parity work.
- [x] Catalogue OpenGL text-rendering workflow and data flow.
- [x] Document glyph atlas upload flow in OpenGL.
- [x] Inventory shader programs/uniforms for text rendering.
- [x] Document vertex/index buffer usage.
- [x] Review CPU-side staging buffers and sprite tracker reuse.
- [x] Consult Apple Metal docs for textures/samplers/encoding.
- [x] Design Metal resource structures (textures, buffers, samplers).
- [x] Plan metallib packaging for cell shaders.
- [x] Prototype Metal pipeline state objects mirroring GL programs.
- [x] Implement Metal glyph atlas upload path against sprite tracker callbacks.
- [x] Implement Metal vertex/selection buffer population via shared writers.
- [x] Encode Metal render pass for main text grid (buffers, textures, draw call).
- [x] Integrate Metal render flow into `render_prepared_os_window` while keeping GL intact.
- [ ] Adjust Python bindings / `fast_data_types` for backend-neutral draw submission.
- [ ] Add diagnostics/logging for Metal text rendering failures.
- [ ] Create focused Metal regression tests (headless snapshot or glyph smoke test).
- [ ] Run Metal-focused tests plus existing fast checks.
- [ ] Document progress and limitations in the design doc and summarize results for the user.

## Next Focus
1. Introduce backend-agnostic interfaces in Python extensions so UI code no longer branches on GL/Metal before draw calls.
2. Add logging hooks (command buffer status, drawable acquisition) to aid debugging on device loss.
3. Build automated Metal smoke tests to exercise glyph uploads and render pass encoding.
4. Update the design doc with the completed rendering milestones and outline remaining parity gaps.
