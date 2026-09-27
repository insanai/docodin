==============================================================================
DOD 6: A Hand-Written docutils Package and Its Import Hook
==============================================================================

:Authors: Vikrant Rathore
:State: committed
:Created: 2026-09-27
:Discussion:
:Labels: shim, compatibility

.. contents:: Contents
   :local:
   :depth: 1

Summary
=======

docodin ships its own implementation of the whole docutils 0.22 package, written for
docodin, in ``python/docodin/shim/docutils``: nodes, frontend, io, readers, the
reStructuredText parser with its directives and roles, transforms, utilities, the math
converters, and every writer (html4css1, html5, latex2e, xetex, manpage, odt, xml,
pseudo-XML, s5, pep).  An import hook serves it under the name ``docutils``, so Sphinx,
its extensions and any other program keep importing ``docutils`` and run on docodin
unchanged.  The parser of that package is the native engine.

Background
==========

docodin's first Python integration had two parts: a patch of an installed docutils
(``docodin.patch_docutils``, which replaces ``Parser.parse`` and
``RSTStateMachine.run``) and a small emulation of the most used docutils modules for
environments without docutils.  The patch works but depends on the installed docutils
version, and the emulation could not run Sphinx: Sphinx uses nearly all of docutils,
including private details.

Proposal
========

A complete package, module by module
------------------------------------

- **Same layout, same names.**  The package mirrors docutils' module layout.  Every
  public class, function and attribute has its docutils name, signature and module path
  (``__module__ == "docutils.nodes"`` and so on), so pickled Sphinx environments,
  ``isinstance`` checks and subclassing work as with docutils.
- **Within the project's code rules.**  Large docutils modules are split into private
  submodules that the public module re-exports, for example ``nodes/_base.py``,
  ``writers/_html_base_*.py``, ``latex2e/_*.py`` and ``utils/math/_math2html_*.py``.
  No file is longer than 1408 lines (DOD 11).
- **Data is generated, not typed.**  Language modules, character tables, URI schemes,
  smart-quote tables, math tables, the writers' stylesheets and templates and the
  standard include files come from docutils through ``scripts/gen_shim_data.py``.  Each
  generated file says so in its header.
- **Native where it pays.**  The parser is the native engine; smart quotes are educated
  natively (``docodin_educate``); ``string2lines`` is native.  The Python versions stay
  in the package as the reference and the fallback.

The parser inside the package
-----------------------------

``Parser.parse`` and ``RSTStateMachine.run`` hand the input to the native engine through
``docodin.builder``, which turns the marshalled parse result into ``docutils.nodes``,
registers targets and ids, nests sections and keeps ``document.current_line`` in step.
Directives and roles are Python code (from docutils, Sphinx or an extension).  They run
on state and state-machine objects that subclass the docutils classes
(``docodin._machine``).  When a directive calls ``nested_parse``, ``inline_text`` or
``parse_directive_block``, the call goes back to the native engine.

The import hook
---------------

``docodin.shim`` defines a meta-path finder that maps ``docutils`` and ``docutils.*`` to
the files of the package.  Each module is loaded once, under its docutils name.

- ``install_shim(force=True)`` puts the finder first, so it takes precedence over an
  installed docutils.  Modules of a docutils that is already imported are dropped.
- ``enable()`` appends it as a fallback: ``import docutils`` finds docodin only when no
  docutils is installed.  ``import docodin`` does this.
- ``docodin.pth`` imports ``docodin_autoload`` when the interpreter starts.  With
  ``DOCODIN_DOCUTILS=1`` in the environment it installs the shim; otherwise it appends a
  lazy fallback finder that imports nothing until something asks for ``docutils``.  It
  costs about 0.1 ms.
- ``docodin-sphinx-build`` installs the shim and runs ``sphinx-build``.
- ``is_active()`` tells whether the loaded ``docutils`` is docodin's; the package sets
  ``docutils.__docodin_shim__``.

DOD 10 covers how these are packaged and activated.

Alternatives
============

- **Vendoring docutils** and swapping its parser.  That keeps docutils' Python parser,
  data layout and module sizes, and it makes docodin a fork to be merged with every
  docutils release.  Writing the package gives docodin control over every module and the
  points where native code takes over, and the project's code rules hold everywhere.
- **Only patching an installed docutils.**  Kept as ``docodin.patch_docutils`` for
  programs that want the stock package, but it cannot work where docutils is absent, and
  it is sensitive to docutils' private details.
- **A partial emulation.**  The first attempt.  Sphinx needs the whole package.

Compatibility and fidelity
==========================

The package must be indistinguishable from docutils 0.22.4: same behaviour, same module
paths, same exceptions.  Where docutils uses Python libraries (Pygments, PIL), the
package uses them too.

Verification
============

- docutils' own test suite runs on the package: 465 passed, 17 skipped, 1862 subtests,
  the same as docutils, natively and with ``DOCODIN_NATIVE=0``.
- Sphinx 9.1's test suite: 2407 passed; the 7 failures are environment-related and fail
  the same way with docutils.
- The test suites of myst-parser, sphinx-design, sphinx-tabs, sphinxcontrib-bibtex,
  sphinx-autodoc-typehints, sphinx-gallery, pydata-sphinx-theme, sphinx-book-theme,
  sphinxext-opengraph, sphinx-notfound-page, sphinx-rtd-theme and breathe give the same
  results as with docutils.
- ``tests/shim_differential.py`` publishes random documents with every writer under
  random settings with both packages; outputs, warnings and node positions must match.
- ``tests/test_shim.py``, ``tests/test_docutils_api.py``, ``tests/test_ecosystem.py``.

Outcome
=======

Implemented in docodin 0.1.0.  The package was added in steps (core; transforms, readers
and publisher; parsers; writers; math) and then served through the import hook, which
replaced the old emulation modules ("Serve the shim through an import hook and remove the
old shim modules").

References
==========

- ``python/docodin/shim``, ``python/docodin/builder.py``, ``python/docodin/_machine.py``,
  ``python/docodin_autoload.py``, ``python/docodin.pth``.
- DOD 7 (the pure-Python parser), DOD 10 (packaging and activation).
