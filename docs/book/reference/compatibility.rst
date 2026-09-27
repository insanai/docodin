.. _compatibility:

=============================
Compatibility and fidelity
=============================

What "identical" means
======================

docodin reproduces docutils 0.22.4.  For the same input and settings, docodin gives:

- the same document tree, node by node, with the same attributes;
- the same ``source`` and ``line`` on every node;
- the same system messages, with the same texts, levels and order, written to the same
  stream in the same format;
- the same output of every writer, byte for byte, and the same ``publish_parts``;
- the same exceptions, with the same class and message;
- the same exit status of the command-line tools.

This holds for the docutils package inside Python and for the native pipeline, whose
outputs are compared with docutils in the same ways.  The exceptions are listed in
:doc:`limits`.

Versions
========

.. list-table::
   :widths: 30 70

   * - docutils
     - 0.22.4 is the reference.  docodin's package reports itself as docutils 0.22.4
       (``docutils.__version__``).
   * - Python
     - 3.12 or later.
   * - Sphinx
     - 8.0 or later for the ``sphinx`` extra; the measurements and test runs in this
       book use Sphinx 9.1.
   * - Unicode
     - the native character tables come from CPython 3.14 (Unicode 16).  The
       differential scripts that produce docutils' reference dumps run under CPython 3.14
       for that reason.

How it is verified
==================

.. list-table::
   :header-rows: 1
   :widths: 40 60

   * - Test
     - Result
   * - docutils' own test suite, run on docodin's package
     - 465 passed, 17 skipped, 1862 subtests: the same as docutils, natively and with
       ``DOCODIN_NATIVE=0``
   * - Sphinx 9.1's test suite, run on docodin
     - 2407 passed; the 7 failures are environment-related and fail the same way with
       docutils; the pass and fail lists are the same with docutils, the native parser
       and the forced Python parser
   * - Test suites of extensions and themes
     - myst-parser, sphinx-design, sphinx-tabs, sphinxcontrib-bibtex,
       sphinx-autodoc-typehints, sphinx-gallery, pydata-sphinx-theme, sphinx-book-theme,
       sphinxext-opengraph, sphinx-notfound-page, sphinx-rtd-theme and breathe: the same
       results as with docutils
   * - Documentation builds
     - the documentation of furo, pydata-sphinx-theme, MyST and sphinx-design builds to
       identical output with the html, latex, man and text builders; CPython's
       documentation to identical HTML
   * - Parser differential fuzzing (``tests/fuzz_differential.py``)
     - generated and mutated documents: pseudo-XML with every message, and every node's
       ``source`` and ``line``, identical
   * - Package differential (``tests/shim_differential.py``)
     - every writer under random settings: outputs, warnings, exceptions and node
       positions identical
   * - Native pipeline differentials (``tests/native_*_differential.py``)
     - each native stage, then ``publish`` end to end, against docutils: output, parts,
       warning stream, failure report and exit status identical
   * - Checker differential (``tests/lint_differential.py``)
     - the checker's messages equal docutils' parser messages
   * - Language server (``tests/test_lsp.py``)
     - diagnostics equal docutils' messages; definitions agree with docutils' resolved
       references

:doc:`../development/testing` and :doc:`../development/differential-testing` describe
how to run them.

What stays Python
=================

Where docutils uses a Python library (Pygments, PIL, ``urllib``, codecs, parser and
writer modules, external MathML converters), docodin uses the same library: the docutils
package calls it as docutils does, and the native tools hand such documents to docutils.
So a document's result depends on the installed libraries exactly as it does with
docutils (DOD 9).

Extensions that change the grammar
==================================

Extensions that subclass or patch docutils' parser states, or its ``Inliner``, work as
with docutils: docodin detects the change and parses those documents with its
pure-Python parser (DOD 7).  sphinx-autodoc-typehints' replacements of ``Body.doctest``
and ``Text.indent`` are replayed on the native parser's output, so its documents keep the
native parser.
