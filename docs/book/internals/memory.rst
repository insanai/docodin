.. _memory:

======
Memory
======

docodin's native code allocates from arenas and keeps its trees in flat arrays
(:doc:`storage`), so the native side is cheap.  Most of a Sphinx build's memory is
Python objects: the document trees and Sphinx's environment.  This chapter follows a
parse result from the native side into Python, and the measurements that shaped it
(DOD 15).

The path of a parse result
==========================

1. **The arena.**  The parser works in a per-thread bump arena.  Blocks are mapped from
   the operating system, start at 1 MB and double up to 64 MB; after a call,
   ``bump_reset`` keeps the largest block of at most 4 MB and returns the rest to the
   operating system at once.
2. **The wire.**  The parse tree is serialised in ``marshal`` format into the arena.  It
   is about 2.9 times the size of the input.
3. **Decoding without a copy.**  ``docodin._native`` wraps the native buffer in a
   read-only ``memoryview`` (``PyMemoryView_FromMemory``), and ``marshal.loads`` decodes
   from it directly, so the wire never exists twice.
4. **Item by item.**  From 64 KB on (``LAZY_MIN_SIZE``), each top-level item of a document
   result is a separate ``marshal`` object.  ``WireItems`` decodes an item when the
   builder first needs it and drops it once iteration has passed it, so the tuples of
   the whole document (about 6.5 times the input) never exist at once.  The buffer is
   released when the builder is done.
5. **The document tree.**  ``builder.py`` creates the ``docutils.nodes`` objects, which
   are what Sphinx keeps.

Why it matters
==============

In docodin 0.1.0, a single-process Sphinx build of CPython's documentation peaked at
999 MB with docodin against 890 MB with docutils, although the memory held after reading
was the same.  The difference came from short-lived objects: a copied wire, and millions
of tuples created before any node and interleaved with long-lived nodes, which leaves
pymalloc arenas that cannot be returned to the operating system; and a 64 MB arena block
kept per thread.  With the changes above, docodin 0.2.0 peaks at 883 MB, against 895 MB
for docutils on the same build.

.. list-table::
   :header-rows: 1
   :widths: 50 25 25

   * - Sphinx, CPython documentation (599 pages, ``-j1``)
     - Peak memory
     - Time
   * - docutils 0.22.4
     - 895 MB
     - 65.6 s
   * - docodin 0.2.0
     - 883 MB
     - 47.6 s
   * - docodin 0.2.0 with ``DOCODIN_GC=tuned``
     - 1034 MB
     - 38.4 s

The collector tuning trades memory for time: garbage is collected later during reading,
so the peak is about 17 % higher (:doc:`../guide/sphinx`).

Native memory in numbers
========================

From the profile of DOD 12, on a 20.9 MB corpus (docutils' documentation repeated): the
parse created 815,866 nodes (25.6 input bytes per node, 96 bytes per ``Node_Data``); the
parse arena used 242.6 MB; ``docodin-check -j1`` ran in 0.36 s with a resident size of
175 MB.  The wire tuple trees of the 60 documentation files take 9.1 MB of Python heap,
6.5 times the input, where docutils' own document trees for the same files take 62.3 MB,
44.8 times the input.

Measuring
=========

Peak resident size is measured with ``/usr/bin/time -l`` (macOS) or ``/usr/bin/time -v``
(Linux) around a fixed Sphinx build, and ``tracemalloc`` peaks in a fixed harness for the
Python side.
