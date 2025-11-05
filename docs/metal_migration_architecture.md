# Metal Renderer Architecture Specification (Draft – 2025-11-03)

This document proposes the target architecture for Kitty’s macOS Metal backend, derived from the current OpenGL surface inventory.

## 1. Overview

- Replace OpenGL context + shaders with a Metal-based rendering stack while preserving existing Python APIs through an abstraction layer.
- Maintain feature parity: text rendering, graphics protocol, animations, background images, transparency, high-DPI support.
- Enable runtime selection between Metal and legacy OpenGL during rollout.

## 2. High-Level Components

1. **MetalSubsystem** (singleton)
   - Owns `id<MTLDevice>`, `id<MTLCommandQueue>`, feature flags, and global caches.
   - Provides thread-safe accessors for per-frame objects and shared pipeline state.
   - Handles device loss detection and fallback to legacy backend.

2. **MetalSurface**
   - Wraps `CAMetalLayer` tied to a Kitty `OSWindow`.
   - Tracks drawable size, scale factor, and maintains a reusable render pass descriptor template.
   - Provides methods `acquireDrawable()`, `presentDrawable(commandBuffer, drawable)`.

3. **Resource Managers**
   - `MetalTextureManager`: Handles glyph atlases, image textures, and dynamic uploads via staging buffers.
   - `MetalBufferPool`: Maintains triple-buffered `MTLBuffer` sets for vertices, indices, uniform/constant data, with explicit synchronization fences.
   - `MetalPipelineCache`: Lazily builds and caches `MTLRenderPipelineState` objects keyed by shader + blending + vertex descriptor combos; invalidated on metallib reload.

4. **Shader/Program Layer**
   - Metallib bundles generated at build time (`kitty/metal/*.metallib`) containing all translated MSL shaders.
   - Runtime loader constructs `MTLLibrary` instances from bundled data and resolves function handles.
   - Adapter functions mimic existing `compile_program` semantics by mapping program IDs to pipeline descriptors.

5. **Command Encoder Flow**
   - Per-frame `@autoreleasepool`.
   - Acquire drawable; build frame-specific `MTLRenderPassDescriptor`.
   - Encode rendering passes (text cells, decorations, images, trails) via `MTLRenderCommandEncoder`.
   - Commit command buffer with completion handler for resource recycling; present drawable.

6. **Backend Abstraction Layer**
   - New interface (e.g., `struct RendererBackendOps`) exposing functions currently provided by `gl.h`.
   - Python/C module `fast_data_types` switches between OpenGL and Metal implementations based on runtime flag.

## 3. Initialization Sequence

1. During Kitty startup on macOS, attempt `MTLCreateSystemDefaultDevice()`.
2. Validate device feature set (`supportsFamily:MTLGPUFamilyMac1` or newer) and capture supported pixel formats (target `MTLPixelFormatBGRA8Unorm_sRGB`).
3. Instantiate global `MetalSubsystem` with command queue, default sampler states, and pipeline cache.
4. For each window creation:
   - Create `CAMetalLayer`, attach to GLFW view.
   - Configure `drawableSize`, `pixelFormat`, `maximumDrawableCount`, `framebufferOnly`.
   - Initialize `MetalSurface` with references to buffer pools and texture manager.

## 4. Resource & Memory Management

- Textures:
  - Glyph atlases stored as private `MTLTexture` objects; uploads via staging `MTLBuffer` + blit encoder.
  - Graphics protocol images stored similarly, tracking premultiplied vs straight alpha.
- Buffers:
  - Vertex data for cell quads stored in dynamic buffers sized per viewport.
  - Uniforms/uniform blocks translated to `MTLBuffer` constant regions or argument buffers.
- Synchronization:
  - Use command buffer completion handlers to recycle staging buffers and mark textures ready.
  - Track inflight frame count to avoid exceeding drawable limit (max three).

## 5. Shader Translation & Pipeline States

- GLSL → MSL conversion performed during build; maintain per-shader metadata (uniform layouts, texture bindings) to map existing Python constants.
- Define canonical vertex descriptors for text cells, borders, trails, etc.
- Pre-create render pipeline states after metallib load; variant combinations for premultiplied alpha, sRGB, blending toggles.
- Expose pipeline IDs analogous to existing GL program IDs for compatibility.

## 6. Python/C API Adaptation

- Extend `fast_data_types` to load either GL or Metal backend at import based on platform/flag.
- Replace GL enums with backend-neutral constants; provide compatibility layer translating to Metal pipeline IDs.
- Update APIs: `compile_program`, `create_vao`, `bind_vertex_array` become no-ops or proxies under Metal, while new calls manage buffer descriptors and resource handles.
- Diagnostics: Implement `metal_renderer_info()` returning device name, feature sets, metallib version.

## 7. GLFW Integration Strategy

- Option A: Upstream-compatible patch to GLFW adding a Metal renderer path triggered via new context hint.
- Option B: Maintain internal fork enabling `CAMetalLayer` plus presentation callbacks.
- Requirements:
  - Replace `_glfwCreateContextNSGL` usage with new `kitty_glfw_metal_init`.
  - Ensure event loop integration (`glfwSwapBuffers`, `glfwMakeContextCurrent`) works with Metal surfaces.
  - Keep LayerShell and retina behaviour consistent.

## 8. Error Handling & Debugging

- Enable Metal API Validation in debug builds (conditional via options).
- Map Metal errors to kitty logs; fatal errors trigger fallback to OpenGL (if available) or graceful shutdown.
- Provide GPU capture hooks (e.g., `MTLCaptureManager`) accessible via debug option.

## 9. Testing Hooks

- Add test seams for injecting mock metallib or verifying pipeline compilation.
- Provide screenshot/texture dump tooling similar to `save_texture_as_png`, using `MTLTexture` readbacks.
- Ensure Python-level tests can detect backend selection and exercise Metal-specific diagnostics.

## 10. Open Questions / TBD

- Final decision on backend abstraction boundary (C-only vs C/Python hybrid).
- Handling of dynamic shader recompilation (currently GLSL supports `allow_recompile`).
- Strategy for hot reload of metallib during development (`xcrun metal` integration).
- Integration with existing options (`debug_rendering`, `sync_to_monitor`) and how they map to Metal semantics.

This draft serves as the baseline for implementation tasks and should be refined collaboratively with the assigned Metal migration team.

