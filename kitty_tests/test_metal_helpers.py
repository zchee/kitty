#!/usr/bin/env python
# License: GPL v3

import ctypes
from typing import Sequence

import kitty.fast_data_types as fast_data_types

from . import BaseTest


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

    def setUp(self) -> None:
        super().setUp()
        if not self.has_helpers:
            self.skipTest('Metal helper exports not available')
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
