# Backend Abstraction Plan: Python/C Interface (2025-11-03)

## Objectives
- Decouple Kitty’s Python modules from OpenGL-specific concepts so the Metal backend can slot in without widespread API churn.
- Provide a backend-neutral interface served by `fast_data_types` (C extension) that supports both OpenGL and Metal implementations during rollout.
- Preserve or emulate existing call signatures to avoid breaking downstream consumers.

## Current GL-Facing Surface
- `kitty/fast_data_types` exposes GL-centric functions: `compile_program`, `init_cell_program`, `init_borders_program`, `create_vao`, `bind_vertex_array`, `unbind_vertex_array`, `unmap_vao_buffer`, `bind_program`, `unbind_program`, plus numerous GL constants (program IDs, enums).
- Python callers (e.g., `kitty/shaders.py`, `kitty/colors.py`, `kitty/options`) assume integer program handles and GL enums.
- Uniform management relies on GL semantics (locations, block indices).

## Target Abstraction Layer

### RendererBackendOps (C Side)
Define a struct of function pointers representing backend operations used by Kitty:
```c
typedef struct {
    void (*initialize)(void);
    void (*shutdown)(void);
    void (*begin_frame)(OSWindow *window);
    void (*end_frame)(OSWindow *window);
    RendererProgramHandle (*compile_program)(RendererProgramId which,
                                             const ShaderSourceSet *vertex,
                                             const ShaderSourceSet *fragment,
                                             bool allow_recompile);
    void (*destroy_program)(RendererProgramId which);
    RendererPipelineInfo (*pipeline_info)(RendererProgramId which);
    RendererBufferHandle (*create_buffer)(RendererBufferDesc desc);
    void* (*map_buffer)(RendererBufferHandle, RendererMapFlags);
    void (*unmap_buffer)(RendererBufferHandle);
    void (*set_uniforms)(RendererProgramId which, const RendererUniformPayload *);
    void (*draw_quads)(const RendererDrawArgs *);
    // ...extend as required for graphics protocol, screenshots, etc.
} RendererBackendOps;
```
- Provide concrete implementations for OpenGL (existing logic) and Metal (new code paths).
- Register backend at startup (`renderer_register_backend(&gl_ops)` or `&metal_ops`).

### Python Binding Layer
- Update `fast_data_types` module initialization to choose backend based on platform option (`--macos-renderer=metal|opengl`).
- Expose backend-neutral APIs that internally delegate to `RendererBackendOps`. For legacy compatibility, keep function names (`compile_program`) but ensure they call into backend dispatch.
- For GL-only concepts (VAOs, uniform locations), introduce shim objects:
  - `RendererProgramHandle` becomes opaque (struct or pointer). Python receives integer IDs mapped via internal table.
  - `create_vao`/`bind_vertex_array` become no-ops under Metal but maintain signature; mark as deprecated.
- Provide new APIs where necessary (e.g., buffer uploads) and update Python call sites gradually.

### Constants & Metadata
- Move GL enums into backend-specific namespaces. Export backend-neutral constants (program IDs, shader identifiers).
- Extend `fast_data_types.pyi` with typed protocols documenting the abstract interface and note backend-specific behaviour.

## Transitional Strategy
1. **Phase 1 – Refactor Without Behaviour Change**
   - Introduce `RendererBackendOps` and route existing GL code through the interface.
   - Update Python stubs to reflect opaque handles.
   - Add runtime checks ensuring backend is initialized before use.

2. **Phase 2 – Metal Implementation**
   - Implement Metal versions of the operations, mapping to architecture defined in `docs/metal_migration_architecture.md`.
   - Provide adapter code translating existing Python data structures (e.g., `Program` definitions from `kitty/shaders.py`) to Metal pipeline descriptors.

3. **Phase 3 – API Cleanup**
   - Deprecate GL-only calls; document replacements (e.g., uniform updates via structured payloads).
   - Update documentation and developer guides.

## Error Handling & Diagnostics
- Add backend identifier to diagnostic logs (e.g., `renderer_backend_name()`).
- Provide introspection APIs for Python (`get_renderer_backend_capabilities()` returning device info, supported features).
- Ensure exceptions raised by backend implementations map to Python `ValueError`/`RuntimeError` consistent with current behaviour.

## Testing Considerations
- Write unit tests verifying dispatch table selection and fallback (OpenGL vs Metal).
- Add contract tests ensuring operations like `compile_program` and `draw_quads` behave consistently across backends given mock inputs.
- Use `basedpyright` to validate updated stubs and maintain strict typing.

## Open Questions
- Exact mapping of uniform locations to Metal resources (argument buffers vs constant buffers) — resolved in implementation phases.
- Handling of runtime shader recompilation requests from Python (Metal may require pipeline rebuild rather than recompilation).
- Whether to expose explicit backend-switch API for users or rely solely on configuration options.

This plan enables incremental refactoring and ensures that the Python/C surface is ready for the Metal backend without disrupting existing workflows.

