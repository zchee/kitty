# CAMetalLayer Prototype Plan (Milestone M1) – 2025-11-03

## Goals
- Replace NSOpenGL context creation with CAMetalLayer-backed surface for a single window.
- Present a solid-color frame via Metal to verify drawables and event loop integration.

## Tasks
1. **GLFW Hook**
   - In `create_os_window`, skip OpenGL context hints when Metal is requested.
   - After `glfwCreateWindow`, obtain `NSView` and attach a `CAMetalLayer` instance.
   - Store layer reference in `OSWindow` for later frame updates.

2. **Metal Context Init**
   - Create `MetalSubsystem` singleton: device, command queue, default library placeholder.
   - Initialize subsystem on first Metal window (guarded by feature flag).

3. **Per-Window Surface**
   - Add `MetalSurface` struct tracking `CAMetalLayer`, drawable size, and `MTLRenderPassDescriptor` template.
   - Update on window resize (callbacks) to sync `drawableSize`.

4. **Frame Loop Prototype**
   - Implement `metal_begin_frame` to acquire drawable and begin command buffer.
   - Implement `metal_end_frame` to encode clear pass and present drawable.
   - Integrate with existing render loop, falling back if drawable unavailable.

5. **Diagnostics & Logging**
   - Log device name, layer pixel format, drawable size changes.
   - Add debug option to force Metal prototype for manual testing.

6. **Testing**
   - Manual smoke test: launch with `KITTY_GPU_BACKEND=metal`, verify blank window.
   - Collect screenshots/logs to confirm CAMetalLayer path executes without crashes.

## Deliverables
- Prototype branch with CAMetalLayer attached and frame clear working.
- Notes on limitations/blockers discovered during prototype.
