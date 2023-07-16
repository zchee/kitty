#!/usr/bin/env python3
# License: GPL v3 Copyright: 2017, Kovid Goyal <kovid at kovidgoyal.net>

import os
import re
import subprocess
import sys
from collections import defaultdict
from contextlib import contextmanager
from functools import lru_cache, partial
from html.entities import html5
from itertools import groupby
from operator import itemgetter
from typing import (
    Callable,
    DefaultDict,
    Dict,
    FrozenSet,
    Generator,
    Iterable,
    List,
    Optional,
    Set,
    Tuple,
    Union,
)
from urllib.request import urlopen

os.chdir(os.path.dirname(os.path.abspath(__file__)))

non_characters = frozenset(range(0xfffe, 0x10ffff, 0x10000))
non_characters |= frozenset(range(0xffff, 0x10ffff + 1, 0x10000))
non_characters |= frozenset(range(0xfdd0, 0xfdf0))
if len(non_characters) != 66:
    raise SystemExit('non_characters table incorrect')
emoji_skin_tone_modifiers = frozenset(range(0x1f3fb, 0x1F3FF + 1))

def get_data(fname: str, folder: str = 'UCD/ucd') -> Iterable[str]:
    url = f'https://www.unicode.org/Public/draft/{folder}/{fname}'
    print('url: {}'.format(url))
    bn = os.path.basename(url)
    local = os.path.join('/tmp', bn)
    if os.path.exists(local):
        with open(local, 'rb') as f:
            data = f.read()
    else:
        data = urlopen(url).read()
        with open(local, 'wb') as f:
            f.write(data)
    for line in data.decode('utf-8').splitlines():
        line = line.strip()
        if line and not line.startswith('#'):
            yield line


@lru_cache(maxsize=2)
def unicode_version() -> Tuple[int, int, int]:
    for line in get_data("ReadMe.txt"):
        m = re.search(r'Version\s+(\d+)\.(\d+)\.(\d+)', line)
        if m is not None:
            return int(m.group(1)), int(m.group(2)), int(m.group(3))
    raise ValueError('Could not find Unicode Version')


# Map of class names to set of codepoints in class
class_maps: Dict[str, Set[int]] = {}
all_symbols: Set[int] = set()
name_map: Dict[int, str] = {}
word_search_map: DefaultDict[str, Set[int]] = defaultdict(set)
soft_hyphen = 0xad
flag_codepoints = frozenset(range(0x1F1E6, 0x1F1E6 + 26))
# See https://github.com/harfbuzz/harfbuzz/issues/169
marks = set(emoji_skin_tone_modifiers) | flag_codepoints
not_assigned = set(range(0, sys.maxunicode))
property_maps: Dict[str, Set[int]] = defaultdict(set)


def parse_prop_list() -> None:
    global marks
    for line in get_data('PropList.txt'):
        if line.startswith('#'):
            continue
        cp_or_range, rest = line.split(';', 1)
        chars = parse_range_spec(cp_or_range.strip())
        name = rest.strip().split()[0]
        property_maps[name] |= chars
    # see https://www.unicode.org/faq/unsup_char.html#3
    marks |= property_maps['Other_Default_Ignorable_Code_Point']


def parse_ucd() -> None:

    def add_word(w: str, c: int) -> None:
        if c <= 32 or c == 127 or 128 <= c <= 159:
            return
        if len(w) > 1:
            word_search_map[w.lower()].add(c)

    first: Optional[int] = None
    for word, c in html5.items():
        if len(c) == 1:
            add_word(word.rstrip(';'), ord(c))
    word_search_map['nnbsp'].add(0x202f)
    for line in get_data('UnicodeData.txt'):
        parts = [x.strip() for x in line.split(';')]
        codepoint = int(parts[0], 16)
        name = parts[1] or parts[10]
        if name == '<control>':
            name = parts[10]
        if name:
            name_map[codepoint] = name
            for word in name.lower().split():
                add_word(word, codepoint)
        category = parts[2]
        s = class_maps.setdefault(category, set())
        desc = parts[1]
        codepoints: Union[Tuple[int, ...], Iterable[int]] = (codepoint,)
        if first is None:
            if desc.endswith(', First>'):
                first = codepoint
                continue
        else:
            codepoints = range(first, codepoint + 1)
            first = None
        for codepoint in codepoints:
            s.add(codepoint)
            not_assigned.discard(codepoint)
            if category.startswith('M'):
                marks.add(codepoint)
            elif category.startswith('S'):
                all_symbols.add(codepoint)
            elif category == 'Cf':
                # we add Cf to marks as it contains things like tags and zero
                # width chars. Not sure if *all* of Cf should be treated as
                # combining chars, might need to add individual exceptions in
                # the future.
                marks.add(codepoint)

    with open('nerd-fonts-glyphs.txt') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            code, category, name = line.split(' ', 2)
            codepoint = int(code, 16)
            if name and codepoint not in name_map:
                name_map[codepoint] = name.upper()
                for word in name.lower().split():
                    add_word(word, codepoint)

    # Some common synonyms
    word_search_map['bee'] |= word_search_map['honeybee']
    word_search_map['lambda'] |= word_search_map['lamda']
    word_search_map['lamda'] |= word_search_map['lambda']
    word_search_map['diamond'] |= word_search_map['gem']


def parse_range_spec(spec: str) -> Set[int]:
    spec = spec.strip()
    if '..' in spec:
        chars_ = tuple(map(lambda x: int(x, 16), filter(None, spec.split('.'))))
        chars = set(range(chars_[0], chars_[1] + 1))
    else:
        chars = {int(spec, 16)}
    return chars


def split_two(line: str) -> Tuple[Set[int], str]:
    spec, rest = line.split(';', 1)
    spec, rest = spec.strip(), rest.strip().split(' ', 1)[0].strip()
    return parse_range_spec(spec), rest


all_emoji: Set[int] = set()
emoji_presentation_bases: Set[int] = set()
narrow_emoji: Set[int] = set()
wide_emoji: Set[int] = set()
flags: Dict[int, List[int]] = {}


def parse_basic_emoji(spec: str) -> None:
    parts = list(filter(None, spec.split()))
    has_emoji_presentation = len(parts) < 2
    chars = parse_range_spec(parts[0])
    all_emoji.update(chars)
    emoji_presentation_bases.update(chars)
    (wide_emoji if has_emoji_presentation else narrow_emoji).update(chars)


def parse_keycap_sequence(spec: str) -> None:
    base, fe0f, cc = list(filter(None, spec.split()))
    chars = parse_range_spec(base)
    all_emoji.update(chars)
    emoji_presentation_bases.update(chars)
    narrow_emoji.update(chars)


def parse_flag_emoji_sequence(spec: str) -> None:
    a, b = list(filter(None, spec.split()))
    left, right = int(a, 16), int(b, 16)
    chars = {left, right}
    all_emoji.update(chars)
    wide_emoji.update(chars)
    emoji_presentation_bases.update(chars)
    flags.setdefault(left, []).append(right)


def parse_emoji_tag_sequence(spec: str) -> None:
    a = int(spec.split()[0], 16)
    all_emoji.add(a)
    wide_emoji.add(a)
    emoji_presentation_bases.add(a)


def parse_emoji_modifier_sequence(spec: str) -> None:
    a, b = list(filter(None, spec.split()))
    char, mod = int(a, 16), int(b, 16)
    mod
    all_emoji.add(char)
    wide_emoji.add(char)
    emoji_presentation_bases.add(char)


def parse_emoji() -> None:
    for line in get_data('emoji-sequences.txt', 'emoji'):
        parts = [x.strip() for x in line.split(';')]
        if len(parts) < 2:
            continue
        data, etype = parts[:2]
        if etype == 'Basic_Emoji':
            parse_basic_emoji(data)
        elif etype == 'Emoji_Keycap_Sequence':
            parse_keycap_sequence(data)
        elif etype == 'RGI_Emoji_Flag_Sequence':
            parse_flag_emoji_sequence(data)
        elif etype == 'RGI_Emoji_Tag_Sequence':
            parse_emoji_tag_sequence(data)
        elif etype == 'RGI_Emoji_Modifier_Sequence':
            parse_emoji_modifier_sequence(data)


doublewidth: Set[int] = set()
ambiguous: Set[int] = set()


def parse_eaw() -> None:
    global doublewidth, ambiguous
    seen: Set[int] = set()
    for line in get_data('EastAsianWidth.txt'):
        chars, eaw = split_two(line)
        if eaw == 'A':
            ambiguous |= chars
            seen |= chars
        elif eaw in ('W', 'F'):
            doublewidth |= chars
            seen |= chars
    doublewidth |= set(range(0x3400, 0x4DBF + 1)) - seen
    doublewidth |= set(range(0x4E00, 0x9FFF + 1)) - seen
    doublewidth |= set(range(0xF900, 0xFAFF + 1)) - seen
    doublewidth |= set(range(0x20000, 0x2FFFD + 1)) - seen
    doublewidth |= set(range(0x30000, 0x3FFFD + 1)) - seen


def get_ranges(items: List[int]) -> Generator[Union[int, Tuple[int, int]], None, None]:
    items.sort()
    for k, g in groupby(enumerate(items), lambda m: m[0]-m[1]):
        group = tuple(map(itemgetter(1), g))
        a, b = group[0], group[-1]
        if a == b:
            yield a
        else:
            yield a, b


def write_case(spec: Union[Tuple[int, ...], int], p: Callable[..., None], for_go: bool = False) -> None:
    if isinstance(spec, tuple):
        if for_go:
            v = ', '.join(f'0x{x:x}' for x in range(spec[0], spec[1] + 1))
            p(f'\t\tcase {v}:')
        else:
            p('\t\tcase 0x{:x} ... 0x{:x}:'.format(*spec))
    else:
        p(f'\t\tcase 0x{spec:x}:')


@contextmanager
def create_header(path: str, include_data_types: bool = True) -> Generator[Callable[..., None], None, None]:
    with open(path, 'w') as f:
        p = partial(print, file=f)
        p('// Unicode data, built from the Unicode Standard', '.'.join(map(str, unicode_version())))
        p(f'// Code generated by {os.path.basename(__file__)}, DO NOT EDIT.', end='\n\n')
        if path.endswith('.h'):
            p('#pragma once')
        if include_data_types:
            p('#include "data-types.h"\n')
            p('START_ALLOW_CASE_RANGE')
        p()
        yield p
        p()
        if include_data_types:
            p('END_ALLOW_CASE_RANGE')


def gen_emoji() -> None:
    with create_header('kitty/emoji.h') as p:
        p('static inline bool\nis_emoji(char_type code) {')
        p('\tswitch(code) {')
        for spec in get_ranges(list(all_emoji)):
            write_case(spec, p)
            p('\t\t\treturn true;')
        p('\t\tdefault: return false;')
        p('\t}')
        p('\treturn false;\n}')

        p('static inline bool\nis_symbol(char_type code) {')
        p('\tswitch(code) {')
        for spec in get_ranges(list(all_symbols)):
            write_case(spec, p)
            p('\t\t\treturn true;')
        p('\t\tdefault: return false;')
        p('\t}')
        p('\treturn false;\n}')


def category_test(
    name: str,
    p: Callable[..., None],
    classes: Iterable[str],
    comment: str,
    use_static: bool = False,
    extra_chars: Union[FrozenSet[int], Set[int]] = frozenset(),
    exclude: Union[Set[int], FrozenSet[int]] = frozenset(),
    least_check_return: Optional[str] = None,
    ascii_range: Optional[str] = None
) -> None:
    static = 'static inline ' if use_static else ''
    chars: Set[int] = set()
    for c in classes:
        chars |= class_maps[c]
    chars |= extra_chars
    chars -= exclude
    p(f'{static}bool\n{name}(char_type code) {{')
    p(f'\t// {comment} ({len(chars)} codepoints)' + ' {{' '{')
    if least_check_return is not None:
        least = min(chars)
        p(f'\tif (LIKELY(code < {least})) return {least_check_return};')
    if ascii_range is not None:
        p(f'\tif (LIKELY(0x20 <= code && code <= 0x7e)) return {ascii_range};')
    p('\tswitch(code) {')
    for spec in get_ranges(list(chars)):
        write_case(spec, p)
        p('\t\t\treturn true;')
    p('\t} // }}}\n')
    p('\treturn false;\n}\n')


def codepoint_to_mark_map(p: Callable[..., None], mark_map: List[int]) -> Dict[int, int]:
    p('\tswitch(c) { // {{{')
    rmap = {c: m for m, c in enumerate(mark_map)}
    for spec in get_ranges(mark_map):
        if isinstance(spec, tuple):
            s = rmap[spec[0]]
            cases = ' '.join(f'case {i}:' for i in range(spec[0], spec[1]+1))
            p(f'\t\t{cases} return {s} + c - {spec[0]};')
        else:
            p(f'\t\tcase {spec}: return {rmap[spec]};')
    p('default: return 0;')
    p('\t} // }}}')
    return rmap


def classes_to_regex(classes: Iterable[str], exclude: str = '', for_go: bool = True) -> Iterable[str]:
    chars: Set[int] = set()
    for c in classes:
        chars |= class_maps[c]
    for x in map(ord, exclude):
        chars.discard(x)

    if for_go:
        def as_string(codepoint: int) -> str:
            if codepoint < 256:
                return fr'\x{codepoint:02x}'
            return fr'\x{{{codepoint:x}}}'
    else:
        def as_string(codepoint: int) -> str:
            if codepoint < 256:
                return fr'\x{codepoint:02x}'
            if codepoint <= 0xffff:
                return fr'\u{codepoint:04x}'
            return fr'\U{codepoint:08x}'

    for spec in get_ranges(list(chars)):
        if isinstance(spec, tuple):
            yield '{}-{}'.format(*map(as_string, (spec[0], spec[1])))
        else:
            yield as_string(spec)


def gen_ucd() -> None:
    cz = {c for c in class_maps if c[0] in 'CZ'}
    with create_header('kitty/unicode-data.c') as p:
        p('#include "unicode-data.h"')
        category_test(
                'is_combining_char', p,
                (),
                'Combining and default ignored characters',
                extra_chars=marks,
                least_check_return='false'
        )
        category_test(
            'is_ignored_char', p, 'Cc Cs'.split(),
            'Control characters and non-characters',
            extra_chars=non_characters,
            ascii_range='false'
        )
        category_test(
            'is_non_rendered_char', p, 'Cc Cs Cf'.split(),
            'Other_Default_Ignorable_Code_Point and soft hyphen',
            extra_chars=property_maps['Other_Default_Ignorable_Code_Point'] | set(range(0xfe00, 0xfe0f + 1)),
            ascii_range='false'
        )
        category_test('is_word_char', p, {c for c in class_maps if c[0] in 'LN'}, 'L and N categories')
        category_test('is_CZ_category', p, cz, 'C and Z categories')
        category_test('is_P_category', p, {c for c in class_maps if c[0] == 'P'}, 'P category (punctuation)')
        mark_map = [0] + list(sorted(marks))
        p('char_type codepoint_for_mark(combining_type m) {')
        p(f'\tstatic char_type map[{len(mark_map)}] =', '{', ', '.join(map(str, mark_map)), '}; // {{{ mapping }}}')
        p('\tif (m < arraysz(map)) return map[m];')
        p('\treturn 0;')
        p('}\n')
        p('combining_type mark_for_codepoint(char_type c) {')
        rmap = codepoint_to_mark_map(p, mark_map)
        p('}\n')
        with open('kitty/unicode-data.h', 'r+') as f:
            raw = f.read()
            f.seek(0)
            raw, num = re.subn(
                r'^// START_KNOWN_MARKS.+?^// END_KNOWN_MARKS',
                '// START_KNOWN_MARKS\nstatic const combining_type '
                f'VS15 = {rmap[0xfe0e]}, VS16 = {rmap[0xfe0f]};'
                '\n// END_KNOWN_MARKS', raw, flags=re.MULTILINE | re.DOTALL)
            if not num:
                raise SystemExit('Faile dto patch mark definitions in unicode-data.h')
            f.truncate()
            f.write(raw)

    chars = ''.join(classes_to_regex(cz, exclude='\n\r'))
    with open('kittens/hints/url_regex.go', 'w') as f:
        f.write('// generated by gen-wcwidth.py, do not edit\n\n')
        f.write('package hints\n\n')
        f.write(f'const URL_DELIMITERS = `{chars}`\n')


def gen_names() -> None:
    aliases_map: Dict[int, Set[str]] = {}
    for word, codepoints in word_search_map.items():
        for cp in codepoints:
            aliases_map.setdefault(cp, set()).add(word)
    if len(name_map) > 0xffff:
        raise Exception('Too many named codepoints')
    with open('tools/unicode_names/names.txt', 'w') as f:
        print(len(name_map), len(word_search_map), file=f)
        for cp in sorted(name_map):
            name = name_map[cp]
            words = name.lower().split()
            aliases = aliases_map.get(cp, set()) - set(words)
            end = '\n'
            if aliases:
                end = '\t' + ' '.join(sorted(aliases)) + end
            print(cp, *words, end=end, file=f)


def gen_wcwidth() -> None:
    seen: Set[int] = set()
    non_printing = class_maps['Cc'] | class_maps['Cf'] | class_maps['Cs']

    def add(p: Callable[..., None], comment: str, chars_: Union[Set[int], FrozenSet[int]], ret: int, for_go: bool = False) -> None:
        chars = chars_ - seen
        seen.update(chars)
        p(f'\t\t// {comment} ({len(chars)} codepoints)' + ' {{' '{')
        for spec in get_ranges(list(chars)):
            write_case(spec, p, for_go)
            p(f'\t\t\treturn {ret};')
        p('\t\t// }}}\n')

    def add_all(p: Callable[..., None], for_go: bool = False) -> None:
        seen.clear()
        add(p, 'Flags', flag_codepoints, 2, for_go)
        add(p, 'Marks', marks | {0}, 0, for_go)
        add(p, 'Non-printing characters', non_printing, -1, for_go)
        add(p, 'Private use', class_maps['Co'], -3, for_go)
        add(p, 'Text Presentation', narrow_emoji, 1, for_go)
        add(p, 'East Asian ambiguous width', ambiguous, -2, for_go)
        add(p, 'East Asian double width', doublewidth, 2, for_go)
        add(p, 'Emoji Presentation', wide_emoji, 2, for_go)

        add(p, 'Not assigned in the unicode character database', not_assigned, -4, for_go)

        p('\t\tdefault:\n\t\t\treturn 1;')
        p('\t}')
        if for_go:
            p('\t}')
        else:
            p('\treturn 1;\n}')

    with create_header('kitty/wcwidth-std.h') as p, open('tools/wcswidth/std.go', 'w') as gof:
        gop = partial(print, file=gof)
        gop('package wcswidth\n\n')
        gop('func Runewidth(code rune) int {')
        p('static inline int\nwcwidth_std(int32_t code) {')
        p('\tif (LIKELY(0x20 <= code && code <= 0x7e)) { return 1; }')
        p('\tswitch(code) {')
        gop('\tswitch(code) {')
        add_all(p)
        add_all(gop, True)

        p('static inline bool\nis_emoji_presentation_base(uint32_t code) {')
        gop('func IsEmojiPresentationBase(code rune) bool {')
        p('\tswitch(code) {')
        gop('\tswitch(code) {')
        for spec in get_ranges(list(emoji_presentation_bases)):
            write_case(spec, p)
            write_case(spec, gop, for_go=True)
            p('\t\t\treturn true;')
            gop('\t\t\treturn true;')
        p('\t\tdefault: return false;')
        p('\t}')
        gop('\t\tdefault:\n\t\t\treturn false')
        gop('\t}')
        p('\treturn true;\n}')
        gop('\n}')
        uv = unicode_version()
        p(f'#define UNICODE_MAJOR_VERSION {uv[0]}')
        p(f'#define UNICODE_MINOR_VERSION {uv[1]}')
        p(f'#define UNICODE_PATCH_VERSION {uv[2]}')
        gop('var UnicodeDatabaseVersion [3]int = [3]int{' f'{uv[0]}, {uv[1]}, {uv[2]}' + '}')
    subprocess.check_call(['gofmt', '-w', '-s', gof.name])


def gen_rowcolumn_diacritics() -> None:
    # codes of all row/column diacritics
    codes = []
    with open("./rowcolumn-diacritics.txt") as file:
        for line in file.readlines():
            if line.startswith('#'):
                continue
            code = int(line.split(";")[0], 16)
            codes.append(code)

    go_file = 'tools/utils/images/rowcolumn_diacritics.go'
    with create_header('kitty/rowcolumn-diacritics.c') as p, create_header(go_file, include_data_types=False) as g:
        p('#include "unicode-data.h"')
        p('int diacritic_to_num(char_type code) {')
        p('\tswitch (code) {')
        g('package images')
        g(f'var NumberToDiacritic = [{len(codes)}]rune''{')
        g(', '.join(f'0x{x:x}' for x in codes) + ',')
        g('}')

        range_start_num = 1
        range_start = 0
        range_end = 0

        def print_range() -> None:
            if range_start >= range_end:
                return
            write_case((range_start, range_end), p)
            p('\t\treturn code - ' + hex(range_start) + ' + ' +
              str(range_start_num) + ';')

        for code in codes:
            if range_end == code:
                range_end += 1
            else:
                print_range()
                range_start_num += range_end - range_start
                range_start = code
                range_end = code + 1
        print_range()

        p('\t}')
        p('\treturn 0;')
        p('}')
    subprocess.check_call(['gofmt', '-w', '-s', go_file])


parse_ucd()
parse_prop_list()
parse_emoji()
parse_eaw()
gen_ucd()
gen_wcwidth()
gen_emoji()
gen_names()
gen_rowcolumn_diacritics()
