import ctypes
import math
import sys

from . import BaseTest
from .renderer_backend import ffi


class TestMetalBackgroundGeometry(BaseTest):

    def setUp(self) -> None:
        super().setUp()
        if not ffi.has_metal or not ffi._has_background_geometry:
            self.skipTest("Metal background geometry helpers unavailable")
        self.addCleanup(ffi.reset)
        ffi.reset()

    def assertSequenceAlmostEqual(self, left, right, *, places=5):  # type: ignore[override]
        for a, b in zip(left, right):
            self.assertAlmostEqual(a, b, places=places)

    def test_tiling_geometry_matches_window_extents(self) -> None:
        ok, geometry = ffi.compute_background_geometry(
            framebuffer_width=800,
            framebuffer_height=600,
            image_width=200,
            image_height=120,
            layout=ffi.BackgroundImageLayout.TILING,
        )
        self.assertTrue(ok)
        self.assertAlmostEqual(geometry.tiled, 1.0, places=6)
        self.assertSequenceAlmostEqual(geometry.positions, (-1.0, 1.0, 1.0, -1.0))
        self.assertSequenceAlmostEqual(geometry.sizes, (800.0, 600.0, 200.0, 120.0))

    def test_center_scaled_geometry_respects_aspect_ratio(self) -> None:
        ok, geometry = ffi.compute_background_geometry(
            framebuffer_width=800,
            framebuffer_height=600,
            image_width=1600,
            image_height=400,
            layout=ffi.BackgroundImageLayout.CENTER_SCALED,
        )
        self.assertTrue(ok)
        self.assertAlmostEqual(geometry.tiled, 0.0, places=6)
        # Image wider than viewport: expect full width, scaled height.
        expected_scaled_height = 800.0 / (1600.0 / 400.0)
        expected_positions = (
            -1.0,
            1.0 - (600.0 - expected_scaled_height) / 600.0,
            1.0,
            -1.0 + (600.0 - expected_scaled_height) / 600.0,
        )
        self.assertSequenceAlmostEqual(geometry.positions, expected_positions)
        self.assertSequenceAlmostEqual(
            geometry.sizes,
            (800.0, 600.0, 800.0, expected_scaled_height),
        )


class TestMetalBackgroundUpload(BaseTest):
    def setUp(self) -> None:
        super().setUp()
        if not ffi.has_metal:
            self.skipTest("Metal backend not available")
        if not hasattr(ffi, "BackgroundImage") or not hasattr(
            ffi.lib, "metal_background_image_uploaded"
        ):
            self.skipTest("Metal background upload helpers unavailable")
        self.addCleanup(ffi.reset)
        ffi.reset()

    @staticmethod
    def _make_pixels(width: int, height: int) -> ctypes.Array[ctypes.c_uint8]:
        count = width * height * 4
        pixels = (ctypes.c_uint8 * count)()
        for i in range(count):
            pixels[i] = ctypes.c_uint8((17 * i) & 0xFF)
        return pixels

    def test_upload_sets_metal_texture_without_gl_id(self) -> None:
        bg = ffi.BackgroundImage()
        bg.width = 2
        bg.height = 1
        pixels = self._make_pixels(bg.width, bg.height)
        bg.bitmap = pixels
        bg.mmap_size = 0

        ffi.lib.metal_background_image_uploaded(
            ctypes.byref(bg),
            ffi.BackgroundImageLayout.TILING,
            ctypes.c_bool(False),
        )
        self.addCleanup(ffi.lib.metal_background_image_release, ctypes.byref(bg))

        # Metal path should not rely on a GL texture id.
        self.assertEqual(bg.texture_id, 0)
        self.assertNotEqual(bg.metal_texture, None)
        self.assertNotEqual(bg.metal_texture, 0)

        ffi.lib.metal_background_image_release(ctypes.byref(bg))
        self.assertEqual(bg.metal_texture, None)
