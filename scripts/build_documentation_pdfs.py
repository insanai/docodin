"""Build the manual, collected DODs and each standalone DOD with docodin."""

from __future__ import annotations

import argparse
import shutil
import subprocess
import tempfile
import tomllib
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def record_sources() -> list[Path]:
    return [path for path in sorted((ROOT / "docs" / "dod").glob("[0-9][0-9][0-9][0-9]-*.rst"))
            if not path.name.startswith("0000-")]


def build_pdfs(binary: Path, output: Path, book_pdf: Path | None = None,
               dod_pdf: Path | None = None, jobs: int = 2) -> None:
    output.mkdir(parents=True, exist_ok=True)
    version = tomllib.loads((ROOT / "pyproject.toml").read_text())["project"]["version"]
    with tempfile.TemporaryDirectory(prefix="docodin-pdfs-", dir=output.parent) as temporary:
        stage = Path(temporary)
        for project, supplied in (("book", book_pdf), ("dod", dod_pdf)):
            name = f"docodin-{project}.pdf"
            if supplied is None:
                build = stage / project
                subprocess.run([str(binary), "book", "build", str(ROOT / "docs" / project),
                                "--pdf", "-W", "-o", str(build)], check=True)
                supplied = build / "latex" / name
            shutil.copy2(supplied, output / name)
        template = stage / "dod.tex"
        text = (ROOT / "docs" / "theme" / "dod.tex").read_text()
        text = text.replace("@VERSION@", version).replace(
            "@DOCODIN_LOGO@", (ROOT / "docs" / "dod" / "_static" / "docodin_logo.png").as_posix())
        template.write_text(text)

        def build_record(source: Path) -> None:
            destination = output / f"dod-{source.stem}.pdf"
            subprocess.run([str(binary), "pdf", "--graphviz", "--engine=lualatex",
                            "--documentclass=article",
                            "--documentoptions=11pt,a4paper", "--syntax-highlight=none",
                            "--use-latex-docinfo", "--use-docutils-toc", "--halt=warning",
                            "--exit-status=warning",
                            f"--template={template}", str(source), str(destination)], check=True)

        with ThreadPoolExecutor(max_workers=jobs) as executor:
            list(executor.map(build_record, record_sources()))
    print(f"Documentation PDFs: {output} ({len(record_sources()) + 2} files)")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=ROOT / "bin" / "docodin")
    parser.add_argument("--output", type=Path, default=ROOT / "build" / "pdf")
    parser.add_argument("--book-pdf", type=Path)
    parser.add_argument("--dod-pdf", type=Path)
    parser.add_argument("--jobs", type=int, default=2)
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    build_pdfs(args.binary.resolve(), args.output.resolve(), args.book_pdf, args.dod_pdf, args.jobs)


if __name__ == "__main__":
    main()
