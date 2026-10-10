"""Hatch build hook: build the native engine and tag platform wheels.

``scripts/build_odin.sh`` compiles the Odin library into ``python/docodin``
and the native programs into ``bin`` (it needs the Odin compiler).  The wheel
installs the programs (``docodin``, ``docodin-check``, ``docodin-lsp``) into
the environment's scripts directory.  Set ``DOCODIN_SKIP_NATIVE_BUILD=1`` to
package an already built engine.  Editable installs never build: run the
script yourself during development.

The library is loaded with ctypes (no CPython ABI), so a wheel is specific
to the platform only: ``py3-none-<platform>``.
"""

from __future__ import annotations

import os
import platform
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

from hatchling.builders.hooks.plugin.interface import BuildHookInterface
from packaging.tags import sys_tags

LIBRARIES = ("libdocodin.dylib", "libdocodin.so", "docodin.dll")
PROGRAMS = ("docodin", "docodin-check", "docodin-lsp")


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
        binaries = [package / name for name in libraries]
        for name in libraries:
            build_data["force_include"][str(package / name)] = f"docodin/{name}"
        for name in native_programs(root / "bin"):
            build_data["shared_scripts"][str(root / "bin" / name)] = name
            binaries.append(root / "bin" / name)
        build_data["pure_python"] = False
        build_data["tag"] = f"py3-none-{platform_tag(binaries)}"


def native_programs(bin_dir: Path) -> list[str]:
    """The file names of the native programs (``.exe`` on Windows)."""
    suffix = ".exe" if sys.platform == "win32" else ""
    names = [name + suffix for name in PROGRAMS]
    missing = [name for name in names if not (bin_dir / name).is_file()]
    if missing:
        raise RuntimeError(f"docodin: {', '.join(missing)} missing in {bin_dir}; "
                           "build them with scripts/build_odin.sh")
    return names


def platform_tag(binaries: list[Path]) -> str:
    """The wheel platform: on macOS the deployment target the binaries are
    built for (see scripts/build_odin.sh), on glibc Linux the manylinux tag of
    the newest glibc symbol version they need, elsewhere the interpreter's
    platform."""
    if sys.platform == "darwin":
        target = os.environ.get("MACOSX_DEPLOYMENT_TARGET", "11.0").split(".")
        return f"macosx_{target[0]}_{target[1] if len(target) > 1 else 0}_{platform.machine()}"
    if sys.platform == "linux" and platform.libc_ver()[0] == "glibc":
        major, minor = glibc_requirement(binaries)
        return f"manylinux_{major}_{minor}_{platform.machine()}"
    return next(iter(sys_tags())).platform


def glibc_requirement(binaries: list[Path]) -> tuple[int, int]:
    """The newest ``GLIBC_x.y`` symbol version the ELF ``binaries`` require (the
    version needs are strings in their dynamic string tables)."""
    versions = [(2, 17)]  # the oldest manylinux baseline for x86-64 and aarch64
    for path in binaries:
        for major, minor in re.findall(rb"GLIBC_(\d+)\.(\d+)", path.read_bytes()):
            versions.append((int(major), int(minor)))
    return max(versions)
