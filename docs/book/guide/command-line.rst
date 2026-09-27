.. _command-line:

=====================
The command line
=====================

docodin has two ``docodin`` commands.  The **native** one, ``bin/docodin`` built by
``scripts/build_odin.sh``, publishes without Python.  The **Python** one, installed by the
wheel and also available as ``python -m docodin``, is docutils' front end with docodin's
parser.  Both take docutils' options and write docutils' output.  This chapter is about
using them; :doc:`../reference/cli` lists every option.

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

   $ ln -s "$PWD/bin/docodin" ~/.local/bin/rst2xetex
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
scaled images, and the other cases in :doc:`../internals/python-needs`), or when you use
``--config``, ``--record-dependencies`` or a ``--dump-*`` option, the native command runs
``python -m docodin`` with the same arguments, the same standard streams and the same
exit status.  It uses ``$DOCODIN_PYTHON`` if that is set, else ``python3`` from the
``PATH``, provided it can import docodin.  If no such Python exists, it explains what
needs Python and how to avoid it, and exits with status 1:

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

PDF
===

.. code-block:: console

   $ docodin pdf doc.rst                     # doc.tex and doc.pdf in the current directory
   $ docodin pdf doc.rst out/manual.pdf
   $ docodin pdf --engine=lualatex --documentclass=report doc.rst

``docodin pdf [--engine=NAME] [options] SOURCE [OUTPUT.pdf]`` writes the LaTeX next to the
PDF and runs the TeX engine twice, so that cross-references and the table of contents
resolve.  The engine is ``pdflatex`` when it is installed, otherwise ``xelatex``;
``--engine`` also accepts ``lualatex``.  With ``pdflatex`` the ``latex`` writer is used,
with ``xelatex`` and ``lualatex`` the ``xetex`` writer.  The other options are those of the
LaTeX writers.  The engine is looked up in ``/Library/TeX/texbin``,
``/usr/local/texlive/bin``, ``/usr/bin`` and the ``PATH``.

Checking
========

``docodin check FILE...`` reports the markup errors that the parser detects, like
``docodin-check`` but one file after another.  :doc:`checker` covers both.

The Python command
==================

.. code-block:: console

   $ docodin doc.rst doc.html                 # the wheel's command
   $ python -m docodin --writer=manpage doc.rst doc.1
   $ python -m docodin rst2odt doc.rst doc.odt
   $ python -m docodin sphinx -b html docs docs/_build/html

The Python front end is ``docutils.core.publish_cmdline`` with ``docodin.Parser``, so it
has every docutils option and writer, including ``manpage``, ``odt``, ``s5``, ``pep`` and
``html4``, and it reads configuration files.  The writer is chosen with ``--writer`` or
a first argument (``html5``, ``latex``, ``rst2man``, ``rst2odt`` and the other ``rst2*``
names); its default is ``html5``, and ``html`` also means ``html5``.  ``docodin sphinx
ARGS...`` runs ``sphinx-build`` with docutils patched to parse with docodin.

.. note::

   When the wheel is installed and the native tools are on your ``PATH`` too, make sure
   that ``docodin`` names the one you mean.  The native command lives in the checkout's
   ``bin`` directory; the Python one in the environment's ``bin`` directory.
