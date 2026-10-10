.. _command-line:

=====================
The command line
=====================

docodin has two front ends.  The **native** ``docodin`` program, which the wheel
installs (and ``scripts/build_odin.sh`` builds as ``bin/docodin``), publishes without
Python and builds books.  The **Python** one, ``python -m docodin``, is docutils' front end
with docodin's parser; the native program runs it for what it does not do natively.
Both take docutils' options and write docutils' output.  This chapter is about using
them; :doc:`../reference/cli` lists every option.

Publishing with the native command
==================================

.. code-block:: console

   $ docodin doc.rst doc.html                          # as: python -m docutils doc.rst doc.html
   $ docodin --writer=latex --documentclass=book doc.rst doc.tex
   $ docodin latex doc.rst doc.tex                     # the writer as the first argument
   $ docodin pseudoxml doc.rst                         # to standard output
   $ cat doc.rst | docodin - doc.html                  # from standard input

``docodin [--writer=NAME] [options] [SOURCE [DESTINATION]]`` reads ``SOURCE`` (standard
input when it is missing or ``-``) and writes ``DESTINATION`` (standard output when it is
missing).  The writers are ``html5`` (the default, also ``html`` and ``xhtml``),
``latex`` (``latex2e``), ``xetex``, ``xml`` and ``pseudoxml``.  A writer name as the first
argument selects it, and so does the name of the program: links named ``rst2html``,
``rst2html5``, ``rst2latex``, ``rst2xetex``, ``rst2xml`` or ``rst2pseudoxml`` that point
to ``docodin`` behave like docutils' commands of the same names.

.. code-block:: console

   $ ln -s "$(command -v docodin)" ~/.local/bin/rst2xetex
   $ rst2xetex doc.rst doc.tex

The options are docutils' front-end options: report, halt and exit-status levels, title
and docinfo switches, section numbering, backlinks, footnote references, smart quotes,
stripping, language, encodings, stylesheets, math output, table styles, the LaTeX
document class and options, and so on.  ``docodin --help`` lists the options of the
html5 writer, and ``docodin --help --writer=latex`` those of another writer.  An unknown
option or a bad value gets an explanation with a hint:

.. code-block:: text

   $ docodin --report=loud doc.rst
   -- INVALID VALUE ------------------------------------------------------- docodin

   `--report=loud` is not valid.

   Hint: Use one of `info`, `warning`, `error`, `severe`, `none`, `1`, `2`, `3`,
   `4`, `5`.

Messages and exit status
------------------------

The command writes docutils' messages to standard error (or to the file of
``--warnings``) in docutils' format, and exits as ``python -m docutils`` does:

- 0 when all went well;
- 1 when the source cannot be read, the destination cannot be written, or the run
  stopped at a message at or above ``--halt`` (default: severe);
- 10 plus the highest message level, when ``--exit-status=LEVEL`` is given and a message
  reached that level (for example 12 for a warning);
- 2 for an unknown option or an invalid option value.

Configuration files
-------------------

The native command reads no configuration files: ``docutils.conf`` and the other
standard files are ignored.  With ``--config=FILE`` it runs the document through Python
instead (see below), where docutils reads the file and the standard configuration files.

Documents that need Python
--------------------------

When a document needs a Python library (Pygments for ``code`` with a language, PIL for
image formats whose dimensions cannot be read natively, and the other cases in
:doc:`../internals/python-needs`), or when you use
``--config``, ``--record-dependencies`` or a ``--dump-*`` option, the native command runs
``python -m docodin`` with the same arguments, the same standard streams and the same
exit status.  It uses the first Python that can import docodin among
``$DOCODIN_PYTHON``, the ``python3`` or ``python`` in the directory of the ``docodin``
program (the environment the wheel installed it into), and ``python3`` on the ``PATH``.
If there is none, it explains what needs Python and how to avoid it, and exits with
status 1:

.. code-block:: text

   -- NEEDS PYTHON ---------------------------------------------------- guide.rst:4

   Highlighting "python" code needs Pygments.

   docodin runs these with docutils' Python front end (`python -m docodin`), but
   found no Python that imports docodin: it tries `$DOCODIN_PYTHON`, the Python
   next to docodin, then `python3`.

   4| .. code:: python
      ^^^^^^^^^^^^^^^^
   Hint: Install docodin's Python package (`pip install docodin`) or set
   `DOCODIN_PYTHON` to a Python that has it, or write `--syntax-highlight=none` to
   publish the code without highlighting.

PDF
===

.. code-block:: console

   $ docodin pdf doc.rst                     # doc.tex and doc.pdf in the current directory
   $ docodin pdf doc.rst out/manual.pdf
   $ docodin pdf --engine=lualatex --documentclass=report doc.rst

``docodin pdf [--engine=NAME] [options] SOURCE [OUTPUT.pdf]`` writes the LaTeX next to the
PDF and runs the TeX engine twice, so that cross-references and the table of contents
resolve.  The engine is ``pdflatex`` when it is installed, otherwise ``xelatex``;
``--engine`` also accepts ``lualatex`` or a full executable path, such as
``--engine=/usr/bin/lualatex``. The executable's basename selects the writer, so full
paths keep the same Unicode support as engine names. With ``pdflatex`` the ``latex``
writer is used, with ``xelatex`` and ``lualatex`` the ``xetex`` writer. The other options are those of the
LaTeX writers.  The engine is looked up in ``/Library/TeX/texbin``,
``/usr/local/texlive/bin``, ``/usr/bin`` and the ``PATH``.  docodin does not include a TeX
engine: install TeX Live or MacTeX for PDFs.

Books
=====

.. code-block:: console

   $ docodin book build docs                 # HTML site and PDF book in docs/_build
   $ docodin book build docs --html -W -o /tmp/site

``docodin book build`` builds a Sphinx project without Python, from the ``conf.py``
values and the markup subset that :doc:`../development/documentation` describes.  Every
source must be UTF-8: a source that cannot be read or decoded is a SEVERE problem (titled
UNREADABLE SOURCE or SOURCE IS NOT UTF-8), and the build stops with status 1 and writes
nothing.  :doc:`../reference/cli` lists the options.

Sphinx
======

.. code-block:: console

   $ docodin sphinx -b html docs docs/_build/html

``docodin sphinx ARGS...`` runs ``python -m docodin sphinx ARGS...`` with the Python found
as above: ``sphinx-build`` with docutils' parser replaced by docodin's (:doc:`sphinx`).
It needs Sphinx in that Python's environment.

Checking
========

``docodin check FILE...`` reports the markup errors that the parser detects, like
``docodin-check`` but one file after another.  :doc:`checker` covers both.

The Python command
==================

.. code-block:: console

   $ python -m docodin --writer=manpage doc.rst doc.1
   $ python -m docodin rst2odt doc.rst doc.odt
   $ python -m docodin sphinx -b html docs docs/_build/html

The Python front end is ``docutils.core.publish_cmdline`` with ``docodin.Parser``, so it
has every docutils option and writer, including ``manpage``, ``odt``, ``s5``, ``pep`` and
``html4``, and it reads configuration files.  The writer is chosen with ``--writer`` or
a first argument (``html5``, ``latex``, ``rst2man``, ``rst2odt`` and the other ``rst2*``
names); its default is ``html5``, and ``html`` also means ``html5``.  ``python -m
docodin sphinx ARGS...`` runs ``sphinx-build`` with docutils patched to parse with
docodin.

.. note::

   Until 0.2.0 the wheel installed the Python front end as a ``docodin`` command.  Since
   1.0.0b1 the wheel's ``docodin`` is the native program, and the Python front end is
   ``python -m docodin`` only.  The native program hands it everything it does not do
   natively, including ``--writer=NAME`` with a Python-only writer (``manpage``,
   ``odt``, ``s5``, ``pep``, ``html4``) and the ``rst2man``, ``rst2odt`` and ``rst2s5``
   first arguments: ``docodin rst2odt doc.rst doc.odt`` runs ``python -m docodin``.
