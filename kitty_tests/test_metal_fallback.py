#!/usr/bin/env python

from __future__ import annotations

import os
import subprocess
import sys
import unittest
from contextlib import contextmanager
from importlib import resources
from pathlib import Path


@contextmanager
def temporarily_rename(path: Path) -> tuple[Path, Path]:
    backup = path.with_suffix(path.suffix + ".bak")
    os.replace(path, backup)
    try:
        yield path, backup
    finally:
        os.replace(backup, path)


class MetalFallbackTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        if sys.platform != "darwin":
            raise unittest.SkipTest("Metal backend only available on macOS")
        try:
            import kitty.fast_data_types as fast_data_types  # noqa: F401
        except ImportError:
            raise unittest.SkipTest("kitty.fast_data_types extension not built")
        cls.fast_data_types = fast_data_types
        try:
            metallib_res = resources.files("kitty.metal") / "cell.metallib"
        except (AttributeError, ModuleNotFoundError):
            raise unittest.SkipTest("kitty.metal package not available")
        with resources.as_file(metallib_res) as p:
            metallib_path = Path(p)
        if not metallib_path.exists():
            raise unittest.SkipTest("cell.metallib not present; nothing to test")
        cls.metallib_path = metallib_path

    def test_preflight_reports_missing_metallib(self) -> None:
        script = r"""
import ctypes
import sys
import kitty.fast_data_types as fast_data_types

lib = ctypes.CDLL(fast_data_types.__file__)
if not hasattr(lib, "metal_renderer_preflight"):
    print("skip")
    sys.exit(0)
reason = ctypes.c_char_p()
lib.metal_renderer_preflight.argtypes = [ctypes.POINTER(ctypes.c_char_p)]
lib.metal_renderer_preflight.restype = ctypes.c_bool
ok = lib.metal_renderer_preflight(ctypes.byref(reason))
print(int(ok))
if reason.value:
    print(reason.value.decode("utf-8", "replace"))
"""
        with temporarily_rename(self.metallib_path):
            proc = subprocess.run(
                [sys.executable, "-c", script],
                capture_output=True,
                text=True,
                env=os.environ.copy(),
                check=True,
            )
        output = [line for line in proc.stdout.strip().splitlines() if line]
        if output and output[0] == "skip":
            self.skipTest("Metal symbols not exported in fast_data_types")
        self.assertTrue(output, msg=f"expected output, got {proc.stdout}")
        self.assertEqual(output[0], "0", msg=f"preflight unexpectedly succeeded: {output}")
        if len(output) > 1:
            self.assertIn("Metal", output[1], msg=f"unexpected reason string: {output[1]}")


if __name__ == "__main__":
    unittest.main()
