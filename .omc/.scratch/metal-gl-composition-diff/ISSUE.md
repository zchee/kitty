# Metal vs GL glyph-edge composition differs beyond 1 LSB

Status: needs-triage

## Symptom

Cross-backend golden (same commit, same scene, occlusion-immune capture:
Metal via KITTY_METAL_DUMP_FRAME, GL via the thumbnail glReadPixels path)
shows the same visual scene with identical backgrounds and sampled solid
interiors, but glyph/edge composition differs up to 89/255 on ~12% of
pixels (delta spectrum 1→89; ink-mask flicker 4% at threshold 8).

## Evidence (2026-07-06, HEAD 871b0cc1f)

- Harness: `.omc/verify/phase7/xbackend_golden.py` + `_xb_content.py`;
  per-backend determinism byte-identical (so the difference is real, not
  capture noise).
- A black-vs-(33,33,33) sample at a glyph-adjacent pixel rules out a pure
  transfer-function (sRGB-vs-linear) mismatch.
- No pixel-shift: offset scan ±4 px shows no alignment that collapses the
  diff.
- §7 acceptance criterion #6 (≤1 LSB vs GL reference, documented exceptions
  only for deliberate colorspace policy) is adjudicated PARTIAL because of
  this — see kitty/metal-pipeline-design.md adjudication table.

## Hypotheses to split

1. Text composition/AA curve difference (text_contrast /
   text_gamma_adjustment implementation divergence between backends).
2. Subpixel glyph placement rounding difference.
3. Capture-path semantics (dump reads the offscreen pre-present target; GL
   thumbnail reads the post-draw framebuffer) — compare same-backend
   dump-vs-thumbnail on GL-capable capture to eliminate.

## Traps recorded

- The Metal thumbnail/screenshot READ is racy (215-px nondeterminism,
  alpha-255 deltas = unrendered regions) — Metal side must use the DUMP
  path. Related pre-existing validation assert: BGRA8→RGBA8 blit in
  take_screenshot_of_rectangular_region.
- The G2 GL watcher writes TOP-DOWN rows; do not re-flip (black backgrounds
  are flip-symmetric and hide the error from numeric checks — compare
  visually first).
