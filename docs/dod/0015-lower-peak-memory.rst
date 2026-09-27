==============================================================================
DOD 15: Lower Peak Memory
==============================================================================

:Authors: Vikrant Rathore
:State: committed
:Created: 2026-09-27
:Discussion:
:Labels: performance, shim

.. contents:: Contents
   :local:
   :depth: 1

Summary
=======

In docodin 0.1.0 a single-process Sphinx build of CPython's documentation peaked at
999 MB with docodin against 890 MB with docutils, although the memory held after reading
was the same.  docodin 0.2.0 decodes native results without copying them, decodes large
results item by item, and keeps less arena memory between calls.  The same build now
peaks at 883 MB, below docutils' 895 MB.

Background
==========

A parse result crosses from Odin to Python as a ``marshal`` buffer (the wire).  DOD 12
measured the costs on the way:

- the per-thread bump arena kept a block of up to 64 MB between calls;
- the wire (about 2.9 times the input) briefly existed twice, because
  ``ctypes.string_at`` copied it into a ``bytes`` object;
- ``marshal.loads`` built the whole tuple tree (about 6.5 times the input) before
  ``builder.py`` created a single node, so millions of short-lived tuples were
  interleaved with long-lived nodes, which leaves pymalloc arenas that cannot be returned
  to the operating system.

Proposal
========

1. **No copy.**  ``marshal.loads`` accepts any bytes-like object.  ``docodin._native``
   wraps the native buffer in a read-only ``memoryview``
   (``PyMemoryView_FromMemory``) and decodes from it directly.  The view is valid until
   the buffer is freed.
2. **Item by item for large results.**  From 64 KB on (``LAZY_MIN_SIZE``), each
   top-level item of a document result is a separate marshal object, and ``WireItems``
   decodes an item when the builder first needs it and drops it once iteration has passed
   it.  The tuples of the whole document never exist at once.
3. **A smaller resident arena.**  The bump arena maps its blocks from the operating
   system (``virtual.reserve_and_commit``), not from the C heap, which may keep freed
   memory, so a released block returns its memory at once.  ``bump_reset`` keeps the
   largest block of at most 4 MB (``BUMP_RETAIN_MAX``): steady-state parsing maps no
   memory, and a large parse does not leave a large block resident.  Blocks start at
   1 MB and double up to 64 MB.

Two further steps from DOD 12, sizing the node reserve by measurement and shrinking
``Node_Data``, were not needed to reach the goal and were not done.

Alternatives
============

- **Stream the wire per top-level construct** from the native side.  Item-by-item
  decoding gives the same peak without changing the native serialiser's control flow.
- **Tune pymalloc** or force collections.  Treats the symptom, costs time.

Compatibility and fidelity
==========================

The wire format's items and their order are unchanged; only when Python objects are
created changes, never the node order.  The shim differential suites and Sphinx's test
suite verify it.

Verification
============

- Peak RSS measured with ``/usr/bin/time`` on a fixed Sphinx project (CPython's
  documentation, 599 pages, ``-j1``) at release time: 883 MB with docodin 0.2.0, 895 MB
  with docutils 0.22.4.
- ``tests/test_native.py``, ``tests/test_sphinx.py`` and the shim differential suites.

Outcome
=======

Released in docodin 0.2.0 ("Decode native results without copying them, item by item
when large", "Map arena blocks from the OS and keep at most a 4 MB block between calls").

References
==========

- ``python/docodin/_native.py``, ``odin/lib/bump.odin``, ``odin/lib/serialize.odin``.
- DOD 12, DOD 16.
