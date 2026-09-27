.. _faq:

==========================
Questions and answers
==========================

Will my Sphinx output change?
   No.  docodin produces docutils' output, byte for byte, and this is tested on Sphinx's
   test suite, the test suites of popular extensions and themes, and the documentation
   of several large projects.  The one exception is opt-in: the garbage-collector tuning
   can change the output of projects with duplicate labels or repeated generated ids
   (:doc:`../guide/sphinx`).  Build with and without docodin and compare; any other
   difference is a bug.

Do I have to change my code?
   No.  docodin is served under the name ``docutils``.  Choose how to activate it
   (:doc:`../guide/installation`); your code keeps importing ``docutils``.

Can docodin and docutils be installed at the same time?
   Yes.  Installing docodin does not change programs that use an installed docutils.
   They use docodin only when you activate it: ``docodin-sphinx-build``,
   ``DOCODIN_DOCUTILS=1``, or ``install_shim(force=True)``.

How do I know which one is running?
   ``docodin.shim.is_active()`` returns ``True`` when the loaded ``docutils`` is
   docodin's; ``docutils.__file__`` points into ``docodin/shim``.

My extension adds directives and roles.  Does it work?
   Yes.  Directives and roles are Python code, and they run on docodin's docutils
   package exactly as on docutils.

My extension changes the reStructuredText grammar.  Does it work?
   Yes.  docodin detects changed or patched parser states and inliners and parses those
   documents with its pure-Python parser, as docutils would (DOD 7).  Such documents do
   not get the native parser's speed.

Why is my Sphinx build not five times faster?
   The parser is about five times faster, but most of a Sphinx build is Sphinx's own
   work.  On CPython's documentation the whole build is 1.38 times faster, or 1.71 times
   with the collector tuning.

Does the native ``docodin`` command need Python?
   Not for documents that use only what the native pipeline implements.  A document that
   needs a Python library (Pygments for highlighted code, PIL for scaled images, ...) is
   handed to ``python -m docodin``.  ``--syntax-highlight=none`` avoids the most common
   need.

Why does ``docodin`` write HTML5 for ``html``?
   docodin's commands treat ``html`` as the current HTML writer, html5.  In docutils it
   still means html4css1.  This is one of the few documented differences
   (:doc:`../reference/limits`).

Does ``docodin-check`` find every problem Sphinx would report?
   No.  It reports the parser's messages: markup errors.  Unknown directives and roles,
   missing files and broken references need the directives, roles and transforms to run.
   ``docodin-lsp`` and the native ``docodin`` command report those, and Sphinx reports
   its own on top.

Does the language server understand Sphinx?
   It knows Sphinx's standard roles and directives by name when ``sphinx`` is set, so
   they are not reported as unknown.  It does not resolve cross-document references.

Why Odin?
   Odin is a systems language with manual memory management, first-class support for
   data-oriented design (``#soa`` arrays, ``distinct`` types for handles, arenas) and a
   portable SIMD package, and it builds small, dependency-free binaries and shared
   libraries with a C ABI.

Why is the Python package not a CPython extension?
   The native library speaks a C ABI and returns ``marshal`` data, which Python decodes in
   C.  One wheel per platform serves every Python version (DOD 10).

Which Python versions are supported?
   Python 3.12 and later.

Where are the design decisions?
   In the DocOdin Discussions, ``docs/dod``.  :doc:`../development/dod-process` lists them.
