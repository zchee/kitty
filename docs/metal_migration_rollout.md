# Rollout & Fallback Strategy for Metal Backend (2025-11-03)

## Feature Flag Design
- Introduce runtime option `macos_rendering_backend` with values `auto`, `metal`, `opengl`.
- Default to `opengl` during development; switch to `auto` (preferring Metal with fallback) once beta quality achieved.
- Support environment override `KITTY_GPU_BACKEND` for testing.
- Persist user choice in configuration files and expose via CLI flag `--macos-renderer`.

## Initialization Flow
1. Parse user option / environment.
2. If Metal requested or `auto`, attempt Metal initialization.
3. On failure (unsupported macOS, missing device/tooling, Metal errors), log diagnostics and fall back to OpenGL automatically.
4. Record backend choice in telemetry/logs for troubleshooting.

## Fallback Scenarios
- Metal initialization failure (device missing, API errors).
- Runtime fatal errors (command buffer failures, drawable acquisition issues).
- Manual user override to OpenGL for troubleshooting.
- Provide command palette action or debug shortcut to toggle backend on next launch.

## Telemetry & Reporting
- Track backend usage, crashes, and performance metrics separately for Metal/OpenGL.
- Provide user-facing command `kitty +metal-info` to dump backend status, metallib version, feature set.

## Release Phases
1. **Developer Preview**: Flag default `opengl`; Metal opt-in via CLI.
2. **Beta**: Default `auto` with fallback; gather telemetry, keep OpenGL fallback accessible.
3. **Stable**: Flip default to `metal` after meeting success metrics; maintain OpenGL fallback for at least one release cycle.
4. **Deprecation**: Announce OpenGL removal timeline once Metal considered stable (coordinate with Step 19).

## Documentation & Support
- Update user manual with instructions for selecting backend, troubleshooting, and reporting issues.
- Provide FAQ for common Metal problems and how to revert to OpenGL.
- Ensure crash reports/log dumps include backend indicator.

