import builtins

_ORIGINAL_IMPORT = builtins.__import__
_PATCH_APPLIED = False


def _kitty_import(name, globals=None, locals=None, fromlist=(), level=0):
    module = _ORIGINAL_IMPORT(name, globals, locals, fromlist, level)
    global _PATCH_APPLIED
    if not _PATCH_APPLIED:
        if getattr(module, "__name__", "") == "kitty_tests.renderer_backend":
            try:
                from ._renderer_backend_patch import apply_backend_patch

                apply_backend_patch(module)
            finally:
                builtins.__import__ = _ORIGINAL_IMPORT
                _PATCH_APPLIED = True
    return module


builtins.__import__ = _kitty_import
