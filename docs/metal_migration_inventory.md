# Kitty OpenGL Surface Inventory (2025-11-03)

This document captures the current OpenGL-facing surface area that must be rewritten or abstracted during the Metal migration.

## 1. Native Modules (C / Objective-C)

### `glfw/nsgl_context.m`
- `_glfwInitNSGL`, `_glfwTerminateNSGL`, `_glfwCreateContextNSGL`, `makeContextCurrentNSGL`, `swapBuffersNSGL`, `destroyContextNSGL`.
- Establishes NSOpenGL pixel formats and contexts, retains a global shared context, and wires GLFW callbacks (`makeCurrent`, `swapBuffers`, `swapInterval`, `getProcAddress`, `destroy`) to the rest of Kitty.
- Responsible for retina scaling via `[window->ns.view setWantsBestResolutionOpenGLSurface:]` and swap interval configuration.

### `kitty/gl.c` / `kitty/gl.h`
- Loads OpenGL via glad (`gladLoadGL`), installs debug/error callbacks, and exposes renderer-wide helpers consumed throughout Kitty.
- Key APIs exported in `gl.h`: `gl_init`, `gl_version_string`, framebuffer helpers (`bind_framebuffer_for_output`, `check_framebuffer_status`), texture utilities (`free_texture`, `save_texture_as_png`), viewport/scissor management (`set_gpu_viewport`, `save_viewport_*`, `restore_viewport`), draw helpers (`draw_quad`), VAO/uniform management (`create_vao`, `add_buffer_to_vao`, `bind_program`, `init_uniforms`, `compile_shaders`).
- Maintains OpenGL state caches (`Program`, `Uniform`, `UniformBlock`) consumed by `kitty/shaders.c` and higher layers.

### `kitty/shaders.c`
- Bridges Python calls from `kitty.fast_data_types` into OpenGL, providing functions such as `compile_program`, `bind_program`, `create_vao`, `unbind_vertex_array`, `sprite_map_set_limits`, `init_cell_program`, `init_borders_program`.
- Handles GLSL shader compilation/linking (`compile_shaders`, `attach_shaders`, `init_uniforms`) and caches program metadata (`Program` array indexed by constants exported to Python).
- Exposes GL enums/constants to Python via `PyModule_AddIntConstant` (e.g., `GL_TRIANGLE_FAN`, `GL_TEXTURE_2D_ARRAY`, `GL_BLEND`).

### `kitty/graphics.c`
- Uses `TextureRef` structures backed by OpenGL texture IDs (`free_texture_ref`, `texture_id_for_img`) and relies on `gl.c` helpers for uploading/composing image data.
- Implements Graphics Protocol commands that ultimately bind textures/framebuffers through `gl.h` interfaces.

### `kitty/glfw.c`
- Manages cross-platform window interactions and coordinates swap intervals; includes macOS-specific code paths guarded by `#ifdef __APPLE__` that depend on the NSOpenGL-backed GLFW context.

### `kitty/gl-wrapper.h`
- Glad-generated header (OpenGL 3.1 core + extensions) providing all GL types, enums, and function pointers used in the C sources.

### `kitty/glfw-wrapper.h`
- Local header mediating GLFW access and integrating the GL loader; would need replacements or conditional paths when Metal replaces OpenGL.

## 2. Python Surface Area

### `kitty/shaders.py`
- High-level shader manager that loads GLSL sources (`Program.program_for`), resolves `#pragma kitty_include_shader`, and calls `fast_data_types.compile_program`.
- Maintains options-driven shader recompilation (`LoadShaderPrograms`) and constant substitutions for features like dimming, blinking, and decorations.

### `kitty/fast_data_types` (extension + stub `fast_data_types.pyi`)
- Python-exposed API surface tied to OpenGL: `compile_program`, `create_vao`, `bind_program`, `bind_vertex_array`, `unmap_vao_buffer`, `init_cell_program`, `init_borders_program`, as well as GL constants (e.g., `CELL_PROGRAM`, `GLSL_VERSION`).
- Stubs declare function signatures that expect integer GL program/VAO identifiers and GL-centric enums.

### Consumers
- Modules such as `kitty/shaders.py`, `kitty/colors.py`, `kitty/options/graphics.py` import the GL-specific constants and functions to drive rendering decisions and diagnostics.

## 3. Shader Assets

- 22 GLSL source files residing at repository root under `kitty/`:
  ```
  alpha_blend.glsl
  bgimage_fragment.glsl
  bgimage_vertex.glsl
  blit_common.glsl
  blit_fragment.glsl
  blit_vertex.glsl
  border_fragment.glsl
  border_vertex.glsl
  cell_defines.glsl
  cell_fragment.glsl
  cell_vertex.glsl
  graphics_fragment.glsl
  graphics_vertex.glsl
  hsluv.glsl
  linear2srgb.glsl
  rounded_rect_fragment.glsl
  rounded_rect_vertex.glsl
  tint_fragment.glsl
  tint_vertex.glsl
  trail_fragment.glsl
  trail_vertex.glsl
  utils.glsl
  ```
- These are composed via `kitty/shaders.py` using include pragmas and mapped onto GL programs enumerated in `kitty/shaders.c`.

## 4. Interface Contracts to Preserve/Redesign

- **Context Lifecycle**: GLFW context callbacks (`makeCurrent`, `swapBuffers`, `destroy`) expected by the platform layer; Metal replacement must supply equivalent hooks.
- **Program Identifiers**: Python modules assume opaque integer program/VAO IDs and GL constants; new abstractions must either emulate handles or provide adapter layers.
- **Shader Compilation Flow**: `compile_program(which, vertex_sources, fragment_sources, allow_recompile)` contract, error propagation (ValueError with GLSL log), and optional recompilation path.
- **Texture/Framebuffer Utilities**: `save_texture_as_png`, `free_texture`, and composition helpers invoked by graphics protocol and debugging commands.
- **Viewport/Scissor Semantics**: `save_viewport_using_top_left_origin` and `enable_scissor_using_top_left_origin` provide top-left coordinate handling tailored to OpenGL; Metal pipeline must offer equivalent conversion helpers.

## 5. Immediate Migration Implications

- Every bullet above becomes a target for abstraction or rewrite. This inventory should serve as the canonical checklist when designing the Metal-compatible interfaces and estimating work per subsystem.

