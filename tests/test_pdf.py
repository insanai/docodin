"""PDF content regressions; require TeX and Poppler's pdftotext."""

from __future__ import annotations

import os
import re
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
BINARY = ROOT / "bin" / "docodin"
PDFTOTEXT = shutil.which("pdftotext")
TEX_DIRS = ["/Library/TeX/texbin", "/usr/local/texlive/bin", "/usr/bin"]

pytestmark = [
    pytest.mark.skipif(not BINARY.is_file(), reason="bin/docodin not built"),
    pytest.mark.skipif(PDFTOTEXT is None, reason="pdftotext not installed"),
]


def engine_path(name: str) -> str:
    found = shutil.which(name)
    if found:
        return found
    for directory in TEX_DIRS:
        path = Path(directory) / name
        if path.is_file():
            return str(path)
    pytest.skip(f"{name} not installed")


def pdf_text(path: Path) -> str:
    result = subprocess.run([PDFTOTEXT or "pdftotext", "-layout", str(path), "-"],
                            capture_output=True, text=True, check=True)
    return result.stdout


def run_pdf(*args: str | Path) -> None:
    result = subprocess.run([str(BINARY), *map(str, args)], capture_output=True, text=True,
                            env={**os.environ, "DOCUTILSCONFIG": ""}, timeout=600, check=False)
    assert result.returncode == 0, result.stderr


@pytest.mark.parametrize("name", ["xelatex", "lualatex"])
@pytest.mark.parametrize("fallback", [False, True], ids=["native", "python-fallback"])
def test_engine_path_preserves_unicode(tmp_path: Path, name: str, fallback: bool) -> None:
    path = engine_path(name)
    source = tmp_path / "unicode.rst"
    text = "Unicode\n=======\n\nПривет, café.\n"
    if fallback:
        pytest.importorskip("pygments")
        text += "\n.. code:: python\n\n   print('hello')\n"
    source.write_text(text, encoding="utf-8")
    for i, engine in enumerate((name, path)):
        output = tmp_path / f"unicode-{i}.pdf"
        run_pdf("pdf", f"--engine={engine}", source, output)
        assert "Привет, café." in pdf_text(output)


@pytest.mark.parametrize("opening", [False, True], ids=["without-opening", "with-opening"])
def test_local_contents_match_their_chapters(tmp_path: Path, opening: bool) -> None:
    engine_path("lualatex")
    (tmp_path / "conf.py").write_text("project = 'Local contents'\n", encoding="utf-8")
    intro = "An unnumbered opening chapter.\n\n" if opening else ""
    (tmp_path / "index.rst").write_text(
        "Local contents\n==============\n\n" + intro +
        ".. toctree::\n\n   first\n   second\n", encoding="utf-8")
    for name, title, section in (("first", "First chapter", "Unique Alpha section"),
                                 ("second", "Second chapter", "Unique Beta section")):
        (tmp_path / f"{name}.rst").write_text(
            f"{title}\n{'=' * len(title)}\n\n"
            ".. contents:: Local contents\n   :local:\n   :depth: 1\n\n"
            f"{section}\n{'-' * len(section)}\n\nA paragraph.\n", encoding="utf-8")
    out = tmp_path / "out"
    run_pdf("book", "build", tmp_path, "--pdf", "-W", "-o", out)
    pages = pdf_text(out / "latex" / "local-contents.pdf").split("\f")
    for section, other in (("Unique Alpha section", "Unique Beta section"),
                           ("Unique Beta section", "Unique Alpha section")):
        # Once in the local ToC, once in the chapter's section heading.
        chapter = next(page for page in pages
                       if re.search(re.escape(section) + r"\s+A paragraph\.", page))
        assert chapter.count(section) == 2, chapter
        assert other not in chapter, chapter
