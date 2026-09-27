"""docodin must produce exactly the docutils document tree (incl. messages)."""

from __future__ import annotations

import docutils.frontend
import docutils.parsers.rst
import docutils.utils
import pytest

CASES = {
    "sections": "Title\n=====\n\nPara.\n\nSub\n---\n\ntext\n\nOther\n=====\n",
    "overlined": "=======\n Title\n=======\n\nSub\n---\n",
    "inconsistent_titles": "A\n=\n\nB\n-\n\nC\n~\n\nD\n=\n\nE\n~\n",
    "inline": ("*em* **strong** ``lit`` `interp` :emphasis:`role` `ref`_ ref_ anon__ "
               "[1]_ [#]_ [*]_ [CIT2002]_ |sub| _`inline target` http://x.org a@b.org\n"),
    "inline_edge_cases": "2*3*4 ``a``b *a *b* c* \\*escaped\\* ***x*** `a\\`b` :a:`b`:c:\n",
    "phrase_refs": "`name <http://u>`_ `alias <tgt_>`_ `<http://only>`_ `anon <http://a>`__ `x`__\n",
    "unclosed": "*unclosed **also ``lit `interp |sub _`t\n",
    "bullet_lists": "- a\n- b\n\n  nested\n\n  - deep\n\n+ other bullet\n",
    "enumerated": ("1. a\n2. b\n\n(a) x\n(b) y\n\ni. roman\nii. roman\n\n#. auto\n#. auto\n\n"
                   "3. starts at 3\n"),
    "definition_lists": "Term\n  Def\n\nTerm : classifier : two\n  Def\n\nNot term::\n  x\n",
    "field_lists": ":a: b\n:long field: body\n  continued\n\n  second para\n:empty:\n",
    "option_lists": ("-a            short\n--long=ARG    long\n-b FILE, --bee=FILE  both\n"
                     "/V            dos\n"),
    "literal_blocks": "Para::\n\n  code\n\n::\n\n  more\n\nQuoted::\n\n> a\n> b\n",
    "doctest": ">>> 1 + 1\n2\n",
    "line_blocks": "| a\n|   b\n|     c\n| d\n",
    "block_quotes": "Para\n\n  quote\n\n  -- attribution\n\n  another\n",
    "transitions": "Para\n\n----\n\nPara\n",
    "grid_table": ("+-----+-----+\n| a   | b   |\n+=====+=====+\n| c   | d   |\n+-----+-----+\n"
                   "| span      |\n+-----------+\n"),
    "simple_table": "=====  =====\nA      B\n=====  =====\n1      2\n3      spans\n=====  =====\n",
    "east_asian_table": "=====  ======\nダイ1  ダイ2\n=====  ======\n",
    "explicit": (".. [1] fn\n.. [#auto] auto\n.. [*] sym\n.. [CIT] cit\n.. _tgt: http://x\n"
                 ".. _indirect: tgt_\n.. __: http://anon\n.. |sub| replace:: text\n.. comment\n..\n"),
    "directives": (".. note:: body\n\n.. image:: pic.png\n   :alt: x\n\n.. unknown:: arg\n\n"
                   ".. topic:: T\n\n   text\n"),
    "malformed": ".. _bad\n\n.. |bad|\n\n+--+\n| x\n\n=== ===\nnot closed\n",
    "unicode": "Ünïcödé Title\n=============\n\n— attribution-ish ✓ テキスト\n",
    "tabs_and_whitespace": "\tTab\tindented\n\nPara\x0bwith\x0cws\r\nline\n",
    "hang_regression": "section underline too short\n-----\n",
    "empty": "",
}


@pytest.mark.parametrize("name", sorted(CASES))
def test_parity(assert_parity, name):
    assert_parity(CASES[name])


def test_character_level_inline_markup(assert_parity):
    assert_parity("a*b*c ``x``y text_ref_\n", character_level_inline_markup=True)


def test_pep_rfc_references(assert_parity):
    assert_parity("See PEP 8 and pep-0287.txt and RFC 2822 and RFC-1234.\n",
                  pep_references=True, rfc_references=True)


def test_trim_footnote_reference_space(assert_parity):
    assert_parity("Footnote [1]_ and citation [CIT]_.\n\n.. [1] a\n.. [CIT] b\n",
                  trim_footnote_reference_space=True)


def test_line_length_limit(assert_parity):
    assert_parity("short\n" + "x" * 200 + "\n", line_length_limit=100)


def test_deep_nesting_is_bounded():
    """docutils fails with RecursionError past ~150 levels; docodin reports."""
    import docodin
    from conftest import parse_pformat

    text = "".join(" " * i + "para\n\n" for i in range(400))
    out = parse_pformat(docodin.Parser(), text)
    assert "Nesting too deep" in out


INCLUDE_FILES = {
    "inc.rst": "Included para.\n\nMore.\n",
    "nest.rst": "Inner para.\n\n.. include:: inc.rst\n",
    "tail.rst": "Tail\n\n.. note:: x",
}
INCLUDE_CASES = {
    "end": "Para.\n\n.. include:: inc.rst\n",
    "end_blanks": "Para.\n\n.. include:: inc.rst\n\n\n",
    "middle": "Para.\n\n.. include:: inc.rst\n\nAfter.\n",
    "nested": "Para.\n\n.. include:: nest.rst\n",
    "nested_mid": ".. include:: nest.rst\n\nZ\n",
    "tail_construct": "Para.\n\n.. include:: tail.rst\n",
    "twice": ".. include:: inc.rst\n.. include:: tail.rst\n",
    "in_note": ".. note::\n\n   .. include:: inc.rst\n",
    "section": "Title\n=====\n\n.. include:: inc.rst\n\nSub\n---\n\n.. include:: tail.rst\n",
}


@pytest.mark.parametrize("name", INCLUDE_CASES)
def test_include_leaves_the_reporter_where_docutils_does(name, tmp_path, monkeypatch):
    """Transforms and writers report through the state machine's final position."""
    import docodin

    for file, text in INCLUDE_FILES.items():
        (tmp_path / file).write_text(text, encoding="utf-8")
    monkeypatch.chdir(tmp_path)

    def state(parser):
        settings = docutils.frontend.get_default_settings(docutils.parsers.rst.Parser)
        settings.report_level = settings.halt_level = 5
        settings.warning_stream = ""
        document = docutils.utils.new_document("main.rst", settings)
        parser.parse(INCLUDE_CASES[name], document)
        return (document.pformat(), document.reporter.get_source_and_line(),
                document.current_source, document.current_line)

    assert state(docodin.Parser()) == state(docutils.parsers.rst.Parser())


def _document_state(parser, text: str, **settings_overrides) -> tuple:
    """Everything a parse leaves behind: pseudo-XML, the source and line of
    every element, the warning stream (all messages, in creation order) and
    the reporter's and document's position."""
    import io

    from docutils import nodes
    from docutils.parsers.rst import directives, roles

    roles._roles.clear()  # docutils caches roles and directives per process
    directives._directives.clear()
    settings = docutils.frontend.get_default_settings(docutils.parsers.rst.Parser)
    stream = io.StringIO()
    settings.warning_stream = stream
    settings.report_level = 1
    settings.halt_level = 5
    for key, value in settings_overrides.items():
        setattr(settings, key, value)
    document = docutils.utils.new_document("test data", settings)
    parser.parse(text, document)
    positions = [(n.tagname, n.source, n.line) for n in document.findall(nodes.Element)]
    return (document.pformat(), positions, stream.getvalue(),
            document.reporter.get_source_and_line(), document.current_source,
            document.current_line)


# Host bugs found by the directive fuzzer (tests/fuzz_differential.py --directives).
STATE_CASES = {
    # the reporter's line stays where the root machine is: explicit lists run
    # in a nested state machine
    "explicit_list_reporter_line": (".. _t1:\n.. note:: x\n   :name: a b\n.. _t2:\n\n"
                                    ".. note:: y\n   :name: a b\n"),
    # a nested state machine that ran past the end of its input leaves the
    # source of its last line
    "end_of_input_source": (".. |sub| replace:: text\n  :other: more\n   .. |sub| replace:: text"
                            "\n\n    Term\n      Def\n"),
    # a grid table reports an indented line after it before parsing its cells
    "grid_table_indentation": ("+---+-----+\n| a | *b  |\n+---+-----+\n  indented\ntext\n"),
    # a paragraph in a table cell reports an indented line before its inline
    # markup (cell lines are numbered one ahead of the source)
    "cell_paragraph_indentation": "====  ====\nR     `x\n      y\n        ]\n====  ====\n",
}


@pytest.mark.parametrize("name", sorted(STATE_CASES))
def test_document_state(name):
    import docodin

    text = STATE_CASES[name]
    assert (_document_state(docodin.Parser(), text)
            == _document_state(docutils.parsers.rst.Parser(), text))


def test_parsed_literal_error_after_include():
    """Only the literal block of ``parsed-literal`` carries an absolute line
    (renumbered after an include), not its error message."""
    import docodin

    text = ".. include:: <isonum.txt>\n.. parsed-literal::\n\n"
    assert (_document_state(docodin.Parser(), text)
            == _document_state(docutils.parsers.rst.Parser(), text))


# ``include``: docutils parses the inserted lines in the state machine that ran
# the directive (explicit lists, block quotes, directive content, table cells)
INCLUDE_STATE_CASES = {
    "block_quote": " .. include:: <isonum.txt>\n.. _tgt:\n",
    "explicit_list": ".. include:: <isonum.txt>\n.. _a:\n.. note:: x\n   :name: a\n",
    "nested_directive": ".. note::\n\n   .. include:: <isolat1.txt>\n\n   |Auml| after\n\nText\n",
    "figure_content": ".. figure:: f.png\n\n  .. include:: <isonum.txt>\n- list\n",
    "substitution_content": (".. |r2| replace:: two\n\n    .. include:: <isonum.txt>\n"
                             "    .. role:: x(literal)\n       :format: no\n"),
    "table_cell": ".. csv-table::\n\n    .. include:: <isonum.txt>\n   .. _ftarget:\n",
    "line_block_after": ".. include:: <isonum.txt>\n\n.. line-block::\n\n   a\n    *b\n",
}


@pytest.mark.parametrize("name", sorted(INCLUDE_STATE_CASES))
def test_include_state(name):
    import docodin

    text = INCLUDE_STATE_CASES[name]
    assert (_document_state(docodin.Parser(), text)
            == _document_state(docutils.parsers.rst.Parser(), text))


def test_directive_content_spliced_around_options():
    """Content before and after the options: docutils numbers its lines
    through the directive's input lines."""
    import docodin

    text = ".. note:: x\n   :name: a b\n\n   Sub\n   ---\n"
    assert (_document_state(docodin.Parser(), text)
            == _document_state(docutils.parsers.rst.Parser(), text))
