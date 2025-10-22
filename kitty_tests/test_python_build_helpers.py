import os
import unittest

from kitty.python_build_helpers import resolve_framework_library


class ResolveFrameworkLibraryTests(unittest.TestCase):
    def test_prefers_pythont_when_gil_disabled(self) -> None:
        framework_dir = '/Frameworks'
        version = '3.13'

        def fake_isdir(p: str) -> bool:
            return p == os.path.join(framework_dir, 'PythonT.framework')

        def fake_exists(p: str) -> bool:
            return p == os.path.join(framework_dir, 'PythonT.framework/Versions/3.13/PythonT')

        path = resolve_framework_library(
            framework_dir,
            version,
            'Python',
            'Python.framework/Versions/3.13/Python',
            True,
            isdir=fake_isdir,
            exists=fake_exists,
        )
        self.assertEqual(path, '/Frameworks/PythonT.framework/Versions/3.13/PythonT')

    def test_falls_back_to_reported_library_when_t_not_available(self) -> None:
        framework_dir = '/Frameworks'
        version = '3.13'
        path = resolve_framework_library(
            framework_dir,
            version,
            'Python',
            'Python.framework/Versions/3.13/Python',
            True,
            isdir=lambda _: False,
            exists=lambda _: False,
        )
        self.assertEqual(path, '/Frameworks/Python.framework/Versions/3.13/Python')

    def test_respects_existing_framework_name(self) -> None:
        framework_dir = '/Frameworks'
        version = '3.13'
        path = resolve_framework_library(
            framework_dir,
            version,
            'PythonT',
            'PythonT.framework/Versions/3.13/PythonT',
            True,
            isdir=lambda _: True,
            exists=lambda _: True,
        )
        self.assertEqual(path, '/Frameworks/PythonT.framework/Versions/3.13/PythonT')
