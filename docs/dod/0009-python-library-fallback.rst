==============================================================================
DOD 9: Python Libraries Stay Python
==============================================================================

:Authors: Vikrant Rathore
:State: committed
:Created: 2026-09-27
:Discussion:
:Labels: native, compatibility, tooling

.. contents:: Contents
   :local:
   :depth: 1

Summary
=======

For a few features docutils calls Python libraries: Pygments to highlight code, PIL to
read image sizes, ``urllib`` to fetch URLs, Python's codecs for unusual encodings, and
parser and writer modules.  docodin does not reimplement them.  The native pipeline
records a *Python need* wherever docutils would use one, and the tools then publish the
document with docutils instead.  So native publishing is complete: every document gets
docutils' result, with the Python libraries that are installed.

Background
==========

A native pipeline that ignored these features would silently produce different output:
code without highlighting, figures without widths.  Porting the libraries is not
realistic: Pygments alone has hundreds of lexers, and the results would have to match the
installed library versions exactly.

Proposal
========

Python needs
------------

Each stage records a need (``doctree.Python_Need``: feature, detail, source and line)
where docutils would use a library:

.. list-table::
   :header-rows: 1
   :widths: 22 78

   * - Feature
     - Where docutils uses Python
   * - Pygments
     - the ``code`` directive and role (and ``include`` with ``:code:``) with a language
       other than ``text``, when ``syntax_highlight`` is not ``none``
   * - PIL
     - HTML5 writer: an image with ``:scale:`` but not both ``:width:`` and ``:height:``;
       a figure with ``:figwidth: image``; when file insertion is on and the image exists
   * - ``urllib``
     - ``raw`` and ``csv-table`` with a ``:url:`` other than a local ``file:`` URL
   * - codecs
     - an encoding other than UTF-8, UTF-8-sig, Latin-1 and ASCII for the source, included,
       raw and CSV files (UTF-16 and UTF-32 are also native for the output), and error
       handlers other than the native ones
   * - parser modules
     - the ``include`` directive's ``:parser:`` option
   * - external programs
     - ``math_output`` MathML with latexml, ttm, blahtexml or pandoc
   * - writer modules
     - writers other than pseudoxml, xml, html5, latex and xetex
   * - front end
     - the options ``--config``, ``--record-dependencies`` and ``--dump-*`` of the
       ``docodin`` command

Until the first need, the native run is exactly docutils' run.  After it, the pipeline
goes on as docutils would without the library (no highlighting, no image sizes, with
docutils' warnings), so the differential tests can still compare it with docutils in an
environment without Pygments and PIL, but its result is not used.

What the hosts do
-----------------

- ``publish.publish`` returns the needs with its results; ``docodin_publish`` in the C
  ABI adds them to its result.
- ``docodin.publish_native``, ``render_html`` and ``render_latex`` publish such a
  document with the importable docutils (``publish_string`` or ``publish_parts`` with the
  same arguments).  With ``native_only=True`` they raise ``docodin.NeedsPythonError``,
  which lists each need and its line.
- The ``docodin`` command runs ``python -m docodin`` with the same arguments, standard
  streams and exit status; standard input it already read is passed on.  The Python is
  ``$DOCODIN_PYTHON``, else ``python3`` on the ``PATH``, if it imports docodin.  Without
  one it prints an Elm-style report for each need, with the source line and how to do
  without the library, and exits with status 1:

  .. code-block:: text

     -- NEEDS PYTHON ---------------------------------------------------- guide.rst:4

     Highlighting "python" code needs Pygments.

     docodin runs these with docutils' Python front end (`python -m docodin`), but
     found no Python that imports docodin: it tries `$DOCODIN_PYTHON`, then
     `python3`.

     4| .. code:: python
        ^^^^^^^^^^^^^^^^
     Hint: Install docodin's Python package (`pip install docodin`) or set
     `DOCODIN_PYTHON` to a Python that has it, or write `--syntax-highlight=none` to
     publish the code without highlighting.

Alternatives
============

- **Port the libraries.**  Large, never finished, and never identical to the installed
  versions.
- **Degrade silently** (publish without highlighting).  Breaks the promise of docutils'
  output without telling anyone.
- **Always require Python.**  Gives up native publishing for the large majority of
  documents that need no library.

Compatibility and fidelity
==========================

The result is always docutils' result.  A document without needs is published natively;
a document with needs is published by docutils.

Verification
============

``tests/native_publish_differential.py`` counts the documents with needs by feature and
still compares their native output with docutils' output without the libraries.
``tests/test_publish_native.py`` and ``tests/test_native_cli.py`` cover the hosts: the
fallback, ``native_only`` and the report without Python.

Outcome
=======

Implemented in docodin 0.1.0 ("Record where docutils would use a Python library in the
native pipeline", "Run documents that need Python libraries through python -m docodin in
the native CLI", "Publish documents that need Python libraries with docutils in
publish_native").

References
==========

- ``odin/doctree/python_needs.odin``, ``odin/publish/needs.odin``,
  ``cmd/docodin/python.odin``, ``python/docodin/_publish.py``.
