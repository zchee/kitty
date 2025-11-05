# Build & Packaging Plan for Metal Backend (2025-11-03)

## Objectives
- Extend Kitty’s build system to compile and package Metal shader assets while linking required frameworks.
- Maintain compatibility with non-macOS builds (no Metal dependencies elsewhere).
- Support debug workflows (hot reload, diagnostics) and CI integration.

## 1. Toolchain Requirements
- Ensure build hosts use Python 3.13 (`./.venv/bin/python3.13`) as per project constraints.
- Verify presence of Apple developer tools:
  - `xcrun metal`
  - `xcrun metallib`
  - Appropriate macOS SDK (>= 13.0 recommended for CAMetalLayer features).
- Update developer documentation to list Metal toolchain prerequisites.

## 2. Source Layout
- Store MSL sources under `kitty/shaders/metal/`.
- Generated `.air` intermediates in `gen/metal/air/<arch>/`.
- Final `.metallib` artifacts in `kitty/metal/<arch>/kitty.metallib`.
- Include manifest (JSON) describing entry points, resource bindings, version hash.

## 3. Build Steps (macOS)
1. **Shader Compilation**
   - For each `.metal` file:
     ```
     xcrun metal -target apple-macos<SDK_VER> -std=metal3.1 \
         -o gen/metal/air/<arch>/<name>.air \
         -mcpu <arch> kitty/shaders/metal/<name>.metal
     ```
   - Run per-architecture (x86_64, arm64).
2. **Linking**
   - Aggregate `.air` files per architecture:
     ```
     xcrun metallib gen/metal/air/<arch>/*.air \
         -o kitty/metal/<arch>/kitty.metallib
     ```
   - Optionally produce universal metallib via `lipo` if needed, or select at runtime based on `sysctl hw.optional.arm64`.
3. **Manifest Generation**
   - Emit metadata file capturing SHA256 of sources, compile timestamp, and entry point mapping (consumed by runtime loader).
4. **Hot Reload Support**
   - For debug builds, copy metallib to development location and set environment variable for runtime reload.

## 4. Build System Integration
- **setup.py**
  - Replace `gl_libs = ['-framework', 'OpenGL']` with conditional logic:
    - On macOS: link `-framework Metal -framework QuartzCore` (retain `Cocoa`, `Carbon`, etc.).
    - Keep OpenGL libs for non-macOS targets.
  - Add new build command or hook to invoke shader compilation prior to packaging.
  - Ensure distutils recognizes `.metal` files as inputs for dependency tracking.
- **Makefiles / CI Scripts**
  - Add targets: `make metallib`, `make metal-debug`.
  - Ensure CI runs metallib build on macOS runners before executing tests.
- **Packaging**
  - Include `kitty/metal/<arch>/kitty.metallib` and manifest in application bundle/wheels.
  - Update installer scripts and notarization pipeline to sign metallib assets.
- **Environment Guards**
  - For non-macOS builds, skip Metal steps gracefully (no `xcrun` invocation).
  - Provide warning/log if Metal tooling missing on macOS build host.

## 5. Runtime Loader Changes
- Modify `kitty/shaders.py` or replacement loader to locate metallib based on architecture and manifest.
- Provide fallback error messaging if metallib missing or mismatched (suggest running `make metallib`).
- Expose metallib version in diagnostics (`metal_renderer_info`).

## 6. Developer Experience
- Add `scripts/rebuild_metallib.py` (or Make target) invoked by developers for quick iteration; parse compiler errors and remap to original source lines.
- Document workflow in contributor guide (`docs/build.rst`).
- Provide optional watch mode for rapid prototyping (e.g., using `fswatch` to trigger rebuild).

## 7. CI Integration
- Ensure GitHub Actions or equivalent has macOS runners with Metal toolchain.
- Add caching for `.air` / `.metallib` outputs keyed by source hash to reduce build times.
- Run smoke tests that load metallib and render minimal frame to catch build issues.

## 8. Release & Distribution
- Update release packaging to bundle metallib assets for both Apple Silicon and Intel.
- Update Homebrew formula or other distribution scripts to install metallib to appropriate resource directory.
- Adjust notarization, signing, and checksums to account for new files.

## 9. Risk Mitigation
- **Missing Toolchain**: Provide clear error messages with installation steps (Xcode Command Line Tools).
- **Cross-Arch Issues**: Validate metallib on both arm64 and x86_64; consider building on universal macOS nodes.
- **Build Time**: Parallelize `xcrun metal` invocations; leverage caching.
- **Packaging Drift**: Add automated tests verifying metallib presence in built artifacts.

This plan equips the build system to support the Metal backend while keeping other platforms unaffected.

