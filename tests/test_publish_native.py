"""Tests of ``docodin.publish_native`` (the native pipeline through ``docodin_publish``)
against docutils' ``publish_string`` and ``publish_parts``."""

from __future__ import annotations

import io
import warnings
from pathlib import Path

import pytest

docutils_core = pytest.importorskip("docutils.core")

import docodin  # noqa: E402
from docutils import languages  # noqa: E402
from docutils.parsers.rst import directives, roles  # noqa: E402
from docutils.parsers.rst import languages as rst_languages  # noqa: E402
from docutils.utils import SystemMessage  # noqa: E402

pytestmark = pytest.mark.skipif(getattr(docutils_core, "__docodin_shim__", False)
                                or "/shim/" in docutils_core.__file__,
                                reason="needs the real docutils as the reference")

DOCS = {
    "basic": "Title\n=====\n\nText *em* \"quotes\" -- dash.\n\n.. note:: A note.\n\n`bad\n",
    "structure": """\
=========
 A Title
=========

:Author: A. Writer
:Date: 2026-09-27

.. contents::
.. sectnum::

Section
=======

A footnote [#]_, a citation [CIT]_, a `link <https://example.org>`_ and |sub|.

.. [#] Footnote.
.. [CIT] Citation.
.. |sub| replace:: *substituted*

Subsection
----------

- item one
- item two

  nested paragraph

1. first
2. second

term
  definition

:field: value

+-----+-----+
| a   | b   |
+=====+=====+
| c   | d   |
+-----+-----+

.. figure:: picture.png
   :width: 50%

   The caption.

.. math:: a^2 + b^2 = c^2

::

   literal block

.. topic:: Topic

   Body.
""",
    "errors": "Para\n\n.. unknown:: x\n\n.. image::\n\nref_ and [9]_\n\n* list\ntext\n",
}

OVERRIDES = [
    {},
    {"report_level": 1, "smart_quotes": True, "doctitle_xform": False},
    {"report_level": 2, "toc_backlinks": "top", "sectnum_xform": False,
     "language_code": "de"},
]
WRITERS = ("pseudoxml", "xml", "html5", "latex", "xetex")


def clear_caches() -> None:
    """A fresh process, as the native pipeline is, for docutils' process-wide caches."""
    languages.get_language.cache.clear()
    rst_languages.get_language.cache.clear()
    directives._directives.clear()
    roles._roles.clear()


def reference(function, text: str, writer: str, overrides: dict) -> tuple:
    clear_caches()
    stream = io.StringIO()
    settings = {"syntax_highlight": "none", **overrides, "warning_stream": stream}
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        result = function(text, source_path="doc.rst", writer=writer,
                          settings_overrides=settings)
    return result, stream.getvalue()


def native(text: str, writer: str, overrides: dict, parts: bool) -> tuple:
    stream = io.StringIO()
    settings = {"syntax_highlight": "none", **overrides, "warning_stream": stream}
    result = docodin.publish_native(text, "doc.rst", writer, settings, parts=parts)
    return result, stream.getvalue()


@pytest.mark.parametrize("writer", WRITERS)
@pytest.mark.parametrize("doc", sorted(DOCS))
@pytest.mark.parametrize("variant", range(len(OVERRIDES)))
def test_same_as_docutils(tmp_path: Path, monkeypatch, writer: str, doc: str,
                          variant: int) -> None:
    monkeypatch.chdir(tmp_path)
    overrides = OVERRIDES[variant]
    text = DOCS[doc]
    assert native(text, writer, overrides, False) == reference(
        docutils_core.publish_string, text, writer, overrides)
    theirs, messages = reference(docutils_core.publish_parts, text, writer, overrides)
    ours, our_messages = native(text, writer, overrides, True)
    assert our_messages == messages
    assert {k: v for k, v in ours.items() if k in theirs} == {
        k: v for k, v in theirs.items() if isinstance(v, str)}


def test_halting_raises_system_message() -> None:
    text = "`one\n\n`two\n"
    settings = {"halt_level": 2, "warning_stream": io.StringIO()}
    with pytest.raises(SystemMessage) as ours:
        docodin.publish_native(text, writer="pseudoxml", settings_overrides=dict(settings))
    with pytest.raises(SystemMessage) as theirs:
        docutils_core.publish_string(text, writer="pseudoxml",
                                     settings_overrides=dict(settings))
    assert str(ours.value) == str(theirs.value)
    assert ours.value.level == theirs.value.level == 2


def test_exceptions_have_docutils_classes() -> None:
    with pytest.raises(ImportError, match='Writer "odt" not found.'):
        docodin.publish_native("x\n", writer="odt")
    with pytest.raises(UnicodeEncodeError) as ours:
        docodin.publish_native("Caf\u00e9\n", writer="pseudoxml",
                               settings_overrides={"output_encoding": "ascii"})
    assert ours.value.start == ours.value.object.index("\u00e9")
    with pytest.raises(LookupError, match="unknown threshold"):
        docodin.publish_native("x\n", settings_overrides={"report_level": "loud"})


def test_output_types_and_encodings() -> None:
    text = "Caf\u00e9\n"
    out = docodin.publish_native(text, writer="pseudoxml",
                                 settings_overrides={"output_encoding": "latin-1"})
    assert out == docutils_core.publish_string(text, writer="pseudoxml",
                                               settings_overrides={"output_encoding": "latin-1"})
    out = docodin.publish_native(text, writer="pseudoxml",
                                 settings_overrides={"output_encoding": "unicode"})
    assert isinstance(out, str) and "Caf\u00e9" in out
    assert docodin.publish_native(text.encode(), writer="pseudoxml") == out.encode()


def test_render_helpers() -> None:
    html = docodin.render_html("Title\n=====\n\nText.\n")
    assert html.startswith("<!DOCTYPE html>") and '<h1 class="title">Title</h1>' in html
    body = docodin.render_html("Text.\n", standalone=False)
    assert body == "<p>Text.</p>\n"
    latex = docodin.render_latex("Text *em*.\n", standalone=False)
    assert latex == "\nText \\emph{em}.\n"


def test_classifier_after_empty_part() -> None:
    """``term : `ref`_``: docutils' classifier has no text for the empty part before the
    reference (both hosts of the native parser)."""
    text = "term : `x y`_\n  def\n\n.. _x y: http://a\n\n_`level` : text\n   def\n"
    settings = {"detailed": True, "warning_stream": io.StringIO()}
    expected = docutils_core.publish_string(text, writer="pseudoxml",
                                            settings_overrides=dict(settings))
    assert docodin.publish_string(text, writer="pseudoxml",
                                  settings_overrides=dict(settings)) == expected
    assert docodin.publish_native(text, writer="pseudoxml",
                                  settings_overrides=dict(settings)) == expected
