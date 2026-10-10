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

.. graphviz::
   :class: adaptive-diagram
   :align: center
   :caption: The host selects a parser for each parse; custom grammar takes the Python path.
   :alt: An explicit native-off setting or a changed parser grammar selects the Python parser; otherwise the Odin parser feeds the same docutils node model.

   digraph parser_choice {
   graph [bgcolor="white", pad="0.28", nodesep="0.4", ranksep="0.6", fontname="Helvetica", fontsize=17, fontcolor="#425574", color="#CBD5E1"];
   node [shape=box, style="rounded,filled", fontname="Helvetica", fontsize=16, margin="0.22,0.16", fillcolor="#EFF4FF", color="#B3C6F7", fontcolor="#18243D", penwidth=1.2];
   edge [fontname="Helvetica", fontsize=12, color="#526B97", fontcolor="#425574", arrowsize=0.75, penwidth=1.4];
   rankdir=TB;
   request [label="Parser.parse / RSTStateMachine.run", fillcolor="#F4F6FA", color="#CDD5E2"];
   forced [label="DOCODIN_NATIVE=0?", shape=diamond, style=filled];
   stock [label="Stock states, Inliner\nand snapshot unchanged?", shape=diamond, style=filled];
   native [label="Odin parser\nStock grammar", fillcolor="#DBE7FF", color="#7DA1ED"];
   python [label="Pure-Python parser\nCustom or patched grammar", fillcolor="#EEE9FB", color="#C0AEE7"];
   nodes [label="Ordinary docutils nodes\nHost directives and roles", fillcolor="#E5F5EE", color="#8DC9B0"];
   request -> forced;
   forced -> python [label="yes"];
   forced -> stock [label="no"];
   stock -> native [label="yes"];
   stock -> python [label="no"];
   native -> nodes [label="marshal + builder"];
   python -> nodes;
   {rank=same; native; python;}
   }


``docodin/_grammar.py`` decides, for each parse in ``Parser.parse`` and
``RSTStateMachine.run``.  docodin's docutils and ``docodin.Parser``, ``patch_docutils``
and the ``docodin.sphinx`` extension on an installed docutils use the same rules.  The
Python parser runs when:

- the state classes are not the stock ones: a custom ``state_classes`` list, a subclass
  of a stock state, or an initial state other than ``Body`` or ``RFC2822Body``;
- a custom ``Inliner`` class is used (extra inline patterns);
- an extension replaced or wrapped a method, or changed a pattern, of a stock state class
  or of ``Inliner`` since the module was loaded;
- ``DOCODIN_NATIVE=0`` is set, which forces the Python parser everywhere.

Detecting patches
=================

``Snapshot`` records the attributes of the stock state classes and of ``Inliner`` when
the module is loaded: docodin's ``states`` module, or ``docodin.parser`` on an installed
docutils (patches made before ``docodin.parser`` is imported are not seen there).
Before a parse, the current attributes are compared with the snapshot:

- methods are compared by identity, so a replaced or wrapped method is detected;
- patterns are compared by their source text, since patterns compile lazily;
- dictionaries, sequences and namespaces are compared item by item;
- attributes that change at run time without changing the grammar are ignored
  (``nested_sm_cache``, and the whitespace patterns that ``StateWS`` adds).

Replayed transitions
====================

Some popular extensions patch the grammar in ways the native path can reproduce.
sphinx-autodoc-typehints replaces ``Body.doctest`` and wraps ``Text.indent``.  These two
transitions (``REPLAYED`` in ``_grammar.py``) do not trigger the fallback: the builder
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
