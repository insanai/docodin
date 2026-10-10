"""Install the pinned Odin compiler; print its directory for PATH."""

from __future__ import annotations

import argparse
import platform
import subprocess
import tarfile
import tempfile
from pathlib import Path

from build_support import download_verified, toolchains


def install(destination: Path) -> Path:
    manifest = toolchains()["odin"]
    architecture = {"aarch64": "arm64", "AMD64": "x86_64"}.get(
        platform.machine(), platform.machine())
    key = f"{platform.system().lower()}-{architecture}"
    if key not in manifest:
        raise RuntimeError(f"The beta toolchain does not support {key}")
    destination.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="docodin-odin-") as temporary:
        archive = Path(temporary) / "odin.tar.gz"
        download_verified(manifest[key], archive)
        with tarfile.open(archive) as source:
            source.extractall(destination, filter="data")
    binaries = [path for path in destination.rglob("odin") if path.is_file()]
    if len(binaries) != 1:
        raise RuntimeError("Expected one Odin executable in the compiler archive")
    binary = binaries[0]
    version = subprocess.check_output([str(binary), "version"], text=True)
    if manifest["version"] not in version:
        raise RuntimeError(f"Unexpected compiler version: {version.strip()}")
    return binary.parent


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path)
    print(install(parser.parse_args().destination.resolve()))
