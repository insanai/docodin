"""Build the GitHub Pages site with docodin's native builder."""

from __future__ import annotations

import argparse
import html
import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path
from urllib.parse import quote

from build_documentation_pdfs import record_sources

ROOT = Path(__file__).resolve().parent.parent
LOGO_URL = "https://raw.githubusercontent.com/insanai/docodin/main/docs/book/_static/docodin_logo.png"


def attach_pdfs(website: Path, directory: Path) -> None:
    names = ["docodin-book.pdf", "docodin-dod.pdf"]
    names.extend(f"dod-{source.stem}.pdf" for source in record_sources())
    downloads = website / "pdf"
    downloads.mkdir()
    for name in names:
        source = directory / name
        with source.open("rb") as stream:
            if stream.read(5) != b"%PDF-":
                raise ValueError(f"Not a PDF: {source}")
        shutil.copy2(source, downloads / name)
    for page in website.rglob("*.html"):
        project = page.relative_to(website).parts[0]
        links = [("docodin-book.pdf", "Download the book (PDF)")]
        if project == "dod":
            links = [("docodin-dod.pdf", "All design records (PDF)")]
            if page.stem != "index" and f"dod-{page.stem}.pdf" in names:
                links.insert(0, (f"dod-{page.stem}.pdf", "Download this DOD (PDF)"))
        elif project != "book":
            links.append(("docodin-dod.pdf", "Design records (PDF)"))
        anchors = []
        for name, label in links:
            href = quote(os.path.relpath(downloads / name, page.parent), safe="/")
            anchors.append(f'<a href="{href}" type="application/pdf">{html.escape(label)}</a>')
        panel = ('<nav class="document-downloads" aria-label="PDF downloads">' +
                 "".join(anchors) + "</nav>\n")
        text = page.read_text(encoding="utf-8")
        text, count = re.subn(r'(<article class="dod-article(?: part-page)?" role="main">\n)',
                             lambda match, panel=panel: match[0] + panel, text, count=1)
        if count != 1:
            raise ValueError(f"Cannot attach PDF downloads to {page}")
        page.write_text(text, encoding="utf-8")


def build_site(binary: Path, output: Path, pdf_directory: Path | None = None) -> None:
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
        if pdf_directory is not None:
            attach_pdfs(website, pdf_directory)
        (website / ".nojekyll").touch()
        if output.exists():
            shutil.rmtree(output)
        shutil.move(str(website), output)
    print(f"docodin website: {output}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=ROOT / "bin" / "docodin")
    parser.add_argument("--output", type=Path, default=ROOT / "build" / "site")
    parser.add_argument("--pdf-dir", type=Path, help="Complete directory of documentation PDFs")
    args = parser.parse_args()
    build_site(args.binary.resolve(), args.output.resolve(), args.pdf_dir)


if __name__ == "__main__":
    main()
