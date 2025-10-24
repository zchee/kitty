#!/usr/bin/env python
# License: GPL v3

from pathlib import Path
from typing import Any, Dict

from . import BaseTest


class TestMetalShaderMetadata(BaseTest):
    def setUp(self) -> None:
        super().setUp()
        from kitty.metal import _reset_shader_metadata_cache_for_tests

        _reset_shader_metadata_cache_for_tests()

    def test_metadata_structure(self) -> None:
        from kitty import metal

        metadata: Dict[str, Any] = metal.get_shader_metadata()
        self.assertIn("schema", metadata)
        self.assertEqual(metadata["schema"], 1)
        shaders = metadata.get("shaders")
        self.assertIsInstance(shaders, dict)
        self.assertIn("cell", shaders)

        cell = shaders["cell"]
        self.assertEqual(cell["metallib"], "cell.metallib")
        self.assertEqual(cell["source"], "cell.metal")
        self.assertIn("source_hash", cell)

        constants = cell.get("constants")
        self.assertIsInstance(constants, dict)
        self.assertIn("MetalCellNumColors", constants)
        self.assertIn("SPRITE_INDEX_MASK", constants)

        metallib_path = Path(__file__).resolve().parents[1] / "kitty" / "metal" / cell["metallib"]
        self.assertTrue(metallib_path.is_file(), f"Missing metallib at {metallib_path}")

    def test_metadata_cached(self) -> None:
        from kitty import metal

        first = metal.get_shader_metadata()
        second = metal.get_shader_metadata()
        self.assertIs(first, second)
