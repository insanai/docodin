==============================================================================
DOD 7: A Pure-Python Parser for Extensions That Change the Grammar
==============================================================================

:Authors: Vikrant Rathore
:State: committed
:Created: 2026-09-27
:Discussion:
:Labels: parser, shim, compatibility

.. contents:: Contents
   :local:
   :depth: 1

Summary
=======

The native engine implements docutils' stock reStructuredText grammar.  Some extensions
change that grammar in Python: they subclass parser states, replace or wrap their
methods, change their patterns, or patch the ``Inliner``.  The native engine cannot see
such changes.  For those documents docodin parses with a complete pure-Python state
machine that is part of its docutils package, so the extension works exactly as it does
with docutils.  Everything else keeps the native parser.

Background
==========

docutils' parser is a set of Python classes (``Body``, ``Text``, ``Line``,
``SpecializedBody`` and more) with regex-driven transitions.  Extensions can and do
change them:

- a custom ``state_classes`` list or another initial state;
- a subclass of a stock state, or a custom ``Inliner`` class with extra inline patterns;
- a monkeypatch of a stock method or pattern at import time.

sphinx-autodoc-typehints is a real example: it replaces ``Body.doctest`` and wraps
``Text.indent``.  A native parser that ignored such changes would silently parse a
different language.

Proposal
========

The shim contains the complete block parser in Python (``parsers/rst/states.py`` with
``_body.py`` and ``_explicit.py``), following docutils.  A document is parsed with it
when:

- the state classes are not the stock ones, or the initial state is not ``Body`` or
  ``RFC2822Body``;
- a custom ``Inliner`` class is used;
- an extension replaced or wrapped a method, or changed a pattern, of a stock state class
  or of ``Inliner`` since the module was loaded.  ``_fallback.Snapshot`` records the
  attributes of the stock classes at import time and compares them with the current
  ones; attributes that change at run time without changing the grammar are ignored;
- ``DOCODIN_NATIVE=0`` is set, which forces the Python parser everywhere (for debugging
  and for comparing the two parsers).

Two replacements keep the native path.  sphinx-autodoc-typehints' ``Body.doctest`` and
``Text.indent`` are replayed by the builder on the constructs the native parser built
(``docodin._machine.replay_transition``), so the documents of projects that use it are
still parsed natively.

The decision is made per parse, in ``Parser.parse`` and ``RSTStateMachine.run``.

Alternatives
============

- **Refuse such extensions.**  They are popular; docodin would not be a drop-in
  replacement.
- **Describe grammar changes to the native engine.**  Extensions change arbitrary Python
  code; there is no declarative form to translate.
- **Always parse in Python when an extension is loaded.**  Too coarse: most extensions
  add directives and roles, which work with the native parser.

Compatibility and fidelity
==========================

The Python parser is docutils' parser in behaviour, so documents that use grammar
changes get docutils' results.  The native path is taken only when the grammar is the
stock one.

Verification
============

- docutils' test suite passes identically with ``DOCODIN_NATIVE=0``.
- ``tests/test_python_states.py``: custom, subclassed and patched parser states against
  docutils.
- ``tests/test_ecosystem.py``: extension patches, including sphinx-autodoc-typehints'.
- Sphinx's test suite gives identical pass and fail lists with the stock docutils, the
  native path and the forced Python path.

Outcome
=======

Implemented in docodin 0.1.0 ("Parse with Python parser states when extensions change
the grammar", "Fall back to the Python parser when extensions patch the Inliner", "Run
extensions' replacements of the doctest and definition list transitions").

References
==========

- ``python/docodin/shim/docutils/parsers/rst/_fallback.py``, ``states.py``,
  ``python/docodin/_machine.py``.
- DOD 6 (the docutils package).
