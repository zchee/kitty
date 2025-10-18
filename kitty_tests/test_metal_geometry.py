#!/usr/bin/env python
# License: GPL v3 Copyright: 2025

import ctypes
import unittest

import kitty.fast_data_types as fast_data_types


class MetalViewportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.lib = ctypes.CDLL(fast_data_types.__file__)
        if hasattr(cls.lib, "metal_compute_viewport_params"):
            cls.lib.metal_compute_viewport_params.argtypes = [
                ctypes.c_uint,
                ctypes.c_uint,
                ctypes.c_uint,
                ctypes.c_uint,
                ctypes.c_uint,
                ctypes.c_uint,
                ctypes.POINTER(ctypes.c_float),
                ctypes.POINTER(ctypes.c_float),
                ctypes.POINTER(ctypes.c_float),
                ctypes.POINTER(ctypes.c_float),
            ]
            cls.lib.metal_compute_viewport_params.restype = ctypes.c_bool
        else:
            cls.lib = None

    def setUp(self) -> None:
        if self.lib is None:
            self.skipTest("Metal support not available in fast_data_types")

    def _call(self, fb_w: int, fb_h: int, left: int, top: int, right: int, bottom: int):
        sx = ctypes.c_float()
        sy = ctypes.c_float()
        ox = ctypes.c_float()
        oy = ctypes.c_float()
        ok = self.lib.metal_compute_viewport_params(
            fb_w,
            fb_h,
            left,
            top,
            right,
            bottom,
            ctypes.byref(sx),
            ctypes.byref(sy),
            ctypes.byref(ox),
            ctypes.byref(oy),
        )
        return ok, sx.value, sy.value, ox.value, oy.value

    def test_full_frame_transform_is_identity(self) -> None:
        ok, sx, sy, ox, oy = self._call(256, 128, 0, 0, 256, 128)
        self.assertTrue(ok)
        self.assertAlmostEqual(sx, 1.0, places=6)
        self.assertAlmostEqual(sy, 1.0, places=6)
        self.assertAlmostEqual(ox, 0.0, places=6)
        self.assertAlmostEqual(oy, 0.0, places=6)

    def test_subregion_transform_matches_expected(self) -> None:
        fb_w, fb_h = 200, 100
        left, top, right, bottom = 50, 20, 150, 80
        ok, sx, sy, ox, oy = self._call(fb_w, fb_h, left, top, right, bottom)
        self.assertTrue(ok)
        expected_left = (2.0 * left / fb_w) - 1.0
        expected_right = (2.0 * right / fb_w) - 1.0
        expected_top = 1.0 - (2.0 * top / fb_h)
        expected_bottom = 1.0 - (2.0 * bottom / fb_h)
        expected_sx = (expected_right - expected_left) * 0.5
        expected_sy = (expected_top - expected_bottom) * 0.5
        expected_ox = (expected_right + expected_left) * 0.5
        expected_oy = (expected_top + expected_bottom) * 0.5
        self.assertAlmostEqual(sx, expected_sx, places=6)
        self.assertAlmostEqual(sy, expected_sy, places=6)
        self.assertAlmostEqual(ox, expected_ox, places=6)
        self.assertAlmostEqual(oy, expected_oy, places=6)

    def test_invalid_geometry_rejected(self) -> None:
        ok, *_ = self._call(128, 128, 10, 10, 5, 20)
        self.assertFalse(ok)


if __name__ == "__main__":
    unittest.main()
