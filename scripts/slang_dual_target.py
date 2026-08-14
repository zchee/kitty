#!/usr/bin/env python3.14
"""Dual-target compile gate for kitty's slang shaders (W2 lane).

Measures which entry-point shader in kitty/shaders/*.slang slangc can carry
to each of the two backends we ship:

  * `-target glsl`     -- the OpenGL backend (Linux), profile glsl_150
  * `-target metallib` -- the Metal backend (macOS)

For each entry-point shader it compiles both entry points (vertex +
fragment) to both targets and prints a shader x stage x target table plus a
summary line; exit status is non-zero if anything failed. A failing shader
never aborts the run: every remaining shader is still compiled and the full
table is always printed.

The glsl column is `slangc accepted it` -- NOT `valid for desktop GL`
-------------------------------------------------------------------------
`-target glsl -profile glsl_150` emits Vulkan-flavoured GLSL: `#version
460`, `#extension GL_ARB_shader_draw_parameters`, `layout(push_constant)`,
`gl_VertexIndex`/`gl_BaseVertex`. What decides GL validity is kitty's own
post-processing, `fixup_opengl_code()` in kitty/shaders/slang.py:534, which
rewrites the version, comments out the extension/push_constant/binding
lines, maps gl_VertexIndex->gl_VertexID and gl_BaseVertex->0, and flattens
non-std140 uniform blocks into the loose glUniform* uniforms that
kitty/glsl-uniforms.h is generated from. So slangc succeeding proves
nothing on its own, and the harness scans the emitted GLSL for constructs
fixup has no rule for -- see VK_ONLY_GLSL below -- and reports them in the
`vk-glsl` column. Anything listed there would reach the GL driver as-is.

Metal defect taxonomy (see DEFECTS)
-----------------------------------
Failures are classified by their first compiler error line so the table can
be read as evidence:
  defect A (stage_in-ptr)      an entry point that mixes a `uniform`
                               parameter with vertex-attribute parameters
                               has its whole parameter list pointerized, and
                               the emitter then stamps `[[stage_in]]` on the
                               pointers: `type 'const float4 *' is not valid
                               for attribute 'stage_in'`. Measured on
                               border.slang's vertex_main: dropping the
                               uniform parameter (attributes kept) compiles;
                               keeping it and adding semantics to the
                               attributes still fails; blit.slang's uniform
                               parameters are fine because that entry point
                               has no attribute inputs, only SV_VertexID.
  defect B (combined-sampler)  `GetDimensions()` / `[]` on a combined
                               Sampler2D lowered to nonsense on
                               `metal::sampler` (the sampler is passed where
                               the out-param/coordinate belongs). Plain
                               `.Sample()` on the same object is fine, which
                               is why only cell.slang trips this.
Both are slang Metal-emitter defects, not shader bugs; do NOT edit shaders
to dodge them (the obvious workarounds -- hoisting the uniform parameter to
file scope, splitting the combined sampler -- change what the GL side gets
out of fixup_opengl_code and silently break the GL host contract).

Why `-target metallib` and never `-target metal`
------------------------------------------------
`-target metal` stops at MSL *source* generation and reports success even
when the MSL it emitted cannot be compiled by Apple's Metal compiler.
`-target metallib` runs the real Metal compiler (metal/metallib via xcrun)
and is therefore the only invocation that actually gates the Metal backend.
Do NOT "optimize" this back to `-target metal`: it silently turns the Metal
half of this harness into a no-op.

Compilation model (mirrors kitty/shaders/slang.py)
--------------------------------------------------
Module-separated compilation is MANDATORY. Handing several .slang sources
to one slangc invocation fails with `conflicting declaration`, so we do what
the real build does:

  1. every .slang file -> a `.slang-module` (`-target none`)
  2. each entry point   -> linked from that module against the requested
                           target, one invocation per (entry point, target)

Sources are materialized into a temp build dir so nothing lands in the repo
-- from the working tree by default, or from any git ref with `--git-ref`
(`--git-ref HEAD` measures the committed baseline while the working tree is
being edited).

Specializations
---------------
`extern static const` declarations without a default (cell.slang has four)
make linking fail with `unresolved external symbol` unless a specialization
module supplies values, so this harness generates ONE representative
specialization module per shader that needs it. graphics.slang's externs
carry defaults and link standalone, so it gets none. One representative
specialization per shader is deliberate: exhaustive specialization coverage
(every cell.slang variant, the graphics alpha_mask/premult variants, ...) is
a later wave's job -- this harness answers "does it compile for both
targets at all", not "does every variant compile".

Preprocessor defines come from kitty.fast_data_types, the same source the
real pipeline reads (see `SlangFile.defines` in kitty/shaders/slang.py), so
they cannot drift from the C values.

Usage:

    scripts/slang_dual_target.py                 # working tree, both targets
    scripts/slang_dual_target.py --git-ref HEAD  # committed baseline
    scripts/slang_dual_target.py --only cell border
    scripts/slang_dual_target.py --target glsl -v
    scripts/slang_dual_target.py --json          # machine-readable summary
    SLANGC=/path/to/slangc scripts/slang_dual_target.py
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Any, Iterable, NamedTuple

REPO_ROOT = Path(__file__).resolve().parent.parent
SHADERS_DIR = REPO_ROOT / "kitty" / "shaders"
DEFAULT_SLANGC = "/opt/local/slang/bin/slangc"
# slangc rejects glsl_140 (https://github.com/shader-slang/slang/issues/11898)
# so the real pipeline clamps to 150; keep the same floor here.
GLSL_PROFILE = "glsl_150"
TARGETS = ("glsl", "metallib")
TOOL = "slang-dual-target"

# -D name -> kitty.fast_data_types attribute, per shader file. Copied in
# structure (not in values) from SlangFile.defines in kitty/shaders/slang.py;
# the values themselves are read from the extension module at runtime.
DEFINES: dict[str, dict[str, str]] = {
    "cell": {
        "MARK_MASK": "MARK_MASK",
        "REVERSE_SHIFT": "REVERSE",
        "STRIKE_SHIFT": "STRIKETHROUGH",
        "DIM_SHIFT": "DIM",
        "BLINK_SHIFT": "BLINK",
        "DECORATION_SHIFT": "DECORATION",
        "MARK_SHIFT": "MARK",
        "DECORATION_MASK": "DECORATION_MASK",
        "COLOR_NOT_SET": "COLOR_NOT_SET",
        "COLOR_IS_SPECIAL": "COLOR_IS_SPECIAL",
        "COLOR_IS_INDEX": "COLOR_IS_INDEX",
        "COLOR_IS_RGB": "COLOR_IS_RGB",
    },
}

# Representative value for a defaultless `extern static const`, by variable
# name; anything not listed falls back to a value picked from its type. These
# only need to be *a* legal specialization -- see the module docstring.
SPECIALIZATION_VALUES: dict[str, str] = {
    "FG_OVERRIDE_ALGO": "1",
    "TEXT_NEW_GAMMA": "false",
    "ONLY_FOREGROUND": "false",
    "ONLY_BACKGROUND": "false",
}
TYPE_DEFAULTS: dict[str, str] = {"bool": "false", "int": "0", "uint": "0", "float": "0.0"}

BLOCK_COMMENT = re.compile(r"/\*[\s\S]*?\*/")

# Failure taxonomy, matched against the first compiler error line. Keyed by
# the observed error text rather than by any guess at the root cause, so a
# reclassification only ever needs a new pattern.
DEFECTS: tuple[tuple[str, str, re.Pattern[str]], ...] = (
    ("A", "stage_in-ptr", re.compile(r"is not valid for attribute 'stage_in'|\bstage_in\b")),
    ("B", "combined-sampler", re.compile(r"metal::sampler")),
)

# Vulkan-only GLSL that kitty's fixup_opengl_code() has NO rule for, so it
# would reach the GL driver verbatim. Everything fixup *does* handle
# (#version, #extension, layout(push_constant), layout(binding =),
# gl_VertexIndex, gl_BaseVertex, gl_InstanceIndex, gl_BaseInstance,
# non-std140 uniform blocks) is deliberately absent from this table --
# see kitty/shaders/slang.py:586-625.
VK_ONLY_GLSL: tuple[tuple[str, re.Pattern[str]], ...] = (
    # separate texture objects: no such opaque type in desktop GLSL, and
    # fixup only recognizes `uniform sampler*` declarations as uniforms
    ("separate-texture", re.compile(r"^\s*uniform\s+[uip]?texture(1D|2D|3D|Cube|Buffer)", re.M)),
    # bare `uniform sampler foo;` (Vulkan separate sampler). fixup's textual
    # `startswith('sampler')` check accepts it, so it is silently registered
    # as a loose uniform and then fails at glCompileShader time.
    ("separate-sampler", re.compile(r"^\s*uniform\s+sampler(Shadow)?\s+\w+\s*;", re.M)),
    ("subpass-input", re.compile(r"^\s*(layout[^\n]*)?\buniform\s+subpassInput", re.M)),
    ("descriptor-set", re.compile(r"layout\s*\([^)]*\bset\s*=", re.M)),
)


class HarnessError(Exception):
    """Environment/usage problem (missing git ref, unbuilt fast_data_types, ...):
    reported as exit status 2, distinct from a shader that failed to compile."""


class Source(NamedTuple):
    name: str  # file stem, e.g. "alpha-blend" (NOT the declared module name)
    path: Path
    imports: frozenset[str]  # declared module names, e.g. "alpha_blend"
    entry_points: tuple[tuple[str, str], ...]  # (stage, function name)
    externs: dict[str, str]  # variable name -> full declaration line
    disable_warnings: tuple[str, ...]

    @property
    def is_entry_point_shader(self) -> bool:
        return bool(self.entry_points)

    @property
    def needs_specialization(self) -> bool:
        return any("=" not in decl for decl in self.externs.values())


class Result(NamedTuple):
    kind: str  # "module" | "link"
    shader: str
    stage: str
    target: str
    ok: bool
    error: str
    cmd: list[str]
    seconds: float
    vk_only: tuple[str, ...] = ()  # Vulkan-only constructs found in emitted GLSL

    @property
    def defect(self) -> str:
        """Failure taxonomy id, e.g. "B (combined-sampler)"; "" when passing."""
        if self.ok:
            return ""
        for ident, label, pattern in DEFECTS:
            if pattern.search(self.error):
                return f"{ident} ({label})"
        return "unclassified"

    @property
    def emitter(self) -> str:
        """Which compiler rejected it: slang itself, or Apple's metal driver."""
        if self.ok:
            return ""
        return "metal" if self.error.startswith("metal ") else "slang"


def log(msg: str) -> None:
    print(f"[{TOOL}] {msg}", file=sys.stderr)


def parse_source(path: Path) -> Source:
    """Line-oriented parse mirroring parse_slang_text() in kitty/shaders/slang.py.

    Deliberately reimplemented in stdlib-only form rather than imported: the
    harness must keep working while the shader pipeline itself is being
    ported, and importing slang.py drags in the whole compiled kitty module.
    """
    text = BLOCK_COMMENT.sub("", path.read_text())
    imports: set[str] = set()
    entry_points: list[tuple[str, str]] = []
    externs: dict[str, str] = {}
    disable_warnings: list[str] = []
    pending_stage = ""
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        if line.startswith("//"):
            if line.startswith("// warnings-disable: "):
                for word in line.split()[2:]:
                    disable_warnings.extend(w for w in word.split(",") if w)
            continue
        words = line.split()
        if pending_stage:
            if words[0].startswith("["):  # a further attribute, e.g. [require(...)]
                continue
            for word in words:
                if "(" in word:
                    name = word.partition("(")[0]
                    if pending_stage in ("fragment", "pixel"):
                        entry_points.append(("fragment", name))
                    elif pending_stage == "vertex":
                        entry_points.append(("vertex", name))
                    break
            pending_stage = ""
            continue
        match words[0]:
            case "import":
                imports.add(words[1].removesuffix(";"))
            case "extern":
                if len(words) > 3 and words[1:3] == ["static", "const"]:
                    externs[line.partition("=")[0].split()[-1].rstrip(";")] = line
            case _:
                if words[0].startswith("[shader("):  # )]
                    pending_stage = words[0].partition("(")[2].partition(")")[0].strip().strip('"')
    return Source(
        path.stem, path, frozenset(imports), tuple(entry_points), externs, tuple(disable_warnings)
    )


def discover(shaders_dir: Path) -> dict[str, Source]:
    return {p.stem: parse_source(p) for p in sorted(shaders_dir.glob("*.slang"))}


def materialize(build_dir: Path, shaders_dir: Path, git_ref: str) -> dict[str, str]:
    """Fill the temp build dir with the .slang sources to measure.

    Without --git-ref that is the working tree; with it, the sources are read
    out of git (read-only, never touching the checkout) so the harness can
    measure a committed baseline while the working tree is being edited.
    Returns provenance for the JSON summary.
    """
    if not git_ref:
        for path in shaders_dir.glob("*.slang"):
            shutil.copy2(path, build_dir / path.name)
        return {"source": "worktree", "path": str(shaders_dir)}

    def git(*args: str) -> str:
        proc = subprocess.run(["git", "-C", str(REPO_ROOT), *args], capture_output=True, text=True)
        if proc.returncode != 0:
            raise HarnessError(f"git {' '.join(args)} failed: {proc.stderr.strip()}")
        return proc.stdout

    rel = os.path.relpath(shaders_dir, REPO_ROOT)
    names = [ln for ln in git("ls-tree", "--name-only", git_ref, f"{rel}/").splitlines() if ln.endswith(".slang")]
    if not names:
        raise HarnessError(f"no .slang files under {rel}/ at git ref {git_ref}")
    for name in names:
        (build_dir / Path(name).name).write_text(git("show", f"{git_ref}:{name}"))
    return {"source": "git", "ref": git_ref, "commit": git("rev-parse", git_ref).strip(), "path": rel}


def scan_vk_only_glsl(path: Path) -> tuple[str, ...]:
    """Vulkan-only constructs in emitted GLSL that fixup_opengl_code cannot fix.

    `slangc -target glsl` succeeding does NOT mean the GLSL is valid desktop
    GL -- see the module docstring. This is the cheap half of that check.
    """
    try:
        text = path.read_text()
    except OSError:
        return ()
    return tuple(name for name, pattern in VK_ONLY_GLSL if pattern.search(text))


def build_order(sources: dict[str, Source]) -> list[Source]:
    """Topological order over `import` edges, so a module is always built
    after everything it imports (slangc would otherwise read a .slang-module
    another process is still writing)."""
    by_module: dict[str, str] = {}
    for stem in sources:
        by_module[stem] = stem
        by_module[stem.replace("-", "_")] = stem  # `import alpha_blend` -> alpha-blend.slang
    order: list[Source] = []
    seen: set[str] = set()

    def visit(stem: str, stack: frozenset[str] = frozenset()) -> None:
        if stem in seen or stem in stack:
            return
        for dep in sorted(sources[stem].imports):
            target = by_module.get(dep)
            if target is not None:
                visit(target, stack | {stem})
        seen.add(stem)
        order.append(sources[stem])

    for stem in sources:
        visit(stem)
    return order


def load_defines(shader: str) -> list[str]:
    """Read the -D values from kitty.fast_data_types, exactly like the build."""
    wanted = DEFINES.get(shader)
    if not wanted:
        return []
    if str(REPO_ROOT) not in sys.path:
        sys.path.insert(0, str(REPO_ROOT))
    try:
        fdt = __import__("kitty.fast_data_types", fromlist=["*"])
    except ImportError as err:  # fail fast: guessing these values would make the gate a lie
        raise HarnessError(
            f"cannot import kitty.fast_data_types ({err}); {shader}.slang needs its preprocessor "
            f"defines. Build kitty first: python3.14 setup.py build"
        ) from err
    return [f"-D{name}={getattr(fdt, attr)}" for name, attr in sorted(wanted.items())]


def specialization_text(source: Source) -> str:
    """One representative specialization for every defaultless extern.

    Mirrors create_specialisations() in kitty/shaders/slang.py: the extern
    declaration is reused verbatim with `extern` -> `export` so the type
    always matches the shader's own.
    """
    lines = []
    for name, decl in sorted(source.externs.items()):
        if "=" in decl:
            continue  # has a default, links standalone
        declaration = decl.rstrip(";").replace("extern ", "export ", 1)
        value = SPECIALIZATION_VALUES.get(name)
        if value is None:
            words = declaration.split()
            value = TYPE_DEFAULTS.get(words[-2] if len(words) > 1 else "", "0")
        lines.append(f"{declaration} = {value};")
    return "\n".join(lines) + "\n" if lines else ""


def run(cmd: list[str], kind: str, shader: str, stage: str, target: str) -> Result:
    start = time.monotonic()
    proc = subprocess.run(cmd, capture_output=True, text=True)
    seconds = time.monotonic() - start
    output = (proc.stderr.strip() or proc.stdout.strip()).splitlines()
    error = ""
    if proc.returncode != 0:
        index = next((i for i, ln in enumerate(output) if "error" in ln.lower()), None)
        if index is None:
            error = output[0].strip() if output else f"exit status {proc.returncode}"
        else:
            error = output[index].strip()
            # slang puts the source location on the following ` --> path:line:col` line
            if index + 1 < len(output) and output[index + 1].lstrip().startswith("-->"):
                error = f"{error} {output[index + 1].strip()}"
    return Result(kind, shader, stage, target, proc.returncode == 0, error, cmd, seconds)


class Builder:

    def __init__(self, slangc: str, build_dir: Path, warnings_as_errors: bool, verbose: bool) -> None:
        self.slangc = slangc
        self.build_dir = build_dir
        self.warnings_as_errors = warnings_as_errors
        self.verbose = verbose

    def base(self, source: Source) -> list[str]:
        cmd = [self.slangc]
        if self.warnings_as_errors:
            cmd += ["-warnings-as-errors", "all"]
        if source.disable_warnings:
            cmd += ["-warnings-disable", ",".join(source.disable_warnings)]
        return cmd

    def module_path(self, source: Source) -> Path:
        return self.build_dir / f"{source.name}.slang-module"

    def spec_path(self, source: Source) -> Path:
        return self.build_dir / f"{source.name}.spec.slang-module"

    def compile_module(self, source: Source) -> Result:
        cmd = self.base(source) + load_defines(source.name) + [
            "-I", str(self.build_dir),
            "-target", "none",
            "-o", str(self.module_path(source)),
            "--", str(self.build_dir / source.path.name),
        ]
        return self.trace(run(cmd, "module", source.name, "-", "module"))

    def compile_specialization(self, source: Source) -> Result:
        text = specialization_text(source)
        src = self.build_dir / f"{source.name}.spec.slang"
        src.write_text(text)
        cmd = [self.slangc, "-I", str(self.build_dir), str(src), "-o", str(self.spec_path(source))]
        return self.trace(run(cmd, "module", source.name, "-", "specialization"))

    def link(self, source: Source, stage: str, entry: str, target: str) -> Result:
        cmd = self.base(source) + ["-I", str(self.build_dir)]
        if source.needs_specialization:
            cmd.append(str(self.spec_path(source)))  # must precede the shader's own module
        cmd.append(str(self.module_path(source)))
        out = self.build_dir / f"{source.name}.{stage}.{target}"
        # metallib (never `metal`) is the Metal gate -- see the module docstring.
        cmd += ["-target", target, "-line-directive-mode", "none"]
        if target == "glsl":
            cmd += ["-profile", GLSL_PROFILE]
        cmd += ["-entry", entry, "-stage", stage, "-o", str(out)]
        result = self.trace(run(cmd, "link", source.name, stage, target))
        if result.ok and not (out.exists() and out.stat().st_size):
            return result._replace(ok=False, error=f"slangc reported success but wrote no {out.name}")
        if result.ok and target == "glsl":
            return result._replace(vk_only=scan_vk_only_glsl(out))
        return result

    def trace(self, result: Result) -> Result:
        if self.verbose:
            status = "ok  " if result.ok else "FAIL"
            log(f"{status} {result.seconds:6.2f}s  {' '.join(result.cmd)}")
        return result


# `glsl` is titled "slangc accepted it": GL validity is decided by
# fixup_opengl_code(), not by slangc -- see the module docstring.
COLUMN_TITLES = {"glsl": "glsl(slangc)", "metallib": "metallib"}


def format_table(sources: list[Source], links: dict[tuple[str, str, str], Result], targets: Iterable[str]) -> str:
    targets = list(targets)
    columns = [max(8, len(COLUMN_TITLES.get(t, t))) for t in targets]
    shader_w = max(6, *(len(s.name) for s in sources))
    header = f"{'shader'.ljust(shader_w)}  {'stage'.ljust(8)}  " + "  ".join(
        COLUMN_TITLES.get(t, t).ljust(w) for t, w in zip(targets, columns)
    )
    if "glsl" in targets:
        header += "  vk-glsl"
    lines = [header, "-" * len(header)]
    for source in sources:
        for stage, _ in sorted(source.entry_points):
            cells = []
            for target, width in zip(targets, columns):
                result = links.get((source.name, stage, target))
                if result is None:
                    text = "--"
                elif result.ok:
                    text = "OK"
                else:
                    text = f"FAIL {result.defect.partition(' ')[0]}".strip()
                cells.append(text.ljust(width))
            row = f"{source.name.ljust(shader_w)}  {stage.ljust(8)}  " + "  ".join(cells)
            if "glsl" in targets:
                glsl = links.get((source.name, stage, "glsl"))
                row += "  " + (",".join(glsl.vk_only) if glsl and glsl.vk_only else "-")
            lines.append(row.rstrip())
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=(__doc__ or "").splitlines()[0], formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--slangc", default=os.environ.get("SLANGC") or DEFAULT_SLANGC,
                        help=f"slangc binary (env SLANGC, default: {DEFAULT_SLANGC})")
    parser.add_argument("--shaders-dir", type=Path, default=SHADERS_DIR, help="directory of .slang sources")
    parser.add_argument("--git-ref", default="", metavar="REF",
                        help="read the sources from this git ref instead of the working tree "
                             "(e.g. HEAD, to measure the committed baseline while the tree is edited)")
    parser.add_argument("--only", nargs="+", metavar="SHADER", default=None,
                        help="restrict to these entry-point shaders (by file stem)")
    parser.add_argument("--target", choices=(*TARGETS, "both"), default="both", help="which target(s) to compile")
    parser.add_argument("--jobs", type=int, default=min(8, os.cpu_count() or 4), help="parallel link jobs")
    parser.add_argument("--no-warnings-as-errors", dest="warnings_as_errors", action="store_false",
                        help="relax the build's -warnings-as-errors all (the real build uses it)")
    parser.add_argument("--keep", action="store_true",
                        help="keep the temp build dir (with the emitted .glsl/.metallib) and print its path")
    parser.add_argument("--json", action="store_true", help="print the JSON summary instead of the table")
    parser.add_argument("--output", type=Path, default=None, help="also write the JSON summary to this path")
    parser.add_argument("-v", "--verbose", action="store_true", help="log every slangc invocation")
    args = parser.parse_args(argv)

    slangc = shutil.which(args.slangc) or args.slangc
    if not Path(slangc).exists():
        log(f"slangc not found at {args.slangc}; pass --slangc or set SLANGC")
        return 2
    if not args.git_ref and not args.shaders_dir.is_dir():
        log(f"no such shaders dir: {args.shaders_dir}")
        return 2
    targets = list(TARGETS) if args.target == "both" else [args.target]

    build_dir = Path(tempfile.mkdtemp(prefix="slang-dual-target-"))
    start = time.monotonic()
    modules: list[Result] = []
    links: dict[tuple[str, str, str], Result] = {}
    try:
        provenance = materialize(build_dir, args.shaders_dir, args.git_ref)
        # Parse what we will actually compile, not the working tree: with
        # --git-ref those differ, and the table must describe the sources
        # that produced it.
        sources = discover(build_dir)
        if not sources:
            log(f"no .slang sources for {provenance}")
            return 2
        entry_shaders = [s for s in build_order(sources) if s.is_entry_point_shader]
        if args.only:
            unknown = sorted(set(args.only) - {s.name for s in entry_shaders})
            if unknown:
                log(f"unknown entry-point shader(s): {', '.join(unknown)}")
                return 2
            entry_shaders = [s for s in entry_shaders if s.name in args.only]
        builder = Builder(slangc, build_dir, args.warnings_as_errors, args.verbose)

        # Modules first, in dependency order: linking reads them, and a
        # single slangc invocation over several sources fails outright with
        # `conflicting declaration`.
        buildable = {s.name for s in entry_shaders}
        for source in build_order(sources):
            if source.is_entry_point_shader and source.name not in buildable:
                continue
            result = builder.compile_module(source)
            modules.append(result)
            if not result.ok:
                buildable.discard(source.name)
            elif source.is_entry_point_shader and source.needs_specialization:
                spec = builder.compile_specialization(source)
                modules.append(spec)
                if not spec.ok:
                    buildable.discard(source.name)

        jobs = [
            (source, stage, entry, target)
            for source in entry_shaders if source.name in buildable
            for stage, entry in sorted(source.entry_points)
            for target in targets
        ]
        with ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
            for result in pool.map(lambda j: builder.link(j[0], j[1], j[2], j[3]), jobs):
                links[(result.shader, result.stage, result.target)] = result
    finally:
        if args.keep:
            log(f"build dir kept: {build_dir}")
        else:
            shutil.rmtree(build_dir, ignore_errors=True)

    elapsed = time.monotonic() - start
    # Drop the temp build dir prefix so slang's `--> path:line:col` reads as a
    # shader-relative location (the dir is gone by the time anyone reads it).
    failures = [r._replace(error=r.error.replace(f"{build_dir}/", ""))
                for r in (*modules, *links.values()) if not r.ok]
    expected = sum(len(s.entry_points) for s in entry_shaders) * len(targets)
    ok_links = sum(1 for r in links.values() if r.ok)
    version = subprocess.run([slangc, "-version"], capture_output=True, text=True)
    summary: dict[str, Any] = {
        "tool": TOOL,
        "slangc": slangc,
        "slangc_version": (version.stdout.strip() or version.stderr.strip()),
        "sources": provenance,
        "targets": targets,
        "glsl_profile": GLSL_PROFILE,
        "warnings_as_errors": args.warnings_as_errors,
        "seconds": round(elapsed, 2),
        "modules": {"total": len(modules), "ok": sum(1 for r in modules if r.ok)},
        "links": {"total": len(links), "expected": expected, "ok": ok_links},
        "shaders": {
            s.name: {
                stage: {
                    **{t: ("ok" if (r := links.get((s.name, stage, t))) and r.ok else "fail" if r else "skipped")
                       for t in targets},
                    "defect": next((r.defect for t in targets
                                    if (r := links.get((s.name, stage, t))) and not r.ok), ""),
                    "vk_only_glsl": list((g := links.get((s.name, stage, "glsl"))) and g.vk_only or ()),
                }
                for stage, _ in sorted(s.entry_points)
            }
            for s in entry_shaders
        },
        "failures": [
            {"kind": r.kind, "shader": r.shader, "stage": r.stage, "target": r.target,
             "defect": r.defect, "reported_by": r.emitter, "error": r.error}
            for r in failures
        ],
        "ok": not failures and ok_links == expected,
    }

    payload = json.dumps(summary, indent=2, sort_keys=True)
    if args.output:
        args.output.write_text(payload + "\n")
        log(f"wrote {args.output}")
    if args.json:
        print(payload)
    else:
        print(f"sources: {provenance.get('source')}"
              f"{' ' + provenance['ref'] + '@' + provenance['commit'][:9] if provenance.get('commit') else ''}"
              f"  slangc: {summary['slangc_version']}\n")
        print(format_table(entry_shaders, links, targets))
        if "glsl" in targets:
            print("\nglsl(slangc) = slangc emitted GLSL, NOT `valid desktop GL`: kitty's "
                  "fixup_opengl_code() (kitty/shaders/slang.py:534) decides that.\n"
                  "vk-glsl = Vulkan-only constructs in the emitted GLSL that fixup has no rule "
                  "for; `-` means none.")
        if failures:
            print("\nFAILURES (first compiler error line, verbatim -- this is the upstream evidence)")
            for r in failures:
                where = f"{r.shader} [{r.kind}]" if r.kind == "module" else f"{r.shader} {r.stage} -> {r.target}"
                print(f"  {where}  defect {r.defect} (reported by {r.emitter})\n    {r.error}")
        status = "PASS" if summary["ok"] else "FAIL"
        stages = sorted({stage for s in entry_shaders for stage, _ in s.entry_points})
        print(
            f"\nSUMMARY: {status}  {ok_links}/{expected} entry-point compiles ok "
            f"({len(entry_shaders)} shaders x {len(stages)} stages x {len(targets)} targets), "
            f"{summary['modules']['ok']}/{summary['modules']['total']} modules ok, {elapsed:.1f}s"
        )
    return 0 if summary["ok"] else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except HarnessError as err:  # environment/usage problem, not a shader failure
        log(str(err))
        raise SystemExit(2) from err
