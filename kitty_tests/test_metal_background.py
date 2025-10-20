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
