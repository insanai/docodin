.. _introduction:

============
Introduction
============

docodin replaces docutils, the Python library that reads reStructuredText and writes
HTML, LaTeX, manual pages and other formats.  docutils is the engine under Sphinx, and
under every tool that renders ``.rst`` files: package indexes, documentation hosts,
linters, static site generators.  docodin does the same work with a reStructuredText
engine written in Odin, a systems language with manual memory management and
data-oriented features, and it gives docutils' results.  It also builds HTML sites and
PDF books from Sphinx projects natively.

What docodin is
===============

docodin has three parts.

A docutils implementation
   ``python/docodin/shim/docutils`` is the whole docutils 0.22 package, written for
   docodin: nodes, frontend, io, readers, the reStructuredText parser with its
   directives and roles, transforms, utilities, the math converters, and every writer
   (HTML4, HTML5, LaTeX, XeLaTeX, manual page, ODT, XML, pseudo-XML, S5 and PEP).  It is
   served under the name ``docutils``, so programs keep importing ``docutils`` and have
   nothing new to learn.  It passes docutils' own test suite and Sphinx's test suite with
   the same results as docutils.

A native reStructuredText engine
   ``odin/rst`` parses the block and inline grammar exactly as docutils does, including
   every system message and line number, about five times faster.  The docutils package
   builds its Python document tree from the engine's output.

Native tools
   ``docodin-check`` reports markup errors without Python, in Elm-style reports with
   source excerpts and hints, or in docutils' one-line format.  The native ``docodin``
   command publishes documents without Python, with docutils' output, messages and exit
   status, through a native port of docutils' reader, transforms and writers, and
   ``docodin book build`` builds HTML sites and PDF books from Sphinx projects that keep
   to a documented subset.  ``docodin-lsp`` is a language server for editors.  Documents
   that need a Python library (Pygments, PIL and a few others) are handed to docutils
   automatically.

What docodin promises
=====================

**docutils' results, within a stated contract.**  For the documents and settings it
supports, docodin produces what docutils 0.22.4 produces: the same output, the same
warnings and errors with the same texts, the same line numbers on every node, the same
exit status.  This is a tested property: docutils' test suite, Sphinx's test suite, the
test suites of popular extensions and themes, and differential tests over hundreds of
thousands of generated documents all compare docodin with docutils.  The 1.0.0b1 beta
supports native publishing, checking, the language server, native HTML book builds from
a documented subset and LaTeX output, and the Python and Sphinx integrations within
those measured bounds.  Full parity with every Sphinx extension is a goal, not a
promise.  :doc:`../reference/limits` states the contract and lists the known
differences.

**No new API.**  You do not port anything to docodin.  You choose how much of your
environment runs on it: one command, every process in a virtual environment, or
automatically where docutils is not installed (:doc:`../guide/installation`).

**Speed where it matters.**  The parser is about five times faster than docutils'.  A
Sphinx build of CPython's documentation takes 47.6 s instead of 65.6 s, or 38.4 s with
the optional collector tuning.  Publishing natively is ten to thirty times faster, the
native book builder builds this book's HTML 27.8 times faster than Sphinx, and checking a
documentation tree for markup errors takes hundredths of a second
(:doc:`../internals/performance`).

What docodin is not
===================

- **Not a new markup language.**  docodin reads reStructuredText as docutils defines it,
  with docutils' quirks.  It does not read Markdown or extend the syntax.
- **Not a Sphinx replacement.**  Under Sphinx, Sphinx still does its own work: the
  environment, cross-references, builders, themes.  docodin makes the docutils part of
  it faster.  The native book builder covers a documented subset of Sphinx projects,
  without extensions or Sphinx's themes.
- **Not a reimplementation of Python libraries.**  Pygments, PIL and the others stay
  Python (DOD 9).

A short history
===============

docodin started as a fast parser with a partial docutils emulation, and approximate
native HTML and LaTeX writers.  It became a complete replacement in 0.1.0: the docutils
package written for docodin, the native parser with exact fidelity, a pure-Python
fallback parser for extensions that change the grammar, and a native port of the whole
publishing pipeline that replaced the approximate writers.  Version 0.2.0 made the parser
2.8 times faster, lowered peak memory below docutils', added source positions and the
language server, and made the garbage-collector tuning opt-in.  The first beta,
1.0.0b1, states the support contract, ships the native programs in the wheel and adds a
release gate.  The :doc:`../appendices/changelog` has the details.

How to read this book
=====================

- If you want to try docodin, read :doc:`concepts` and :doc:`quick-start`, then the
  chapter of Part II that matches your use.
- If you maintain a Sphinx project, :doc:`../guide/sphinx` is the chapter for you.
- If you call docutils from Python, read :doc:`../guide/python`.
- If you want to know how docodin works, start Part IV with
  :doc:`../internals/architecture`.
- If you want to change docodin, read Part V, starting with
  :doc:`../development/building`.
