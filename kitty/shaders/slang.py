#!/usr/bin/env python
# License: GPLv3 Copyright: 2026, Kovid Goyal <kovid at kovidgoyal.net>

import glob
import hashlib
import json
import os
import re
import runpy
import shutil
import sys
import time
from collections import OrderedDict
from contextlib import suppress
from enum import StrEnum
from functools import lru_cache
from itertools import chain, product
from pathlib import Path
from types import MappingProxyType
from typing import Any, Callable, Iterable, Iterator, Literal, NamedTuple

from kitty.constants import read_kitty_resource, shaders_dir, slangc
from kitty.fast_data_types import (
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
    DECORATION,
    DECORATION_MASK,
    DIM,
    GLSL_VERSION,
    GRAPHICS_ALPHA_MASK_PROGRAM,
    GRAPHICS_PREMULT_PROGRAM,
    GRAPHICS_PROGRAM,
    MARK,
    MARK_MASK,
    REVERSE,
    ROUNDED_RECT_PROGRAM,
    SCREENSHOT_PROGRAM,
    STRIKETHROUGH,
    TINT_PROGRAM,
    TRAIL_PROGRAM,
    compile_program,
    get_options,
    init_cell_program,
)
from kitty.options.types import Options, defaults


@lru_cache(maxsize=64)
def get_shader_src(name: str) -> str:
    return read_kitty_resource(f'{name}.slang', 'kitty.shaders').decode()


@lru_cache(maxsize=2)
def self_mtime() -> float:
    with suppress(Exception):
        return os.path.getmtime(__file__)
    return 0


@lru_cache(maxsize=2)
def slangc_version() -> str:
    import subprocess
    return subprocess.check_output(list(slangc()) + ['-version'], stderr=subprocess.STDOUT).decode().strip()


def is_dir_slangc_version_ok(path: str) -> bool:
    with suppress(OSError), open(os.path.join(path, 'slangc.version')) as f:
        return f.read().strip() == slangc_version()
    return False


def ensure_cache_dir(path: str) -> None:
    os.makedirs(path, exist_ok=True)
    # slang IR is version dependent and the compiler often crashes when loading .slang-module from another version
    if not is_dir_slangc_version_ok(path):
        shutil.rmtree(path)
        os.makedirs(path)
        with open(os.path.join(path, 'slangc.version'), 'w') as f:
            f.write(slangc_version())


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


def cell_variant(opts: Options = defaults, only_fg: bool = False, only_bg: bool = False) -> dict[str, str]:
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
    return {
        'FG_OVERRIDE_ALGO': algo,
        'TEXT_NEW_GAMMA': 'false' if opts.text_composition_strategy == 'legacy' else 'true',
        'ONLY_FOREGROUND': 'true' if only_fg else 'false',
        'ONLY_BACKGROUND': 'true' if only_bg else 'false',
    }


@lru_cache(maxsize=2)
def cell_variations() -> tuple[MappingProxyType[str, str], ...]:
    variations = {'FG_OVERRIDE_ALGO': ('0', '1', '2')}
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
            bool(opts.text_fg_override_threshold[0]) != bool(self.text_fg_override_threshold[0]) or
            opts.text_fg_override_threshold[1] != self.text_fg_override_threshold[1] or
            (opts.text_composition_strategy == 'legacy') != self.text_old_gamma
        )

    def recompile_if_needed(self) -> None:
        if self.needs_recompile:
            self(allow_recompile=True)

    def __call__(self, allow_recompile: bool = False) -> None:
        default_cell_variant = cell_variant()
        opts = self.get_options()
        self.text_old_gamma = opts.text_composition_strategy == 'legacy'
        self.text_fg_override_threshold = opts.text_fg_override_threshold
        for prog, (only_fg, only_bg) in {
            CELL_PROGRAM: (False, False), CELL_FG_PROGRAM: (True, False), CELL_BG_PROGRAM: (False, True),
        }.items():
            v = cell_variant(opts, only_fg=only_fg, only_bg=only_bg)
            vert, frag = glsl_shaders('cell', variant_name(v, default_cell_variant))
            compile_program(prog, (vert,), (frag,), allow_recompile)
        for prog, vname in {
            GRAPHICS_PROGRAM: '', GRAPHICS_ALPHA_MASK_PROGRAM: 'alpha_mask',
            GRAPHICS_PREMULT_PROGRAM: 'premult',
        }.items():
            vert, frag = glsl_shaders('graphics', vname)
            compile_program(prog, (vert,), (frag,), allow_recompile)
        for name, prog in {
            'bgimage': BGIMAGE_PROGRAM,
            'tint': TINT_PROGRAM,
            'trail': TRAIL_PROGRAM,
            'blit': BLIT_PROGRAM,
            'screenshot': SCREENSHOT_PROGRAM,
            'rounded_rect': ROUNDED_RECT_PROGRAM,
            'border': BORDERS_PROGRAM,
        }.items():
            vert, frag = glsl_shaders(name)
            compile_program(prog, (vert,), (frag,), allow_recompile)
        init_cell_program()


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
        ' Return a dict useable for serialization to JSON '
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
            s['path'], s['text'], frozenset(s['imports']),
            frozenset(EntryPoint.fromdict(x) for x in s['entry_points']),
            s['module'], MappingProxyType(s['specializable_variables']), frozenset(s['disable_warnings']))

    @property
    def should_compile_to_ir(self) -> bool:
        return bool(self.module or self.entry_points)

    @property
    def defines(self) -> MappingProxyType[str, str]:
        ans = {}
        match os.path.basename(self.path):
            case 'cell.slang':
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
                yield s('premult', texture_is_not_premultiplied='true')
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
                    break
            found_entry_point = ''
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
            path, src_code, frozenset(imports), frozenset(entry_points), module,
            MappingProxyType(specializable_variables), frozenset(disable_warnings))


@lru_cache(4096)
def parse_slang_file(path: str) -> SlangFile:
    with open(path) as f:
        text = f.read()
    return parse_slang_text(text, path)


def build_import_graph(dirpath: str) -> dict[str, SlangFile]:
    graph: dict[str, SlangFile] = {}
    for root, _, files in os.walk(os.path.abspath(dirpath)):
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
        ans = 0.
        for deppath in read_deps_file(path):
            mtime = os.path.getmtime(deppath)
            ans = max(mtime, ans)
        return max(ans, self_mtime())
    return future()


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
            yield Command(needs_build, f'Compiling |{name}.slang| ...', cmdbase + defines + [
                '-I', output_dirpath, '-I', src_dir, '-depfile', deps_file,
                '-target', 'none', '-o', slang_module, '--', sfile.path,
            ])


def iter_entry_point_shaders(
    sources: dict[str, SlangFile], build_dir: str, dest_dir: str
) -> Iterator[tuple[str, str, str, list[str], SlangFile]]:
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


def commands_to_compile_to_spirv(
    sources: dict[str, SlangFile], build_dir: str, dest_dir: str, built_files: list[str]
) -> Iterator[Command]:
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
def commands_to_compile_to_glsl(
    sources: dict[str, SlangFile], build_dir: str, dest_dir: str, built_glsl_files: list[str]
) -> Iterator[Command]:
    glsl_version = max(150, GLSL_VERSION)  # slangc fails with glsl_140 https://github.com/shader-slang/slang/issues/11898
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

    def __init__(self) -> None:
        self.loose_uniforms = {}
        self.uniform_structs = {}
        self.input_locations = {}
        self.uniform_struct_names = {}

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
            'uniform_struct_names': self.uniform_struct_names}


def fixup_opengl_code(glsl_code: str, path: str) -> tuple[str, GLSLMetadata]:
    is_fragment_shader = 'frag' in os.path.basename(path).split('.')
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

    def add_uniform_name(name: str, uniform_names: dict[str, str] = uniform_names) -> str:
        name = name.rstrip(';')
        uniform_name = name.rpartition('_')[0]
        if uniform_name in uniform_names:
            raise KeyError(f'The uniform name {uniform_name} is used with multiple suffixes in {path}')
        if '[' in name:
             name = name.partition('[')[0] + '[0]'
        uniform_names[uniform_name] = name
        return name
    src_lines = glsl_code.splitlines()

    for i, line in enumerate(src_lines):
        next_line = src_lines[i+1] if i+1 < len(src_lines) else ''
        if in_uniform_block:
            if in_uniform_block_contents:
                if line.startswith('}'):
                    in_uniform_block = in_uniform_block_contents = False
                    block_name = line.lstrip('}').rstrip(';').strip()
                    if uniform_block_is_struct:
                        uniform_structs[current_uniform_struct_name] = current_uniform_struct_members
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
            elif line.startswith('layout(location =') and (is_fragment_shader or next_line.startswith('out ')):
                line = '// ' + line
            elif line.startswith('flat layout(location ='):
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
                        current_uniform_struct_name = current_uniform_struct_name[len('block_'):].rpartition('_')[0]
                        current_uniform_struct_members = {}
                        uniform_struct_names[current_uniform_struct_name] = words[-1]
                    else:
                        line = '// ' + line
                elif words[0] == 'uniform' and len(words) > 2 and words[1].startswith('sampler'):
                    add_uniform_name(words[2])
                elif not is_fragment_shader and words[0] == 'in':
                    name = words[-1].rstrip(';')
                    input_locations[name.rpartition('_')[0]] = int(lines[-1].split()[-1].rstrip(')'))
        lines.append(line)
    ans = '\n'.join(lines)
    for block_name, names in uniform_blocks.items():
        for u in names:
            u = u.partition('[')[0]  # ]
            ans = ans.replace(f'{block_name}.{u}', u)
    ans = ans.replace('gl_VertexIndex', 'gl_VertexID')
    ans = ans.replace('gl_BaseVertex', '0')
    ans = ans.replace('gl_InstanceIndex', 'gl_InstanceID')
    ans = ans.replace('gl_BaseInstance', '0')
    m = GLSLMetadata()
    m.loose_uniforms = uniform_names
    m.uniform_structs = uniform_structs
    m.input_locations = input_locations
    m.uniform_struct_names = uniform_struct_names
    return ans, m


def fixup_opengl_files(paths: Iterable[str], metadata_map: dict[str, GLSLMetadata]) -> None:
    ' Convert the GLSL output of slangc to something that will work with OpenGL 3.1 '
    for path in paths:
        with open(path, 'r') as f:
            glsl_code = f.read()
        try:
            fixed, metadata = fixup_opengl_code(glsl_code, path)
        except Exception:
            os.unlink(path)
            raise
        parts = os.path.basename(path).split('.')
        write_if_changed(path, fixed)
        if len(parts) == 3:
            name = parts[0]
            if name in metadata_map:
                metadata_map[name].merge(metadata)
            else:
                metadata_map[name] = metadata


def write_if_changed(dest: str, text: str) -> None:
    with suppress(FileNotFoundError), open(dest) as f:
        existing = f.read()
        if existing == text:
            return
    with open(dest, 'w') as f:
        f.write(text)


def write_glsl_header(metadata_map: dict[str, GLSLMetadata], dest: str = 'kitty/glsl-uniforms.h') -> None:
    lines = ['// generated by slang.py DO NOT EDIT', '#include "gl.h"', '']
    a = lines.append
    for name in sorted(metadata_map):
        m = metadata_map[name]
        struct_name = name.capitalize() + 'Uniforms'
        a('')
        a(f'typedef struct {struct_name} {{')  # }}
        for u in sorted(m.loose_uniforms):
            a(f'    int {u};')
        if m.input_locations:
            a('    // Vertex Input locations')
            for u in sorted(m.input_locations):
                a(f'    int {u};')
        if m.uniform_structs:
            a('    // Uniform block locations')
            for u in sorted(m.uniform_structs):
                a(f'    UniformBlock {u};')
                for v in sorted(m.uniform_structs[u]):
                    vv = m.uniform_structs[u][v]
                    if ']' in vv:
                        a(f'    ArrayInformation {v};')

        a(f'}} {struct_name};')
        a('')
        a(f'static inline void get_uniform_locations_{name}(int program, {struct_name} *ans) {{')  # }}
        for u in sorted(m.loose_uniforms):
            a(f'    ans->{u} = get_uniform_location(program, "{m.loose_uniforms[u]}");')
        for u in sorted(m.input_locations):
            a(f'    ans->{u} = {m.input_locations[u]};')
        for u in sorted(m.uniform_structs):
            a(f'    ans->{u}.index = block_index(program, "{m.uniform_struct_names[u]}");')
            a(f'    ans->{u}.size = block_size(program, ans->{u}.index);')
            block_name = m.uniform_struct_names[u]
            for v in sorted(m.uniform_structs[u]):
                vv = m.uniform_structs[u][v]
                if ']' in vv:
                    a(f'    ans->{v} = get_uniform_array_information(program, "{block_name}.{vv}");')
        a('}')
    write_if_changed(dest, '\n'.join(lines))
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


def canonical_epilogue_functions() -> str:
    ''' The ONE authority for the fork epilogue's colour maths in slang: the
    transfer scalars are this template (mirroring color_transfer.metal.h's
    scalar triple, f-suffixed so codegen stays byte-identical to the retired
    hand-written MSL), and the P3 matrix rows are read from the header's
    KITTY_SRGB_TO_P3_R* defines at check time. Every fork wrapper must carry
    this block VERBATIM (checked by check_fork_epilogue_pin below), so the
    wrapper copy is a checked rendering, not a second source of truth. '''
    base = os.path.dirname(os.path.abspath(__file__))
    header = open(os.path.join(base, '..', 'color_transfer.metal.h')).read()
    rows = []
    for row in ('KITTY_SRGB_TO_P3_R0', 'KITTY_SRGB_TO_P3_R1', 'KITTY_SRGB_TO_P3_R2'):
        m = re.search(rf'#define {row} (.+)', header)
        if m is None:
            raise SystemExit(f'{row} missing from color_transfer.metal.h -- the fork epilogue pin cannot run')
        rows.append(m.group(1).strip())
    return f'''float linear2srgb(float x) {{
    float lower = 12.92f * x;
    float upper = 1.055f * pow(x, 1.0f / 2.4f) - 0.055f;
    return lerp(lower, upper, step(0.0031308f, x));
}}

float3 srgb_to_p3(float3 c) {{
    float3 r = float3(
        dot(float3({rows[0]}), c),
        dot(float3({rows[1]}), c),
        dot(float3({rows[2]}), c));
    return max(r, float3(0.0));
}}'''


FORK_EPILOGUE_WRAPPERS = ('border_fork.slang',)


def check_fork_epilogue_pin() -> None:
    ''' W3i F1 closed row permutation with an ordered-row compare; W3i round-2
    F9 showed the CLASS is wider -- input swizzle (c -> c.bgr), permuted
    assembly destinations, a deleted max(0) gamut floor all passed, and no
    golden can see any of them (the matrix runs only in the never-captured
    wide-arm variants; capture pins the BGRA8 offscreen). Per that review's
    charter ("widening the regex is the third iteration of the same textual
    approach and will lose the next round"), this is NOT a fragment matcher:
    the whole canonical function block is RENDERED from the header
    (canonical_epilogue_functions) and each fork wrapper must contain it
    verbatim, modulo comments and whitespace. Any textual deviation -- the
    three F9 vectors included -- fails the build and prints the expected
    block; a shadowing second definition is a slang redefinition error. '''
    def normalize(text: str) -> str:
        return re.sub(r'\s+', ' ', re.sub(r'//[^\n]*', '', text)).strip()
    canonical = canonical_epilogue_functions()
    want = normalize(canonical)
    base = os.path.dirname(os.path.abspath(__file__))
    for name in FORK_EPILOGUE_WRAPPERS:
        wrapper = open(os.path.join(base, name)).read()
        if want not in normalize(wrapper):
            raise SystemExit(
                f'{name} has drifted from the canonical epilogue block (rendered from '
                f'color_transfer.metal.h). Replace its linear2srgb/srgb_to_p3 with exactly:\n\n{canonical}')


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
    check_fork_epilogue_pin()
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


def copy_files_preserving_structure(source_dir: str, dest_dir: str, extension: str) -> None:
    '''
    Copies all files with a specific extension from a source directory
    to a destination directory while preserving the subdirectory structure.
    '''
    source = Path(source_dir)
    destination = Path(dest_dir)
    if not extension.startswith('.'):
        extension = f".{extension}"
    # Recursively find all matching files
    for file_path in source.rglob(f"*{extension}"):
        if file_path.is_file():
            # Calculate relative path to maintain folder hierarchy
            relative_path = file_path.relative_to(source)
            target_path = destination / relative_path
            target_path.parent.mkdir(parents=True, exist_ok=True)
            # Copy file while preserving original metadata
            shutil.copy2(file_path, target_path)


def create_specialisations(sources: dict[str, SlangFile], build_dir: str) -> Iterator[Command]:
    for _, base_build, _, _, sfile in iter_entry_point_shaders(sources, build_dir, build_dir):
        if sfile.entry_points and sfile.specializations:
            for sp in sfile.specializations:
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
                yield Command(needs_build, f'Compiling specialisation |{os.path.basename(dest)}| ...',
                              list(slangc()) + [dest, '-o', dest + '-module'])


def compile_builtin_shaders(build_dir: str, dest_dir: str, parallel_run: ParallelRun) -> None:
    ensure_cache_dir(build_dir)
    ensure_cache_dir(dest_dir)
    src_dir = os.path.abspath('kitty/shaders')
    source_tree = get_ordered_sources_in_tree(src_dir)
    serialize_source_metadata(source_tree, dest_dir)

    # First ensure all IR is generated
    parallel_run(commands_to_compile_dir_to_ir(source_tree, src_dir, build_dir))
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
    metadata_map = {}
    fixup_opengl_files(glob.glob(os.path.join(dest_dir, '*.glsl')), metadata_map=metadata_map)
    if shutil.which('glslangValidator'):
        from kitty.shaders.validate_shaders import validation_command_for_file
        parallel_run((True, f'Validating |{os.path.basename(x)}| ...', validation_command_for_file(x)) for x in built_glsl_files)
    write_glsl_header(metadata_map)
    fixup_metal_files(dest_dir)


def main() -> None:
    if not shutil.which(slangc()[0]):
        raise SystemExit(f'The shader slang compiler ({slangc()[0]}) not in PATH: {os.environ.get("PATH")}')
    setup = runpy.run_path('setup.py')
    Command = setup['Command']
    parallel_run = setup['parallel_run']
    emphasis = setup['emphasis']
    def prun(cmds: Iterable[tuple[bool, str, list[str]]]) -> None:
        needed = []
        for (needs_build, desc, cmd) in cmds:
            if needs_build:
                desc = re.sub(r'\|(.+?)\|', lambda m: emphasis(m.group(1)), desc)
                needed.append(Command(desc, cmd, lambda: True))
        parallel_run(needed)
    compile_builtin_shaders(sys.argv[-2], sys.argv[-1], prun)


def test_slang_build() -> None:
    import subprocess
    if shutil.which(slangc()[0]) is None:
        raise AssertionError(f'The shader slang compiler ({slangc()[0]}) not in PATH: {os.environ.get("PATH")}')
    q = os.path.join(shaders_dir, 'graphics.spv')
    if not os.path.isfile(q):
        raise AssertionError(f'The compiled graphics shader {q} does not exist')
    if not get_shader_src('graphics'):
        raise AssertionError('Could not load graphics.slang shader source')
    src = b'''
#language slang 2026
[shader("vertex")]
float4 main(uint vertex_id : SV_VertexID) : SV_Position { return float4(vertex_id, 1, 0, 1); }
'''
    cp = subprocess.run(list(slangc()) + '-lang slang -entry main -stage vertex -target glsl -o /dev/stdout -- -'.split(),
                        input=src, capture_output=True)
    if cp.returncode != 0:
        raise AssertionError(f'Test compile of shader to GLSL failed with returncode: {cp.returncode} and stderr: {cp.stderr.decode()}')


if __name__ == '__main__':
    main()
