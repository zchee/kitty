#!/usr/bin/env python

from __future__ import annotations

import ctypes
import unittest

import kitty.fast_data_types as fast_data_types


class RendererSharedApiTest(unittest.TestCase):

    @classmethod
    def setUpClass(cls) -> None:
        cls.lib = ctypes.CDLL(fast_data_types.__file__)

        class FrameParams(ctypes.Structure):
            _fields_ = [
                ("screen", ctypes.c_void_p),
                ("os_window", ctypes.c_void_p),
                ("cursor_has_moved", ctypes.c_bool),
            ]

        class FrameResult(ctypes.Structure):
            _fields_ = [
                ("cell_data_changed", ctypes.c_bool),
                ("selection_data_changed", ctypes.c_bool),
                ("graphics_data_changed", ctypes.c_bool),
                ("default_bg", ctypes.c_uint32),
            ]

        cls.FrameParams = FrameParams
        cls.FrameResult = FrameResult

        cls.lib.renderer_shared_prepare_frame.argtypes = [
            ctypes.POINTER(FrameParams),
            ctypes.c_void_p,
            ctypes.c_void_p,
            ctypes.POINTER(FrameResult),
        ]
        cls.lib.renderer_shared_prepare_frame.restype = ctypes.c_bool

        cls.lib.renderer_shared_populate_uniform_data.argtypes = [
            ctypes.c_void_p,
            ctypes.c_void_p,
            ctypes.c_void_p,
            ctypes.c_float,
            ctypes.c_float,
            ctypes.c_void_p,
            ctypes.c_size_t,
            ctypes.c_size_t,
        ]
        cls.lib.renderer_shared_populate_uniform_data.restype = ctypes.c_uint32

    def test_prepare_frame_allows_null_screen(self) -> None:
        params = self.FrameParams(screen=None, os_window=None, cursor_has_moved=False)
        result = self.FrameResult()
        ok = self.lib.renderer_shared_prepare_frame(
            ctypes.byref(params),
            None,
            None,
            ctypes.byref(result),
        )
        self.assertTrue(ok)
        self.assertFalse(result.cell_data_changed)
        self.assertFalse(result.selection_data_changed)
        self.assertFalse(result.graphics_data_changed)
        self.assertEqual(result.default_bg, 0)

    def test_populate_uniform_data_null_inputs(self) -> None:
        default_bg = self.lib.renderer_shared_populate_uniform_data(
            None,
            None,
            None,
            1.0,
            1.0,
            None,
            0,
            0,
        )
        self.assertEqual(default_bg, 0)


if __name__ == "__main__":
    unittest.main()
