# Wave 19: prove the founding bar, discriminate the above-wall residual

Status: ready-for-human

## Origin

Deep-dive pipeline (2026-07-08, session on `metal-fable-5-fast` @ d9c315283):
trace → interview → spec, final ambiguity 12.5%.

- **Spec (authoritative)**: `.omc/specs/deep-dive-worlds-fastest-terminal-optimization.md`
- **Trace evidence**: `.omc/specs/deep-dive-trace-worlds-fastest-terminal-optimization.md`

## Summary

The 18-wave PLATEAU verdict is scoped to a 2-competitor world the founding
charter defined as insufficient. Two workstreams remain:

1. **Step-0 probe battery** (zero product code, reuse
   `.omc/verify/wave18/step0_decouple.py`): (A) suppress-render on
   unicode+dense_cells, (B) `input_delay=0` on region/vim/control,
   (C) medium_cells DECSET-2026 split. Gate table + ≥5% action threshold
   confirmed by user — see spec Acceptance Criteria 1.
2. **Competitive bar closure**: 4 competitors (Ghostty, Alacritty, iTerm2,
   Terminal.app) × 3 axes (throughput, typing p50/p99, energy), same-machine
   interleaved, zero BLOCKED cells. Accessibility grant DONE (preflight
   True); sudo powermetrics + iTerm2 install approved by operator.

Victory rule: declare "world's fastest" only if every cell is measured and
kitty is 1st or tied-1st on every axis; otherwise emit the ranked gap list
as the Wave-20 charter.

## Authority

input_delay policy family: FULL fork-local authority incl. default changes
(user, interview R4), guarded by idle CPU 0.0% and energy non-regression.
Refuted families (pacing decouple, draw bucket, governor, render split)
stay closed.

## Comments

**2026-07-08 (Step-0 battery complete)**: A=HOLD/HOLD (dark residual real,
raster exonerated), B=PARTIAL(region D=0.304)/NONE(vim D=0.029 — input_delay
lane closed), C=ATTRIBUTES (survival 1.0 — the vim gap IS DECSET-2026, 19.27
ms/MiB: parse +5.8, drain-serialization +13.4). Charters: L4 (top), L3, L1
(typing-only); L2 dead. See .omc/verify/wave19/GATE-ADJUDICATION.md.

**2026-07-08 (L4 resolved, L3 narrowed)**: L4 = vtebench median artifact ×
real 1.43× BSU-snapshot cost; COW-snapshot fix → Wave-20. Probe D killed
L2 on 4 axes (and showed input_delay batching saves ~10 ms/MiB of flood
render CPU — energy evidence). L3 residual = io/PTY read path by
elimination; io-side instrumentation in flight.

**2026-07-08 (matrix: throughput + typing axes adjudicated)**: 5-app
interleaved block complete (105/105 runs after one load-storm re-run —
QUIET-GATE-NOTE.md). Throughput: **kitty 3rd on all 7 benches** (Ghostty
6/7 wins, Alacritty 1/7); worst cells sit on L4 (sync 6×) and L3 (floods
1.6–1.9×). Terminal.app column was occlusion-throttle contaminated
(AppleEvent windows never composite un-activated — macOS 27 finding) and
was re-captured visible: 2.8–4.6× faster, ranks unchanged; iTerm2 measured
insensitive. Typing (typing_photon.py first live run; multi-display
coord + activation teething fixed): Ghostty/Terminal tied-1st 7.9/8.2 ms
p50; **kitty tied-4th 38.9 ms p50 / 60.9 p99**; cross-val shows ~32.4 ms
is pre-present (input→present pipeline, ≈2 frames) — L1's ~3 ms slice cannot
change rank, NOT landed (net-of-matrix gate). Victory rule already fails
on both axes → outcome = ranked gap list (MATRIX-FINAL.md). Energy axis
pending operator sudo.

**2026-07-08 (CLOSED — adjudicated, no declaration)**: Energy row recorded
as an explicit documented limitation (operator deferred the sudo session;
`p2b_energy.py` driver+analyzer ready for later replacement — cells swap
in without re-running other axes). Final verdict per the mechanical rule:
**kitty is 1st on no axis** (throughput 3rd everywhere; typing tied-4th) —
outcome = ranked Wave-20 gap list in MATRIX-FINAL.md: (1) typing
input→present decomposition (~32.4 ms pre-present), (2) select-free PTY
reader (L3), (3) BSU COW snapshot (L4), (4) region residual folded into
(2). Ledger updated (metal-pipeline-design.md Phase 19). mediaanalysisd
un-frozen at close. Remaining human items: Wave-20 charter kickoff,
optional later energy capture, stale .omc/golden recapture (800×500 vs
701×391 note from the resume handoff).
