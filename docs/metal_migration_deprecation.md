# OpenGL Deprecation Timeline (Draft – 2025-11-03)

## Phase 0 – Legacy Support (current)
- Default macOS backend: OpenGL.
- Metal available via opt-in flag.

## Phase 1 – Dual Support (post-M2)
- Default: `auto` (Metal first with OpenGL fallback).
- Communicate to users that OpenGL is deprecated but still available.

## Phase 2 – Deprecation Warning (target: +2 releases after Metal default)
- Display warning on OpenGL backend startup (CLI log, optional UI notice).
- Encourage users to migrate to Metal; collect feedback on blocking issues.

## Phase 3 – Soft Removal (target: +4 releases)
- Remove OpenGL fallback option from default builds; provide legacy build for one additional release for users needing OpenGL.
- Update documentation to reflect Metal-only support.

## Phase 4 – Hard Removal (target: +6 releases)
- Remove OpenGL code paths from macOS build.
- Update CI to drop OpenGL tests on macOS.
- Announce completion of migration and archive legacy documentation.

## Communication
- Announce timeline in release notes once Phase 1 begins.
- Provide migration guide and FAQ updates at each phase.
- Coordinate with package maintainers (Homebrew, distro packages) to ensure smooth transition.
