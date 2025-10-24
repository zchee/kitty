import importlib.resources
import sys
import unittest
from pathlib import Path
from unittest import mock


class TestMetalResources(unittest.TestCase):
    def test_metal_sources_present(self) -> None:
        metal_pkg = importlib.resources.files('kitty.metal')
        root_pkg = importlib.resources.files('kitty')
        self.assertTrue((metal_pkg / 'cell.metal').is_file(), 'Missing cell.metal')
        self.assertTrue((root_pkg / 'srgb_gamma_values.inc').is_file(), 'Missing srgb gamma LUT include')

    @unittest.skipUnless(sys.platform == 'darwin', 'Metal metallib generation only relevant on macOS')
    def test_metallib_artifact_exists_or_compilation_needed(self) -> None:
        pkg = importlib.resources.files('kitty.metal')
        metallib = pkg / 'cell.metallib'
        if not metallib.is_file():
            self.skipTest('cell.metallib not built yet; run setup.py build to generate')
        self.assertGreater(metallib.stat().st_size, 0, 'cell.metallib is empty')

    @unittest.skipUnless(sys.platform == 'darwin', 'Metal metallib caching only relevant on macOS')
    def test_metallib_helper_caches_path(self) -> None:
        from kitty import metal as metal_pkg

        metal_pkg._reset_cell_metallib_cache_for_tests()
        pkg = importlib.resources.files('kitty.metal')
        metallib = pkg / 'cell.metallib'
        if not metallib.is_file():
            self.skipTest('cell.metallib not built yet; run setup.py build to generate')

        with mock.patch('importlib.resources.as_file', wraps=importlib.resources.as_file) as spy:
            path1 = Path(metal_pkg.get_cell_metallib_path())
            self.assertTrue(path1.is_file(), 'helper returned a non-existent path')
            path2 = Path(metal_pkg.get_cell_metallib_path())
        self.assertEqual(path1, path2, 'helper did not reuse cached metallib path')
        self.assertEqual(spy.call_count, 1, 'helper should extract metallib exactly once per process')
        metal_pkg._reset_cell_metallib_cache_for_tests()

    @unittest.skipUnless(sys.platform == 'darwin', 'Metal metallib caching only relevant on macOS')
    def test_metallib_helper_propagates_missing_resource(self) -> None:
        from kitty import metal as metal_pkg

        metal_pkg._reset_cell_metallib_cache_for_tests()
        with mock.patch('importlib.resources.as_file', side_effect=FileNotFoundError('boom')):
            with self.assertRaises(FileNotFoundError):
                metal_pkg.get_cell_metallib_path()
        metal_pkg._reset_cell_metallib_cache_for_tests()
