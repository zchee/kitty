#!/usr/bin/env -S uv run --quiet --no-project --python 3.14 --with Pillow
"""Golden-image capture + compare tool for kitty's Metal-backend
optimization project. See
.omc/plans/2026-07-02-metal-worlds-fastest-optimization.md SS6 Phase 0
step 4 and docs/metal-performance.md. This is every later phase's pixel
regression gate (plan SS6: "Golden-image gate = all configs diff <=1 LSB
vs GL reference via KITTY_METAL_DUMP_FRAME").

Two subcommands:

  capture --output-dir DIR [--configs NAME ...]
    For each config in the matrix (default: all of default-opaque,
    background_opacity_0.85, cursor_trail, bgimage), launches kitty with
    that config's `-o` overrides plus KITTY_METAL_DUMP_FRAME=DIR/NAME.png
    and a fixed deterministic test-content script
    (_golden_content_helper.py: colored text, ligature triggers, emoji,
    then a settle sleep). Writes DIR/manifest.json with capture provenance
    (config, kitty options used, timing, any failures) alongside the PNGs.
    NEVER fabricates a PNG: a config that fails to capture is recorded as
    an error in the manifest, not silently skipped or faked.

  compare DIR_A DIR_B [--threshold N]
    For each config PNG present in BOTH directories (matched by filename),
    decodes with Pillow (optional dependency -- see kitty_tests/graphics.py
    for the same "PIL not available, skip" convention this follows) and
    computes the max per-channel absolute difference. Passes if <= threshold
    (default 1, i.e. <=1 LSB in an 8-bit channel). Configs missing from
    either side are reported as failures, not silently ignored. Exit code
    0 iff every compared config passes and none are missing.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from _kitty_harness_common import (
    REPO_ROOT,
    get_kitty_version,
    get_machine_info,
    require_kitty_binary,
    spawn_kitty,
    terminate_kitty,
    wait_for_build_lock_clear,
)

CONTENT_HELPER = Path(__file__).resolve().parent / "_golden_content_helper.py"
DEFAULT_GOLDEN_DIR = REPO_ROOT / ".omc" / "golden"
BGIMAGE_ASSET = REPO_ROOT / "logo" / "kitty-128.png"
# Floor for the non-black capture gate; the deterministic content helper
# paints hundreds of distinct colors (reference set: 1700+), so anything
# below this is an empty/failed frame, not a rendering difference.
MIN_UNIQUE_COLORS = 32

# Phase-0 starting matrix, exactly as specified by the task: default-opaque,
# background_opacity=0.85, cursor_trail enabled, one bgimage config. Values
# are kitty `-o key=value` overrides; content (colored text/ligatures/emoji)
# is identical across all four -- only the rendering config varies, since
# the point is exercising each render-pass code path (opaque single-pass vs.
# layered transparency/bgimage/cursor-trail 2-pass), not different content.
CONFIG_MATRIX: dict[str, list[str]] = {
    "default-opaque": [],
    "background_opacity_0.85": ["background_opacity=0.85"],
    # "Set this to a value larger than zero to enable" (cursor_trail's own
    # docstring, kitty/options/definition.py) -- forces the layered 2-pass
    # code path even though this content doesn't move the cursor enough to
    # keep an animated trail visible at capture time (Phase 0 scope: verify
    # the pass structure/pixel correctness with the option enabled, not the
    # trail animation itself).
    "cursor_trail": ["cursor_trail=20"],
    "bgimage": [f"background_image={BGIMAGE_ASSET}"],
    # W3e F1b: a non-1:1 layout, because the default tiled config samples the
    # texture exactly 1:1 (every sample lands on a texel centre), which makes it
    # structurally blind to the sampler FILTER -- the W3e review measured an
    # 11.07% pixel delta between nearest and linear on this layout that no
    # other config can see. Locks filter (nearest by default) and the
    # REPEAT_CLAMP wrap the scaled layouts use.
    "bgimage-scaled": [f"background_image={BGIMAGE_ASSET}", "background_image_layout=scaled"],
    # W27 P3.6 / GLSL-freeze-out stage 0 (risk R4): coverage for the GRAPHICS
    # and ROUNDED_RECT programs, previously exercised by no golden config, and
    # the OKLCH-palette scene that locks the dump channel's rendering of
    # wide-capable palette entries. Content varies per scene (CONFIG_SCENE);
    # the four legacy configs keep the byte-identical legacy scene.
    "graphics": [],
    "progress-bar": ["progress_bar=top"],
    "palette-oklch": [],
    # W27 P4.3: the EDR golden — an f=3232 float ramp rendered through the
    # tone-map with the headroom PINNED (see CONFIG_ENV), so the dump-channel
    # rendition is display-state-independent.
    "hdr-ramp": [],
    # W3d: coverage for the TRAIL program, which every other config is blind to
    # (cursor_trail=20 above never renders a visible trail at capture time —
    # the trail exists only mid-animation, and a settled trail masks itself
    # out). KITTY_METAL_TEST_PIN_TRAIL (see CONFIG_ENV) pins the corners one
    # cell outside the cursor rect at opacity 1, a deterministic function of
    # the settled cursor position. Explicit trail colour so the baseline does
    # not depend on the cursor colour.
    "cursor-trail-pinned": [
        "cursor_blink_interval=0", "cursor_shape_unfocused=unchanged",
        "cursor_trail=1", "cursor_trail_color=#7742ff",
    ],
}

# Scene argument handed to the content helper (argv[1]); configs not listed
# here run the legacy scene, whose bytes are pinned by the existing baselines.
CONFIG_SCENE: dict[str, str] = {
    "graphics": "graphics",
    "progress-bar": "progress",
    "palette-oklch": "palette",
    "hdr-ramp": "hdr-ramp",
}

# Extra environment for specific configs (merged into the sanitized spawn env).
CONFIG_ENV: dict[str, dict[str, str]] = {
    # Deterministic tone-map ceiling for the EDR golden (the live headroom
    # moves with the panel and its brightness slider).
    "hdr-ramp": {"KITTY_METAL_EDR_HEADROOM_OVERRIDE": "2.0"},
    "cursor-trail-pinned": {"KITTY_METAL_TEST_PIN_TRAIL": "1"},
}


def capture_config(name: str, opts: list[str], output_dir: Path, timeout: float, env: dict[str, str] | None = None) -> dict[str, Any]:
    require_kitty_binary()
    png_path = output_dir / f"{name}.png"
    if png_path.exists():
        png_path.unlink()  # never let a stale PNG from a prior failed run masquerade as a fresh capture

    # cursor_blink_interval=0 always comes first so a per-config opts entry
    # could still override it if a future config matrix entry ever needed
    # to (kitty applies -o overrides in argv order, later wins). Without
    # this, capture timing vs. the blink phase is an uncontrolled source of
    # run-to-run pixel/file-size non-determinism -- observed empirically
    # while writing this script: two captures of the same config differed
    # by a few bytes despite identical content, consistent with catching
    # different blink phases. A golden-image regression gate needs
    # bit-for-bit reproducibility for a fixed config to be trustworthy.
    # cursor_shape_unfocused=unchanged: the dump overwrites on EVERY frame and
    # content is static after the helper paints, so the surviving frame lands
    # on an arbitrary side of the focus-arrival race — without this pin the
    # focused (block) vs unfocused (hollow) cursor makes same-session pairs
    # differ by max_diff≈204 in the cursor cell (Wave-2 finding, re-hit in
    # Wave-20 P0; see .omc/golden/RECAPTURE-NOTES.md).
    full_opts = ["cursor_blink_interval=0", "cursor_shape_unfocused=unchanged", *opts]
    # take_focus=True is load-bearing (Wave-20 P0 finding): an unfocused
    # spawn fully occluded by the user's windows renders ZERO frames (kitty's
    # occlusion skip), so KITTY_METAL_DUMP_FRAME never fires and the capture
    # silently produces nothing — or, at a display-attach boundary, a single
    # empty (all-black) frame. The Wave-2/3 reference driver pinned focus for
    # the same reason ("golden_capture_focus_pinned").
    helper_argv = [sys.executable, str(CONTENT_HELPER)]
    scene = CONFIG_SCENE.get(name)
    if scene:
        helper_argv.append(scene)
    proc = spawn_kitty(
        helper_argv,
        extra_env={"KITTY_METAL_DUMP_FRAME": str(png_path), **CONFIG_ENV.get(name, {}), **(env or {})},
        extra_kitty_opts=full_opts,
        take_focus=True,
    )
    timed_out = False
    try:
        proc.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
    clean_shutdown = terminate_kitty(proc)

    result: dict[str, Any] = {
        "config": name, "kitty_opts": full_opts, "timed_out": timed_out, "clean_shutdown": clean_shutdown,
    }
    if timed_out or not clean_shutdown:
        result["error"] = "kitty had to be forcibly terminated -- capture is INVALID, discarding any PNG it produced"
        if png_path.exists():
            png_path.unlink()
        return result
    if not png_path.exists():
        result["error"] = "no PNG produced (KITTY_METAL_DUMP_FRAME never wrote a file)"
        return result
    result["path"] = str(png_path)
    result["bytes"] = png_path.stat().st_size
    # Non-black gate (Wave-20 P0 finding): a capture that "succeeds" while
    # the window never composits content is a valid-looking PNG of pure
    # black; byte-identical black pairs pass a naive A/B diff. The fixed
    # content helper paints 16/256/truecolor samples, so any real capture
    # has far more than MIN_UNIQUE_COLORS distinct pixels.
    try:
        from PIL import Image
        with Image.open(png_path) as im:
            colors = im.convert("RGB").getcolors(maxcolors=1 << 24)
        result["unique_colors"] = len(colors) if colors else 0
        if result["unique_colors"] < MIN_UNIQUE_COLORS:
            result["error"] = (
                f"capture is visually EMPTY ({result['unique_colors']} unique colors < {MIN_UNIQUE_COLORS})"
                " -- window likely never rendered content (occluded/display-off); capture is INVALID"
            )
    except ImportError:
        result["unique_colors"] = None  # Pillow-less direct invocation: gate skipped, recorded as unknown
    return result


def cmd_capture(args: argparse.Namespace) -> int:
    require_kitty_binary()
    wait_for_build_lock_clear()

    configs = {k: CONFIG_MATRIX[k] for k in (args.configs or CONFIG_MATRIX)}
    unknown = set(args.configs or []) - set(CONFIG_MATRIX)
    if unknown:
        print(f"ERROR: unknown config(s) {sorted(unknown)}; known: {sorted(CONFIG_MATRIX)}", file=sys.stderr)
        return 2
    if "bgimage" in configs and not BGIMAGE_ASSET.exists():
        print(f"ERROR: bgimage config needs {BGIMAGE_ASSET}, which does not exist in this checkout", file=sys.stderr)
        return 2

    args.output_dir.mkdir(parents=True, exist_ok=True)
    manifest: dict[str, Any] = {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "kitty_version": get_kitty_version(),
        # Provenance: which source state produced the binary under capture. A
        # baseline whose lineage rests on a file timestamp cannot prove it
        # predates a migration; the SHA (+ the modified-file list) can.
        "git_head": subprocess.run(
            ["git", "rev-parse", "HEAD"], capture_output=True, text=True
        ).stdout.strip() or "unknown",
        # The boolean alone cannot discriminate: this repo's build regenerates
        # the tracked kitty/glsl-uniforms.h, so every capture is "dirty". The
        # file list is what lets a reader tell that apart from real edits.
        "git_dirty_files": sorted(
            line[3:] for line in subprocess.run(
                ["git", "status", "--porcelain", "--untracked-files=no"], capture_output=True, text=True
            ).stdout.splitlines() if line.strip()
        ),
        "machine": get_machine_info(),
        "output_dir": str(args.output_dir),
        "captures": {},
    }
    ok = True
    for name, opts in configs.items():
        print(f"[metal-golden] capturing {name!r} (opts={opts}) ...", file=sys.stderr)
        result = capture_config(name, opts, args.output_dir, args.timeout,
                                env=dict(kv.split("=", 1) for kv in (args.env or [])))
        manifest["captures"][name] = result
        if "error" in result:
            ok = False
            print(f"[metal-golden]   ERROR: {result['error']}", file=sys.stderr)
        else:
            print(f"[metal-golden]   wrote {result['path']} ({result['bytes']} bytes)", file=sys.stderr)

    manifest_path = args.output_dir / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print(f"[metal-golden] wrote {manifest_path}", file=sys.stderr)
    print(json.dumps(manifest, indent=2, sort_keys=True))
    return 0 if ok else 1


def compare_images(path_a: Path, path_b: Path, threshold: int) -> dict[str, Any]:
    try:
        from PIL import Image, ImageChops
    except ImportError:
        return {"pass": None, "error": "Pillow (PIL) not installed -- execute this script directly (./scripts/metal-golden.py, the uv shebang resolves it) or pip install --user Pillow"}

    img_a = Image.open(path_a).convert("RGBA")
    img_b = Image.open(path_b).convert("RGBA")
    if img_a.size != img_b.size:
        return {"pass": False, "error": f"size mismatch: {img_a.size} vs {img_b.size}"}

    diff = ImageChops.difference(img_a, img_b)
    extrema = diff.getextrema()  # ((minR,maxR),(minG,maxG),(minB,maxB),(minA,maxA))
    max_per_channel = dict(zip("RGBA", (mx for _, mx in extrema)))
    max_diff = max(max_per_channel.values())
    return {"pass": max_diff <= threshold, "max_diff": max_diff, "max_diff_per_channel": max_per_channel, "threshold": threshold}


def cmd_compare(args: argparse.Namespace) -> int:
    dir_a, dir_b = args.dir_a, args.dir_b
    for d in (dir_a, dir_b):
        if not d.is_dir():
            print(f"ERROR: {d} is not a directory", file=sys.stderr)
            return 2

    configs_a = {p.stem for p in dir_a.glob("*.png")}
    configs_b = {p.stem for p in dir_b.glob("*.png")}
    all_configs = sorted(configs_a | configs_b)
    if not all_configs:
        # Vacuous-pass hole (hit in Wave-20 P0): comparing two empty/not-yet-
        # written directories must be a loud failure, not an all_pass=True.
        print(f"ERROR: no PNGs found in either {dir_a} or {dir_b} -- nothing to compare", file=sys.stderr)
        return 2

    summary: dict[str, Any] = {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "dir_a": str(dir_a), "dir_b": str(dir_b), "threshold": args.threshold,
        "results": {},
    }
    all_ok = True
    for name in all_configs:
        if name not in configs_a or name not in configs_b:
            missing_from = str(dir_b) if name not in configs_b else str(dir_a)
            summary["results"][name] = {"pass": False, "error": f"missing from {missing_from}"}
            all_ok = False
            continue
        result = compare_images(dir_a / f"{name}.png", dir_b / f"{name}.png", args.threshold)
        summary["results"][name] = result
        if result.get("pass") is not True:
            all_ok = False

    summary["all_pass"] = all_ok
    payload = json.dumps(summary, indent=2, sort_keys=True)
    if args.output:
        args.output.write_text(payload + "\n")
        print(f"[metal-golden] wrote {args.output}", file=sys.stderr)
    print(payload)
    return 0 if all_ok else 1


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    p_capture = sub.add_parser("capture", help="capture the golden-image config matrix")
    p_capture.add_argument("--output-dir", type=Path, default=DEFAULT_GOLDEN_DIR, help="directory to write PNGs + manifest.json into (default: .omc/golden/ directly, per the config-matrix spec's .omc/golden/<config>.png; pass an explicit subdirectory, e.g. .omc/golden/gl-baseline, to keep multiple captures around for `compare`)")
    p_capture.add_argument("--configs", nargs="+", choices=list(CONFIG_MATRIX), default=None, help="subset of the config matrix to capture (default: all)")
    p_capture.add_argument("--timeout", type=float, default=30.0, help="seconds to wait per config capture (default: 30)")
    p_capture.add_argument("--env", action="append", default=None, metavar="KEY=VALUE", help="extra environment variable(s) for the spawned kitty (repeatable) -- for lever ON-arm golden runs, e.g. --env KITTY_PAUSE_SNAPSHOT_COW=1; passed through spawn_kitty's sanitized env as extra_env")
    p_capture.set_defaults(func=cmd_capture)

    p_compare = sub.add_parser("compare", help="compare two golden-image directories")
    p_compare.add_argument("dir_a", type=Path)
    p_compare.add_argument("dir_b", type=Path)
    p_compare.add_argument("--threshold", type=int, default=1, help="max allowed per-channel diff, in 8-bit LSBs (default: 1)")
    p_compare.add_argument("--output", type=Path, default=None, help="also write the JSON summary to this path")
    p_compare.set_defaults(func=cmd_compare)

    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_arg_parser().parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
