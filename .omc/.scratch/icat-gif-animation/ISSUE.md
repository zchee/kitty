# icat-transmitted GIF animations do not animate

Status: ready-for-agent

## Symptom

`kitten icat --loop=-1 --hold anim.gif` (48-frame animated GIF, verified
`is_animated` via PIL) displays only the first frame: 3-4 presents total in
a focused window over 9 s, CPU 0%.

## Evidence (2026-07-06, HEAD 871b0cc1f)

- Reproduces in EVERY configuration: default, `KITTY_NO_PERSISTENT_IMAGE_TEXTURE=1
  KITTY_NO_DELTA_IMAGE_UPLOAD=1` (G1/G3 off), and `KITTY_METAL_IOSURFACE=0`
  (pre-Wave-5 legacy present path) — therefore NOT a Metal-phase regression.
- Synthetic APC animation (a=t/a=f/a=a via raw escapes,
  `.omc/verify/g1/_g3_synthetic_content.py`) animates fine in the same
  builds (39 presents / 6 s, timer-driven advances) — kitty's animation
  machinery works; the icat transmission→animation-start path is what fails.
- icat stderr is empty (no error).
- Harness note: `--loop=0` means "first frame only" by design — early
  captures used it by mistake; the failure above is with `--loop=-1`.

## Next probes

1. Capture what icat actually transmits (script(1)-faked tty → byte dump):
   does it send `a=a` (animation start) and frame gaps (`z=`)?
2. Compare against upstream kitty (same icat build vs upstream terminal) to
   split icat-side vs terminal-side.
3. Check `scan_active_animations` preconditions for the icat-created image
   (`is_drawn`, `animation_state`, `extra_framecnt`, `animation_duration`).
