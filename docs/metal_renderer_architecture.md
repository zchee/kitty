# Metal Renderer Architecture Plan

## Status
- Phase: 2 (Implementation – Metal fail-fast enforcement)
- Maintainers: TBD (requires assignment of Metal specialist, renderer generalist, macOS build/CI, QA automation)
- Inputs: `.agent/MEMORY.md` roadmap, existing OpenGL implementation under `kitty/` and `glfw/`

## Goals
1. Deliver Metal backend for macOS with full feature parity to the current OpenGL renderer.
2. Maintain OpenGL backend for non-macOS platforms; macOS runs exclusively on Metal.
3. Avoid regression in performance, latency, and visual fidelity.
4. Preserve test and CI coverage while adding backend-specific validation.

## Non-Goals
- Supporting additional graphics APIs (Vulkan, DirectX) in this effort.
- Rewriting non-rendering subsystems (input, compositor, font cache) unless required for backend decoupling.

## Constraints
- No partial implementations: each phase exits with shippable, fully tested behavior.
- Tests must exist for every new function (unit or integration as appropriate).
- No code duplication: abstractions must reuse existing logic where possible.
- Metal backend must run on macOS 13+ (Apple Silicon and Intel with supported GPUs).
- Build system continues to support cross-platform targets without Metal dependencies.
- macOS Metal initialization failures must surface fatal errors; do not fall back to OpenGL.

## Current OpenGL Touch Points
| Area | File(s) | Notes |
|------|---------|-------|
| Context lifecycle | `glfw/nsgl_context.m`, `glfw/cocoa_window.m` | NSOpenGLContext creation, shared context, swap/present |
| Renderer bootstrap | `kitty/gl.c`, `kitty/glfw.c` | glad init, capability detection, GLFW integration |
| Rendering core | `kitty/graphics.c`, `kitty/window.c`, `kitty/shaders.c`, `kitty/gl_shader_cache.c` | Draw calls, buffer updates, shader compilation |
| Shader assets | `kitty/*.glsl`, `kitty/shaders.py` | GLSL compilation, include processing, shader cache |
| Build hooks | `setup.py`, `Makefile` | OpenGL frameworks, compilation flags, packaging |

## Proposed Backend Architecture
```
+---------------------+
| kitty/graphics.c    |  <-- backend-agnostic rendering commands
+----------+----------+
           |
+----------v----------+
| RendererBackend API |
|  - init(device_opts) |
|  - shutdown()        |
|  - begin_frame()     |
|  - draw_pass(pass)   |
|  - present(sync)     |
+-----+---------+-----+
      |         |
+-----v----+ +--v------------------+
| OpenGL  | | Metal                |
| backend | | backend (new)        |
+---------+ +----------------------+
```

### Backend Lifecycle Responsibilities
To keep the OpenGL and Metal implementations aligned, the backend API has to surface every lifecycle step that `gl.c` currently performs implicitly. Capturing those responsibilities up front gives us an objective checklist for the expanded interface.

1. **Global bootstrap**
   - Detect required capabilities (`gl_init` for OpenGL, `MTLCreateSystemDefaultDevice` for Metal).
   - Create backend-wide objects (shared GL context, Metal device/command queue).
   - Install debugging/error callbacks such as `gladSetGLPostCallback` or Metal device notification handlers.

2. **Window attachment**
   - Bind the drawable surface (`NSOpenGLContext` FBO or `CAMetalLayer`) and apply `RendererWindowConfig`.
   - Register for resize/content-scale events so swapchains can be updated promptly.

3. **Context binding**
   - Provide `make_context_current`/`restore_context` semantics for OpenGL.
   - Supply an acquisition token for Metal drawable ownership so higher layers can bracket rendering safely.

4. **Frame lifecycle**
   - `begin_frame` prepares default framebuffers/render pass descriptors and clears staging areas.
   - `encode_pass` consumes backend-neutral render pass descriptions and issues draw calls/encoders.
   - `present` submits the command buffer or swaps framebuffers while honoring swap-interval policy.

5. **Resize & suspend handling**
   - `on_resize` reallocates attachments when framebuffer size or scale changes.
   - `on_suspend`/`on_resume` respond to device loss, display sleep, or app nap transitions.

6. **Resource helpers**
   - Centralize buffer/texture allocation and destruction to replace direct OpenGL calls (`create_buffer`, `free_texture`, etc.).
   - Coordinate shader/pipeline cache management so GLSL → MSL translation stays consistent across backends.

> **Status (Oct 24 2025)**: The Metal backend now routes capture cleanup through `metal_reset_capture_state`, and debug-only exports expose per-window capture metadata so tests can assert lifecycle correctness without mocks.

### Proposed Backend API Shape
The expanded C surface pairs the lifecycle above with explicit data carriers so that higher-level code calls a uniform contract regardless of backend.

```c
typedef struct RendererBackend RendererBackend;

typedef struct RendererInitConfig {
    bool prefer_low_latency;
    bool enable_debug_labels;
} RendererInitConfig;

typedef struct RendererFrameParams {
    monotonic_t frame_start_time;
    bool vsync_enabled;
} RendererFrameParams;

typedef struct RendererPresentParams {
    bool blocking;            // respect swap interval
    bool capture_framebuffer; // used by screenshots/tests
} RendererPresentParams;

typedef struct RendererResizeParams {
    int framebuffer_width;
    int framebuffer_height;
    float framebuffer_scale;
} RendererResizeParams;

typedef struct RendererBackendOps {
    const char *name;
    bool  (*ensure_initialized)(const RendererInitConfig *cfg);
    void  (*shutdown)(void);
    bool  (*attach_window)(GLFWwindow *window, const RendererWindowConfig *config);
    void* (*make_context_current)(GLFWwindow *window);
    void  (*restore_context)(void *token);
    bool  (*begin_frame)(RendererFrameParams *params);
    bool  (*encode_pass)(const RenderPass *pass);
    bool  (*present)(RendererPresentParams *params);
    void  (*on_resize)(const RendererResizeParams *params);
    void  (*on_suspend)(void);
    void  (*on_resume)(void);
} RendererBackendOps;
```

- `RendererBackend` remains opaque; backends manage their own state.
- `ensure_initialized` gates global device/context creation. It should be idempotent.
- `make_context_current`/`restore_context` are no-ops for Metal but remain required to keep the OpenGL path functioning.
- `encode_pass` operates on the existing backend-neutral render-pass description produced by `graphics.c`.
- All hooks return `bool` when failure is meaningful so the caller can surface fatal errors promptly.

### OpenGL Compatibility Checklist
To ensure the existing renderer slots cleanly into this interface, every hook maps to code that already runs today:

| Proposed Hook | Current OpenGL Implementation | Notes |
|---------------|------------------------------|-------|
| `ensure_initialized` | `gl_init` (sets version, installs debug callbacks) | Called once per process; already idempotent. |
| `shutdown` | No-op today; would wrap teardown routines used during exit. | Placeholder to keep parity with Metal device teardown. |
| `attach_window` | `glfwAttachContextToWindow` logic inside `glfw.c` / `nsgl_context.m` | Needs extraction so window config flows through `RendererWindowConfig`. |
| `make_context_current` / `restore_context` | `glfwMakeContextCurrent` pairing spread across `glfw.c` | Direct mapping; tokens can remain `NSOpenGLContext*`. |
| `begin_frame` | Combination of `glBindFramebuffer`, `set_gpu_viewport`, and clear paths in `gl.c` | Will move into adapter to prep default framebuffer. |
| `encode_pass` | Draw paths in `graphics.c` (`draw_quad`, shader binds, texture uploads) | Requires refactor to emit render-pass descriptors consumed by backend. |
| `present` | `renderer_backend_swap_buffers` ➜ `glfwSwapBuffers` (with CVDisplayLink pacing) | Hook already exists; we broaden parameters. |
| `on_resize` | `resize.c` + `glViewport` and framebuffer reallocations | Adapter will forward framebuffer size changes. |
| `on_suspend` / `on_resume` | Currently unused hooks; OpenGL path can log + clear caches. | Metal will use them for device-loss events. |

This audit confirms there is a GL owner for every lifecycle stage, so the refactor can proceed without behavioural regressions.

### C Interface (Phase 1 deliverable)
```c
typedef struct RendererBackendOps {
    bool    (*init)(RendererConfig *cfg, RendererContext *out_ctx);
    void    (*shutdown)(RendererContext *ctx);
    bool    (*begin_frame)(RendererContext *ctx, FrameParams *params);
    void    (*encode_pass)(RendererContext *ctx, const RenderPass *pass);
    bool    (*present)(RendererContext *ctx, PresentParams *params);
    void    (*on_resize)(RendererContext *ctx, int width, int height, float scale);
    void    (*on_suspend)(RendererContext *ctx);
    void    (*on_resume)(RendererContext *ctx);
} RendererBackendOps;
```
- `RendererContext` will wrap backend-specific state via opaque pointer.
- Existing OpenGL code becomes the first implementation of `RendererBackendOps` without semantic change.

### Python Integration
- `kitty/glfw.py` (and any Python callers) interact with renderer through a thin C API exported from `kitty/glwrapper` module.
- Introduce configuration flag (`metal_renderer = auto|metal`) stored in `kitty/options/definition.py` and exposed via CLI; `auto` enforces Metal on macOS 13+ and fails fast if initialization is unavailable.

## GLFW / Windowing Changes
- Replace direct NSOpenGLView usage with backend-owned view stacks.
- For Metal backend create CAMetalLayer during window creation and pass pointer to C backend.
- Maintain NSOpenGLContext for OpenGL path; both share resized via unified callback.
- CVDisplayLink remains the timing source; backend decides presentation path.

## Shader Pipeline Strategy
1. Retain existing GLSL asset layout as authoritative source.
2. Introduce translation stage to MSL using either bespoke translator or shader transpiler; store Metal-specific versions in build cache.
3. Augment `kitty/shaders.py` to emit shader metadata (uniform layouts, sampler usage) consumed by both backends.
4. Validation: unit tests confirm GLSL/ MS L pairs share signatures; integration tests run image diff across backends.

## Build & CI Requirements
- Extend `setup.py` to:
  - Detect Xcode toolchain and run `xcrun metal`/`metallib` for `.metal` generation.
  - Package metallib inside app bundle and standalone build.
  - Link `Metal`, `MetalKit`, `QuartzCore` frameworks when Metal backend enabled.
  - Validate that the build uses the same Python framework as the runtime (no accidental `PythonT.framework` linkage) and fail fast otherwise.
- CI enhancements:
  - macOS runners with Metal support (Apple Silicon + Intel).
  - Artifact upload of metallibs for test reuse.
  - New test targets: `./test.py metal-backend` exercising backend selection and rendering snapshots.

## Acceptance Criteria (Phase 0 exit)
- Architecture document reviewed and approved by core maintainers.
- Consensus on backend API signatures (C and Python boundary).
- Confirmation of minimum macOS version, hardware, and CI resource availability.
- Agreement on shader translation approach and testing methodology.
- Identified owners for each subsequent phase and estimated timelines approved by project lead.

## Debugging Controls
- `kitty --debug-metal` enables verbose Metal renderer logging on macOS. When active, Metal device lifecycle, drawable acquisitions, and command submission events emit via `timed_debug_print`, mirroring existing OpenGL debug flags without muting fatal error reporting.
- `kitty --metal-gpu-capture` forces every swap to capture the CAMetalLayer framebuffer for offline inspection. Captured frames remain available through `metal_renderer_copy_captured_frame_for_tests` and the runtime flag diagnostics, and the toggle automatically blocks until command buffers complete.
- Both toggles surface through the renderer backend configuration so tests and integrations can verify runtime state via `metal_renderer_debug_get_runtime_flags_for_tests`.

## Risks & Mitigations
- **Shader parity risk**: complex GLSL features may not map directly to MSL. Mitigation: spike transpilation early, maintain automated shader tests.
- **Performance regression**: Metal path may expose bottlenecks. Mitigation: integrate profiling tools (Metal System Trace) during Phase 4.
- **Build complexity**: Metallib compilation increases build time. Mitigation: cache compiled outputs and reuse in CI.
- **Fallback reliability**: need robust error handling. Mitigation: enforce positive and negative initialization tests in Phase 2.

## Next Actions
1. Schedule design review with graphics maintainers and macOS lead.
2. Assign engineers to roles outlined above and provision required hardware.
3. Begin Phase 1 tasks once approvals are recorded.
