"""Tests for the DocOdin docutils compatibility shim.

Verifies that DocOdin can serve as a complete zero-dependency drop-in replacement
for upstream docutils across nodes, core publisher, and writers.
"""

from __future__ import annotations

import sys
from typing import Any

import pytest

import docodin
from docodin.shim import install_shim, uninstall_shim


def test_shim_installation_and_submodules() -> None:
    """Verify that install_shim registers all required docutils submodules in sys.modules."""
    install_shim(force=True)
    try:
        import docutils
        import docutils.core
        import docutils.frontend
        import docutils.nodes
        import docutils.parsers.rst
        import docutils.parsers.rst.directives
        import docutils.parsers.rst.roles
        import docutils.parsers.rst.states
        import docutils.statemachine
        import docutils.transforms
        import docutils.utils
        import docutils.writers
        import docutils.writers.html5_polyglot
        import docutils.writers.latex2e

        assert getattr(docutils, "_is_docodin_shim", False) is True
        assert hasattr(docutils.nodes, "document")
        assert hasattr(docutils.core, "Publisher")
        assert hasattr(docutils.parsers.rst, "Directive")
        assert hasattr(docutils.statemachine, "StringList")
        assert hasattr(docutils.frontend, "get_default_settings")
    finally:
        uninstall_shim()


def test_shim_publish_string_html_and_latex() -> None:
    """Verify that docutils.core.publish_string generates valid HTML and LaTeX through DocOdin."""
    install_shim(force=True)
    try:
        import docutils.core

        content = "Title\n=====\n\nHello **world** from DocOdin!"
        html = docutils.core.publish_string(content, writer_name="html5")
        assert isinstance(html, (bytes, str))
        html_str = html.decode("utf-8") if isinstance(html, bytes) else html
        assert "<section" in html_str
        assert "<h1>Title</h1>" in html_str
        assert "<strong>world</strong>" in html_str

        tex = docutils.core.publish_string(content, writer_name="latex")
        assert isinstance(tex, (bytes, str))
        tex_str = tex.decode("utf-8") if isinstance(tex, bytes) else tex
        assert "\\documentclass{article}" in tex_str
        assert "\\section{Title}" in tex_str
        assert "\\textbf{world}" in tex_str
    finally:
        uninstall_shim()


def test_shim_nodes_and_visitor() -> None:
    """Verify document tree construction, traversal, and formatting using shim nodes."""
    from docodin.shim import nodes

    doc = nodes.document()
    sec = nodes.section(ids=["intro"])
    tit = nodes.title("Introduction", "Introduction")
    p = nodes.paragraph("", "Welcome to DocOdin.")
    p += nodes.strong(" fast", " fast")

    sec += tit
    sec += p
    doc += sec

    assert len(doc) == 1
    assert doc[0] is sec
    assert sec.section_hierarchy() == [sec]
    assert "intro" in sec.attributes["ids"]
    assert "Welcome to DocOdin. fast" in p.astext()

    formatted = doc.pformat()
    assert "<document>" in formatted
    assert "<section ids=['intro']>" in formatted
    assert "<title>" in formatted


def test_native_rendering_html_and_latex() -> None:
    """Verify direct native Odin HTML5 and LaTeX rendering functions."""
    content = "Hello DocOdin\n=============\n\nThis is a *fast* test with **bold** text."

    html_out = docodin.render_html(content, title="My Test", standalone=True)
    assert "<!DOCTYPE html>" in html_out
    assert "<title>My Test</title>" in html_out
    assert '<h1 id="hello-docodin">Hello DocOdin</h1>' in html_out
    assert "<em>fast</em>" in html_out
    assert "<strong>bold</strong>" in html_out

    tex_out = docodin.render_latex(content, title="My Test", standalone=True)
    assert "\\documentclass[11pt,a4paper]{article}" in tex_out
    assert "\\title{My Test}" in tex_out
    assert "\\section{Hello DocOdin}" in tex_out
    assert "\\emph{fast}" in tex_out
    assert "\\textbf{bold}" in tex_out


def test_native_statemachine_string2lines() -> None:
    """Verify that shim string2lines delegates to the native Odin line splitter."""
    install_shim(force=True)
    try:
        from docutils.statemachine import string2lines

        text = "line 1\r\n\tline 2 with tab\nline 3"
        lines = string2lines(text, tab_width=4)
        assert len(lines) == 3
        assert lines[0] == "line 1"
        assert lines[1] == "    line 2 with tab"
        assert lines[2] == "line 3"
    finally:
        uninstall_shim()


def test_sphinx_conf_discovery_and_metadata(tmp_path: Any) -> None:
    """Verify Sphinx conf.py metadata extraction in python and the native CLI compiler."""
    import subprocess
    from pathlib import Path
    from docodin.conf import find_conf_py, get_metadata

    conf_dir = Path(tmp_path) / "docs"
    conf_dir.mkdir(parents=True)
    conf_file = conf_dir / "conf.py"
    conf_file.write_text(
        "project = 'Sphinx Test Doc'\n"
        "author = 'Insan.ai Engineers'\n"
        "version = '1.0'\n"
        "release = '1.0.0'\n"
        "html_title = 'Sphinx Test Doc Documentation'\n",
        encoding="utf-8",
    )

    doc_file = conf_dir / "index.rst"
    doc_file.write_text(
        "Welcome\n=======\n\nDocOdin native test.\n",
        encoding="utf-8",
    )

    # 1. Test Python metadata extraction
    found = find_conf_py(doc_file)
    assert found == conf_file

    meta = get_metadata(doc_file)
    assert meta["project"] == "Sphinx Test Doc"
    assert meta["title"] == "Sphinx Test Doc Documentation"
    assert meta["author"] == "Insan.ai Engineers"

    # 2. Test Standalone Odin CLI auto-extracting conf.py metadata
    cli_bin = Path(__file__).resolve().parent.parent / "bin" / "docodin"
    if cli_bin.is_file():
        out_html = conf_dir / "index.html"
        result = subprocess.run(
            [str(cli_bin), "html", str(doc_file), "-o", str(out_html)],
            capture_output=True,
            text=True,
        )
        assert result.returncode == 0
        html_content = out_html.read_text(encoding="utf-8")
        assert "Sphinx Test Doc Documentation" in html_content
        assert '<h1 id="welcome">Welcome</h1>' in html_content
