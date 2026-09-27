==============================================================================
The docodin Book
==============================================================================

docodin is a drop-in replacement for docutils 0.22.4, built on a reStructuredText engine
written in Odin.  Sphinx, its extensions and every other program that imports
``docutils`` run on it unchanged and produce identical output, faster.  docodin also
publishes and checks documents natively, without Python, and gives editors a language
server with docutils' exact diagnostics.

This book is written for four kinds of readers, in five parts.  Part I explains what
docodin is and gets you to a first result.  Part II shows how to use it: with Sphinx,
from Python, on the command line, as a checker and in an editor.  Part III is the
reference for commands, settings, environment variables and compatibility.  Part IV
explains how docodin works inside, and Part V how to build, test and change it.  The
appendices hold a glossary, questions and answers, the changelog and the checklist for
maintaining this book.

The design decisions behind docodin are recorded separately, as numbered DocOdin
Discussions (``docs/dod``).  The book refers to them by number, for example "DOD 8".

Orientation
===========

.. toctree::
   :maxdepth: 2
   :caption: Part I: Orientation

   orientation/introduction
   orientation/concepts
   orientation/quick-start

Using docodin
=============

.. toctree::
   :maxdepth: 2
   :caption: Part II: Using docodin

   guide/installation
   guide/sphinx
   guide/python
   guide/command-line
   guide/checker
   guide/editors

Reference
=========

.. toctree::
   :maxdepth: 2
   :caption: Part III: Reference

   reference/compatibility
   reference/cli
   reference/environment
   reference/python-api
   reference/settings
   reference/limits

Internals
=========

.. toctree::
   :maxdepth: 2
   :caption: Part IV: Internals

   internals/architecture
   internals/parser
   internals/storage
   internals/spans
   internals/shim
   internals/fallback-parser
   internals/pipeline
   internals/interchange
   internals/writers
   internals/python-needs
   internals/math-and-smartquotes
   internals/language-server
   internals/memory
   internals/performance

Development
===========

.. toctree::
   :maxdepth: 2
   :caption: Part V: Development

   development/building
   development/testing
   development/differential-testing
   development/code-rules
   development/dod-process
   development/documentation

Appendices
==========

.. toctree::
   :maxdepth: 2
   :caption: Appendices

   appendices/glossary
   appendices/faq
   appendices/changelog
   appendices/maintenance-checklist
