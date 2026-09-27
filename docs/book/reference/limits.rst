.. _limits:

============
Known limits
============

docodin aims at no differences from docutils 0.22.4.  This chapter lists every known
difference and every limit of the native tools, so that none of them is a surprise.

Differences from docutils
=========================

Two nested-include cases
   In about 20,000 generated documents, two differ in line numbers.  Both have an
   ``include`` directive two directive levels deep, with more content after it in the
   outer directive.  The output is otherwise the same.

The ``html`` writer name
   In the native ``docodin`` command and in ``python -m docodin``, ``html`` means the
   ``html5`` writer.  In docutils it means ``html4css1``.  Name the writer ``html4`` (with
   the Python command) to get docutils' old HTML writer.

Nesting depth
   The native parser limits nesting to 160 levels (``MAX_NESTING``), and the native math
   converters to 1000 (``MAX_DEPTH``).  Where docutils would fail with Python's
   ``RecursionError``, docodin reports an error message ("Nesting too deep; content
   ignored.") and goes on.

Limits of the native pipeline
=============================

Python extensions
   Directives, roles, transforms and writers registered in Python are not seen by the
   native pipeline.  Publish documents that use them with the docutils package
   (``docodin.publish_string``, ``docutils.core``, Sphinx).

Python libraries
   The native pipeline does not reimplement Pygments, PIL, ``urllib``, Python's codecs,
   parser and writer modules or external MathML converters.  Documents that need them are
   published by docutils automatically (:doc:`../internals/python-needs`).  Without a
   Python that has docodin, the native command reports what needs Python and exits with
   status 1.

Writers
   The native writers are pseudo-XML, XML, HTML5, LaTeX and XeLaTeX.  The manual page,
   ODT, S5, PEP and HTML4 writers are Python only.

Configuration files
   The native ``docodin`` command does not read ``docutils.conf`` or the other standard
   configuration files.  With ``--config`` it runs the document through Python, which
   reads them.

Limits of the checker
=====================

``docodin-check`` reports the parser's messages only.  It does not run directives, roles
or transforms, so it does not report unknown directives or roles, missing include files,
unknown or duplicate targets.  Publish the document, or use ``docodin-lsp``, for those.

Limits of the language server
=============================

- It works on one file at a time: cross-document ``:ref:`` and ``:doc:`` are not
  resolved.
- Included files are read from disk.
- Unknown languages of ``code`` directives are not reported (docutils asks Pygments).
- Sphinx's roles and directives, and those of extensions, are unknown to docutils; the
  ``sphinx``, ``knownRoles`` and ``knownDirectives`` settings silence those messages.
- There is no rename.

Limits of source spans
======================

Nodes built from lines that ``include`` inserted are not in the input; they get an empty
span at the end of the inserting directive.  Table entries of one row, and rows with
cells spanning several rows, may overlap.

The garbage-collector tuning
============================

``DOCODIN_GC=tuned`` and ``docodin_gc_tuning = True`` can change the output of Sphinx
projects that have duplicate labels or repeated generated ids, with docutils as with
docodin.  It is therefore off by default (:doc:`../guide/sphinx`).
