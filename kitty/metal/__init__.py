from __future__ import annotations

import atexit
import json
import threading
from contextlib import ExitStack
from importlib import resources
from pathlib import Path

__all__ = ["get_cell_metallib_path", "get_shader_metadata"]

_METALLIB_NAME = "cell.metallib"
_metallib_lock = threading.RLock()
_metallib_exit_stack: ExitStack | None = None
_metallib_path: str | None = None
_atexit_registered = False
_shader_metadata_lock = threading.RLock()
_shader_metadata: dict | None = None


def _close_metallib_stack() -> None:
    global _metallib_exit_stack, _metallib_path
    stack = _metallib_exit_stack
    _metallib_exit_stack = None
    _metallib_path = None
    if stack is not None:
        stack.close()


def _ensure_atexit_registration() -> None:
    global _atexit_registered
    if not _atexit_registered:
        atexit.register(_close_metallib_stack)
        _atexit_registered = True


def get_cell_metallib_path() -> str:
    """
    Return a filesystem path to the packaged Metal shader library.

    Uses importlib.resources.as_file so the path remains valid when the package
    is zipped. The extracted file is cached for subsequent callers.
    """
    global _metallib_exit_stack, _metallib_path
    with _metallib_lock:
        if _metallib_path and Path(_metallib_path).is_file():
            return _metallib_path

        pkg_files = resources.files(__name__)
        traversable = pkg_files / _METALLIB_NAME

        stack = ExitStack()
        try:
            extracted = stack.enter_context(resources.as_file(traversable))
            path = Path(extracted)
            if not path.is_file():
                raise FileNotFoundError(
                    f"Metal shader library {_METALLIB_NAME} is missing"
                )
        except BaseException:
            stack.close()
            raise

        old_stack = _metallib_exit_stack
        _metallib_exit_stack = stack
        _metallib_path = str(path)
        _ensure_atexit_registration()

        if old_stack is not None:
            old_stack.close()

        return _metallib_path


def _reset_cell_metallib_cache_for_tests() -> None:
    with _metallib_lock:
        _close_metallib_stack()


def get_shader_metadata() -> dict:
    """
    Load cached shader metadata emitted during the build.
    """
    global _shader_metadata
    with _shader_metadata_lock:
        if _shader_metadata is not None:
            return _shader_metadata

        pkg_files = resources.files(__name__)
        traversable = pkg_files / "shader_metadata.json"
        with resources.as_file(traversable) as metadata_path:
            data = Path(metadata_path).read_text(encoding="utf-8")
        _shader_metadata = json.loads(data)
        return _shader_metadata


def _reset_shader_metadata_cache_for_tests() -> None:
    global _shader_metadata
    with _shader_metadata_lock:
        _shader_metadata = None
