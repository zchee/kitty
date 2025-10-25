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
        self._should_register_opengl = sys.platform != "darwin"
        self.has_opengl = False

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
        class RendererInitConfig(ctypes.Structure):
            _pack_ = 1
            _fields_ = [
                ("prefer_low_latency", ctypes.c_uint8),
                ("enable_debug_labels", ctypes.c_uint8),
                ("enable_debug_logging", ctypes.c_uint8),
                ("enable_frame_capture", ctypes.c_uint8),
            ]

        self.RendererInitConfig = RendererInitConfig

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
            self.has_metal = sys.platform == 'darwin'
            if self.has_metal and hasattr(self.lib, "metal_renderer_preflight"):
                self.lib.metal_renderer_preflight.argtypes = [ctypes.POINTER(ctypes.c_char_p)]
                self.lib.metal_renderer_preflight.restype = ctypes.c_bool
            if self.has_metal and hasattr(self.lib, "metal_compute_background_geometry"):
                self.lib.metal_compute_background_geometry.argtypes = [
                    ctypes.c_uint,
                    ctypes.c_uint,
                    ctypes.c_uint,
                    ctypes.c_uint,
                    ctypes.c_int,
                    ctypes.POINTER(MetalBackgroundGeometry),
                ]
                self.lib.metal_compute_background_geometry.restype = ctypes.c_bool
            elif self.has_metal:
                self.has_metal = False
            if self.has_metal:
                class TextureRef(ctypes.Structure):
                    _fields_ = [
                        ("id", ctypes.c_uint32),
                        ("refcnt", ctypes.c_uint32),
                        ("backend_handle", ctypes.c_void_p),
                    ]

                class RendererGraphicsImageUpload(ctypes.Structure):
                    _fields_ = [
                        ("pixels", ctypes.c_void_p),
                        ("width", ctypes.c_int32),
                        ("height", ctypes.c_int32),
                        ("is_opaque", ctypes.c_uint8),
                        ("is_4byte_aligned", ctypes.c_uint8),
                        ("linear_filter", ctypes.c_uint8),
                        ("_pad0", ctypes.c_uint8),
                        ("repeat", ctypes.c_int32),
                    ]

                class MetalGraphicsTextureInfo(ctypes.Structure):
                    _fields_ = [
                        ("width", ctypes.c_uint32),
                        ("height", ctypes.c_uint32),
                        ("linear_filter", ctypes.c_bool),
                        ("is_opaque", ctypes.c_bool),
                        ("repeat", ctypes.c_int32),
                    ]

                class RepeatStrategy:
                    MIRROR = 0
                    CLAMP = 1
                    DEFAULT = 2

                class BackgroundImage(ctypes.Structure):
                    _fields_ = [
                        ("texture_id", ctypes.c_uint32),
                        ("height", ctypes.c_uint),
                        ("width", ctypes.c_uint),
                        ("bitmap", ctypes.POINTER(ctypes.c_uint8)),
                        ("refcnt", ctypes.c_uint32),
                        ("id", ctypes.c_uint32),
                        ("mmap_size", ctypes.c_size_t),
                        ("metal_texture", ctypes.c_void_p),
                    ]

                self.TextureRef = TextureRef
                self.RendererGraphicsImageUpload = RendererGraphicsImageUpload
                self.MetalGraphicsTextureInfo = MetalGraphicsTextureInfo
                self.RepeatStrategy = RepeatStrategy
                self.BackgroundImage = BackgroundImage

                if self.has_metal:
                    class MetalWindowDebugState(ctypes.Structure):
                        _fields_ = [
                            ("frame_has_content", ctypes.c_bool),
                            ("capture_valid", ctypes.c_bool),
                            ("capture_width", ctypes.c_uint32),
                            ("capture_height", ctypes.c_uint32),
                            ("capture_bytes_per_row", ctypes.c_uint32),
                            ("contents_scale", ctypes.c_float),
                            ("drawable_width", ctypes.c_uint32),
                            ("drawable_height", ctypes.c_uint32),
                            ("layer_attached", ctypes.c_bool),
                        ]

                    self.MetalWindowDebugState = MetalWindowDebugState
                    class MetalRuntimeDebugFlags(ctypes.Structure):
                        _fields_ = [
                            ("debug_labels", ctypes.c_bool),
                            ("debug_events", ctypes.c_bool),
                            ("capture_frames", ctypes.c_bool),
                        ]

                    self.MetalRuntimeDebugFlags = MetalRuntimeDebugFlags

                self.lib.renderer_backend_upload_graphics_image.argtypes = [
                    ctypes.POINTER(TextureRef),
                    ctypes.POINTER(RendererGraphicsImageUpload),
                ]
                self.lib.renderer_backend_upload_graphics_image.restype = ctypes.c_bool
                self.lib.renderer_backend_destroy_graphics_image.argtypes = [
                    ctypes.POINTER(TextureRef)
                ]
                self.lib.renderer_backend_destroy_graphics_image.restype = None
                if hasattr(self.lib, "metal_renderer_debug_get_graphics_texture"):
                    self.lib.metal_renderer_debug_get_graphics_texture.argtypes = [
                        ctypes.c_uint32,
                        ctypes.POINTER(MetalGraphicsTextureInfo),
                    ]
                    self.lib.metal_renderer_debug_get_graphics_texture.restype = ctypes.c_bool
                else:
                    self.has_metal = False
                if self.has_metal and hasattr(self.lib, "metal_background_image_uploaded"):
                    self.lib.metal_background_image_uploaded.argtypes = [
                        ctypes.POINTER(BackgroundImage),
                        ctypes.c_uint,
                        ctypes.c_bool,
                    ]
                    self.lib.metal_background_image_uploaded.restype = None
                if self.has_metal and hasattr(self.lib, "metal_background_image_release"):
                    self.lib.metal_background_image_release.argtypes = [
                        ctypes.POINTER(BackgroundImage)
                    ]
                    self.lib.metal_background_image_release.restype = None
                if self.has_metal and hasattr(self.lib, "metal_renderer_debug_seed_window_state_for_tests"):
                    self.lib.metal_renderer_debug_seed_window_state_for_tests.argtypes = [
                        ctypes.c_void_p
                    ]
                    self.lib.metal_renderer_debug_seed_window_state_for_tests.restype = None
                if self.has_metal and hasattr(self.lib, "metal_renderer_debug_get_window_state_for_tests"):
                    self.lib.metal_renderer_debug_get_window_state_for_tests.argtypes = [
                        ctypes.c_void_p,
                        ctypes.POINTER(self.MetalWindowDebugState),
                    ]
                    self.lib.metal_renderer_debug_get_window_state_for_tests.restype = ctypes.c_bool
                if self.has_metal and hasattr(self.lib, "metal_renderer_debug_set_window_state_for_tests"):
                    self.lib.metal_renderer_debug_set_window_state_for_tests.argtypes = [
                        ctypes.c_void_p,
                        ctypes.POINTER(self.MetalWindowDebugState),
                    ]
                    self.lib.metal_renderer_debug_set_window_state_for_tests.restype = None
                if self.has_metal and hasattr(self.lib, "metal_renderer_debug_reset_capture_state_for_tests"):
                    self.lib.metal_renderer_debug_reset_capture_state_for_tests.argtypes = [
                        ctypes.c_void_p,
                        ctypes.c_bool,
                    ]
                    self.lib.metal_renderer_debug_reset_capture_state_for_tests.restype = None
                if self.has_metal and hasattr(self.lib, "metal_renderer_debug_get_runtime_flags_for_tests"):
                    self.lib.metal_renderer_debug_get_runtime_flags_for_tests.argtypes = [
                        ctypes.POINTER(self.MetalRuntimeDebugFlags),
                    ]
                    self.lib.metal_renderer_debug_get_runtime_flags_for_tests.restype = None
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
        registered: list[str] = []
        self.has_opengl = False
        if self._should_register_opengl:
            if not self.lib.register_opengl_renderer_backend():
                raise RuntimeError("Failed to register OpenGL backend for tests")
            self.has_opengl = True
            registered.append('opengl')
        if self.has_metal:
            if not self.lib.register_metal_renderer_backend():
                raise RuntimeError("Failed to register Metal backend for tests")
            registered.append('metal')
        if registered:
            renderer_backend_select(registered[0])

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
        ensure_initialized=DEFAULT,
        begin_frame=DEFAULT,
        render=DEFAULT,
        present=DEFAULT,
    ) -> "RendererBackendOps":
        ops = self.RendererBackendOps()
        ops.name = name.encode()
        refs = []

        if ensure_initialized is self.DEFAULT:
            ops.ensure_initialized = self._ensure_true
        elif ensure_initialized is None:
            ops.ensure_initialized = ctypes.cast(None, self.EnsureFunc)
        else:
            cb = self.EnsureFunc(ensure_initialized)
            refs.append(cb)
            ops.ensure_initialized = cb
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

    def graphics_texture_info(self, texture_id: int):
        if not self.has_metal or not hasattr(self, "MetalGraphicsTextureInfo"):
            raise RuntimeError("Metal graphics texture inspection unavailable")
        info = self.MetalGraphicsTextureInfo()
        ok = self.lib.metal_renderer_debug_get_graphics_texture(
            ctypes.c_uint32(texture_id), ctypes.byref(info)
        )
        if not ok:
            return None
        return info


ffi = BackendFFI()
ffi.reset()


class TestRendererBackend(BaseTest):

    def setUp(self) -> None:
        super().setUp()
        ffi.reset()
        self.available = renderer_backends_available()
        self.has_opengl = 'opengl' in self.available
        if self.has_opengl:
            renderer_backend_select('opengl')
        elif 'metal' in self.available:
            renderer_backend_select('metal')
        self.default_backend = renderer_backend_current()
        self.addCleanup(renderer_backend_select, self.default_backend)

    def test_available_backends_contains_opengl(self) -> None:
        available = renderer_backends_available()
        if self.has_opengl:
            self.assertIn('opengl', available)
        else:
            self.assertNotIn('opengl', available)

    def test_current_backend_defaults_to_opengl(self) -> None:
        expected = 'opengl' if self.has_opengl else 'metal'
        self.assertEqual(expected, renderer_backend_current())

    def test_select_invalid_backend_raises(self) -> None:
        with self.assertRaisesRegex(ValueError, 'Unknown renderer backend'):
            renderer_backend_select('invalid-backend')

    def test_select_opengl_idempotent(self) -> None:
        if not self.has_opengl:
            self.skipTest('OpenGL backend unavailable on this platform')
        renderer_backend_select('opengl')
        self.assertEqual('opengl', renderer_backend_current())

    def test_metal_backend_registration_matches_platform(self) -> None:
        available = renderer_backends_available()
        if sys.platform == 'darwin':
            self.assertIn('metal', available)
        else:
            self.assertNotIn('metal', available)

    def test_macos_reports_only_metal_backend(self) -> None:
        if sys.platform != 'darwin':
            self.skipTest('macOS-only behaviour')
        available = renderer_backends_available()
        self.assertIn('metal', available)
        self.assertNotIn('opengl', available)

    def test_macos_rejects_opengl_selection(self) -> None:
        if sys.platform != 'darwin':
            self.skipTest('macOS-only behaviour')
        with self.assertRaises(ValueError) as exc:
            renderer_backend_select('opengl')
        self.assertIn('macOS', str(exc.exception))

    def test_macos_register_opengl_backend_returns_false(self) -> None:
        if sys.platform != 'darwin':
            self.skipTest('macOS-only behaviour')
        err_type = ctypes.py_object()
        err_value = ctypes.py_object()
        err_traceback = ctypes.py_object()
        result = ffi.lib.register_opengl_renderer_backend()
        self.assertFalse(result)
        ffi._pyerr_fetch(ctypes.byref(err_type), ctypes.byref(err_value), ctypes.byref(err_traceback))
        self.assertIsNotNone(err_type.value)
        self.assertIn('not supported', str(err_value.value))

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
        if self.has_opengl:
            renderer_backend_select('opengl')

    def test_select_opengl_after_metal_rebuilds_vaos(self) -> None:
        if 'metal' not in self.available or 'opengl' not in self.available:
            self.skipTest('Requires both Metal and OpenGL backends')
        if not ffi.has_metal or not hasattr(ffi.lib, 'state_debug_add_os_window_for_tests'):
            self.skipTest('Renderer state debug helpers unavailable')

        renderer_backend_select('metal')

        create_os_window = ffi.lib.state_debug_add_os_window_for_tests
        create_os_window.argtypes = []
        create_os_window.restype = ctypes.c_ulonglong
        os_window_id = create_os_window()
        self.assertGreater(os_window_id, 0)

        remove_os_window = ffi.lib.remove_os_window
        remove_os_window.argtypes = [ctypes.c_ulonglong]
        remove_os_window.restype = ctypes.c_bool
        os_window_id_c = ctypes.c_ulonglong(os_window_id)
        self.addCleanup(lambda: remove_os_window(os_window_id_c))

        tab_id = fast_data_types.add_tab(os_window_id)
        self.assertIsInstance(tab_id, int)
        window_id = fast_data_types.add_window(os_window_id, tab_id, 'opengl-fallback')
        self.assertIsInstance(window_id, int)

        get_tab_bar_vao = ffi.lib.state_debug_get_tab_bar_vao_for_tests
        get_tab_bar_vao.argtypes = [ctypes.c_ulonglong]
        get_tab_bar_vao.restype = ctypes.c_longlong

        get_window_vao = ffi.lib.state_debug_get_window_vao_for_tests
        get_window_vao.argtypes = [ctypes.c_ulonglong, ctypes.c_ulonglong, ctypes.c_ulonglong]
        get_window_vao.restype = ctypes.c_longlong

        tab_id_c = ctypes.c_ulonglong(tab_id)
        window_id_c = ctypes.c_ulonglong(window_id)

        self.assertEqual(
            get_tab_bar_vao(os_window_id_c),
            -1,
            'Metal-backed tab bar should not allocate an OpenGL VAO',
        )
        self.assertEqual(
            get_window_vao(os_window_id_c, tab_id_c, window_id_c),
            -1,
            'Metal-backed window should not allocate an OpenGL VAO',
        )

        renderer_backend_select('opengl')

        window_vao = get_window_vao(os_window_id_c, tab_id_c, window_id_c)
        tab_bar_vao = get_tab_bar_vao(os_window_id_c)

        self.assertGreaterEqual(
            window_vao,
            0,
            'OpenGL fallback must allocate a window VAO',
        )
        self.assertGreaterEqual(
            tab_bar_vao,
            0,
            'OpenGL fallback must allocate a tab bar VAO',
        )

    def test_tab_bar_upload_without_screen_returns_false(self) -> None:
        if 'metal' not in self.available or 'opengl' not in self.available:
            self.skipTest('Requires both Metal and OpenGL backends')
        if not hasattr(ffi.lib, 'state_debug_upload_tab_bar_for_tests'):
            self.skipTest('Tab bar upload debug helper unavailable')

        renderer_backend_select('metal')

        create_os_window = ffi.lib.state_debug_add_os_window_for_tests
        create_os_window.argtypes = []
        create_os_window.restype = ctypes.c_ulonglong
        os_window_id = create_os_window()
        self.assertGreater(os_window_id, 0)
        os_window_id_c = ctypes.c_ulonglong(os_window_id)

        remove_os_window = ffi.lib.remove_os_window
        remove_os_window.argtypes = [ctypes.c_ulonglong]
        remove_os_window.restype = ctypes.c_bool
        self.addCleanup(lambda: remove_os_window(os_window_id_c))

        renderer_backend_select('opengl')

        upload_tab_bar = ffi.lib.state_debug_upload_tab_bar_for_tests
        upload_tab_bar.argtypes = [ctypes.c_ulonglong]
        upload_tab_bar.restype = ctypes.c_bool

        self.assertFalse(
            upload_tab_bar(os_window_id_c),
            'Tab bar upload should be a no-op when the screen is unset',
        )

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


class TestMetalGraphicsTextures(BaseTest):

    def setUp(self) -> None:
        super().setUp()
        if not ffi.has_metal or sys.platform != 'darwin':
            self.skipTest("Metal backend unavailable on this platform")
        ffi.reset()
        previous = renderer_backend_current()
        renderer_backend_select('metal')
        self.addCleanup(renderer_backend_select, previous)

    def _make_upload(
        self,
        data: ctypes.Array,
        *,
        width: int,
        height: int,
        is_opaque: bool,
        linear: bool,
        repeat: int,
    ):
        upload = ffi.RendererGraphicsImageUpload()
        upload.pixels = ctypes.cast(data, ctypes.c_void_p)
        upload.width = width
        upload.height = height
        upload.is_opaque = 1 if is_opaque else 0
        upload.is_4byte_aligned = 1
        upload.linear_filter = 1 if linear else 0
        upload._pad0 = 0
        upload.repeat = repeat
        return upload

    def test_upload_rgba_texture_metadata(self) -> None:
        tex = ffi.TextureRef()
        width, height = 2, 2
        rgba = (ctypes.c_uint8 * (width * height * 4))(
            255, 0, 0, 128,
            0, 255, 0, 255,
            0, 0, 255, 64,
            255, 255, 255, 255,
        )
        upload = self._make_upload(
            rgba,
            width=width,
            height=height,
            is_opaque=False,
            linear=True,
            repeat=ffi.RepeatStrategy.DEFAULT,
        )
        ok = ffi.lib.renderer_backend_upload_graphics_image(
            ctypes.byref(tex), ctypes.byref(upload)
        )
        self.assertTrue(ok, "Metal graphics upload should succeed for RGBA data")
        self.assertNotEqual(tex.id, 0)
        self.assertTrue(tex.backend_handle)
        info = ffi.graphics_texture_info(tex.id)
        self.assertIsNotNone(info)
        assert info is not None
        self.assertEqual(info.width, width)
        self.assertEqual(info.height, height)
        self.assertTrue(info.linear_filter)
        self.assertFalse(info.is_opaque)
        self.assertEqual(info.repeat, ffi.RepeatStrategy.DEFAULT)
        texture_id = tex.id
        ffi.lib.renderer_backend_destroy_graphics_image(ctypes.byref(tex))
        self.assertEqual(tex.id, 0)
        self.assertFalse(tex.backend_handle)
        self.assertIsNone(
            ffi.graphics_texture_info(texture_id),
            "Destroy should remove Metal texture from debug map",
        )

    def test_upload_rgb_texture_marks_opaque(self) -> None:
        tex = ffi.TextureRef()
        width, height = 1, 2
        rgb = (ctypes.c_uint8 * (width * height * 3))(
            10, 20, 30,
            200, 210, 220,
        )
        upload = self._make_upload(
            rgb,
            width=width,
            height=height,
            is_opaque=True,
            linear=False,
            repeat=ffi.RepeatStrategy.CLAMP,
        )
        ok = ffi.lib.renderer_backend_upload_graphics_image(
            ctypes.byref(tex), ctypes.byref(upload)
        )
        self.assertTrue(ok)
        info = ffi.graphics_texture_info(tex.id)
        self.assertIsNotNone(info)
        assert info is not None
        self.assertEqual(info.width, width)
        self.assertEqual(info.height, height)
        self.assertFalse(info.linear_filter)
        self.assertTrue(info.is_opaque)
        self.assertEqual(info.repeat, ffi.RepeatStrategy.CLAMP)
        ffi.lib.renderer_backend_destroy_graphics_image(ctypes.byref(tex))

    def test_destroy_graphics_texture_clears_state(self) -> None:
        tex = ffi.TextureRef()
        width = height = 1
        rgba = (ctypes.c_uint8 * 4)(0, 0, 0, 255)
        upload = self._make_upload(
            rgba,
            width=width,
            height=height,
            is_opaque=False,
            linear=True,
            repeat=ffi.RepeatStrategy.DEFAULT,
        )
        self.assertTrue(
            ffi.lib.renderer_backend_upload_graphics_image(
                ctypes.byref(tex), ctypes.byref(upload)
            )
        )
        texture_id = tex.id
        ffi.lib.renderer_backend_destroy_graphics_image(ctypes.byref(tex))
        self.assertEqual(tex.id, 0)
        self.assertIsNone(
            ffi.graphics_texture_info(texture_id),
            "Destroyed Metal texture should not be reported by debug helper",
        )
