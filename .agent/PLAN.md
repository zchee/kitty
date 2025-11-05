# 2025‑11‑03 Assessment

- Re-ran full dependency review targeting a Metal backend: `glfw/nsgl_context.m`, `kitty/gl.c`, `kitty/shaders.c`, `gl-wrapper.h`, and 22 GLSL assets still hard-code OpenGL constructs (contexts, shader compilation, VAOs, framebuffer management) that would all require first-principles rewrites.
- Confirmed GLFW in-tree code only exposes Metal through the Vulkan surface helper; there is no ready-made CAMetalLayer path for Kitty’s window pipeline, so a Metal port would involve forking or substantially extending the upstream cocoa backend.
- Validated Python interfaces remain tightly coupled to OpenGL IDs and enums via `kitty/fast_data_types` (e.g., `compile_program`, VAO helpers) necessitating widespread API redesign and Python caller adjustments.
- Rechecked build and tooling: `setup.py` links `-framework OpenGL` and lacks Metallib packaging; no automated tests exercise GPU rendering, meaning a Metal port would need new CI infrastructure and validation strategy.
- Conclusion unchanged: implementing Metal today exceeds single-session capacity without a dedicated project plan, multiple refactors, and extensive testing.

# 2025‑11‑01 Update

- Audited the current macOS renderer and confirmed Kitty still relies on the OpenGL stack across `gl.c`, `glfw/nsgl_context.m`, `graphics.c`, and the GLSL shader toolchain. Converting these paths to Metal requires replacing GL context creation, VAO/VBO helpers, shader loading, and texture atlas management end-to-end.
- Identified dozens of GLSL sources and their Python build glue (`kitty/shaders.py`) that would need a new Metal compilation workflow (`xcrun metal` + `metallib`) along with rewritten shading code in MSL.
- Verified Python bindings in `fast_data_types` expose GL-specific entry points (e.g., `compile_program`, VAO manipulation). A Metal port must redesign these C-ext APIs and propagate changes to Python consumers.
- Confirmed the build system (`setup.py`) hardcodes `-framework OpenGL`. Transitioning to Metal entails new framework links (`Metal`, `QuartzCore`), asset packaging, and CI/tooling updates spanning multiple scripts.
- Checked macOS font discovery and determined Kitty already uses CoreText (`kitty/core_text.m`, `kitty/fonts/core_text.py`), so no additional porting is required there.
- Conclusion: Completing a Metal renderer within this session is infeasible without a sustained rewrite effort spanning C/Objective‑C, Python, build tooling, shaders, and tests. Recommend planning a multi-milestone project with dedicated engineering time before attempting code changes.

# Kitty macOS Metal Backend Migration Plan

## Objective
Replace Kitty's macOS OpenGL renderer with a Metal-based backend while leaving non-macOS platforms unchanged. Maintain feature parity (font rendering, graphics protocol, screenshots, background images, secure keyboard, retina handling) and allow a staged rollout with a runtime feature flag until Metal reaches parity.

## Scope & Constraints
- macOS builds only; Linux/Windows pipelines remain OpenGL/Vulkan.
- Remove all OpenGL dependencies from macOS-specific code (context, shaders, resource management).
- Deliver Metal equivalent functionality for existing GPU features, including premultiplied alpha blending and sRGB handling.
- Preserve current Python APIs where possible; document any breaking changes.
- Provide feature flag fallback to legacy OpenGL during transition.

## Affected Subsystems
1. macOS window/bootstrap: `glfw/nsgl_context.m`, `kitty/glfw.c`, `kitty/cocoa_window.m/h`.
2. Renderer core: `kitty/gl.c`, `kitty/graphics.c/h`, `kitty/shaders.c`.
3. Shader assets and loader: all `.glsl` files, `kitty/shaders.py`.
4. Python bindings and diagnostics: `kitty/fast_data_types.*`, `kitty/debug_config.py`, options layer.
5. Build tooling: `setup.py`, `shell.nix`, packaging of metallib assets.
6. Tests/CI: macOS GPU runners, new validation scripts.

## Target Architecture Overview
### Global Metal Context
- Singleton C struct (`MetalContext`) holding `id<MTLDevice>`, `id<MTLCommandQueue>`, compiled `MTLLibrary` cache, and diagnostic flags.
- Initialized on first macOS window creation; torn down at process exit.

### Per-Window Metal Surface
- `MetalSurface` attached to each `OSWindow`, owns `CAMetalLayer`, drawable size tracking, retina scale helpers, presentation logic.
- Integrates with GLFW macOS callbacks for resize and lifecycle.

### Resource Managers
- `MetalTextureRef`: wraps `id<MTLTexture>`, metadata, refcounts replacing GL texture IDs.
- `MetalBufferPool`: triple-buffered staging `MTLBuffer` objects for dynamic vertex/instance data.
- `MetalPipelineCache`: builds and caches `MTLRenderPipelineState` objects per shader/blend configuration.

### Render Scheduler
- Frame flow: obtain drawable → configure render pass → encode commands → present → recycle resources via command-buffer completion handlers.
- Autorelease pool per frame to ensure drawables released promptly.

## 2025‑11‑03 Project Planning Checklist
1. Confirm project charter, scope, success metrics, and stakeholder alignment.
2. Assign core Metal migration team (lead engineer, graphics specialists, tooling/test owner).
3. Inventory current OpenGL renderer, shader assets, and Python bindings; document interface contracts.
4. Specify target Metal architecture (device lifecycle, CAMetalLayer integration, rendering pipeline).
5. Design GLFW modifications or alternatives to host CAMetalLayer surfaces for Kitty windows.
6. Plan shader porting strategy: GLSL to MSL mapping, shared utilities, build-time tooling.
7. Define Python/C API abstraction layer decoupling rendering backend details.
8. Update build system requirements: metallib compilation, framework links, asset packaging.
9. Outline automated testing approach (unit, integration, GPU smoke tests on macOS).
10. Draft risk register and mitigation plans (performance regressions, feature gaps, macOS compatibility).
11. Schedule prototype milestone delivering Metal surface creation and basic clear pass.
12. Schedule milestone implementing text rendering path with CoreText + Metal textures.
13. Plan feature parity tasks (images, animations, shaders, blending, effects).
14. Define fallback/feature-flag strategy to switch between OpenGL and Metal during rollout.
15. Identify documentation updates (developer docs, user-facing release notes, migration guides).
16. Estimate CI infrastructure changes and secure macOS GPU runner capacity.
17. Plan performance benchmarking and regression tracking for Metal backend.
18. Develop rollout validation checklist (QA scenarios, beta program, canary tests).
19. Prepare deprecation timeline for OpenGL backend on macOS.
20. Set communication plan for stakeholders and community updates.

## Object Lifecycles
- Device/command queue created once; feature checks stored for option fallbacks.
- Per frame:
  1. Enter `@autoreleasepool`.
  2. Acquire drawable (`nextDrawable`); skip frame if nil.
  3. Create render pass descriptor (clear vs. load based on background opacity).
  4. Encode commands (text, images, effects) using Metal encoders.
  5. Commit command buffer with `presentDrawable`; attach completion handler for resource recycling.
- Resizing updates `CAMetalLayer.drawableSize` and recalculates viewport/pipeline state.

## Resource Abstraction Strategy
- Replace VAO/VBO concepts with explicit vertex descriptors and buffer bindings.
- Uniform blocks become Metal constant buffers or argument buffers; map existing uniform usage to struct layouts.
- Texture uploads through staging buffers and `blitCommandEncoder` for efficient transfers.

## Shader Pipeline
- Convert GLSL programs to MSL, stored in `kitty/shaders/metal/*.metal`.
- Build step invokes `xcrun metal` + `metallib`; packaged outputs in `kitty/metal/*.metallib`.
- Runtime shader reload uses `newLibraryWithData:` mirroring current GLSL path.

## Rendering Flow
1. `prepare_frame(os_window)` ensures pipelines and resources ready.
2. Encode instanced quads for text cells using glyph atlas textures.
3. Draw images/backgrounds with appropriate pipeline variants (premultiplied alpha, sRGB conversions).
4. Handle scissor, viewport, blending via `MTLRenderCommandEncoder` state.
5. Finalize command buffer and present drawable.

## Python Binding & API Updates
- Remove GL-specific diagnostics (`gl_version_string`), replace with Metal equivalents (GPU name, feature set).
- Update debug toggles to control Metal API Validation.
- Ensure type hints and stubs reflect new APIs; run `basedpyright` on modifications.

## Build & Tooling Changes
- `setup.py`: remove `-framework OpenGL`, add `Metal`, `QuartzCore`, ensure `xcrun metal` available.
- Adjust packaging to include metallib assets; guard non-macOS builds from Metal dependencies.
- Update `shell.nix` and other dev tooling for Metal compilation prerequisites.

## Compatibility & Risks
- Minimum macOS version: 11.0 or higher (confirm based on required Metal feature set).
- Need validation across GPU vendors (Intel, AMD, NVIDIA, Apple Silicon).
- Potential performance/visual regressions; maintain feature flag fallback.

## Testing Expectations (Future Stages)
- Screenshot-based regression tests for fonts, graphics protocol, backgrounds.
- Automated resizing/retina stress tests.
- Metal API Validation enabled in debug/test builds.
- Manual QA checklist (Mission Control interactions, Secure Keyboard Entry, menu updates).

## Milestones & Review Gates
1. **Stage 1** (this document): design approval by renderer + macOS leads.
2. **Stage 2**: Metal bootstrap + CAMetalLayer behind feature flag.
3. **Stage 3**: Resource abstraction layer parity.
4. **Stage 4**: Metal shader pipeline integrated.
5. **Stage 5**: Rendering loop parity, enable Metal by default in nightly builds.
6. **Stage 6**: Remove macOS OpenGL path after stable release.

## Open Questions
- Automated GLSL→MSL conversion feasibility vs. manual rewrite effort.
- Hybrid transition (Metal for core rendering, GL fallback for remaining features) necessary?
- Packaging strategy for metallib across architectures.
- Telemetry/metrics for staging rollout.

# Stage 2 – Implementation Roadmap

1. **Enumerate GL Entry Points** – Trace every macOS rendering call from window creation through draw submission (`kitty/gl.c`, `kitty/graphics.c`, `glfw/nsgl_context.m`, Cocoa glue) and record how state flows into shaders and buffers.
2. **Shader Inventory** – List all GLSL programs, their includes, and the Python loader behavior (`kitty/shaders.py`). Capture dependencies (defines, uniforms, instancing patterns) that must map cleanly to Metal.
3. **Resource Lifecycle Audit** – Document how textures, framebuffers, VAOs/VBOs, and atlas data are created, shared, reused, and destroyed. Include ref-count logic in `graphics.c` and Python-facing wrappers.
4. **API Surface Mapping** – Identify C extension functions/structs exposed to Python that directly reference OpenGL objects (`fast_data_types.*`, `gl.h`). Note which Python modules call them and expectations around IDs, formats, and error handling.
5. **Windowing Glue Review** – Analyze the GLFW/Cocoa stack for surface setup, resizing, retina scaling, vsync, and event timing. Determine touch points that must be replaced with `CAMetalLayer` and Metal drawable management.
6. **Target Architecture Draft** – Produce a Metal design doc covering device selection, command queue, command buffer lifecycle, render pass descriptors, synchronization, and fallback behavior if Metal isn’t available.
7. **Resource Abstraction Design** – Define new Metal-centric structs (textures, buffers, pipeline cache) and how they map back to existing Kitty abstractions. Decide ownership rules, pooling strategy, and memory limits.
8. **Shader Port Plan** – For each GLSL program, specify the MSL equivalents, required vertex/fragment inputs, uniform/constant buffer layouts, and blending/state encoding. Decide whether to use argument buffers or classic constant buffers.
9. **Shader Build Pipeline** – Extend the build system to run `xcrun metal`/`metallib`, set up per-target outputs, embed resources, and enable debug symbol generation. Capture how hot reload will consume the new assets.
10. **Runtime Loader Rewrite** – Redesign `kitty/shaders.py` (or replacement) to load metallibs, select functions, handle specialization constants, and report compile/link errors with user-friendly context.
11. **Python API Adjustments** – Update option parsing (`macos_use_metal`), diagnostics, and any public API that mentions OpenGL. Determine deprecation strategy for GL-specific toggles and craft migration notes.
12. **Graphics Command Translation** – Refactor graphics protocol execution paths to build Metal command buffers: staging uploads, blit passes, instanced quads, scissoring, and blending logic equivalent to current GL flows.
13. **Build-System Updates** – Modify `setup.py`, CI scripts, and packaging configs to link `Metal`, `QuartzCore`, bundle metallibs, and guard non-macOS builds. Verify universal binaries and codesigning aspects.
14. **Test Harness Design** – Specify automated checks (headless GPU validation, screenshot diffs, shader compilation tests) and extend existing test runner to invoke them. Decide on CI requirements/macOS runners.
15. **Manual QA Checklist** – Draft scenarios covering retina scaling, background images, graphics protocol edge cases, transparency, secure keyboard entry, and performance regression capture using Metal tools.
16. **Feature Flag Strategy** – Decide how/when to enable Metal by default, fallback handling if initialization fails, and telemetry/logging hooks for early adopters.
17. **Effort & Risk Estimation** – Allocate engineering time, outline dependencies, and flag high-risk areas (shader parity, texture atlas correctness, performance tuning). Present estimates to stakeholders for approval.
18. **Documentation Updates** – Plan revisions for developer docs, user manuals, troubleshooting guides, and release notes explaining prerequisites (macOS 11+, GPU families) and configuration changes.
19. **Communication Plan** – Schedule announcements to contributors/users, draft migration guides, and set expectations for feedback channels during beta rollout.
20. **Review & Post-Launch Protocol** – Define code review gates, acceptance criteria, staging rollout steps, monitoring dashboards, and rollback procedures for regressions once Metal ships.

### Stage 2 Progress Log

- **Step 1 (GL entry point audit, 2025‑11‑01):**
  - `kitty/gl.c:53` `gl_init` handles GLAD setup, extension checks, and SRGB feature flags; every render path depends on this bootstrap.
  - `kitty/gl.c:117` `bind_framebuffer_for_output`, `set_framebuffer_to_use_for_output`, and `draw_quad` orchestrate framebuffer binding, blending, and instanced quad draws across the renderer.
  - `kitty/gl.c:145` viewport/scissor utilities (`set_gpu_viewport`, `save_viewport_*`, `restore_viewport`, `enable_scissor_using_top_left_origin`, `disable_scissor`) manage coordinate transforms consumed by `graphics.c` and window composition.
  - `kitty/gl.c:197` `save_texture_as_png` plus `free_texture` / `free_framebuffer` expose texture lifecycle hooks for diagnostics and cleanup routines.
  - `kitty/gl.c:224`–`kitty/gl.c:318` shader/program helpers (`compile_shaders`, `init_uniforms`, `bind_program`, `block_index`, etc.) encapsulate OpenGL program usage for the Python shader loader and C extensions.
  - `kitty/gl.c:336` onward buffer/VAO abstractions (`create_vao`, `add_buffer_to_vao`, `map_vao_buffer`, `bind_vao_uniform_buffer`) manage vertex data submission for cells, graphics protocol images, and decorations.
  - `kitty/shaders.c:65` and surrounding functions call `glUniform*`, `glCopyImageSubData`, `glTex*`, and framebuffer clears directly during sprite atlas management and graphics uploads—these bypass the wrapper layer and must be ported explicitly.
  - `glfw/nsgl_context.m:128` `_glfwCreateContextNSGL` constructs the NSOpenGL pixel format/context, sets swap interval, and wires per-window callbacks, representing the macOS surface entry point that will transition to `CAMetalLayer`.
  - No other compilation units include `gl.h`, confirming that `gl.c` and `shaders.c` constitute the exported OpenGL surface while numerous subsystems consume their APIs.
- **Step 2 (GLSL shader catalogue, 2025‑11‑01):**
  - Identified 22 GLSL resources under `kitty/`: vertex/fragment pairs for `cell`, `borders`, `graphics`, `bgimage`, `tint`, `trail`, `blit`, `rounded_rect`, plus shared includes like `alpha_blend.glsl`, `linear2srgb.glsl`, `cell_defines.glsl`, `blit_common.glsl`, `utils.glsl`, and `hsluv.glsl`.
  - Primary program mapping (vertex → fragment):
    - `cell`, `cell_fg`, `cell_bg` → `cell_vertex.glsl` / `cell_fragment.glsl`
    - `borders` → `border_vertex.glsl` / `border_fragment.glsl`
    - `graphics`, `graphics_premult`, `graphics_alpha_mask` → `graphics_vertex.glsl` / `graphics_fragment.glsl`
    - `bgimage` → `bgimage_vertex.glsl` / `bgimage_fragment.glsl`
    - `tint` → `tint_vertex.glsl` / `tint_fragment.glsl`
    - `trail` → `trail_vertex.glsl` / `trail_fragment.glsl`
    - `blit` → `blit_vertex.glsl` / `blit_fragment.glsl`
    - `rounded_rect` → `rounded_rect_vertex.glsl` / `rounded_rect_fragment.glsl`
  - `#pragma kitty_include_shader <...>` directives form a custom include system handled by `Program._load_sources`, which injects `#version {GLSL_VERSION}` headers and stitches dependency files while tracking synthetic line numbers for error reporting.
  - `program_for(name)` memoizes `Program` instances; the `Program` class caches original sources (`original_vertex_sources` / `original_fragment_sources`) and supports transformation callbacks (`apply_to_sources`) before invoking the C extension `compile_program`.
  - `LoadShaderPrograms.__call__` orchestrates compilation: it fills in macro placeholders via `MultiReplacer` for the cell pipelines (handling reverse/bold/dim flags, text gamma, FG override thresholds) and tweaks the graphics fragment shader to switch between image, premultiplied, and alpha-mask variants.
  - Shared GLSL snippets provide color space conversions (`alpha_blend.glsl`, `linear2srgb.glsl`), coordinate math (`utils.glsl`, `blit_common.glsl`), and HSLuv computations (`hsluv.glsl`); these will require one-to-one Metal equivalents or reimplementation in MSL.
  - Any Metal port must replicate the include-resolution mechanism, option-driven shader parameterization, and multi-program compilation order encapsulated by `LoadShaderPrograms` and `init_cell_program()`.
- **Step 3 (Texture & buffer lifecycle audit, 2025‑11‑01):**
  - `GraphicsManager` instantiates a `TextureRef` for every `Image`, managing refcounts and deleting GL textures via `free_texture` when the last user releases it (`graphics.c:108`–`graphics.c:140`). Disk-cache entries and per-frame metadata are cleared together to avoid stale GPU resources (`graphics.c:139`–`graphics.c:154`).
  - `LoadData` centralizes staging for image uploads (`graphics.h:119`), supporting chunked buffers, mmapped files, and optional zlib/PNG inflation (`graphics.c:348`–`graphics.c:622`) before marking data ready for GPU transfer.
  - `upload_to_gpu` enforces GL context ownership, then calls `send_image_to_gpu`, which lazily creates textures, sets sampling/wrap modes, handles border colors, and issues `glTexImage2D` with SRGB or RGB formats (`graphics.c:699`–`graphics.c:707`, `shaders.c:259`–`shaders.c:281`).
  - Clone operations and render-data generation reuse texture handles by bumping the `TextureRef` count (`graphics.c:266`, `graphics.c:1277`), while `clear_texture_ref` cleans up automatically when references drop to zero.
  - Storage accounting (`graphics.c:154`), disk-cache size tracking (`graphics.c:61`), and context guards (`graphics.c:701`) highlight lifecycle constraints that a Metal backend must mirror with its own texture/buffer pools and command submission model.
- **Step 4 (Python ↔ C GL interface audit, 2025‑11‑01):**
  - The `kitty.shaders` extension exposes GL entry points to Python: `compile_program`, `create_vao`, `bind_program`, `bind_vertex_array`, `unmap_vao_buffer`, `init_borders_program`, and `init_cell_program` are registered in `module_methods` and backed by the GL helpers in `gl.c`/`shaders.c` (`shaders.c:1437`–`shaders.c:1556`).
  - `compile_program` bridges Python shader source tuples to GL programs—creating, attaching, linking, and populating uniform metadata via `init_uniforms` before returning the program ID to Python (`shaders.c:1437`–`shaders.c:1463`).
  - VAO management (`create_vao`, `bind_vertex_array`, `unmap_vao_buffer`) and program binding mirror the GL helper layer, signalling that any Metal port must replace these wrappers or provide API-compatible shims.
  - Constants like `CELL_PROGRAM`, `GRAPHICS_PROGRAM`, `GL_TEXTURE_2D_ARRAY`, and `GLSL_VERSION` are exported to Python through `init_shaders` (`shaders.c:1523`–`shaders.c:1554`), meaning option logic and shader compilation in Python depend on these symbolic values.
  - Additional Python-visible hooks in `fast_data_types.pyi`—`compile_program`, `init_cell_program`, window/context utilities—are thin veneers over the same GL operations, so redesigning the C extension API is mandatory when swapping in a Metal backend.
- **Step 5 (GLFW/Cocoa integration audit, 2025‑11‑01):**
  - `_glfwCreateContextNSGL` constructs the per-window NSOpenGL context, picking pixel format attributes, handling retina scaling, wiring swap/makeCurrent callbacks, and retaining a globally shared context to avoid shader/atlas loss when all windows close (`glfw/nsgl_context.m:126`–`glfw/nsgl_context.m:325`).
  - Swap and teardown paths (`swapBuffersNSGL`, `destroyContextNSGL`) operate on `NSOpenGLContext` objects, while `getProcAddressNSGL` pulls symbols from `com.apple.opengl` (`glfw/nsgl_context.m:43`–`glfw/nsgl_context.m:84`). A Metal backend must replace these with CAMetalLayer/MTLDevice setup and appropriate drawable presentation.
  - Kitty’s OS-window management relies on `make_os_window_context_current` to call `glfwMakeContextCurrent`, with higher-level helpers (`make_window_context_current`, `upload_to_gpu`) assuming a GL context exists before touching GPU resources (`kitty/glfw.c:917`–`kitty/glfw.c:924`, `kitty/state.c:650`–`kitty/state.c:655`).
  - The GLFW Cocoa surface creator already allocates a `CAMetalLayer` when MoltenVK is requested (`glfw/cocoa_window.m:3120`–`glfw/cocoa_window.m:3154`), offering a useful reference for managing drawable size and retina scaling in a future Metal path.
  - Any Metal migration must rework the GLFW macOS hooks, context-current helpers, and state bookkeeping so that Python and C callers no longer assume NSOpenGL contexts while preserving the shared-context semantics Kitty depends on today.
- **Step 6 (Target Metal architecture draft, 2025‑11‑01):**
  - **Device/queue initialization:** Create a single `MTLDevice` via `MTLCreateSystemDefaultDevice()` during startup; gate Metal availability on the device’s feature sets (macOS GPU family 1 v4 or newer). Populate a `MTLCommandQueue`, `MTLHeap`/buffer pools, and a diagnostics struct mirroring `global_state.gl_version`. Expose a graceful fallback that reverts to legacy OpenGL if Metal initialization fails.
  - **Surface integration:** Replace NSOpenGL layers with `CAMetalLayer` per `OSWindow`, setting `device`, `pixelFormat` (likely `MTLPixelFormatBGRA8Unorm_sRGB`), `framebufferOnly`, and `maximumDrawableCount`. Update resize paths to recompute `drawableSize` based on retina scaling, leveraging existing logic in `glfw/cocoa_window.m` as a template.
  - **Render pass structure:** For each frame, acquire `nextDrawable`, build a `MTLRenderPassDescriptor` with load/store actions derived from background opacity (clear vs. load), and encode command buffers in a strict order: text cells, graphics protocol quads, backgrounds, overlays. Attach completion handlers to recycle staging resources and maintain synchronization with the GPU.
  - **Resource management:** Introduce Metal equivalents of `TextureRef`/VAO buffers—e.g., a texture atlas backed by `MTLTexture`, dynamic vertex data staged through ring-buffer `MTLBuffer`s, and constant-buffers mirroring existing uniform blocks. Use argument buffers or per-draw constant updates to replace uniform block lookups (`block_index`, `block_size`).
  - **Shader pipeline:** Compile MSL sources into `.metallib` assets (per platform architecture) and load them via `newLibraryWithURL:`/`newLibraryWithData:`. Create and cache `MTLRenderPipelineState` objects for each program variant (`cell`, `graphics`, etc.) with appropriate blending (`pre-multiplied` vs. straight alpha) and depth/stencil settings.
  - **Synchronization & presentation:** Wrap each frame in an `@autoreleasepool`, ensure command buffers commit with `presentDrawable:` calls, and integrate Metal API Validation toggles into Kitty’s debug options. Maintain a shared command queue but allow per-window drawable lifetimes to emulate the current shared-context behavior.
  - **Fallback path:** Preserve the existing OpenGL backend behind the `macos_use_metal` flag during transition—initializing only one renderer per process and cleaning up Metal resources gracefully if the flag is toggled off at startup.
- **Step 7 (Metal resource abstraction design, 2025‑11‑01):**
  - **Textures:** Replace `TextureRef` with a `MetalTextureRef` struct holding `id<MTLTexture>`, usage metadata (atlas layer, wrap mode), and a submission fence/`MTLSharedEvent` handle to coordinate reuse after command-buffer completion. Maintain refcount semantics so cloned images share GPU storage until freed.
  - **Buffer pools:** Introduce per-frame ring buffers for dynamic data: a `MetalBufferPool` managing multiple `id<MTLBuffer>` objects with CPU-visible storage (`storageModeManaged`/`storageModeShared`) and allocation cursors. Expose helpers to reserve space for cell vertices, instance data, and uniform uploads, mirroring `alloc_vao_buffer`/`map_vao_buffer` behavior.
  - **Constant data:** Model uniform blocks as POD structs uploaded into `MTLBuffer` slices or `MTLArgumentEncoder` buffers. Cache offsets keyed by program type to emulate `block_index`/`block_size`, and provide mapping utilities that respect Metal’s 256-byte alignment constraints.
  - **Pipeline cache:** Create a `MetalPipelineStateCache` keyed by shader variant (program name + blending/tint flags). Each entry stores `MTLRenderPipelineState`, vertex descriptor, and precomputed `MTLDepthStencilState` when needed. Include a lazy compilation path to avoid upfront creation of every variant.
  - **Staging utilities:** Replace `send_image_to_gpu` with a two-stage upload—first copy into a `MTLBuffer` or `MTLTexture` using `replaceRegion`/`newTextureWithDescriptor`, then issue a blit pass if linearization or color conversion is required. Encapsulate these operations in a `MetalImageUploader` that handles repeat modes, sRGB conversions, and border colors.
  - **Lifetime management:** Tie buffer/texture recycling to command-buffer completion handlers, ensuring resources aren’t reused until the GPU finishes. Maintain per-window resource registries so Metal cleanup mirrors the current `free_image_resources` and disk-cache behavior.
- **Step 8 (Shader porting & metallib pipeline, 2025‑11‑01):**
  - **MSL translation plan:** Hand-port each GLSL shader to Metal Shading Language, preserving existing include structure by splitting shared snippets (`utils`, `alpha_blend`, `cell_defines`) into `.metal` headers or inline functions. Document any semantic differences (e.g., coordinate origin, texture sampling) per shader.
  - **Source layout:** Organize Metal sources under `kitty/shaders/metal/`, mirroring GLSL filenames (`cell_vertex.metal`, `graphics_fragment.metal`, etc.) plus shared headers. Maintain a manifest mapping Metal functions to pipeline entries for use at runtime.
  - **Compilation tooling:** Extend the build system to invoke `xcrun metal` -> `.air`, `xcrun metallib` -> `.metallib` for each architecture (x86_64, arm64). Package metallibs with the Kitty app bundle and record their revisions for cache invalidation.
  - **Hot reload & diagnostics:** Provide a developer path to rebuild metallibs on the fly (similar to GLSL recompilation) with friendly error reporting by parsing `metal` compiler output and mapping it back to source filenames, akin to the current GLSL error remapping.
  - **Shader options:** Re-implement shader customization hooks (`MultiReplacer`, text gamma/FG overrides) via preprocessor macros or argument buffers during compilation, ensuring the same option combinations generate distinct pipeline states.
  - **Validation:** Enable `metal tools validation` in debug builds, run automated tests that compile the full shader set, and capture pipeline reflection data (resource indices, buffer layouts) to cross-check against C structs.
- **Step 9 (Shader loader & hot reload redesign, 2025‑11‑01):**
  - Replace `Program`/`program_for` with a `MetalShaderLibrary` manager responsible for loading `.metallib` files, retrieving `MTLFunction` handles by name, and building pipeline descriptors. Maintain a cache keyed by program + variant to avoid redundant lookups.
  - Rework `LoadShaderPrograms` to trigger metallib rebuilds or reloads via a new helper (`reload_metal_library`) that monitors file timestamps and repopulates pipeline state caches. Integrate the existing option-driven shader substitutions (gamma, FG override) as specialization constants or pipeline toggles.
  - Provide a developer-facing command (akin to the current `compile_program`) that rebuilds metallibs using `xcrun metal` and reports errors back to Python, preserving the current user experience for on-the-fly shader tweaks.
  - Update `init_cell_program`/related initialization hooks to bind constant-buffer indices and resource slots obtained from Metal pipeline reflection rather than searching for uniform locations.
  - Ensure fallback logic keeps the GLSL loader intact when Metal is disabled, allowing both backends to coexist during transition while sharing similar Python entry points.
- **Step 10 (Python API & option updates, 2025‑11‑01):**
  - Keep `macos_use_metal` as a startup-only option but extend parsing to emit detailed validation (minimum macOS version, GPU feature support). Invalid combinations should downgrade to OpenGL with a warning rather than aborting.
  - Expose new diagnostics in `debug_config`/RC commands (e.g., `metal_info`, API validation toggles, pipeline cache stats) so users can inspect Metal state analogous to `gl_version_string`.
  - Update Python modules that assume GL identifiers (`gl_version_string`, GL uniform handles) to query a backend-agnostic `RendererInfo` object returning Metal-specific data when active.
  - Ensure kittens and options (`kitty/options/definition.py`, `parse.py`) reflect that Metal is the default once stable, adding documentation for required macOS versions and the fallback flag to force legacy GL.
  - Provide migration helpers so third-party kittens using `fast_data_types` APIs receive no-op stubs or clear errors when GL-specific functions are unavailable under Metal.

- **Step 11 (Graphics protocol migration plan, 2025-11-01):**
  - Map each GL draw path (textured quads, alpha-mask, premultiplied images) to a Metal render-encoder sequence using instanced quads fed by the new buffer pool. Define a per-frame encoder builder that batches refs by pipeline variant to minimize state switches.
  - Recreate scissor/viewport logic with `setScissorRect`/`setViewport`, accounting for top-left origin adjustments already handled by GL helpers.
  - Implement glyph atlas updates as texture blits or compute passes, ensuring synchronization between CPU uploads and subsequent render passes (fences or `blitCommandEncoder` with completion handlers).
  - For animations and z-sorted image refs, devise ordering rules that translate `ImageRenderData` into Metal draw calls, preserving blending semantics (`MTLBlendOperationAdd` with premultiplied alpha where needed).
  - Handle background images and tint layers through dedicated pipeline states, using specialized uniform buffers mirroring the GLSL layout. Integrate fallback code paths for missing features (e.g., if a shader relies on GL-only functionality).
- **Step 12 (Build system updates, 2025-11-01):**
  - Update `setup.py` and related build scripts to detect Xcode command-line tools, add `-framework Metal -framework QuartzCore`, and invoke the Metal toolchain during build steps (including universal binaries for arm64/x86_64).
  - Add a `make metallib` helper plus CI integration that regenerates metallibs for release artifacts; ensure cached outputs invalidate when Metal sources change.
  - Guard non-macOS builds by skipping Metal commands and falling back to existing GL assets. For macOS, embed metallibs in app bundles and development layouts, adjusting packaging scripts accordingly.
  - Ensure cross-compilation and notarization flows sign the metallibs and include them in distribution manifests.

- **Step 13 (Automated test strategy, 2025-11-01):**
  - Develop a Metal-specific test suite that runs on macOS CI with GPU access, capturing screenshots for regression comparison and validating shader compilation with `xcrun metal`.
  - Add unit tests for buffer/texture lifetimes using mock command-buffer completion handlers and ensure CPU/GPU synchronization errors surface during testing.
  - Integrate performance smoke tests that measure frame times with Metal API validation on, flagging regressions relative to OpenGL baselines.

- **Step 14 (Manual QA & profiling plan, 2025-11-01):**
  - Draft checklists covering retina scaling, Mission Control/Spaces, secure keyboard entry, background images, graphics protocol stress cases, and macOS power-saving scenarios.
  - Include instructions for capturing Metal GPU traces (`xcrun metal-capture`) and profiling with Xcode to compare against OpenGL baselines.
  - Document fallback verification steps (forcing legacy OpenGL) and recovery procedures for common issues (black screen, flicker, command-buffer failures).

- **Step 15 (Rollout strategy, 2025-11-01):**
  - Stage Metal behind `macos_use_metal yes` for nightly builds, collect telemetry on failures and performance deltas, and only promote to default after stability criteria are met.
  - Provide a command-line switch/env var to force legacy OpenGL for troubleshooting and publish downgrade instructions.
  - Plan phased rollout (nightly -> beta -> stable) with success metrics and rollback triggers tied to crash logs or regression thresholds.

- **Step 16 (Effort & risk estimate, 2025-11-01):**
  - Produce a work breakdown structure covering renderer, shader, tooling, QA, and docs, with time estimates and required expertise per area.
  - Identify high-risk items (shader correctness, glyph atlas performance, build tool availability) and define mitigation tasks (prototypes, early CI coverage).
  - Track dependencies on external tooling (Xcode versions, CI GPU availability) and set contingency plans.

- **Step 17 (Documentation plan, 2025-11-01):**
  - Update developer docs with Metal build prerequisites, debugging workflow, and fallback instructions.
  - Revise user-facing manuals (INSTALL.md, docs/faq.rst) to highlight Metal requirements, configuration options, and troubleshooting tips.
  - Provide migration notes for theme authors and extension developers affected by rendering changes.

- **Step 18 (Communication plan, 2025-11-01):**
  - Announce the Metal migration roadmap to contributors via mailing list/Matrix, including timelines and testing expectations.
  - Draft release notes and blog posts explaining benefits, required OS versions, and fallback instructions for users.
  - Coordinate with package maintainers (Homebrew, MacPorts) to ensure build recipes reflect new dependencies.

- **Step 19 (Review & approval gates, 2025-11-01):**
  - Establish milestone reviews after each major phase (Metal bootstrap, resource layer, shader port, full rendering parity) with designated approvers.
  - Require passing automated tests and manual QA sign-off before enabling Metal by default.
  - Track open issues/regressions in a dedicated board to gate promotion between release channels.

- **Step 20 (Post-launch monitoring, 2025-11-01):**
  - Instrument Metal error logging and crash telemetry to detect GPU faults after release.
  - Schedule regression sweeps (automated screenshots, performance benchmarks) for future releases to ensure parity remains.
  - Maintain a rollback plan and hotfix process if Metal regressions surface in stable builds.
# 2025‑11‑03 Update

- Restored local planning context from existing .agent records and reaffirmed constraints: drop macOS OpenGL paths, adopt Metal-only renderer, ensure CoreText font discovery remains first-class, use Python 3.13 toolchain.
- Established 20-step execution plan covering investigation, documentation research (apple-docs MCP), static analysis (clangd/basedpyright), Metal architecture design, shader migration, build/test updates, and documentation.
- Key task inventory:
  1. Restore prior context from .agent files and summarize constraints.
  2. Identify macOS OpenGL entry points across C/ObjC code.
  3. Catalogue build scripts linking OpenGL frameworks.
  4. Inventory GLSL shader assets and compilation pipeline.
  5. Inspect CoreText font discovery modules for integration points.
  6. Gather Apple Metal and CoreText documentation via apple-docs MCP.
  7. Use clangd MCP to analyze GL-centric call graphs.
  8. Use basedpyright MCP to map Python GPU interface dependencies.
  9. Design target Metal architecture aligned with Kitty abstractions.
  10. Define Metal-native resource wrapper data structures.
  11. Map GLSL shader functionality to MSL equivalents.
  12. Plan build pipeline updates for Metal shader compilation.
  13. Modify macOS windowing code to adopt CAMetalLayer surfaces.
  14. Implement Metal renderer core replacing gl.c/graphics.c flows.
  15. Update Python bindings/FFI for new Metal entry points.
  16. Rework texture/font uploads for Metal staging/blit paths.
  17. Refresh debug/diagnostic tooling for Metal state.
  18. Author Metal-specific tests for renderer and font discovery.
  19. Execute full test suite with Python 3.13 and iterate.
  20. Document migration and update .agent memory/plan files.
