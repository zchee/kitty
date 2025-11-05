# CI & Infrastructure Plan for Metal Migration (2025-11-03)

## macOS GPU Runners
- Secure at least 2 dedicated macOS builders with Metal-capable GPUs (1 Apple Silicon, 1 Intel) for CI.
- Evaluate hosted options (GitHub macOS runners, MacStadium) vs on-prem hardware.
- Ensure runners have Xcode Command Line Tools installed and `xcrun metal` available.

## Pipeline Changes
- Add job stage for metallib compilation prior to tests.
- Run Metal smoke tests per PR; schedule full regression suite nightly.
- Cache metallib outputs keyed by source hash to reduce build time.

## Resource Planning
- Estimate additional CI minutes for Metal jobs (~15 min per PR, 45 min nightly regression).
- Budget for Mac hardware leasing/maintenance if using dedicated machines.

## Monitoring
- Instrument CI to track Metal job success rates, duration, and queue times.
- Alert on consecutive Metal job failures separate from OpenGL pipelines.
