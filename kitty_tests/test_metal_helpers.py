#!/usr/bin/env python
# License: GPL v3

import ctypes
import sys
from typing import Sequence

import kitty.fast_data_types as fast_data_types

from . import BaseTest


class MetalBorderUniforms(ctypes.Structure):
    _fields_ = [
        ("colors", ctypes.c_uint32 * 9),
        ("background_opacity", ctypes.c_float),
        ("_pad0", ctypes.c_float),
        ("_pad1", ctypes.c_float),
    ]


class MetalTrailUniforms(ctypes.Structure):
    _fields_ = [
        ("x_coords", ctypes.c_float * 4),
        ("y_coords", ctypes.c_float * 4),
        ("cursor_edge_x", ctypes.c_float * 2),
        ("cursor_edge_y", ctypes.c_float * 2),
        ("color", ctypes.c_uint32),
        ("opacity", ctypes.c_float),
        ("_pad0", ctypes.c_float),
        ("_pad1", ctypes.c_float),
    ]


class TestMetalHelperFunctions(BaseTest):
    @classmethod
    def setUpClass(cls) -> None:
        super().setUpClass()
        cls.lib = ctypes.CDLL(fast_data_types.__file__)
        cls.has_helpers = all(
            hasattr(cls.lib, symbol)
            for symbol in (
                "metal_renderer_prepare_border_uniforms_for_tests",
                "metal_renderer_prepare_trail_uniforms_for_tests",
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

    def setUp(self) -> None:
        super().setUp()
        if not self.has_helpers:
            self.skipTest("Metal helper exports not available")

    def test_prepare_border_uniforms_populates_expected_colors(self) -> None:
        uniforms = MetalBorderUniforms()
        inputs = {
            "default_bg": 0x102030,
            "active": 0x223344,
            "inactive": 0x556677,
            "bell": 0x778899,
            "tab_bg": 0x445566,
            "tab_margin": 0x8899AA,
            "edge_left": 0x123456,
            "edge_right": 0xabcdef,
            "opacity": 0.42,
        }
        self.lib.metal_renderer_prepare_border_uniforms_for_tests(  # type: ignore[arg-type]
            inputs["default_bg"],
            inputs["active"],
            inputs["inactive"],
            inputs["bell"],
            inputs["tab_bg"],
            inputs["tab_margin"],
            inputs["edge_left"],
            inputs["edge_right"],
            ctypes.c_float(inputs["opacity"]),
            ctypes.byref(uniforms),
        )
        expected = [
            inputs["default_bg"],
            inputs["active"],
            inputs["inactive"],
            0,
            inputs["bell"],
            inputs["tab_bg"],
            inputs["tab_margin"],
            inputs["edge_left"],
            inputs["edge_right"],
        ]
        self.assertEqual(list(uniforms.colors), expected)
        self.assertAlmostEqual(uniforms.background_opacity, inputs["opacity"], places=6)

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
