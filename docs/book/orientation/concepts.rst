.. _concepts:

========
Concepts
========

docodin follows docutils' model of a document, so most of its vocabulary is docutils'
vocabulary.  This chapter explains that model briefly, then the words docodin adds.
:doc:`../appendices/glossary` has short definitions of all of them.

How docutils publishes a document
=================================

docutils turns reStructuredText into output in four steps, run by a *publisher*:

.. code-block:: text

   source text --reader + parser--> document tree --transforms--> document tree
               --writer--> output (HTML, LaTeX, XML, ...)

The reader and the parser
   The *standalone reader* reads the source and hands it to the reStructuredText
   *parser*, which builds a *document tree*: a tree of nodes such as ``section``,
   ``paragraph``, ``emphasis`` and ``reference``.  The parser runs *directives* (block
   extensions such as ``image`` or ``code``) and *roles* (inline extensions such as
   ``:math:``) as it goes.

Transforms
   *Transforms* then change the tree: they resolve references, number footnotes, apply
   substitutions, turn the first field list into bibliographic data, educate quotes, and
   more.  Each has a priority, and the *transformer* applies them in priority order.

The writer
   A *writer* walks the finished tree and produces the output.  ``publish_parts``
   returns the output split into named parts (``body``, ``title``, ``whole`` and
   others).

Settings
   Everything is configured by *settings*, for example ``report_level``,
   ``syntax_highlight`` or ``stylesheet_path``, which come from defaults, configuration
   files, the command line or ``settings_overrides``.

System messages
   Problems become *system messages* with a level: 0 debug, 1 info, 2 warning, 3 error,
   4 severe.  Messages at or above ``report_level`` are written to the warning stream;
   one at or above ``halt_level`` stops the run; the exit status of the command line
   tools follows ``exit_status_level``.

Every node records its ``source`` and ``line``.  Tools such as Sphinx use them to point
at the right place in a warning, which is why docodin must reproduce them exactly.

What docodin adds
=================

The docutils path
   Everything that produces docutils' results: the docutils package inside Python, and
   the native pipeline.  docodin's rule is that the docutils path is identical to
   docutils 0.22.4 (DOD 3).

The native engine
   The reStructuredText parser in Odin (``odin/rst``).  It builds a *parse tree*, a
   compact, data-oriented tree from which a docutils document tree is built.

The shim
   docodin's docutils package (``python/docodin/shim/docutils``).  The word comes from
   its role: it sits where docutils would be.  It is a complete implementation, not a
   thin layer.

Activation
   How a Python process comes to use the shim instead of an installed docutils:
   ``docodin-sphinx-build``, ``DOCODIN_DOCUTILS=1``, the fallback when docutils is not
   installed, or ``install_shim(force=True)`` (:doc:`../guide/installation`).

The wire
   The ``marshal`` buffer in which the native engine hands a parse result to Python.
   ``marshal.loads`` decodes it in C.

The fallback parser
   A pure-Python copy of docutils' state machine inside the shim.  docodin uses it for
   documents whose grammar an extension changed, because the native engine cannot see
   changes made in Python (DOD 7).

The native pipeline
   A port of docutils' reader, transforms and writers to Odin (``odin/reader``,
   ``odin/transforms``, ``odin/writers``, ``odin/publish``).  It publishes without Python
   and powers the ``docodin`` command and ``docodin.publish_native``.

Python needs
   Places where docutils would call a Python library, such as Pygments for highlighted
   code.  The native pipeline records them, and the tools then publish the document with
   docutils instead (DOD 9).

Elm-style reports
   docodin's own way of explaining a problem: a titled report with a source excerpt,
   markers and a hint (DOD 5).  The docutils path keeps docutils' messages.

Spans and the line index
   The byte range of the source that each parse node came from, and the conversion of
   byte offsets to editor positions (DOD 13).  They serve the language server.

DOD
   A DocOdin Discussion: a numbered design record in ``docs/dod``.

Two ways to run docodin
=======================

.. list-table::
   :header-rows: 1
   :widths: 20 40 40

   * -
     - Inside Python
     - Without Python
   * - What runs
     - the shim: docutils' Python code, with the native parser
     - the native pipeline: reader, transforms and writers in Odin
   * - Entry points
     - ``import docutils``, ``docodin-sphinx-build``, ``docodin.publish_string``
     - ``docodin``, ``docodin-check``, ``docodin-lsp``, ``docodin.publish_native``
   * - Extensions
     - every Python directive, role, transform and writer works
     - the standard directives, roles and transforms; the pseudo-XML, XML, HTML5, LaTeX
       and XeLaTeX writers
   * - Python libraries
     - used as docutils uses them
     - the document is handed to docutils

Both give docutils' results.  Use the Python side for Sphinx and for anything with
extensions; use the native side for fast publishing, checking and editing of plain
reStructuredText.
