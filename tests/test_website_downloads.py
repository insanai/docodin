"""Documentation downloads must resolve from every native website page."""

from __future__ import annotations

import importlib
import re
from pathlib import Path
from urllib.parse import unquote

import pytest

ROOT = Path(__file__).resolve().parent.parent


@pytest.fixture
def website_tools(monkeypatch):
    monkeypatch.syspath_prepend(str(ROOT / "scripts"))
    return importlib.import_module("build_site")


def pdf_fixtures(directory: Path, tools) -> list[str]:
    names = ["docodin-book.pdf", "docodin-dod.pdf"]
    names.extend(f"dod-{source.stem}.pdf" for source in tools.record_sources())
    directory.mkdir()
    for name in names:
        (directory / name).write_bytes(b"%PDF-1.7\nfixture")
    return names


@pytest.mark.skipif(not (ROOT / "bin" / "docodin").is_file(), reason="native tool not built")
def test_every_native_page_has_resolving_pdf_downloads(tmp_path: Path, website_tools) -> None:
    pdfs = tmp_path / "pdfs"
    names = pdf_fixtures(pdfs, website_tools)
    site = tmp_path / "website"
    website_tools.build_site(ROOT / "bin" / "docodin", site, pdfs)
    assert sorted(path.name for path in (site / "pdf").glob("*.pdf")) == sorted(names)
    for page in site.rglob("*.html"):
        assert 'class="system-message"' not in page.read_text(), page
        panel = re.search(r'<nav class="document-downloads"[^>]*>(.*?)</nav>',
                          page.read_text(), re.DOTALL)
        assert panel, page
        targets = [(page.parent / unquote(href)).resolve()
                   for href in re.findall(r'href="([^"]+)"', panel[1])]
        assert all(target.is_file() and target.parent == site / "pdf" for target in targets)
        individual = f"dod-{page.stem}.pdf"
        if page.parent == site / "dod" and individual in names:
            assert site / "pdf" / individual in targets
        if page.relative_to(site).parts[0] == "book":
            assert targets == [site / "pdf" / "docodin-book.pdf"]


@pytest.mark.parametrize("damage", ["missing", "invalid"])
@pytest.mark.skipif(not (ROOT / "bin" / "docodin").is_file(), reason="native tool not built")
def test_failed_pdf_assembly_keeps_existing_site(tmp_path: Path, website_tools, damage: str) -> None:
    pdfs = tmp_path / "pdfs"
    names = pdf_fixtures(pdfs, website_tools)
    record = pdfs / names[-1]
    if damage == "missing":
        record.unlink()
    else:
        record.write_bytes(b"not a PDF")
    site = tmp_path / "website"
    site.mkdir()
    marker = site / "index.html"
    marker.write_text("previous website")
    with pytest.raises((FileNotFoundError, ValueError)):
        website_tools.build_site(ROOT / "bin" / "docodin", site, pdfs)
    assert marker.read_text() == "previous website"
    assert list(site.iterdir()) == [marker]
