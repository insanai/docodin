.. _differential-testing:

===================================
Differential testing and fuzzing
===================================

A differential test runs the same input through docutils and through docodin and
requires the results to be identical.  It needs no expected output: docutils is the
oracle.  Combined with generated inputs it finds the corner cases that no one would
think of writing down, and it is how docodin's fidelity is established and kept.

The reference environment
=========================

Scripts that produce docutils' reference results run under CPython 3.14, the version the
native Unicode tables are generated from, with docutils 0.22.4 installed on the side:

.. code-block:: console

   $ PY="uv run --no-project --python 3.14 --with docutils==0.22.4 python"

Unicode data and the texts of Python exceptions (which docutils lets through) differ
between Python versions, so another Python could report differences that are not bugs.
Several scripts also need the docutils 0.22.4 source tree (``--docutils-src``), for its
functional test inputs, expected outputs and documentation.

The differential suites
=======================

The parser: ``tests/fuzz_differential.py``
------------------------------------------

.. code-block:: console

   $ uv run python tests/fuzz_differential.py --cases 10000
   $ uv run python tests/fuzz_differential.py --directives --cases 3000
   $ uv run python tests/fuzz_differential.py --inline --cases 5000 --seed 7

Generates random reStructuredText, grammar-based documents and byte-level mutations of
corpus files (``--corpus DIR``), parses each with docutils and docodin, and compares the
pseudo-XML (with every system message) and the ``source`` and ``line`` of every node.
``--directives`` generates directives and roles (with ``include`` enabled) and also
compares the warning stream.  ``--inline`` generates paragraphs dense in the inliner's
hard cases: standalone URIs, e-mail addresses, ``name_`` reference chains, escapes and
non-ASCII words, under random inline settings.  Mismatches, crashes and timeouts are
saved for inspection (``--out DIR``).

The docutils package: ``tests/shim_differential.py``
----------------------------------------------------

.. code-block:: console

   $ uv run python tests/shim_differential.py --cases 2000 --jobs 8
   $ uv run python tests/shim_differential.py --writers html5,latex --cases 500

Publishes random documents and corpus files with every writer, in two worker processes,
one running docutils and one running docodin's package, under randomly varied settings.
The outputs, warnings and exceptions must be identical, and so must every node's
position.

The checker: ``tests/lint_differential.py``
-------------------------------------------

.. code-block:: console

   $ uv run python tests/lint_differential.py --cases 5000

Parses generated documents with docutils' parser (no transforms) and compares the parser
messages with ``bin/docodin-check --error-format=docutils --report=warning``.  Messages of
directives, roles and the name registry are not the checker's and are ignored.

The native stages
-----------------

Each native stage is compared with docutils separately, then the whole pipeline:

``tests/native_reader_differential.py``
   The native reader (through the harness in ``odin/reader/tests/harness``) against
   docutils' parser into ``new_document``: the pseudo-XML, the ``(tagname, source,
   line)`` of every element, and the warning stream, at ``report_level`` 5 and 1.  Inputs:
   fuzz documents, generated directive documents, varied parser settings, and docutils'
   functional inputs and documentation.

``tests/native_transforms_differential.py``
   Every case is dumped at stage ``parsed`` and after each transform docutils applies
   (:doc:`../internals/interchange`).  The Odin runner applies the same queue one
   transform at a time and must reproduce each dump byte for byte: the tree with every
   node's source and line, the registry, the reporter's messages, the queue and the
   settings.  A mismatch is attributed to the first transform after which the dumps
   differ.

   .. code-block:: console

      $ $PY tests/native_transforms_differential.py --docutils-src DIR --fuzz 2000 --jobs 8

``tests/native_writers_differential.py``
   Every input is published by docutils for each writer and settings variant and dumped
   at stage ``output``; the Odin runner writes the transformed document natively and
   compares the output and every part.

   .. code-block:: console

      $ $PY tests/native_writers_differential.py --docutils-src ~/src/docutils-0.22.4 \
            --work /tmp/writers --fuzz 2000

``tests/native_math_differential.py``
   Hand-picked edge cases, a grammar-driven fuzzer and random command sequences through
   ``tex2mathml``, ``math2html``, ``uni2tex`` and ``pick_math_environment``, natively and
   in docutils: outputs, trace messages and exceptions.

``tests/native_publish_differential.py``
   ``publish`` end to end against docutils' ``Publisher.publish``: the output, every
   part, the warning stream, the failure report and the exit status, on the functional
   inputs and ``docs/**/*.rst`` with every writer and settings variants, and on
   generated documents under random settings (halt and exit-status levels, command-line
   style strings).  Documents with Python needs are counted by feature and still
   compared with docutils without the libraries.

   .. code-block:: console

      $ $PY tests/native_publish_differential.py --docutils-src ~/src/docutils-0.22.4 --fuzz 3000

Smart quotes: ``tests/smartquotes_differential.py``
---------------------------------------------------

.. code-block:: console

   $ uv run python tests/smartquotes_differential.py --cases 20000

Random token sequences educated by the native code and by the Python reference, with
random attribute modes, languages and customised quotes.

The parse-tree hash
===================

Performance work on the parser must not change its output.  A hash over every field of
every parse node (kind, line, current line, numbers, links, ``text``, ``raw``, ``name``,
directive and phrase data) is compared before and after a change, on a large corpus
(docutils' documentation repeated to about 21 MB) and on tens of thousands of generated
documents under several settings.  The hash must be identical, and identical with spans
on and off.

When a difference appears
=========================

1. Reduce the input: the saved case is usually generated noise around a small core.
   Remove lines and characters while the difference remains.
2. Check the stage.  ``DOCODIN_NATIVE=0`` tells whether the native parser is involved;
   the stage differentials tell which native stage.
3. Read docutils' code for the construct.  The difference is almost always a docutils
   behaviour that docodin does not reproduce yet: an order of operations, a Python
   semantic, a line-number adjustment.
4. Fix it in docodin, add the reduced case to a unit or parity test, and run the
   differential again with the same seed.

Large runs
==========

Long fuzzing runs and full-scale benchmarks, such as tens of thousands of cases or
CPython's documentation, are best run on a Linux machine with many cores
(``--jobs``).  Keep the seed of every run that found something, so that it can be
repeated.
