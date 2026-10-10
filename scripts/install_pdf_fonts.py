"""Install pinned Source OTF fonts into a dedicated TeX tree."""

from __future__ import annotations

import argparse
import os
import subprocess
import tempfile
import zipfile
from pathlib import Path

from build_support import download_verified, toolchains


def install(texmf: Path) -> None:
    fonts = texmf / "fonts" / "opentype" / "docodin"
    fonts.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="docodin-fonts-") as temporary:
        archive = Path(temporary) / "fonts.zip"
        for asset in toolchains()["fonts"]:
            download_verified(asset, archive)
            with zipfile.ZipFile(archive) as source:
                for name in source.namelist():
                    if name.endswith(".otf"):
                        (fonts / Path(name).name).write_bytes(source.read(name))
    # The book template follows CTAN's RegularIt filename convention.
    for family in ("SourceSerif4", "SourceSans3", "SourceCodePro"):
        (fonts / f"{family}-RegularIt.otf").write_bytes((fonts / f"{family}-It.otf").read_bytes())
    env = {**os.environ, "TEXMFHOME": str(texmf)}
    subprocess.run(["mktexlsr", str(texmf)], env=env, check=True)
    subprocess.run(["luaotfload-tool", "--update", "--force"], env=env, check=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("texmf", type=Path)
    install(parser.parse_args().texmf.resolve())
