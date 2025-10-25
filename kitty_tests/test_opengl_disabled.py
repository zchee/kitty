import sys
import unittest
from importlib import reload


@unittest.skipUnless(sys.platform == "darwin", "OpenGL stubs only active on macOS")
class TestOpenGLDisabledExports(unittest.TestCase):
    def setUp(self) -> None:
        import kitty.fast_data_types as fdt

        self.fast_data_types = reload(fdt)

    def test_shader_program_constants_present(self) -> None:
        fdt = self.fast_data_types
        expected_program_ids = {
            "CELL_PROGRAM": 0,
            "CELL_FG_PROGRAM": 1,
            "CELL_BG_PROGRAM": 2,
            "BORDERS_PROGRAM": 3,
            "GRAPHICS_PROGRAM": 4,
        }
        for name, value in expected_program_ids.items():
            with self.subTest(name=name):
                self.assertTrue(
                    hasattr(fdt, name),
                    f"{name} should be exported when OpenGL renderer is disabled",
                )
                self.assertEqual(
                    getattr(fdt, name),
                    value,
                    f"{name} should retain its numeric identifier",
                )
        for gl_constant in ("GL_TRIANGLE_FAN", "GL_TEXTURE_BUFFER", "GL_UNIFORM_BUFFER"):
            with self.subTest(gl_constant=gl_constant):
                self.assertTrue(
                    hasattr(fdt, gl_constant),
                    f"{gl_constant} should remain available for compatibility checks",
                )

    def test_shader_helper_methods_raise_runtime_error(self) -> None:
        fdt = self.fast_data_types
        checks: list[tuple[str, tuple[object, ...]]] = [
            ("compile_program", ()),
            ("sprite_map_set_limits", ()),
            ("create_vao", ()),
            ("gpu_driver_version_string", ()),
            ("bind_vertex_array", (0,)),
            ("unbind_vertex_array", ()),
            ("unmap_vao_buffer", (None, None)),
            ("bind_program", (0,)),
            ("unbind_program", ()),
            ("init_borders_program", ()),
            ("init_cell_program", ()),
        ]
        for name, args in checks:
            with self.subTest(name=name):
                func = getattr(fdt, name)
                with self.assertRaises(RuntimeError) as exc:
                    func(*args)
                message = str(exc.exception)
                self.assertIn(
                    "OpenGL renderer is disabled",
                    message,
                    "Stub error message should explain OpenGL path is unavailable",
                )
                self.assertIn(
                    name,
                    message,
                    "Stub error message should include the helper name for diagnostics",
                )

