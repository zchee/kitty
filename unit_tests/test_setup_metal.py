import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import setup


class MetalToolCmdTests(unittest.TestCase):

    def test_metal_tool_cmd_includes_macos_sdk(self) -> None:
        cmd = setup.metal_tool_cmd('/usr/bin/xcrun', 'metallib')
        self.assertEqual(
            cmd,
            ['/usr/bin/xcrun', '--sdk', 'macosx', 'metallib'],
        )


class CompileMetalShadersTests(unittest.TestCase):

    def setUp(self) -> None:
        self.tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmpdir.cleanup)
        self._orig_src_base = setup.src_base
        self._orig_build_dir = setup.build_dir
        self._orig_is_macos = setup.is_macos
        setup.src_base = self.tmpdir.name
        setup.build_dir = os.path.join(self.tmpdir.name, 'build')
        setup.is_macos = True
        metal_dir = Path(self.tmpdir.name) / 'kitty' / 'metal'
        metal_dir.mkdir(parents=True, exist_ok=True)
        (metal_dir / 'cell.metal').write_text('kernel void dummy() {}')
        self.addCleanup(self._restore_globals)

    def _restore_globals(self) -> None:
        setup.src_base = self._orig_src_base
        setup.build_dir = self._orig_build_dir
        setup.is_macos = self._orig_is_macos

    def test_compile_metal_shaders_raises_when_tool_fails(self) -> None:
        with mock.patch('setup.shutil.which', return_value='/usr/bin/xcrun'), \
             mock.patch('setup.run_tool', side_effect=SystemExit(42)):
            with self.assertRaises(SystemExit) as excinfo:
                setup.compile_metal_shaders(object())
        self.assertIn('Metal shader build failed', str(excinfo.exception))

    def test_compile_metal_shaders_detects_stale_packaged_output(self) -> None:
        def fake_run_tool(cmd, desc=None):
            tool = cmd[3]
            out_index = cmd.index('-o') + 1
            output_path = Path(cmd[out_index])
            output_path.parent.mkdir(parents=True, exist_ok=True)
            output_path.write_text(tool)

        with mock.patch('setup.shutil.which', return_value='/usr/bin/xcrun'), \
             mock.patch('setup.run_tool', side_effect=fake_run_tool), \
             mock.patch('setup.shutil.copy2', side_effect=lambda src, dest: None):
            with self.assertRaises(SystemExit) as excinfo:
                setup.compile_metal_shaders(object())
        self.assertIn('Metal shader build failed', str(excinfo.exception))


class GetPythonFlagsTests(unittest.TestCase):

    def test_zero_string_flag_does_not_force_python_t(self) -> None:
        opts = setup.Options()
        cflags: list[str] = []

        include_path = '/Frameworks/Python.framework/Versions/3.13/include/python3.13'
        framework_root = '/Frameworks'

        def fake_get_config_var(name: str) -> str | None:
            mapping = {
                'LIBS': '',
                'SYSLIBS': '',
                'Py_GIL_DISABLED': '0',
                'PYTHONFRAMEWORK': 'Python',
                'VERSION': '3.13',
                'LDLIBRARY': 'Python.framework/Versions/3.13/Python',
            }
            return mapping.get(name)

        def fake_get_path(name: str) -> str | None:
            if name in {'data', 'include', 'stdlib'}:
                return f'{framework_root}/Python.framework/Versions/3.13/{name}'
            return None

        with mock.patch('setup.get_python_include_paths', return_value=[include_path]), \
             mock.patch('setup.sysconfig.get_config_var', side_effect=fake_get_config_var), \
             mock.patch('setup.sysconfig.get_path', side_effect=fake_get_path), \
             mock.patch('setup.os.path.isdir', return_value=True), \
             mock.patch('setup.resolve_framework_library', return_value='/Frameworks/Python') as resolve:
            libs = setup.get_python_flags(opts, cflags)
        self.assertIn('/Frameworks/Python', libs)
        called_args = resolve.call_args
        self.assertIsNotNone(called_args)
        self.assertFalse(called_args[0][4], 'gil_disabled should be False when flag is \"0\"')
        self.assertTrue(all('PythonT' not in lib for lib in libs))


class CreateMinimalBundleTests(unittest.TestCase):

    def setUp(self) -> None:
        self.tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmpdir.cleanup)
        self.launcher_root = Path(self.tmpdir.name) / 'launcher'
        self.launcher_root.mkdir()
        self._orig_src_base = setup.src_base
        setup.src_base = os.path.join(self.tmpdir.name, 'src')
        src_root = Path(setup.src_base)
        src_root.mkdir(parents=True, exist_ok=True)
        (src_root / 'fonts').mkdir(exist_ok=True)
        (src_root / 'shell-integration').mkdir(exist_ok=True)
        (src_root / 'shell-integration' / 'README').write_text('stub', encoding='utf-8')

    def tearDown(self) -> None:
        setup.src_base = self._orig_src_base

    @mock.patch('setup.create_quick_access_bundle')
    @mock.patch('setup.create_macos_app_icon')
    def test_minimal_bundle_symlinks_resources_before_kittens(
        self,
        mock_icon: mock.Mock,
        mock_quake: mock.Mock,
    ) -> None:
        resources_symlink_checked: list[Path] = []

        def fake_build_launcher(args: setup.Options, launcher_dir: str, bundle_type: str = 'source') -> None:
            Path(launcher_dir).mkdir(parents=True, exist_ok=True)
            (Path(launcher_dir) / 'kitty').touch()

        def fake_build_static(args: setup.Options, launcher_dir: str, **_: object) -> None:
            resources_dir = Path(launcher_dir).parent / 'Resources'
            dest = resources_dir / 'kitty'
            self.assertTrue(dest.is_symlink(), 'Resources/kitty should be a symlink before kittens build')
            resources_symlink_checked.append(dest)

        with mock.patch('setup.build_launcher', side_effect=fake_build_launcher) as mock_launcher, \
             mock.patch('setup.build_static_kittens', side_effect=fake_build_static) as mock_kittens:
            setup.create_minimal_macos_bundle(setup.Options(), str(self.launcher_root))

        self.assertTrue(mock_launcher.called)
        self.assertTrue(mock_kittens.called)
        resources_dir = self.launcher_root / 'kitty.app' / 'Contents' / 'Resources'
        dest = resources_dir / 'kitty'
        self.assertTrue(dest.is_symlink())
        expected_target = os.path.relpath(setup.src_base, str(resources_dir))
        self.assertEqual(os.readlink(dest), expected_target)
        self.assertTrue((dest / 'fonts').exists(), 'fonts directory should be reachable via symlink')
        self.assertTrue((dest / 'shell-integration').exists(), 'shell-integration should be reachable via symlink')
        self.assertTrue(resources_symlink_checked, 'Test should observe build_static_kittens execution')


class KittyEnvMetalTests(unittest.TestCase):

    @mock.patch('setup.xxhash_flags', return_value=([], []))
    @mock.patch('setup.libcrypto_flags', return_value=([], []))
    @mock.patch('setup.get_python_flags', return_value=[])
    @mock.patch('setup.pkg_config', return_value=[])
    @mock.patch('setup.homebrew_prefix', return_value='/opt/homebrew')
    @mock.patch('setup.at_least_version', return_value=None)
    def test_kitty_env_drops_opengl_framework(
        self,
        mock_at_least_version: mock.Mock,
        mock_homebrew_prefix: mock.Mock,
        mock_pkg_config: mock.Mock,
        mock_get_python_flags: mock.Mock,
        mock_libcrypto_flags: mock.Mock,
        mock_xxhash_flags: mock.Mock,
    ) -> None:
        original_env = setup.env
        original_is_macos = setup.is_macos
        try:
            setup.is_macos = True
            setup.env = setup.Env()
            env = setup.kitty_env(setup.Options())
        finally:
            setup.env = original_env
            setup.is_macos = original_is_macos

        ldflags_combined = ' '.join(env.ldpaths)
        self.assertNotIn('OpenGL', ldflags_combined)
        self.assertIn('Metal', ldflags_combined)


if __name__ == '__main__':
    unittest.main()
