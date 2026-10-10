"""Build the GitHub Pages site with docodin's native builder."""

from __future__ import annotations

import argparse
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LOGO_URL = "https://raw.githubusercontent.com/insanai/docodin/main/docs/book/_static/docodin_logo.png"


def build_site(binary: Path, output: Path) -> None:
    if output == ROOT or output in ROOT.parents or output == ROOT / "docs":
        raise ValueError("The website output must not replace the project sources")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="docodin-site-", dir=output.parent) as temporary:
        stage = Path(temporary)
        website = stage / "website"
        for project, destination in (("site", ""), ("book", "book"), ("dod", "dod")):
            build = stage / "projects" / project
            subprocess.run([str(binary), "book", "build", str(ROOT / "docs" / project),
                            "--html", "-W", "-o", str(build)], check=True)
            shutil.copytree(build / "html", website / destination, dirs_exist_ok=True)
        # Serve the homepage's logo from the copied static asset, including offline.
        home = website / "index.html"
        home.write_text(home.read_text(encoding="utf-8").replace(
            LOGO_URL, "_static/docodin_logo.png"), encoding="utf-8")
        (website / ".nojekyll").touch()
        if output.exists():
            shutil.rmtree(output)
        shutil.move(str(website), output)
    print(f"docodin website: {output}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=ROOT / "bin" / "docodin")
    parser.add_argument("--output", type=Path, default=ROOT / "build" / "site")
    args = parser.parse_args()
    build_site(args.binary.resolve(), args.output.resolve())


if __name__ == "__main__":
    main()
