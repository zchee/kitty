#!/usr/bin/env python3
# License: GPLv3 Copyright: 2026, Kovid Goyal <kovid at kovidgoyal.net>

# Standalone validation of the Phase-12 SPSC input ring
# (kitty/vt-input-ring.h) with real producer/consumer threads: in-order
# lossless delivery (seeded stream compare), back-pressure without loss
# (max_used == capacity + producer zero-windows + deterministic consumer
# stalls), wrap-around, partial writes, and the FR-1
# covered-or-fail-open timestamp contract (quiescent pending bytes are
# covered; reachable transients can only open the input_delay gate
# early - each racy resolution path is pinned by the deterministic
# interleaving proofs in spsc_ring_check.c). Two builds
# run always: the default 1 MiB ring and a 4 KiB ring that maximizes
# full-ring transitions. ThreadSanitizer builds of both run when
# KITTY_RING_TSAN=1 (slow; used by the phase verification, not the
# default suite).

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

SRC = Path(__file__).parent / 'spsc_ring_check.c'
KITTY_INC = Path(__file__).parent.parent / 'kitty'


class TestSPSCRing(unittest.TestCase):

    def build_and_run(self, name: str, extra_cflags=(), seed: str = '0x5eed') -> str:
        with tempfile.TemporaryDirectory(prefix=f'spsc-{name}-') as td:
            exe = os.path.join(td, name)
            cmd = [
                'cc', '-O1', '-std=c11', '-Wall', '-Wextra', '-Werror',
                *extra_cflags, '-I', str(KITTY_INC), str(SRC), '-o', exe, '-lpthread',
            ]
            cp = subprocess.run(cmd, capture_output=True, text=True)
            self.assertEqual(cp.returncode, 0, f'compile failed: {cp.stderr}')
            run = subprocess.run([exe, seed], capture_output=True, text=True, timeout=600)
            self.assertEqual(run.returncode, 0, f'{name} failed:\n{run.stdout}\n{run.stderr}')
            self.assertIn('OK bytes=', run.stdout, run.stdout)
            self.assertNotIn('ThreadSanitizer', run.stderr, run.stderr)
            return run.stdout + run.stderr

    def test_spsc_ring(self):
        out = self.build_and_run('ring-default')
        self.assertIn('max_used=1048576/1048576', out, 'back-pressure never engaged: ' + out)
        out = self.build_and_run('ring-small', extra_cflags=('-DVT_RING_SZ=4096u',))
        self.assertIn('max_used=4096/4096', out, 'back-pressure never engaged: ' + out)

    @unittest.skipUnless(os.environ.get('KITTY_RING_TSAN') == '1', 'slow; set KITTY_RING_TSAN=1')
    def test_spsc_ring_tsan(self):
        self.build_and_run('ring-tsan', extra_cflags=('-fsanitize=thread',), seed='0xfeed')
        # the small ring reaches full-ring transitions even under TSan
        # slowdown, so the back-pressure paths are sanitized too
        out = self.build_and_run('ring-tsan-small', extra_cflags=('-fsanitize=thread', '-DVT_RING_SZ=4096u'), seed='0xbeef')
        self.assertIn('max_used=4096/4096', out, out)
