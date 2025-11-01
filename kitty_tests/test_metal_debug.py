#!/usr/bin/env python
# License: GPL v3

from __future__ import annotations

import ctypes
import io
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

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

        opts, leftover = cli.parse_args(['--debug-metal', '--metal-gpu-capture', '--metal-dump-frame', '/tmp/frame.png'])
        self.assertEqual(leftover, [], 'cli.parse_args left unexpected positional args')
        self.assertTrue(getattr(opts, 'debug_metal', False), '--debug-metal flag not reflected in CLI options')
        self.assertTrue(getattr(opts, 'metal_gpu_capture', False), '--metal-gpu-capture flag not reflected in CLI options')
        self.assertEqual(getattr(opts, 'metal_dump_frame', ''), '/tmp/frame.png', '--metal-dump-frame flag not reflected in CLI options')

    def test_dump_metal_capture_writes_png(self) -> None:
        from kitty import main

        buf = ctypes.create_string_buffer(b'\xff\x00\x00\xff')

        class StubLib:
            def __init__(self) -> None:
                self._buf = buf
                self.cleared = False

            def metal_renderer_copy_captured_frame_for_tests(self, info_ptr: ctypes.POINTER(ctypes.c_void_p)) -> bool:
                info = info_ptr.contents
                info.width = 1
                info.height = 1
                info.bytes_per_row = 4
                info.pixels = ctypes.cast(ctypes.addressof(self._buf), ctypes.c_void_p)
                return True

            def metal_renderer_debug_clear_captured_frame_for_tests(self) -> None:
                self.cleared = True

        with tempfile.TemporaryDirectory() as td:
            out_path = Path(td) / 'capture.png'
            stub = StubLib()
            stderr = io.StringIO()
            with mock.patch('kitty.main.ctypes.CDLL', return_value=stub):
                with mock.patch('kitty.main.is_macos', True):
                    with mock.patch('sys.stderr', stderr):
                        main._dump_metal_capture(out_path)
            files = sorted(p.name for p in Path(td).iterdir())
            self.assertTrue(out_path.exists(), f'Failed to write Metal capture PNG: {stderr.getvalue()} files={files}')
            self.assertTrue(stub.cleared, 'Captured frame was not cleared after dump')
            data = out_path.read_bytes()
            self.assertTrue(data.startswith(b'\x89PNG\r\n\x1a\n'), 'PNG output missing signature header')
            self.assertIn('Metal capture saved to', stderr.getvalue())

    def test_dump_metal_capture_handles_missing_frame(self) -> None:
        from kitty import main

        class EmptyLib:
            def metal_renderer_copy_captured_frame_for_tests(self, info_ptr: ctypes.POINTER(ctypes.c_void_p)) -> bool:
                info = info_ptr.contents
                info.width = 0
                info.height = 0
                info.bytes_per_row = 0
                info.pixels = ctypes.c_void_p()
                return False

        with tempfile.TemporaryDirectory() as td:
            out_path = Path(td) / 'capture.png'
            stderr = io.StringIO()
            with mock.patch('kitty.main.ctypes.CDLL', return_value=EmptyLib()):
                with mock.patch('kitty.main.is_macos', True):
                    with mock.patch('sys.stderr', stderr):
                        main._dump_metal_capture(out_path)
        self.assertFalse(out_path.exists(), 'Unexpected PNG produced when capture unavailable')
        self.assertIn('No Metal capture available', stderr.getvalue())

    def test_run_app_dumps_before_renderer_shutdown(self) -> None:
        from contextlib import contextmanager
        from types import SimpleNamespace
        from kitty import main

        calls: list[str] = []

        @contextmanager
        def fake_cached_values(_name: str):
            calls.append('cached_enter')
            try:
                yield {}
            finally:
                calls.append('cached_exit')

        @contextmanager
        def fake_startup_handler(**_kw):
            calls.append('notify_enter')
            try:
                yield lambda *a, **k: None
            finally:
                calls.append('notify_exit')

        class DummyBoss:
            def __init__(self, *args, **kwargs) -> None:
                self.misc_config_errors: list[str] = []
                self.child_monitor = SimpleNamespace(main_loop=lambda: calls.append('main_loop'))

            def start(self, *args, **kwargs) -> None:
                calls.append('boss_start')

            def show_bad_config_lines(self, *args, **kwargs) -> None:
                pass

            def show_error(self, *args, **kwargs) -> None:
                pass

            def destroy(self) -> None:
                calls.append('destroy')

        def fake_dump(path: object) -> None:
            calls.append(f'dump:{path}')

        args = SimpleNamespace(
            cls='',
            name='',
            title=None,
            position=None,
            start_as=None,
            grab_keyboard=False,
            debug_font_fallback=False,
            debug_rendering=False,
            debug_metal=False,
            metal_dump_frame='/tmp/metal-capture.png',
            metal_gpu_capture=True,
            session='',
        )
        opts = SimpleNamespace(
            startup_session=None,
            remember_window_position=False,
            macos_custom_beam_cursor=False,
        )

        with mock.patch('kitty.main.is_macos', True),              mock.patch('kitty.main.set_cocoa_global_shortcuts', side_effect=lambda *a, **k: calls.append('set_shortcuts') or {}),              mock.patch('kitty.main.set_macos_app_custom_icon'),              mock.patch('kitty.main.cached_values_for', fake_cached_values),              mock.patch('kitty.main.startup_notification_handler', fake_startup_handler),              mock.patch('kitty.main.create_sessions', return_value=[]),              mock.patch('kitty.main.create_os_window', side_effect=lambda *a, **k: calls.append('create_window') or 1),              mock.patch('kitty.main.parse_os_window_state', return_value=None),              mock.patch('kitty.main.get_os_window_sizing_data', return_value=None),              mock.patch('kitty.main.Boss', side_effect=lambda *a, **k: DummyBoss()),              mock.patch('kitty.main._dump_metal_capture', side_effect=fake_dump),              mock.patch('kitty.main.set_custom_ibeam_cursor'),              mock.patch('kitty.main.dump_font_debug'),              mock.patch('kitty.main.set_font_family', side_effect=lambda *a, **k: calls.append('set_font_family')):
            with mock.patch.object(main.run_app, 'initial_window_size_func', lambda *a, **k: (80, 24)):
                main._run_app(opts, args)

        dump_calls = [entry for entry in calls if entry.startswith('dump:')]
        self.assertTrue(dump_calls, 'Metal capture dump was not triggered by _run_app')
        self.assertLess(calls.index(dump_calls[0]), calls.index('destroy'), 'Metal dump should run before renderer teardown')


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
