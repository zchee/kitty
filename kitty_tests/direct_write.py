#!/usr/bin/env python
# License: GPL v3 Copyright: 2026, Kovid Goyal <kovid at kovidgoyal.net>

# W28.2 B2 ordering stress (plan §W28.2): the KITTY_DIRECT_KEY_WRITE lever
# writes keystroke-sized payloads inline at the scheduling site while the io
# thread keeps draining queued data. Ordering across the two lanes is a
# claim this test ASSERTS, never assumes: a real pty pair (no mocks), a
# monotonic sequence-token stream mixing direct-eligible single tokens with
# fallback-forcing batches, and a strict receive-order check on the child
# side. Denominators are asserted non-zero for BOTH lanes so a latched-off
# gate or an all-fallback run fails loudly instead of passing vacuously.

import os
import subprocess
import threading
import time
import tty
from contextlib import suppress

from kitty.fast_data_types import ChildMonitor, direct_write_counters

from . import BaseTest

# ChildMonitor is one-per-process (the C layer keeps a static the_monitor
# pointer and dealloc does not clear it), so the instance is created once
# and kept alive for the life of the test process.
_monitor = None

CHILD_ID = 1
TOKEN_FMT = b'%08d\n'
TOKEN_SZ = 9
# Plan §3 AC5 (frozen): zero ordering violations across >= 10^6 INTERLEAVED
# direct/queued write operations. 2.5M tokens at 41 write ops per 100-token
# cycle = 1_025_000 ops (asserted below, not assumed), ~22 MiB through a
# 1024-byte XNU pty queue: hundreds of thousands of EAGAIN/partial-write
# boundaries, both lanes exercised heavily.
NUM_TOKENS = 2_500_000
MIN_WRITE_OPS = 1_000_000
# Per 100-token cycle: 40 single-token writes (9 B <= 256, direct-eligible)
# then one 60-token batch (540 B > 256, always the queued/fallback lane).
SINGLES_PER_CYCLE = 40
CYCLE = 100
# Drain window every DRAIN_EVERY cycles: lets the io thread empty the queue
# so the next cycle's first singles hit the direct lane again — each window
# is a queued->direct boundary crossing, the exact interleave AC5 is about.
DRAIN_EVERY = 4
DEADLINE_S = 600.0


class TestDirectWrite(BaseTest):

    def test_direct_write_ordering_stress(self):
        global _monitor
        # A pid that is guaranteed dead before the monitor exists: shutdown's
        # cleanup_child -> hangup(pid) must hit ESRCH, never a live pgid.
        proc = subprocess.Popen(['/usr/bin/true'])
        proc.wait()
        dead_pid = proc.pid

        # The C gate is a one-shot cached bool: it must be in the
        # environment before the first schedule_write_to_child call in this
        # process. The direct_writes > 0 assertion below is the loud failure
        # if some earlier caller ever latches it off.
        os.environ['KITTY_DIRECT_KEY_WRITE'] = '1'

        master, slave = os.openpty()
        # Raw slave: no ECHO (nothing flows child->master) and no input
        # transformation, so the child-side byte stream is exactly what was
        # written, in kernel delivery order.
        tty.setraw(slave)
        # Mirror kitty/child.py's pty setup: the master must be O_NONBLOCK
        # (try_direct_write refuses the fd otherwise, by spec).
        os.set_blocking(master, False)

        screen = self.create_screen()
        if _monitor is None:
            _monitor = ChildMonitor(lambda *a: None, None)
        cm = _monitor
        cm.add_child(CHILD_ID, dead_pid, master, master, screen)
        cm.start()
        try:
            # add_queue -> children[] transfer happens on the io thread;
            # until then writes are not routable (needs_write returns False).
            st = time.monotonic()
            while not cm.needs_write(CHILD_ID, b''):
                if time.monotonic() - st > 10:
                    self.fail('io thread never adopted the child from the add queue')
                time.sleep(0.005)

            received = bytearray()
            expected_bytes = NUM_TOKENS * TOKEN_SZ
            stop_reading = threading.Event()

            def reader():
                # Periodic stalls let the 1024-byte pty queue fill so the
                # writer side sees EAGAIN and partial writes (the
                # remainder-requeue path), not just clean full writes.
                reads = 0
                while len(received) < expected_bytes and not stop_reading.is_set():
                    with suppress(OSError):
                        chunk = os.read(slave, 65536)
                        if not chunk:
                            break
                        received.extend(chunk)
                    reads += 1
                    if reads % 200 == 0:
                        time.sleep(0.001)

            rt = threading.Thread(target=reader, name='DirectWriteStressReader', daemon=True)
            rt.start()

            # Deltas, not absolutes: the counters are cumulative and the
            # process may some day run other direct-write work first.
            direct0, fallbacks0 = direct_write_counters()

            deadline = time.monotonic() + DEADLINE_S
            seq = 0
            write_ops = 0
            cycles = 0
            while seq < NUM_TOKENS:
                for _ in range(min(SINGLES_PER_CYCLE, NUM_TOKENS - seq)):
                    self.assertTrue(cm.needs_write(CHILD_ID, TOKEN_FMT % seq), f'needs_write refused token {seq}')
                    seq += 1
                    write_ops += 1
                batch_n = min(CYCLE - SINGLES_PER_CYCLE, NUM_TOKENS - seq)
                if batch_n:
                    batch = b''.join(TOKEN_FMT % s for s in range(seq, seq + batch_n))
                    self.assertTrue(cm.needs_write(CHILD_ID, batch), f'needs_write refused batch at token {seq}')
                    seq += batch_n
                    write_ops += 1
                cycles += 1
                if cycles % DRAIN_EVERY == 0:
                    time.sleep(0.0003)
                if time.monotonic() > deadline:
                    self.fail(f'writer did not finish before deadline: queued {seq}/{NUM_TOKENS} tokens')
            # AC5 magnitude is a denominator, asserted rather than assumed.
            self.assertGreaterEqual(write_ops, MIN_WRITE_OPS, f'stress issued only {write_ops} write ops')

            while len(received) < expected_bytes and time.monotonic() < deadline:
                time.sleep(0.01)
            stop_reading.set()
            rt.join(timeout=10)

            direct1, fallbacks1 = direct_write_counters()
            direct, fallbacks = direct1 - direct0, fallbacks1 - fallbacks0
            context = (
                f'write_ops={write_ops} direct_writes={direct} direct_write_fallbacks={fallbacks}'
                f' received={len(received)}/{expected_bytes} bytes'
            )
            self.assertEqual(len(received), expected_bytes, f'child did not receive the full stream: {context}')

            lines = bytes(received).split(b'\n')
            self.assertEqual(lines[-1], b'', f'stream did not end on a token boundary: {context}')
            tokens = [int(x) for x in lines[:-1]]
            self.assertEqual(len(tokens), NUM_TOKENS, f'token count mismatch: {context}')
            for idx, tok in enumerate(tokens):
                if tok != idx:
                    prev = tokens[max(0, idx - 3):idx]
                    self.fail(
                        f'receive order broke at index {idx}: got token {tok},'
                        f' expected {idx} (previous tokens: {prev}); {context}'
                    )

            # Denominator rule: both lanes must actually have fired.
            self.assertGreater(direct, 0, f'direct lane never fired (gate latched off?): {context}')
            self.assertGreater(fallbacks, 0, f'fallback lane never fired (stress not adversarial): {context}')
        finally:
            cm.shutdown_monitor()  # joins the io thread; cleanup_child closes the master fd
            with suppress(OSError):
                os.close(slave)
