from __future__ import annotations

from os import path


def resolve_framework_library(
    framework_dir: str,
    version: str | None,
    framework_name: str,
    ldlib: str,
    gil_disabled: bool,
    *,
    isdir=path.isdir,
    exists=path.exists,
) -> str:
    """
    Return the absolute path to the Python framework library that should be linked.

    When the headers indicate Py_GIL_DISABLED we link against PythonT.framework
    if it is available, otherwise fall back to the path reported by Python itself.
    """
    if not ldlib:
        return ''
    candidate = path.join(framework_dir, ldlib)
    if gil_disabled and framework_name == 'Python':
        pythont_dir = path.join(framework_dir, 'PythonT.framework')
        if isdir(pythont_dir):
            version_component = version or ''
            pythont_lib = path.join(
                framework_dir,
                f'PythonT.framework/Versions/{version_component}/PythonT',
            )
            if exists(pythont_lib):
                return pythont_lib
    return candidate
