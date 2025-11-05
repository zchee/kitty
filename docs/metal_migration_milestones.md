# Metal Migration Milestones (Draft – 2025-11-03)

## Milestone M1: Prototype – Metal Surface & Clear Pass
- **Duration**: 4 weeks
- **Owner**: Metal Renderer Engineer
- **Dependencies**: Architecture spec finalized, GLFW integration approach chosen (Option B prototype).
- **Objectives**:
  1. Attach `CAMetalLayer` to Kitty GLFW window and manage `drawableSize`/retina scaling.
  2. Initialize `MTLDevice`, `MTLCommandQueue`, and per-frame command buffer lifecycle.
  3. Encode and present a clear pass (solid color) each frame, ensuring frame pacing works with existing event loop.
- **Exit Criteria**:
  - Kitty launches on macOS with Metal backend flag and displays cleared window without crashing.
  - Swap interval / frame pacing consistent with current behaviour.
  - Automated smoke test renders a frame and validates drawable acquisition/presentation.
- **Deliverables**:
  - Prototype branch/PR demonstrating CAMetalLayer integration.
  - Documentation updates covering developer environment setup.
  - Preliminary performance measurement (baseline frame time).


## Milestone M2: Text Rendering Path
- **Duration**: 6 weeks
- **Owner**: Shader Engineer (in collaboration with Python/FFI Engineer)
- **Dependencies**: M1 complete, shader porting tooling operational, backend abstraction layer ready.
- **Objectives**:
  1. Translate cell shaders (vertex/fragment) to MSL and integrate into metallib.
  2. Implement glyph atlas uploads using Metal texture storage and staging buffers.
  3. Encode text rendering pipeline (foreground/background, decorations, cursor) with correct blending/gamma.
  4. Wire Python `LoadShaderPrograms` to Metal pipeline creation and ensure option-driven recompilation works.
- **Exit Criteria**:
  - Text rendering works for standard workloads (monospace fonts, decorations, cursor) under Metal backend.
  - Regression tests comparing Metal vs OpenGL text output pass within tolerance.
  - Performance within ±10% of OpenGL baseline for text throughput benchmarks.
- **Deliverables**:
  - Metal text rendering implementation merged behind feature flag.
  - Updated documentation for shader build/reload workflow.
  - Test reports covering automated diff tests and manual QA checklist for text features.


## Milestone M3: Graphics Protocol Feature Parity
- **Duration**: 6 weeks
- **Owner**: Metal Renderer Engineer (coordination with Graphics Protocol maintainer)
- **Dependencies**: M2 complete (text rendering stable), shader porting for graphics programs available.
- **Objectives**:
  1. Implement Metal pipelines for graphics protocol commands (image uploads, animations, transparency).
  2. Support rounded rectangles, tinting, trails, background images with appropriate blending and sRGB handling.
  3. Ensure texture atlas management handles animated frames and memory pressure parity with OpenGL.
  4. Port debugging utilities (`save_texture_as_png`, diagnostics) to Metal equivalents.
- **Exit Criteria**:
  - All graphics protocol commands pass automated tests under Metal backend.
  - Visual diffs for representative scenes fall within tolerance vs OpenGL output.
  - Memory usage and frame pacing comparable to OpenGL for image-heavy workloads.
- **Deliverables**:
  - Metal graphics feature implementation behind feature flag.
  - Updated documentation for graphics protocol behaviour in Metal mode.
  - Performance report covering image upload throughput and animation smoothness.

## Upcoming Milestones (Preview)
- M4: Stabilisation & Beta Rollout.
- M3: Graphics Protocol Feature Parity.
- M4: Stabilisation & Beta Rollout.
- Detailed schedules for M2–M4 will be fleshed out in subsequent planning steps.

