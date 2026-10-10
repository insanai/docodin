.. _faq:

==========================
Questions and answers
==========================

What does the beta support?
   Native publishing, the native checker, the language server's documented features,
   native HTML book builds from a documented subset of Sphinx projects, and LaTeX output
   with an external TeX engine for PDFs; and the Python, docutils and Sphinx
   integrations within their measured bounds.  :doc:`../reference/limits` states the
   contract and the verified platforms.

Will my Sphinx output change?
   It should not.  docodin aims at docutils' output, byte for byte, and Sphinx's test
   suite, the test suites of popular extensions and themes, and the documentation of
   several large projects give the same results.  Full parity with every extension is a
   goal, not a promise of the beta.  One difference is opt-in: the garbage-collector
   tuning can change the output of projects with duplicate labels or repeated generated
   ids (:doc:`../guide/sphinx`).  Build with and without docodin and compare; any other
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

Does the wheel include the native programs?
   Yes, since 1.0.0b1: ``pip install docodin`` installs ``docodin``, ``docodin-check``
   and ``docodin-lsp`` into the environment's ``bin`` directory.  They run without the
   source checkout.  The Python front end that used to be the ``docodin`` command is
   ``python -m docodin``.

Does the native ``docodin`` command need Python?
   Not for documents that use only what the native pipeline implements.  A document that
   needs a Python library (Pygments for highlighted code, PIL for unsupported image
   headers, ...) is
   handed to ``python -m docodin``, run by ``$DOCODIN_PYTHON`` or else the Python of the
   environment the program is installed in.  ``--syntax-highlight=none`` avoids the most
   common need.

Why does ``docodin book build`` stop at one of my files?
   Every source must be UTF-8.  A file that cannot be decoded is reported as SOURCE IS
   NOT UTF-8 with its line, and the build writes nothing, rather than publishing pages
   with invalid text.  Save the file as UTF-8.

Can a long-running service call the library from many threads?
   Yes.  Each call works in its thread's arena, and when the call returns the arena's
   block goes to a cache shared by all threads, of at most 8 blocks of 4 MB.  A thread
   that exits keeps no memory, so services that create and retire threads stay bounded
   (:doc:`../reference/limits`).

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
   Python 3.12 and later.  The release gate ran 1.0.0b1 under CPython 3.12 on macOS and
   on Linux.  The native engine uses Unicode 16 under every Python, so on
   Pythons before 3.14 a few results can differ from docutils on the same Python
   (:doc:`../reference/limits`).

Where are the design decisions?
   In the DocOdin Discussions, ``docs/dod``.  :doc:`../development/dod-process` lists them.
