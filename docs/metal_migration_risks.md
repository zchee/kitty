# Risk Register – Metal Migration (2025-11-03)

| ID | Risk | Impact | Likelihood | Mitigation | Owner |
|----|------|--------|------------|------------|-------|
| R1 | GLFW Metal support effort underestimated | High – delays core window integration | Medium | Prototype in-tree CAMetalLayer hook early (Option B), maintain close contact with GLFW maintainers; schedule dedicated spike sprint. | Graphics Architect |
| R2 | Shader translation causes visual regressions | High – degraded rendering quality | Medium | Establish automated image diff tests, manual review by shader engineer, maintain GLSL fallback during beta. | Shader Engineer |
| R3 | Performance regressions on Intel Macs | High – user dissatisfaction | Medium | Benchmark both OpenGL and Metal across hardware; optimize resource uploads; gate rollout until metrics within ±5%. | Renderer Engineer |
| R4 | Insufficient macOS GPU CI capacity | Medium – untested builds reach users | Medium | Secure dedicated macOS runners early; budget for hosted hardware; stagger heavy regression suites nightly. | Tooling & CI Engineer |
| R5 | Metal toolchain unavailable on developer machines/CI | Medium – build failures | Low | Update docs with Xcode CLI install steps; add setup checks in build scripts; block Metal build with actionable errors. | Tooling & CI Engineer |
| R6 | Abstraction layer introduces bugs in OpenGL path | Medium – regressions for non-macOS | Medium | Maintain comprehensive OpenGL regression suite; roll out backend interface incrementally with feature flags. | Python/FFI Engineer |
| R7 | Metallib packaging/signing issues in releases | High – shipping broken builds | Low | Integrate metallib into packaging scripts early; add automated verification tests; include in notarization flow. | Release Manager |
| R8 | Schedule slip due to cross-team coordination | Medium | Medium | Break project into milestones with clear owners; hold weekly syncs; adjust scope via change control when risks materialize. | Project Lead |
| R9 | Metal-only bugs surfaced late in beta | High | Medium | Launch closed beta early, collect telemetry, keep OpenGL fallback accessible; triage Metal issues promptly. | QA Lead |
| R10| Apple platform changes (new macOS breaking Metal code) | Medium | Low | Track macOS betas; run regression suite on developer previews; maintain OpenGL fallback until post-release validation. | Project Lead |

Notes:
- Risk ratings should be revisited at each milestone checkpoint.
- Additional risks can be appended as the project progresses (e.g., developer attrition, external dependency shifts).

