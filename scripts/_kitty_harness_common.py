#!/usr/bin/env python3.14
"""Shared process-lifecycle and detection helpers for the Metal-backend
Phase-0 harness scripts (metal-baseline.py, metal-latency.py, metal-golden.py).

Not a standalone tool -- imported as a sibling module (Python adds a
directly-run script's own directory to sys.path[0], so `import
_kitty_harness_common` works from any script under scripts/ without extra
path setup).

Encodes the operational rules shared by every harness script that launches
throwaway kitty windows:
  - never build kitty (require_kitty_binary just asserts it exists);
  - refuse to run while .omc/build.lock is held (wait_for_build_lock_clear);
  - track every spawned kitty by its exact Popen PID, never by name/pattern;
    SIGTERM, a grace period, then SIGKILL as a last resort (terminate_kitty);
  - always launch with --config NONE and
    -o macos_quit_when_last_window_closed=yes (otherwise the app stays
    resident after its child process exits).
"""

from __future__ import annotations

import os
import platform
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parent.parent
KITTY_BINARY = REPO_ROOT / "kitty" / "launcher" / "kitty"
BUILD_LOCK = REPO_ROOT / ".omc" / "build.lock"

# metal_present line format, fixed by task #1's metal.m instrumentation
# (final, kitty/metal.m ~1657-1663):
#   metal_present frame=<uint64> presented_time=<float seconds, 9 decimals>
# presented_time is MTLDrawable.presentedTime -- host time in seconds, the
# same timebase as CACurrentMediaTime()/mach_absolute_time (see
# current_media_time() in metal-latency.py). Shared here because both
# metal-baseline.py (frame-count/availability check) and metal-latency.py
# (injection-to-present pairing) parse this same line.
PRESENTED_RE = re.compile(r"^metal_present\s+frame=(\d+)\s+presented_time=([\d.]+)\s*$", re.MULTILINE)


def percentile(values: list[float], pct: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    idx = max(0, min(len(ordered) - 1, round(pct / 100.0 * (len(ordered) - 1))))
    return ordered[idx]


def parse_presented_lines(text: str) -> tuple[list[tuple[int, float]], int]:
    """Parse metal_present lines into (frame, presented_time) pairs, time-sorted.

    Rows with presented_time == 0.000000000 are dropped -- a known
    first-drawable quirk (addPresentedHandler fires with a zero timestamp
    for the very first drawable of a session; not a real photon-present
    time). Returns (kept_pairs, dropped_zero_count).
    """
    raw = [(int(m.group(1)), float(m.group(2))) for m in PRESENTED_RE.finditer(text)]
    dropped_zero = sum(1 for _, t in raw if t == 0.0)
    kept = sorted((f, t) for f, t in raw if t != 0.0)
    return kept, dropped_zero


def require_kitty_binary() -> None:
    if not KITTY_BINARY.exists():
        print(f"ERROR: built kitty binary not found at {KITTY_BINARY}", file=sys.stderr)
        print("This script does not build kitty -- build it first:", file=sys.stderr)
        print("  KITTY_USE_METAL=1 python3.14 setup.py build   # Metal backend", file=sys.stderr)
        print("  python3.14 setup.py build                     # GL backend (fresh checkout/build dir)", file=sys.stderr)
        sys.exit(1)


def wait_for_build_lock_clear(timeout_s: float = 30.0, poll_s: float = 1.0) -> None:
    """Refuse to run benchmarks while a build is in progress.

    .omc/build.lock is the repo-wide convention (see team handoff notes) for
    "a build is currently writing kitty/launcher/kitty" -- benchmarking
    against a binary mid-write would silently measure a partial/corrupt
    build. If the lock is held, poll for up to timeout_s before giving up
    loudly (never proceeding past a held lock).
    """
    if not BUILD_LOCK.exists():
        return
    print(f"[kitty-harness] {BUILD_LOCK} is held -- waiting up to {timeout_s:.0f}s for the build to finish ...", file=sys.stderr)
    waited = 0.0
    while BUILD_LOCK.exists():
        if waited >= timeout_s:
            print(
                f"ERROR: {BUILD_LOCK} still held after {timeout_s:.0f}s -- refusing to benchmark "
                "against a binary that may be mid-build. Re-run once the build completes.",
                file=sys.stderr,
            )
            sys.exit(1)
        time.sleep(poll_s)
        waited += poll_s
    print("[kitty-harness] build lock cleared, proceeding", file=sys.stderr)


def find_app_bundle(binary: Path) -> Path | None:
    real = binary.resolve()
    for parent in real.parents:
        if parent.suffix == ".app":
            return parent
    return None


def metallib_search_paths(binary: Path) -> list[Path]:
    """Mirror kitty/metal.m's gl_init() default.metallib search order exactly
    (kitty/metal.m:773-790), so filesystem-based backend detection tracks the
    same locations the running binary itself would actually load from --
    including the CWD-relative dev fallbacks, which is where this repo's
    build actually keeps it (kitty/default.metallib in the source tree, not
    copied into the .app bundle's Resources). Paths are de-duplicated while
    preserving search order.
    """
    exec_dir = binary.resolve().parent
    candidates = []
    bundle = find_app_bundle(binary)
    if bundle is not None:
        candidates.append(bundle / "Contents" / "Resources" / "default.metallib")  # 1. bundle Resources
    candidates.append(exec_dir / "default.metallib")  # 2. next to executable
    candidates.append((exec_dir / ".." / "Resources" / "default.metallib").resolve())  # 3. ../Resources
    # 4. dev layout: kitty.app/Contents/MacOS -> ../../.. -> kitty/default.metallib
    candidates.append((exec_dir / ".." / ".." / "..").resolve() / "kitty" / "default.metallib")
    # 5/6. CWD-relative fallbacks -- meaningful because spawn_kitty() launches
    # kitty without an explicit cwd=, so it inherits the calling script's CWD.
    candidates.append(Path("kitty/default.metallib").resolve())
    candidates.append(Path("default.metallib").resolve())
    seen: set[Path] = set()
    ordered: list[Path] = []
    for c in candidates:
        if c not in seen:
            seen.add(c)
            ordered.append(c)
    return ordered


def detect_backend(explicit: str | None) -> tuple[str, str]:
    if explicit and explicit != "auto":
        return explicit, f"explicit --backend {explicit}"
    searched = metallib_search_paths(KITTY_BINARY)
    for path in searched:
        if path.exists():
            return "metal", f"detected via presence of {path}"
    if find_app_bundle(KITTY_BINARY) is not None:
        listing = ", ".join(str(p) for p in searched)
        return "gl", f"no default.metallib in any of kitty/metal.m's search paths ({listing})"
    return "unknown", "could not locate a .app bundle for backend auto-detection; pass --backend explicitly"


def get_kitty_version() -> str | None:
    try:
        out = subprocess.run([str(KITTY_BINARY), "--version"], capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.TimeoutExpired):
        return None
    m = re.search(r"kitty\s+(\S+)", out)
    return m.group(1) if m else (out.strip() or None)


def get_machine_info() -> dict[str, Any]:
    def sysctl(name: str) -> str | None:
        try:
            out = subprocess.run(["sysctl", "-n", name], capture_output=True, text=True, timeout=5)
        except (OSError, subprocess.TimeoutExpired):
            return None
        return out.stdout.strip() or None

    return {"model": sysctl("hw.model"), "chip": sysctl("machdep.cpu.brand_string"), "os": platform.platform()}


def get_display_hz(explicit: float | None) -> tuple[float | None, str | None]:
    if explicit is not None:
        return explicit, "manually specified via --display-hz"
    try:
        out = subprocess.run(
            ["system_profiler", "SPDisplaysDataType"], capture_output=True, text=True, timeout=15,
        ).stdout
    except (OSError, subprocess.TimeoutExpired) as exc:
        return None, f"system_profiler failed: {exc}"

    # Group lines into per-display blocks, keyed on the fixed 8-space-indent
    # "Name:" header line system_profiler emits for each display entry.
    blocks: list[list[str]] = []
    for line in out.splitlines():
        if re.match(r"^ {8}\S.*:\s*$", line):
            blocks.append([line])
        elif blocks:
            blocks[-1].append(line)

    for block in blocks:
        block_text = "\n".join(block)
        if "Main Display: Yes" not in block_text:
            continue
        m = re.search(r"@\s*([\d.]+)\s*Hz", block_text)
        if m:
            return float(m.group(1)), None
        return None, (
            "main display block found but system_profiler reported no explicit Hz "
            "(common for fixed-panel/XDR-class displays); pass --display-hz to override"
        )
    return None, "could not identify a main-display block in system_profiler output; pass --display-hz to override"


def get_power_source() -> dict[str, Any]:
    """Battery vs AC, per danluu.com/term-latency's confound list."""
    try:
        out = subprocess.run(["pmset", "-g", "batt"], capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.TimeoutExpired) as exc:
        return {"source": None, "note": f"pmset failed: {exc}"}
    if "AC Power" in out:
        return {"source": "AC", "raw": out.strip().splitlines()[0] if out.strip() else None}
    if "Battery Power" in out:
        return {"source": "battery", "raw": out.strip().splitlines()[0] if out.strip() else None}
    return {"source": None, "note": "pmset output not recognized (no battery? desktop Mac?)", "raw_excerpt": out[:200]}


def get_peak_rss_mb(samples_kb: list[int]) -> float | None:
    return (max(samples_kb) / 1024.0) if samples_kb else None


def spawn_kitty(
    argv_command: list[str] | None = None,
    *,
    extra_env: dict[str, str] | None = None,
    extra_kitty_opts: list[str] | None = None,
    stdout: Any = subprocess.DEVNULL,
    stderr: Any = subprocess.DEVNULL,
) -> subprocess.Popen:
    """Launch a throwaway kitty OS window (--config NONE, quit-on-last-close)
    and return its Popen handle immediately (does not wait for exit). Caller
    owns the lifecycle: wait for natural exit and/or call terminate_kitty().

    argv_command, if given, runs as the foreground child (kitty's default
    shell otherwise). extra_kitty_opts are additional `-o key=value`
    overrides (e.g. for the golden-image config matrix), appended after the
    two mandatory ones.
    """
    require_kitty_binary()
    argv = [
        str(KITTY_BINARY),
        "-c", "NONE",
        "-o", "macos_quit_when_last_window_closed=yes",
        "-o", "update_check_interval=0",
    ]
    for opt in (extra_kitty_opts or []):
        argv += ["-o", opt]
    if argv_command:
        argv += ["--", *argv_command]
    run_env = dict(os.environ)
    if extra_env:
        run_env.update(extra_env)
    return subprocess.Popen(argv, env=run_env, stdout=stdout, stderr=stderr)


def terminate_kitty(proc: subprocess.Popen, grace_s: float = 5.0) -> bool:
    """SIGTERM the tracked PID, wait grace_s, SIGKILL only as a last resort.

    Never kills by name or pattern -- always this exact Popen's own PID.
    Returns True if the process exited on SIGTERM alone (clean shutdown,
    any in-flight measurement is still trustworthy up to this point), False
    if SIGKILL was needed (callers should treat the run as invalidated by
    this forced termination, per the team's kill-safety protocol).
    """
    if proc.poll() is not None:
        return True  # already exited on its own
    proc.terminate()
    try:
        proc.wait(timeout=grace_s)
        return True
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=10)
        assert proc.poll() is not None, f"kitty pid {proc.pid} did not exit after SIGKILL"
        return False


def run_in_kitty(
    argv_command: list[str],
    *,
    timeout: float,
    extra_env: dict[str, str] | None = None,
    capture_stderr_to: Path | None = None,
    extra_kitty_opts: list[str] | None = None,
) -> dict[str, Any]:
    """Launch a throwaway kitty OS window running argv_command, wait for exit.

    argv_command runs as the foreground child of a fresh kitty window via
    /bin/sh; its own stdout/stderr are redirected by the shell wrapper to a
    temp file (returned as "child_output") -- this does NOT affect anything
    argv_command writes directly to /dev/tty (the pty), so real terminal
    parsing/rendering still happens in the visible window. kitty's OWN
    process stderr (where KITTY_METAL_STATS/signpost logging is expected to
    land, per task #1) is optionally captured to capture_stderr_to.
    """
    import shlex
    import tempfile
    import threading

    require_kitty_binary()
    with tempfile.TemporaryDirectory(prefix="kitty-bench-") as td:
        out_path = Path(td) / "child_stdout.txt"
        shell_cmd = " ".join(shlex.quote(a) for a in argv_command) + f" >{shlex.quote(str(out_path))} 2>&1"

        stderr_fh = open(capture_stderr_to, "wb") if capture_stderr_to is not None else None
        rss_samples_kb: list[int] = []
        stop_poll = threading.Event()
        proc = spawn_kitty(
            ["/bin/sh", "-c", shell_cmd],
            extra_env=extra_env,
            extra_kitty_opts=extra_kitty_opts,
            stderr=stderr_fh if stderr_fh is not None else subprocess.DEVNULL,
        )

        def poll_rss() -> None:
            while not stop_poll.wait(0.2):
                try:
                    r = subprocess.run(
                        ["ps", "-o", "rss=", "-p", str(proc.pid)], capture_output=True, text=True, timeout=2,
                    )
                    val = r.stdout.strip()
                    if val:
                        rss_samples_kb.append(int(val))
                except (OSError, subprocess.TimeoutExpired, ValueError):
                    pass

        poll_thread = threading.Thread(target=poll_rss, daemon=True)
        start = time.perf_counter()
        poll_thread.start()
        timed_out = False
        try:
            proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            # A run that needed forced termination is invalid -- callers must
            # discard any partial output, not report it as a measurement.
            timed_out = True
            terminate_kitty(proc)
        elapsed = time.perf_counter() - start
        assert proc.poll() is not None, f"kitty pid {proc.pid} did not exit after wait() returned"
        stop_poll.set()
        poll_thread.join(timeout=2)
        if stderr_fh is not None:
            stderr_fh.close()

        child_output = out_path.read_text(errors="replace") if out_path.exists() else ""
        return {
            "child_output": child_output,
            "elapsed_s": elapsed,
            "returncode": proc.returncode,
            "timed_out": timed_out,
            "peak_rss_kb": max(rss_samples_kb) if rss_samples_kb else None,
        }
