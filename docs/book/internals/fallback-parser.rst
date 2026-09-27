.. _fallback-parser:

==========================
The pure-Python parser
==========================

The native engine implements docutils' stock reStructuredText grammar.  Extensions can
change that grammar in Python, and the native engine cannot see such changes.  For those
documents docodin's docutils package parses with its own pure-Python state machine,
which behaves exactly like docutils' (DOD 7).

When it is used
===============

``docutils/parsers/rst/_fallback.py`` decides, for each parse in ``Parser.parse`` and
``RSTStateMachine.run``.  The Python parser runs when:

- the state classes are not the stock ones: a custom ``state_classes`` list, a subclass
  of a stock state, or an initial state other than ``Body`` or ``RFC2822Body``;
- a custom ``Inliner`` class is used (extra inline patterns);
- an extension replaced or wrapped a method, or changed a pattern, of a stock state class
  or of ``Inliner`` since the module was loaded;
- ``DOCODIN_NATIVE=0`` is set, which forces the Python parser everywhere.

Detecting patches
=================

``Snapshot`` records the attributes of the stock state classes and of ``Inliner`` when
the module is loaded.  Before a parse, the current attributes are compared with the
snapshot:

- methods are compared by identity, so a replaced or wrapped method is detected;
- patterns are compared by their source text, since patterns compile lazily;
- dictionaries, sequences and namespaces are compared item by item;
- attributes that change at run time without changing the grammar are ignored
  (``nested_sm_cache``, and the whitespace patterns that ``StateWS`` adds).

Replayed transitions
====================

Some popular extensions patch the grammar in ways the native path can reproduce.
sphinx-autodoc-typehints replaces ``Body.doctest`` and wraps ``Text.indent``.  These two
transitions (``REPLAYED`` in ``_fallback.py``) do not trigger the fallback: the builder
runs the extension's replacement on the constructs the native parser built
(``docodin._machine.replay_transition``), so projects that use the extension keep the
native parser.

The Python state machine
========================

``parsers/rst/states.py``, ``_body.py`` and ``_explicit.py`` hold the complete block
parser in Python, following docutils: the state machine, the states and their
transitions, the inliner.  It is also the reference against which the native parser is
compared, and running docutils' test suite with ``DOCODIN_NATIVE=0`` exercises it on
its own.

Verification
============

- docutils' test suite passes identically with ``DOCODIN_NATIVE=0``.
- ``tests/test_python_states.py`` checks custom, subclassed and patched parser states
  against docutils.
- ``tests/test_ecosystem.py`` covers extension patches, including
  sphinx-autodoc-typehints'.
- Sphinx's test suite gives the same pass and fail lists with docutils, with the native
  parser and with the forced Python parser.
