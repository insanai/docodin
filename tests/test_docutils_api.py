"""docutils integration: publisher API, patching and front ends."""

from __future__ import annotations

import docodin
import docutils.core
import docutils.parsers
import docutils.parsers.rst

SOURCE = """\
Document Title
==============

:Author: Me

Some *text* with a reference_ and a footnote [#]_.

.. _reference: http://example.org

.. [#] The footnote.

.. note:: An admonition.

Section
-------

.. contents::
"""

OVERRIDES = {"warning_stream": "", "_disable_config": True}


def test_publish_string_matches_docutils():
    for writer in ("pseudoxml", "html5", "latex", "xml", "manpage"):
        ours = docodin.publish_string(SOURCE, writer=writer, settings_overrides=OVERRIDES)
        stock = docutils.core.publish_string(SOURCE, writer=writer, settings_overrides=OVERRIDES)
        assert ours == stock, writer


def test_publish_parts_matches_docutils():
    ours = docodin.publish_parts(SOURCE, writer="html5", settings_overrides=OVERRIDES)
    stock = docutils.core.publish_parts(SOURCE, writer="html5", settings_overrides=OVERRIDES)
    assert ours == stock


def test_publish_doctree_and_parse():
    doctree = docodin.publish_doctree(SOURCE, settings_overrides=OVERRIDES)
    assert doctree["title"] == "Document Title"
    raw = docodin.parse(SOURCE)
    assert raw.children[0].tagname == "section"  # no transforms applied


def test_patch_and_unpatch():
    stock_parse = docutils.parsers.rst.Parser.parse
    docodin.patch_docutils()
    try:
        assert docodin.is_patched()
        assert docutils.parsers.rst.Parser.parse is not stock_parse
        patched = docutils.core.publish_string(SOURCE, writer="html5", settings_overrides=OVERRIDES)
    finally:
        docodin.unpatch_docutils()
    assert docutils.parsers.rst.Parser.parse is stock_parse
    assert patched == docutils.core.publish_string(SOURCE, writer="html5", settings_overrides=OVERRIDES)


def test_parser_name_lookup():
    """``rst2html --parser=docodin`` resolves through docutils' parser lookup."""
    parser_class = docutils.parsers.get_parser_class("docodin")
    assert parser_class is docodin.Parser


def test_custom_state_classes_fall_back_to_docutils():
    class CustomParser(docodin.Parser):
        def __init__(self):
            super().__init__()
            self.state_classes = tuple(self.state_classes)[:-1]

    doc = docodin.publish_doctree("text", parser=CustomParser(), settings_overrides=OVERRIDES)
    assert doc.astext() == "text"
