==============================================================================
DOD 3: A Native Parser with Exact docutils Fidelity
==============================================================================

:Authors: Vikrant Rathore
:State: committed
:Created: 2026-09-27
:Discussion:
:Labels: parser, compatibility

.. contents:: Contents
   :local:
   :depth: 1

Summary
=======

docodin's native parser (``odin/rst``) reproduces docutils 0.22.4's reStructuredText
parser exactly: the same tree shapes, the same system messages with the same texts and
levels, in the same order, and the same ``source`` and ``line`` on every node.  "Close
enough" is not the goal.  docutils' behaviour, including its quirks, is the
specification, and every difference is a bug.  This record states the rule, the places
where it is hard to keep, and how it is verified.

Background
==========

reStructuredText has a written specification, but real documents depend on what docutils
does, not on what the specification says.  Sphinx and its extensions inspect node
positions to report warnings, pickle document trees into their environment, and match
message texts in tests.  A parser that differs in a line number changes a warning; one
that differs in a message text breaks a test suite; one that differs in a tree shape
changes the output.  To be a drop-in replacement, docodin has to be indistinguishable.

Proposal
========

The rule
--------

For every input and every parser setting, the native parser produces what docutils'
parser produces:

- the document tree, node by node, with every attribute;
- every system message: text, level, type, and where it is attached;
- ``source`` and ``line`` of every node, and the reporter's line for every message;
- the order of messages and of generated identifiers.

When docutils has a bug, docodin has the same bug.

How the parser is built
-----------------------

- **A state machine like docutils'.**  ``statemachine.odin`` follows docutils'
  ``StateMachine`` and ``StateMachineWS``: the input is a list of lines, states match
  transitions against the current line, and indented blocks are cut out
  (``get_indented``) and parsed by nested state machines.  The body, list,
  explicit-markup and table states live in ``body.odin``, ``lists.odin``,
  ``explicit.odin`` and ``tables.odin``, and the inliner in ``inline.odin``.
- **Hand-written matchers for docutils' regular expressions.**  Each regex of
  ``docutils.parsers.rst.states`` is a procedure in ``patterns.odin`` that accepts
  exactly the same strings, including the leftmost-match and backtracking behaviour
  that decides which alternative wins.
- **Memo tables instead of backtracking.**  Some of docutils' patterns backtrack, which
  makes pathological inputs quadratic or worse.  The inliner keeps memo tables
  (``no_end``, ``name_fail``, ``role_fail``, ``email_fail``) that record where a search
  already failed, so the result is the same and the time is linear.
- **Python's character classes.**  docutils' patterns use Python's Unicode categories
  (``\w``, punctuation classes for inline markup boundaries).  The tables are generated
  from CPython 3.14 (Unicode 16) by ``scripts/gen_unicode_tables.py``; each generated
  file records the version in its header.

The hard cases
--------------

- **Line numbers of nested parses.**  Table cells are parsed with a one-based
  ``input_offset``, and substitution definitions drop lines without adjusting the
  offset.  ``line_delta`` carries both adjustments.
- **The reporter's line and ``document.current_line``.**  docutils reports messages at
  the outermost state machine's position (frozen inside list-like constructs) and moves
  a cursor with every ``next_line``, ``previous_line`` and ``goto_line``.  The parser
  tracks both and records them where docutils attaches nodes.
- **include.**  Included lines are inserted into the input of the state machine that runs
  the directive and parsed there, with docutils' padding lines, as ``insert_input``
  does.  The Python host runs docutils' own ``Include`` through a native callback (a dry
  run) so that path resolution, options and errors are docutils'; the errors themselves
  are raised by the real run, in document order.
- **Message order.**  Some messages are created before the construct they belong to is
  parsed, for example "Unexpected indentation." after a paragraph, or the message about
  an enumerated list's start value.  The parser creates them first too.
- **Python semantics.**  Where docutils' result depends on Python, the native code
  reproduces Python: ``str`` methods, ``repr``, float formatting, ``unicodedata``
  normalisation for ``make_id``, dict ordering, ``findall`` while the tree changes, and
  the texts of exceptions that docutils lets through.
- **Limits.**  Recursion is bounded (``MAX_NESTING = 160`` in the state machine).  Where
  docutils would crash with a ``RecursionError``, docodin reports an error message
  instead.  This is the one intended difference, and it only affects input that docutils
  cannot process at all.

Alternatives
============

- **Follow the written specification** and accept differences from docutils.  Every
  difference would surface as a changed warning, test failure or output diff in someone's
  project, and docodin would no longer be a drop-in replacement.
- **Compile docutils' regular expressions** with a regex engine in Odin.  The patterns
  depend on Python's ``re`` semantics and Unicode tables; hand-written matchers are
  faster, and they are easier to make linear.

Compatibility and fidelity
==========================

This record is the fidelity rule.  Every later record that touches the docutils path
refers back to it.

Verification
============

- **docutils' own test suite**, run on the shim: 465 passed, 17 skipped and 1862
  subtests, the same as docutils, natively and with ``DOCODIN_NATIVE=0``.
- **docutils' parser tests** (``tests/conformance/run_docutils_suite.py``): the
  input and expected pseudo-XML pairs of ``test/test_parsers``.
- **Differential fuzzing** (``tests/fuzz_differential.py``): generated documents and
  byte-level mutations of corpus files are parsed by docutils and docodin; the
  pseudo-XML (with every system message) and the ``source`` and ``line`` of every node
  must be identical.  ``--directives`` generates directives, roles and includes, and
  compares the warning stream; ``--inline`` concentrates on the inliner's hard cases.
- **The shim differential** (``tests/shim_differential.py``): whole documents with every
  writer under random settings, compared end to end.
- **Sphinx's test suite** and the test suites of popular extensions give the same
  results as with docutils (see the book's compatibility chapter).

Outcome
=======

Implemented in docodin 0.1.0 and kept through 0.2.0, whose parser changes (DOD 12) were
checked with a hash over every field of every parse node.

One known difference remains: in about 20,000 generated documents, two cases of nested
includes differ in line numbers.  Both have an ``include`` two directive levels deep,
with more content after it in the outer directive.

References
==========

- ``odin/rst``, ``scripts/gen_unicode_tables.py``.
- ``tests/fuzz_differential.py``, ``tests/shim_differential.py``,
  ``tests/conformance/run_docutils_suite.py``.
- DOD 12 (the 0.2.0 parser work and the tree hash).
