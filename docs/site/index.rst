*******
docodin
*******

**A native reStructuredText toolchain, written in Odin.**

Publish documents, check markup, build HTML sites and PDF books, and work with editor
diagnostics. The native tools use explicit ownership, arenas and data-oriented storage;
supported documents run without Python. The Python package lets docutils and Sphinx use
the same native engine.

.. image:: https://raw.githubusercontent.com/insanai/docodin/main/docs/book/_static/docodin_logo.png
   :alt: Sphinx's single-eye symbol with Odin's beard, drawn in pencil.
   :width: 180px
   :align: center

Get started
===========

The first beta is **1.0.0b1**. Start with the `installation guide
<book/guide/installation.html>`__ or `build from source
<book/development/building.html>`__. Published packages and native archives are listed
on `GitHub Releases <https://github.com/insanai/docodin/releases>`__.

.. code-block:: console

   $ docodin hello.rst hello.html
   $ docodin-check hello.rst
   $ docodin pdf --engine=lualatex hello.rst hello.pdf
   $ docodin book build docs --html -o build/manual

PDFs need TeX Live or MacTeX. Python libraries are used for features that need them,
such as Pygments highlighting and image metadata outside the native reader's scope.

Features
========

* **Native publishing:** HTML5, LaTeX, XeLaTeX, Docutils XML and pseudo-XML.
* **Documentation builds:** navigation, search, cross-document references and PDF books.
* **Markup checks:** source excerpts and hints, or docutils-compatible reports.
* **Editor support:** diagnostics, definitions, references, hover and completion through
  ``docodin-lsp``.
* **Python integration:** native publication, a docutils package and Sphinx integration.

Learn and contribute
====================

* `The docodin Book <book/index.html>`__: tools, editors, reference and internals.
* `DocOdin Discussions <dod/index.html>`__: design decisions and their states.
* `Known limits <book/reference/limits.html>`__: the beta's supported boundary.
* `Source code <https://github.com/insanai/docodin>`__ and
  `issues <https://github.com/insanai/docodin/issues>`__.

Native tooling is the main focus. Differential checks target docutils 0.22.4; complete
compatibility with every Sphinx project or extension is outside this beta's promise.
See the `performance chapter <book/internals/performance.html>`__ for measured results,
including the distinction between native builds and parser replacement inside Sphinx.

Authors
-------

**Vikrant Rathore** is the author and maintainer, with algorithm assistance from
**Ronak Rathore** and logo design by **Kanak Rathore**.

docodin is MIT licensed. This website, its book and its design records are built by
docodin itself and hosted on GitHub Pages.
