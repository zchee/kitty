#!/usr/bin/env python
# License: GPL v3

import ctypes
import os
import struct
import sys
import unittest
import zlib
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


class MetalTintUniforms(ctypes.Structure):
    _fields_ = [
        ('edges', ctypes.c_float * 4),
        ('color', ctypes.c_float * 4),
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
                'metal_renderer_prepare_tint_uniforms_for_tests',
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
            cls.lib.metal_renderer_prepare_tint_uniforms_for_tests.argtypes = [
                ctypes.c_uint32,
                ctypes.c_float,
                ctypes.POINTER(MetalTintUniforms),
            ]
            cls.lib.metal_renderer_prepare_tint_uniforms_for_tests.restype = None
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

    @staticmethod
    def _srgb_channel_to_linear(channel: int) -> float:
        value = channel / 255.0
        if value <= 0.04045:
            return value / 12.92
        return ((value + 0.055) / 1.055) ** 2.4

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

    def test_prepare_tint_uniforms_converts_linear_premultiplied(self) -> None:
        uniforms = MetalTintUniforms()
        background = 0x336699
        tint_amount = 0.5
        self.lib.metal_renderer_prepare_tint_uniforms_for_tests(
            ctypes.c_uint32(background),
            ctypes.c_float(tint_amount),
            ctypes.byref(uniforms),
        )
        for actual, expected in zip(uniforms.edges, (-1.0, 1.0, 1.0, -1.0)):
            self.assertAlmostEqual(actual, expected, places=6)
        channels = [
            (background >> 16) & 0xFF,
            (background >> 8) & 0xFF,
            background & 0xFF,
        ]
        expected_color = [self._srgb_channel_to_linear(value) * tint_amount for value in channels]
        expected_color.append(tint_amount)
        for actual, expected in zip(uniforms.color, expected_color):
            self.assertAlmostEqual(actual, expected, places=6)

    def test_prepare_tint_uniforms_clamps_amount(self) -> None:
        uniforms = MetalTintUniforms()
        self.lib.metal_renderer_prepare_tint_uniforms_for_tests(
            ctypes.c_uint32(0xFFFFFF),
            ctypes.c_float(3.0),
            ctypes.byref(uniforms),
        )
        for component in uniforms.color[:3]:
            self.assertAlmostEqual(component, 1.0, places=6)
        self.assertAlmostEqual(uniforms.color[3], 1.0, places=6)

        uniforms = MetalTintUniforms()
        self.lib.metal_renderer_prepare_tint_uniforms_for_tests(
            ctypes.c_uint32(0x112233),
            ctypes.c_float(-0.25),
            ctypes.byref(uniforms),
        )
        for component in uniforms.color:
            self.assertAlmostEqual(component, 0.0, places=6)

    def test_prepare_tint_uniforms_handles_multiple_backgrounds(self) -> None:
        cases: dict[int, list[float]] = {
            0x000000: [0.0, 0.25, 0.5, 1.0],
            0x336699: [0.0, 0.4, 0.8],
            0xFFAA33: [0.0, 0.5, 1.0],
        }
        tolerance = 1e-6
        for background, tint_levels in cases.items():
            previous_expected: list[float] | None = None
            for tint_amount in tint_levels:
                uniforms = MetalTintUniforms()
                self.lib.metal_renderer_prepare_tint_uniforms_for_tests(
                    ctypes.c_uint32(background),
                    ctypes.c_float(tint_amount),
                    ctypes.byref(uniforms),
                )
                with self.subTest(background=f"0x{background:06X}", tint=tint_amount):
                    for actual, expected in zip(uniforms.edges, (-1.0, 1.0, 1.0, -1.0)):
                        self.assertAlmostEqual(actual, expected, places=6)
                    clamped = max(0.0, min(tint_amount, 1.0))
                    expected_components = [
                        self._srgb_channel_to_linear((background >> shift) & 0xFF) * clamped
                        for shift in (16, 8, 0)
                    ]
                    expected_components.append(clamped)
                    for index, (actual, expected) in enumerate(zip(uniforms.color, expected_components)):
                        self.assertAlmostEqual(
                            actual,
                            expected,
                            places=6,
                            msg=f"component {index} mismatch for tint {tint_amount}",
                        )
                    if previous_expected is not None:
                        for idx in range(4):
                            self.assertGreaterEqual(
                                expected_components[idx],
                                previous_expected[idx] - tolerance,
                                msg=f"component {idx} should not decrease as tint increases for background 0x{background:06X}",
                            )
                    previous_expected = expected_components

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

class TestMetalBackgroundTintRendering(BaseTest):
    @classmethod
    def setUpClass(cls) -> None:
        super().setUpClass()
        if not ffi.has_metal:
            raise unittest.SkipTest('Metal backend not available')
        cls.lib = ctypes.CDLL(fast_data_types.__file__)
        required_symbols = (
            'metal_renderer_copy_captured_frame_for_tests',
            'metal_renderer_debug_clear_captured_frame_for_tests',
        )
        if not all(hasattr(cls.lib, symbol) for symbol in required_symbols):
            raise unittest.SkipTest('Metal capture helpers unavailable')

    def setUp(self) -> None:
        super().setUp()
        if sys.platform != 'darwin':
            self.skipTest('Metal tint rendering requires macOS')
        if os.environ.get('KITTY_ENABLE_METAL_GUI_TESTS') not in {'1', 'true', 'TRUE'}:
            self.skipTest('Metal tint rendering requires KITTY_ENABLE_METAL_GUI_TESTS=1 in GUI session')
        self._ensure_ns_application_loaded()
        if hasattr(ffi.lib, 'metal_renderer_preflight'):
            reason = ctypes.c_char_p()
            if not ffi.lib.metal_renderer_preflight(ctypes.byref(reason)):
                message = reason.value.decode('utf-8') if reason.value else 'Metal renderer preflight failed'
                self.skipTest(message)
        required = (
            hasattr(ffi.lib, 'state_debug_add_os_window_for_tests')
            and hasattr(ffi.lib, 'remove_os_window')
            and hasattr(ffi.lib, 'handle_for_window_id')
            and hasattr(ffi.lib, 'renderer_backend_attach_window')
            and hasattr(ffi.lib, 'renderer_backend_begin_frame')
            and hasattr(ffi.lib, 'renderer_backend_render')
            and hasattr(ffi.lib, 'renderer_backend_present')
            and hasattr(ffi.lib, 'renderer_backend_shutdown_active')
            and hasattr(ffi.lib, 'get_os_window_struct_for_tests')
        )
        if not required:
            self.skipTest('Required renderer helpers unavailable')
        self.addCleanup(ffi.reset)
        ffi.reset()
        renderer_backend_select('metal')
        self.lib.metal_renderer_debug_clear_captured_frame_for_tests()

    @staticmethod
    def _ensure_ns_application_loaded() -> None:
        try:
            appkit = ctypes.CDLL('/System/Library/Frameworks/AppKit.framework/AppKit')
        except OSError:
            return
        try:
            load_func = getattr(appkit, 'NSApplicationLoad')
        except AttributeError:
            return
        load_func.restype = ctypes.c_bool
        load_func.argtypes = []
        load_func()

    @staticmethod
    def _png_chunk(tag: bytes, payload: bytes) -> bytes:
        length = struct.pack(">I", len(payload))
        crc = struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF)
        return length + tag + payload + crc

    def _create_metal_os_window(self) -> int:
        def get_window_size(
            cell_width: int,
            cell_height: int,
            dpi_x: float,
            dpi_y: float,
            xscale: float,
            yscale: float,
        ) -> tuple[int, int]:
            safe_x = xscale if xscale > 0 else 1.0
            safe_y = yscale if yscale > 0 else 1.0
            width = max(int(cell_width * 80 / safe_x), 640)
            height = max(int(cell_height * 24 / safe_y), 480)
            return width, height

        def pre_show_callback(_handle: int) -> None:
            return None

        try:
            return fast_data_types.create_os_window(
                get_window_size,
                pre_show_callback,
                'Metal Tint Test',
                'kitty',
                'kitty',
            )
        except Exception as exc:
            self.skipTest(f'Unable to create Metal test window: {exc}')

    @classmethod
    def _solid_rgba_png(cls, width: int, height: int, color: tuple[int, int, int, int]) -> bytes:
        r, g, b, a = color
        row = bytes([r, g, b, a] * width)
        raw = b''.join(b'\x00' + row for _ in range(height))
        ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
        return (
            b"\x89PNG\r\n\x1a\n"
            + cls._png_chunk(b'IHDR', ihdr)
            + cls._png_chunk(b'IDAT', zlib.compress(raw, 9))
            + cls._png_chunk(b'IEND', b'')
        )

    def _render_and_capture_pixel(
        self,
        tint_value: float,
        background_color: int,
        *,
        background_image: bool = True,
    ) -> tuple[int, int, int, int]:
        self.set_options({'background_tint': tint_value})
        options_obj = fast_data_types.get_options()
        fast_data_types.set_options(options_obj, False, False, False, False, True)
        os_window_id = self._create_metal_os_window()
        self.assertGreater(os_window_id, 0)
        remove_os_window = ffi.lib.remove_os_window
        remove_os_window.argtypes = [ctypes.c_ulonglong]
        remove_os_window.restype = ctypes.c_bool
        def cleanup_window() -> None:
            fast_data_types.set_background_image(None, (os_window_id,), True)
            remove_os_window(ctypes.c_ulonglong(os_window_id))
        self.addCleanup(cleanup_window)

        tab_id = fast_data_types.add_tab(os_window_id)
        window_id = fast_data_types.add_window(os_window_id, tab_id, 'tint-test')

        if background_image:
            png = self._solid_rgba_png(2, 2, (255, 255, 255, 255))
            fast_data_types.set_background_image(
                "memory.png",
                (os_window_id,),
                True,
                "tiled",
                png,
                False,
                None,
                None,
            )

        os_window_ptr = ffi.lib.get_os_window_struct_for_tests(ctypes.c_ulonglong(os_window_id))
        window_handle = ffi.lib.handle_for_window_id(ctypes.c_ulonglong(os_window_id))
        if not window_handle:
            self.skipTest('Metal tint rendering requires an active Cocoa window handle')

        config = ffi.RendererWindowConfig()
        config.is_first_window = True
        config.wants_transparency = False
        config.background_opacity = 1.0
        config.background_color = background_color if not background_image else 0
        if not ffi.lib.renderer_backend_attach_window(window_handle, ctypes.byref(config)):
            self.skipTest('Metal renderer failed to attach to window')

        frame_params = ffi.RendererFrameParams()
        frame_params.frame_start_time = 0.0
        frame_params.vsync_enabled = True
        if not ffi.lib.renderer_backend_begin_frame(window_handle, ctypes.byref(frame_params)):
            self.skipTest('Metal renderer begin_frame rejected window')

        render_params = ffi.RendererRenderParams()
        render_params.os_window = ctypes.c_void_p(os_window_ptr)
        render_params.active_window_id = window_id
        render_params.active_window_bg = ctypes.c_uint32(background_color)
        render_params.num_visible_windows = 1
        render_params.all_windows_have_same_bg = True
        if not ffi.lib.renderer_backend_render(window_handle, ctypes.byref(render_params)):
            self.skipTest('Metal renderer render failed')

        present_params = ffi.RendererPresentParams()
        present_params.blocking = True
        present_params.capture_framebuffer = True
        if not ffi.lib.renderer_backend_present(window_handle, ctypes.byref(present_params)):
            self.skipTest('Metal renderer present failed')

        info = MetalCapturedFrameDebugInfo()
        if not self.lib.metal_renderer_copy_captured_frame_for_tests(ctypes.byref(info)):
            self.skipTest('Metal renderer did not provide captured frame')
        if not info.pixels or info.width == 0 or info.height == 0 or info.bytes_per_row == 0:
            self.skipTest('Metal renderer returned empty framebuffer')
        size = info.bytes_per_row * info.height
        if size <= 0:
            self.skipTest('Metal renderer reported invalid framebuffer size')
        data = ctypes.string_at(info.pixels, size)
        pixel = tuple(data[:4])
        self.lib.metal_renderer_debug_clear_captured_frame_for_tests()
        ffi.lib.renderer_backend_shutdown_active()
        return pixel

    @staticmethod
    def _expected_tinted_pixel(background: int, tint: float) -> tuple[int, int, int, int]:
        def srgb_to_linear(channel: int) -> float:
            value = channel / 255.0
            if value <= 0.04045:
                return value / 12.92
            return ((value + 0.055) / 1.055) ** 2.4

        def channel_mix(channel: int) -> int:
            base = channel / 255.0
            tinted = srgb_to_linear(channel) * tint
            mixed = tinted + base * (1.0 - tint)
            mixed = max(0.0, min(1.0, mixed))
            return int(round(mixed * 255.0))

        r = (background >> 16) & 0xFF
        g = (background >> 8) & 0xFF
        b = background & 0xFF
        return channel_mix(r), channel_mix(g), channel_mix(b), 255

    def test_background_tint_changes_captured_frame(self) -> None:
        background = 0x006400  # dark green
        baseline = self._render_and_capture_pixel(0.0, background)
        tinted = self._render_and_capture_pixel(0.5, background)
        self.assertNotEqual(tinted, baseline, 'Tinted frame should differ from baseline')
        # Expect tint to push the pixel towards green.
        self.assertGreater(tinted[1], tinted[0])
        self.assertGreater(tinted[1], tinted[2])

    def test_background_tint_captures_multiple_combinations(self) -> None:
        cases = {
            0x006400: {'dominant': 1},
            0x002874: {'dominant': 2},
            0x8A1B10: {'dominant': 0},
        }
        tint_levels = (0.25, 0.5, 0.75)
        for background, meta in cases.items():
            baseline_pixel = self._render_and_capture_pixel(0.0, background)
            with self.subTest(background=f"0x{background:06X}", tint=0.0):
                self._assert_valid_baseline(baseline_pixel)
            for tint_value in tint_levels:
                tinted_pixel = self._render_and_capture_pixel(tint_value, background)
                with self.subTest(background=f"0x{background:06X}", tint=tint_value):
                    self._assert_capture_progress(baseline_pixel, tinted_pixel, meta['dominant'])

    @staticmethod
    def _assert_valid_baseline(pixel: tuple[int, int, int, int]) -> None:
        # Baseline should be opaque white (from background image), tolerating minor deviations.
        for channel in pixel[:3]:
            if channel < 240:
                raise AssertionError(f'Baseline channel unexpectedly low: {channel}')
        if pixel[3] < 240:
            raise AssertionError(f'Baseline alpha unexpectedly low: {pixel[3]}')

    @staticmethod
    def _assert_capture_progress(
        baseline: tuple[int, int, int, int],
        tinted: tuple[int, int, int, int],
        dominant_channel: int,
    ) -> None:
        if tinted == baseline:
            raise AssertionError('Tinted capture matches baseline unexpectedly')
        for idx in range(3):
            if tinted[idx] > baseline[idx]:
                raise AssertionError(f'Channel {idx} increased relative to baseline')
        diffs = [baseline[i] - tinted[i] for i in range(3)]
        max_diff = max(diffs)
        if max_diff <= 0:
            raise AssertionError('No channel changed relative to baseline')
        # Dominant channel should reflect strongest shift.
        # Allow ties by enforcing within small tolerance.
        tolerance = 5
        if diffs[dominant_channel] + tolerance < max_diff:
            raise AssertionError(
                f'Dominant channel {dominant_channel} did not exhibit strongest tint influence'
            )

    def test_initial_blank_frame_uses_active_window_background(self) -> None:
        background = 0x224466
        pixel = self._render_and_capture_pixel(0.0, background, background_image=False)
        expected = (
            (background >> 16) & 0xFF,
            (background >> 8) & 0xFF,
            background & 0xFF,
            255,
        )
        for actual, exp in zip(pixel, expected):
            self.assertLessEqual(abs(actual - exp), 1, f'channel mismatch: got {pixel} expected {expected}')

    def test_background_tint_without_image_uses_clear_load_action(self) -> None:
        background = 0x224466
        tint = 0.5
        pixel = self._render_and_capture_pixel(tint, background, background_image=False)
        expected = self._expected_tinted_pixel(background, tint)
        for idx, (actual, exp) in enumerate(zip(pixel, expected)):
            tolerance = 2 if idx < 3 else 0
            self.assertLessEqual(
                abs(actual - exp),
                tolerance,
                f'channel {idx} mismatch: got {pixel} expected {expected}',
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
