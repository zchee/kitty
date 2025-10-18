import importlib.resources
import sys
import unittest


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
