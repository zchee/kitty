# Kitty macOS Metal Migration Charter

## Background
OpenGL on macOS is deprecated and increasingly fragile. Kitty’s renderer, shaders, and Python bindings are tightly coupled to the legacy NSOpenGL stack, blocking modern GPU optimisations and risking future incompatibility. A Metal backend is required to keep the macOS build supported.

## Goals
- Deliver a production Metal renderer for macOS with functional parity to the current OpenGL implementation.
- Maintain seamless behaviour for fonts, graphics protocol, window effects, and performance-sensitive features.
- Provide a controlled rollout that allows falling back to the OpenGL path until Metal is proven stable.

## Success Metrics
- **Compatibility**: All existing kitty integration tests pass on macOS with Metal enabled; manual QA confirms parity for text rendering, images, animations, cursor effects, and transparency.
- **Performance**: Frame times within ±5% of OpenGL baseline for representative workloads (text throughput, graphics protocol stress, heavy window splits) on Apple Silicon and Intel Macs.
- **Stability**: No Metal-specific crashers or GPU hangs reported across beta cycle; CI runs Metal smoke tests on every macOS PR.
- **Rollout**: Feature flag defaults to Metal within two releases after beta, with documented fallback for users.

## Scope
- Replace NSOpenGL context creation with CAMetalLayer-backed surfaces.
- Rebuild renderer core, resource management, and shader toolchain in Metal.
- Update Python/C bindings and options to be backend-neutral.
- Extend build/packaging/tooling to compile Metallib assets and link Metal frameworks.
- Add automated Metal validation in CI plus targeted GPU benchmarks.

## Out of Scope
- Changes to non-macOS GPU backends (OpenGL, Vulkan) beyond necessary abstractions.
- New rendering features unrelated to the Metal migration.
- Wholesale rewrite of the graphics protocol.

## Stakeholders
- **Project Lead**: Metal migration technical owner coordinating architecture and delivery.
- **Rendering Engineers**: Implement Metal pipelines, textures, shaders.
- **Tooling & CI Owner**: Integrate metallib builds, macOS GPU runners, automation.
- **QA & Release Manager**: Plan validation matrix, beta feedback, rollback procedures.
- **Documentation Owner**: Update developer guides, user release notes, migration docs.

### Core Team Roles
- **Project Lead / Graphics Architect** – Drives architecture, coordinates milestones, interfaces with stakeholders.
- **Metal Renderer Engineer** – Builds CAMetalLayer integration, command-buffer lifecycle, and rendering loops.
- **Shader Engineer** – Converts GLSL to MSL, maintains shared shader utilities, oversees metallib compilation.
- **Python/FFI Engineer** – Refactors `fast_data_types` APIs for backend agnosticism, updates Python consumers.
- **Tooling & CI Engineer** – Adds metallib build steps, manages macOS GPU runners, automates Metal smoke tests.
- **QA Lead** – Defines validation matrix, manages beta feedback, ensures regression coverage for Metal features.

## Dependencies
- Availability of macOS GPU CI runners with Metal support.
- Access to Apple developer tooling (`xcrun metal`, `metallib`, Xcode SDKs).
- Coordination with upstream GLFW (or internal fork) for CAMetalLayer integration.

## Risks & Mitigations
- **Incomplete GLFW Metal support**: Prototype CAMetalLayer path early; maintain fallback to OpenGL until upstream work lands.
- **Shader translation regressions**: Establish GLSL→MSL parity tests and visual diff tooling.
- **Performance regressions**: Baseline workloads pre-migration, monitor via automated benchmarks.
- **Limited QA coverage**: Expand macOS testing to cover graphics protocol edge cases and interactive scenarios.

## Milestones (High-Level)
1. **Foundation (4–6 weeks)** – GLFW CAMetalLayer path, Metal device bootstrap, abstraction layer over renderer APIs.
2. **Rendering Core (6–8 weeks)** – Text rendering, texture atlas, pipeline cache, initial shaders in MSL.
3. **Feature Parity (6 weeks)** – Images, effects, graphics protocol commands, diagnostics.
4. **Stabilisation (4 weeks)** – Performance tuning, bug fixing, documentation, beta rollout.
5. **Release** – Flip feature flag default, monitor telemetry, schedule OpenGL deprecation.
