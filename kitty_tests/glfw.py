#!/usr/bin/env python
# License: GPL v3 Copyright: 2020, Kovid Goyal <kovid at kovidgoyal.net>

import sys
import unittest

from .base import BaseTest

_plat = sys.platform.lower()
is_macos = 'darwin' in _plat


class TestGLFW(BaseTest):

    def test_preferred_display_link_backend_symbol(self):
        if not is_macos:
            self.skipTest('macOS only test')
        import subprocess
        import sys
        from textwrap import dedent

        from kitty.constants import glfw_path
        from kitty.utils import macos_version

        lib_path = glfw_path('cocoa')
        # A real python interpreter, not sys.executable: under upstream's
        # parallel runner the workers ARE the kitty binary, where '-c' means
        # --config and this probe hung as a terminal. _real_python() resolves
        # a plain CPython (see kitty_tests.slot_cow); lib_path is embedded in
        # the script text rather than passed as argv so the call site is
        # interpreter-agnostic.
        from kitty_tests.slot_cow import _real_python
        script = dedent(f'''
            import ctypes
            import sys

            try:
                lib = ctypes.CDLL({lib_path!r})
            except OSError as e:
                print(e, file=sys.stderr)
                sys.exit(1)
            func = lib.glfwCocoaPreferredDisplayLinkBackend
            func.restype = ctypes.c_int
            print(func())
        ''')
        proc = subprocess.run([_real_python(), '-c', script], capture_output=True, text=True)
        if proc.returncode != 0:
            self.skipTest('Unable to query Cocoa display link backend: ' + proc.stderr.strip())
        backend_text = proc.stdout.strip()
        if not backend_text:
            self.skipTest('No backend result reported')
        backend = int(backend_text)
        self.assertIn(backend, (0, 1))
        if backend == 1:
            self.assertGreaterEqual(macos_version()[:1], (14,))

    def test_display_link_backend_helper(self):
        from kitty.main import query_display_link_backend

        backend = query_display_link_backend('cocoa')
        self.assertEqual(backend, query_display_link_backend('cocoa'))
        if is_macos:
            if backend is None:
                self.skipTest('Display link backend introspection unavailable')
            self.assertIn(backend, (0, 1))
        else:
            self.assertIsNone(backend)

    def test_display_link_backend_helper_missing_library(self):
        import kitty.main as km

        orig = km._display_link_backend_lib
        try:
            km._display_link_backend_lib = None
            self.assertIsNone(km.query_display_link_backend('definitely-not-a-real-backend'))
        finally:
            km._display_link_backend_lib = orig

    def test_os_window_size_calculation(self):
        from kitty.utils import get_new_os_window_size

        def t(w, h, width=0, height=0, unit='cells', incremental=False):
            self.ae((w, h), get_new_os_window_size(metrics, width, height, unit, incremental, has_window_scaling))

        with self.subTest(has_window_scaling=False):
            has_window_scaling = False
            metrics = {
                'width': 200,
                'height': 100,
                'framebuffer_width': 200,
                'framebuffer_height': 100,
                'xscale': 2.0,
                'yscale': 2.0,
                'xdpi': 192.0,
                'ydpi': 192.0,
                'cell_width': 8,
                'cell_height': 16,
            }
            t(80 * metrics['cell_width'], 100, 80)
            t(80 * metrics['cell_width'] + metrics['width'], 100, 80, incremental=True)
            t(1217, 100, 1217, unit='pixels')
            t(1217 + metrics['width'], 100, 1217, unit='pixels', incremental=True)

        with self.subTest(has_window_scaling=True):
            has_window_scaling = True
            metrics['framebuffer_width'] = metrics['width'] * 2
            metrics['framebuffer_height'] = metrics['height'] * 2
            t(80 * metrics['cell_width'] / metrics['xscale'], 100, 80)
            t(80 * metrics['cell_width'] / metrics['xscale'] + metrics['width'], 100, 80, incremental=True)
            t(1217, 100, 1217, unit='pixels')
            t(1217 + metrics['width'], 100, 1217, unit='pixels', incremental=True)

    @unittest.skipIf(is_macos, 'Skipping test on macOS because glfw-cocoa.so is not built with backend_utils')
    def test_utf_8_strndup(self):
        import ctypes

        from kitty.constants import glfw_path

        backend_utils = glfw_path('x11')
        lib = ctypes.CDLL(backend_utils)
        libc = ctypes.CDLL(None)

        class allocated_c_char_p(ctypes.c_char_p):
            def __del__(self):
                libc.free(self)

        utf_8_strndup = lib.utf_8_strndup
        utf_8_strndup.restype = allocated_c_char_p
        utf_8_strndup.argtypes = (ctypes.c_char_p, ctypes.c_size_t)

        def test(string):
            string_bytes = bytes(string, 'utf-8')
            prev_part_bytes = b''
            prev_length_bytes = -1
            for length in range(len(string) + 1):
                part = string[:length]
                part_bytes = bytes(part, 'utf-8')
                length_bytes = len(part_bytes)
                for length_bytes_2 in range(prev_length_bytes + 1, length_bytes):
                    self.ae(utf_8_strndup(string_bytes, length_bytes_2).value, prev_part_bytes)
                self.ae(utf_8_strndup(string_bytes, length_bytes).value, part_bytes)
                prev_part_bytes = part_bytes
                prev_length_bytes = length_bytes
            self.ae(utf_8_strndup(string_bytes, len(string_bytes) + 1).value, string_bytes)  # Try to go one character after the end of the string

        self.ae(utf_8_strndup(None, 2).value, None)
        self.ae(utf_8_strndup(b'', 2).value, b'')

        test('ö')
        test('>a<')
        test('>ä<')
        test('>ế<')
        test('>𐍈<')
        test('∮ E⋅da = Q,  n → ∞, 𐍈∑ f(i) = ∏ g(i)')
        self.ae(utf_8_strndup(b'\xf0\x9f\x98\xb8', 3).value, b'')
        self.ae(utf_8_strndup(b'\xc3\xb6\xf0\x9f\x98\xb8', 4).value, b'\xc3\xb6')
