==============================================================================
DOD 18: The Documentation System
==============================================================================

:Authors: Vikrant Rathore
:State: committed
:Created: 2026-09-27
:Updated: 2026-10-11
:Discussion:
:Labels: documentation, tooling, process

.. contents:: Contents
   :local:
   :depth: 1

Summary
=======

docodin documents itself in reStructuredText only, and builds its documentation with
itself.  There are two Sphinx projects: *The docodin Book* (``docs/book``), a manual in
parts with a PDF edition, and the DocOdin Discussions (``docs/dod``), the design records.
Both build with Sphinx and furo, and natively with ``docodin book build``, to HTML with a
furo-inspired docodin theme and to a PDF book.  ``docodin dod`` manages the records.  All
Markdown and Typst files were converted and removed.

Background
==========

Before 0.2.0's documentation work the repository had a Markdown README and changelog,
three Markdown design documents (architecture, native pipeline, the 0.2.0 memo), a
Markdown copy of the first specification, and the same specification in Typst with its
own theme.  None of it could be checked or built by docodin, and nothing said which
documents described the current design.

Proposal
========

Layout
------

.. graphviz::
   :class: adaptive-diagram
   :align: center
   :caption: Graphviz renders the diagrams; docodin publishes the surrounding documentation and PDF downloads.
   :alt: Inline DOT is rendered to SVG or vector PDF and combined with reStructuredText by docodin into themed HTML, both collected PDFs and each individual DOD PDF.

   digraph documentation_flow {
   graph [bgcolor="white", pad="0.28", nodesep="0.4", ranksep="0.6", fontname="Helvetica", fontsize=17, fontcolor="#425574", color="#CBD5E1"];
   node [shape=box, style="rounded,filled", fontname="Helvetica", fontsize=16, margin="0.22,0.16", fillcolor="#EFF4FF", color="#B3C6F7", fontcolor="#18243D", penwidth=1.2];
   edge [fontname="Helvetica", fontsize=12, color="#526B97", fontcolor="#425574", arrowsize=0.75, penwidth=1.4];
   rankdir=TB;
   rst [label="reStructuredText source\nBook + DODs", fillcolor="#F4F6FA", color="#CDD5E2"];
   dot [label="Inline graphviz directive\nDOT beside the explanation"];
   renderer [label="Graphviz dot\nSVG / vector PDF"];
   publisher [label="docodin native builder\nReader, transforms, writers", fillcolor="#DBE7FF", color="#7DA1ED"];
   html [label="HTML\nLight / dark theme"];
   book [label="Book + collected DOD PDF\nLight layout"];
   records [label="Individual DOD PDFs\nLight layout"];
   site [label="GitHub Pages\nHTML + PDF download links", fillcolor="#E5F5EE", color="#8DC9B0"];
   release [label="GitHub release\nPDFs match the source tag", fillcolor="#E5F5EE", color="#8DC9B0"];
   rst -> dot -> renderer -> publisher;
   rst -> publisher [label="text + structure"];
   publisher -> html;
   publisher -> book;
   publisher -> records;
   {rank=same; html; book; records;}
   html -> site;
   book -> site;
   records -> site;
   book -> release;
   records -> release;
   }


.. code-block:: text

   README.rst            the front page: what docodin is, install, a first command, links
   CHANGELOG.rst         what changed in each release
   docs/README.rst       how to build the documentation
   docs/book/            The docodin Book (a Sphinx project)
     conf.py, index.rst  the parts, in toctrees
     orientation/ guide/ reference/ internals/ development/ appendices/
     _static/            images
   docs/dod/             the DocOdin Discussions (a Sphinx project)
     conf.py, index.rst  all records (a glob toctree) and the "By state" index
     0000-template.rst   the template, excluded from builds
     NNNN-slug.rst       the records
   docs/theme/           the docodin theme, shared by both projects

The book
--------

The book is organised in parts by reader: Orientation (what docodin is, concepts, a
quick start), Using docodin (installation, Sphinx, the Python API, the command line, the
checker, editors), Reference (compatibility, the command-line options, environment
variables, the Python API, settings, limits), Internals (architecture, the parser,
storage, spans, the shim, the fallback parser, the pipeline, writers, math, smart quotes,
the language server, memory, performance) and Development (building, testing, fuzzing,
code rules, the DOD process, maintaining the book), followed by appendices (glossary,
FAQ, changelog, maintenance checklist).  The PDF has a title page, part pages and styled
chapters.

The records
-----------

The format and process are DOD 1.  ``index.rst`` lists every record through a
``:glob:`` toctree and has a "By state" section between the comments
``.. dod-index-start`` and ``.. dod-index-end``, which ``docodin dod index``
regenerates: a rubric for each state that has records, followed by a bullet list of
``:doc:`` references to its records in number order.

The markup subset
-----------------

The documents use only markup that both Sphinx and the native builder handle: every
docutils standard directive and role; Sphinx's ``toctree``, ``code-block``,
``literalinclude``, ``highlight``, ``glossary``, ``seealso``, ``versionadded``,
``versionchanged``, ``deprecated``, ``only``, ``index``, ``centered`` and ``hlist``; the
roles ``doc``, ``ref``, ``term``, ``abbr``, ``file``, ``command``, ``program``,
``envvar``, ``kbd``, ``guilabel``, ``samp``, ``numref`` and ``download``; labels; math.
No Sphinx extensions beyond the built-in ones and no MyST. Inline Graphviz DOT diagrams
now explain architecture and workflows: Sphinx uses ``sphinx.ext.graphviz``, while the
native builder invokes ``dot`` directly, producing SVG for HTML and vector PDF for TeX.
The DOT stays in the reStructuredText source. Standalone DOD PDFs enable Graphviz
explicitly with ``docodin pdf --graphviz``.

Configuration
-------------

``conf.py`` is valid Sphinx configuration.  The native builder reads its simple
module-level assignments: ``project``, ``author``, ``copyright``, ``version``,
``release``, ``html_title``, ``language``, ``root_doc`` (or ``master_doc``),
``exclude_patterns``, ``numfig``, ``today_fmt``, and three values of its own:
``docodin_tagline``, ``docodin_part_labels`` and ``docodin_pdf_filename``.  Sphinx reads
the rest: ``html_theme = "furo"`` with ``docodin.css`` from ``docs/theme``, and a LaTeX
book look for lualatex in ``latex_elements``.

The native commands
-------------------

.. code-block:: text

   docodin book build [DIR] [-o OUTDIR] [--html] [--pdf] [--engine=lualatex|xelatex]
   docodin dod new "Title" [--number N] [--labels a,b] [--dir docs/dod]
   docodin dod list [--state S] [--label L] [--dir docs/dod]
   docodin dod index [--dir docs/dod]
   docodin dod check [--dir docs/dod]

``docodin book build`` builds a Sphinx-style project: an HTML site with the docodin
theme (navigation from the toctrees, page contents, light and dark modes, client-side
search, previous and next links, part and chapter numbering) and a PDF book (one LaTeX
document in toctree order through the native LaTeX writer, with a title page, part pages
and styled chapters, run through the TeX engine twice).  Warnings come in docutils'
format or the Elm style.

Conversion
----------

- ``README.md`` became ``README.rst`` (a short front page) and ``CHANGELOG.md`` became
  ``CHANGELOG.rst``; ``pyproject.toml`` names ``README.rst``.
- ``docs/ARCHITECTURE.md`` and ``docs/NATIVE_PIPELINE.md`` became the book's Internals
  part and DOD 3 to DOD 9.
- ``docs/design/0.2.0.md`` became DOD 12, with DOD 13 to DOD 17 for its outcomes.
- The Typst specification (``docs/sds``, ``docs/shared``) and its Markdown copy became
  DOD 2.
- Every Markdown and Typst file was removed.

Alternatives
============

- **Sphinx only.**  Simple, but docodin would not use its own engine for its own
  documentation, and a Python environment would be needed to read the manual as a PDF.
- **Native only.**  The Sphinx build is the reference that the native builder is
  compared with, and many readers know furo's look.
- **Keep Markdown for the README.**  Package indexes render reStructuredText READMEs, and
  one markup language is simpler.

Compatibility and fidelity
==========================

No code on the docutils path changes.  The new commands are part of the native
``docodin`` command only.

Verification
============

- ``sphinx-build -W --keep-going -b html`` for both projects, and ``-b latex`` followed by
  ``latexmk -lualatex`` for both PDFs.
- ``docodin book build`` for both projects, with no warnings.
- ``docodin-check`` reports no warnings for any ``.rst`` file.
- ``docodin dod check`` passes.

Decision
========

Accepted.  The content (the book, the records, the README and changelog) and the Sphinx
builds are done; the state moves to ``committed`` when the native ``docodin book`` and
``docodin dod`` commands are merged.

References
==========

- DOD 1 (the process), ``docs/README.rst``.
- The book's chapter on maintaining the documentation.
