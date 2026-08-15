#!/usr/bin/env python
# License: GPLv3 Copyright: 2026, Kovid Goyal <kovid at kovidgoyal.net>

import glob
import hashlib
import json
import os
import re
import runpy
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import types
from collections import OrderedDict
from contextlib import suppress
from enum import StrEnum, auto
from functools import lru_cache, partial
from itertools import chain, product
from types import MappingProxyType
from typing import Any, Callable, Iterable, Iterator, Literal, NamedTuple, TypedDict, TypeGuard

from kitty.constants import read_kitty_resource, shaders_dir, slangc
from kitty.fast_data_types import (
    ANIMATION_SAMPLE_WAIT,
    BGIMAGE_PROGRAM,
    BLINK,
    BLIT_PROGRAM,
    BORDERS_PROGRAM,
    CELL_BG_PROGRAM,
    CELL_FG_PROGRAM,
    CELL_PROGRAM,
    COLOR_IS_INDEX,
    COLOR_IS_RGB,
    COLOR_IS_SPECIAL,
    COLOR_NOT_SET,
    CUSTOM_END_PROGRAM,
    DECORATION,
    DECORATION_MASK,
    DIM,
    GLSL_VERSION,
    GRAPHICS_ALPHA_MASK_PROGRAM,
    GRAPHICS_PREMULT_PROGRAM,
    GRAPHICS_PROGRAM,
    MARK,
    MARK_MASK,
    MAX_CUSTOM_SHADER_GROUPS,
    PADDING_PROGRAM,
    REVERSE,
    ROUNDED_RECT_PROGRAM,
    SCREENSHOT_PROGRAM,
    STRIKETHROUGH,
    TINT_PROGRAM,
    TRAIL_PROGRAM,
    compile_program,
    get_options,
    set_cell_shader_opts,
)
from kitty.options.types import Options, defaults
from kitty.options.utils import EasingFunction
from kitty.types import run_once
from kitty.utils import lock_with_file, log_error, resolve_custom_file


@lru_cache(maxsize=64)
def get_shader_src(name: str) -> str:
    return read_kitty_resource(f'{name}.slang', 'kitty.shaders').decode()


@lru_cache(maxsize=64)
def get_custom_shader_src(name: str) -> bytes:
    return read_kitty_resource(f'{name}.slang', 'kitty.shaders.custom')


@lru_cache(maxsize=32)
def get_custom_pipeline_src(name: str) -> bytes:
    return read_kitty_resource(f'{name}.pipeline', 'kitty.shaders.custom')


@run_once
def slangc_version() -> str:
    return subprocess.check_output(list(slangc()) + ['-version'], stderr=subprocess.STDOUT).decode().strip()


def is_dir_ok(path: str, checks: dict[str, str]) -> bool:
    for fname, expected in checks.items():
        try:
            with open(os.path.join(path, fname)) as f:
                if f.read().strip() != expected:
                    return False
        except OSError:
            return False
    return True


def ensure_cache_dir(path: str) -> None:
    "Ensure the cache dir is for the current slangc version and slang.py version"
    os.makedirs(path, exist_ok=True)
    # slang IR is version dependent and the compiler often crashes when loading .slang-module from another version
    checks = {'slangc.version': slangc_version(), 'slangpy.version': get_hash_for_self()}
    if not is_dir_ok(path, checks):
        shutil.rmtree(path)
        os.makedirs(path)
        for fname, expected in checks.items():
            with open(os.path.join(path, fname), 'w') as f:
                f.write(expected)


class Stage(StrEnum):
    vertex = 'vertex'
    fragment = 'fragment'


class EntryPoint(NamedTuple):
    stage: Stage
    name: str

    def asdict(self) -> dict[str, str]:
        return {'stage': str(self.stage), 'name': self.name}

    @classmethod
    def fromdict(self, s: dict[str, str]) -> 'EntryPoint':
        return EntryPoint(Stage(s['stage']), s['name'])


class Specialization(NamedTuple):
    name: str
    variables: MappingProxyType[str, str]

    @property
    def filename_insert(self) -> str:
        return f'.{self.name}' if self.name else '.default-specialization'


def cell_variant(opts: Options = defaults, program: int = CELL_PROGRAM) -> dict[str, str]:
    text_fg_override_threshold: float = opts.text_fg_override_threshold[0]
    algo = '0'
    match opts.text_fg_override_threshold[1]:
        case '%':
            text_fg_override_threshold = max(0, min(text_fg_override_threshold, 100.0)) * 0.01
            algo = '1'
        case 'ratio':
            text_fg_override_threshold = max(0, min(text_fg_override_threshold, 21.0))
            algo = '2'
    if not text_fg_override_threshold:
        algo = '0'
    render_mode = (CELL_PROGRAM, CELL_BG_PROGRAM, CELL_FG_PROGRAM).index(program)
    return {
        'FG_OVERRIDE_ALGO': algo,
        'TEXT_NEW_GAMMA': 'false' if opts.text_composition_strategy == 'legacy' else 'true',
        'RENDER_MODE': str(render_mode),
    }


@lru_cache(maxsize=2)
def cell_variations() -> tuple[MappingProxyType[str, str], ...]:
    variations = {'FG_OVERRIDE_ALGO': ('0', '1', '2'), 'RENDER_MODE': ('0', '1', '2')}
    bool_variations = 'false', 'true'
    variants_dict = {k: variations.get(k, bool_variations) for k in cell_variant()}
    return tuple(MappingProxyType(dict(zip(variants_dict.keys(), comb))) for comb in product(*variants_dict.values()))


def variant_name(variant: dict[str, str], default: dict[str, str]) -> str:
    if variant == default:
        return ''
    data = ' '.join(f'{k}={variant[k]}' for k in sorted(default)).encode()
    key = hashlib.md5(data, usedforsecurity=False)
    return key.hexdigest()[:5]


def glsl_shaders(name: str, variant_name: str = '') -> tuple[str, str]:
    if variant_name:
        variant_name = '.' + variant_name
    with open(os.path.join(shaders_dir, f'{name}{variant_name}.vert.glsl')) as f:
        vert = f.read()
    with open(os.path.join(shaders_dir, f'{name}{variant_name}.frag.glsl')) as f:
        frag = f.read()
    return vert, frag


class LoadShaderPrograms:
    text_fg_override_threshold: tuple[float, Literal['%', 'ratio']] = 0, '%'
    text_old_gamma: bool = False
    custom_shaders: tuple[str, ...] = ()
    force_recompile_of_custom_shaders: bool = False
    last_built_custom_shaders: dict[int, Any] = {}

    opts: Options | None = None

    def get_options(self) -> Options:
        try:
            return self.opts or get_options()
        except RuntimeError:
            return defaults

    @property
    def needs_recompile(self) -> bool:
        opts = self.get_options()
        return (
            bool(opts.text_fg_override_threshold[0]) != bool(self.text_fg_override_threshold[0])
            or opts.text_fg_override_threshold[1] != self.text_fg_override_threshold[1]
            or (opts.text_composition_strategy == 'legacy') != self.text_old_gamma
        )

    def recompile_if_needed(self) -> None:
        if self.needs_recompile:
            self(allow_recompile=True)
        else:
            opts = self.get_options()
            if opts.custom_shaders != self.custom_shaders or self.force_recompile_of_custom_shaders:
                self.compile_custom_shaders(allow_recompile=True)

    def __call__(self, allow_recompile: bool = False) -> None:
        default_cell_variant = cell_variant()
        opts = self.get_options()
        self.text_old_gamma = opts.text_composition_strategy == 'legacy'
        self.text_fg_override_threshold = opts.text_fg_override_threshold
        # Resolved once, consumed twice: baked into the GLSL below for the GL
        # backend, and handed to the Metal backend directly (it takes them as
        # pipeline function constants). Computing them in one place is the point
        # -- the Metal side used to recover these by parsing the `#define`s back
        # out of the preprocessed GLSL, so the two channels could not be seen to
        # agree from any single spot in the code.
        text_fg_override_threshold: float = opts.text_fg_override_threshold[0]
        match opts.text_fg_override_threshold[1]:
            case '%':
                text_fg_override_threshold = max(0, min(text_fg_override_threshold, 100.0)) * 0.01
            case 'ratio':
                text_fg_override_threshold = max(0, min(text_fg_override_threshold, 21.0))
        do_fg_override = bool(text_fg_override_threshold)
        fg_override_algo = 1 if opts.text_fg_override_threshold[1] == '%' else 2
        text_new_gamma = not self.text_old_gamma
        set_cell_shader_opts(do_fg_override, fg_override_algo, text_fg_override_threshold, text_new_gamma)
        metadata = load_glsl_metadata()

        def cell(prog: int) -> None:
            v = cell_variant(opts, program=prog)
            vert, frag = glsl_shaders('cell', variant_name(v, default_cell_variant))
            compile_program(prog, (vert,), (frag,), metadata['cell'], allow_recompile)

        cell(CELL_PROGRAM), cell(CELL_BG_PROGRAM), cell(CELL_FG_PROGRAM)
        for prog, vname in {
            GRAPHICS_PROGRAM: '',
            GRAPHICS_ALPHA_MASK_PROGRAM: 'alpha_mask',
            GRAPHICS_PREMULT_PROGRAM: 'premult',
        }.items():
            vert, frag = glsl_shaders('graphics', vname)
            compile_program(prog, (vert,), (frag,), metadata['graphics'], allow_recompile)
        for name, prog in {
            'bgimage': BGIMAGE_PROGRAM,
            'tint': TINT_PROGRAM,
            'trail': TRAIL_PROGRAM,
            'blit': BLIT_PROGRAM,
            'screenshot': SCREENSHOT_PROGRAM,
            'rounded_rect': ROUNDED_RECT_PROGRAM,
            'border': BORDERS_PROGRAM,
            'padding': PADDING_PROGRAM,
        }.items():
            vert, frag = glsl_shaders(name)
            compile_program(prog, (vert,), (frag,), metadata[name], allow_recompile)
        compile_program(-1, (), (), {})  # initialize programs
        self.compile_custom_shaders(allow_recompile)

    def compile_custom_shaders(self, allow_recompile: bool = False) -> None:
        self.force_recompile_of_custom_shaders = False
        opts = self.get_options()
        self.custom_shaders = tuple(opts.custom_shaders)
        pmap: dict[str, list[Pipeline]] = {}
        for k in self.custom_shaders:
            try:
                d = parse_pipeline(k)
            except FileNotFoundError:
                try:
                    custom_shader(k)
                except Exception as e:
                    log_error(f'Failed to read custom shader pipeline definition from {k} with error: {e}')
                    continue
                try:
                    d = parse_pipeline_definition(['startgroup', f'    shaders {k}', 'endgroup'], k)
                except Exception as e:
                    log_error(f'Failed to build minimal shader pipeline for {k} with error: {e}')
                    continue
            except Exception as e:
                log_error(f'Failed to read custom shader pipeline definition from {k} with error: {e}')
                continue
            pmap.setdefault(d['slot'], []).append(d)

        def do(prog: int, slot: str) -> None:
            slot_pipelines = pmap.get(slot)
            if not slot_pipelines:
                compile_program(prog, (), (), {}, allow_recompile)
            else:
                try:
                    pipeline = merge_pipelines(slot_pipelines)
                    vert, frag, metadata = build_custom_shader_pipeline_glsl(pipeline)
                    # print(vert, file=open('/tmp/sample.vert', 'w'))
                    # print(frag, file=open('/tmp/sample.frag', 'w'))
                except Exception as e:
                    log_error(f'Failed to build custom shader for slot {slot} with error: {e}')
                    compile_program(prog, (), (), {}, allow_recompile)
                else:
                    try:
                        if self.last_built_custom_shaders.get(prog) != (vert, frag, metadata):
                            compile_program(prog, (vert,), (frag,), metadata, allow_recompile)
                            self.last_built_custom_shaders[prog] = vert, frag, metadata
                    except Exception as e:
                        log_error(f'Failed to load custom shader for slot {slot} with error: {e}')
                        compile_program(prog, (), (), {}, allow_recompile)

        do(CUSTOM_END_PROGRAM, 'end')
        compile_program(-2, (), (), {})  # initialize programs


load_shader_programs = LoadShaderPrograms()


class SlangFile(NamedTuple):
    path: str = ''
    text: str = ''
    imports: frozenset[str] = frozenset()
    entry_points: frozenset[EntryPoint] = frozenset()
    module: str = ''
    specializable_variables: MappingProxyType[str, str] = MappingProxyType({})
    disable_warnings: frozenset[str] = frozenset()

    def asdict(self, skip_source: bool = False) -> dict[str, Any]:
        "Return a dict useable for serialization to JSON"
        ans = self._asdict()
        ans['imports'] = tuple(ans['imports'])
        ans['entry_points'] = tuple(ep.asdict() for ep in ans['entry_points'])
        ans['specializable_variables'] = dict(ans['specializable_variables'])
        ans['disable_warnings'] = tuple(ans['disable_warnings'])
        if skip_source:
            ans['text'] = ''
            ans['path'] = os.path.basename(ans['path'])
        return ans

    @classmethod
    def fromdict(cls, s: dict[str, Any]) -> 'SlangFile':
        return SlangFile(
            s['path'],
            s['text'],
            frozenset(s['imports']),
            frozenset(EntryPoint.fromdict(x) for x in s['entry_points']),
            s['module'],
            MappingProxyType(s['specializable_variables']),
            frozenset(s['disable_warnings']),
        )

    @property
    def should_compile_to_ir(self) -> bool:
        return bool(self.module or self.entry_points)

    @property
    def defines(self) -> MappingProxyType[str, str]:
        ans = {}
        match os.path.basename(self.path):
            case 'background.slang' | 'cell.slang' | 'cell_fork.slang':
                ans['MARK_MASK'] = str(MARK_MASK)
                ans['REVERSE_SHIFT'] = str(REVERSE)
                ans['STRIKE_SHIFT'] = str(STRIKETHROUGH)
                ans['DIM_SHIFT'] = str(DIM)
                ans['BLINK_SHIFT'] = str(BLINK)
                ans['DECORATION_SHIFT'] = str(DECORATION)
                ans['MARK_SHIFT'] = str(MARK)
                ans['DECORATION_MASK'] = str(DECORATION_MASK)
                ans['COLOR_NOT_SET'] = str(COLOR_NOT_SET)
                ans['COLOR_IS_SPECIAL'] = str(COLOR_IS_SPECIAL)
                ans['COLOR_IS_INDEX'] = str(COLOR_IS_INDEX)
                ans['COLOR_IS_RGB'] = str(COLOR_IS_RGB)
        return MappingProxyType(ans)

    @property
    def specializations(self) -> Iterator[Specialization]:
        def s(name: str = '', **kwargs: str) -> Specialization:
            return Specialization(name, MappingProxyType(kwargs))

        match os.path.basename(self.path):
            case 'graphics.slang':
                yield s()
                yield s('alpha_mask', is_alpha_mask='true')
                yield s('premult', texture_is_not_premultiplied='false')
            case 'graphics_fork.slang':
                # The fork wrapper (W3h) carries upstream's axes under
                # upstream's names, so its variant set mirrors graphics'.
                yield s()
                yield s('alpha_mask', is_alpha_mask='true')
                yield s('premult', texture_is_not_premultiplied='true')
            case 'border_fork.slang':
                # W3i (ADR-0034 §2): the epilogue's reachable half of the
                # (transfer, primaries) product — metal.m's resolvers can
                # produce only these four pairs; the unreachable two fail
                # loud at the PSO site. rop_p3 is byte-identical to
                # linear_p3 today (the shader branches only on ENCODE),
                # kept distinct so C-side selection transcribes
                # target_color_space_for() instead of embedding
                # "ROP==LINEAR in this shader" as a hidden coupling.
                yield s()
                yield s('linear', target_color_space='1')
                yield s('linear_p3', target_color_space='1', target_primaries_is_p3='true')
                yield s('rop_p3', target_color_space='2', target_primaries_is_p3='true')
            case 'cell.slang':
                d = cell_variant()
                seen = set()
                for variant in cell_variations():
                    name = variant_name(dict(variant), d)
                    if name in seen:
                        raise Exception('Variant names for cell shader not unique')
                    seen.add(name)
                    yield s(name, **variant)
            case 'cell_fork.slang':
                # Phase C (ADR-0038): upstream cell.slang's axes crossed with
                # the border_fork epilogue pairs (ADR-0034 §2). Names are
                # composed, not hashed, so metal.m selects entries by
                # snprintf instead of a generated hash table:
                # rm{RENDER_MODE}a{FG_OVERRIDE_ALGO}{og|ng}[_linear|_linear_p3|_rop_p3].
                # ONLY_BACKGROUND (rm=1) has no foreground path, so the fg
                # axes collapse there to a0/og.
                targets = (
                    ('', {}),
                    ('linear', {'target_color_space': '1'}),
                    ('linear_p3', {'target_color_space': '1', 'target_primaries_is_p3': 'true'}),
                    ('rop_p3', {'target_color_space': '2', 'target_primaries_is_p3': 'true'}),
                )
                cf_seen = set()
                for variant in cell_variations():
                    v = dict(variant)
                    if v['RENDER_MODE'] == '1' and (v['FG_OVERRIDE_ALGO'] != '0' or v['TEXT_NEW_GAMMA'] != 'false'):
                        continue
                    base = f"rm{v['RENDER_MODE']}a{v['FG_OVERRIDE_ALGO']}" + ('ng' if v['TEXT_NEW_GAMMA'] == 'true' else 'og')
                    for tname, tover in targets:
                        name = f'{base}_{tname}' if tname else base
                        if name in cf_seen:
                            raise Exception('Variant names for cell_fork shader not unique')
                        cf_seen.add(name)
                        yield s(name, **v, **tover)
            case _:
                yield s()


def parse_slang_text(src_code: str, path: str = '') -> SlangFile:
    text = re.sub(r'/\*[\s\S]*?\*/', '', src_code)
    entry_points, imports = [], set()
    module = ''
    found_entry_point = ''
    specializable_variables = {}
    disable_warnings = []
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        if line.startswith('//'):
            if line.startswith('// warnings-disable: '):
                words = line.split()
                for word in words[2:]:
                    for w in word.split(','):
                        disable_warnings.append(w)
            continue
        words = line.split()
        if found_entry_point:
            if words[0].startswith('['):  # ]
                continue
            for q in words:
                if '(' in q:
                    name = q.partition('(')[0]  # ))
                    match found_entry_point:
                        case 'vertex':
                            entry_points.append(EntryPoint(Stage.vertex, name))
                        case 'fragment' | 'pixel':
                            entry_points.append(EntryPoint(Stage.fragment, name))
                    found_entry_point = ''
                    break
        else:
            match words[0]:
                case 'module':
                    module = words[1].removesuffix(';')
                case 'import':
                    imports.add(words[1].removesuffix(';'))
                case 'extern':
                    if len(words) > 3 and words[1:3] == ['static', 'const']:
                        specializable_variables[line.partition('=')[0].split()[-1].rstrip(';')] = line
                case _:
                    if words[0].startswith('[shader('):  # ])
                        text = words[0].partition('(')[2].partition(')')[0].strip()
                        found_entry_point = text[1:-1]
    return SlangFile(
        path, src_code, frozenset(imports), frozenset(entry_points), module, MappingProxyType(specializable_variables), frozenset(disable_warnings)
    )


@lru_cache(4096)
def parse_slang_file(path: str) -> SlangFile:
    with open(path) as f:
        text = f.read()
    return parse_slang_text(text, path)


def build_import_graph(dirpath: str) -> dict[str, SlangFile]:
    graph: dict[str, SlangFile] = {}
    exclude = os.path.abspath(os.path.join(dirpath, 'custom'))
    for root, _, files in os.walk(os.path.abspath(dirpath)):
        if root == exclude:
            continue
        for file in files:
            if file.endswith('.slang'):
                full_path = os.path.abspath(os.path.join(root, file))
                relpath = os.path.relpath(full_path, root)
                modname = os.path.splitext(relpath.replace(os.sep, '.'))[0]
                graph[modname] = parse_slang_file(full_path)
    return graph


def topological_sort(graph: dict[str, SlangFile]) -> list[str]:
    visited = set()
    order = []

    def visit(node: str) -> None:
        if node in visited or node not in graph:
            return
        for dep in graph[node].imports:
            visit(dep)
        visited.add(node)
        order.append(node)

    for node in graph:
        visit(node)
    return order


def topological_layers(graph: dict[str, SlangFile]) -> list[list[str]]:
    layer_of: dict[str, int] = {}

    def compute_layer(node: str) -> int:
        if node in layer_of:
            return layer_of[node]
        if node not in graph:
            return -1
        layer = max((compute_layer(dep) + 1 for dep in graph[node].imports), default=0)
        layer_of[node] = layer
        return layer

    for node in graph:
        compute_layer(node)

    if not layer_of:
        return []
    max_layer = max(layer_of.values())
    layers: list[list[str]] = [[] for _ in range(max_layer + 1)]
    for node, layer in layer_of.items():
        layers[layer].append(node)
    return layers


def get_ordered_sources_in_tree(dirpath: str) -> OrderedDict[str, SlangFile]:
    g = build_import_graph(dirpath)
    return OrderedDict({k: g[k] for k in topological_sort(g)})


def future() -> float:
    return time.time() + 1000000


def safe_mtime(path: str, defval: float = 0) -> float:
    with suppress(OSError):
        return os.path.getmtime(path)
    return defval if defval >= 0 else future()


def read_deps_file(path: str) -> Iterator[str]:
    with open(path) as f:
        for line in f:
            line = line.partition(':')[2].strip()
            yield from line.split()


def get_newest_dep_time(path: str) -> float:
    with suppress(OSError):
        ans = 0.0
        for deppath in read_deps_file(path):
            mtime = os.path.getmtime(deppath)
            ans = max(mtime, ans)
        return ans
    return future()


def sanitize_code_object(code_obj: types.CodeType) -> types.CodeType:
    """
    Recursively strips environmental metadata (like file paths and first line numbers)
    from a code object so the hash remains identical across different machines.
    """
    # Recursively process nested constants (inner functions/classes)
    new_consts = []
    for const in code_obj.co_consts:
        if isinstance(const, types.CodeType):
            new_consts.append(sanitize_code_object(const))
        else:
            new_consts.append(const)

    # Rebuild the code object with sanitized file names and line numbers
    # (Using replace() is safe and fully compatible with Python 3.8+)
    return code_obj.replace(
        co_filename='slang.py',  # Forces a uniform mock filename
        co_firstlineno=1,  # Standardizes the line number offsets
        co_consts=tuple(new_consts),
    )


@run_once
def get_hash_for_self() -> str:
    """
    Climbs to the module scope, sanitizes it, and returns a unique
    SHA-256 hash representing the entire executable structure.
    """
    import hashlib
    import importlib.util
    import marshal
    from importlib.abc import InspectLoader

    if __name__ == '__main__':
        with open(__file__, 'rb') as f:
            serialized_bytes = f.read()
    else:
        spec = importlib.util.find_spec(__name__)
        assert spec is not None and isinstance(spec.loader, InspectLoader)
        top_code_obj = spec.loader.get_code(__name__)
        assert top_code_obj is not None
        clean_code_obj = sanitize_code_object(top_code_obj)
        serialized_bytes = marshal.dumps(clean_code_obj)
    return hashlib.md5(serialized_bytes).hexdigest()


class Command(NamedTuple):
    needs_build: bool
    description: str
    cmd: list[str]


def commands_to_compile_dir_to_ir(sources: dict[str, SlangFile], src_dir: str, output_dirpath: str) -> Iterator[Command]:
    cmdbase = list(slangc()) + ['-warnings-as-errors', 'all']
    for name, sfile in sources.items():
        if sfile.should_compile_to_ir:
            parts = name.split('.')
            base_dest = os.path.join(output_dirpath, *parts)
            slang_module = f'{base_dest}.slang-module'
            deps_file = f'{base_dest}.deps'
            module_mtime = safe_mtime(slang_module)
            needs_build = module_mtime < get_newest_dep_time(deps_file)
            defines = [f'-D{k}={v}' for k, v in sfile.defines.items()]
            yield Command(
                needs_build,
                f'Compiling |{name}.slang| ...',
                cmdbase
                + defines
                + [
                    '-I',
                    output_dirpath,
                    '-I',
                    src_dir,
                    '-depfile',
                    deps_file,
                    '-target',
                    'none',
                    '-o',
                    slang_module,
                    '--',
                    sfile.path,
                ],
            )


def iter_entry_point_shaders(sources: dict[str, SlangFile], build_dir: str, dest_dir: str) -> Iterator[tuple[str, str, str, list[str], SlangFile]]:
    cmdbase = list(slangc()) + ['-warnings-as-errors', 'all']
    for name, sfile in sources.items():
        if not sfile.entry_points:
            continue
        parts = name.split('.')
        base_dest = os.path.join(dest_dir, *parts)
        base_build = os.path.join(build_dir, *parts)
        slang_module = f'{base_build}.slang-module'
        cmd = list(cmdbase)
        if sfile.disable_warnings:
            cmd += ['-warnings-disable', ','.join(sfile.disable_warnings)]
        cmd += ['-I', build_dir, slang_module]
        yield base_dest, base_build, slang_module, cmd, sfile


def serialize_source_metadata(sources: dict[str, SlangFile], dest_dir: str) -> None:
    for base_dest, _, _, _, sfile in iter_entry_point_shaders(sources, dest_dir, dest_dir):
        dest = f'{base_dest}.json'
        with open(dest, 'w') as f:
            f.write(json.dumps(sfile.asdict(skip_source=True), indent=2, sort_keys=True))


def commands_to_compile_to_spirv(sources: dict[str, SlangFile], build_dir: str, dest_dir: str, built_files: list[str]) -> Iterator[Command]:
    # glsl 450 is vulkan 1.1 and spirv 1.3 released 2008
    base_cmd = ['-target', 'spirv', '-profile', 'glsl_450', '-capability', 'vk_mem_model', '-fvk-use-entrypoint-name']
    for base_dest, base_build, slang_module, scmd, sfile in iter_entry_point_shaders(sources, build_dir, dest_dir):
        for x in sfile.specializations:
            cmd = list(scmd)
            dest = f'{base_dest}.{x.name}.spv' if x.name else f'{base_dest}.spv'
            if x.variables:
                cmd.insert(-1, f'{base_build}{x.filename_insert}.slang-module')
            cmd += base_cmd + ['-o', dest, '-reflection-json', dest + '.json']
            output_mtime = safe_mtime(dest)
            module_mtime = os.path.getmtime(slang_module)
            needs_build = output_mtime < module_mtime
            if needs_build:
                built_files.append(dest)
            yield Command(needs_build, f'Linking |{os.path.basename(dest)}| ...', cmd)


# GLSL {{{
glsl_version = max(150, GLSL_VERSION)  # slangc fails with glsl_140 https://github.com/shader-slang/slang/issues/11898


def commands_to_compile_to_glsl(sources: dict[str, SlangFile], build_dir: str, dest_dir: str, built_glsl_files: list[str]) -> Iterator[Command]:
    for base_dest, base_build, slang_module, cmd, sfile in iter_entry_point_shaders(sources, build_dir, dest_dir):
        module_mtime = os.path.getmtime(slang_module)
        extra_cmd = ['-line-directive-mode', 'none', '-target', 'glsl', '-profile', f'glsl_{glsl_version}']
        for ep in sfile.entry_points:
            for sp in sfile.specializations:
                v = {Stage.vertex: 'vert', Stage.fragment: 'frag'}[ep.stage]
                c = list(cmd)
                dest = f'{base_dest}{sp.filename_insert}.{v}.glsl' if sp.name else f'{base_dest}.{v}.glsl'
                if sp.variables:
                    c.insert(-1, f'{base_build}{sp.filename_insert}.slang-module')
                c += extra_cmd + ['-entry', ep.name, '-stage', ep.stage.name, '-o', dest]
                output_mtime = safe_mtime(dest)
                needs_build = output_mtime < module_mtime
                if needs_build:
                    built_glsl_files.append(dest)
                yield Command(needs_build, f'Linking |{os.path.basename(slang_module)}| to GLSL {ep.stage.value} shader ...', c)


class GLSLMetadata:
    loose_uniforms: dict[str, str]
    uniform_structs: dict[str, dict[str, str]]
    input_locations: dict[str, int]
    uniform_struct_names: dict[str, str]
    fragment_inputs: dict[int, str]

    def __init__(self) -> None:
        self.loose_uniforms = {}
        self.uniform_structs = {}
        self.input_locations = {}
        self.uniform_struct_names = {}
        self.fragment_inputs = {}

    def merge(self, other: 'GLSLMetadata') -> None:
        self.loose_uniforms.update(other.loose_uniforms)
        self.uniform_structs.update(other.uniform_structs)
        self.uniform_struct_names.update(other.uniform_struct_names)
        self.input_locations.update(other.input_locations)

    def asdict(self) -> dict[str, Any]:
        return {
            'loose_uniforms': self.loose_uniforms,
            'uniform_structs': self.uniform_structs,
            'input_locations': self.input_locations,
            'uniform_struct_names': self.uniform_struct_names,
            'fragment_inputs': self.fragment_inputs,
        }

    @classmethod
    def fromdict(cls, d: dict[str, Any]) -> 'GLSLMetadata':
        ans = GLSLMetadata()
        ans.loose_uniforms = d['loose_uniforms']
        ans.uniform_structs = d['uniform_structs']
        ans.input_locations = d['input_locations']
        ans.uniform_struct_names = d['uniform_struct_names']
        ans.fragment_inputs = d['fragment_inputs']
        return ans


def fixup_opengl_code(glsl_code: str, shader_name: str, existing_metadata: GLSLMetadata | None) -> tuple[str, GLSLMetadata]:
    is_fragment_shader = existing_metadata is None
    shader_name += '.frag.glsl' if is_fragment_shader else '.vert.glsl'
    lines: list[str] = []
    in_uniform_block = False
    in_uniform_block_contents = False
    uniform_block_is_struct = False
    current_uniform_struct_members: dict[str, str] = {}
    current_uniform_struct_name: str = ''
    uniform_blocks = {}
    current_uniform_names: list[str] = []
    uniform_names: dict[str, str] = {}
    uniform_structs = {}
    uniform_struct_names = {}
    input_locations = {}
    named_interface_blocks = set()
    pipeline_io_vars: dict[int, str] = {}
    replacements = {
        'gl_VertexIndex': 'gl_VertexID',
        'gl_BaseVertex': '0',
        'gl_InstanceIndex': 'gl_InstanceID',
        'gl_BaseInstance': '0',
    }
    fragment_inputs = {} if existing_metadata is None else existing_metadata.fragment_inputs.copy()

    def register_pipeline_boundary_io(line: str, next_line: str) -> None:
        m = re.search(r'location = (\d+)', line)
        assert m is not None
        name = next_line.split()[-1].rstrip(';')
        location = int(m.group(1))
        if existing_metadata is None:
            if not next_line.startswith('out '):
                pipeline_io_vars[location] = name
        else:
            with suppress(KeyError):
                replacements[name] = fragment_inputs.pop(location)

    def add_uniform_name(name: str, uniform_names: dict[str, str] = uniform_names) -> str:
        name = name.rstrip(';')
        uniform_name = name.rpartition('_')[0]
        if uniform_name in uniform_names:
            raise KeyError(f'The uniform name {uniform_name} is used with multiple suffixes in {shader_name}')
        if '[' in name:
            name = name.partition('[')[0] + '[0]'
        uniform_names[uniform_name] = name
        return name

    src_lines = glsl_code.splitlines()

    for i, line in enumerate(src_lines):
        next_line = src_lines[i + 1] if i + 1 < len(src_lines) else ''
        if in_uniform_block:
            if in_uniform_block_contents:
                if line.startswith('}'):
                    in_uniform_block = in_uniform_block_contents = False
                    block_name = line.lstrip('}').rstrip(';').strip()
                    if uniform_block_is_struct:
                        uniform_structs[current_uniform_struct_name] = current_uniform_struct_members
                        named_interface_blocks.add(block_name)
                        line = '};'
                    else:
                        uniform_blocks[block_name] = current_uniform_names
                        line = '// ' + line
                    current_uniform_names = []
                else:
                    if uniform_block_is_struct:
                        current_uniform_names.append(add_uniform_name(line.split()[-1], current_uniform_struct_members))
                    else:
                        line = line.strip()
                        current_uniform_names.append(add_uniform_name(line.split()[-1]))
                        line = 'uniform ' + line
            elif line.startswith('{'):  # }}
                if not uniform_block_is_struct:
                    line = '// ' + line
                in_uniform_block_contents = True
                current_uniform_names = []
        else:
            if line.startswith('#version '):
                line = f'#version {GLSL_VERSION}'
                if not is_fragment_shader:
                    line += '\n#extension GL_ARB_explicit_attrib_location : require'
            elif line.startswith('#extension ') or line in ('layout(row_major) buffer;', 'layout(push_constant)'):
                line = '// ' + line
            elif line.startswith('layout(binding ='):
                line = '// ' + line
            elif line.startswith('layout(location =') and (is_fragment_shader or next_line.startswith('out ')):  # ))
                register_pipeline_boundary_io(line, next_line)
                line = '// ' + line
            elif line.startswith('flat layout(location ='):
                register_pipeline_boundary_io(line[len('flat ') :], next_line)
                line = 'flat'
            elif line:  # ))))
                words = line.split()
                if 'uniform' in words and line.startswith('layout('):  # )
                    in_uniform_block = True
                    in_uniform_block_contents = False
                    uniform_block_is_struct = line.startswith('layout(std140')  # )
                    if uniform_block_is_struct:
                        current_uniform_struct_name = words[-1]
                        assert current_uniform_struct_name.startswith('block_')
                        current_uniform_struct_name = current_uniform_struct_name[len('block_') :].rpartition('_')[0]
                        current_uniform_struct_members = {}
                        uniform_struct_names[current_uniform_struct_name] = words[-1]
                    else:
                        line = '// ' + line
                elif words[0] == 'uniform' and len(words) > 2 and words[1].removeprefix('u').removeprefix('i').startswith('sampler'):
                    add_uniform_name(words[2])
                elif not is_fragment_shader and words[0] == 'in':
                    name = words[-1].rstrip(';')
                    input_locations[name.rpartition('_')[0]] = int(lines[-1].split()[-1].rstrip(')'))
        lines.append(line)
    if fragment_inputs:
        raise ValueError(
            f'Could not match vertex outputs to fragment inputs for shader: {shader_name}. Leftover fragment inputs: {", ".join(fragment_inputs.values())}'
        )
    ans = '\n'.join(lines)
    for block_name, names in uniform_blocks.items():
        for u in names:
            u = u.partition('[')[0]  # ]
            replacements[f'{block_name}.{u}'] = u

    for x in named_interface_blocks:
        replacements[f'{x}.'] = ''

    def sub(m: re.Match[str]) -> str:
        return replacements[m.group(1)]

    ans = re.sub(r'\b(' + '|'.join(re.escape(word) for word in replacements) + r')\b', sub, ans)
    # Slang emits `{ }` style struct initializers which aren't valid in GLSL 140;
    # convert them to GLSL constructor call syntax.
    ans = re.sub(
        r'\b([A-Za-z_]\w*)\s+(\w+)\s*=\s*\{([^}]*)\}',
        lambda m: f'{m.group(1)} {m.group(2)} = {m.group(1)}({m.group(3)})',
        ans,
    )
    m = GLSLMetadata()
    m.loose_uniforms = uniform_names
    m.uniform_structs = uniform_structs
    m.input_locations = input_locations
    m.uniform_struct_names = uniform_struct_names
    if is_fragment_shader:
        m.fragment_inputs = pipeline_io_vars
    return ans, m


def shader_name_from_path(path: str) -> str:
    parts = os.path.basename(path).split('.')
    if parts[1] in ('vert', 'frag', 'glsl'):
        return parts[0]
    return '.'.join(parts[:2])


def fixup_opengl_files(paths: Iterable[str]) -> None:
    "Convert the GLSL output of slangc to something that will work with OpenGL 3.1"
    metadata_map: dict[str, GLSLMetadata] = {}
    dest_dir = ''
    for path in sorted(paths):
        dest_dir = os.path.dirname(path)
        with open(path, 'r') as f:
            glsl_code = f.read()
        shader_name = shader_name_from_path(path)
        try:
            fixed, metadata = fixup_opengl_code(glsl_code, shader_name, metadata_map.get(shader_name))
        except Exception:
            os.unlink(path)
            raise
        write_if_changed(path, fixed)
        if shader_name in metadata_map:
            metadata_map[shader_name].merge(metadata)
        else:
            metadata_map[shader_name] = metadata
    for name, gm in metadata_map.items():
        with open(os.path.join(dest_dir, f'{name}.glsl.json'), 'w') as f:
            f.write(json.dumps(gm.asdict()))


def write_if_changed(dest: str, text: str) -> None:
    with suppress(FileNotFoundError), open(dest) as f:
        existing = f.read()
        if existing == text:
            return
    with open(dest, 'w') as f:
        f.write(text)


def glsl_metadata_for_shader(path: str) -> dict[str, Any]:
    with open(path) as f:
        d = json.load(f)
    m = GLSLMetadata.fromdict(d)
    return {
        'loose_uniforms': m.loose_uniforms,
        'uniform_structs': m.uniform_structs,
        'input_locations': m.input_locations,
        'uniform_struct_names': m.uniform_struct_names,
    }


def write_glsl_metadata(dest_dir: str, dest: str = 'glsl-uniforms.json') -> None:
    metadata_map = {}
    for x in glob.glob(os.path.join(dest_dir, '*.glsl.json')):
        shader_name = shader_name_from_path(x)
        if '.' in shader_name:
            continue
        metadata_map[shader_name] = glsl_metadata_for_shader(x)
    write_if_changed(os.path.join(dest_dir, dest), json.dumps(metadata_map, indent=2, sort_keys=True))


@lru_cache(maxsize=1)
def load_glsl_metadata() -> dict[str, dict[str, Any]]:
    with open(os.path.join(shaders_dir, 'glsl-uniforms.json')) as f:
        return dict(json.load(f))


# }}}


# Metal {{{
# The macOS backend renders from MSL, and this is where slang starts supplying
# it. Migration is one (shader, stage) at a time because every pair listed here
# is handed to Apple's Metal compiler during the build: adding a pair that slang
# cannot lower (cell, on the combined-sampler defect of ADR-0026 §2) turns a
# measurable gap into a broken build. A stage absent from this map keeps its
# hand-written function in kitty/*.metal.
#
# border's fragment stays hand-written on purpose: upstream's fragment is a bare
# pass-through of color_premul, while this fork's does the primaries conversion
# and the linear->sRGB encode under function constants that have no slang
# equivalent. Generating it would delete the fork's colour management and import
# no upstream code in exchange. tint, trail and rounded_rect had no such
# epilogue (their former home, effects_shaders.metal, declared no function
# constants at all), so all their stages come from slang and that file is gone.
class VertexOrder(StrEnum):
    ''' Where a generated vertex shader's draw order comes from.

    GL draws every quad as a 4-vertex GL_TRIANGLE_FAN and Metal has no fan, so a
    generated vertex shader may or may not need the fan->strip index buffer, and
    which one is not derivable from the MSL. `fan` means vertex_id is a fan
    position -- whether the shader indexes a constant table baked into itself OR
    an array the C side filled in fan order (trail: cursor_trail.c's corners are
    cyclic because upstream fan-draws them) -- and must go through the remap.
    `client` is reserved for a shader whose vertex_id order is already strip
    order end to end; no shader qualifies today, and the first one that claims
    to must bring pixel evidence (trail claimed it and was refuted: a raw strip
    over its fan-ordered corners missed a wedge and double-blended a seam,
    ADR-0029 §8).

    Declared here rather than detected, because both obvious detectors are
    proxies that fail silently in both directions: a shader can be fan-ordered
    without a table, and a file-scope table need not be a fan-order map.
    '''
    fan = 'fan'
    client = 'client'


class MetalShader(NamedTuple):
    stages: frozenset[Stage]
    vertex_order: VertexOrder


METAL_SHADERS: MappingProxyType[str, MetalShader] = MappingProxyType({
    'border': MetalShader(frozenset({Stage.vertex}), VertexOrder.fan),
    'tint': MetalShader(frozenset({Stage.vertex, Stage.fragment}), VertexOrder.fan),
    'rounded_rect': MetalShader(frozenset({Stage.vertex, Stage.fragment}), VertexOrder.fan),
    # fan by the checkable identity, not by the presence of a LUT (a table need
    # not be a fan map -- see the VertexOrder docstring): the retired hand-written
    # LUTs equal the slang ones permuted by exactly fan_to_strip_indices, for
    # position AND texcoord, so the index remap reproduces the shipped geometry.
    'bgimage': MetalShader(frozenset({Stage.vertex, Stage.fragment}), VertexOrder.fan),
    # trail indexes x_coords[vertex_id]/y_coords[vertex_id], which the C side
    # fills in FAN order (cursor_trail.c's corner_index yields TR,BR,BL,TL --
    # cyclic -- because upstream draws every quad as GL_TRIANGLE_FAN, gl.c).
    # It was first declared client on the belief that the array order was
    # already the draw order; measurement refuted that -- a raw strip over
    # cyclic corners misses the top wedge and double-blends a seam, and the
    # fork's hand-written trail had rendered that way since the MSL port.
    'trail': MetalShader(frozenset({Stage.vertex, Stage.fragment}), VertexOrder.fan),
    # screenshot: blit-common's vertex_pos_map walks the quad perimeter
    # RT,RB,LB,LT -- drawn as a strip that order leaves the top corner region
    # uncovered (verified by tiling the two strip triangles), so it is a fan.
    # NOTE: unlike bgimage, the retired hand-written LUT is NOT the fan table
    # permuted by fan_to_strip_indices -- the two strips split the quad along
    # DIFFERENT diagonals. They render identically because every interpolated
    # attribute (texcoord) is affine across the rectangle, so the diagonal
    # choice cannot change any pixel; the golden thumbnail gate is the proof.
    # The hand-written vertex also baked the GL-bottom-up vs Metal-top-down
    # texture flip into its tex LUT; the generated shader is upstream-faithful,
    # so the C push swaps src_rect's top/bottom instead (metal.m, program 12).
    'screenshot': MetalShader(frozenset({Stage.vertex, Stage.fragment}), VertexOrder.fan),
    # graphics_fork (W3h): the fork-owned wrapper, NOT upstream graphics.slang
    # (whose vertex is non-instanced and cannot express G2 — ADR-0032 §1).
    # Fan, derived: the wrapper embeds blit-common's fan table (RT,RB,LB,LT)
    # and the C side draws it through the fan->strip index remap with
    # instanceCount — the exact composition BORDERS has shipped since W3b
    # (generated fan vertex + per-instance data, ADR-0032 §8 F7).
    'graphics_fork': MetalShader(frozenset({Stage.vertex, Stage.fragment}), VertexOrder.fan),
    # cell_fork (Phase C, ADR-0038): the fork-owned cell wrapper, NOT upstream
    # cell.slang (whose combined samplers trip defect B on the Metal emitter —
    # ADR-0035 §2 — and which carries neither the F1 colored atlas, the P3.5b
    # wide table, nor the colour epilogue). Fan, like every generated vertex:
    # upstream's cell_pos_map order drawn through the fan->strip index remap
    # with instanceCount.
    'cell_fork': MetalShader(frozenset({Stage.vertex, Stage.fragment}), VertexOrder.fan),
    # W3i: FRAGMENT-ONLY (the first) — border's vertex stays generated from
    # upstream border.slang above; this fork wrapper carries only the colour
    # epilogue upstream cannot express. The VertexOrder is inert for a
    # fragment-only entry (the relay consults vertex shaders); fan recorded
    # to match the border vertex it pairs with.
    'border_fork': MetalShader(frozenset({Stage.fragment}), VertexOrder.fan),
})

# Slang names every entry point vertex_main/fragment_main, which would collide
# in the single default.metallib all shaders link into. Rename to the names
# kitty/metal.m already looks up.
def metal_function_name(shader: str, stage: Stage, specialization: str = '') -> str:
    ans = f'{shader}_{stage.value}'
    return f'{ans}_{specialization}' if specialization else ans


COLOR_FORK_MODULE = 'color_fork_generated.slang'


def render_color_fork_module() -> str:
    ''' The fork's slang-side colour seam, rendered from
    kitty/color_transfer.metal.h so NO hand-maintained slang copy of the P3
    matrix exists (W3j round-1 F2: every textual pin over a live copy lost --
    presence is not use; the only winning move is for the copy not to exist).
    Exports ONLY srgb_to_p3: the transfer functions come from upstream's
    linear2srgb module, so a second export here would make every use site
    ambiguous. '''
    base = os.path.dirname(os.path.abspath(__file__))
    header = open(os.path.join(base, '..', 'color_transfer.metal.h')).read()
    rows = []
    for row in ('KITTY_SRGB_TO_P3_R0', 'KITTY_SRGB_TO_P3_R1', 'KITTY_SRGB_TO_P3_R2'):
        m = re.search(rf'#define {row} (.+)', header)
        if m is None:
            raise SystemExit(f'{row} missing from color_transfer.metal.h -- cannot render {COLOR_FORK_MODULE}')
        rows.append(m.group(1).strip())
    return f'''#language slang 2026
// GENERATED by kitty/shaders/slang.py from kitty/color_transfer.metal.h.
// DO NOT EDIT: every build regenerates this file; an unexpected diff here
// means the header changed (commit the regenerated file) or someone edited
// this copy (the build just overwrote it -- the drift cannot ship).
module color_fork_generated;

// Linear sRGB-primaries -> linear Display-P3-primaries; max(0) is the P3
// gamut floor for extended-range input.
public float3 srgb_to_p3(float3 c) {{
    float3 r = float3(
        dot(float3({rows[0]}), c),
        dot(float3({rows[1]}), c),
        dot(float3({rows[2]}), c));
    return max(r, float3(0.0));
}}
'''


def ensure_color_fork_module() -> None:
    ''' Regenerate-and-compare: the committed module is rewritten whenever its
    rendering from the header differs, so a tampered or stale copy becomes an
    uncommitted diff -- loud in git status and fatal to reverify's
    clean-worktree check -- instead of a silently shipping drift. '''
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), COLOR_FORK_MODULE)
    want = render_color_fork_module()
    have = ''
    with suppress(FileNotFoundError), open(path) as f:
        have = f.read()
    if have != want:
        with open(path, 'w') as f:
            f.write(want)
        print(f'{COLOR_FORK_MODULE} regenerated from color_transfer.metal.h; '
              'commit it if the header change was intentional', file=sys.stderr)
    # Absence guard (measured in W3j round 2: a wrapper-local definition
    # legally SHADOWS the imported one -- slang raises no redefinition error
    # -- so the module alone cannot stop a twin). SCOPE, stated exactly
    # (round-2 R2-F1): this is NAME-KEYED on the srgb_to_p3*/linear2srgb*
    # stems -- it closes accidental drift, same-name shadows and name-family
    # twins, and cannot see deliberately new math under an unrelated name or
    # written inline; that residual is out of reach of ANY textual gate and
    # is closed only by golden coverage of the wide-arm variants (bead
    # kitty-zhi). Absence cannot be comment-parked: the pre-filter strips
    # BOTH comment forms before matching.
    base = os.path.dirname(os.path.abspath(__file__))
    for name in ('border_fork.slang', 'cell.slang'):
        text = open(os.path.join(base, name)).read()
        text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
        text = re.sub(r'//[^\n]*', '', text)
        m = re.search(r'float3?\s+(srgb_to_p3\w*|linear2srgb\w*)\s*\(', text)
        if m:
            raise SystemExit(
                f'{name} defines a local {m.group(1)}: colour maths must come from '
                f'the linear2srgb / {COLOR_FORK_MODULE} modules only -- a local '
                'definition silently shadows the imported canonical one')
    # Transfer-equivalence assert (round-2 R2-F3): color_transfer.metal.h is
    # FORK-created -- upstream has no MSL header to keep in sync -- so the
    # header's scalar linear2srgb and upstream's linear2srgb.slang module are
    # two authorities the FORK must hold together. Compare their transfer
    # constants as floats; a divergence is a build failure, not a silent
    # whole-gamma split between hand-written and generated shaders.
    header_text = open(os.path.join(base, '..', 'color_transfer.metal.h')).read()
    module_text = open(os.path.join(base, 'linear2srgb.slang')).read()
    def transfer_constants(text: str, fn_pattern: str, what: str) -> list[float]:
        m2 = re.search(fn_pattern + r'.*?\{(.*?)\n\}', text, re.S)
        if m2 is None:
            raise SystemExit(f'transfer-equivalence assert cannot find {what} '
                             '(a signature reflow? widen the pattern here)')
        # ORDERED, not a multiset (round-3 R3-1: sorted() was permutation-blind
        # -- swapping 12.92 and 1.055 inside the function left the multiset
        # identical while the transfer became a whole-gamma error).
        return [float(tok) for tok in re.findall(r'(\d+\.\d+)f?', m2.group(1))]
    # Both scalar transfer functions (round-3 R3-2 extended coverage from one);
    # the vector forms share the scalars' constants and remain a recorded
    # residual -- a vector-only header edit is golden-visible, unlike these.
    for what, hdr_pat, mod_pat in (
        ('scalar linear2srgb', r'inline float\s+linear2srgb\(float x\)', r'public float\s+linear2srgb\(float x\)'),
        ('scalar srgb2linear', r'inline float\s+srgb2linear\(float x\)', r'public float\s+srgb2linear\(float x\)'),
    ):
        h_consts = transfer_constants(header_text, hdr_pat, f'the header {what} body')
        m_consts = transfer_constants(module_text, mod_pat, f'the module {what} body')
        if h_consts != m_consts:
            raise SystemExit(
                f'color_transfer.metal.h and linear2srgb.slang disagree on {what} '
                f'(ordered compare): header={h_consts} module={m_consts} -- the fork owns '
                'BOTH files and they must stay numerically identical')


def commands_to_compile_to_metal(sources: dict[str, SlangFile], build_dir: str, dest_dir: str) -> Iterator[Command]:
    ''' Emit MSL source, not a .metallib, so the output merges into the single
    kitty/default.metallib that setup.py links from every kitty/*.metal: that
    build compiles each .metal to AIR and links the lot, and a standalone
    .metallib per shader cannot join that link. Apple's compiler still runs --
    it is the AIR step -- so an MSL error slangc would have waved through
    (`-target metal` succeeds on MSL the Metal compiler rejects) still fails
    the build. '''
    if sys.platform != 'darwin':
        return
    for base_dest, base_build, slang_module, cmd, sfile in iter_entry_point_shaders(sources, build_dir, dest_dir):
        shader = METAL_SHADERS.get(os.path.basename(base_dest))
        if shader is None:
            continue
        stages = shader.stages
        module_mtime = os.path.getmtime(slang_module)
        extra_cmd = ['-line-directive-mode', 'none', '-target', 'metal']
        for ep in sfile.entry_points:
            if ep.stage not in stages:
                continue
            for sp in sfile.specializations:
                v = {Stage.vertex: 'vert', Stage.fragment: 'frag'}[ep.stage]
                c = list(cmd)
                dest = f'{base_dest}{sp.filename_insert}.{v}.metal' if sp.name else f'{base_dest}.{v}.metal'
                if sp.variables:
                    c.insert(-1, f'{base_build}{sp.filename_insert}.slang-module')
                c += extra_cmd + ['-entry', ep.name, '-stage', ep.stage.name, '-o', dest]
                yield Command(safe_mtime(dest) < module_mtime,
                              f'Linking |{os.path.basename(slang_module)}| to MSL {ep.stage.value} shader ...', c)


MSL_SCALAR_SIZES = MappingProxyType({
    'bool': 1, 'char': 1, 'uchar': 1, 'short': 2, 'ushort': 2, 'int': 4, 'uint': 4, 'float': 4, 'half': 2,
})


def msl_type_size_align(decl: str) -> tuple[int, int]:
    ' Size and alignment of an MSL type as slang spells it in its output. '
    decl = decl.strip()
    if m := re.fullmatch(r'array<(.+),\s*int\((\d+)\)>', decl):
        size, align = msl_type_size_align(m.group(1))
        return size * int(m.group(2)), align
    if m := re.fullmatch(r'([a-z]+)([234])?', decl):
        if (base := MSL_SCALAR_SIZES.get(m.group(1))) is not None:
            n = int(m.group(2) or 1)
            # MSL rounds a 3-component vector up to 4 components for both.
            width = base * (4 if n == 3 else n)
            return width, width
    raise ValueError(f'Cannot size the MSL type {decl!r} from a generated shader')


class MSLMember(NamedTuple):
    type_name: str
    name: str
    attribute: str  # the [[...]] qualifier, without the brackets


def parse_msl_structs(msl: str) -> dict[str, list[MSLMember]]:
    ans: dict[str, list[MSLMember]] = {}
    for m in re.finditer(r'\bstruct\s+(\w+)\s*\{([^}]*)\}', msl):
        members = []
        for line in m.group(2).splitlines():
            # `array<uint, int(9)> colors_0;` / `float4 rect_0 [[attribute(0)]];`
            if d := re.fullmatch(r'(.+?)\s+(\w+)\s*(?:\[\[(.+?)\]\])?\s*;', line.strip()):
                members.append(MSLMember(d.group(1), d.group(2), d.group(3) or ''))
        ans[m.group(1)] = members
    return ans


def msl_struct_size(members: Iterable[MSLMember]) -> int:
    size, max_align = 0, 1
    for member in members:
        msize, malign = msl_type_size_align(member.type_name)
        max_align = max(max_align, malign)
        size = ((size + malign - 1) // malign) * malign + msize
    return ((size + max_align - 1) // max_align) * max_align


def entry_point_declaration(msl: str, stage: Stage) -> tuple[str, str]:
    ' The generated entry point\'s name and its parameter list. '
    m = re.search(rf'\[\[{stage.value}\]\]\s+\S+\s+(\w+)\s*\(', msl)
    if m is None:
        raise ValueError(f'The generated MSL has no [[{stage.value}]] entry point')
    depth = 0
    for i in range(m.end() - 1, len(msl)):
        if msl[i] == '(':
            depth += 1
        elif msl[i] == ')':
            depth -= 1
            if not depth:
                return m.group(1), msl[m.end():i]
    raise ValueError('The generated MSL entry point has an unterminated parameter list')


class MetalBindings(NamedTuple):
    prefix: str
    buffers: dict[str, tuple[int, int]]  # name -> (index, byte size of the struct)
    attributes: dict[str, int]           # name -> attribute index
    textures: dict[str, int]             # name -> [[texture(n)]] index
    samplers: dict[str, int]             # name -> [[sampler(n)]] index
    blocks: dict[str, int]               # MSL struct type name -> computed byte size
    # W3h step 0: the publication contract below needs the shader identity and
    # stage STRUCTURED, not re-parsed out of the prefix -- a specialized prefix
    # like GRAPHICS_VERTEX_ALPHA_MASK defeats both the endswith('_VERTEX')
    # filter and the rsplit('_', 1) shader lookup (measured in the W3g review:
    # specialized vertices silently left the contract).
    shader: str = ''
    stage: 'Stage' = Stage.vertex
    specialization: str = ''


def strip_slang_suffix(name: str) -> str:
    ' Slang uniquifies every identifier with a _N suffix; the C side wants the source spelling. '
    return re.sub(r'_\d+$', '', name)


def add_binding(bindings: dict[str, Any], name: str, value: Any, prefix: str) -> None:
    ' Stripping slang\'s _N suffix can collide; a silently dropped binding is the one thing this header exists to prevent. '
    if name in bindings:
        raise ValueError(f'Two {prefix} bindings collapse onto the name {name!r} once slang\'s numeric suffix is stripped')
    bindings[name] = value


def parse_metal_bindings(msl: str, stage: Stage, prefix: str) -> MetalBindings:
    structs = parse_msl_structs(msl)
    _, signature = entry_point_declaration(msl, stage)
    buffers: dict[str, Any] = {}
    blocks: dict[str, int] = {}
    matches = list(re.finditer(r'(\w+)\s+(?:constant|device)\s*\*\s*(\w+)\s*\[\[buffer\((\d+)\)\]\]', signature))
    # Counted against the raw occurrences, not tested for emptiness: an
    # all-or-nothing guard misses the partial case where slangc changes its
    # spelling for one parameter kind and the regex silently skips just that one.
    if len(matches) != signature.count('[[buffer('):
        raise ValueError(
            f'{prefix}: the entry signature declares {signature.count("[[buffer(")} buffer parameters '
            f'but only {len(matches)} were recognised -- slangc changed its spelling')
    for m in matches:
        size = msl_struct_size(structs[m.group(1)])
        blocks[m.group(1)] = size
        add_binding(buffers, strip_slang_suffix(m.group(2)), (int(m.group(3)), size), prefix)
    attributes: dict[str, Any] = {}
    if m := re.search(r'(\w+)\s+\w+\s*\[\[stage_in\]\]', signature):
        for member in structs.get(m.group(1), ()):
            if a := re.fullmatch(r'attribute\((\d+)\)', member.attribute):
                add_binding(attributes, strip_slang_suffix(member.name), int(a.group(1)), prefix)

    def indexed_params(kind: str) -> dict[str, Any]:
        ' Texture/sampler entry parameters, with the same count guard the buffers have. '
        found: dict[str, Any] = {}
        matches = list(re.finditer(r'(\w+)\s+\[\[' + kind + r'\((\d+)\)\]\]', signature))
        declared = signature.count('[[' + kind + '(')
        if len(matches) != declared:
            raise ValueError(
                f'{prefix}: the entry signature declares {declared} {kind} parameters '
                f'but only {len(matches)} were recognised -- slangc changed its spelling')
        for m in matches:
            # slang names the split pair image_texture_N / image_sampler_N from
            # the source's combined `Sampler2D image`; strip the role suffix so
            # both defines carry the source spelling.
            name = strip_slang_suffix(m.group(1))
            name = name.removesuffix('_texture').removesuffix('_sampler')
            add_binding(found, name, int(m.group(2)), prefix)
        return found

    return MetalBindings(prefix, buffers, attributes, indexed_params('texture'), indexed_params('sampler'), blocks, '', stage, '')


def internalize_msl_helpers(msl: str, entry: str) -> str:
    ''' Give every non-entry function internal linkage.

    Each generated shader is its own translation unit in the metallib link, and
    slang names its inner wrapper after the entry point and keeps the source
    spelling of anything imported from utils.slang. So two generated shaders
    both define `vertex_main_0`, `if_one_then_0` and friends, and linking them
    together dies with `LLVM ERROR: multiple symbols`. MSL is C++, so `static`
    is the fix and no call site changes.

    A definition is a line at column 0 that contains `(` whose next line is a bare
    `{`. That excludes slang's file-scope array constants, which contain `(` from
    `int(N)` but are written on one line — measured across every file slangc
    lowers, and there the two classes never overlap.

    Only a MISS is loud: a signature wrapped onto two lines leaves a helper
    exported, and the collision comes back as a duplicate-symbol link error.
    Every mis-fire measured so far is SILENT, so do not extend this rule assuming
    the compiler will catch a mistake. `static` on a `constant` declaration
    compiles and does nothing (namespace-scope `constant` already has internal
    linkage); `static` on a struct is a warning only, and setup.py compiles MSL
    without -Werror, so warnings never fail the build.

    Note also that -Wno-unused-function became load-bearing here: internalizing a
    helper turns "external, unused, no warning" into "static, unused, warns".
    '''
    lines = msl.splitlines()
    for i, line in enumerate(lines):
        if not line or line[0].isspace() or line.startswith('[[') or line.startswith('static '):
            continue
        if '(' not in line or i + 1 >= len(lines) or lines[i + 1].strip() != '{':
            continue
        # Redundant with the [[ test only for as long as slang keeps the stage
        # marker on the same line as the signature; this is what keeps the entry
        # point exported if it ever splits them.
        if re.match(rf'.*\b{re.escape(entry)}\s*\(', line):
            continue
        lines[i] = 'static ' + line
    return '\n'.join(lines) + ('\n' if msl.endswith('\n') else '')


def fixup_metal_files(dest_dir: str, dest: str = 'kitty/metal-bindings.h') -> None:
    ''' Rename the generated entry points to the names metal.m binds by, and
    publish the bindings slangc chose. The indices are an output of the
    compiler, not a contract, so pinning them in a generated header turns a
    slangc that re-assigns a buffer into a changed #define (and a failing
    _Static_assert when a struct also resized) instead of a shader quietly
    reading the wrong bytes. '''
    if sys.platform != 'darwin':
        return
    all_bindings: list[MetalBindings] = []
    for path in sorted(glob.glob(os.path.join(dest_dir, '*.metal'))):
        parts = os.path.basename(path).split('.')
        shader, stage = parts[0], {'vert': Stage.vertex, 'frag': Stage.fragment}[parts[-2]]
        specialization = '.'.join(parts[1:-2])
        with open(path) as f:
            msl = f.read()
        fn = metal_function_name(shader, stage, specialization)
        msl = re.sub(rf'\b{entry_point_declaration(msl, stage)[0]}\b', fn, msl)
        msl = internalize_msl_helpers(msl, fn)
        bindings = parse_metal_bindings(msl, stage, fn.upper())._replace(shader=shader, specialization=specialization)
        # The BUFSZ defines pin the C side against slang.py's MODEL of MSL
        # layout; a wrong model would leave C and the #define agreeing and both
        # wrong. Embedding the computed sizes as static_asserts makes the Metal
        # compiler validate the model itself on every build. Strip any previously
        # embedded asserts first: the file is mutated in place and mtime-gated,
        # so a model change without a .slang change would otherwise append a
        # second, contradictory assert beside the stale one and blame the
        # now-correct model.
        msl = re.sub(r'^static_assert\(sizeof\(\w+\) == \d+, "slang\.py mis-sized[^"]*"\);\n', '', msl, flags=re.M)
        for type_name, size in sorted(bindings.blocks.items()):
            assert_line = (f'static_assert(sizeof({type_name}) == {size}, '
                           f'"slang.py mis-sized this block; fix msl_type_size_align");')
            if assert_line not in msl:
                msl = msl.rstrip('\n') + '\n' + assert_line + '\n'
        write_if_changed(path, msl)
        all_bindings.append(bindings)
    lines = ['// generated by slang.py DO NOT EDIT', '#pragma once']
    for b in all_bindings:
        lines.append('')
        for name, (index, size) in sorted(b.buffers.items()):
            lines.append(f'#define {b.prefix}_BUF_{name} {index}')
            lines.append(f'#define {b.prefix}_BUFSZ_{name} {size}u')
        for name, index in sorted(b.attributes.items()):
            lines.append(f'#define {b.prefix}_ATTR_{name} {index}')
        for name, index in sorted(b.textures.items()):
            lines.append(f'#define {b.prefix}_TEX_{name} {index}')
        for name, index in sorted(b.samplers.items()):
            lines.append(f'#define {b.prefix}_SAMP_{name} {index}')
        if b.attributes:
            # Vertex attributes share the buffer argument table with the
            # [[buffer(n)]] parameters, so the instance data has to go
            # somewhere slang did not already claim.
            lines.append(f'#define {b.prefix}_ATTR_BUFFER {max((i for i, _ in b.buffers.values()), default=-1) + 1}')
    # metal.m decides per program whether to draw through the fan->strip index
    # buffer, but the answer is a property of the shader, not of the program id
    # (which lives in shaders.c's enum and not in any header). So the decision is
    # declared once in METAL_SHADERS and published here, rather than restated as
    # prose in an assert message: metal.m relays the value instead of holding an
    # opinion. Every way the set can change fails the build -- a removal or a
    # swap takes a #define away, KITTY_SLANG_VERTEX_SHADERS (a count of
    # DISTINCT shaders, matching metal.m's program-mapping concern) catches a
    # new shader, and _SPECIALIZATIONS (emitted per stage once a shader has
    # more than its default variant) catches a variant set changing size.
    # cell_fork: metal.m binds all 52 variants through ONE canonical define
    # set (CELL_FORK_VERTEX_* / CELL_FORK_FRAGMENT_*), selecting only the
    # entry NAME per variant. That is sound only while slangc assigns every
    # variant the same binding table, so the uniformity is asserted here and
    # a divergence fails the build instead of binding one variant's buffers
    # to another's indices.
    cf_bindings = [b for b in all_bindings if b.shader == 'cell_fork']
    for cf_stage in (Stage.vertex, Stage.fragment):
        group = [b for b in cf_bindings if b.stage is cf_stage]
        if not group:
            continue
        # Coherence, not identity: RENDER_MODE variants legitimately DROP
        # resources (bg-only has no textures, fg-only no vertex params) and
        # binding at an index a variant does not declare is legal in Metal.
        # What must hold for a single canonical table: a name never moves
        # between indices across variants, and no index serves two names.
        union_bufs: dict[str, tuple[int, int]] = {}
        union_attrs: dict[str, int] = {}
        union_tex: dict[str, int] = {}
        union_samp: dict[str, int] = {}
        for b in group:
            for dst, src in ((union_bufs, b.buffers), (union_attrs, b.attributes), (union_tex, b.textures), (union_samp, b.samplers)):
                for name, val in src.items():
                    if dst.setdefault(name, val) != val:
                        raise SystemExit(f'cell_fork {cf_stage.name}: {name!r} binds at both '
                                         f'{dst[name]} and {val} across variants; per-variant binding needed')
        # No two distinct names may share an index within a kind (buffers,
        # textures, samplers, attributes all have their own [[n]] namespaces).
        for kind, m in (('buffer', {n: i for n, (i, _) in union_bufs.items()}),
                        ('texture', union_tex), ('sampler', union_samp), ('attribute', union_attrs)):
            idxs = list(m.values())
            if len(set(idxs)) != len(idxs):
                raise SystemExit(f'cell_fork {cf_stage.name}: two {kind} names share one index across variants')
        canon = f'CELL_FORK_{cf_stage.name.upper()}'
        lines.append('')
        lines.append(f'// canonical union (coherent across all {len(group)} {cf_stage.name} variants; '
                     'variants may omit entries, never move them)')
        for name, (index, size) in sorted(union_bufs.items()):
            lines.append(f'#define {canon}_BUF_{name} {index}')
            lines.append(f'#define {canon}_BUFSZ_{name} {size}u')
        for name, index in sorted(union_attrs.items()):
            lines.append(f'#define {canon}_ATTR_{name} {index}')
        for name, index in sorted(union_tex.items()):
            lines.append(f'#define {canon}_TEX_{name} {index}')
        for name, index in sorted(union_samp.items()):
            lines.append(f'#define {canon}_SAMP_{name} {index}')
        if union_attrs:
            lines.append(f'#define {canon}_ATTR_BUFFER {max((i for i, _ in union_bufs.values()), default=-1) + 1}')
        if cf_stage is Stage.vertex:
            cf_order = METAL_SHADERS['cell_fork'].vertex_order
            lines.append(f'#define {canon}_IS_GENERATED 1')
            lines.append(f'#define {canon}_ORDER_FAN {1 if cf_order is VertexOrder.fan else 0}')
    # W3h step 0: the old endswith('_VERTEX') prefix filter silently excluded
    # specialized vertex entries from all three guarantees (W3g review, F5).
    vertex_bindings = [b for b in all_bindings if b.stage is Stage.vertex]
    lines.append('')
    # Presence and value are deliberately separate symbols. _IS_GENERATED exists
    # to be #ifdef'd (metal.m's removal guards); _ORDER_FAN is always defined,
    # as 0 or 1, and must be read with #if or as an expression. The moment a
    # client-ordered shader lands, its _ORDER_FAN is defined-and-zero, so an
    # #ifdef on it would silently answer "fan" for a shader declared otherwise.
    lines.append('// _ORDER_FAN is always defined (0 or 1): test with #if, never #ifdef.')
    for b in vertex_bindings:
        order = METAL_SHADERS[b.shader].vertex_order
        lines.append(f'#define {b.prefix}_IS_GENERATED 1')
        lines.append(f'#define {b.prefix}_ORDER_FAN {1 if order is VertexOrder.fan else 0}')
    lines.append(f'#define KITTY_SLANG_VERTEX_SHADERS {len({b.shader for b in vertex_bindings})}')
    variant_counts: dict[tuple[str, Stage], int] = {}
    for b in all_bindings:
        key = (b.shader, b.stage)
        variant_counts[key] = variant_counts.get(key, 0) + 1
    for (shader_name, stage_v), n in sorted(variant_counts.items()):
        if n > 1:
            lines.append(f'#define {shader_name.upper()}_{stage_v.name.upper()}_SPECIALIZATIONS {n}')
    write_if_changed(dest, '\n'.join(lines) + '\n')
# }}}


ParallelRun = Callable[[Iterable[tuple[bool, str, list[str]]]], None]


def create_specialisations(sources: dict[str, SlangFile], build_dir: str) -> Iterator[Command]:
    for _, base_build, _, _, sfile in iter_entry_point_shaders(sources, build_dir, build_dir):
        if sfile.entry_points and sfile.specializations:
            for sp in sfile.specializations:
                if not sp.variables:
                    continue
                dest = f'{base_build}{sp.filename_insert}.slang'
                payload = existing = ''
                if sp.variables:
                    lines = []
                    for key, val in sp.variables.items():
                        declaration = sfile.specializable_variables[key].rpartition('=')[0]
                        if not declaration:
                            declaration = sfile.specializable_variables[key].rstrip(';')
                        declaration = declaration.replace('extern ', 'export ', 1)
                        lines.append(f'{declaration} = {val};')
                    payload = '\n'.join(lines)
                with suppress(FileNotFoundError), open(dest) as f:
                    existing = f.read()
                if needs_build := payload != existing:
                    if payload:
                        with open(dest, 'w') as fw:
                            fw.write(payload)
                    else:
                        os.remove(dest)
                yield Command(needs_build, f'Compiling specialisation |{os.path.basename(dest)}| ...', list(slangc()) + [dest, '-o', dest + '-module'])


def compile_builtin_shaders(build_dir: str, dest_dir: str, parallel_run: ParallelRun) -> None:
    ensure_cache_dir(build_dir)
    ensure_cache_dir(dest_dir)
    # Before the source walk: the committed generated colour module must match
    # its rendering from color_transfer.metal.h (see ensure_color_fork_module).
    ensure_color_fork_module()
    src_dir = os.path.abspath('kitty/shaders')
    source_tree = get_ordered_sources_in_tree(src_dir)
    serialize_source_metadata(source_tree, dest_dir)

    # Compile IR layer by layer so each module's dependencies finish before it starts
    for layer in topological_layers(source_tree):
        layer_sources = {k: source_tree[k] for k in layer}
        parallel_run(commands_to_compile_dir_to_ir(layer_sources, src_dir, build_dir))
    # Create the specializations
    parallel_run(create_specialisations(source_tree, build_dir))
    # Now Vulkan shaders
    built_spirv_files: list[str] = []
    spirv_commands = commands_to_compile_to_spirv(source_tree, build_dir, dest_dir, built_spirv_files)
    # Now glsl files
    built_glsl_files: list[str] = []
    glsl_commands = commands_to_compile_to_glsl(source_tree, build_dir, dest_dir, built_glsl_files)
    # Now the MSL the Metal backend renders from
    metal_commands = commands_to_compile_to_metal(source_tree, build_dir, dest_dir)
    # Now run all commands
    parallel_run(chain(spirv_commands, glsl_commands, metal_commands))
    fixup_opengl_files(built_glsl_files)
    if shutil.which('glslangValidator'):
        from kitty.shaders.validate_shaders import validation_command_for_file

        parallel_run((True, f'Validating |{os.path.basename(x)}| ...', validation_command_for_file(x)) for x in built_glsl_files)
    write_glsl_metadata(dest_dir)
    fixup_metal_files(dest_dir)


def main() -> None:
    if not shutil.which(slangc()[0]):
        raise SystemExit(f'The shader slang compiler ({slangc()[0]}) not in PATH: {os.environ.get("PATH")}')
    setup = runpy.run_path('setup.py')
    verbose = sys.argv[-3] == 'verbose'
    Command = setup['Command']
    parallel_run = setup['parallel_run']
    emphasis = setup['emphasis']

    def prun(cmds: Iterable[tuple[bool, str, list[str]]]) -> None:
        cmds = tuple(cmds)
        needed = []
        for needs_build, desc, cmd in cmds:
            if needs_build:
                desc = re.sub(r'\|(.+?)\|', lambda m: emphasis(m.group(1)), desc)
                needed.append(Command(desc, cmd, lambda: True))
        parallel_run(needed, verbose)

    compile_builtin_shaders(sys.argv[-2], sys.argv[-1], prun)


class SlangFailed(Exception):
    def __init__(self, fname: str, cp: subprocess.CompletedProcess):
        args = cp.args
        stderr = cp.stderr
        if isinstance(args, str):
            cmd = args
        else:
            cmd = shlex.join(args)
        super().__init__(f'Failed to compile {fname} with command line:\n{cmd}\nand stderr:\n{stderr.decode()}')


def key(*items: str | bytes) -> bytes:
    h = hashlib.md5(usedforsecurity=False)
    for data in items:
        if isinstance(data, str):
            data = data.encode()
        h.update(data)
    return h.hexdigest().encode()


@lru_cache(maxsize=64)
def custom_shader(name: str = '', pipeline_dir: str = '') -> tuple[str, str, bytes, bytes]:
    import_dir = ''
    if not name:
        src = get_custom_shader_src('types')
        return name, import_dir, src, key(src)

    found_path = ''
    src = b''

    if pipeline_dir:
        candidate = os.path.join(pipeline_dir, f'{name}.slang')
        try:
            with open(candidate, 'rb') as f:
                src = f.read()
            found_path = os.path.abspath(candidate)
            import_dir = os.path.dirname(found_path)
        except FileNotFoundError:
            pass

    if not found_path:
        config_path = resolve_custom_file(f'{name}.slang')
        config_shader_dir = os.path.dirname(os.path.abspath(config_path))
        if not pipeline_dir or os.path.normpath(os.path.abspath(pipeline_dir)) != os.path.normpath(config_shader_dir):
            try:
                with open(config_path, 'rb') as f:
                    src = f.read()
                found_path = os.path.abspath(config_path)
                import_dir = os.path.dirname(found_path)
            except FileNotFoundError:
                pass

    if not found_path:
        src = get_custom_shader_src(name)
        return name, import_dir, src, key(src)

    return found_path, import_dir, src, key(src)


@lru_cache(maxsize=64)
def pipeline_definition(name: str) -> tuple[tuple[str, ...], str]:
    if os.path.isabs(name):
        pipeline_path = name if name.endswith('.pipeline') else name + '.pipeline'
        with open(pipeline_path, 'rb') as f:
            src = f.read()
        return tuple(src.decode().splitlines()), os.path.dirname(os.path.abspath(pipeline_path))

    filename = name if name.endswith('.pipeline') else f'{name}.pipeline'
    path = resolve_custom_file(f'shaders/{filename}')
    try:
        with open(path, 'rb') as f:
            src = f.read()
        pipeline_dir = os.path.dirname(os.path.abspath(path))
    except FileNotFoundError:
        base_name = name[: -len('.pipeline')] if name.endswith('.pipeline') else name
        src = get_custom_pipeline_src(base_name)
        pipeline_dir = ''
    return tuple(src.decode().splitlines()), pipeline_dir


class NamedTexture(StrEnum):
    a = auto()
    b = auto()
    persist = auto()
    default = auto()


class Slot(StrEnum):
    end = auto()


def is_valid_named_texture(x: str) -> TypeGuard[NamedTexture]:
    return x in NamedTexture._value2member_map_


def is_valid_slot(x: str) -> TypeGuard[Slot]:
    return x in Slot._value2member_map_


VALID_VAR_TYPES: frozenset[str] = frozenset({'uint', 'int', 'float', 'double', 'bool'})
SHADER_ANIMATION_EVENTS: frozenset[str] = frozenset(
    {
        'pointer-left-button-press',
        'os-window-focus-in',
        'os-window-focus-out',
        'window-focus-in',
        'window-focus-out',
        'tab-change',
        'bell-in-window',
        'user-activity',
        'user-idle',
        'cursor-trail-move',
        'cursor-trail-stop',
    }
)


def is_valid_animation_event(name: str) -> bool:
    return name in SHADER_ANIMATION_EVENTS


def parse_animation_events(raw: str) -> tuple[str, ...]:
    events = raw.split('|')
    for e in events:
        if not is_valid_animation_event(e):
            raise ValueError(f'{e!r} is not a valid animation event name; valid names: {", ".join(sorted(SHADER_ANIMATION_EVENTS))}')
    return tuple(events)


def parse_css_animation_curve(spec: str) -> EasingFunction:
    _NAMED: dict[str, tuple[str, str]] = {
        'ease-in-out': ('cubic-bezier', '0.42, 0, 0.58, 1'),
        'linear': ('cubic-bezier', '0, 0, 1, 1'),
        'ease': ('cubic-bezier', '0.25, 0.1, 0.25, 1'),
        'ease-out': ('cubic-bezier', '0, 0, 0.58, 1'),
        'ease-in': ('cubic-bezier', '0.42, 0, 1, 1'),
        'step-start': ('steps', '1, start'),
        'step-end': ('steps', '1, end'),
    }

    def make(func_name: str, params: str) -> EasingFunction:
        if func_name == 'cubic-bezier':
            return EasingFunction.cubic_bezier(params)
        if func_name == 'linear':
            return EasingFunction.linear(params)
        if func_name == 'steps':
            return EasingFunction.steps(params)
        raise ValueError(f'{func_name!r} is not a valid easing function type')

    spec = spec.strip()
    if spec in _NAMED:
        return make(*_NAMED[spec])
    m = re.match(r'^([-a-zA-Z]+)\(([^)]+)\)$', spec)
    if m:
        return make(m.group(1), m.group(2))
    raise ValueError(f'{spec!r} is not a recognized CSS animation curve')


@run_once
def identifiers_pat() -> re.Pattern[str]:
    return re.compile(r'^[A-Za-z_][A-Za-z0-9_]*$')


def parse_var_directive(parts: list[str]) -> tuple[str, str, str]:
    if len(parts) < 4:
        raise ValueError('var directive requires: var <type> <name> [=] <value>')
    var_type = parts[1]
    q = var_type[:-1] if var_type and var_type[-1] in '234' else var_type
    if q not in VALID_VAR_TYPES:
        raise ValueError(f'var type {var_type!r} must be one of: {", ".join(sorted(VALID_VAR_TYPES))}')
    var_name = parts[2]
    if not identifiers_pat().match(var_name):
        raise ValueError(f'var name {var_name!r} is not a valid identifier')
    if parts[3] == '=':
        if len(parts) < 5:
            raise ValueError('var directive missing value after =')
        value = ' '.join(parts[4:])
    else:
        value = ' '.join(parts[3:])
    return var_type, var_name, value.rstrip(';')


def apply_pipeline_specializations(src: bytes, merged_vars: dict[str, tuple[str, str]]) -> bytes:
    for var_name, (var_type, value) in merged_vars.items():
        # Replace: static const <any_type> <name> = <default>; → static const <type> <name> = <value>;
        pattern = rf'(?m)^(\s*)static\s+const\s+{re.escape(var_type)}\s+{re.escape(var_name)}\s*=.+'
        src = re.sub(pattern.encode(), rf'\g<1>static const {var_type} {var_name} = {value};'.encode(), src)
    return src


class Group(TypedDict):
    pipeline_dir: str  # directory used to resolve shader names for this group
    viewport_pos: tuple[float, float]
    viewport_size: tuple[float, float]
    output_texture: NamedTexture
    shaders: tuple[str, ...]
    vars: dict[str, tuple[str, str]]
    animation_start: tuple[str, ...]  # empty = no animation
    animation_curve: EasingFunction  # parsed easing curve
    animation_step: int  # nanoseconds between animation samples
    animation_end_events: tuple[str, ...]  # events that stop the animation
    animation_end_duration: int  # nanoseconds; 0 = no time limit, negative = use cursor_stop_blinking_after
    attached: bool  # if True, this group is always active when the previous group is active


class Pipeline(TypedDict):
    slot: Slot
    textures: tuple[NamedTexture, ...]
    groups: tuple[Group, ...]
    vars: dict[str, tuple[str, str]]
    pipeline_dir: str


def parse_pipeline_definition(lines: Iterable[str], pipeline_name: str, pipeline_dir: str = '') -> Pipeline:
    slot = Slot.end
    textures: tuple[NamedTexture, ...] = ()
    groups: list[Group] = []
    current_group: Group | None = None
    pipeline_vars: dict[str, tuple[str, str]] = {}

    def unit_float(x: str) -> float:
        return max(0, min(float(x), 1))

    def commit_group() -> None:
        nonlocal current_group
        if current_group is not None:
            groups.append(current_group)
            current_group = None

    def init_group(*shaders: str) -> Group:
        return {
            'pipeline_dir': pipeline_dir,
            'viewport_pos': (0, 0),
            'viewport_size': (1, 1),
            'output_texture': NamedTexture.default,
            'shaders': shaders,
            'vars': {},
            'animation_start': (),
            'animation_curve': EasingFunction(),
            'animation_step': ANIMATION_SAMPLE_WAIT,
            'animation_end_events': (),
            'animation_end_duration': -1,
            'attached': False,
        }

    for line in lines:
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        parts = line.split()
        if current_group is None:
            match parts[0]:
                case 'slot':
                    if not is_valid_slot(parts[1]):
                        raise ValueError(f'slot {parts[1]} is not valid')
                    slot = parts[1]
                case 'textures':
                    textures = tuple(map(NamedTexture, parts[1:]))
                case 'startgroup':
                    commit_group()
                    current_group = init_group()
                case 'var':
                    var_type, var_name, value = parse_var_directive(parts)
                    pipeline_vars[var_name] = (var_type, value)
                case _:
                    raise ValueError(f'Unknown key {parts[0]}')
        else:
            match parts[0]:
                case 'viewport_pos':
                    current_group['viewport_pos'] = unit_float(parts[1]), unit_float(parts[1 if len(parts) < 3 else 2])
                case 'viewport_size':
                    current_group['viewport_size'] = unit_float(parts[1]), unit_float(parts[1 if len(parts) < 3 else 2])
                case 'output_texture':
                    if not is_valid_named_texture(parts[1]):
                        raise ValueError(f'output_texture {parts[1]} does not appear in textures')
                    current_group['output_texture'] = parts[1]
                case 'shaders':
                    current_group['shaders'] += tuple(parts[1:])
                case 'var':
                    var_type, var_name, value = parse_var_directive(parts)
                    current_group['vars'][var_name] = (var_type, value)
                case 'animation_start':
                    val = ''.join(parts[1:]) if len(parts) > 1 else 'none'
                    current_group['animation_start'] = () if val == 'none' else parse_animation_events(val)
                case 'animation_curve':
                    if len(parts) < 2:
                        raise ValueError('animation_curve requires a CSS curve name')
                    current_group['animation_curve'] = parse_css_animation_curve(' '.join(parts[1:]))
                case 'animation_step':
                    if len(parts) < 2:
                        raise ValueError('animation_step requires a millisecond value')
                    current_group['animation_step'] = int(parts[1]) * 1_000_000
                case 'animation_stop':
                    val = ''.join(parts[1:]) if len(parts) > 1 else 'never'
                    if val == 'never':
                        current_group['animation_end_events'] = ()
                        current_group['animation_end_duration'] = 0
                    else:
                        end_events: list[str] = []
                        end_duration: int = 0
                        for token in val.split('|'):
                            try:
                                end_duration = int(token) * 1_000_000
                            except ValueError:
                                end_events.extend(parse_animation_events(token))
                        current_group['animation_end_events'] = tuple(end_events)
                        current_group['animation_end_duration'] = end_duration
                case 'attach':
                    current_group['attached'] = True
                case 'endgroup':
                    commit_group()
                case _:
                    raise ValueError(f'Unknown key {parts[0]}')
    if current_group is not None:
        raise ValueError('Unclosed group present')
    groups = groups or [init_group(pipeline_name)]
    if len(groups) > MAX_CUSTOM_SHADER_GROUPS:
        raise ValueError(f'Pipeline {pipeline_name!r} has {len(groups)} groups but the maximum is {MAX_CUSTOM_SHADER_GROUPS}')
    if groups[0]['attached']:
        raise ValueError('The first group in a pipeline cannot use attach (no previous group to attach to)')
    if groups[-1]['output_texture'] is not NamedTexture.default:
        raise ValueError('The final group cannot output to a named texture')
    if groups[-1]['viewport_pos'] != (0, 0) or groups[-1]['viewport_size'] != (1, 1):
        raise ValueError('The final group must not specify a viewport')

    return {'slot': slot, 'textures': textures, 'groups': tuple(groups), 'vars': pipeline_vars, 'pipeline_dir': pipeline_dir}


@lru_cache(maxsize=32)
def parse_pipeline(name: str) -> Pipeline:
    lines, pipeline_dir = pipeline_definition(name)
    return parse_pipeline_definition(lines, name, pipeline_dir)


def merge_pipelines(pipelines: list[Pipeline]) -> Pipeline:
    if len(pipelines) == 1:
        return pipelines[0]
    slot = pipelines[0]['slot']
    for p in pipelines[1:]:
        if p['slot'] != slot:
            raise ValueError(f'Cannot chain pipelines with different slots: {slot!r} vs {p["slot"]!r}')
    seen_textures: set[NamedTexture] = set()
    merged_textures: list[NamedTexture] = []
    for p in pipelines:
        for t in p['textures']:
            if t not in seen_textures:
                seen_textures.add(t)
                merged_textures.append(t)
    all_groups: list[Group] = []
    for p in pipelines:
        all_groups.extend(p['groups'])
    if len(all_groups) > MAX_CUSTOM_SHADER_GROUPS:
        raise ValueError(f'Chained pipelines have {len(all_groups)} groups combined but the maximum is {MAX_CUSTOM_SHADER_GROUPS}')
    if all_groups[-1]['output_texture'] is not NamedTexture.default:
        raise ValueError('The final group of the last pipeline cannot output to a named texture')
    if all_groups[-1]['viewport_pos'] != (0, 0) or all_groups[-1]['viewport_size'] != (1, 1):
        raise ValueError('The final group of the last pipeline must not specify a viewport')
    merged_vars: dict[str, tuple[str, str]] = {}
    for p in pipelines:
        merged_vars.update(p['vars'])
    return {
        'slot': slot,
        'textures': tuple(merged_textures),
        'groups': tuple(all_groups),
        'vars': merged_vars,
        'pipeline_dir': pipelines[0]['pipeline_dir'],
    }


def build_custom_shader_pipeline_ir(pipeline: Pipeline, cache_dir: str, invocation_tracker: set[tuple[str, ...]]) -> tuple[tuple[str, ...], str]:
    slot = pipeline['slot']
    slot_module_name = f'{slot.replace("-", "_")}'
    cache_dir = os.path.join(cache_dir, 'c')
    ensure_cache_dir(cache_dir)
    slot_dir = os.path.join(cache_dir, slot)
    libdir = os.path.join(cache_dir, 'lib')
    import_dirs = [slot_dir, libdir]
    bc = list(slangc()) + ['-warnings-as-errors', 'all', '-lang', 'slang', '-I', libdir]
    _, _, ct_shader, ct_key = custom_shader()
    os.makedirs(libdir, exist_ok=True)
    os.makedirs(slot_dir, exist_ok=True)
    cache_ok = False
    mtime = 0
    types_rebuilt = False

    def entry_point(g_idx: int, s_idx: int) -> str:
        return f'fragment_main_{g_idx}_{s_idx}'

    j = partial(os.path.join, libdir)
    with suppress(FileNotFoundError), open(j('ct.key'), 'rb') as f:
        cache_ok = f.read() == ct_key
        mtime = max(mtime, os.fstat(f.fileno()).st_mtime_ns)
    if not cache_ok:
        cmd = bc + ['-module-name', 'kitty_custom_shader_types', '-o', j('kitty-custom-shader-types.slang-module'), '--', '-']
        invocation_tracker.add(tuple(cmd))
        cp = subprocess.run(cmd, input=ct_shader, capture_output=True)
        if cp.returncode != 0:
            raise SlangFailed('custom-types.slang', cp)
        ct_key_path = j('ct.key')
        with open(ct_key_path, 'wb') as f:
            f.write(ct_key)
        mtime = max(mtime, os.stat(ct_key_path).st_mtime_ns)
        types_rebuilt = True

    slot_key_parts: list[str | bytes] = [json.dumps(pipeline, sort_keys=True), get_custom_shader_src('pipeline')]

    for group in pipeline['groups']:
        for name in group['shaders']:
            _path, import_dir, _src, content_key = custom_shader(name, group['pipeline_dir'])
            if import_dir and import_dir not in import_dirs:
                import_dirs.append(import_dir)
            slot_key_parts.append(content_key)
    slot_key = key(*slot_key_parts)
    slot_key_file = os.path.join(slot_dir, 'inputs.key')
    ans = os.path.join(slot_dir, f'{slot}.slang-module')
    if not types_rebuilt:
        with suppress(FileNotFoundError), open(slot_key_file, 'rb') as f:
            if f.read() == slot_key:
                return tuple(import_dirs), ans

    j = partial(os.path.join, slot_dir)
    imports = []
    for g_idx, group in enumerate(pipeline['groups']):
        merged_vars = pipeline['vars'].copy()
        merged_vars.update(group['vars'])
        for s_idx, name in enumerate(group['shaders']):
            _path, import_dir, src, _content_key = custom_shader(name, group['pipeline_dir'])
            if import_dir and import_dir not in import_dirs:
                import_dirs.append(import_dir)
            src = apply_pipeline_specializations(src, merged_vars)
            modname = f'm_{g_idx}_{s_idx}'
            imports.append(modname)
            module_file = j(f'{modname}.slang-module')
            inc = ['-I', import_dir] if import_dir else []
            cmd = bc + inc + [f'-Dfragment_main={entry_point(g_idx, s_idx)}', '-module-name', modname, '-o', module_file, '--', '-']
            invocation_tracker.add(tuple(cmd))
            cp = subprocess.run(cmd, input=src, capture_output=True)
            if cp.returncode != 0:
                raise SlangFailed(name, cp)
            mtime = max(mtime, os.stat(module_file).st_mtime_ns)
    # Generate group-branched PIPELINE code.
    # sRGB conversion is emitted in every group's branch, gated on the convert_to_srgb
    # parameter. The C caller sets it to true only for the last active group so that
    # inactive animated groups do not cause an extra blit draw call.
    pipeline_parts: list[str] = []
    for g_idx, group in enumerate(pipeline['groups']):
        calls = '\n'.join(f'        color = {entry_point(g_idx, i)}(color, t, csd);' for i in range(len(group['shaders'])))
        calls += '\n        if (convert_to_srgb) color = float4(linear2srgb(color.rgb), color.a);'
        prefix = '} else ' if g_idx else ''
        pipeline_parts.append(f'    {prefix}if (group == {g_idx}) {{\n{calls}')
    pipeline_parts.append('    }')
    pipeline_code = '\n'.join(pipeline_parts)

    mod_src = get_custom_shader_src('pipeline').decode()
    mod_src = mod_src.replace('// IMPORTS', '\n'.join(f'import {imp};' for imp in imports), 1)
    mod_src = mod_src.replace('// PIPELINE', pipeline_code, 1)
    # subprocess.run(['bat', '-P', '-l', 'cpp'], input=mod_src.encode())

    with tempfile.TemporaryDirectory() as tdir:
        for x in import_dirs:
            inc.extend(('-I', x))
        cmd = bc + inc + ['-module-name', slot_module_name, '-o', ans, '--', '-']
        invocation_tracker.add(tuple(cmd))
        cp = subprocess.run(cmd, cwd=tdir, capture_output=True, input=mod_src.encode())
        if cp.returncode != 0:
            raise SlangFailed(f'{slot}.slang', cp)

    with open(slot_key_file, 'wb') as f:
        f.write(slot_key)
    return tuple(import_dirs), ans


def module_wrapper_for_slot(slot: str) -> bytes:
    return """
#language slang 2026
import MODULE;

struct VertexOutput {
    float2 texcoord : TEXCOORD;
    float4 position : SV_Position;
};

[shader("vertex")]
VertexOutput vmain_wrap(uint vertex_id : SV_VertexID) {
    float4 c = pipeline_vertex_main(vertex_id);
    return {float2(c[0], c[1]), float4(c[2], c[3], 0, 1)};
}

[shader("fragment")]
float4 fmain_wrap(
    float2 texcoord : TEXCOORD,
    uniform int group,
    uniform float4 viewport,
    uniform float animation_progress,
    uniform bool convert_to_srgb
) : SV_Target {
    return pipeline_fragment_main(texcoord, group, viewport, animation_progress, convert_to_srgb);
}
        """.replace('MODULE', slot.replace('-', '_')).encode()


def build_custom_shader_pipeline_glsl(
    pipeline: Pipeline, cache_dir: str = '', invocation_tracker: set[tuple[str, ...]] | None = None
) -> tuple[str, str, dict[str, Any]]:
    import kitty.constants as kc

    cache_dir = os.path.join(cache_dir or kc.cache_dir(), 'shaders')
    os.makedirs(cache_dir, exist_ok=True)
    if invocation_tracker is None:
        invocation_tracker = set()

    with lock_with_file(
        os.path.join(cache_dir, 'lock'),
    ):
        import_dirs, slang_module_path = build_custom_shader_pipeline_ir(pipeline, cache_dir, invocation_tracker)
        glsl_dir = os.path.join(os.path.dirname(os.path.dirname(slang_module_path)), 'glsl')
        os.makedirs(glsl_dir, exist_ok=True)
        module_mtime = safe_mtime(slang_module_path)
        slot = pipeline['slot']
        vertex = os.path.join(glsl_dir, f'{slot}.vert.glsl')
        fragment = os.path.join(glsl_dir, f'{slot}.frag.glsl')
        metadata = os.path.join(glsl_dir, f'{slot}.glsl.json')
        if module_mtime > safe_mtime(metadata):
            inc = []
            for x in import_dirs:
                inc.extend(('-I', x))
            cmd = (
                list(slangc())
                + inc
                + [
                    '-warnings-as-errors',
                    'all',
                    '-line-directive-mode',
                    'none',
                    '-lang',
                    'slang',
                    '-target',
                    'glsl',
                    '-profile',
                    f'glsl_{glsl_version}',
                ]
            )
            vcmd = cmd + ['-stage', 'vertex', '-entry', 'vmain_wrap', '-o', vertex, '--', '-']
            fcmd = cmd + ['-stage', 'fragment', '-entry', 'fmain_wrap', '-o', fragment, '--', '-']
            src = module_wrapper_for_slot(slot)
            invocation_tracker.add(tuple(vcmd))
            invocation_tracker.add(tuple(fcmd))
            v = subprocess.Popen(vcmd, stderr=subprocess.PIPE, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL)
            f = subprocess.Popen(fcmd, stderr=subprocess.PIPE, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL)
            assert v.stdin is not None and f.stdin is not None
            assert v.stderr is not None and f.stderr is not None
            v.stdin.write(src), v.stdin.close()
            f.stdin.write(src), f.stdin.close()
            try:
                if (rc := v.wait()) != 0:
                    raise SlangFailed(f'{slot}.vert.glsl', subprocess.CompletedProcess(vcmd, rc, stderr=v.stderr.read()))
                if (rc := f.wait()) != 0:
                    raise SlangFailed(f'{slot}.frag.glsl', subprocess.CompletedProcess(fcmd, rc, stderr=f.stderr.read()))
            finally:
                v.stderr.close()
                f.stderr.close()
            fixup_opengl_files((fragment, vertex))
        with open(vertex) as vf, open(fragment) as ff:
            m = glsl_metadata_for_shader(metadata)
            m['pipeline'] = pipeline
            return vf.read(), ff.read(), m


def clear_caches() -> None:
    custom_shader.cache_clear()
    pipeline_definition.cache_clear()
    parse_pipeline.cache_clear()
    load_shader_programs.force_recompile_of_custom_shaders = True


def test_slang_build() -> None:

    if shutil.which(slangc()[0]) is None:
        raise AssertionError(f'The shader slang compiler ({slangc()[0]}) not in PATH: {os.environ.get("PATH")}')
    q = os.path.join(shaders_dir, 'graphics.spv')
    if not os.path.isfile(q):
        raise AssertionError(f'The compiled graphics shader {q} does not exist')
    if not get_shader_src('graphics'):
        raise AssertionError('Could not load graphics.slang shader source')
    src = b"""
#language slang 2026
[shader("vertex")]
float4 main(uint vertex_id : SV_VertexID) : SV_Position { return float4(vertex_id, 1, 0, 1); }
"""
    cp = subprocess.run(list(slangc()) + '-lang slang -entry main -stage vertex -target glsl -o /dev/stdout -- -'.split(), input=src, capture_output=True)
    if cp.returncode != 0:
        raise AssertionError(f'Test compile of shader to GLSL failed with returncode: {cp.returncode} and stderr: {cp.stderr.decode()}')


if __name__ == '__main__':
    main()
