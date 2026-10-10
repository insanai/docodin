.. _architecture:

============
Architecture
============

docodin replaces docutils 0.22 in two ways:

- **Inside Python.**  ``python/docodin/shim/docutils`` is a complete docutils package:
  nodes, frontend, io, readers, parser, directives, roles, transforms, writers and
  utilities.  It is served under the name ``docutils``, so Sphinx and its extensions run
  on it without changes, within the bounds of :doc:`../reference/limits`.  Its
  reStructuredText parser is docodin's native engine.
- **Without Python.**  A native Odin pipeline (reader, transforms, writers) publishes
  documents byte for byte like docutils.  It powers the ``docodin`` command and its
  book builder, ``docodin-check``, ``docodin-lsp`` and ``docodin.publish_native``.  Where docutils
  would use a Python library, the pipeline reports that the document needs Python, and
  the tools publish it with docutils instead.

The picture
===========

.. graphviz::
   :class: adaptive-diagram
   :align: center
   :caption: One parser feeds two toolchains; the Sphinx path still builds and processes Python nodes.
   :alt: The Odin parser feeds the native reader, transforms and writers, or a marshal bridge into Python nodes and Sphinx.

   digraph architecture {
   newrank=true;
   graph [bgcolor="white", pad="0.28", nodesep="0.4", ranksep="0.6", fontname="Helvetica", fontsize=17, fontcolor="#425574", color="#CBD5E1"];
   node [shape=box, style="rounded,filled", fontname="Helvetica", fontsize=16, margin="0.22,0.16", fillcolor="#EFF4FF", color="#B3C6F7", fontcolor="#18243D", penwidth=1.2];
   edge [fontname="Helvetica", fontsize=12, color="#526B97", fontcolor="#425574", arrowsize=0.75, penwidth=1.4];
   rankdir=TB;
   source [label="reStructuredText source", fillcolor="#F4F6FA", color="#CDD5E2"];
   parser [label="Odin parser\nodin/rst\nFlat parse tree + messages", fillcolor="#DBE7FF", color="#7DA1ED"];
   source -> parser;
   subgraph cluster_native {
     label="NATIVE TOOLCHAIN"; style="rounded"; bgcolor="#F7FAFF";
     reader [label="Native reader\ndoctree + registry" ];
     transform [label="Native transforms\nReferences, contents, validation"];
     writer [label="Native writers\nHTML, LaTeX, XML"];
     native_out [label="Native output\nHTML / PDF / XML", fillcolor="#E5F5EE", color="#8DC9B0"];
     reader -> transform -> writer -> native_out;
   }
   subgraph cluster_python {
     label="PYTHON / SPHINX"; style="rounded"; bgcolor="#FAF8FF";
     wire [label="C ABI / marshal\nNative result buffer", fillcolor="#EEE9FB", color="#C0AEE7"];
     builder [label="Python builder\nOrdinary docutils nodes", fillcolor="#EEE9FB", color="#C0AEE7"];
     sphinx [label="Python transforms + writers\nSphinx and extensions", fillcolor="#EEE9FB", color="#C0AEE7"];
     python_out [label="Sphinx outputs\nWithin measured support", fillcolor="#E5F5EE", color="#8DC9B0"];
     wire -> builder -> sphinx -> python_out;
   }
   parser -> reader [label="Odin API"];
   parser -> wire [label="C ABI"];
   {rank=same; reader; wire;}
   {rank=same; transform; builder;}
   {rank=same; writer; sphinx;}
   {rank=same; native_out; python_out;}
   }

The left side is the Python path: the native parser feeds docodin's docutils package,
where everything else is docutils' Python code (and Sphinx's, and the extensions').  The
right side is the native path: the same parser feeds the native reader, transforms and
writers.  Both are held to docutils' results.

Odin packages
=============

.. list-table::
   :header-rows: 1
   :widths: 22 78

   * - Package
     - Contents
   * - ``odin/rst``
     - The parser.  ``nodes.odin`` is the data-oriented parse tree: ``Node`` handles into
       a ``Tree`` with an ``#soa`` node array and side tables for directive and
       phrase-reference data.  The package also holds the state machine
       (``statemachine.odin``), the body, list, explicit-markup and table states, the
       inliner, hand-written matchers for docutils' regular expressions
       (``patterns.odin``), the SIMD scanners (``scan.odin``), source spans
       (``spans.odin``), the line index (``line_index.odin``) and generated
       Python-compatible character classes.
   * - ``odin/check``
     - The checker core: collects parser messages, including those inside the
       reStructuredText content of standard directives, and renders them in the Elm
       style (excerpt, markers, hint) or in docutils' format.
   * - ``odin/doctree``
     - The docutils document tree: ``Node`` handles into an ``#soa`` element array,
       interned strings, attribute side tables, the complete ``document`` registry, the
       reporter, settings, pseudo-XML, validation, Python needs, and the JSON interchange
       with docutils.
   * - ``odin/reader``
     - ``Parser.parse`` into a ``doctree.Doc``: a port of ``builder.py`` (registration,
       sections, include handling) with the complete standard directive and role set and
       docutils' language tables.
   * - ``odin/transforms``
     - The transformer (priority queue, docutils' ordering rules) and every standard
       transform: universal, references, frontmatter, parts, misc, writer_aux,
       components, peps.
   * - ``odin/writers``
     - The pseudoxml, xml, html5, latex and xetex writers with their parts.  They use
       output buffers, dispatch tables indexed by ``doctree.Tag``, and docutils'
       templates and stylesheets embedded with ``#load``.
   * - ``odin/math`` (``texmath``)
     - ``math2html`` and ``latex2mathml``, with docutils' exact output, trace messages
       and errors.
   * - ``odin/text``
     - Smart quotes (``educate_tokens``), every language and attribute mode.
   * - ``odin/publish``
     - ``publish``: settings with docutils' validators, reader, transforms, writer,
       reporter and halting, the exit status of ``publish_cmdline``, and the Python needs
       of the document.  ``read_document`` stops before the writer and returns the
       document and its messages as records.
   * - ``odin/lib``
     - The C ABI for Python: ``docodin_parse`` (with an include callback),
       ``docodin_parse_inline``, ``docodin_split_lines``, ``docodin_educate``,
       ``docodin_publish``, ``docodin_free``, and the version and initialisation
       functions.  Results use CPython's ``marshal`` format.
   * - ``odin/lsp``
     - The language server.
   * - ``cmd/docodin``
     - The native ``docodin`` command (docutils' front-end options, ``check``, ``pdf``),
       which runs documents that need Python through ``python -m docodin``.
   * - ``cmd/docodin-check``
     - The parallel checker.
   * - ``cmd/docodin-lsp``
     - The language server's entry point.

The Python package
==================

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Module
     - Contents
   * - ``docodin``
     - The public API: publishing functions, ``Parser``, ``patch_docutils``,
       ``publish_native``, ``render_html``, ``render_latex``.
   * - ``docodin._native``
     - Loads the library with ``ctypes`` and decodes its results (the wire).
   * - ``docodin.builder``
     - Builds ``docutils.nodes`` from the parse result: registration, section nesting,
       ``document.current_line``, and the calls into Python directives and roles.
   * - ``docodin._machine``
     - State and state-machine objects that subclass docutils' classes, on which
       directives and roles run; ``nested_parse`` and friends return to the native
       engine.
   * - ``docodin._include``
     - The include callback: docutils' ``Include`` run dry when the parser meets it.
   * - ``docodin._publish``
     - ``publish_native`` and its fallback to docutils.
   * - ``docodin.parser``
     - ``Parser`` and ``patch_docutils``.
   * - ``docodin.shim``
     - The import hook; ``docodin.shim.docutils`` is the docutils package.
   * - ``docodin.sphinx``, ``docodin.sphinx_build``
     - The Sphinx extension and ``docodin-sphinx-build``.
   * - ``docodin.conf``
     - Reading a Sphinx ``conf.py`` without Sphinx.
   * - ``docodin_autoload`` (top level)
     - The start-up hook imported by ``docodin.pth``.

From Python to Odin and back
============================

When Sphinx parses a document on the Python path:

1. Sphinx calls ``Parser.parse`` of docodin's docutils package (or of the
   ``docodin.sphinx`` parser).
2. ``docodin.builder`` checks that the grammar is the stock one (otherwise the
   pure-Python parser takes over) and calls ``docodin_parse`` with the text and the
   parser settings.
3. The native parser builds its parse tree in a per-thread arena.  When it meets an
   ``include``, it calls back into Python, where docutils' ``Include`` directive runs dry
   to resolve the path and read the file; the lines are parsed in place.
4. The parse tree is serialised in ``marshal`` format into the arena, and Python decodes
   it with ``marshal.loads`` directly from the native buffer (large results item by
   item).
5. ``builder.py`` creates the ``docutils.nodes`` objects, registers targets, nests
   sections, and runs directives and roles, which are Python code.  A directive that
   parses its content (``nested_parse``) goes back to step 2 for that content.
6. Sphinx applies its transforms and writers, which are Python code working on ordinary
   docutils nodes.

The C ABI is versioned (``docodin_abi_version``), and so is the wire format.  The
library's only shared mutable state is a locked cache of arena blocks (:doc:`storage`),
so it can be called from several threads at once.

Where to read next
==================

- :doc:`parser` for the native parser.
- :doc:`storage` for the data-oriented trees and arenas.
- :doc:`shim` and :doc:`fallback-parser` for the Python side.
- :doc:`pipeline` for the native reader, transforms and publisher.
