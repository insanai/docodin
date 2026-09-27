"""Hatch build hook: build the native engine and tag platform wheels.

``scripts/build_odin.sh`` compiles the Odin library into ``python/docodin``
(it needs the Odin compiler).  Set ``DOCODIN_SKIP_NATIVE_BUILD=1`` to package
an already built library.  Editable installs never build: run the script
yourself during development.

The library is loaded with ctypes (no CPython ABI), so a wheel is specific
to the platform only: ``py3-none-<platform>``.
"""

from __future__ import annotations

import os
import platform
import subprocess
import sys
from pathlib import Path
from typing import Any

from hatchling.builders.hooks.plugin.interface import BuildHookInterface
from packaging.tags import sys_tags

LIBRARIES = ("libdocodin.dylib", "libdocodin.so", "docodin.dll")


class NativeBuildHook(BuildHookInterface):
    PLUGIN_NAME = "custom"

    def initialize(self, version: str, build_data: dict[str, Any]) -> None:
        if self.target_name != "wheel" or version == "editable":
            return
        root = Path(self.root)
        if os.environ.get("DOCODIN_SKIP_NATIVE_BUILD") != "1":
            subprocess.check_call(["bash", str(root / "scripts" / "build_odin.sh")])
        package = root / "python" / "docodin"
        libraries = [name for name in LIBRARIES if (package / name).exists()]
        if not libraries:
            raise RuntimeError("docodin: no native library in python/docodin; "
                               "build it with scripts/build_odin.sh")
        for name in libraries:
            build_data["force_include"][str(package / name)] = f"docodin/{name}"
        build_data["pure_python"] = False
        build_data["tag"] = f"py3-none-{platform_tag()}"


def platform_tag() -> str:
    """The wheel platform: on macOS the deployment target the library is built
    for (see scripts/build_odin.sh), elsewhere the interpreter's platform."""
    if sys.platform == "darwin":
        target = os.environ.get("MACOSX_DEPLOYMENT_TARGET", "11.0").split(".")
        return f"macosx_{target[0]}_{target[1] if len(target) > 1 else 0}_{platform.machine()}"
    return next(iter(sys_tags())).platform
