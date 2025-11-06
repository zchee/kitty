# Kitty macOS Metal Migration Design

**Status:** Draft for internal review — November 6, 2025  
**Authors:** Codex agent (with prior groundwork from Kitty maintainers)  
**Audience:** Kitty core maintainers, GPU/rendering contributors, CI/tooling owners

## 1. Purpose and Scope

This design describes how Kitty’s macOS build will transition from the legacy OpenGL stack to a Metal-only renderer. It consolidates the architecture direction, implementation phases, tooling updates, and rollout strategy required to ship Metal as the default backend while keeping catastrophic risk tolerance in mind. The scope covers:

- Replacing GLFW’s NSOpenGL context handling (`kitty/glfw.c:1340-1395`) with a CAMetalLayer-backed pathway.
- Rebuilding the renderer core (`kitty/gl.c`, `kitty/graphics.c`) and shader toolchain around Metal primitives.
- Updating Python↔C bindings (`kitty/shaders.c:1416-1499`, `kitty/fast_data_types.*`) to operate against Metal constructs without breaking existing APIs.
- Ensuring font discovery continues through CoreText (`kitty/fonts/core_text.py`) with the necessary glue to populate Metal texture atlases.
- Delivering build, testing, and release infrastructure that packages `.metallib` assets and verifies Metal rendering on macOS CI.

Out of scope: Linux/Windows rendering, Vulkan experimentation, or rewriting non-rendering subsystems unless directly impacted.

## 2. Background

macOS OpenGL has been deprecated since 10.14 and diverges from Apple’s GPU driver investment. Kitty’s current renderer relies on GLFW’s NSGL backend, 22 GLSL shaders, and a Python extension whose public API exposes OpenGL IDs. This creates fragility on new macOS releases and blocks feature work (HDR, async shader compilation, GPU timeline debugging).

Prior repository work already catalogued affected components (`docs/metal_migration_*`). This design synthesizes those findings into an actionable execution plan with explicit component boundaries and integration points.

## 3. Goals

1. **Parity:** Deliver text/graphics rendering parity with current OpenGL output across retina and non-retina displays.
2. **Performance:** Match or exceed baseline frame times for workloads (scrolling, ligatures, graphics protocol) on Apple Silicon and Intel GPUs.
3. **Stability:** Ship Metal as the default backend with no regressions in crash rate or rendering correctness.
4. **Operability:** Provide logging/introspection hooks suitable for diagnosing Metal GPU faults.
5. **Maintainability:** Establish abstractions so future GPU features (e.g., variable refresh, HDR) plug in without re-architecting Python callers.

## 4. Non-Goals and Constraints

- No fallback to OpenGL on macOS once Metal is marked GA; the legacy path can remain for other platforms.
- No reliance on private API or MTKView; we control the full CAMetalLayer integration.
- Python API signatures should remain stable where possible; breaking changes must be version-gated.
- Avoid rewriting font discovery: continue using CoreText via `coretext_all_fonts()` and reuse existing scoring logic in `kitty/fonts/core_text.py`.
- Maintain compatibility with Python 3.13 runtime (`.venv/bin/python3.13`) for all scripts/tests involved in implementation.

## 5. System Architecture Overview

### 5.1 Component Map

| Component | Responsibilities | Source Touchpoints |
|-----------|-----------------|--------------------|
| **MetalSubsystem** | Own `MTLDevice`, `MTLCommandQueue`, feature flags, runtime metrics. Handles device loss and global caches. | New C++/ObjC module (e.g., `kitty/metal/runtime.mm`). |
| **MetalSurface** | Wrap CAMetalLayer per `OSWindow`, track drawable lifecycle, manage frame pacing. | Extend existing `kitty/metal_surface.mm` beyond scaffolding. |
| **Render Graph** | Coordinate command buffers, encoders, pass sequencing (text grid, images, overlays). | Replace `kitty/gl.c` main loops with Metal equivalents. |
| **Resource Managers** | Texture atlas uploads, buffer pooling, uniform staging, sampler caches. | New modules invoked from `graphics.c` analog. |
| **Shader/Pipeline Loader** | Translate existing GLSL programs to MSL, compile with `xcrun metal`, load `MTLLibrary` and `MTLRenderPipelineState`. | Build scripts + runtime loader replacing `compile_program`. |
| **Python Binding Layer** | Provide Python-visible API compatible with `kitty/shaders.py`, backed by Metal handles instead of GL IDs. | Rewrite `kitty/fast_data_types` metal sections. |
| **Diagnostics** | GPU capture hooks, log integration, runtime toggles. | Shared logging utilities and new CLI toggles. |

### 5.2 Execution Flow

1. Window creation requests a Metal backend; GLFW delegates to custom Cocoa glue that installs a CAMetalLayer on the NSWindow content view.
2. On frame start, the renderer obtains `CAMetalDrawable` via `nextDrawable()` inside an autorelease pool to avoid drawable exhaustion (per Apple guidance).
3. Command buffers are sourced from a per-surface `MTLCommandQueue`. Encoders are created for each pass (background clear, text quads, imagery, debug overlays).
4. Resource managers stage glyph and image data using `MTLBlitCommandEncoder` when needed, syncing with CPU via fences/events.
5. Upon encoding completion, the command buffer is committed and presents the drawable. Completion handlers recycle resources and schedule idle callbacks.
6. Python code interacts with the backend through a normalized API that abstains from exposing raw Metal pointers, using opaque handles and command batching helpers.

## 6. Detailed Design

### 6.1 Window Surface & Swapchain

- **CAMetalLayer integration:**  
  - Replace NSOpenGL context creation with a Cocoa helper that sets `NSView.wantsLayer = YES` and assigns a `CAMetalLayer`.  
  - Configure pixel format (BGRA8Unorm or BGRA8Unorm_sRGB) and `presentsWithTransaction = NO` for low-latency presentation.  
  - Track drawable size updates via `viewDidChangeBackingProperties` to handle retina scaling gracefully.  
  - Respect Apple’s drawable lifecycle requirements (release drawables after `presentDrawable:` on committed command buffer).
- **Swap Interval & Frame Pacing:**  
  - Implement throttling via `MTLCommandBuffer` `presentAtTime:` to mimic VSync toggles currently exposed via `apply_swap_interval`.  
  - Provide fallback frame pacing when running headless (tests) using `CAMetalLayer.displaySyncEnabled`.
- **Resource Attachment:**  
  - Build `MTLRenderPassDescriptor` templates per surface, binding `drawable.texture` to color attachment 0 and optionally offscreen textures for special effects (e.g., background blur).

### 6.2 MetalSubsystem Runtime

- Initialize `MTLDevice` via `MTLCreateSystemDefaultDevice()` once during backend selection.  
- Allocate a dedicated `MTLCommandQueue` per surface to simplify workload isolation. Queue creation happens during `metal_backend_init`.  
- Expose thread-safe getters for device, queue, feature flags (supportsIndirectCommandBuffers, programmableBlending, etc.).  
- Implement device loss callbacks by observing `MTLDeviceNotificationNameWasRemoved` and triggering fallback or app restart logic.

### 6.3 Resource & Memory Management

- **Buffers:**  
  - Introduce `MetalBufferPool` to maintain triple-buffered vertex/uniform buffers sized to the largest expected frame.  
  - Use `MTLStorageModeManaged` on Intel Macs, `MTLStorageModeShared` on Apple Silicon for reduced copy overhead.  
  - Provide `reserve_vertex_space(size_t bytes)` style APIs analogous to existing VBO routines.
- **Textures:**  
  - Glyph atlas stored as `MTLTexture` with `MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite`; updates executed via `MTLBlitCommandEncoder` copy from staging buffers.  
  - Image textures support array textures to replace `GL_TEXTURE_2D_ARRAY` semantics.  
  - Handle SRGB conversions explicitly because Metal requires sampler/texture descriptors to define color space.
- **Samplers:**  
  - Cache `MTLSamplerState` objects keyed by filter/wrap modes previously expressed via OpenGL constants.
- **Synchronization:**  
  - Use `MTLFence` or `MTLEvent` to coordinate CPU writes and GPU reads when reusing buffers across frames.

### 6.4 Shader & Pipeline Strategy

- Translate each GLSL shader pair into Metal Shading Language (MSL). Maintain the conceptual grouping (cell program, border program, image program, etc.).  
- Organize MSL sources under `kitty/metal/shaders/`.  
- Extend build tooling to run `xcrun metal` → `metal-ar` → `metallib`, producing bundled libraries per program set.  
- At runtime, load `MTLLibrary` objects from the packaged metallib data (embedded via generated C arrays or resource files).  
- Build `MTLRenderPipelineDescriptor` mirroring current blending/state:  
  - color attachment 0 with premultiplied alpha blending  
  - vertex descriptor matching per-vertex attributes (position, UV, color).  
- Replace `compile_program` API with `create_pipeline(program_id, allow_rebuild=False)` that returns an opaque pipeline handle, caching `MTLRenderPipelineState` per program.

### 6.5 Command Encoding & Render Passes

- Sequence passes similarly to current GL renderer: clear, background fill, main grid, underline/strike layers, image overlays, debug overlays.  
- Each pass obtains an `MTLRenderCommandEncoder` with matching pipeline state and bound resources.  
- Uniform data previously sent via `glUniform*` becomes small constant buffers or argument buffers.  
- Introduce helper to bind per-pass textures/samplers to expected indices to keep Python call sites stable.

### 6.6 Python/FFI Layer

- Expose backend-neutral operations through `kitty/fast_data_types`:
  - `create_pipeline(program_id, allow_recompile=False)`
  - `bind_pipeline(pipeline_handle)`
  - `allocate_vertex_buffer(size_bytes)`
  - `submit_frame(commands_handle)` (optional future batching)
- Internally store handles as lightweight structs referencing Metal objects; reference counts mirror Python expectations.  
- Maintain compatibility shim for existing Python code by updating `kitty/shaders.py` to call new APIs while preserving function names where feasible.  
- Provide migration helpers for code that expects raw GL enum constants (e.g., convert to backend-agnostic enums).

### 6.7 Diagnostics & Tooling

- Integrate Metal validation toggles (set `MTLDevice` `newCommandQueueWithDescriptor` with `MTLCommandQueueDescriptorErrorOptions`).  
- Provide environment flag to enable GPU capture-friendly names (`setLabel:` on buffers/textures).  
- Extend `kitty/debug_config.py` to report Metal device name, driver version, and active backend.  
- Capture per-frame telemetry (frame time, command buffer duration) for logging.

### 6.8 OpenGL Text Pipeline Inventory (Parity Baseline)

Metal has to reproduce the OpenGL data path before we can iterate. The current renderer organizes the text grid as follows:

- **Shader programs & variants**
  - `CELL_PROGRAM` draws background + foreground in a single instanced pass.
  - `CELL_BG_PROGRAM` recompiles the same sources with `ONLY_BACKGROUND` for layered UI.
  - `CELL_FG_PROGRAM` recompiles with `ONLY_FOREGROUND`, adding cursor and decoration sprites.
  - All three bind the shared `CellRenderData` UBO, `gamma_lut[256]`, `sprites` (glyph atlas, unit `SPRITE_MAP_UNIT`), and `sprite_decorations_map` (unit `SPRITE_DECORATIONS_MAP_UNIT`).
- **Vertex inputs**
  - Instanced attribute 0 (`uvec3 colors`) reads `GPUCell.fg`, `GPUCell.bg`, `GPUCell.decoration_fg`.
  - Attribute 1 (`uvec2 sprite_idx`) draws from `GPUCell.sprite_idx` plus decoration page index.
  - Attribute 2 (`uint is_selected`) is sourced from the selection buffer and drives highlight logic.
- **Buffers**
  - Cell instance buffer = tightly packed `GPUCell` array (`sizeof(GPUCell) == 20`) mapped via `cell_prepare_to_render()`.
  - Selection buffer = one byte per cell populated by `screen_apply_selection()`.
  - Uniform buffer = streamed `GPUCellRenderData` structure containing cursor bounds, atlas metrics (`sprites_xnum`, `sprites_ynum`, `cell_width`, `cell_height`), inactive text alpha, dim/blink opacity, and expanded color tables.
- **Textures & samplers**
  - Glyph atlas is a `GL_TEXTURE_2D_ARRAY` sized `sprites_xnum * cell_width` × `sprites_ynum * (cell_height + 1)` × `z` with `GL_SRGB8_ALPHA8` storage and `GL_NEAREST` filtering.
  - Decorations map is a `GL_TEXTURE_2D` (`GL_R32UI`) storing underline/strike sprite indices per glyph; also `GL_NEAREST`.
  - `send_sprite_to_gpu()` handles uploads via `glTexSubImage3D/2D` after `sprite_tracker` picks coordinates.
- **CPU staging**
  - `screen_update_cell_data()` renders dirty lines into `Line::gpu_cells` and copies the results into the mapped instance buffer.
  - `screen_apply_selection()` writes highlight masks; `grman_update_layers()` prepares image layers consumed by `draw_cells_with_layers()`.
- `draw_cells()` chooses layered vs non-layered path and issues instanced draws over `lines * columns`.

This inventory is the contract the Metal backend must satisfy when reconstructing buffers, textures, and shader logic.

### 6.9 Metal Text Resource Layout (Proposed)

- **Per-font atlas state** — extend `SpriteMap` with a `MetalSpriteMap` payload containing:
  - `id<MTLTexture> glyph_array;` (`MTLTextureType2DArray`, `MTLPixelFormatBGRA8Unorm_sRGB`, `MTLStorageModePrivate`).
  - `id<MTLTexture> decorations;` (`MTLPixelFormatR32Uint`, `MTLTextureType2D`, `MTLStorageModePrivate`).
  - `id<MTLBlitCommandEncoder>` usage hooks so uploads happen via `replaceRegion:` when data is CPU-side or `copyFromBuffer` when we stage into a shared upload buffer.
  - Cached dimensions (`sprites_xnum`, `sprites_ynum`, `layers`, `cell_width`, `cell_height_plus1`) for quick validation against CPU layout.
- **Sampler state** — global `id<MTLSamplerState> glyph_sampler;` configured via `MTLSamplerDescriptor` with `minFilter = magFilter = nearest`, `addressMode = clampToEdge`, and `normalizedCoordinates = YES`.
- **Pipeline objects** — create three `id<MTLRenderPipelineState>` items mirroring GL programs (full, background-only, foreground-only). Vertex descriptor maps:
  - Buffer 0: `MTLVertexFormatUInt4` for `gpu_cell_colors_idx` (we pack fg/bg/decoration into `uint4` with final slot reserved for future flags).
  - Buffer 1: `MTLVertexFormatUInt2` for `sprite_idx`.
  - Buffer 2: `MTLVertexFormatUChar` for selection mask (promoted to `uint` in shader).
- **Uniform buffers** — introduce `struct MetalCellUniforms` aligned to 16 bytes and shared between Objective-C++ and MSL. Allocate a per-surface ring of 3 `MTLBuffer` objects (`storageModeShared`) sized to hold `GPUCellRenderData`. Each frame cycles the ring to avoid CPU/GPU contention, with `didModifyRange:` for managed macOS targets.
- **Instance + selection buffers** — allocate resizable `MTLBuffer` objects per `Screen`:
  - `cell_instances` sized `sizeof(GPUCell) * columns * lines`, `storageModeShared`.
  - `selection_mask` sized `columns * lines`, `MTLResourceCPUCacheModeWriteCombined`.
  - Both buffers reuse the existing CPU staging produced by `screen_update_cell_data()` and `screen_apply_selection()` by memcpy-ing into `buffer.contents`.
- **Command encoding** — build a `MetalTextEncoder` helper that:
  1. Ensures atlas textures match sprite tracker layout, reallocating with `newTextureWithDescriptor:` when `sprites_xnum`/`ynum` change.
  2. Uploads dirty glyph slices via `replaceRegion:mipmapLevel:slice:withBytes:bytesPerRow:bytesPerImage:` (or blit from staging buffer for contiguous regions).
  3. Writes uniform data into the current ring buffer, binds textures/samplers, sets vertex buffers (quad positions remain implicit via `vertex_id` logic), then issues `drawPrimitives:vertexStart:vertexCount:instanceCount:` with `vertexCount == 4`.

This layout keeps CPU producers untouched while giving Metal explicit ownership of textures, buffers, and pipeline state.

## 7. Build, Packaging, and Tooling Updates

- Modify `setup.py:680-706` to drop `-framework OpenGL` in favor of `-framework Metal -framework QuartzCore -framework MetalKit (optional)` and include metallib assets in the package data.  
- Add build step invoking `.venv/bin/python3.13` script to compile MSL → metallib during `make devel` and `python3 setup.py build`.  
- Update `Makefile` and CI scripts to ensure Xcode Command Line Tools are present and `xcrun metal` is available.  
- Extend `gen/` tooling to regenerate shader headers with offsets/attribute bindings.  
- Ensure notarization pipeline includes metallib files.

## 8. Testing & Validation Strategy

- **Unit Tests:**  
  - Introduce headless rendering harness using `MTLCommandBuffer` offscreen targets; verify pixel hashes for canonical frames (basic grid, emoji, image).  
  - Add Python tests exercising new backend-neutral APIs (compile pipeline, upload glyph) via `basedpyright` type checking.
- **Integration Tests:**  
  - Extend `./test.py` to run macOS-specific GPU smoke tests using `KITTY_GPU_BACKEND=metal` with screenshot comparisons.  
  - Leverage Apple’s Metal validation layer during CI to catch state errors.  
  - Add performance regression scripts comparing OpenGL baseline vs Metal (until OpenGL removed).
- **Manual QA:**  
  - Document checklist (retina scaling, ligatures, color emoji, background images, window resizing, transparency).

## 9. Migration, Risks, and Rollout

- **Phase 0 – Bootstrapping:** implement surface creation + clear color rendering; deliver minimal window with Metal context.  
- **Phase 1 – Text Rendering:** port glyph atlas upload and core grid rendering; achieve monochrome text parity.  
- **Phase 2 – Decorations & Images:** port underline/strike, border effects, and image protocol.  
- **Phase 3 – Advanced Effects:** implement blur, shaders with dynamic uniforms, animations.  
- **Phase 4 – Diagnostics & Telemetry:** finalize logging, GPU capture support.  
- **Phase 5 – Rollout:** enable feature flag default-on, remove OpenGL fallback, update docs.

**Key Risks (acknowledging catastrophic tolerance):**

- **Shader translation bugs:** mitigate with dual-render comparisons during Phases 1-3.  
- **Drawable starvation:** solved by strict autorelease usage and frame pacing loops (CAMetalLayer guidance).  
- **Pipeline state explosion:** enforce cache eviction and compile-time pipeline generation.  
- **CI hardware limitations:** secure dedicated Apple Silicon runner with GPU access; fallback to nightly tests if PR gating infeasible.  
- **Python API drift:** maintain compatibility wrappers until major release to reduce breakage.

## 10. Milestones & Timeline (Agile Targets)

| Milestone | Exit Criteria | Owner(s) | Target |
|-----------|---------------|----------|--------|
| M0: Surface bootstrap | Metal backend creates window, clears to background color | Rendering team | 2 weeks |
| M1: Text pipeline parity | Text grid renders correctly; screenshot diff < 1% | Rendering + Fonts | 5 weeks |
| M2: Graphics protocol parity | Images, shaders, animations ported | Rendering | 9 weeks |
| M3: Diagnostics + performance | Validation hooks, telemetry, perf parity ±5% | Tooling | 11 weeks |
| M4: Rollout readiness | CI green, documentation updated, feature flag default | All | 14 weeks |

With unlimited time available, milestones can be extended, but sequencing should stay intact to limit regression scope.

## 11. Open Questions

1. Do we retain any OpenGL stubs for compatibility with older macOS releases (< 10.15) or drop support entirely?  
2. Should we introduce a higher-level render graph abstraction to aid future portable backends (e.g., wgpu)?  
3. How do we expose Metal debug capture toggles to users without bloating CLI surface?  
4. What is the fallback when Metal device creation fails (e.g., headless SSH sessions)?

## 12. References

- Apple Developer Documentation — *Setting up a command structure* (Metal command buffers/queues).  
- Apple Developer Documentation — *CAMetalLayer* class reference (drawable management, presentation).  
- Apple Developer Documentation — *MTLRenderPipelineState* reference (pipeline creation & reuse).  
- Kitty repository files:
  - `kitty/glfw.c:1340-1395` — OpenGL context initialization flow.  
  - `kitty/gl.c`, `kitty/graphics.c` — Current rendering loops.  
  - `kitty/shaders.c:1416-1499` — Python-facing OpenGL API.  
  - `kitty/fonts/core_text.py` — CoreText-based font discovery (unchanged).

## 13. Milestone 0 Prototype Status

- Initial prototype work replaces the legacy GLFW OpenGL context with a CAMetalLayer-backed surface when `KITTY_GPU_BACKEND=metal` is set.  
- `metal_surface.mm` now allocates a per-window Metal state (device, command queue, drawable, command buffer) and issues a clear-only render pass using `MTLClearColor`.  
- `kitty/glfw.c` short-circuits the OpenGL hints, skips GL initialization, and integrates Metal lifecycle calls (init, frame begin/end, teardown).  
- `child-monitor.c` detects Metal windows and drives a minimal frame loop that clears the drawable to Kitty’s configured background color before presenting.  
- `setup.py` links the Metal/QuartzCore frameworks and defines `KITTY_ENABLE_METAL` so the new Objective-C++ code paths participate in the build.
- Added `kitty_tests/metal_bootstrap.py` to exercise the Metal bootstrap path headlessly and guard against regressions.

---

**Next Steps:** socialize this design with maintainers, spin up prototype branch, and begin Milestone 0 implementation under the documented plan.
