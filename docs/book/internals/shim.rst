.. _shim:

=========================
The docutils package
=========================

``python/docodin/shim/docutils`` is docodin's implementation of the docutils 0.22
package: about 170 modules and 38,000 lines of Python, written for docodin (DOD 6).  It
is what Sphinx runs on when docodin is active.  This chapter explains how it is laid out,
how it reaches the native parser, and how it is served as ``docutils``.

Layout
======

The package mirrors docutils' module layout: ``core``, ``frontend``, ``io``,
``statemachine``, ``nodes``, ``utils``, ``languages``, ``readers``, ``parsers``,
``transforms`` and ``writers``, with every writer (html4css1, html5_polyglot, latex2e,
xetex, manpage, odt, docutils_xml, pseudoxml, s5_html, pep_html).

- Every public class, function and attribute has its docutils name, signature and module
  path (``__module__ == "docutils.nodes"`` and so on).  Pickled Sphinx environments,
  ``isinstance`` checks and subclassing work as with docutils.
- Large modules are split into private submodules that the public module re-exports:
  ``nodes/_base.py``, ``nodes/_elements.py``, ``nodes/_document.py``,
  ``nodes/_visitors.py``, ``writers/_html_base_*.py``, ``latex2e/_*.py``,
  ``utils/math/_math2html_*.py``.  No file exceeds the project's 1408-line limit.
- ``docutils.__version__`` is ``"0.22.4"``, and ``docutils.__docodin_shim__`` is
  ``True``.

Generated data
--------------

Language modules, character tables, URI schemes, smart-quote tables, math tables, the
writers' stylesheets and templates, and the standard include files come from docutils,
through ``scripts/gen_shim_data.py``.  Each generated file carries a header naming the
script and the docutils version.

From the parser to the tree
===========================

``Parser.parse`` and ``RSTStateMachine.run`` hand the input to the native engine through
``docodin.builder``:

1. **Parse.**  ``docodin_parse`` returns the parse tree in ``marshal`` format, decoded
   without a copy (large results item by item).
2. **Build.**  The builder turns parse nodes into ``docutils.nodes`` and does the host
   side of docutils' parser, in docutils' order: registration with the ``document``
   (``note_*``, ``set_id``: names, ids, references, footnotes, citations,
   substitutions), section nesting (``check_subsection`` and ``new_subsection``), and
   ``document.current_line`` bookkeeping.
3. **Run directives and roles.**  Directives and interpreted-text roles are Python code
   from docutils, Sphinx or extensions.  They run with state and state-machine objects
   (``docodin._machine``: ``OdinStateMachine``, ``OdinBody`` and the inliner) that are
   subclasses of docutils' classes, so they see the complete ``StateMachineWS`` and
   ``RSTState`` interface.  When a directive calls ``nested_parse``, ``inline_text`` or
   ``parse_directive_block``, the call goes back to the native engine.

``include``
-----------

docutils parses included lines inside the state machine that ran the directive, as part
of its input.  ``docodin._include`` gives the native parser the same behaviour:

- When the parser meets a directive, the include hook runs docutils' own ``include``
  directive dry (without side effects) and returns the lines it would insert.  The parser
  inserts them and parses on, and the hook inserts them into the host's input lines at
  the same place, so line lookups stay in step.
- When the builder later runs the directive for real, its ``insert_input`` is skipped.
- Insertions of nested parses are removed when the nested parse ends and restored for
  the transforms.  ``include`` subclasses that the hook cannot run dry (Sphinx's, for
  example) are parsed separately.
- Errors are raised by the real run, in document order.

Native helpers
==============

Besides the parser, the package uses native code where it measurably pays:

- the builder splits the document's lines natively (``docodin_split_lines``), with
  ``string2lines``' semantics;
- ``SmartQuotes`` educates text with ``docodin_educate`` (:doc:`math-and-smartquotes`);
- visitor dispatch and ``walkabout`` skip formatting debug messages that are not shown.

The pure-Python versions stay in the package, as the reference that the differential
tests compare with, and as the fallback.

Serving the package as docutils
===============================

``docodin.shim`` defines a meta-path finder that maps ``docutils`` and ``docutils.*`` to
the package's files.  Each module is loaded once, under its docutils name.

``install_shim(force=True)``
   Puts the finder first, before an installed docutils.  Modules of a docutils that was
   already imported are dropped (objects created from them keep their classes).
``enable()``
   Appends the finder as a fallback, used only when no docutils is installed.  ``import
   docodin`` calls it.
``uninstall_shim()``
   Removes the finder and drops docodin's ``docutils`` modules.
``is_active()``
   Whether the loaded ``docutils`` is docodin's.

``docodin.pth`` imports ``docodin_autoload`` at interpreter start-up.  With
``DOCODIN_DOCUTILS=1`` it installs the shim; otherwise it appends a lazy finder that
imports docodin only when something asks for ``docutils`` and nothing else provides it.
``docodin-sphinx-build`` installs the shim and runs Sphinx.

Verification
============

- docutils' test suite runs on the package with docutils' results (465 passed, 17
  skipped, 1862 subtests), natively and with ``DOCODIN_NATIVE=0``.
- Sphinx's test suite and those of popular extensions and themes give docutils' results.
- ``tests/shim_differential.py`` publishes random documents with every writer under
  random settings in two worker processes, one with docutils and one with docodin, and
  compares outputs, warnings, exceptions and node positions.
- ``tests/test_shim.py``, ``tests/test_docutils_api.py``, ``tests/test_parity.py`` and
  ``tests/test_ecosystem.py`` cover the import hook, the API, host corner cases and
  extension patches.
