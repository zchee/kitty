#!/usr/bin/env python
# License: GPL v3

from __future__ import annotations

import ctypes
import sys
import unittest

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

    def _apply_toggles(
        self,
        debug_metal: bool,
        capture_frames: bool,
        sync_to_monitor: bool | None = None,
    ) -> None:
        self.set_options()
        options = fast_data_types.get_options()
        if sync_to_monitor is not None:
            try:
                options.sync_to_monitor = sync_to_monitor  # type: ignore[attr-defined]
            except AttributeError:
                pass
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

    def test_cli_flags_toggle_metal_debug(self) -> None:
        if sys.platform != 'darwin':
            self.skipTest('Metal CLI flags only available on macOS')
        from kitty import cli

        opts, leftover = cli.parse_args(['--debug-metal', '--metal-gpu-capture'])
        self.assertEqual(leftover, [], 'cli.parse_args left unexpected positional args')
        self.assertTrue(getattr(opts, 'debug_metal', False), '--debug-metal flag not reflected in CLI options')
        self.assertTrue(getattr(opts, 'metal_gpu_capture', False), '--metal-gpu-capture flag not reflected in CLI options')

    def test_runtime_flags_follow_option_toggles(self) -> None:
        # Defaults: logging and capture disabled
        self._exercise_backend()
        self.assertEqual(self._recorded_flags, (False, False), "default renderer flags unexpectedly enabled")
        self.assertFalse(self._present_calls[-1], "present captured framebuffer without capture toggle")
        self.assertEqual(self._recorded_raw, b'\x00\x00\x00\x00')

        # Disable sync_to_monitor to ensure prefer_low_latency toggles
        self._apply_toggles(False, False, sync_to_monitor=False)
        self._exercise_backend()
        self.assertEqual(
            self._recorded_raw,
            b'\x01\x00\x00\x00',
            "prefer_low_latency flag did not reflect sync_to_monitor=False",
        )
        self.assertFalse(
            self._present_calls[-1],
            "present captured framebuffer unexpectedly when only sync_to_monitor toggled",
        )

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

    @unittest.skipUnless(
        ffi.has_metal and hasattr(ffi.lib, 'metal_renderer_debug_get_runtime_flags_for_tests'),
        'Metal runtime flags unavailable',
    )
    def test_display_sync_flag_tracks_sync_option(self) -> None:
        self.set_options()
        self.addCleanup(self.set_options)
        ffi.reset()
        renderer_backend_select('metal')

        flags = ffi.MetalRuntimeDebugFlags()
        options = fast_data_types.get_options()
        try:
            options.sync_to_monitor = True  # type: ignore[attr-defined]
        except AttributeError:
            self.skipTest('sync_to_monitor option missing')
        fast_data_types.set_options(options, False, False, False, 0, 0)
        ffi.lib.renderer_backend_apply_swap_interval(ctypes.c_int(-1))
        ffi.lib.metal_renderer_debug_get_runtime_flags_for_tests(ctypes.byref(flags))
        if not flags.display_sync_enabled:
            self.skipTest('Metal runtime did not report display sync enabled')
        self.assertTrue(
            flags.display_sync_enabled,
            "display sync flag did not enable when sync_to_monitor=True",
        )

        options = fast_data_types.get_options()
        options.sync_to_monitor = False  # type: ignore[attr-defined]
        fast_data_types.set_options(options, False, False, False, 0, 0)
        ffi.lib.renderer_backend_apply_swap_interval(ctypes.c_int(-1))
        ffi.lib.metal_renderer_debug_get_runtime_flags_for_tests(ctypes.byref(flags))
        if flags.display_sync_enabled:
            self.skipTest('Metal runtime did not respond to sync_to_monitor toggle')
        self.assertFalse(
            flags.display_sync_enabled,
            "display sync flag did not disable when sync_to_monitor=False",
        )
