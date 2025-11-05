# Performance Benchmarking Plan for Metal Backend (2025-11-03)

## Benchmark Scenarios
- Text throughput benchmark: render large scrollback, measure frame time and FPS.
- Graphics protocol stress: rapid image uploads, animations, translucent overlays.
- Window management stress: split windows, resizing, transparency changes.

## Metrics
- Frame time percentiles (p50, p95) for Metal vs OpenGL.
- GPU utilization and bandwidth (captured via Metal Performance HUD).
- CPU overhead (command encoding time) and memory usage.

## Tooling
- Extend existing benchmark scripts or create new Python harness invoking kitty with scripted workloads.
- Integrate Metal frame capture (Xcode Instruments) for manual investigations.
- Automate collection of metrics via logging or telemetry file output.

## Schedule
- Baseline benchmarks at end of M1 (clear pass) and M2 (text) for comparison.
- Full benchmark suite at completion of M3 before beta rollout.
- Periodic regression runs (weekly) after Metal becomes default.

## Regression Tracking
- Store benchmark results in CI artifacts; aggregate trends in dashboard/spreadsheet.
- Define acceptable variance thresholds (±5% for text, ±10% for graphics workloads).
- Trigger alerts when thresholds exceeded; require investigation before release.
