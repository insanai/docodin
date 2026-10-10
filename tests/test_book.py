"""Integration tests of ``docodin book build`` and ``docodin dod`` (``bin/docodin``).

A small Sphinx project (``tests/book_fixture``) is built natively, and so are the
documentation projects ``docs/book`` and ``docs/dod``.  The HTML pages are checked for
well-formed markup and for internal links that resolve (files and anchors); the navigation,
search index and PDF book are checked on the fixture.  The PDF tests are skipped without a
TeX engine.
"""

from __future__ import annotations

import html.parser
import json
import os
import re
import shutil
import subprocess
from pathlib import Path
from urllib.parse import unquote, urlsplit

import pytest

ROOT = Path(__file__).resolve().parent.parent
BINARY = ROOT / "bin" / "docodin"
FIXTURE = ROOT / "tests" / "book_fixture"
TEX_DIRS = ["/Library/TeX/texbin", "/usr/local/texlive/bin", "/usr/bin"]

pytestmark = pytest.mark.skipif(not BINARY.is_file(), reason="bin/docodin not built")


def tex_engine() -> str | None:
    for directory in TEX_DIRS:
        if (Path(directory) / "lualatex").is_file():
            return str(Path(directory) / "lualatex")
    return shutil.which("lualatex")


def docodin(*args: str | Path, cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
    env = dict(os.environ, NO_COLOR="1")
    return subprocess.run([str(BINARY), *map(str, args)], capture_output=True, text=True,
                          cwd=cwd, env=env, timeout=600, check=False)


# --- HTML checks -------------------------------------------------------------------------------

VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source",
        "track", "wbr"}
# MathML and SVG elements may be self-closed
FOREIGN = {"svg", "math"}


class Page(html.parser.HTMLParser):
    """The ids, links and structure errors of an HTML page."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.stack: list[str] = []
        self.errors: list[str] = []
        self.ids: set[str] = set()
        self.links: list[str] = []
        self.foreign = 0

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        values = dict(attrs)
        if values.get("id"):
            self.ids.add(values["id"] or "")
        for key in ("href", "src"):
            if values.get(key):
                self.links.append(values[key] or "")
        if tag in FOREIGN:
            self.foreign += 1
        if tag not in VOID:
            self.stack.append(tag)

    def handle_startendtag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        values = dict(attrs)
        if values.get("id"):
            self.ids.add(values["id"] or "")
        for key in ("href", "src"):
            if values.get(key):
                self.links.append(values[key] or "")

    def handle_endtag(self, tag: str) -> None:
        if tag in VOID:
            return
        if not self.stack or self.stack[-1] != tag:
            self.errors.append(f"</{tag}> closes <{self.stack[-1] if self.stack else None}>")
            if tag in self.stack:
                while self.stack and self.stack.pop() != tag:
                    pass
            return
        self.stack.pop()
        if tag in FOREIGN:
            self.foreign -= 1


def parse_page(path: Path) -> Page:
    page = Page()
    page.feed(path.read_text(encoding="utf-8"))
    page.close()
    if page.stack:
        page.errors.append(f"unclosed elements: {page.stack}")
    return page


def check_site(site: Path) -> list[str]:
    """Structure errors and broken internal links of every page of ``site``."""
    pages = {path: parse_page(path) for path in site.rglob("*.html")}
    problems: list[str] = []
    for path, page in pages.items():
        problems += [f"{path.relative_to(site)}: {e}" for e in page.errors]
        if not path.read_text(encoding="utf-8").startswith("<!DOCTYPE html>"):
            problems.append(f"{path.relative_to(site)}: no doctype")
        for link in page.links:
            problem = check_link(site, path, link, pages)
            if problem:
                problems.append(f"{path.relative_to(site)}: {problem}")
    return problems


def check_link(site: Path, page: Path, link: str, pages: dict[Path, Page]) -> str | None:
    parts = urlsplit(link)
    if parts.scheme or link.startswith("//") or link.startswith("data:"):
        return None
    target = page if not parts.path else (page.parent / unquote(parts.path)).resolve()
    if not target.exists():
        return f"broken link {link}"
    if not str(target).startswith(str(site.resolve())) and target != page:
        return f"link {link} leaves the site"
    if parts.fragment and target.suffix == ".html":
        ids = pages.get(target) or pages.get(Path(os.path.normpath(target)))
        if ids is None:
            ids = parse_page(target)
        # "#top" is the top of the page (HTML), as docutils' contents use it
        if unquote(parts.fragment) not in ids.ids | {"top"}:
            return f"missing anchor {link}"
    return None


# --- the fixture -------------------------------------------------------------------------------


@pytest.fixture(scope="module")
def fixture_site(tmp_path_factory: pytest.TempPathFactory) -> Path:
    out = tmp_path_factory.mktemp("fixture")
    result = docodin("book", "build", FIXTURE, "-o", out, "--html", "-W")
    assert result.returncode == 0, result.stderr
    assert "warning" not in result.stderr.lower(), result.stderr
    return out / "html"


def test_pages_and_assets(fixture_site: Path) -> None:
    names = {p.relative_to(fixture_site).as_posix() for p in fixture_site.rglob("*")
             if p.is_file()}
    for name in ("index.html", "guide/intro.html", "guide/usage.html", "guide/nested.html",
                 "reference/glossary.html", "reference/api.html", "orphan.html", "search.html",
                 "searchindex.json", "searchindex.js", "_static/docodin.css",
                 "_static/docodin.js", "_static/arch.svg", "_downloads/sample.odin"):
        assert name in names, name
    assert "drafts/draft.html" not in names  # exclude_patterns


def test_html_is_well_formed_and_links_resolve(fixture_site: Path) -> None:
    assert check_site(fixture_site) == []


def test_navigation_and_numbers(fixture_site: Path) -> None:
    text = (fixture_site / "guide" / "usage.html").read_text(encoding="utf-8")
    assert '<a class="reference current-page" aria-current="page" href="usage.html">' \
        '2. Usage</a>' in text
    assert '<span class="sectnum">2.1. </span>Options' in text
    assert re.search(r'class="prev" href="intro.html">.*1\. Introduction', text)
    assert re.search(r'class="next" href="nested.html">.*2\.2\.1\. Nested page', text)
    assert '<p class="caption"><span class="caption-text">Reference material</span></p>' in text
    assert '<span class="caption-number">Listing 2.1 </span>' in text
    assert "<title>Usage — Fixture Book 1.2.3</title>" in text


def test_cross_references(fixture_site: Path) -> None:
    intro = (fixture_site / "guide" / "intro.html").read_text(encoding="utf-8")
    assert 'href="../reference/glossary.html#term-builder"' in intro
    assert 'href="usage.html#usage-options"><span class="std std-ref">Options</span>' \
        in intro
    assert '<span class="std std-numref">Fig. 1.1</span>' in intro
    assert "This paragraph is only in HTML." in intro
    assert "only in LaTeX" not in intro
    assert '<abbr title="DocOdin Discussion">DOD</abbr>' in intro
    assert "Added in version 1.0: " in intro
    index = (fixture_site / "index.html").read_text(encoding="utf-8")
    assert '<a class="reference internal" href="reference/glossary.html#glossary-label">' in index


def test_search_index(fixture_site: Path) -> None:
    index = json.loads((fixture_site / "searchindex.json").read_text(encoding="utf-8"))
    names = [d["n"] for d in index["docs"]]
    assert "guide/intro" in names
    builder = index["terms"]["builder"]
    assert any(names[doc] == "reference/glossary" for doc, _ in builder)
    assert [names.index("guide/usage"), "Options", "options"] in index["sections"]
    script = (fixture_site / "searchindex.js").read_text(encoding="utf-8")
    assert script.startswith("window.DOCODIN_SEARCH_INDEX = {")


@pytest.mark.skipif(tex_engine() is None, reason="no TeX engine")
def test_pdf_book(tmp_path: Path) -> None:
    result = docodin("book", "build", FIXTURE, "-o", tmp_path, "--pdf")
    assert result.returncode == 0, result.stderr
    pdf = tmp_path / "latex" / "fixture-book.pdf"
    assert pdf.read_bytes().startswith(b"%PDF")
    tex = (tmp_path / "latex" / "fixture-book.tex").read_text(encoding="utf-8")
    assert "\\part{Part One: Guide" in tex
    assert "\\chapter{Introduction" in tex
    assert "\\hyperref[doc-reference-glossary--term-builder]" in tex
    assert "This paragraph is only in LaTeX." in tex
    log = (tmp_path / "latex" / "fixture-book.log").read_text(encoding="utf-8", errors="replace")
    assert "undefined" not in log.lower()


# --- warnings and errors -----------------------------------------------------------------------


def broken_project(tmp_path: Path) -> Path:
    (tmp_path / "conf.py").write_text('project = "Broken"\n', encoding="utf-8")
    (tmp_path / "index.rst").write_text(
        "Broken\n======\n\n.. toctree::\n\n   missing\n\nSee :ref:`nowhere`.\n",
        encoding="utf-8")
    return tmp_path


def test_warnings_in_docutils_format(tmp_path: Path) -> None:
    project = broken_project(tmp_path)
    result = docodin("book", "build", project, "--html", "--error-format=docutils",
                     "--exit-status=warning", cwd=project)
    assert result.returncode == 12
    assert "index.rst:6: (WARNING/2) toctree contains reference to nonexisting document " \
        "'missing'" in result.stderr
    assert "index.rst:8: (WARNING/2) undefined label: 'nowhere'" in result.stderr


def test_warnings_in_elm_style(tmp_path: Path) -> None:
    project = broken_project(tmp_path)
    result = docodin("book", "build", project, "--html", cwd=project)
    assert result.returncode == 0
    assert "index.rst:8" in result.stderr
    assert "8| See :ref:`nowhere`." in result.stderr


def test_invalid_utf8_source_stops_the_build(tmp_path: Path) -> None:
    project = tmp_path / "project"
    shutil.copytree(FIXTURE, project)
    (project / "bad.rst").write_bytes(b"Bad\n===\n\ncaf\xff\n")
    result = docodin("book", "build", project, "--html", "-W", "--error-format=docutils",
                     "-o", tmp_path / "out")
    assert result.returncode == 1
    assert "bad.rst:4: (SEVERE/4) Cannot decode the document: 'utf-8' codec can't decode " \
        "byte 0xff in position 12: invalid start byte." in result.stderr
    assert not (tmp_path / "out" / "html").exists()


def test_root_document_that_is_not_utf8(tmp_path: Path) -> None:
    project = tmp_path / "project"
    project.mkdir()
    (project / "conf.py").write_text("project = 'P'\n", encoding="utf-8")
    (project / "index.rst").write_bytes(b"Root\n====\n\n\xff\n")
    result = docodin("book", "build", project, "--html", "--error-format=docutils")
    assert result.returncode == 1
    assert "index.rst:4: (SEVERE/4) Cannot decode the document" in result.stderr


def test_dod_new_without_an_author(tmp_path: Path) -> None:
    dod_dir = tmp_path / "dod"
    dod_dir.mkdir()
    env = dict(os.environ, NO_COLOR="1", GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1",
               HOME=str(tmp_path))
    result = subprocess.run([str(BINARY), "dod", "new", "A record", f"--dir={dod_dir}"],
                            capture_output=True, text=True, env=env, cwd=tmp_path, check=False)
    assert result.returncode == 2
    assert "-- NO AUTHOR" in result.stderr and "--author=" in result.stderr
    assert not list(dod_dir.glob("*.rst"))


def test_usage_errors(tmp_path: Path) -> None:
    result = docodin("book", "build", tmp_path / "nothere")
    assert result.returncode == 2
    assert "-- NO SUCH DIRECTORY" in result.stderr
    result = docodin("book", "build", "--htlm")
    assert result.returncode == 2
    assert "Did you mean `--html`?" in result.stderr
    result = docodin("book", "build", tmp_path)
    assert result.returncode == 2
    assert "-- NOT A SPHINX PROJECT" in result.stderr
    result = docodin("dod", "lst")
    assert "Did you mean `dod list`?" in result.stderr
    assert "book build [DIR]" in docodin("--help").stdout


# --- DOD ---------------------------------------------------------------------------------------


def test_dod_commands(tmp_path: Path) -> None:
    dod_dir = tmp_path / "dod"
    shutil.copytree(ROOT / "docs" / "dod", dod_dir, ignore=shutil.ignore_patterns("_build"))
    check = docodin("dod", "check", f"--dir={dod_dir}")
    assert check.returncode == 0, check.stderr
    records = sorted(dod_dir.glob("[0-9][0-9][0-9][0-9]-*.rst"))
    last = max(int(p.name[:4]) for p in records)
    new = docodin("dod", "new", "A test record", "--labels=tooling",
                  "--author=Test Author <test@example.com>", f"--dir={dod_dir}")
    assert new.returncode == 0, new.stderr
    created = dod_dir / f"{last + 1:04d}-a-test-record.rst"
    text = created.read_text(encoding="utf-8")
    assert f"DOD {last + 1}: A test record" in text
    assert ":State: prediscussion" in text and ":Labels: tooling" in text
    assert ":Authors: Test Author <test@example.com>" in text
    assert ":orphan:" not in text
    listing = docodin("dod", "list", "--state=prediscussion", f"--dir={dod_dir}").stdout
    assert "A test record" in listing
    stale = docodin("dod", "check", f"--dir={dod_dir}", "--error-format=docutils")
    assert "(WARNING/2) The records by state in index.rst are out of date." in stale.stderr
    assert docodin("dod", "index", f"--dir={dod_dir}").returncode == 0
    assert f"<{created.stem}>" in (dod_dir / "index.rst").read_text(encoding="utf-8")
    assert docodin("dod", "check", f"--dir={dod_dir}").returncode == 0
    created.write_text(text.replace(":State: prediscussion", ":State: finished"),
                       encoding="utf-8")
    bad = docodin("dod", "check", f"--dir={dod_dir}")
    assert bad.returncode == 1
    assert "-- UNKNOWN STATE" in bad.stderr


# --- the documentation projects ----------------------------------------------------------------


@pytest.mark.parametrize("project", ["book", "dod"])
def test_documentation_builds_without_warnings(project: str, tmp_path: Path) -> None:
    source = ROOT / "docs" / project
    if not (source / "conf.py").is_file():
        pytest.skip(f"docs/{project} is missing")
    result = docodin("book", "build", source, "-o", tmp_path, "--html", "-W",
                     "--error-format=docutils")
    assert result.returncode == 0, result.stderr
    assert check_site(tmp_path / "html") == []


@pytest.mark.skipif(tex_engine() is None, reason="no TeX engine")
@pytest.mark.skipif(not os.environ.get("DOCODIN_BOOK_PDF"),
                    reason="set DOCODIN_BOOK_PDF=1 to typeset the documentation (slow)")
@pytest.mark.parametrize("project", ["book", "dod"])
def test_documentation_pdf(project: str, tmp_path: Path) -> None:
    result = docodin("book", "build", ROOT / "docs" / project, "-o", tmp_path, "--pdf", "-W")
    assert result.returncode == 0, result.stderr
    assert next((tmp_path / "latex").glob("*.pdf")).read_bytes().startswith(b"%PDF")
