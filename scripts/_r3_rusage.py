#!/usr/bin/env python3.14
"""R3 per-process bill sampler: proc_pid_rusage(RUSAGE_INFO_V4) via ctypes.

Samples another process's lifetime resource bill without privileges (same
uid): CPU time (ri_user_time/ri_system_time, mach absolute ticks), OS
wakeups (ri_pkg_idle_wkups + ri_interrupt_wkups — the Activity Monitor
"Idle Wake Ups" pair), and ri_billed_energy (nJ, observational). Layout
generated verbatim from MacOSX.sdk sys/resource.h `struct rusage_info_v4`;
proc_pid_rusage is libproc.h, macOS 10.9+. Mach ticks convert to ns via
mach_timebase_info.

CLI: `--pid N` prints one JSON sample; `--selftest` spins this process ~2 s
and cross-checks the converted CPU delta against time.process_time().
"""

from __future__ import annotations

import ctypes
import json
import time

RUSAGE_INFO_V4 = 4


class RusageInfoV4(ctypes.Structure):
    _fields_ = [
        ("ri_uuid", ctypes.c_uint8 * 16),
        ("ri_user_time", ctypes.c_uint64),
        ("ri_system_time", ctypes.c_uint64),
        ("ri_pkg_idle_wkups", ctypes.c_uint64),
        ("ri_interrupt_wkups", ctypes.c_uint64),
        ("ri_pageins", ctypes.c_uint64),
        ("ri_wired_size", ctypes.c_uint64),
        ("ri_resident_size", ctypes.c_uint64),
        ("ri_phys_footprint", ctypes.c_uint64),
        ("ri_proc_start_abstime", ctypes.c_uint64),
        ("ri_proc_exit_abstime", ctypes.c_uint64),
        ("ri_child_user_time", ctypes.c_uint64),
        ("ri_child_system_time", ctypes.c_uint64),
        ("ri_child_pkg_idle_wkups", ctypes.c_uint64),
        ("ri_child_interrupt_wkups", ctypes.c_uint64),
        ("ri_child_pageins", ctypes.c_uint64),
        ("ri_child_elapsed_abstime", ctypes.c_uint64),
        ("ri_diskio_bytesread", ctypes.c_uint64),
        ("ri_diskio_byteswritten", ctypes.c_uint64),
        ("ri_cpu_time_qos_default", ctypes.c_uint64),
        ("ri_cpu_time_qos_maintenance", ctypes.c_uint64),
        ("ri_cpu_time_qos_background", ctypes.c_uint64),
        ("ri_cpu_time_qos_utility", ctypes.c_uint64),
        ("ri_cpu_time_qos_legacy", ctypes.c_uint64),
        ("ri_cpu_time_qos_user_initiated", ctypes.c_uint64),
        ("ri_cpu_time_qos_user_interactive", ctypes.c_uint64),
        ("ri_billed_system_time", ctypes.c_uint64),
        ("ri_serviced_system_time", ctypes.c_uint64),
        ("ri_logical_writes", ctypes.c_uint64),
        ("ri_lifetime_max_phys_footprint", ctypes.c_uint64),
        ("ri_instructions", ctypes.c_uint64),
        ("ri_cycles", ctypes.c_uint64),
        ("ri_billed_energy", ctypes.c_uint64),
        ("ri_serviced_energy", ctypes.c_uint64),
        ("ri_interval_max_phys_footprint", ctypes.c_uint64),
        ("ri_runnable_time", ctypes.c_uint64),
    ]


class _MachTimebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


_libproc = ctypes.CDLL("libproc.dylib", use_errno=True)
_libproc.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
_libproc.proc_pid_rusage.restype = ctypes.c_int

_libsys = ctypes.CDLL(None, use_errno=True)
_tb = _MachTimebase()
if _libsys.mach_timebase_info(ctypes.byref(_tb)) != 0:
    raise OSError("mach_timebase_info failed")


def ticks_to_ns(ticks: int) -> int:
    return ticks * _tb.numer // _tb.denom


def sample(pid: int) -> RusageInfoV4:
    buf = RusageInfoV4()
    if _libproc.proc_pid_rusage(pid, RUSAGE_INFO_V4, ctypes.byref(buf)) != 0:
        err = ctypes.get_errno()
        raise OSError(err, f"proc_pid_rusage(pid={pid}) failed")
    return buf


def snap(pid: int) -> dict[str, int]:
    """One lifetime-total sample with the derived bill fields."""
    s = sample(pid)
    return {
        "user_ns": ticks_to_ns(s.ri_user_time),
        "system_ns": ticks_to_ns(s.ri_system_time),
        "cpu_ns": ticks_to_ns(s.ri_user_time + s.ri_system_time),
        "pkg_idle_wkups": int(s.ri_pkg_idle_wkups),
        "interrupt_wkups": int(s.ri_interrupt_wkups),
        "wakeups": int(s.ri_pkg_idle_wkups + s.ri_interrupt_wkups),
        "billed_energy_nj": int(s.ri_billed_energy),
        "runnable_ns": ticks_to_ns(s.ri_runnable_time),
    }


def delta(before: dict[str, int], after: dict[str, int]) -> dict[str, int]:
    return {k: after[k] - before[k] for k in before}


def _selftest() -> int:
    import os

    t0 = time.process_time()
    deadline = t0 + 2.0
    x = 0
    while time.process_time() < deadline:
        x += 1
    reported = time.process_time() - t0
    measured = snap(os.getpid())["cpu_ns"] / 1e9
    # measured is lifetime CPU (includes interpreter startup); reported is the
    # spin span alone, so compare against lifetime process_time instead.
    lifetime = time.process_time()
    err = abs(measured - lifetime) / lifetime
    ok = err <= 0.05 and reported >= 1.9
    print(json.dumps({
        "spin_s": round(reported, 4), "lifetime_process_time_s": round(lifetime, 4),
        "rusage_cpu_s": round(measured, 4), "rel_err": round(err, 5),
        "timebase": [_tb.numer, _tb.denom], "ok": ok,
    }))
    return 0 if ok else 1


if __name__ == "__main__":
    import argparse
    import sys

    ap = argparse.ArgumentParser()
    ap.add_argument("--pid", type=int)
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()
    if args.selftest:
        raise SystemExit(_selftest())
    if args.pid is None:
        ap.error("--pid or --selftest required")
    print(json.dumps(snap(args.pid)))
    sys.exit(0)
