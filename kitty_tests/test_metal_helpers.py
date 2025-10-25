#!/usr/bin/env python
# License: GPL v3

import ctypes
import unittest
import sys
from typing import Sequence

import kitty.fast_data_types as fast_data_types

from . import BaseTest
from .renderer_backend import ffi, renderer_backend_current, renderer_backend_select


class MetalBorderUniforms(ctypes.Structure):
    _fields_ = [
        ('colors', ctypes.c_uint32 * 9),
        ('background_opacity', ctypes.c_float),
        ('_pad0', ctypes.c_float),
        ('_pad1', ctypes.c_float),
    ]


class MetalTrailUniforms(ctypes.Structure):
    _fields_ = [
        ('x_coords', ctypes.c_float * 4),
        ('y_coords', ctypes.c_float * 4),
        ('cursor_edge_x', ctypes.c_float * 2),
        ('cursor_edge_y', ctypes.c_float * 2),
        ('color', ctypes.c_uint32),
        ('opacity', ctypes.c_float),
        ('_pad0', ctypes.c_float),
        ('_pad1', ctypes.c_float),
    ]


class MetalGraphicsUniforms(ctypes.Structure):
    _fields_ = [
        ('src_rect', ctypes.c_float * 4),
        ('dest_rect', ctypes.c_float * 4),
        ('extra_alpha', ctypes.c_float),
        ('_pad0', ctypes.c_float),
        ('_pad1', ctypes.c_float),
        ('_pad2', ctypes.c_float),
    ]


class MetalGraphicsAlphaUniforms(ctypes.Structure):
    _fields_ = [
        ('src_rect', ctypes.c_float * 4),
        ('dest_rect', ctypes.c_float * 4),
        ('foreground_rgb', ctypes.c_float * 3),
        ('_pad0', ctypes.c_float),
        ('background_premul', ctypes.c_float * 4),
    ]


class MetalCapturedFrameDebugInfo(ctypes.Structure):
    _fields_ = [
        ('width', ctypes.c_uint32),
        ('height', ctypes.c_uint32),
        ('bytes_per_row', ctypes.c_uint32),
        ('pixels', ctypes.c_void_p),
    ]


class MetalWindowDebugState(ctypes.Structure):
    _fields_ = [
        ('frame_has_content', ctypes.c_bool),
        ('capture_valid', ctypes.c_bool),
        ('capture_width', ctypes.c_uint32),
        ('capture_height', ctypes.c_uint32),
        ('capture_bytes_per_row', ctypes.c_uint32),
        ('contents_scale', ctypes.c_float),
        ('drawable_width', ctypes.c_uint32),
        ('drawable_height', ctypes.c_uint32),
        ('layer_attached', ctypes.c_bool),
    ]


class MetalDrawParams(ctypes.Structure):
    _fields_ = [
        ('text_contrast', ctypes.c_float),
        ('text_gamma_adjustment', ctypes.c_float),
        ('decorations_count', ctypes.c_uint32),
        ('draw_background_mask', ctypes.c_uint32),
        ('draw_foreground', ctypes.c_uint32),
        ('extra_alpha', ctypes.c_float),
        ('viewport_scale_x', ctypes.c_float),
        ('viewport_scale_y', ctypes.c_float),
        ('viewport_origin_x', ctypes.c_float),
        ('viewport_origin_y', ctypes.c_float),
    ]


METAL_DRAW_BG_DEFAULT = 0x1
METAL_DRAW_BG_NON_DEFAULT = 0x2
METAL_DRAW_BG_BOTH = METAL_DRAW_BG_DEFAULT | METAL_DRAW_BG_NON_DEFAULT


class ImageRect(ctypes.Structure):
    _fields_ = [
        ('left', ctypes.c_float),
        ('top', ctypes.c_float),
        ('right', ctypes.c_float),
        ('bottom', ctypes.c_float),
    ]


class ImageRenderData(ctypes.Structure):
    _fields_ = [
        ('src_rect', ImageRect),
        ('dest_rect', ImageRect),
        ('texture_id', ctypes.c_uint32),
        ('group_count', ctypes.c_uint32),
        ('z_index', ctypes.c_int32),
        ('image_id', ctypes.c_uint64),
        ('ref_id', ctypes.c_uint64),
    ]


class TestMetalHelperFunctions(BaseTest):
    @classmethod
    def setUpClass(cls) -> None:
        super().setUpClass()
        cls.lib = ctypes.CDLL(fast_data_types.__file__)
        cls.has_helpers = all(
            hasattr(cls.lib, symbol)
            for symbol in (
                'metal_renderer_prepare_border_uniforms_for_tests',
                'metal_renderer_prepare_trail_uniforms_for_tests',
                'metal_cell_draw_flag_defaults',
                'metal_renderer_pack_graphics_uniforms_for_tests',
                'metal_renderer_pack_graphics_alpha_uniforms_for_tests',
                'metal_renderer_apply_draw_params_for_tests',
                'renderer_shared_visual_bell_alpha_scale_for_tests',
                'metal_renderer_copy_captured_frame_for_tests',
                'metal_renderer_debug_set_captured_frame_for_tests',
                'metal_renderer_debug_clear_captured_frame_for_tests',
                'metal_renderer_debug_seed_window_state_for_tests',
                'metal_renderer_debug_get_window_state_for_tests',
                'metal_renderer_debug_set_window_state_for_tests',
                'metal_renderer_debug_reset_capture_state_for_tests',
                'metal_renderer_blank_drawable',
            )
        )
        if cls.has_helpers:
            cls.lib.metal_renderer_prepare_border_uniforms_for_tests.argtypes = [
                ctypes.c_uint32,
                ctypes.c_uint32,
                ctypes.c_uint32,
                ctypes.c_uint32,
                ctypes.c_uint32,
                ctypes.c_uint32,
                ctypes.c_uint32,
                ctypes.c_uint32,
                ctypes.c_float,
                ctypes.POINTER(MetalBorderUniforms),
            ]
            cls.lib.metal_renderer_prepare_border_uniforms_for_tests.restype = None
            cls.lib.metal_renderer_prepare_trail_uniforms_for_tests.argtypes = [
                ctypes.POINTER(ctypes.c_float),
                ctypes.POINTER(ctypes.c_float),
                ctypes.POINTER(ctypes.c_float),
                ctypes.POINTER(ctypes.c_float),
                ctypes.c_uint32,
                ctypes.c_float,
                ctypes.POINTER(MetalTrailUniforms),
            ]
            cls.lib.metal_renderer_prepare_trail_uniforms_for_tests.restype = None
            cls.lib.metal_cell_draw_flag_defaults.argtypes = []
            cls.lib.metal_cell_draw_flag_defaults.restype = ctypes.c_uint32
            cls.lib.metal_renderer_pack_graphics_uniforms_for_tests.argtypes = [
                ctypes.POINTER(ImageRenderData),
                ctypes.c_float,
                ctypes.POINTER(MetalGraphicsUniforms),
            ]
            cls.lib.metal_renderer_pack_graphics_uniforms_for_tests.restype = None
            cls.lib.metal_renderer_pack_graphics_alpha_uniforms_for_tests.argtypes = [
                ctypes.POINTER(ImageRenderData),
                ctypes.c_float,
                ctypes.c_float,
                ctypes.c_float,
                ctypes.c_float,
                ctypes.c_float,
                ctypes.c_float,
                ctypes.c_float,
                ctypes.c_float,
                ctypes.POINTER(MetalGraphicsAlphaUniforms),
            ]
            cls.lib.metal_renderer_pack_graphics_alpha_uniforms_for_tests.restype = None
            cls.lib.metal_renderer_apply_draw_params_for_tests.argtypes = [
                ctypes.POINTER(MetalDrawParams),
                ctypes.c_uint32,
                ctypes.c_bool,
            ]
            cls.lib.metal_renderer_apply_draw_params_for_tests.restype = None
            cls.lib.renderer_shared_visual_bell_alpha_scale_for_tests.argtypes = [
                ctypes.c_uint32,
                ctypes.c_float,
            ]
            cls.lib.renderer_shared_visual_bell_alpha_scale_for_tests.restype = ctypes.c_float
            cls.lib.metal_renderer_copy_captured_frame_for_tests.argtypes = [
                ctypes.POINTER(MetalCapturedFrameDebugInfo),
            ]
            cls.lib.metal_renderer_copy_captured_frame_for_tests.restype = ctypes.c_bool
            cls.lib.metal_renderer_debug_set_captured_frame_for_tests.argtypes = [
                ctypes.POINTER(ctypes.c_uint8),
                ctypes.c_uint32,
                ctypes.c_uint32,
                ctypes.c_uint32,
                ctypes.c_bool,
            ]
            cls.lib.metal_renderer_debug_set_captured_frame_for_tests.restype = ctypes.c_bool
            cls.lib.metal_renderer_debug_clear_captured_frame_for_tests.argtypes = []
            cls.lib.metal_renderer_debug_clear_captured_frame_for_tests.restype = None
            cls.lib.metal_renderer_debug_seed_window_state_for_tests.argtypes = [
                ctypes.c_void_p,
            ]
            cls.lib.metal_renderer_debug_seed_window_state_for_tests.restype = None
            cls.lib.metal_renderer_debug_get_window_state_for_tests.argtypes = [
                ctypes.c_void_p,
                ctypes.POINTER(MetalWindowDebugState),
            ]
            cls.lib.metal_renderer_debug_get_window_state_for_tests.restype = ctypes.c_bool
            cls.lib.metal_renderer_debug_set_window_state_for_tests.argtypes = [
                ctypes.c_void_p,
                ctypes.POINTER(MetalWindowDebugState),
            ]
            cls.lib.metal_renderer_debug_set_window_state_for_tests.restype = None
            cls.lib.metal_renderer_debug_reset_capture_state_for_tests.argtypes = [
                ctypes.c_void_p,
                ctypes.c_bool,
            ]
            cls.lib.metal_renderer_debug_reset_capture_state_for_tests.restype = None
            cls.lib.metal_renderer_blank_drawable.argtypes = [
                ctypes.c_void_p,
                ctypes.c_uint32,
                ctypes.c_float,
            ]
            cls.lib.metal_renderer_blank_drawable.restype = ctypes.c_bool

    def setUp(self) -> None:
        super().setUp()
        if not self.has_helpers:
            self.skipTest('Metal helper exports not available')
        self.addCleanup(ffi.reset)
        ffi.reset()
        previous = renderer_backend_current()
        renderer_backend_select('metal')
        self.addCleanup(renderer_backend_select, previous)
        self.lib.metal_renderer_debug_clear_captured_frame_for_tests()

    def tearDown(self) -> None:
        if self.has_helpers:
            self.lib.metal_renderer_debug_clear_captured_frame_for_tests()
        super().tearDown()

    def _make_draw_params(self, mask: int, draw_fg: int = 1) -> MetalDrawParams:
        params = MetalDrawParams()
        params.text_contrast = 1.25
        params.text_gamma_adjustment = 0.85
        params.decorations_count = 7
        params.draw_background_mask = mask
        params.draw_foreground = draw_fg
        params.extra_alpha = 0.5
        params.viewport_scale_x = 0.9
        params.viewport_scale_y = 1.1
        params.viewport_origin_x = -0.2
        params.viewport_origin_y = 0.3
        return params

    def test_prepare_border_uniforms_populates_expected_colors(self) -> None:
        uniforms = MetalBorderUniforms()
        inputs = {
            'default_bg': 0x102030,
            'active': 0x223344,
            'inactive': 0x556677,
            'bell': 0x778899,
            'tab_bg': 0x445566,
            'tab_margin': 0x8899AA,
            'edge_left': 0x123456,
            'edge_right': 0xABCDEF,
            'opacity': 0.42,
        }
        self.lib.metal_renderer_prepare_border_uniforms_for_tests(  # type: ignore[arg-type]
            inputs['default_bg'],
            inputs['active'],
            inputs['inactive'],
            inputs['bell'],
            inputs['tab_bg'],
            inputs['tab_margin'],
            inputs['edge_left'],
            inputs['edge_right'],
            ctypes.c_float(inputs['opacity']),
            ctypes.byref(uniforms),
        )
        expected = [
            inputs['default_bg'],
            inputs['active'],
            inputs['inactive'],
            0,
            inputs['bell'],
            inputs['tab_bg'],
            inputs['tab_margin'],
            inputs['edge_left'],
            inputs['edge_right'],
        ]
        self.assertEqual(list(uniforms.colors), expected)
        self.assertAlmostEqual(uniforms.background_opacity, inputs['opacity'], places=6)

    def test_prepare_trail_uniforms_writes_coordinates(self) -> None:
        uniforms = MetalTrailUniforms()

        def to_c_floats(values: Sequence[float]) -> ctypes.Array[ctypes.c_float]:
            arr = (ctypes.c_float * len(values))()
            arr[:] = values
            return arr

        x_coords = to_c_floats([0.1, 0.2, 0.3, 0.4])
        y_coords = to_c_floats([-0.5, -0.6, -0.7, -0.8])
        edge_x = to_c_floats([-0.25, 0.25])
        edge_y = to_c_floats([0.75, -0.75])
        color = 0xA0B1C2
        opacity = 0.73

        self.lib.metal_renderer_prepare_trail_uniforms_for_tests(  # type: ignore[arg-type]
            x_coords,
            y_coords,
            edge_x,
            edge_y,
            color,
            ctypes.c_float(opacity),
            ctypes.byref(uniforms),
        )
        for actual, expected in zip(uniforms.x_coords, [0.1, 0.2, 0.3, 0.4]):
            self.assertAlmostEqual(actual, expected, places=6)
        for actual, expected in zip(uniforms.y_coords, [-0.5, -0.6, -0.7, -0.8]):
            self.assertAlmostEqual(actual, expected, places=6)
        for actual, expected in zip(uniforms.cursor_edge_x, [-0.25, 0.25]):
            self.assertAlmostEqual(actual, expected, places=6)
        for actual, expected in zip(uniforms.cursor_edge_y, [0.75, -0.75]):
            self.assertAlmostEqual(actual, expected, places=6)
        self.assertEqual(uniforms.color, color)
        self.assertAlmostEqual(uniforms.opacity, opacity, places=6)

    def test_draw_flag_defaults(self) -> None:
        defaults = self.lib.metal_cell_draw_flag_defaults()
        self.assertEqual(defaults & 0b001, 0b001)
        self.assertEqual(defaults & 0b010, 0b010)
        self.assertEqual(defaults & 0b100, 0b100)

    def test_visual_bell_alpha_scale(self) -> None:
        # Dark color => attenuation 0.4
        flash = 0x202020
        intensity = 0.5
        alpha = self.lib.renderer_shared_visual_bell_alpha_scale_for_tests(flash, ctypes.c_float(intensity))
        self.assertAlmostEqual(alpha, intensity * 0.4, places=6)
        # Bright color => attenuation 0.6
        bright = 0xFFFFFF
        alpha_bright = self.lib.renderer_shared_visual_bell_alpha_scale_for_tests(bright, ctypes.c_float(intensity))
        self.assertAlmostEqual(alpha_bright, intensity * 0.6, places=6)

    def test_pack_graphics_uniforms(self) -> None:
        data = ImageRenderData()
        data.src_rect = ImageRect(0.1, 0.2, 0.3, 0.4)
        data.dest_rect = ImageRect(-0.5, 0.75, 0.25, -0.25)
        data.texture_id = 42
        data.group_count = 1
        data.z_index = -5
        data.image_id = 7
        data.ref_id = 9

        uniforms = MetalGraphicsUniforms()
        extra_alpha = 0.35
        self.lib.metal_renderer_pack_graphics_uniforms_for_tests(  # type: ignore[arg-type]
            ctypes.byref(data),
            ctypes.c_float(extra_alpha),
            ctypes.byref(uniforms),
        )
        self.assertAlmostEqual(uniforms.src_rect[0], 0.1, places=6)
        self.assertAlmostEqual(uniforms.src_rect[1], 0.2, places=6)
        self.assertAlmostEqual(uniforms.src_rect[2], 0.3, places=6)
        self.assertAlmostEqual(uniforms.src_rect[3], 0.4, places=6)
        self.assertAlmostEqual(uniforms.dest_rect[0], -0.5, places=6)
        self.assertAlmostEqual(uniforms.dest_rect[1], 0.75, places=6)
        self.assertAlmostEqual(uniforms.dest_rect[2], 0.25, places=6)
        self.assertAlmostEqual(uniforms.dest_rect[3], -0.25, places=6)
        self.assertAlmostEqual(uniforms.extra_alpha, extra_alpha, places=6)

    def test_pack_graphics_alpha_uniforms(self) -> None:
        data = ImageRenderData()
        data.src_rect = ImageRect(0.0, 0.0, 1.0, 1.0)
        data.dest_rect = ImageRect(-0.5, 0.5, 0.5, -0.5)
        data.texture_id = 9
        data.group_count = 1

        uniforms = MetalGraphicsAlphaUniforms()
        fg = (0.2, 0.4, 0.6)
        bg = (0.1, 0.3, 0.5, 0.8)
        extra_alpha = 0.75

        self.lib.metal_renderer_pack_graphics_alpha_uniforms_for_tests(  # type: ignore[arg-type]
            ctypes.byref(data),
            ctypes.c_float(fg[0]),
            ctypes.c_float(fg[1]),
            ctypes.c_float(fg[2]),
            ctypes.c_float(bg[0]),
            ctypes.c_float(bg[1]),
            ctypes.c_float(bg[2]),
            ctypes.c_float(bg[3]),
            ctypes.c_float(extra_alpha),
            ctypes.byref(uniforms),
        )
        self.assertAlmostEqual(list(uniforms.src_rect), [0.0, 0.0, 1.0, 1.0])
        self.assertAlmostEqual(list(uniforms.dest_rect), [-0.5, 0.5, 0.5, -0.5])
        expected_fg = [component * extra_alpha for component in fg]
        for actual, expected in zip(uniforms.foreground_rgb, expected_fg):
            self.assertAlmostEqual(actual, expected, places=6)
        expected_bg = [component * extra_alpha for component in bg]
        for actual, expected in zip(uniforms.background_premul, expected_bg):
            self.assertAlmostEqual(actual, expected, places=6)

    def test_apply_draw_params_preserves_effect_flag_for_default_pass(self) -> None:
        defaults = self.lib.metal_cell_draw_flag_defaults()
        params = self._make_draw_params(defaults)
        self.lib.metal_renderer_apply_draw_params_for_tests(ctypes.byref(params), METAL_DRAW_BG_DEFAULT, True)
        preserved = defaults & ~METAL_DRAW_BG_BOTH
        self.assertEqual(params.draw_background_mask, preserved | METAL_DRAW_BG_DEFAULT)
        self.assertEqual(params.draw_foreground, 1)
        self.assertAlmostEqual(params.text_contrast, 1.25)

    def test_apply_draw_params_sets_non_default_mask_and_zeroes_foreground(self) -> None:
        defaults = self.lib.metal_cell_draw_flag_defaults()
        params = self._make_draw_params(defaults, draw_fg=1)
        self.lib.metal_renderer_apply_draw_params_for_tests(ctypes.byref(params), METAL_DRAW_BG_NON_DEFAULT, False)
        preserved = defaults & ~METAL_DRAW_BG_BOTH
        self.assertEqual(params.draw_background_mask, preserved | METAL_DRAW_BG_NON_DEFAULT)
        self.assertEqual(params.draw_foreground, 0)

    def test_apply_draw_params_strips_unknown_background_bits(self) -> None:
        defaults = self.lib.metal_cell_draw_flag_defaults()
        params = self._make_draw_params(defaults)
        noisy_mask = METAL_DRAW_BG_BOTH | 0x14
        self.lib.metal_renderer_apply_draw_params_for_tests(ctypes.byref(params), noisy_mask, True)
        preserved = defaults & ~METAL_DRAW_BG_BOTH
        self.assertEqual(params.draw_background_mask, preserved | METAL_DRAW_BG_BOTH)
        self.assertEqual(params.draw_foreground, 1)

    def test_copy_captured_frame_reports_absence(self) -> None:
        info = MetalCapturedFrameDebugInfo()
        result = self.lib.metal_renderer_copy_captured_frame_for_tests(ctypes.byref(info))
        self.assertFalse(result)
        self.assertEqual(info.width, 0)
        self.assertEqual(info.height, 0)
        self.assertEqual(info.bytes_per_row, 0)
        self.assertEqual(info.pixels, None)

    def test_debug_set_captured_frame_converts_bgra(self) -> None:
        src = (ctypes.c_uint8 * 8)(
            0x10,
            0x20,
            0x30,
            0x40,
            0x50,
            0x60,
            0x70,
            0x80,
        )
        ok = self.lib.metal_renderer_debug_set_captured_frame_for_tests(  # type: ignore[arg-type]
            src,
            ctypes.c_uint32(2),
            ctypes.c_uint32(1),
            ctypes.c_uint32(8),
            ctypes.c_bool(True),
        )
        self.assertTrue(ok)
        info = MetalCapturedFrameDebugInfo()
        self.assertTrue(self.lib.metal_renderer_copy_captured_frame_for_tests(ctypes.byref(info)))
        self.assertEqual((info.width, info.height, info.bytes_per_row), (2, 1, 8))
        data = ctypes.string_at(info.pixels, info.bytes_per_row * info.height)
        self.assertEqual(list(data[:4]), [0x30, 0x20, 0x10, 0x40])
        self.assertEqual(list(data[4:8]), [0x70, 0x60, 0x50, 0x80])

    def test_debug_set_captured_frame_preserves_rgba(self) -> None:
        src = (ctypes.c_uint8 * 8)(
            0x01,
            0x02,
            0x03,
            0x04,
            0x05,
            0x06,
            0x07,
            0x08,
        )
        ok = self.lib.metal_renderer_debug_set_captured_frame_for_tests(  # type: ignore[arg-type]
            src,
            ctypes.c_uint32(2),
            ctypes.c_uint32(1),
            ctypes.c_uint32(8),
            ctypes.c_bool(False),
        )
        self.assertTrue(ok)
        info = MetalCapturedFrameDebugInfo()
        self.assertTrue(self.lib.metal_renderer_copy_captured_frame_for_tests(ctypes.byref(info)))
        data = ctypes.string_at(info.pixels, info.bytes_per_row * info.height)
        self.assertEqual(list(data[:8]), [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])

    def test_reset_capture_state_helper_clears_window_state(self) -> None:
        window = ctypes.c_void_p()
        self.lib.metal_renderer_debug_seed_window_state_for_tests(window)

        state = MetalWindowDebugState()
        state.frame_has_content = True
        state.capture_valid = True
        state.capture_width = 64
        state.capture_height = 32
        state.capture_bytes_per_row = 256
        self.lib.metal_renderer_debug_set_window_state_for_tests(window, ctypes.byref(state))

        sample = (ctypes.c_uint8 * 4)(0xAA, 0xBB, 0xCC, 0xDD)
        self.assertTrue(
            self.lib.metal_renderer_debug_set_captured_frame_for_tests(  # type: ignore[arg-type]
                sample,
                ctypes.c_uint32(1),
                ctypes.c_uint32(1),
                ctypes.c_uint32(4),
                ctypes.c_bool(False),
            )
        )

        self.lib.metal_renderer_debug_reset_capture_state_for_tests(window, ctypes.c_bool(True))

        out_state = MetalWindowDebugState()
        self.assertTrue(
            self.lib.metal_renderer_debug_get_window_state_for_tests(window, ctypes.byref(out_state))
        )
        self.assertFalse(out_state.frame_has_content)
        self.assertFalse(out_state.capture_valid)
        self.assertEqual(out_state.capture_width, 0)
        self.assertEqual(out_state.capture_height, 0)
        self.assertEqual(out_state.capture_bytes_per_row, 0)

        info = MetalCapturedFrameDebugInfo()
        self.assertFalse(self.lib.metal_renderer_copy_captured_frame_for_tests(ctypes.byref(info)))

    @unittest.skipUnless(sys.platform == 'darwin', 'Metal backend only available on macOS')
    def test_blank_drawable_sets_frame_has_content(self) -> None:
        if not ffi.has_metal:
            self.skipTest('Metal backend not available')

        previous = renderer_backend_current()
        renderer_backend_select('metal')
        self.addCleanup(renderer_backend_select, previous)

        stub_window = ctypes.c_void_p(0xDEADBEEF)
        self.lib.metal_renderer_debug_enable_blank_stub_for_tests(True)
        self.addCleanup(
            lambda: self.lib.metal_renderer_debug_enable_blank_stub_for_tests(False)
        )
        self.lib.metal_renderer_debug_seed_window_state_for_tests(stub_window)

        initial = MetalWindowDebugState()
        self.assertTrue(
            self.lib.metal_renderer_debug_get_window_state_for_tests(
                stub_window, ctypes.byref(initial)
            )
        )
        self.assertFalse(initial.frame_has_content)

        color = ctypes.c_uint32(0x224466)
        opacity = ctypes.c_float(0.5)
        self.assertTrue(
            self.lib.metal_renderer_blank_drawable(stub_window, color, opacity)
        )

        updated = MetalWindowDebugState()
        self.assertTrue(
            self.lib.metal_renderer_debug_get_window_state_for_tests(
                stub_window, ctypes.byref(updated)
            )
        )
        self.assertTrue(updated.frame_has_content)

    def test_metal_windows_do_not_allocate_opengl_vaos(self) -> None:
        if sys.platform != 'darwin':
            self.skipTest('Metal backend not available on this platform')
        if not ffi.has_metal or not hasattr(ffi.lib, 'state_debug_add_os_window_for_tests'):
            self.skipTest('Metal backend helpers unavailable')

        previous = renderer_backend_current()
        renderer_backend_select('metal')
        self.addCleanup(renderer_backend_select, previous)

        create_os_window = ffi.lib.state_debug_add_os_window_for_tests
        create_os_window.argtypes = []
        create_os_window.restype = ctypes.c_ulonglong
        os_window_id = create_os_window()
        self.assertGreater(os_window_id, 0, 'Failed to create an OS window for Metal tests')

        remove_os_window = ffi.lib.remove_os_window
        remove_os_window.argtypes = [ctypes.c_ulonglong]
        remove_os_window.restype = ctypes.c_bool
        self.addCleanup(lambda: remove_os_window(ctypes.c_ulonglong(os_window_id)))

        tab_id = fast_data_types.add_tab(os_window_id)
        self.assertIsInstance(tab_id, int)

        window_id = fast_data_types.add_window(os_window_id, tab_id, 'metal-test')
        self.assertIsInstance(window_id, int)

        ffi.lib.state_debug_get_tab_bar_vao_for_tests.argtypes = [ctypes.c_ulonglong]
        ffi.lib.state_debug_get_tab_bar_vao_for_tests.restype = ctypes.c_longlong
        tab_bar_vao = ffi.lib.state_debug_get_tab_bar_vao_for_tests(ctypes.c_ulonglong(os_window_id))
        self.assertEqual(
            tab_bar_vao,
            -1,
            'Metal tab bar should not allocate an OpenGL VAO',
        )

        ffi.lib.state_debug_get_window_vao_for_tests.argtypes = [
            ctypes.c_ulonglong,
            ctypes.c_ulonglong,
            ctypes.c_ulonglong,
        ]
        ffi.lib.state_debug_get_window_vao_for_tests.restype = ctypes.c_longlong
        vao_idx = ffi.lib.state_debug_get_window_vao_for_tests(
            ctypes.c_ulonglong(os_window_id),
            ctypes.c_ulonglong(tab_id),
            ctypes.c_ulonglong(window_id),
        )
        self.assertEqual(
            vao_idx,
            -1,
            'Metal window render data should not allocate an OpenGL VAO',
        )


class TestMetalCaptureLifecycle(BaseTest):
    def setUp(self) -> None:
        super().setUp()
        if not ffi.has_metal:
            self.skipTest('Metal backend not available')
        required = (
            hasattr(ffi.lib, 'metal_renderer_debug_seed_window_state_for_tests')
            and hasattr(ffi.lib, 'metal_renderer_debug_get_window_state_for_tests')
            and hasattr(ffi.lib, 'metal_renderer_debug_set_window_state_for_tests')
            and hasattr(ffi.lib, 'metal_renderer_debug_reset_capture_state_for_tests')
        )
        if not required:
            self.skipTest('Metal debug helpers unavailable')
        self.addCleanup(ffi.reset)
        ffi.reset()
        previous = renderer_backend_current()
        renderer_backend_select('metal')
        self.addCleanup(renderer_backend_select, previous)
        ffi.lib.metal_renderer_debug_seed_window_state_for_tests(ctypes.c_void_p())
        ffi.lib.metal_renderer_debug_clear_captured_frame_for_tests()

    def test_resize_invalidates_capture_state(self) -> None:
        state = ffi.MetalWindowDebugState()
        state.frame_has_content = True
        state.capture_valid = True
        state.capture_width = 120
        state.capture_height = 60
        state.capture_bytes_per_row = 480
        state.contents_scale = 1.0
        state.drawable_width = 320
        state.drawable_height = 200
        state.layer_attached = False
        ffi.lib.metal_renderer_debug_set_window_state_for_tests(None, ctypes.byref(state))

        src = (ctypes.c_uint8 * 16)(*range(16))
        self.assertTrue(
            ffi.lib.metal_renderer_debug_set_captured_frame_for_tests(  # type: ignore[arg-type]
                src,
                ctypes.c_uint32(2),
                ctypes.c_uint32(2),
                ctypes.c_uint32(8),
                ctypes.c_bool(False),
            )
        )

        resize_params = ffi.RendererResizeParams(
            framebuffer_width=640,
            framebuffer_height=480,
            framebuffer_scale=2.0,
        )
        ffi.lib.renderer_backend_on_resize(None, ctypes.byref(resize_params))

        out_state = ffi.MetalWindowDebugState()
        self.assertTrue(
            ffi.lib.metal_renderer_debug_get_window_state_for_tests(None, ctypes.byref(out_state))
        )
        self.assertFalse(out_state.frame_has_content)
        self.assertFalse(out_state.capture_valid)
        self.assertEqual(out_state.capture_width, 0)
        self.assertEqual(out_state.capture_height, 0)
        self.assertEqual(out_state.capture_bytes_per_row, 0)
        self.assertAlmostEqual(out_state.contents_scale, 2.0)
        self.assertEqual(out_state.drawable_width, 640)
        self.assertEqual(out_state.drawable_height, 480)
        self.assertFalse(out_state.layer_attached)

        info = MetalCapturedFrameDebugInfo()
        self.assertFalse(ffi.lib.metal_renderer_copy_captured_frame_for_tests(ctypes.byref(info)))
