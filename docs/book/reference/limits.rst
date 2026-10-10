.. _limits:

============
Known limits
============

This chapter states what the 1.0.0b1 beta supports, and lists every known difference
from docutils 0.22.4 and every limit of the native tools, so that none of them is a
surprise.  DOD 19 records why the contract has this shape.

What the beta supports
======================

Native publishing
   ``docodin``, ``docodin pdf`` and ``docodin.publish_native`` turn reStructuredText into
   HTML5, LaTeX, XeLaTeX, Docutils XML and pseudo-XML with docutils' standard reader,
   transforms and writers: docutils' output, messages and exit status.  Documents that
   need a Python library are handed to docutils (:doc:`../internals/python-needs`).
The native checker
   ``docodin-check`` and ``docodin check`` report the parser's messages, explained or in
   docutils' format.
The language server
   ``docodin-lsp``'s documented features (:doc:`../guide/editors`), one document at a
   time.
Native book and site builds
   ``docodin book build`` builds the HTML site of a Sphinx project whose ``conf.py`` uses
   the documented values (:doc:`settings`) and whose sources keep to the markup subset of
   :doc:`../development/documentation`.  It reads ``conf.py`` without running it, runs no
   Sphinx extensions, and writes its own theme rather than Sphinx's HTML.
LaTeX and PDF
   The LaTeX and XeLaTeX writers are native.  PDFs need an external TeX engine
   (``pdflatex``, ``xelatex`` or ``lualatex``, from TeX Live or MacTeX), which docodin
   does not include; ``docodin pdf`` and ``docodin book build`` run it.
The Python, docutils and Sphinx integrations
   docodin's docutils package, ``docodin-sphinx-build``, ``DOCODIN_DOCUTILS=1``, the
   ``docodin.sphinx`` extension and ``patch_docutils`` are supported within their
   measured bounds: docutils' and Sphinx's test suites, and those of the extensions and
   themes in :doc:`compatibility`, give the same results as with docutils.  Full parity
   with every Sphinx extension and project is a goal, not a promise.  Check your own
   project as :doc:`../guide/sphinx` shows, and report any difference.

Platforms
   The release gate (:doc:`../development/releasing`) has verified 1.0.0b1 on macOS
   arm64, with the PDF books, and on Linux x86-64 under CPython 3.12.  The Linux wheel
   is ``manylinux_2_34_x86_64`` and needs glibc 2.34 or later (Ubuntu 22.04, Debian 12,
   RHEL 9 or newer).  Windows, other CPU architectures and other C libraries (such as
   musl) are not verified.

Differences from docutils
=========================

Stock-parser import order
   When integrating with an installed stock docutils, import ``docodin.parser`` before
   an extension patches docutils' parser states. The snapshot used to detect grammar
   changes is taken at that import; earlier patches may otherwise look like the stock
   grammar. ``DOCODIN_NATIVE=0`` explicitly selects Python parsing. This caveat concerns
   the stock-parser integration rather than the shim's startup path.

Two nested-include cases
   In about 20,000 generated documents, two differ in line numbers.  Both have an
   ``include`` directive two directive levels deep, with more content after it in the
   outer directive.  The output is otherwise the same.

The ``html`` writer name
   In the native ``docodin`` command and in ``python -m docodin``, ``html`` means the
   ``html5`` writer.  In docutils it means ``html4css1``.  Name the writer ``html4`` (with
   the Python command) to get docutils' old HTML writer.

Nesting depth
   The native parser limits nesting to 160 levels (``MAX_NESTING``), and the native math
   converters to 1000 (``MAX_DEPTH``).  Where docutils would fail with Python's
   ``RecursionError``, docodin reports an error message ("Nesting too deep; content
   ignored.") and goes on.

Unicode version
   The native engine's character tables are generated from Unicode 16 (CPython 3.14's
   ``unicodedata``) and are used whatever the Python: in the native tools, and in the
   native parser under every Python.  docutils uses the Unicode data of the Python it runs
   on, which is older before Python 3.14 (Unicode 15.0 in 3.12, 15.1 in 3.13).  For
   characters whose category or case changed since, inline-markup recognition (and, in
   the native tools, generated ids) can differ from docutils on that Python.  The
   differential tests run under CPython 3.14 for this reason.

Limits of the native pipeline
=============================

Python extensions
   Directives, roles, transforms and writers registered in Python are not seen by the
   native pipeline.  Publish documents that use them with the docutils package
   (``docodin.publish_string``, ``docutils.core``, Sphinx).

Python libraries
   The native pipeline does not reimplement Pygments, PIL, ``urllib``, Python's codecs,
   parser and writer modules or external MathML converters.  Documents that need them are
   published by docutils automatically (:doc:`../internals/python-needs`).  Without a
   Python that has docodin, the native command reports what needs Python and exits with
   status 1.

Image dimensions
   ``odin/imageinfo`` reads PNG, JPEG, GIF, BMP, TIFF and WebP headers natively for image
   scaling and figure widths.  It reads at most 64 KiB and allocates no pixels.  Other
   formats, longer metadata, invalid headers and images larger than 89,478,485 pixels
   keep the Pillow fallback.  Missing files, non-file URIs, video images and disabled
   file insertion are diagnosed natively, with the messages of Docutils with Pillow.

Writers
   The native writers are pseudo-XML, XML, HTML5, LaTeX and XeLaTeX.  The manual page,
   ODT, S5, PEP and HTML4 writers are Python only.

Configuration files
   The native ``docodin`` command does not read ``docutils.conf`` or the other standard
   configuration files.  With ``--config`` it runs the document through Python, which
   reads them.

Book sources
   ``docodin book build`` reads every source as UTF-8.  A source that cannot be read or
   decoded stops the build with a SEVERE report and status 1, and nothing is written.

The shared library and threads
   The Python package calls the native library in the calling thread.  Each thread has
   its own arena; when its outermost call returns, the arena's one kept block (at most
   4 MiB) goes to a process-wide cache of at most 8 blocks, and a thread's next call takes
   a block from that cache.  Between calls a thread owns no native memory, so a host that
   creates and retires threads keeps at most 32 MiB cached, however many threads it has
   run.  Result buffers belong to the caller (``docodin_free``).  The standalone
   programs do not use this cache.

Limits of the checker
=====================

``docodin-check`` reports the parser's messages only.  It does not run directives, roles
or transforms, so it does not report unknown directives or roles, missing include files,
unknown or duplicate targets.  Publish the document, or use ``docodin-lsp``, for those.

Limits of the language server
=============================

- It works on one file at a time: cross-document ``:ref:`` and ``:doc:`` are not
  resolved.
- Included files are read from disk.
- Unknown languages of ``code`` directives are not reported (docutils asks Pygments).
- Sphinx's roles and directives, and those of extensions, are unknown to docutils; the
  ``sphinx``, ``knownRoles`` and ``knownDirectives`` settings silence those messages.
- There is no rename.

Limits of source spans
======================

Nodes built from lines that ``include`` inserted are not in the input; they get an empty
span at the end of the inserting directive.  Table entries of one row, and rows with
cells spanning several rows, may overlap.

The garbage-collector tuning
============================

``DOCODIN_GC=tuned`` and ``docodin_gc_tuning = True`` can change the output of Sphinx
projects that have duplicate labels or repeated generated ids, with docutils as with
docodin.  It is therefore off by default (:doc:`../guide/sphinx`).
