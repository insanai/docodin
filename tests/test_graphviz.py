"""Inline DOT must work natively in HTML and PDF without changing plain docutils."""

from __future__ import annotations

import re
import shutil
import subprocess
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
BINARY = ROOT / "bin" / "docodin"
pytestmark = pytest.mark.skipif(not BINARY.is_file() or not shutil.which("dot"),
                               reason="native tool and Graphviz required")


def run(*args: str | Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run([str(BINARY), *map(str, args)], capture_output=True,
                          text=True, timeout=120, check=False)


@pytest.fixture
def source(tmp_path: Path) -> Path:
    path = tmp_path / "index.rst"
    path.write_text("""DOT example
===========

.. graphviz::
   :alt: Source reaches the native engine.
   :caption: A **native** diagram.
   :name: native-diagram

   digraph pipeline { source -> native; }
""")
    return path


def test_graphviz_is_explicit_for_standalone_publication(source: Path) -> None:
    plain = run("--exit-status=warning", source)
    assert plain.returncode != 0
    assert 'Unknown directive type "graphviz"' in plain.stderr
    out = source.parent / "result.html"
    rendered = run("--graphviz", "--exit-status=warning", source, out)
    assert rendered.returncode == 0, rendered.stderr
    text = out.read_text()
    uri = re.search(r'src="([^"]+\.svg)"', text)
    assert uri and not Path(uri[1]).is_absolute()
    assert (out.parent / uri[1]).is_file()
    assert "Source reaches the native engine." in text
    assert "native-diagram" in text and "<strong>native</strong>" in text


@pytest.mark.parametrize("directive, code", [
    ("graphviz", "digraph example { source -> native; }"),
    ("digraph:: example", "source -> native;"),
    ("graph:: example", "source -- native;"),
])
def test_book_renders_inline_directives(tmp_path: Path, directive: str, code: str) -> None:
    project = tmp_path / "project"
    project.mkdir()
    (project / "conf.py").write_text('project = "DOT"\n')
    heading = directive if "::" in directive else f"{directive}::"
    (project / "index.rst").write_text(f"DOT\n===\n\n.. {heading}\n\n   {code}\n")
    result = run("book", "build", project, "--html", "-W", "-o", tmp_path / "build")
    assert result.returncode == 0, result.stderr
    html = tmp_path / "build" / "html"
    image = re.search(r'src="([^"]+\.svg)"', (html / "index.html").read_text())
    assert image and (html / image[1]).is_file()
    svg = (html / image[1]).read_text()
    assert ">source</text>" in svg and ">native</text>" in svg


def test_failed_dot_stops_warning_as_error_build(source: Path) -> None:
    (source.parent / "conf.py").write_text('project = "DOT"\n')
    source.write_text("DOT\n===\n\n.. graphviz::\n\n   digraph broken { source -> }\n")
    result = run("book", "build", source.parent, "--html", "-W", "-o", source.parent / "build")
    assert result.returncode != 0
    assert "Graphviz failed" in result.stderr
    assert not list((source.parent / "build" / "_graphviz").glob("*.svg"))


def test_adaptive_book_diagrams_have_distinct_svg_palettes(source: Path) -> None:
    (source.parent / "conf.py").write_text('project = "DOT"\n')
    text = source.read_text().replace('.. graphviz::', '.. graphviz::\n   :class: adaptive-diagram')
    source.write_text(text.replace('digraph pipeline {',
                                  'digraph pipeline { node [fillcolor="#EFF4FF", style=filled];'))
    out = source.parent / "build"
    result = run("book", "build", source.parent, "--html", "-W", "-o", out)
    assert result.returncode == 0, result.stderr
    html = (out / "html" / "index.html").read_text()
    assert "graphviz-light" in html and "graphviz-dark" in html
    images = list((out / "html" / "_images").glob("*.svg"))
    assert len(images) == 2
    palettes = [image.read_text().lower() for image in images]
    assert any('fill="#eff4ff"' in text for text in palettes)
    assert any('fill="#1b2b48"' in text for text in palettes)


def test_graphviz_python_need_has_clear_diagnostic(source: Path) -> None:
    result = run("--graphviz", "--config=ignored.conf", source)
    assert result.returncode == 1
    assert "--graphviz needs native publication" in result.stderr


def test_concurrent_standalone_builds_share_complete_assets(source: Path) -> None:
    def publish(number: int):
        return run("--graphviz", "--exit-status=warning", source,
                   source.parent / f"page-{number}.html")
    with ThreadPoolExecutor(max_workers=4) as pool:
        results = list(pool.map(publish, range(8)))
    assert all(result.returncode == 0 for result in results), [r.stderr for r in results]
    assets = source.parent / "_graphviz"
    assert len(list(assets.glob("*.svg"))) == 1
    assert not list(assets.glob("render-*"))


def test_pdf_contains_vector_graphviz(source: Path) -> None:
    engine = shutil.which("lualatex")
    if not engine and Path("/Library/TeX/texbin/lualatex").is_file():
        engine = "/Library/TeX/texbin/lualatex"
    if not engine or not shutil.which("pdftotext"):
        pytest.skip("LuaLaTeX and Poppler required")
    output = source.parent / "diagram.pdf"
    result = run("pdf", "--graphviz", f"--engine={engine}", "--exit-status=warning", source, output)
    assert result.returncode == 0, result.stderr
    text = subprocess.check_output(["pdftotext", str(output), "-"], text=True)
    assert "source" in text and "native" in text
    vector = next((source.parent / "_graphviz").glob("*.pdf"))
    assert vector.read_bytes().startswith(b"%PDF-")
