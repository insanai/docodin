==============================================================================
DOD 16: Garbage-Collector Tuning Is Opt-In
==============================================================================

:Authors: Vikrant Rathore
:State: committed
:Created: 2026-09-27
:Discussion:
:Labels: performance, compatibility, release

.. contents:: Contents
   :local:
   :depth: 1

Summary
=======

``docodin-sphinx-build`` and the ``docodin.sphinx`` extension can tune Python's garbage
collector for Sphinx builds: raised thresholds, and the long-lived objects frozen after
the extensions are loaded and after reading.  It makes a build of CPython's documentation
about 20 % faster.  In docodin 0.1.0 it was on by default.  Since 0.2.0 it is opt-in
(``DOCODIN_GC=tuned``, or ``docodin_gc_tuning = True`` in ``conf.py``), because the output
of some projects depends on when Python collects garbage.

Background
==========

A Sphinx build keeps a large, long-lived environment in memory, and Python's full
collections rescan it again and again.  Two changes avoid most of that work:

- ``gc.set_threshold(50_000, 20, 100)``: fewer collections of the young generation;
- ``gc.collect()`` then ``gc.freeze()`` when the builder is initialised and when the
  environment is updated (after reading): the objects alive at those points are moved to
  a permanent generation that later collections skip.

``docodin-sphinx-build`` patches ``Sphinx.__init__`` to connect the two events; the
extension connects them from ``builder-inited``.

Discussion
==========

In 0.1.0 the tuning was measured as about 18 % faster on CPython's documentation, for
about 17 % more peak memory (garbage is collected later during reading), and the HTML
was identical.  While preparing 0.2.0 the output of CPython's documentation changed in
four pages between runs with and without the tuning, *with docutils as with docodin*.
The cause is in Sphinx, not in docodin: with duplicate labels or repeated generated ids,
"last one wins" in Sphinx's environment follows the lifetime of objects, and a collector
that runs at other moments changes which object is last.

A setting that can change a project's output cannot be on by default in a drop-in
replacement.  The choice was between:

1. keeping it on by default and documenting the risk;
2. making it opt-in, and documenting the benefit;
3. removing it.

Option 2 was chosen.  The speed-up is real and safe for projects without duplicate labels
or ids, and a project can check that by building with and without it.

Proposal
========

- ``docodin-sphinx-build`` tunes the collector only with ``DOCODIN_GC=tuned`` in the
  environment (any other value, or none, keeps Python's defaults).
- The ``docodin.sphinx`` extension registers the configuration value
  ``docodin_gc_tuning`` (default ``False``); ``True`` tunes the collector.

Alternatives
============

See the discussion: on by default, or removed.

Compatibility and fidelity
==========================

By default, docodin now runs Sphinx with Python's own collector settings, exactly as
docutils does.  With the tuning on, a project whose output depends on collection timing
can change, with docutils as with docodin; for other projects the output is the same.

Verification
============

- ``tests/test_shim.py`` (``test_sphinx_build_wrapper_tunes_the_collector``) checks that
  the wrapper tunes the collector only on request.
- Release measurements on CPython's documentation (599 pages, ``-j1``, Linux x86-64,
  Python 3.13): 47.6 s and 883 MB with docodin 0.2.0 by default; 38.4 s and 1034 MB with
  ``DOCODIN_GC=tuned``; 65.6 s and 895 MB with docutils.

Outcome
=======

Released in docodin 0.2.0 ("Make the collector tuning opt-in because Sphinx output can
depend on it").

References
==========

- ``python/docodin/sphinx_build.py``, ``python/docodin/sphinx.py``.
- ``CHANGELOG.rst`` (0.1.0 and 0.2.0).
