import unittest

import setup


class MetalToolCmdTests(unittest.TestCase):

    def test_metal_tool_cmd_includes_macos_sdk(self) -> None:
        cmd = setup.metal_tool_cmd('/usr/bin/xcrun', 'metallib')
        self.assertEqual(
            cmd,
            ['/usr/bin/xcrun', '--sdk', 'macosx', 'metallib'],
        )


if __name__ == '__main__':
    unittest.main()
