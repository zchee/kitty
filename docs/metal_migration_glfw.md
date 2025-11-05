# GLFW Integration Plan for Metal Backend (2025-11-03)

## Goals
- Provide Kitty with a CAMetalLayer-backed surface management path within GLFW, replacing the current NSOpenGL context usage on macOS.
- Preserve existing GLFW APIs (`glfwMakeContextCurrent`, `glfwSwapBuffers`, event loop integration) from Kitty’s perspective.
- Ensure Retina, LayerShell, and window lifecycle behaviours remain consistent.

## Current State Snapshot
- `glfw/nsgl_context.m` implements NSOpenGL context creation, shared context retention, swap buffers, and teardown.
- `glfw/cocoa_window.m` already creates `CAMetalLayer` instances when setting up Vulkan surfaces (see `_glfwPlatformCreateWindowSurface`), but there is no equivalent path for native rendering without Vulkan.
- `glfw/glfw3.h` exposes `glfwCreateWindowSurface` for Vulkan and mentions CAMetalLayer in remarks; no public Metal-specific API exists.

## Integration Strategies

### Option A: Upstream-Oriented Patch
1. Implement a new GLFW context backend (e.g., `_glfwPlatformCreateMetalContext`) modelled after NSGL but using CAMetalLayer directly.
2. Add public GLFW context hints (`GLFW_CONTEXT_API = GLFW_NO_API`, plus a new `GLFW_PLATFORM_METAL` flag) to signal window creation without OpenGL.
3. Update `_glfwChooseVisual`, `glfwMakeContextCurrent`, `glfwSwapBuffers`, and context destruction paths to call Metal-specific hooks.
4. Submit patch upstream; maintain temporary fork until merged.

### Option B: In-Tree Extension
1. Leave upstream GLFW untouched; introduce Kitty-specific wrappers around GLFW window creation.
2. After `glfwCreateWindow`, replace the NSOpenGL context with a custom `kitty_glfw_attach_metal_layer` that:
   - Instantiates `CAMetalLayer`.
   - Sets layer properties (`device`, `pixelFormat`, `framebufferOnly`, `drawableSize`).
   - Captures resize events to update drawable size.
3. Override GLFW context callbacks stored in `_GLFWwindow->context` with Metal equivalents (`makeCurrent`, `swapBuffers`, `destroy`) implemented in Kitty.
4. Requires touching internal GLFW structs; manageable given Kitty already vendors GLFW sources.

### Option C: Hybrid
- Implement minimal upstream patches to expose Metal-friendly hooks (e.g., getter/setter for `NSView` layer) while maintaining context management within Kitty.

## Required Changes (Regardless of Option)

1. **Context Hooks**
   - Replace `_glfwCreateContextNSGL` usage in Kitty bootstrap with new `kitty_glfw_init_metal`.
   - Implement `makeCurrent` as a no-op (Metal does not require context binding per thread) but maintain API compatibility.
   - `swapBuffers` should invoke Kitty’s Metal presentation path (commit command buffer & present drawable).
   - Ensure `_glfwPlatformSwapBuffers` / `swapInterval` semantics degrade gracefully (Metal uses display link or command buffer completion).

2. **Layer Management**
   - On window creation, attach `CAMetalLayer` to the `NSView` (`[view setLayer:layer]; [view setWantsLayer:YES];`).
   - Track retina scale (`contentsScale`) on resize callbacks; update `drawableSize`.
   - Manage layer lifetime across window hide/show and release operations.

3. **Event Loop & V-Sync**
   - Maintain compatibility with existing frame scheduling (Kitty uses `CVDisplayLink` on macOS). Decide whether to reuse or migrate to command buffer-based throttling.
   - Ensure `glfwSwapInterval` calls from cross-platform code do not crash; map to Metal-friendly toggles or no-ops with warnings.

4. **Fallback**
   - Provide runtime flag to fall back to NSOpenGL path if Metal initialization fails (device missing, unsupported macOS versions).

5. **Build System**
   - Ensure GLFW is compiled with Objective-C/++ flags when Metal path is active (may require `.mm` sources).

## Validation Checklist
- Window creation/destruction without leaks (profiling for retained CAMetalLayers).
- Retina scaling correctness (layer `drawableSize` matches framebuffer size).
- Interaction with Kitty’s LayerShell integration (transparency, blur) remains intact.
- Swap/present behaviour matches existing frame pacing (no stutter/regressions).
- Compatibility with multiple windows and shared global resources.

## Next Steps
1. Prototype Option B (in-tree extension) to validate feasibility quickly.
2. Evaluate effort to upstream changes; align with GLFW maintainers if pursuing Option A/C.
3. Update architecture spec with final decision and integrate into implementation milestones.

