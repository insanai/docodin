.. _documentation:

==============================
Maintaining the documentation
==============================

docodin documents itself in reStructuredText only, and builds its documentation with
itself (DOD 18).  This chapter explains the two documentation projects, how to build
them, the markup they may use, and the conventions of this book.

The projects
============

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
   rst -> dot -> renderer -> publisher;
   rst -> publisher [label="text + structure"];
   publisher -> html;
   publisher -> book;
   publisher -> records;
   {rank=same; html; book; records;}
   html -> site;
   book -> site;
   records -> site;
   }


.. code-block:: text

   README.rst            the front page: what docodin is, how to install, links
   CHANGELOG.rst         what changed in each release (included in the book)
   docs/README.rst       how to build the documentation
   docs/book/            The docodin Book
     conf.py, index.rst  the parts, as toctrees under top-level sections
     orientation/ guide/ reference/ internals/ development/ appendices/
     _static/            images
   docs/dod/             the DocOdin Discussions
     conf.py, index.rst  every record (a glob toctree) and the "By state" index
     0000-template.rst   the template (excluded from the builds)
     NNNN-slug.rst       the records
   docs/theme/           the docodin theme, shared by both projects

There is no Markdown in the repository.

Building
========

Natively, with docodin:

.. code-block:: console

   $ bin/docodin book build docs/book            # HTML and PDF
   $ bin/docodin book build docs/dod --html
   $ bin/docodin book build docs/book --pdf --engine=xelatex -o /tmp/book

With Sphinx, in the ``docs`` dependency group (Sphinx and furo):

.. code-block:: console

   $ uv run --group docs sphinx-build -W --keep-going -b html docs/book docs/book/_build/html
   $ uv run --group docs sphinx-build -W --keep-going -b latex docs/book docs/book/_build/latex
   $ (cd docs/book/_build/latex && latexmk -lualatex -interaction=nonstopmode docodin-book.tex)

The same commands build ``docs/dod``; its LaTeX file is ``docodin-dod.tex``.  Both
builders must succeed without warnings.  ``_build`` directories are not versioned.

The native PDF uses Source Serif 4, Source Sans 3 and Source Code Pro
(``docs/theme/book.tex``).  A current TeX Live or MacTeX includes these fonts.  Older
distribution packages can contain only Source Serif Pro and Source Sans Pro; those names
do not satisfy the native template.  Install the current CTAN ``sourceserif`` and
``sourcesans`` OpenType fonts into ``~/texmf/fonts/opentype``, then run ``mktexlsr ~/texmf``
and ``luaotfload-tool --update``.  Check them with ``kpsewhich SourceSerif4-Regular.otf``,
``kpsewhich SourceSans3-Regular.otf`` and ``kpsewhich SourceCodePro-Regular.otf``.

The Sphinx PDF uses TeX Gyre Pagella, Fira Sans and DejaVu Sans Mono.  Books containing
SVG images also need ``rsvg-convert`` (``librsvg2-bin`` on Debian) or Inkscape to convert
them to PDF.

The markup subset
=================

Both projects are built by Sphinx and by docodin's native builder, so they use only markup
that both understand:

- every docutils directive and role: admonitions, ``topic``, ``sidebar``, ``rubric``,
  ``epigraph``, ``compound``, ``container``, ``contents``, ``sectnum``, ``image``,
  ``figure``, ``table``, ``csv-table``, ``list-table``, ``math``, ``include``,
  ``class``, ``role``, ``default-role``, ``title``, ``meta``, ``parsed-literal``,
  ``line-block``, ``code``;
- from Sphinx, the directives ``toctree`` (``:maxdepth:``, ``:caption:``,
  ``:numbered:``, ``:hidden:``, ``:glob:``, ``:titlesonly:``, ``:name:``),
  ``code-block`` (``:caption:``, ``:linenos:``, ``:emphasize-lines:``, ``:name:``),
  ``literalinclude``, ``highlight``, ``glossary``, ``seealso``, ``versionadded``,
  ``versionchanged``, ``deprecated``, ``only`` (``html`` and ``latex``), ``index``,
  ``centered`` and ``hlist``;
- from Sphinx, the roles ``doc``, ``ref``, ``term``, ``abbr``, ``file``, ``command``,
  ``program``, ``envvar``, ``kbd``, ``guilabel``, ``samp``, ``numref`` (figures and
  tables) and ``download``;
- labels (``.. _label:``) before sections and figures, referenced with ``:ref:``;
- math with ``:math:`` and ``.. math::``.

Use inline ``graphviz``, ``graph`` or ``digraph`` directives for architecture, flow and
sequence diagrams. Sphinx loads ``sphinx.ext.graphviz``; the native book builder handles
the same inline DOT without Sphinx. Both need Graphviz's ``dot`` program. HTML uses SVG
and the light PDFs use vector PDF diagrams. The native subset supports ``:alt:``,
``:caption:``, ``:align:``, ``:name:`` and ``:class:``; external DOT files and custom
layout engines are outside this subset. Standalone publication enables these directives
explicitly with ``docodin --graphviz`` or ``docodin pdf --graphviz``.

Keep DOT beside the text it explains, with descriptive alternative text and a caption.
Use short labels, blue for native stages, purple for Python work, green for results and
amber for review or fallback. Add ``:class: adaptive-diagram`` to use this book's
palette. The native builder renders separate light and dark SVGs, selected by the
HTML theme switch or the system theme. PDFs always embed the light vector diagram.

Not allowed: MyST, third-party Sphinx extensions, the ``raw`` directive (except where
nothing else works, and then for HTML only), and Sphinx's domain directives
(``py:function``, ``option``, ``envvar`` and so on).

Code blocks
-----------

Use ``code-block`` with a language Pygments knows: ``console`` for shell sessions,
``python``, ``rst``, ``lua``, ``ts``, ``toml``, ``json``, ``yaml``.  Write Odin code and
ASCII diagrams as ``text``: Pygments has no Odin lexer (its ``odin`` lexer is for another
language).  Keep literal lines within 88 characters, so that they fit the PDF's text
width.

Writing style
=============

- Plain technical English, in short sentences.  Say what docodin does, not what it
  "allows" or "enables".
- Every claim is checked against the code.  Numbers come from the changelog or from a
  measurement whose machine and command are stated.
- Name files, commands, settings and options in inline literals: ``odin/rst``,
  ``docodin-check``, ``report_level``, ``--report``.
- Refer to design records as "DOD n".  The book explains how docodin works; the records
  explain why.
- Link chapters with ``:doc:``; add a label only where a section is linked from
  elsewhere.
- Keep the source lines within 99 characters.

The conf.py files
=================

``conf.py`` is valid Sphinx configuration, and docodin's builder reads its simple
module-level assignments (:doc:`../reference/settings`): ``project``, ``author``,
``copyright``, ``version``, ``release``, ``html_title``, ``language``, ``root_doc``,
``exclude_patterns``, ``numfig``, ``today_fmt``, ``docodin_tagline``,
``docodin_part_labels`` and ``docodin_pdf_filename``.  Keep these as plain literals.
Everything else is Sphinx's: the furo theme with ``docs/theme/docodin.css``
(``html_static_path = ["../theme", "_static"]``), and the LaTeX book design in
``latex_elements`` (title page, part pages, chapter headings, running heads and colours).

Organisation of the book
========================

The book is organised in parts by reader:

- **Orientation**: what docodin is, the concepts, a quick start.
- **Using docodin**: tasks, one chapter per way of using docodin.
- **Reference**: complete and exact lists: commands, options, settings, environment
  variables, the Python API, compatibility, limits.
- **Internals**: how docodin works.
- **Development**: how to build, test, change and release docodin.
- **Appendices**: glossary, questions, changelog, the maintenance checklist.

Put a new chapter in the part of its reader, and add it to the part's toctree in
``index.rst``.  When a change affects several parts, update all of them in the same
commit: :doc:`../appendices/maintenance-checklist` lists what to check.

Checking
========

.. code-block:: console

   $ bin/docodin-check README.rst CHANGELOG.rst docs/README.rst docs/book/*.rst \
         docs/book/*/*.rst docs/dod/*.rst
   $ bin/docodin dod check

Both must report nothing.
