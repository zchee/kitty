# Rollout Validation Checklist for Metal Backend (2025-11-03)

## Pre-Beta
- Complete M1 and M2 milestones; pass core smoke tests.
- Validate Metal fallback logic (auto → OpenGL) on unsupported hardware.
- Run manual QA matrix on Apple Silicon + Intel.

## Beta Entry Criteria
- All Metal regression tests green (text + graphics diffs).
- Performance benchmarks within thresholds.
- Documentation (build guide, options) updated.
- Telemetry pipeline capable of distinguishing Metal vs OpenGL sessions.

## Beta Monitoring
- Collect crash reports and telemetry weekly; categorize Metal-specific issues.
- Maintain beta feedback channel; triage issues within 48 hours.
- Run nightly full regression suite (Metal + OpenGL).

## Pre-Stable Checklist
- Complete M3 milestone (feature parity). All high/critical Metal bugs resolved.
- Update release notes and migration guide for users.
- Verify notarized builds include metallib assets and pass Gatekeeper.
- Sign-off from QA lead after extensive manual pass.

## Stable Rollout
- Flip default backend to `auto` (Metal first) while retaining fallback option.
- Run canary rollout (10% of beta testers) for one week before general release.
- Monitor metrics; revert to OpenGL default if crash rate exceeds baseline by >20%.

## Post-Release
- Continue monitoring metrics; gather user feedback for at least two release cycles.
- Prepare communication for OpenGL deprecation timeline (see separate doc).
