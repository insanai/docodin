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
    with pytest.raises(ImportError, match='Writer "nope" not found'):
        docodin.publish_native("x\n", writer="nope")
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


# --- documents that need Python --------------------------------------------------------------

def needs(text: str, writer: str = "html5", overrides: dict | None = None,
          source_path: str = "doc.rst") -> list[tuple]:
    """(feature, detail, source, line) of what the native publisher reports."""
    items = list((overrides or {}).items())
    result = docodin.native().publish(text, source_path, writer, items, "")
    return [(n.feature, n.detail, n.source, n.line) for n in result.needs_python]


def same_as_docutils(text: str, writer: str, overrides: dict | None = None,
                     source_path: str = "doc.rst") -> None:
    """The fallback's output, parts and messages are docutils'."""
    for function, parts in ((docutils_core.publish_string, False),
                            (docutils_core.publish_parts, True)):
        stream = io.StringIO()
        clear_caches()
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            ours = docodin.publish_native(text, source_path, writer,
                                          {**(overrides or {}), "warning_stream": stream},
                                          parts=parts)
        expected, messages = reference(function, text, writer,
                                       {"syntax_highlight": "long", **(overrides or {})})
        assert ours == expected
        assert stream.getvalue() == messages


CODE = """\
Title
=====

.. code:: python
   :number-lines:

   def f(x):
       return x + 1

Inline :code:`x = 1` without a language, and :py:`len(x)` with one.

.. role:: py(code)
   :language: python

.. code::

   no language

.. code:: nolanguage

   unknown lexer
"""


def test_pygments_detection(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.chdir(tmp_path)
    (tmp_path / "code.py").write_text("x = 1\n", encoding="utf-8")
    # the role is used before it is defined: an unknown role
    assert needs(CODE) == [("pygments", "python", "doc.rst", 4),
                           ("pygments", "nolanguage", "doc.rst", 19)]
    role = ".. role:: py(code)\n   :language: python\n\nA :py:`x` and :py:`y`.\n"
    assert needs(role) == [("pygments", "python", "doc.rst", 4)]
    assert needs(CODE, overrides={"syntax_highlight": "none"}) == []
    assert needs(".. code:: text\n\n   plain\n\n.. code::\n\n   x\n") == []
    assert needs(".. include:: code.py\n   :code: python\n", "pseudoxml") == [
        ("pygments", "python", "doc.rst", 1)]


@pytest.mark.parametrize("writer", WRITERS)
def test_pygments_fallback(writer: str) -> None:
    same_as_docutils(CODE, writer)
    same_as_docutils(CODE, writer, {"syntax_highlight": "short", "report_level": 1})


def write_png(path: Path, width: int, height: int) -> None:
    """A PNG image of the size (written with PIL)."""
    from PIL import Image

    Image.new("RGB", (width, height)).save(path)


IMAGES = """\
.. image:: pic.png
   :scale: 50

.. image:: pic.png
   :scale: 200
   :width: 10px

.. figure:: pic.png
   :figwidth: image

   Caption.
"""


def test_pil_detection(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.chdir(tmp_path)
    assert needs(IMAGES) == [("pil", "pic.png", "doc.rst", 1), ("pil", "pic.png", "doc.rst", 4)]
    (tmp_path / "pic.png").write_bytes(b"not read natively")
    assert needs(IMAGES) == [("pil", "pic.png", "doc.rst", 8), ("pil", "pic.png", "doc.rst", 1),
                             ("pil", "pic.png", "doc.rst", 4)]
    # no PIL: the LaTeX writer reads no sizes, file insertion off reads no figure width
    assert needs(IMAGES, "latex") == [("pil", "pic.png", "doc.rst", 8)]
    assert needs(IMAGES, "latex", {"file_insertion_enabled": False}) == []
    assert needs(".. image:: pic.png\n   :scale: 50\n   :width: 1\n   :height: 2\n") == []


@pytest.mark.parametrize("writer", ("html5", "latex", "pseudoxml"))
def test_pil_fallback(tmp_path: Path, monkeypatch, writer: str) -> None:
    pytest.importorskip("PIL")
    monkeypatch.chdir(tmp_path)
    write_png(tmp_path / "pic.png", 40, 30)
    same_as_docutils(IMAGES, writer)


def test_url_detection() -> None:
    """Detection only: the fallback would fetch the URLs."""
    text = (".. raw:: html\n   :url: https://example.invalid/raw.html\n\n"
            ".. csv-table::\n   :url: http://example.invalid/table.csv\n")
    assert needs(text) == [("url", "https://example.invalid/raw.html", "doc.rst", 1),
                           ("url", "http://example.invalid/table.csv", "doc.rst", 4)]
    assert needs(".. raw:: html\n   :url: file:missing.html\n") == []
    with pytest.raises(docodin.NeedsPythonError, match=r"doc\.rst:1: Fetching"):
        docodin.publish_native(text, "doc.rst", native_only=True)


LATIN9 = "Price: 5 \u20ac, \u0161\u017e \u0152uvre.\n"


@pytest.mark.parametrize("writer", ("html5", "latex", "pseudoxml"))
def test_latin9_include(tmp_path: Path, monkeypatch, writer: str) -> None:
    monkeypatch.chdir(tmp_path)
    (tmp_path / "inc.rst").write_bytes(LATIN9.encode("iso-8859-15"))
    text = "Title\n=====\n\n.. include:: inc.rst\n   :encoding: latin-9\n"
    assert needs(text, writer) == [("codec", "latin-9", "doc.rst", 4)]
    same_as_docutils(text, writer)
    plain = "Title\n=====\n\n.. include:: inc.rst\n"
    assert needs(plain, writer, {"input_encoding": "iso-8859-15"}) == [
        ("codec", "iso-8859-15", "doc.rst", 4)]
    same_as_docutils(plain, writer, {"input_encoding": "iso-8859-15"})
    assert needs(plain, writer, {"input_encoding": "latin-1"}) == []


def test_other_python_features(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.chdir(tmp_path)
    (tmp_path / "inc.rst").write_text("Included *text*.\n", encoding="utf-8")
    parsed = ".. include:: inc.rst\n   :parser: rst\n"
    assert needs(parsed) == [("parser", "rst", "doc.rst", 1)]
    same_as_docutils(parsed, "pseudoxml")
    assert needs(".. math:: a^2\n", overrides={"math_output": "MathML pandoc"}) == [
        ("mathml-converter", "pandoc", "doc.rst", 1)]
    assert needs("x\n", "pseudoxml", {"output_encoding": "cp1252"}) == [
        ("codec", "cp1252", "", 0)]
    same_as_docutils("Caf\u00e9 \u2019\n", "pseudoxml", {"output_encoding": "cp1252"})
    same_as_docutils("\u2192\n", "pseudoxml",
                     {"output_encoding": "ascii", "output_encoding_error_handler": "namereplace"})
    assert needs("x\n", "manpage") == [("writer", "manpage", "", 0)]
    same_as_docutils("Title\n=====\n\nText.\n", "manpage")


def test_native_only() -> None:
    with pytest.raises(docodin.NeedsPythonError) as info:
        docodin.publish_native(CODE, "doc.rst", "latex", native_only=True)
    assert [need.feature for need in info.value.needs] == ["pygments", "pygments"]
    assert "doc.rst:4: Highlighting \"python\" code needs Pygments." in str(info.value)
    with pytest.raises(docodin.NeedsPythonError):
        docodin.render_html(CODE, native_only=True)
    with pytest.raises(docodin.NeedsPythonError):
        docodin.render_latex(CODE, native_only=True)
    with pytest.raises(docodin.NeedsPythonError, match="writer"):
        docodin.publish_native("x\n", writer="manpage", native_only=True)
    with pytest.raises(docodin.NeedsPythonError, match="codec"):
        docodin.publish_native(b"x\xff\n", native_only=True)
    assert docodin.render_html("Text.\n", standalone=False, native_only=True) == (
        "<p>Text.</p>\n")


@pytest.mark.filterwarnings("ignore::FutureWarning")
def test_render_helpers_fall_back() -> None:
    clear_caches()
    expected = docutils_core.publish_parts(CODE, writer="html5",
                                           settings_overrides={"warning_stream": False})
    clear_caches()
    assert docodin.render_html(CODE, warning_stream=False) == expected["whole"]
    clear_caches()
    assert docodin.render_html(CODE, standalone=False, warning_stream=False) == (
        expected["body"])
    clear_caches()
    latex = docutils_core.publish_parts(CODE, writer="latex",
                                        settings_overrides={"warning_stream": False})
    clear_caches()
    assert docodin.render_latex(CODE, warning_stream=False) == latex["whole"]


def test_undecodable_bytes_fall_back() -> None:
    source = "Caf\u00e9 \u20ac\n".encode("iso-8859-15")
    settings = {"input_encoding": "iso-8859-15", "warning_stream": io.StringIO()}
    clear_caches()
    expected = docutils_core.publish_string(source, writer="pseudoxml",
                                            settings_overrides=dict(settings))
    clear_caches()
    assert docodin.publish_native(source, writer="pseudoxml",
                                  settings_overrides=dict(settings)) == expected
