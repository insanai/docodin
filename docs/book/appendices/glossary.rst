.. _glossary:

========
Glossary
========

.. glossary::
   :sorted:

   activation
      How a Python process comes to use docodin's docutils package instead of an
      installed docutils: ``docodin-sphinx-build``, ``DOCODIN_DOCUTILS=1``, the fallback
      when docutils is missing, or ``docodin.shim.install_shim(force=True)``.

   arena
      A region of memory from which many objects are allocated and then released
      together.  docodin allocates each parse, document and write from one arena.

   bump arena
      An arena that allocates by advancing a pointer through a block.  The C ABI uses a
      per-thread bump arena (``odin/lib/bump.odin``).

   C ABI
      The C functions that the native library exports to Python: ``docodin_parse``,
      ``docodin_publish``, ``docodin_educate`` and others.

   candidate scanner
      The part of the inliner that jumps from one byte that can start inline markup to
      the next, sixteen bytes at a time.

   directive
      An explicit markup block of the form ``.. name:: arguments``, such as ``image``,
      ``code`` or ``note``.  docutils and Sphinx implement directives in Python; the
      native reader implements the standard ones in Odin.

   docutils path
      Everything in docodin that produces docutils' results: the docutils package inside
      Python and the native pipeline.  It is held identical to docutils 0.22.4.

   document tree
      docutils' tree of nodes (``document``, ``section``, ``paragraph``, ...) that the
      parser builds, the transforms change and the writers write.  Also called the
      doctree.

   DOD
      A DocOdin Discussion: a numbered design record in ``docs/dod``.  (Data-oriented
      design is always written out in full in this book.)

   data-oriented design
      Designing code around the layout of its data: flat arrays, handles instead of
      pointers, struct-of-arrays storage, arenas.

   Elm-style report
      docodin's format for explaining a problem: a titled header, the source excerpt with
      markers, the message, and a hint.

   fallback parser
      The pure-Python reStructuredText parser in docodin's docutils package, used when an
      extension changes the grammar or with ``DOCODIN_NATIVE=0``.

   fidelity
      Producing exactly what docutils produces: tree, messages, positions, output, exit
      status.

   handle
      A ``distinct u32`` index into a tree's arrays that stands for a node; ``0`` is the
      null handle.

   import hook
      The meta-path finder in ``docodin.shim`` that serves ``docutils`` and its submodules
      from docodin's package.

   include hook
      The callback through which the native parser lets its host run an ``include``
      directive dry and insert the included lines.

   interchange
      The JSON format in which ``scripts/doctree_json.py`` dumps docutils' document tree,
      registry, transformer, reporter and settings, and which ``odin/doctree`` loads and
      dumps back.

   line index
      ``rst.Line_Index``: converts byte offsets to and from line and column positions in
      UTF-16, UTF-8 or UTF-32.

   line table
      The byte offset where each ``string2lines`` line starts in the input, recorded by
      every parse.

   LSP
      The Language Server Protocol, which editors use to talk to language servers such as
      ``docodin-lsp``.

   native pipeline
      The Odin port of docutils' reader, transforms and writers, driven by
      ``publish.publish``.

   parse tree
      The native parser's data-oriented tree (``rst.Tree``), from which a docutils
      document tree is built.

   Python need
      A place where docutils would use a Python library (Pygments, PIL, ...).  The native
      pipeline records it, and the tools publish the document with docutils.

   role
      Inline markup of the form ``:name:`text```, such as ``:math:`` or ``:ref:``.

   settings
      docutils' configuration values, such as ``report_level`` or ``syntax_highlight``,
      given on the command line, in configuration files or as ``settings_overrides``.

   shim
      docodin's implementation of the docutils package, in
      ``python/docodin/shim/docutils``.  A complete package, despite the name.

   span
      The half-open byte range of the input that a parse node was parsed from.

   struct of arrays
      Storing each field of a record type in its own array (Odin's ``#soa``), so that a
      traversal reads only the fields it needs.

   system message
      docutils' representation of a problem, with a level: debug (0), info (1), warning
      (2), error (3) or severe (4).

   transform
      A step that changes the document tree after parsing, such as resolving references
      or numbering footnotes.  Transforms run in priority order.

   wire
      The ``marshal`` buffer in which the native parser hands a parse result to Python.

   writer
      The component that turns a document tree into output: HTML5, LaTeX, XML and others.
