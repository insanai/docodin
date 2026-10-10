.. _python-needs:

==========================
Documents that need Python
==========================

docutils uses Python libraries for a few features.  Pygments, PIL and the other libraries
stay Python (DOD 9), except that native raster headers supply image dimensions.  Each stage
records a **Python need** (``doctree.Python_Need``: feature, detail, source and line)
wherever docutils would use a library, and the hosts publish such documents with
docutils.

Where docutils uses Python
==========================

.. list-table::
   :header-rows: 1
   :widths: 20 80

   * - Feature
     - When
   * - Pygments
     - The ``code`` directive and role (and ``include`` with ``:code:``) with a language
       other than ``text``, when ``syntax_highlight`` is not ``none``
       (``utils.code_analyzer.Lexer``).
   * - PIL
     - Image dimensions that the native header reader cannot supply: an unsupported or
       invalid format, metadata beyond its 64 KiB prefix, or an image exceeding
       89,478,485 pixels.  PNG, JPEG, GIF, BMP, TIFF and WebP headers are native, for
       HTML5 ``:scale:`` and figures' ``:figwidth: image``.  No pixels are decoded.
   * - ``urllib``
     - ``raw`` and ``csv-table`` with a ``:url:`` other than a local ``file:`` URL.
   * - codecs
     - An encoding other than UTF-8, UTF-8-sig, Latin-1 and ASCII for the source, included,
       raw and CSV files (UTF-16 and UTF-32 are also native for the output), and error
       handlers other than the native ones.
   * - parser modules
     - The ``include`` directive's ``:parser:`` option.
   * - external programs
     - ``math_output`` MathML with latexml, ttm, blahtexml or pandoc.
   * - writer modules
     - Writers other than pseudoxml, xml, html5, latex and xetex.
   * - front end
     - The options ``--config``, ``--record-dependencies`` and ``--dump-*`` of the
       ``docodin`` command.

What the pipeline does after a need
===================================

Until the first need, the native run is exactly docutils' run.  After it, the pipeline
goes on as docutils does without the library: code without highlighting (as with
``syntax_highlight: none``), no image sizes from PIL, with docutils' warnings.  The
differential tests use this to compare the native output with docutils in an
environment without Pygments, with PIL cases requiring fallback counted separately.
Native image-size cases must match the reference with Pillow installed.  The result
after a Python need is not used:

- ``publish.publish`` returns the needs with its results, and ``docodin_publish`` adds
  them to its result.
- ``docodin.publish_native``, ``render_html`` and ``render_latex`` publish the document
  with the importable docutils: ``publish_string`` or ``publish_parts`` with the same
  arguments.  With ``native_only=True`` they raise ``NeedsPythonError``, which lists the
  needs.
- The ``docodin`` command runs ``python -m docodin`` with the same arguments, standard
  streams and exit status; standard input it already read is passed on.  The Python is
  the first that imports docodin among ``$DOCODIN_PYTHON``, the ``python3`` or ``python``
  next to the program, and ``python3`` on the ``PATH``.  Without one, the command prints
  an Elm-style report for each need, with its source line and how to do without the
  library, and exits with status 1.

So native publishing is complete: every document gets docutils' result, with the Python
libraries that are installed.

Avoiding needs
==============

A document that should be published natively can avoid most needs:

- ``--syntax-highlight=none`` (``syntax_highlight: "none"``) publishes code without
  Pygments;
- PNG, JPEG, GIF, BMP, TIFF and WebP images normally supply dimensions natively;
  other formats can give both ``:width:`` and ``:height:``;
- figures can give an explicit ``:figwidth:``;
- files can be read as UTF-8.

The report of the native command names the relevant option for each need.
