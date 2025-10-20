#!/usr/bin/env python
# License: GPL v3 Copyright: 2025

import ctypes
import sys

import kitty.fast_data_types as fast_data_types
from kitty.fast_data_types import (
    renderer_backend_current,
    renderer_backend_select,
    renderer_backends_available,
)

from . import BaseTest


class BackendFFI:
    DEFAULT = object()
    RENDERER_BACKEND_OPENGL = 0
    RENDERER_BACKEND_METAL = 1

    def __init__(self) -> None:
        self.lib = ctypes.CDLL(fast_data_types.__file__)
        self.stub_helper = getattr(fast_data_types, "renderer_backend_register_stub_for_tests", None)

        class RendererFrameParams(ctypes.Structure):
            _fields_ = [
                ("frame_start_time", ctypes.c_int64),
                ("vsync_enabled", ctypes.c_bool),
            ]

        class RendererPresentParams(ctypes.Structure):
            _fields_ = [
                ("blocking", ctypes.c_bool),
                ("capture_framebuffer", ctypes.c_bool),
            ]

        class RendererResizeParams(ctypes.Structure):
            _fields_ = [
                ("framebuffer_width", ctypes.c_int),
                ("framebuffer_height", ctypes.c_int),
                ("framebuffer_scale", ctypes.c_float),
            ]

        class RendererRenderParams(ctypes.Structure):
            _fields_ = [
                ("os_window", ctypes.c_void_p),
                ("active_window_id", ctypes.c_uint),
                ("active_window_bg", ctypes.c_uint32),
                ("num_visible_windows", ctypes.c_uint),
                ("all_windows_have_same_bg", ctypes.c_bool),
            ]

        self.RendererFrameParams = RendererFrameParams
        self.RendererPresentParams = RendererPresentParams
        self.RendererResizeParams = RendererResizeParams
        self.RendererRenderParams = RendererRenderParams

        class MetalBackgroundGeometry(ctypes.Structure):
            _fields_ = [
                ("tiled", ctypes.c_float),
                ("positions", ctypes.c_float * 4),
                ("sizes", ctypes.c_float * 4),
            ]

        self.MetalBackgroundGeometry = MetalBackgroundGeometry

        self.EnsureFunc = ctypes.CFUNCTYPE(ctypes.c_bool, ctypes.c_void_p)
        self.ShutdownFunc = ctypes.CFUNCTYPE(None)
        self.AttachWindowFunc = ctypes.CFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.c_void_p)
        self.MakeCurrentFunc = ctypes.CFUNCTYPE(ctypes.c_void_p, ctypes.c_void_p)
        self.RestoreContextFunc = ctypes.CFUNCTYPE(None, ctypes.c_void_p)
        self.ApplySwapIntervalFunc = ctypes.CFUNCTYPE(None, ctypes.c_int)
        self.BeginFrameFunc = ctypes.CFUNCTYPE(
            ctypes.c_bool, ctypes.c_void_p, ctypes.POINTER(self.RendererFrameParams)
        )
        self.RenderFunc = ctypes.CFUNCTYPE(
            ctypes.c_bool, ctypes.c_void_p, ctypes.POINTER(self.RendererRenderParams)
        )
        self.PresentFunc = ctypes.CFUNCTYPE(
            ctypes.c_bool, ctypes.c_void_p, ctypes.POINTER(self.RendererPresentParams)
        )
        self.ResizeFunc = ctypes.CFUNCTYPE(
            None, ctypes.c_void_p, ctypes.POINTER(self.RendererResizeParams)
        )
        self.SuspendFunc = ctypes.CFUNCTYPE(None)
        self.ResumeFunc = ctypes.CFUNCTYPE(None)

        class RendererBackendOps(ctypes.Structure):
            _fields_ = [
                ("name", ctypes.c_char_p),
                ("ensure_initialized", self.EnsureFunc),
                ("shutdown", self.ShutdownFunc),
                ("attach_window", self.AttachWindowFunc),
                ("make_context_current", self.MakeCurrentFunc),
                ("restore_context", self.RestoreContextFunc),
                ("apply_swap_interval", self.ApplySwapIntervalFunc),
                ("begin_frame", self.BeginFrameFunc),
                ("render", self.RenderFunc),
                ("present", self.PresentFunc),
                ("on_resize", self.ResizeFunc),
                ("on_suspend", self.SuspendFunc),
                ("on_resume", self.ResumeFunc),
            ]

        self.RendererBackendOps = RendererBackendOps

        # Default callbacks retained to keep function pointers alive.
        self._ensure_true = self.EnsureFunc(lambda cfg: True)
        self._shutdown_noop = self.ShutdownFunc(lambda: None)
        self._attach_true = self.AttachWindowFunc(lambda window, config: True)
        self._make_context_null = self.MakeCurrentFunc(lambda window: None)
        self._restore_context_noop = self.RestoreContextFunc(lambda token: None)
        self._apply_swap_noop = self.ApplySwapIntervalFunc(lambda val: None)
        self._begin_true = self.BeginFrameFunc(lambda window, params: True)
        self._render_true = self.RenderFunc(lambda window, params: True)
        self._present_true = self.PresentFunc(lambda window, params: True)
        self._resize_noop = self.ResizeFunc(lambda window, params: None)
        self._suspend_noop = self.SuspendFunc(lambda: None)
        self._resume_noop = self.ResumeFunc(lambda: None)

        self.lib.renderer_backend_register.argtypes = [
            ctypes.c_int,
            ctypes.POINTER(self.RendererBackendOps),
        ]
        self.lib.renderer_backend_register.restype = ctypes.c_bool
        self.lib.renderer_backend_begin_frame.argtypes = [
            ctypes.c_void_p,
            ctypes.POINTER(self.RendererFrameParams),
        ]
        self.lib.renderer_backend_begin_frame.restype = ctypes.c_bool
        self.lib.renderer_backend_render.argtypes = [
            ctypes.c_void_p,
            ctypes.POINTER(self.RendererRenderParams),
        ]
        self.lib.renderer_backend_render.restype = ctypes.c_bool
        self.lib.renderer_backend_present.argtypes = [
            ctypes.c_void_p,
            ctypes.POINTER(self.RendererPresentParams),
        ]
        self.lib.renderer_backend_present.restype = ctypes.c_bool
        self.lib.renderer_backend_reset_for_tests.argtypes = []
        self.lib.renderer_backend_reset_for_tests.restype = None
        self.lib.register_opengl_renderer_backend.argtypes = []
        self.lib.register_opengl_renderer_backend.restype = ctypes.c_bool
        if hasattr(self.lib, "register_metal_renderer_backend"):
            self.lib.register_metal_renderer_backend.argtypes = []
            self.lib.register_metal_renderer_backend.restype = ctypes.c_bool
            self.has_metal = True
            if hasattr(self.lib, "metal_renderer_preflight"):
                self.lib.metal_renderer_preflight.argtypes = [ctypes.POINTER(ctypes.c_char_p)]
                self.lib.metal_renderer_preflight.restype = ctypes.c_bool
            if hasattr(self.lib, "metal_compute_background_geometry"):
                self.lib.metal_compute_background_geometry.argtypes = [
                    ctypes.c_uint,
                    ctypes.c_uint,
                    ctypes.c_uint,
                    ctypes.c_uint,
                    ctypes.c_int,
                    ctypes.POINTER(MetalBackgroundGeometry),
                ]
                self.lib.metal_compute_background_geometry.restype = ctypes.c_bool
            else:
                self.has_metal = False
        else:
            self.has_metal = False

        self._pyerr_fetch = ctypes.pythonapi.PyErr_Fetch
        self._pyerr_fetch.argtypes = [
            ctypes.POINTER(ctypes.py_object),
            ctypes.POINTER(ctypes.py_object),
            ctypes.POINTER(ctypes.py_object),
        ]
        self._pyerr_fetch.restype = None

    def reset(self) -> None:
        self.lib.renderer_backend_reset_for_tests()
        if not self.lib.register_opengl_renderer_backend():
            raise RuntimeError("Failed to register OpenGL backend for tests")
        if self.has_metal:
            self.lib.register_metal_renderer_backend()
        renderer_backend_select('opengl')

        class BackgroundImageLayout:
            TILING = 0
            SCALED = 1
            MIRRORED = 2
            CLAMPED = 3
            CENTER_CLAMPED = 4
            CENTER_SCALED = 5

        self.BackgroundImageLayout = BackgroundImageLayout
        self._has_background_geometry = hasattr(self.lib, "metal_compute_background_geometry")

    def make_backend_ops(
        self,
        name: str,
        *,
        begin_frame=DEFAULT,
        render=DEFAULT,
        present=DEFAULT,
    ) -> "RendererBackendOps":
        ops = self.RendererBackendOps()
        ops.name = name.encode()
        refs = []

        ops.ensure_initialized = self._ensure_true
        ops.shutdown = self._shutdown_noop
        ops.attach_window = self._attach_true
        ops.make_context_current = self._make_context_null
        ops.restore_context = self._restore_context_noop
        ops.apply_swap_interval = self._apply_swap_noop

        if begin_frame is self.DEFAULT:
            ops.begin_frame = self._begin_true
        elif begin_frame is None:
            ops.begin_frame = ctypes.cast(None, self.BeginFrameFunc)
        else:
            cb = self.BeginFrameFunc(begin_frame)
            refs.append(cb)
            ops.begin_frame = cb

        if render is self.DEFAULT:
            ops.render = self._render_true
        elif render is None:
            ops.render = ctypes.cast(None, self.RenderFunc)
        else:
            cb = self.RenderFunc(render)
            refs.append(cb)
            ops.render = cb

        if present is self.DEFAULT:
            ops.present = self._present_true
        elif present is None:
            ops.present = ctypes.cast(None, self.PresentFunc)
        else:
            cb = self.PresentFunc(present)
            refs.append(cb)
            ops.present = cb

        ops.on_resize = self._resize_noop
        ops.on_suspend = self._suspend_noop
        ops.on_resume = self._resume_noop
        ops._refs = refs  # keep callbacks alive
        return ops

    def compute_background_geometry(
        self,
        framebuffer_width: int,
        framebuffer_height: int,
        image_width: int,
        image_height: int,
        layout: int,
    ) -> tuple[bool, "MetalBackgroundGeometry"]:
        if not self._has_background_geometry:
            raise RuntimeError("Metal background geometry function unavailable")
        geometry = self.MetalBackgroundGeometry()
        ok = self.lib.metal_compute_background_geometry(
            framebuffer_width,
            framebuffer_height,
            image_width,
            image_height,
            layout,
            ctypes.byref(geometry),
        )
        return bool(ok), geometry

    def fetch_error(self):
        err_type = ctypes.py_object()
        err_value = ctypes.py_object()
        err_tb = ctypes.py_object()
        self._pyerr_fetch(
            ctypes.byref(err_type), ctypes.byref(err_value), ctypes.byref(err_tb)
        )
        return err_type.value, err_value.value, err_tb.value


ffi = BackendFFI()
ffi.reset()


class TestRendererBackend(BaseTest):

    def setUp(self) -> None:
        super().setUp()
        ffi.reset()
        renderer_backend_select('opengl')

    def test_available_backends_contains_opengl(self) -> None:
        available = renderer_backends_available()
        self.assertIn('opengl', available)

    def test_current_backend_defaults_to_opengl(self) -> None:
        self.assertEqual('opengl', renderer_backend_current())

    def test_select_invalid_backend_raises(self) -> None:
        with self.assertRaisesRegex(ValueError, 'Unknown renderer backend'):
            renderer_backend_select('invalid-backend')

    def test_select_opengl_idempotent(self) -> None:
        renderer_backend_select('opengl')
        self.assertEqual('opengl', renderer_backend_current())

    def test_metal_backend_registration_matches_platform(self) -> None:
        available = renderer_backends_available()
        if sys.platform == 'darwin':
            self.assertIn('metal', available)
        else:
            self.assertNotIn('metal', available)

    def test_metal_preflight_reports_status(self) -> None:
        if not ffi.has_metal:
            self.skipTest("Metal backend not compiled in this build")
        reason = ctypes.c_char_p()
        result = ffi.lib.metal_renderer_preflight(ctypes.byref(reason))
        if sys.platform == 'darwin':
            self.assertTrue(
                result,
                "Metal preflight should succeed on supported macOS hosts.",
            )
            self.assertIsNone(
                reason.value,
                "Successful Metal preflight must not return a failure reason.",
            )
        else:
            self.assertFalse(result)
            self.assertIsNotNone(
                reason.value,
                "Metal preflight on non-macOS hosts must provide a reason.",
            )
            message = reason.value.decode('utf-8', errors='ignore')
            self.assertNotEqual(
                message.strip(),
                '',
                "Metal preflight failure reason should be informative.",
            )

    def test_select_metal_round_trip(self) -> None:
        available = renderer_backends_available()
        if 'metal' not in available:
            with self.assertRaisesRegex(ValueError, 'Unknown renderer backend'):
                renderer_backend_select('metal')
            return
        renderer_backend_select('metal')
        self.assertEqual('metal', renderer_backend_current())
        renderer_backend_select('opengl')

    def test_backend_render_hook_invocation_order(self) -> None:
        self.addCleanup(ffi.reset)
        call_log = []

        def log_begin_frame(window, params):
            call_log.append(("begin_frame", params.contents.frame_start_time))
            return True

        def log_render(window, params):
            call_log.append(("render", params.contents.active_window_id))
            return True

        def log_present(window, params):
            call_log.append(("present", params.contents.blocking))
            return True

        ops = ffi.make_backend_ops(
            "stub-backend",
            begin_frame=log_begin_frame,
            render=log_render,
            present=log_present,
        )
        self.assertTrue(
            ffi.lib.renderer_backend_register(
                ffi.RENDERER_BACKEND_METAL, ctypes.byref(ops)
            )
        )
        renderer_backend_select('metal')

        frame_params = ffi.RendererFrameParams(frame_start_time=123, vsync_enabled=False)
        render_params = ffi.RendererRenderParams(
            os_window=None,
            active_window_id=7,
            active_window_bg=0,
            num_visible_windows=1,
            all_windows_have_same_bg=True,
        )
        present_params = ffi.RendererPresentParams(
            blocking=True,
            capture_framebuffer=False,
        )

        self.assertTrue(
            ffi.lib.renderer_backend_begin_frame(None, ctypes.byref(frame_params))
        )
        self.assertTrue(
            ffi.lib.renderer_backend_render(None, ctypes.byref(render_params))
        )
        self.assertTrue(
            ffi.lib.renderer_backend_present(None, ctypes.byref(present_params))
        )

        self.assertEqual(
            [entry[0] for entry in call_log],
            ["begin_frame", "render", "present"],
        )
        self.assertEqual(call_log[1][1], 7)

    def test_renderer_backend_render_missing_hook_sets_error(self) -> None:
        self.addCleanup(ffi.reset)
        if ffi.stub_helper:
            ffi.stub_helper(
                "stub-missing-render",
                ffi.RENDERER_BACKEND_METAL,
                False,
                True,
            )
        else:
            ops = ffi.make_backend_ops("stub-missing-render", render=None)
            self.assertTrue(
                ffi.lib.renderer_backend_register(
                    ffi.RENDERER_BACKEND_METAL, ctypes.byref(ops)
                )
            )
        renderer_backend_select('metal')
        render_params = ffi.RendererRenderParams(
            os_window=None,
            active_window_id=1,
            active_window_bg=0,
            num_visible_windows=0,
            all_windows_have_same_bg=True,
        )
        if hasattr(fast_data_types, "renderer_backend_render_for_tests"):
            with self.assertRaises(RuntimeError) as exc:
                fast_data_types.renderer_backend_render_for_tests(
                    active_window_id=1,
                    active_window_bg=0,
                    num_visible_windows=0,
                    all_windows_have_same_bg=True,
                )
            message = str(exc.exception)
            self.assertIn("render", message)
            self.assertIn("stub-missing-render", message)
        else:
            success = ffi.lib.renderer_backend_render(None, ctypes.byref(render_params))
            self.assertFalse(success)
            err_type, err_value, _ = ffi.fetch_error()
            self.assertIs(err_type, RuntimeError)
            self.assertIn("render", str(err_value))
            self.assertIn("stub-missing-render", str(err_value))

    def test_renderer_backend_present_missing_hook_sets_error(self) -> None:
        self.addCleanup(ffi.reset)
        if ffi.stub_helper:
            ffi.stub_helper(
                "stub-missing-present",
                ffi.RENDERER_BACKEND_METAL,
                True,
                False,
            )
        else:
            ops = ffi.make_backend_ops("stub-missing-present", present=None)
            self.assertTrue(
                ffi.lib.renderer_backend_register(
                    ffi.RENDERER_BACKEND_METAL, ctypes.byref(ops)
                )
            )
        renderer_backend_select('metal')
        present_params = ffi.RendererPresentParams(
            blocking=True,
            capture_framebuffer=False,
        )
        if hasattr(fast_data_types, "renderer_backend_present_for_tests"):
            with self.assertRaises(RuntimeError) as exc:
                fast_data_types.renderer_backend_present_for_tests(
                    blocking=True,
                    capture_framebuffer=False,
                )
            message = str(exc.exception)
            self.assertIn("present", message)
            self.assertIn("stub-missing-present", message)
        else:
            success = ffi.lib.renderer_backend_present(None, ctypes.byref(present_params))
            self.assertFalse(success)
            err_type, err_value, _ = ffi.fetch_error()
            self.assertIs(err_type, RuntimeError)
            self.assertIn("present", str(err_value))
            self.assertIn("stub-missing-present", str(err_value))

    def test_opengl_helpers_are_not_python_accessible(self) -> None:
        # Ensure OpenGL-specific helpers are not exposed through the public C API.
        for name in ("draw_cells", "draw_borders", "blank_canvas", "setup_os_window_for_rendering"):
            self.assertFalse(
                hasattr(fast_data_types, name),
                f"{name} should not be exported via fast_data_types",
            )
