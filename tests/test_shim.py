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
