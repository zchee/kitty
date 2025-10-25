from __future__ import annotations

from typing import Any, Callable


def apply_backend_patch(renderer_backend_module: Any) -> None:
    if getattr(renderer_backend_module, "_kitty_backend_patch_applied", False):
        return
    renderer_backend_module._kitty_backend_patch_applied = True

    BackendFFI = renderer_backend_module.BackendFFI
    original_init = BackendFFI.__init__

    def patched_init(self: Any, *args: Any, **kwargs: Any) -> None:
        original_init(self, *args, **kwargs)
        original_func = self.lib.register_opengl_renderer_backend

        class _RegisterWrapper:
            def __init__(self, func: Callable[[], bool], owner: Any) -> None:
                self._func = func
                self._owner = owner
                for attr in ("argtypes", "restype", "errcheck"):
                    if hasattr(func, attr):
                        setattr(self, attr, getattr(func, attr))

            def __call__(self) -> bool:
                try:
                    return self._func()
                except RuntimeError as exc:
                    self._owner._kitty_last_opengl_error = (RuntimeError, exc, None)
                    return False

        self.lib.register_opengl_renderer_backend = _RegisterWrapper(original_func, self)
        original_fetch = self._pyerr_fetch

        def fetch_wrapper(type_ptr: Any, value_ptr: Any, tb_ptr: Any) -> None:
            stored = getattr(self, "_kitty_last_opengl_error", None)
            if stored is not None:
                err_type, err_value, err_tb = stored
                type_ptr.contents.value = err_type
                value_ptr.contents.value = err_value
                tb_ptr.contents.value = err_tb
                del self._kitty_last_opengl_error
            else:
                original_fetch(type_ptr, value_ptr, tb_ptr)

        self._pyerr_fetch = fetch_wrapper

    BackendFFI.__init__ = patched_init

