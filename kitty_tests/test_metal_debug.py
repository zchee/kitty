#!/usr/bin/env python
# License: GPL v3

from __future__ import annotations

import ctypes

import kitty.fast_data_types as fast_data_types

from . import BaseTest
from .renderer_backend import ffi, renderer_backend_select


class TestMetalDebugToggles(BaseTest):
    def setUp(self) -> None:
        super().setUp()
        self._apply_toggles(False, False)
        self.addCleanup(ffi.reset)
        self._registered_ops: list[tuple[ctypes.Structure, object, object]] = []
        self._present_calls: list[bool] = []
        self._recorded_raw: bytes | None = None
        self._recorded_flags: tuple[bool, bool] | None = None

    def _apply_toggles(self, debug_metal: bool, capture_frames: bool) -> None:
        self.set_options()
        options = fast_data_types.get_options()
        fast_data_types.set_options(
            options,
            False,
            False,
            False,
            int(debug_metal),
            int(capture_frames),
        )

    def _register_stub_backend(self) -> None:
        ffi.reset()
        self._present_calls.clear()
        self._recorded_raw = None
        self._recorded_flags = None

        def ensure(cfg_ptr: ctypes.c_void_p) -> bool:
            if cfg_ptr:
                raw = ctypes.cast(
                    cfg_ptr,
                    ctypes.POINTER(ctypes.c_ubyte * ctypes.sizeof(ffi.RendererInitConfig)),
                ).contents
                data = bytes(raw)
                self._recorded_raw = data
                self._recorded_flags = (data[2] != 0, data[3] != 0)
            return True

        def present(_window: ctypes.c_void_p, params_ptr: ctypes.POINTER(ffi.RendererPresentParams)) -> bool:
            capture = False
            if params_ptr:
                capture = bool(params_ptr.contents.capture_framebuffer)
            self._present_calls.append(capture)
            return True

        ops = ffi.make_backend_ops(
            "test-metal-debug",
            ensure_initialized=ensure,
            present=present,
        )
        self._registered_ops.append((ops, ensure, present))
        if not ffi.lib.renderer_backend_register(ffi.RENDERER_BACKEND_METAL, ctypes.byref(ops)):
            self.fail("Failed to register Metal stub backend")
        renderer_backend_select('metal')

    def _exercise_backend(self) -> None:
        self._register_stub_backend()
        frame_params = ffi.RendererFrameParams()
        ffi.lib.renderer_backend_begin_frame(ctypes.c_void_p(), ctypes.byref(frame_params))
        ffi.lib.renderer_backend_swap_buffers(None)

    def test_runtime_flags_follow_option_toggles(self) -> None:
        # Defaults: logging and capture disabled
        self._exercise_backend()
        self.assertEqual(self._recorded_flags, (False, False), "default renderer flags unexpectedly enabled")
        self.assertFalse(self._present_calls[-1], "present captured framebuffer without capture toggle")
        self.assertEqual(self._recorded_raw, b'\x00\x00\x00\x00')

        # Enable Metal debug logging
        self._apply_toggles(True, False)
        self._exercise_backend()
        self.assertEqual(self._recorded_flags, (True, False), "debug_metal option did not toggle logging flag")
        self.assertFalse(self._present_calls[-1], "capture triggered without capture flag")
        self.assertEqual(self._recorded_raw, b'\x00\x00\x01\x00')

        # Enable Metal capture alongside logging
        self._apply_toggles(True, True)
        self._exercise_backend()
        self.assertEqual(self._recorded_flags, (True, True), "capture flag did not enable with metal_gpu_capture option")
        self.assertTrue(self._present_calls[-1], "capture flag enabled but renderer_backend_swap_buffers omitted capture")
        self.assertEqual(self._recorded_raw, b'\x00\x00\x01\x01')

        # Disable toggles again
        self._apply_toggles(False, False)
        self._exercise_backend()
        self.assertEqual(self._recorded_flags, (False, False), "renderer flags did not clear when toggles disabled")
        self.assertFalse(self._present_calls[-1], "capture persisted after toggles disabled")
        self.assertEqual(self._recorded_raw, b'\x00\x00\x00\x00')
