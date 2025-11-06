#!/usr/bin/env python3
# License: GPL v3

import os
import subprocess
import sys
import unittest


@unittest.skipUnless(sys.platform == 'darwin', 'Metal backend is Darwin only')
class MetalBootstrapTest(unittest.TestCase):
    def test_fast_data_types_module_initializes(self) -> None:
        env = os.environ.copy()
        env['KITTY_GPU_BACKEND'] = 'metal'
        cmd = [
            sys.executable,
            '-c',
            (
                'import os; os.environ["KITTY_GPU_BACKEND"]="metal"; '
                'import kitty.fast_data_types; print("metal-backend-ok")'
            ),
        ]
        proc = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
            check=False,
        )
        self.assertEqual(
            proc.returncode, 0,
            f'bootstrap command failed: stdout={proc.stdout!r} stderr={proc.stderr!r}',
        )
        self.assertIn('metal-backend-ok', proc.stdout)


if __name__ == '__main__':
    unittest.main()

