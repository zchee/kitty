# Legacy drawable path (KITTY_METAL_IOSURFACE=0) SIGSEGVs under link-driven flood

Status: needs-triage

## Symptom

With the legacy kill switch active (`KITTY_METAL_IOSURFACE=0`), a kitty
window running a sustained output loop (`for i in $(seq 1 N); do date;
seq 1 3000; sleep 1; done`, spawned via
`scripts/_kitty_harness_common.spawn_kitty()` with `KITTY_METAL_STATS=1`)
segfaults deterministically a few seconds in, after ~4 presents.
Faulting stack (identical in every capture):

```
objc_msgSend
begin_render_pass_to_drawable   (kitty/metal.m)
draw_quad                       (kitty/metal.m)
render_os_window
cocoa_metal_frame_callback
-[KittyMetalDisplayLinkDelegate metalDisplayLink:needsUpdate:]  (glfw/metal_context.m)
CA::Display::MetalLinkItem::dispatch_
```

EXC_BAD_ACCESS / KERN_INVALID_ADDRESS with a garbage-tagged pointer
(e.g. `0x00132859b2fdd8a8`) inside `begin_render_pass_to_drawable` —
consistent with a dangling drawable (or dangling render-pass object)
being messaged on a link-driven frame.

## Evidence (2026-07-08, HEAD d9c315283 + calayer branch)

- PRE-EXISTING: reproduced 3/3 on a build of the unmodified tree
  (stash of the plain-CALayer diff; exit code -11 each time, same
  stack), and on the plain-CALayer branch build. Crash reports:
  `~/Library/Logs/DiagnosticReports/kitty-2026-07-08-07{26,27,29,30}*.ips`.
- Found during the plain-CALayer verification battery
  (`.omc/verify/calayer/*/results.json`, workload.legacy entries); the
  layer-class change is exonerated by the byte-identical stack on the
  pre-change build, and by the legacy arm's golden captures
  (`KITTY_METAL_DUMP_FRAME`, offscreen render — no drawable) passing
  byte-identical on both builds.
- The IOSurface default arm ran the same workload 45 s clean
  (91 presents on the pre-change build, 46+12 presents on the branch).
- Not attributable to the resize RC call (crashes with and without it).

## Notes

The legacy path is the Wave-5 kill switch, so a flood crash here degrades
the escape hatch, not the default. Suspect area: the CAMetalDisplayLink
delegate's drawable handoff (`pending_drawable`, valid only for the
synchronous callback) racing the flood's inline renders, or a drawable
released while `mtl_current_render_pass`/`mtl_current_drawable` still
references it.
