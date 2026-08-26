#!/usr/bin/env python
# License: GPL v3 Copyright: 2017, Kovid Goyal <kovid at kovidgoyal.net>

import array
import os
import tempfile
import unittest
from collections.abc import Iterable
from functools import lru_cache, partial
from itertools import repeat
from math import ceil

from kitty.constants import is_macos, read_kitty_resource
from kitty.fast_data_types import (
    DECAWM,
    ParsedFontFeature,
    current_fonts,
    get_fallback_font,
    set_allow_use_of_box_fonts,
    set_ligature_name_cache_enabled,
    sprite_idx_to_pos,
    sprite_map_set_layout,
    sprite_map_set_limits,
    test_render_line,
    test_sprite_position_increment,
    wcwidth,
)
from kitty.fonts import family_name_to_key
from kitty.fonts.common import FontSpec, all_fonts_map, face_from_descriptor, get_font_files, get_named_style, spec_for_face
from kitty.fonts.render import coalesce_symbol_maps, create_face, render_string, setup_for_testing, shape_string
from kitty.options.types import Options

from .base import BaseTest, draw_multicell


def parse_font_spec(spec):
    return FontSpec.from_setting(spec)


@lru_cache(maxsize=64)
def testing_font_data(name):
    return read_kitty_resource(name, __name__.rpartition('.')[0])


class Selection(BaseTest):
    def test_font_selection(self):
        self.set_options({'font_features': {'LiberationMono': (ParsedFontFeature('-dlig'),)}})
        opts = Options()
        fonts_map = all_fonts_map(True)
        names = set(fonts_map['family_map']) | set(fonts_map['variable_map'])
        del fonts_map

        def s(family: str, *expected: str, alternate=None) -> None:
            opts.font_family = parse_font_spec(family)
            ff = get_font_files(opts)
            actual = tuple(face_from_descriptor(ff[x]).postscript_name() for x in ('medium', 'bold', 'italic', 'bi'))  # type: ignore
            del ff
            for x in actual:
                if '/' in x:  # Old FreeType failed to generate postscript name for a variable font probably
                    return
            with self.subTest(spec=family):
                try:
                    self.ae(expected, actual)
                except AssertionError:
                    if alternate:
                        self.ae(alternate, actual)
                    else:
                        raise

        def both(family: str, *expected: str, alternate=None) -> None:
            for family in (family, f'family="{family}"'):
                s(family, *expected, alternate=alternate)

        def has(family, allow_missing_in_ci=False):
            ans = family_name_to_key(family) in names
            if self.is_ci and not allow_missing_in_ci and not ans:
                raise AssertionError(f'The family: {family} is not available')
            return ans

        def t(family, psprefix, bold='Bold', italic='Italic', bi='', reg='Regular', allow_missing_in_ci=False, alternate=None):
            if has(family, allow_missing_in_ci=allow_missing_in_ci):
                bi = bi or bold + italic
                if reg:
                    reg = '-' + reg
                both(family, f'{psprefix}{reg}', f'{psprefix}-{bold}', f'{psprefix}-{italic}', f'{psprefix}-{bi}', alternate=alternate)

        t('Source Code Pro', 'SourceCodePro', 'Semibold', 'It')
        t('sourcecodeVf', 'SourceCodeVF', 'Semibold')

        # The Arch ttf-fira-code package excludes the variable fonts for some reason
        t(
            'fira code',
            'FiraCodeRoman',
            'SemiBold',
            'Regular',
            'SemiBold',
            alternate=('FiraCode-Regular', 'FiraCode-SemiBold', 'FiraCode-Retina', 'FiraCode-SemiBold'),
        )
        t('hack', 'Hack')
        # some ubuntu systems (such as the build VM) have only the regular and
        # bold faces of DejaVu Sans Mono installed.
        # t('DejaVu Sans Mono', 'DejaVuSansMono', reg='', italic='Oblique')
        t('ubuntu mono', 'UbuntuMono')
        t('liberation mono', 'LiberationMono', reg='')
        t('ibm plex mono', 'IBMPlexMono', 'SmBld', reg='')
        t('iosevka fixed', 'Iosevka-Fixed', 'Semibold', reg='', bi='Semibold-Italic', allow_missing_in_ci=True)
        t('iosevka term', 'Iosevka-Term', 'Semibold', reg='', bi='Semibold-Italic', allow_missing_in_ci=True)
        t('fantasque sans mono', 'FantasqueSansMono')
        t('jetbrains mono', 'JetBrainsMono', 'SemiBold')
        t('consolas', 'Consolas', reg='', allow_missing_in_ci=True)
        if has('cascadia code'):
            if is_macos:
                both('cascadia code', 'CascadiaCode-Regular', 'CascadiaCode-Regular_SemiBold', 'CascadiaCode-Italic', 'CascadiaCode-Italic_SemiBold-Italic')
            else:
                both('cascadia code', 'CascadiaCodeRoman-Regular', 'CascadiaCodeRoman-SemiBold', 'CascadiaCode-Italic', 'CascadiaCode-SemiBoldItalic')
        if has('cascadia mono'):
            if is_macos:
                both('cascadia mono', 'CascadiaMono-Regular', 'CascadiaMono-Regular_SemiBold', 'CascadiaMono-Italic', 'CascadiaMono-Italic_SemiBold-Italic')
            else:
                both('cascadia mono', 'CascadiaMonoRoman-Regular', 'CascadiaMonoRoman-SemiBold', 'CascadiaMono-Italic', 'CascadiaMono-SemiBoldItalic')
        if has('operator mono', allow_missing_in_ci=True):
            both('operator mono', 'OperatorMono-Medium', 'OperatorMono-Bold', 'OperatorMono-MediumItalic', 'OperatorMono-BoldItalic')

        # Test variable font selection

        if has('SourceCodeVF'):
            opts = Options()
            opts.font_family = parse_font_spec('family="SourceCodeVF" variable_name="SourceCodeUpright" style="Bold"')
            ff = get_font_files(opts)
            face = face_from_descriptor(ff['medium'])
            self.ae(get_named_style(face)['name'], 'Bold')
            face = face_from_descriptor(ff['italic'])
            self.ae(get_named_style(face)['name'], 'Bold Italic')
            face = face_from_descriptor(ff['bold'])
            self.ae(get_named_style(face)['name'], 'Black')
            face = face_from_descriptor(ff['bi'])
            self.ae(get_named_style(face)['name'], 'Black Italic')
            opts.font_family = parse_font_spec('family=SourceCodeVF variable_name=SourceCodeUpright wght=470')
            opts.italic_font = parse_font_spec('family=SourceCodeVF variable_name=SourceCodeItalic style=Black')
            ff = get_font_files(opts)
            self.assertFalse(get_named_style(ff['medium']))
            self.ae(get_named_style(ff['italic'])['name'], 'Black Italic')
        if has('cascadia code'):
            opts = Options()
            opts.font_family = parse_font_spec('family="cascadia code"')
            opts.italic_font = parse_font_spec('family="cascadia code" variable_name= style="Light Italic"')
            ff = get_font_files(opts)

            def t(x, **kw):
                if 'spec' in kw:
                    fs = FontSpec.from_setting('family="Cascadia Code" ' + kw['spec'])._replace(created_from_string='')
                else:
                    kw['family'] = 'Cascadia Code'
                    fs = FontSpec(**kw)
                face = face_from_descriptor(ff[x])
                self.ae(fs.as_setting, spec_for_face('Cascadia Code', face).as_setting)

            t('medium', variable_name='CascadiaCodeRoman', style='Regular')
            t('italic', variable_name='', style='Light Italic')

            opts = Options()
            opts.font_family = parse_font_spec('family="cascadia code" variable_name=CascadiaCodeRoman wght=455')
            opts.italic_font = parse_font_spec('family="cascadia code" variable_name= wght=405')
            opts.bold_font = parse_font_spec('family="cascadia code" variable_name=CascadiaCodeRoman wght=603')
            ff = get_font_files(opts)
            t('medium', spec='variable_name=CascadiaCodeRoman wght=455')
            t('italic', spec='variable_name= wght=405')
            t('bold', spec='variable_name=CascadiaCodeRoman wght=603')
            t('bi', spec='variable_name= wght=603')

        # Test font features
        if has('liberation mono'):
            opts = Options()
            opts.font_family = parse_font_spec('family="liberation mono"')
            ff = get_font_files(opts)
            self.ae(face_from_descriptor(ff['medium']).applied_features(), {'dlig': '-dlig'})
            self.ae(face_from_descriptor(ff['bold']).applied_features(), {})
            opts.font_family = parse_font_spec('family="liberation mono" features="dlig test=3"')
            ff = get_font_files(opts)
            self.ae(face_from_descriptor(ff['medium']).applied_features(), {'dlig': 'dlig', 'test': 'test=3'})
            self.ae(face_from_descriptor(ff['bold']).applied_features(), {'dlig': 'dlig', 'test': 'test=3'})

    def test_synthetic_italic_matrix(self):
        # A roman-only font that find_best_match finds (e.g. Fira Code, which ships
        # no italic face) must get fontconfig's synthetic-italic FC_MATRIX
        # (90-synthetic.conf) attached, so its italic renders slanted rather than
        # upright; real-italic faces must not. The shear value is fontconfig's, not
        # ours, so assert the invariant (a non-identity matrix is present), not the
        # exact tuple, for cross-config stability.
        if is_macos:
            self.skipTest('synthetic-italic FC_MATRIX is a fontconfig feature')
        from kitty.fonts.fontconfig import FC_MONO, fc_match

        names = set(all_fonts_map(True)['family_map']) | set(all_fonts_map(True)['variable_map'])
        if family_name_to_key('fira code') not in names:
            self.skipTest('Fira Code not installed')
        # Probe fc_match directly so we can tell "environment lacks the rule" (skip)
        # from "code did not attach the matrix" (fail).
        if fc_match('Fira Code', False, True, FC_MONO).get('matrix') is None:
            self.skipTest('fontconfig 90-synthetic.conf not active; no synthetic-italic matrix')
        opts = Options()
        opts.font_family = parse_font_spec('Fira Code')
        ff = get_font_files(opts)
        self.assertIsNone(ff['medium'].get('matrix'))  # upright stays upright
        mi = ff['italic'].get('matrix')
        self.assertIsNotNone(mi)  # roman, no italic -> sheared
        self.assertNotEqual(mi[1], 0.0)  # actually slanted, not identity
        # Faces are built from a size-specialized descriptor at render time; the
        # matrix must survive specialize_font_descriptor or the glyphs render
        # upright despite the descriptor above being correct.
        from kitty.fast_data_types import specialize_font_descriptor

        sd = specialize_font_descriptor(dict(ff['italic']), 12.0, 96.0, 96.0)
        self.ae(sd.get('matrix'), mi)
        if family_name_to_key('liberation mono') in names:  # real-italic control
            opts.font_family = parse_font_spec('Liberation Mono')
            self.assertIsNone(get_font_files(opts)['italic'].get('matrix'))


def block_helpers(s, sprites, cell_width, cell_height):
    mr = {}
    actual = b''
    block_size = cell_width * cell_height * 4

    def full_block():
        return b'\xff' * block_size

    def empty_block():
        return b'\0' * block_size

    def half_block(first=b'\xff', second=b'\0', swap=False):
        frac = 0.5
        height = ceil(frac * cell_height)
        rest = cell_height - height
        if swap:
            height, rest = rest, height
            first, second = second, first
        return (first * (height * cell_width * 4)) + (second * rest * cell_width * 4)

    def quarter_block():
        frac = 0.5
        height = ceil(frac * cell_height)
        width = ceil(frac * cell_width)
        ans = array.array('I', b'\0' * block_size)
        for y in range(height):
            pos = cell_width * y
            for x in range(width):
                ans[pos + x] = 0xFFFFFFFF
        return ans.tobytes()

    def upper_half_block():
        return half_block()

    def lower_half_block():
        return half_block(swap=True)

    def block_as_str(a):
        pixels = array.array('I', a)

        def row(y):
            pos = y * cell_width
            return ' '.join(f'{int(pixels[pos + x] != 0)}' for x in range(cell_width))

        return '\n'.join(row(y) for y in range(cell_height))

    def assert_blocks(a, b, msg=''):
        nonlocal mr, actual, full_block, half_block, quarter_block, block_test, empty_block
        if a != b:
            del mr, actual, full_block, half_block, quarter_block, block_test, empty_block
            msg = msg or 'block not equal'
            if len(a) != len(b):
                assert_blocks.__msg = msg + f' block lengths not equal: {len(a) / 4} != {len(b) / 4}'
            else:
                assert_blocks.__msg = msg + '\n' + block_as_str(a) + '\n\n' + block_as_str(b)
            del a, b
            raise AssertionError(assert_blocks.__msg)

    def multiline_render(text, scale=1, width=1, **kw):
        s.reset()
        draw_multicell(s, text, scale=scale, width=width, **kw)
        ans = []
        for y in range(scale):
            line = s.line(y)
            test_render_line(line)
            for x in range(width * scale):
                ans.append(sprites[sprite_idx_to_pos(line.sprite_at(x), setup_for_testing.xnum, setup_for_testing.ynum)])
        return ans

    def block_test(*expected, **kw):
        nonlocal mr, actual
        mr = multiline_render(kw.pop('text', '█'), **kw)
        try:
            z = zip(expected, mr, strict=True)
        except TypeError:
            z = zip(expected, mr)
        for i, (expected, actual) in enumerate(z):
            assert_blocks(expected(), actual, f'Block {i} expected != actual')

    return full_block, empty_block, upper_half_block, lower_half_block, quarter_block, block_as_str, block_test


class FontBaseTest(BaseTest):
    font_size = 16.0
    dpi = 72.0
    font_name = 'FiraCode-Medium.otf'

    def path_for_font(self, name):
        if name not in self.font_path_cache:
            with open(os.path.join(self.tdir, name), 'wb') as f:
                self.font_path_cache[name] = f.name
                f.write(testing_font_data(name))
        return self.font_path_cache[name]

    def setUp(self):
        super().setUp()
        self.font_path_cache = {}
        self.tdir = tempfile.mkdtemp()
        self.addCleanup(self.rmtree_ignoring_errors, self.tdir)
        path = self.path_for_font(self.font_name) if self.font_name else ''
        tc = setup_for_testing(size=self.font_size, dpi=self.dpi, main_face_path=path)
        self.sprites, self.cell_width, self.cell_height = tc.__enter__()
        self.addCleanup(tc.__exit__)
        self.assertEqual([k[0] for k in self.sprites], list(range(11)))

    def tearDown(self):
        del self.sprites, self.cell_width, self.cell_height
        self.font_path_cache = {}
        super().tearDown()


class Rendering(FontBaseTest):
    def test_sprite_map(self):
        sprite_map_set_limits(10, 3)
        sprite_map_set_layout(5, 4)  # 4 because of underline_exclusion row
        self.ae(test_sprite_position_increment(), (0, 0, 0))
        self.ae(test_sprite_position_increment(), (1, 0, 0))
        self.ae(test_sprite_position_increment(), (0, 1, 0))
        self.ae(test_sprite_position_increment(), (1, 1, 0))
        self.ae(test_sprite_position_increment(), (0, 0, 1))
        self.ae(test_sprite_position_increment(), (1, 0, 1))
        self.ae(test_sprite_position_increment(), (0, 1, 1))
        self.ae(test_sprite_position_increment(), (1, 1, 1))
        self.ae(test_sprite_position_increment(), (0, 0, 2))
        self.ae(test_sprite_position_increment(), (1, 0, 2))

    def test_box_drawing(self):
        s = self.create_screen(cols=len(box_chars) + 1, lines=1, scrollback=0)
        prerendered = len(self.sprites)
        s.draw(''.join(box_chars))
        line = s.line(0)
        test_render_line(line)
        self.assertEqual(len(self.sprites) - prerendered, len(box_chars))

    def test_scaled_box_drawing(self):
        self.scaled_drawing_test()

    def test_scaled_font_drawing(self):
        set_allow_use_of_box_fonts(False)
        try:
            self.scaled_drawing_test()
        finally:
            set_allow_use_of_box_fonts(True)

    def scaled_drawing_test(self):
        s = self.create_screen(cols=8, lines=8, scrollback=0)
        full_block, empty_block, upper_half_block, lower_half_block, quarter_block, block_as_str, block_test = block_helpers(
            s, self.sprites, self.cell_width, self.cell_height
        )
        block_test(full_block)
        block_test(full_block, full_block, full_block, full_block, scale=2)
        block_test(full_block, empty_block, empty_block, empty_block, scale=2, subscale_n=1, subscale_d=2)
        block_test(empty_block, full_block, empty_block, empty_block, scale=2, subscale_n=1, subscale_d=2, horizontal_align=1)
        block_test(full_block, full_block, empty_block, empty_block, scale=2, subscale_n=1, subscale_d=2, text='██')
        block_test(empty_block, empty_block, full_block, empty_block, scale=2, subscale_n=1, subscale_d=2, vertical_align=1)
        block_test(quarter_block, scale=1, subscale_n=1, subscale_d=2)
        block_test(upper_half_block, scale=1, subscale_n=1, subscale_d=2, text='██')
        block_test(lower_half_block, scale=1, subscale_n=1, subscale_d=2, text='██', vertical_align=1)

    def test_font_rendering(self):
        render_string('ab\u0347\u0305你好|\U0001f601|\U0001f64f|\U0001f63a|')
        text = 'He\u0347\u0305llo\u0341, w\u0302or\u0306l\u0354d!'
        # macOS has no fonts capable of rendering combining chars
        if is_macos:
            text = text.encode('ascii', 'ignore').decode('ascii')
        cells = render_string(text)[-1]
        self.ae(len(cells), len(text.encode('ascii', 'ignore')))
        text = '你好,世界'
        sz = sum(map(lambda x: wcwidth(ord(x)), text))
        cells = render_string(text)[-1]
        self.ae(len(cells), sz)

    @unittest.skipIf(is_macos, 'COLRv1 is only supported on Linux')
    def test_rendering_colrv1(self):
        f = create_face(self.path_for_font('twemoji_smiley-cff2_colr_1.otf'))
        f.set_size(64, 96, 96)
        for char in '😁😇😈':
            _, w, h = f.render_codepoint(ord(char))
            self.assertGreater(w, 64)
            self.assertGreater(h, 64)

    def test_color_emoji_not_shrunk(self):
        # Regression test for https://github.com/kovidgoyal/kitty/issues/10144.
        # fontconfig gives fixed-size color faces (e.g. Noto Color Emoji) a
        # pixel-size fixup encoded as FC_MATRIX. That scale must not reach the
        # cairo font matrix used for color glyphs; applying it shrinks color emoji
        # to a dot (ee937bdd1b). Render the same font two ways at the same size:
        # from its fontconfig descriptor, which carries the fixup matrix, and from
        # its file path, which does not. A correct build renders both at the same
        # size; the bug shrinks the descriptor one. Comparing the two is
        # environment-independent since only the matrix differs.
        if is_macos:
            self.skipTest('FC_MATRIX is a fontconfig feature, not used on macOS')
        from kitty.fonts.fontconfig import fc_match

        desc = dict(fc_match('emoji', False, False, 0))
        if not (desc.get('color') and desc.get('matrix')):
            self.skipTest('no fixed-size color emoji font with a fontconfig fixup matrix')
        with_matrix = face_from_descriptor(desc)
        with_matrix.set_size(64, 96, 96)
        without_matrix = create_face(desc['path'])
        without_matrix.set_size(64, 96, 96)
        _, mw, mh = with_matrix.render_codepoint(0x1F40D)
        _, rw, rh = without_matrix.render_codepoint(0x1F40D)
        self.assertGreater(mh, 0.5 * rh, f'color emoji shrunk by FC_MATRIX: {mh}px vs {rh}px (#10144)')

    def test_shaping(self):

        def ss(text, font=None):
            path = self.path_for_font(font) if font else None
            return shape_string(text, path=path)

        def groups(text, font=None):
            return [x[:2] for x in ss(text, font)]

        for font in ('FiraCode-Medium.otf', 'CascadiaCode-Regular.otf', 'iosevka-regular.ttf'):
            g = partial(groups, font=font)
            self.ae(g('abcd'), [(1, 1) for i in range(4)])
            self.ae(g('A===B!=C'), [(1, 1), (3, 3), (1, 1), (2, 2), (1, 1)])
            self.ae(g('A=>>B!=C'), [(1, 1), (3, 3), (1, 1), (2, 2), (1, 1)])
            self.ae(g('->'), [(2, 2)])
            self.ae(g('<-'), [(2, 2)])
            self.ae(g('==>'), [(3, 3)])
            self.ae(g('<=='), [(3, 3)])
            self.ae(g('a->b'), [(1, 1), (2, 2), (1, 1)])
            self.ae(g('a<-b'), [(1, 1), (2, 2), (1, 1)])
            self.ae(g('a==>b'), [(1, 1), (3, 3), (1, 1)])
            self.ae(g('a<==b'), [(1, 1), (3, 3), (1, 1)])
            if 'iosevka' in font:
                self.ae(g('--->'), [(4, 4)])
                self.ae(g('-' * 12 + '>'), [(13, 13)])
                self.ae(g('<~~~'), [(4, 4)])
                self.ae(g('a<~~~b'), [(1, 1), (4, 4), (1, 1)])
            else:
                self.ae(g('----'), [(4, 4)])
                self.ae(g('F--a--'), [(1, 1), (2, 2), (1, 1), (2, 2)])
                self.ae(g('===--<>=='), [(3, 3), (2, 2), (2, 2), (2, 2)])
                self.ae(g('==!=<>==<><><>'), [(4, 4), (2, 2), (2, 2), (2, 2), (2, 2), (2, 2)])
                self.ae(g('-' * 18), [(18, 18)])
                self.ae(g('<==>'), [(4, 4)])
                self.ae(g('<!--'), [(4, 4)])
                self.ae(g('a<==>b'), [(1, 1), (4, 4), (1, 1)])
                self.ae(g('a<!--b'), [(1, 1), (4, 4), (1, 1)])
            self.ae(g('a>\u2060<b'), [(1, 1), (1, 2), (1, 1), (1, 1)])
        comfy = partial(groups, font='ComfyCode-Regular.ttf')
        comfy_cases = {
            '->': ('a->b', 2),
            '<-': ('a<-b', 2),
            '==>': ('a==>b', 3),
            '<==': ('a<==b', 3),
        }
        for text, (wrapped, ligature_width) in comfy_cases.items():
            baseline = comfy(text)
            self.assertIn(baseline, ([(ligature_width, ligature_width)], [(1, 1) for i in range(ligature_width)]))
            if baseline == [(ligature_width, ligature_width)]:
                self.ae(comfy(wrapped), [(1, 1), (ligature_width, ligature_width), (1, 1)])
            else:
                self.ae(comfy(wrapped), [(1, 1) for i in range(len(wrapped))])
        colon_glyph = ss('9:30', font='FiraCode-Medium.otf')[1][2]
        self.assertNotEqual(colon_glyph, ss(':', font='FiraCode-Medium.otf')[0][2])
        self.ae(colon_glyph, 1031)
        self.ae(groups('9:30', font='FiraCode-Medium.otf'), [(1, 1), (1, 1), (1, 1), (1, 1)])
        self.ae(groups('#_(', font='FiraCode-Medium.otf'), [(3, 3)])
        self.ae(groups('a#_(b', font='FiraCode-Medium.otf'), [(1, 1), (3, 3), (1, 1)])
        self.ae(groups('<*>>', font='FiraCode-Medium.otf'), [(3, 3), (1, 1)])
        self.ae(groups('a<*>>b', font='FiraCode-Medium.otf'), [(1, 1), (3, 3), (1, 1), (1, 1)])

        self.ae(groups('|\U0001f601|\U0001f64f|\U0001f63a|'), [(1, 1), (2, 1), (1, 1), (2, 1), (1, 1), (2, 1), (1, 1)])
        self.ae(groups('He\u0347\u0305llo\u0337,', font='LiberationMono-Regular.ttf'), [(1, 1), (1, 3), (1, 1), (1, 1), (1, 2), (1, 1)])

        self.ae(groups('i\u0332\u0308', font='LiberationMono-Regular.ttf'), [(1, 2)])
        self.ae(groups('u\u0332 u\u0332\u0301', font='LiberationMono-Regular.ttf'), [(1, 2), (1, 1), (1, 2)])

        # FN1: the ligature-name memoization must not change shaping. Assert the
        # cached (default) and uncached paths produce byte-identical shaping for
        # an infinite-ligature font (Cascadia: _start.seq/_end.seq glyph names)
        # and a calt-ligature font (Fira Code), covering cache miss, hit, and the
        # KITTY_DISABLE_LIGNAME_CACHE fallback path.
        lig_probe = (
            'abcd', 'A===B!=C', 'A=>>B!=C', '->', '<-', '==>', '<==', 'a->b',
            'a==>b', '----', 'F--a--', '===--<>==', '<==>', '<!--', 'a<!--b',
            '#_(', 'a#_(b', '<*>>', '9:30',
        )
        for font in ('CascadiaCode-Regular.otf', 'FiraCode-Medium.otf'):
            cached = [ss(t, font=font) for t in lig_probe]
            prev = set_ligature_name_cache_enabled(False)
            try:
                uncached = [ss(t, font=font) for t in lig_probe]
            finally:
                set_ligature_name_cache_enabled(prev)
            self.ae(cached, uncached, f'ligature-name cache changed shaping for {font}')

    def test_emoji_presentation(self):
        s = self.create_screen()
        s.draw('\u2716\u2716\ufe0f')
        self.ae((s.cursor.x, s.cursor.y), (3, 0))
        s.draw('\u2716\u2716')
        self.ae((s.cursor.x, s.cursor.y), (5, 0))
        s.draw('\ufe0f')
        self.ae((s.cursor.x, s.cursor.y), (2, 1))
        self.ae(str(s.line(0)), '\u2716\u2716\ufe0f\u2716')
        self.ae(str(s.line(1)), '\u2716\ufe0f')
        s.draw('\u2716' * 3)
        self.ae((s.cursor.x, s.cursor.y), (5, 1))
        self.ae(str(s.line(1)), '\u2716\ufe0f\u2716\u2716\u2716')
        self.ae((s.cursor.x, s.cursor.y), (5, 1))
        s.reset_mode(DECAWM)
        s.draw('\ufe0f')
        s.set_mode(DECAWM)
        self.ae((s.cursor.x, s.cursor.y), (5, 1))
        self.ae(str(s.line(1)), '\u2716\ufe0f\u2716\u2716\ufe0f')
        s.cursor.y = s.lines - 1
        s.draw('\u2716' * s.columns)
        self.ae((s.cursor.x, s.cursor.y), (5, 4))
        s.draw('\ufe0f')
        self.ae((s.cursor.x, s.cursor.y), (2, 4))
        self.ae(str(s.line(s.cursor.y)), '\u2716\ufe0f')

    @unittest.skipUnless(is_macos, 'Only macOS has a Last Resort font')
    def test_fallback_font_not_last_resort(self):
        # Ensure that the LastResort font is not reported as a fallback font on
        # macOS. See https://github.com/kovidgoyal/kitty/issues/799
        with self.assertRaises(ValueError, msg='No fallback font found'):
            get_fallback_font('\U0010ffff', False, False)

    def test_coalesce_symbol_maps(self):
        q = {(2, 3): 'a', (4, 6): 'b', (5, 5): 'b', (7, 7): 'b', (9, 9): 'b', (1, 1): 'a'}
        self.ae(coalesce_symbol_maps(q), {(1, 3): 'a', (4, 7): 'b', (9, 9): 'b'})
        q = {(1, 4): 'a', (2, 3): 'b'}
        self.ae(coalesce_symbol_maps(q), {(1, 1): 'a', (2, 3): 'b', (4, 4): 'a'})
        q = {(2, 3): 'b', (1, 4): 'a'}
        self.ae(coalesce_symbol_maps(q), {(1, 4): 'a'})
        q = {(1, 4): 'a', (2, 5): 'b'}
        self.ae(coalesce_symbol_maps(q), {(1, 1): 'a', (2, 5): 'b'})
        q = {(2, 5): 'b', (1, 4): 'a'}
        self.ae(coalesce_symbol_maps(q), {(1, 4): 'a', (5, 5): 'b'})
        q = {(1, 4): 'a', (2, 5): 'a'}
        self.ae(coalesce_symbol_maps(q), {(1, 5): 'a'})
        q = {(1, 4): 'a', (4, 5): 'b'}
        self.ae(coalesce_symbol_maps(q), {(1, 3): 'a', (4, 5): 'b'})
        q = {(4, 5): 'b', (1, 4): 'a'}
        self.ae(coalesce_symbol_maps(q), {(1, 4): 'a', (5, 5): 'b'})
        q = {(0, 30): 'a', (10, 10): 'b', (11, 11): 'b', (2, 2): 'c', (1, 1): 'c'}
        self.ae(coalesce_symbol_maps(q), {(0, 0): 'a', (1, 2): 'c', (3, 9): 'a', (10, 11): 'b', (12, 30): 'a'})


class FallbackFontChain(BaseTest):
    # Tests for the user-configurable fallback chain (fallback_font /
    # emoji_font): style-aware static bands consulted by load_fallback_font()
    # before the OS fallback path.

    def setup_ctx(self, main: str = 'family=Menlo', fallback: tuple = (), emoji: tuple = (), symbol_map_font: str = ''):
        from kitty.options.types import defaults
        from kitty.options.utils import emoji_font as emoji_font_parser
        from kitty.options.utils import fallback_font as fallback_font_parser
        from kitty.options.utils import symbol_map

        opts = defaults._replace(font_family=parse_font_spec(main))
        opts.fallback_font = {k: v for x in fallback for k, v in fallback_font_parser(x)}
        opts.emoji_font = {k: v for x in emoji for k, v in emoji_font_parser(x)}
        if symbol_map_font:
            opts.symbol_map = dict(symbol_map(f'U+E0A0-U+E0A3 {symbol_map_font}'))
        return setup_for_testing(opts=opts)

    def has_family(self, family: str) -> bool:
        return family_name_to_key(family) in all_fonts_map(False)['family_map']

    @unittest.skipUnless(is_macos, 'Test uses macOS system fonts')
    def test_fallback_font_current_fonts_bands(self):
        # AC5: the symbol tuple length must equal the number of symbol_map
        # families regardless of configured fallback entries. Guards the
        # derived-count bug in current_fonts(): the two new bands sit between
        # first_symbol_font_idx and first_fallback_font_idx, so counting
        # symbol fonts by band subtraction would absorb them.
        with self.setup_ctx(symbol_map_font='Menlo'):
            cf = current_fonts()
            self.ae(len(cf['symbol']), 1)
            self.ae(len(cf['user_fallback']), 0)
            self.ae(len(cf['emoji_fallback']), 0)
        with self.setup_ctx(
            symbol_map_font='Menlo',
            fallback=('family="Hiragino Sans"', 'family=Menlo'),
            emoji=('family="Apple Color Emoji"',),
        ):
            cf = current_fonts()
            self.ae(len(cf['symbol']), 1)  # AC5
            # AC9: band lengths equal the configured family counts
            self.ae(len(cf['user_fallback']), 2)
            for styles in cf['user_fallback']:
                self.ae(len(styles), 4)
            self.ae(len(cf['emoji_fallback']), 1)

    @unittest.skipUnless(is_macos, 'Test uses macOS system fonts')
    def test_fallback_font_style_resolution(self):
        if not self.has_family('Hiragino Sans'):
            self.skipTest('Hiragino Sans is not available')
        with self.setup_ctx(fallback=('family="Hiragino Sans"',)):
            styles = current_fonts()['user_fallback'][0]
            regular_ps, bold_ps = styles[0].postscript_name(), styles[1].postscript_name()
            # The family must have a distinct bold face for AC2 to be meaningful
            self.assertNotEqual(regular_ps, bold_ps)
            # AC1: regular text uses the regular resolution of the spec
            self.ae(get_fallback_font('あ', False, False).postscript_name(), regular_ps)
            # AC2: bold text uses the bold resolution
            self.ae(get_fallback_font('あ', True, False).postscript_name(), bold_ps)
            # Both hits came from the static band: no dynamic OS fallback font was created
            self.ae(len(current_fonts()['fallback']), 0)

    @unittest.skipUnless(is_macos, 'Test uses macOS system fonts')
    def test_fallback_font_coverage_skip(self):
        if not self.has_family('Hiragino Sans'):
            self.skipTest('Hiragino Sans is not available')
        # AC3: a first entry that does not cover the text is skipped, not used
        with self.setup_ctx(fallback=('family=Menlo', 'family="Hiragino Sans"')):
            expected = current_fonts()['user_fallback'][1][0].postscript_name()
            self.ae(get_fallback_font('あ', False, False).postscript_name(), expected)
            self.ae(len(current_fonts()['fallback']), 0)

    @unittest.skipUnless(is_macos, 'Test uses macOS system fonts')
    def test_fallback_font_ordering(self):
        if not self.has_family('Hiragino Sans') or not self.has_family('Hiragino Mincho ProN'):
            self.skipTest('Hiragino families are not available')
        # Two covering entries: the first listed wins
        with self.setup_ctx(fallback=('family="Hiragino Sans"', 'family="Hiragino Mincho ProN"')):
            expected = current_fonts()['user_fallback'][0][0].postscript_name()
            self.ae(get_fallback_font('あ', False, False).postscript_name(), expected)
        with self.setup_ctx(fallback=('family="Hiragino Mincho ProN"', 'family="Hiragino Sans"')):
            expected = current_fonts()['user_fallback'][0][0].postscript_name()
            self.ae(get_fallback_font('あ', False, False).postscript_name(), expected)

    @unittest.skipUnless(is_macos, 'Test uses macOS system fonts')
    def test_fallback_font_falls_through_to_os(self):
        # All entries non-covering: the result must equal the no-config result
        with self.setup_ctx():
            os_ps = get_fallback_font('あ', False, False).postscript_name()
        with self.setup_ctx(fallback=('family=Menlo',)):
            self.ae(get_fallback_font('あ', False, False).postscript_name(), os_ps)
            # the OS path was used, so a dynamic fallback font was created
            self.ae(len(current_fonts()['fallback']), 1)

    @unittest.skipUnless(is_macos, 'Test uses macOS system fonts')
    def test_emoji_font_fallthrough(self):
        # AC10: an emoji_font lacking the emoji falls through to the OS emoji
        # font instead of rendering .notdef
        with self.setup_ctx(emoji=('family=Menlo',)):
            self.ae(get_fallback_font('🍣', False, False).postscript_name(), 'AppleColorEmoji')
            self.ae(len(current_fonts()['fallback']), 1)
        # And when the configured font does cover the emoji, the static band
        # is used and no dynamic fallback font is created
        with self.setup_ctx(emoji=('family="Apple Color Emoji"',)):
            cf = current_fonts()
            if cf['emoji_fallback'][0].postscript_name() == 'AppleColorEmoji':
                self.ae(get_fallback_font('🍣', False, False).postscript_name(), 'AppleColorEmoji')
                self.ae(len(current_fonts()['fallback']), 0)

    def test_fallback_font_spec_parsing(self):
        from kitty.options.utils import fallback_font as fallback_font_parser
        d: dict = {}
        entries = ('family="Hiragino Sans"', 'postscript_name=HiraginoSans-W6', 'family="Hiragino Sans" style=W6', 'Hiragino Sans')
        for v in entries:
            d.update(fallback_font_parser(v))
        specs = list(d.values())
        self.ae(len(specs), 4)
        self.ae([s.created_from_string for s in specs], list(entries))  # config order is preserved
        self.ae(specs[0].family, 'Hiragino Sans')
        self.ae(specs[1].postscript_name, 'HiraginoSans-W6')
        self.ae(specs[2].style, 'W6')
        self.assertTrue(specs[3].is_system)
        # a duplicate entry collapses instead of growing the chain
        d.update(fallback_font_parser(entries[0]))
        self.ae(len(d), 4)
        # a hyphenated postscript name survives family_name_to_key
        self.assertIn('-', family_name_to_key('HiraginoSans-W6'))


def test_chars(chars: str = '╌', sz: int = 128) -> None:
    # kitty +runpy "from kitty.fonts.box_drawing import test_chars; test_chars('XXX')"
    from kitty.fast_data_types import concat_cells, render_box_char, set_send_sprite_to_gpu
    from kitty.fonts.render import display_bitmap, setup_for_testing

    if not chars:
        import sys

        chars = sys.argv[-1]

    def as_ord(x: str) -> int:
        if x.lower().startswith('u+'):
            return int(x[2:], 16)
        return ord(x)

    if '...' in chars:
        start, end = chars.partition('...')[::2]
        chars = ''.join(map(chr, range(as_ord(start), as_ord(end) + 1)))

    with setup_for_testing('monospace', sz) as (_, width, height):
        try:
            for ch in chars:
                nb = render_box_char(as_ord(ch), width, height)
                rgb_data = concat_cells(width, height, False, (nb,))
                display_bitmap(rgb_data, width, height)
                print()
        finally:
            set_send_sprite_to_gpu(None)


def test_drawing(sz: int = 48, family: str = 'monospace', start: int = 0x2500, num_rows: int = 10, num_cols: int = 16) -> None:
    from kitty.fast_data_types import concat_cells, render_box_char, set_send_sprite_to_gpu

    from .render import display_bitmap, setup_for_testing

    with setup_for_testing(family, sz) as (_, width, height):
        space = bytearray(width * height)

        def join_cells(cells: Iterable[bytes]) -> bytes:
            cells = tuple(bytes(x) for x in cells)
            return concat_cells(width, height, False, cells)

        def render_chr(ch: str) -> bytearray:
            if ch in box_chars:
                return bytearray(render_box_char(ord(ch), width, height))
            return space

        pos = start
        rows = []
        space_row = join_cells(repeat(space, 32))

        try:
            for r in range(num_rows):
                row = []
                for i in range(num_cols):
                    row.append(render_chr(chr(pos)))
                    row.append(space)
                    pos += 1
                rows.append(join_cells(row))
                rows.append(space_row)
            rgb_data = b''.join(rows)
            width *= 32
            height *= len(rows)
            assert len(rgb_data) == width * height * 4, f'{len(rgb_data)} != {width * height * 4}'
            display_bitmap(rgb_data, width, height)
        finally:
            set_send_sprite_to_gpu(None)


box_chars = {  # {{{
    '─',
    '━',
    '│',
    '┃',
    '┄',
    '┅',
    '┆',
    '┇',
    '┈',
    '┉',
    '┊',
    '┋',
    '┌',
    '┍',
    '┎',
    '┏',
    '┐',
    '┑',
    '┒',
    '┓',
    '└',
    '┕',
    '┖',
    '┗',
    '┘',
    '┙',
    '┚',
    '┛',
    '├',
    '┝',
    '┞',
    '┟',
    '┠',
    '┡',
    '┢',
    '┣',
    '┤',
    '┥',
    '┦',
    '┧',
    '┨',
    '┩',
    '┪',
    '┫',
    '┬',
    '┭',
    '┮',
    '┯',
    '┰',
    '┱',
    '┲',
    '┳',
    '┴',
    '┵',
    '┶',
    '┷',
    '┸',
    '┹',
    '┺',
    '┻',
    '┼',
    '┽',
    '┾',
    '┿',
    '╀',
    '╁',
    '╂',
    '╃',
    '╄',
    '╅',
    '╆',
    '╇',
    '╈',
    '╉',
    '╊',
    '╋',
    '╌',
    '╍',
    '╎',
    '╏',
    '═',
    '║',
    '╒',
    '╓',
    '╔',
    '╕',
    '╖',
    '╗',
    '╘',
    '╙',
    '╚',
    '╛',
    '╜',
    '╝',
    '╞',
    '╟',
    '╠',
    '╡',
    '╢',
    '╣',
    '╤',
    '╥',
    '╦',
    '╧',
    '╨',
    '╩',
    '╪',
    '╫',
    '╬',
    '╭',
    '╮',
    '╯',
    '╰',
    '╱',
    '╲',
    '╳',
    '╴',
    '╵',
    '╶',
    '╷',
    '╸',
    '╹',
    '╺',
    '╻',
    '╼',
    '╽',
    '╾',
    '╿',
    '▀',
    '▁',
    '▂',
    '▃',
    '▄',
    '▅',
    '▆',
    '▇',
    '█',
    '▉',
    '▊',
    '▋',
    '▌',
    '▍',
    '▎',
    '▏',
    '▐',
    '░',
    '▒',
    '▓',
    '▔',
    '▕',
    '▖',
    '▗',
    '▘',
    '▙',
    '▚',
    '▛',
    '▜',
    '▝',
    '▞',
    '▟',
    '◉',
    '○',
    '●',
    '◖',
    '◗',
    '◜',
    '◝',
    '◞',
    '◟',
    '◠',
    '◡',
    '◢',
    '◣',
    '◤',
    '◥',
    '⠀',
    '⠁',
    '⠂',
    '⠃',
    '⠄',
    '⠅',
    '⠆',
    '⠇',
    '⠈',
    '⠉',
    '⠊',
    '⠋',
    '⠌',
    '⠍',
    '⠎',
    '⠏',
    '⠐',
    '⠑',
    '⠒',
    '⠓',
    '⠔',
    '⠕',
    '⠖',
    '⠗',
    '⠘',
    '⠙',
    '⠚',
    '⠛',
    '⠜',
    '⠝',
    '⠞',
    '⠟',
    '⠠',
    '⠡',
    '⠢',
    '⠣',
    '⠤',
    '⠥',
    '⠦',
    '⠧',
    '⠨',
    '⠩',
    '⠪',
    '⠫',
    '⠬',
    '⠭',
    '⠮',
    '⠯',
    '⠰',
    '⠱',
    '⠲',
    '⠳',
    '⠴',
    '⠵',
    '⠶',
    '⠷',
    '⠸',
    '⠹',
    '⠺',
    '⠻',
    '⠼',
    '⠽',
    '⠾',
    '⠿',
    '⡀',
    '⡁',
    '⡂',
    '⡃',
    '⡄',
    '⡅',
    '⡆',
    '⡇',
    '⡈',
    '⡉',
    '⡊',
    '⡋',
    '⡌',
    '⡍',
    '⡎',
    '⡏',
    '⡐',
    '⡑',
    '⡒',
    '⡓',
    '⡔',
    '⡕',
    '⡖',
    '⡗',
    '⡘',
    '⡙',
    '⡚',
    '⡛',
    '⡜',
    '⡝',
    '⡞',
    '⡟',
    '⡠',
    '⡡',
    '⡢',
    '⡣',
    '⡤',
    '⡥',
    '⡦',
    '⡧',
    '⡨',
    '⡩',
    '⡪',
    '⡫',
    '⡬',
    '⡭',
    '⡮',
    '⡯',
    '⡰',
    '⡱',
    '⡲',
    '⡳',
    '⡴',
    '⡵',
    '⡶',
    '⡷',
    '⡸',
    '⡹',
    '⡺',
    '⡻',
    '⡼',
    '⡽',
    '⡾',
    '⡿',
    '⢀',
    '⢁',
    '⢂',
    '⢃',
    '⢄',
    '⢅',
    '⢆',
    '⢇',
    '⢈',
    '⢉',
    '⢊',
    '⢋',
    '⢌',
    '⢍',
    '⢎',
    '⢏',
    '⢐',
    '⢑',
    '⢒',
    '⢓',
    '⢔',
    '⢕',
    '⢖',
    '⢗',
    '⢘',
    '⢙',
    '⢚',
    '⢛',
    '⢜',
    '⢝',
    '⢞',
    '⢟',
    '⢠',
    '⢡',
    '⢢',
    '⢣',
    '⢤',
    '⢥',
    '⢦',
    '⢧',
    '⢨',
    '⢩',
    '⢪',
    '⢫',
    '⢬',
    '⢭',
    '⢮',
    '⢯',
    '⢰',
    '⢱',
    '⢲',
    '⢳',
    '⢴',
    '⢵',
    '⢶',
    '⢷',
    '⢸',
    '⢹',
    '⢺',
    '⢻',
    '⢼',
    '⢽',
    '⢾',
    '⢿',
    '⣀',
    '⣁',
    '⣂',
    '⣃',
    '⣄',
    '⣅',
    '⣆',
    '⣇',
    '⣈',
    '⣉',
    '⣊',
    '⣋',
    '⣌',
    '⣍',
    '⣎',
    '⣏',
    '⣐',
    '⣑',
    '⣒',
    '⣓',
    '⣔',
    '⣕',
    '⣖',
    '⣗',
    '⣘',
    '⣙',
    '⣚',
    '⣛',
    '⣜',
    '⣝',
    '⣞',
    '⣟',
    '⣠',
    '⣡',
    '⣢',
    '⣣',
    '⣤',
    '⣥',
    '⣦',
    '⣧',
    '⣨',
    '⣩',
    '⣪',
    '⣫',
    '⣬',
    '⣭',
    '⣮',
    '⣯',
    '⣰',
    '⣱',
    '⣲',
    '⣳',
    '⣴',
    '⣵',
    '⣶',
    '⣷',
    '⣸',
    '⣹',
    '⣺',
    '⣻',
    '⣼',
    '⣽',
    '⣾',
    '⣿',
    '\ue0b0',
    '\ue0b1',
    '\ue0b2',
    '\ue0b3',
    '\ue0b4',
    '\ue0b5',
    '\ue0b6',
    '\ue0b7',
    '\ue0b8',
    '\ue0b9',
    '\ue0ba',
    '\ue0bb',
    '\ue0bc',
    '\ue0bd',
    '\ue0be',
    '\ue0bf',
    '\ue0d6',
    '\ue0d7',
    '\uee00',
    '\uee01',
    '\uee02',
    '\uee03',
    '\uee04',
    '\uee05',
    '\uee06',
    '\uee07',
    '\uee08',
    '\uee09',
    '\uee0a',
    '\uee0b',
    '\uf5d0',
    '\uf5d1',
    '\uf5d2',
    '\uf5d3',
    '\uf5d4',
    '\uf5d5',
    '\uf5d6',
    '\uf5d7',
    '\uf5d8',
    '\uf5d9',
    '\uf5da',
    '\uf5db',
    '\uf5dc',
    '\uf5dd',
    '\uf5de',
    '\uf5df',
    '\uf5e0',
    '\uf5e1',
    '\uf5e2',
    '\uf5e3',
    '\uf5e4',
    '\uf5e5',
    '\uf5e6',
    '\uf5e7',
    '\uf5e8',
    '\uf5e9',
    '\uf5ea',
    '\uf5eb',
    '\uf5ec',
    '\uf5ed',
    '\uf5ee',
    '\uf5ef',
    '\uf5f0',
    '\uf5f1',
    '\uf5f2',
    '\uf5f3',
    '\uf5f4',
    '\uf5f5',
    '\uf5f6',
    '\uf5f7',
    '\uf5f8',
    '\uf5f9',
    '\uf5fa',
    '\uf5fb',
    '\uf5fc',
    '\uf5fd',
    '\uf5fe',
    '\uf5ff',
    '\uf600',
    '\uf601',
    '\uf602',
    '\uf603',
    '\uf604',
    '\uf605',
    '\uf606',
    '\uf607',
    '\uf608',
    '\uf609',
    '\uf60a',
    '\uf60b',
    '\uf60c',
    '\uf60d',
    '🬀',
    '🬁',
    '🬂',
    '🬃',
    '🬄',
    '🬅',
    '🬆',
    '🬇',
    '🬈',
    '🬉',
    '🬊',
    '🬋',
    '🬌',
    '🬍',
    '🬎',
    '🬏',
    '🬐',
    '🬑',
    '🬒',
    '🬓',
    '🬔',
    '🬕',
    '🬖',
    '🬗',
    '🬘',
    '🬙',
    '🬚',
    '🬛',
    '🬜',
    '🬝',
    '🬞',
    '🬟',
    '🬠',
    '🬡',
    '🬢',
    '🬣',
    '🬤',
    '🬥',
    '🬦',
    '🬧',
    '🬨',
    '🬩',
    '🬪',
    '🬫',
    '🬬',
    '🬭',
    '🬮',
    '🬯',
    '🬰',
    '🬱',
    '🬲',
    '🬳',
    '🬴',
    '🬵',
    '🬶',
    '🬷',
    '🬸',
    '🬹',
    '🬺',
    '🬻',
    '🬼',
    '🬽',
    '🬾',
    '🬿',
    '🭀',
    '🭁',
    '🭂',
    '🭃',
    '🭄',
    '🭅',
    '🭆',
    '🭇',
    '🭈',
    '🭉',
    '🭊',
    '🭋',
    '🭌',
    '🭍',
    '🭎',
    '🭏',
    '🭐',
    '🭑',
    '🭒',
    '🭓',
    '🭔',
    '🭕',
    '🭖',
    '🭗',
    '🭘',
    '🭙',
    '🭚',
    '🭛',
    '🭜',
    '🭝',
    '🭞',
    '🭟',
    '🭠',
    '🭡',
    '🭢',
    '🭣',
    '🭤',
    '🭥',
    '🭦',
    '🭧',
    '🭨',
    '🭩',
    '🭪',
    '🭫',
    '🭬',
    '🭭',
    '🭮',
    '🭯',
    '🭰',
    '🭱',
    '🭲',
    '🭳',
    '🭴',
    '🭵',
    '🭶',
    '🭷',
    '🭸',
    '🭹',
    '🭺',
    '🭻',
    '🭼',
    '🭽',
    '🭾',
    '🭿',
    '🮀',
    '🮁',
    '🮂',
    '🮃',
    '🮄',
    '🮅',
    '🮆',
    '🮇',
    '🮈',
    '🮉',
    '🮊',
    '🮋',
    '🮌',
    '🮍',
    '🮎',
    '🮏',
    '🮐',
    '🮑',
    '🮒',
    '\U0001fb93',
    '🮔',
    '🮕',
    '🮖',
    '🮗',
    '🮘',
    '🮙',
    '🮚',
    '🮛',
    '🮜',
    '🮝',
    '🮞',
    '🮟',
    '🮠',
    '🮡',
    '🮢',
    '🮣',
    '🮤',
    '🮥',
    '🮦',
    '🮧',
    '🮨',
    '🮩',
    '🮪',
    '🮫',
    '🮬',
    '🮭',
    '🮮',
    '\U0001fbe6',
    '\U0001fbe7',
}  # }}}
for ch in range(0x1CD00, 0x1CDE5 + 1):  # octants
    box_chars.add(chr(ch))
for ch in range(0x1FBCE, 0x1FBF0):  # blocks, diagonals, circles (legacy computing)
    box_chars.add(chr(ch))
for ch in range(0x1CC1B, 0x1CC40):  # box drawing variants, separated quadrants, circle arcs (supplement)
    box_chars.add(chr(ch))
for ch in range(0x1CE16, 0x1CE1A):  # box drawings light vertical T-junctions (supplement)
    box_chars.add(chr(ch))
for ch in range(0x1CE51, 0x1CEB0):  # separated block sextants, sixteenth blocks, quarter parts (supplement)
    box_chars.add(chr(ch))
