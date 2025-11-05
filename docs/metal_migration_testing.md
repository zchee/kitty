# Testing & QA Plan for Metal Backend (2025-11-03)

## Objectives
- Provide comprehensive automated and manual testing coverage for the Metal renderer.
- Detect regressions early (visual, performance, stability) and ensure parity with OpenGL behaviour.
- Integrate Metal validation into CI pipelines and release gates.

## 1. Test Categories

### Unit Tests
- Backend abstraction layer: mock `RendererBackendOps` to verify dispatch, error handling, and fallback logic.
- Shader metadata parsing: ensure manifest → pipeline mapping works, metallib symbol presence validated.
- Buffer/texture utilities: test staging buffer lifecycles, atlas management, upload routines (using CPU-side mocks where possible).

### Integration Tests
- Extend existing `kitty_tests/graphics.py` to support backend selection (OpenGL vs Metal) and validate graphics protocol operations via offscreen rendering or readbacks.
- Create dedicated Metal smoke test harness:
  - Initializes Metal backend, renders minimal scene (text grid, image).
  - Captures framebuffer using `MTLBlitCommandEncoder` and compares against stored fixtures.
  - Validates scissor/viewport conversions, blending modes, gamma adjustments.

### GPU Regression Tests
- Define golden images for key scenarios (text anti-aliasing, cursor, underline, background opacity, graphics protocol animation).
- Use tolerance-based image diffing (e.g., SSIM or pixel threshold) to compare Metal output with OpenGL baseline.
- Run nightly on macOS GPU runners due to heavier compute cost; smoke subset runs per PR.

### Performance Benchmarks
- Port existing benchmarks or create new ones measuring frame time under various workloads (scrolling, image updates, dense text).
- Record metrics for both OpenGL and Metal; define regression thresholds (±5%).
- Automate via performance CI job (weekly) with trend reporting.

### Stability / Stress Tests
- Long-running sessions exercising graphics protocol, window resize, live shader reload.
- Automated script sending randomized graphics commands, verifying no GPU hangs or leaks (monitor memory + drawable counts).

## 2. Tooling & Infrastructure
- Implement test harness using Python + pytest or existing testing framework; ensure `./test.py` can target Metal backend.
- Add utilities for capturing/diffing textures; store fixtures in `kitty_tests/fixtures/metal/`.
- Provide CLI option/env var to select backend for tests (`KITTY_GPU_BACKEND=metal`).
- Integrate Xcode’s `metal` validation layer in debug builds; tests should assert no validation errors.

## 3. CI Integration
- macOS runners with GPU access required; pipeline stages:
  1. Build metallib assets.
  2. Run unit tests (backend-agnostic).
  3. Run Metal smoke tests (subset).
  4. Optionally run full regression suite on nightly schedule.
- Collect artifacts (framebuffer dumps, logs) for failed runs.
- Use caching for metallib builds and fixture downloads.

## 4. Manual QA & Beta Program
- Document manual test matrix covering:
  - Various macOS versions (12.x, 13.x, latest).
  - Apple Silicon (M1/M2) and Intel hardware.
  - High refresh rate displays, external monitors, retina scaling.
  - Interaction with LayerShell, background blur, transparency.
- Beta toggle allowing users to opt into Metal; gather telemetry/crash reports to track issues.

## 5. Bug Reporting & Triage
- Introduce Metal-specific log categories; ensure crash dumps include backend identifier and metallib version.
- Maintain dashboard tracking open Metal issues, severity, and regression status.

## 6. Dependencies & Open Questions
- Need macOS CI hardware with GPU access (may require hosted runners or internal infrastructure).
- Confirm acceptable diff thresholds for visual comparisons.
- Decide on automation framework (existing tests vs pytest extension) for GPU diffing.

This plan should be refined with QA leads and integrated into the overall migration schedule, ensuring testing efforts align with milestone delivery.

