# Shader Porting Plan: GLSL → MSL (2025-11-03)

## Objectives
- Translate Kitty’s 22 GLSL programs to Metal Shading Language (MSL) while preserving visual behaviour and numeric fidelity.
- Build reproducible tooling (`xcrun metal`, `metallib`) integrated with the existing build system.
- Maintain developer ergonomics: include resolution, hot reload, and meaningful error reporting.

## Source Inventory
Transition scope covers all GLSL files in `kitty/`:
- `alpha_blend.glsl`, `bgimage_fragment.glsl`, `bgimage_vertex.glsl`, `blit_common.glsl`, `blit_fragment.glsl`, `blit_vertex.glsl`
- `border_fragment.glsl`, `border_vertex.glsl`, `cell_defines.glsl`, `cell_fragment.glsl`, `cell_vertex.glsl`
- `graphics_fragment.glsl`, `graphics_vertex.glsl`, `hsluv.glsl`, `linear2srgb.glsl`
- `rounded_rect_fragment.glsl`, `rounded_rect_vertex.glsl`, `tint_fragment.glsl`, `tint_vertex.glsl`
- `trail_fragment.glsl`, `trail_vertex.glsl`, `utils.glsl`

## Translation Strategy
1. **Establish Shared Utility Library**
   - Convert common GLSL helper files (`alpha_blend`, `linear2srgb`, `utils`, `hsluv`, `blit_common`) into reusable MSL header modules (`.metal` includes).
   - Maintain consistent function signatures and inline semantics.

2. **Vertex/Pipeline Parameters**
   - Map GLSL inputs (`in`, `out`, `uniform`, `sampler2DArray`) to MSL structures using `[[stage_in]]`, `[[buffer(N)]]`, `[[texture(N)]]`, `[[sampler(N)]]`.
   - Define explicit vertex descriptor formats aligned with Metal pipeline cache.

3. **Coordinate Adjustments**
   - Ensure coordinate systems match (Metal’s viewport origin default bottom-left; text pipeline expects top-left adjustments). Handle via vertex shader or viewport state.

4. **Conditional Compilation / Options**
   - Replace GLSL `#define` toggles with either MSL `constant` values or pipeline specialization constants.
   - For per-program variants (foreground/background toggles), consider argument buffers or separate pipeline functions.

5. **Gamma / Color Utilities**
   - Verify `linear2srgb` conversions produce correct results in MSL (use double precision where required).

6. **Validation**
   - For each shader, render reference scenes under OpenGL and Metal; capture framebuffer diffs within acceptable tolerances.
   - Add automated comparison tests in CI (requires deterministic output fixtures).

## Tooling Pipeline
1. **Source Layout**
   - Store MSL sources under `kitty/shaders/metal/`.
   - Mirror current naming to maintain mapping (`cell_vertex.metal`, etc.).

2. **Compilation**
   - Invoke `xcrun metal` during build to compile `.metal` to `.air`.
   - Link `.air` files into `kitty/metal/kitty.metallib` using `xcrun metallib`.
   - Embed metadata manifest (JSON/TOML) describing function names, resource bindings, and associated program IDs.

3. **Development Workflow**
   - Provide developer script (or make target) for incremental recompilation and error reporting line-mapped back to MSL source.
   - Support debug toggles enabling runtime metallib reload via `MTLLibrary newLibraryWithData:` similar to `allow_recompile`.

4. **Error Reporting**
   - Parse `xcrun metal` error output to present friendly messages to Python callers (map to file/line using manifest).

## Metadata & Binding Mapping
- Maintain table aligning existing GL program constants (`CELL_PROGRAM`, `BGIMAGE_PROGRAM`, etc.) with MSL entry points (vertex/fragment function names).
- Define uniform/constant layouts in C header shared between Metal backend and Python metadata.
- Use argument buffers or constant structs to replicate uniform block behaviour (e.g., text parameters, color adjustments).

## Testing & QA
- Introduce GPU regression tests rendering canonical scenes and diffing against expected PNGs.
- Add assertions in Python to ensure metallib contains required symbols during startup.
- Provide manual QA checklist including text gamma, rounded corners, background images, trail effects, tinting.

## Risks & Mitigations
- **Precision differences**: Use `half` vs `float` judiciously; baseline with unit tests; allow fallback to higher precision where regressions appear.
- **Include resolution**: Build script must expand `#pragma kitty_include_shader` analogs; consider preprocessor step generating flattened MSL sources.
- **Build time**: Cache metallib outputs; detect incremental changes to avoid full rebuilds.
- **Debugging complexity**: Document usage of Xcode GPU Frame Capture for Metal pipeline debugging.

## Next Actions
1. Draft prototype MSL versions of `cell_vertex`/`cell_fragment` to validate pipeline setup.
2. Implement build system changes (Step 8 of migration plan) to compile metallib.
3. Create automated shader comparison tests and integrate into CI (ties into testing/benchmarking steps).

