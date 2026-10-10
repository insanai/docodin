.. _python-api:

====================
Python API reference
====================

The ``docodin`` package imports nothing heavy when it is imported: docutils is loaded
only when a function needs it, so the shim can still be installed first.  Importing
``docodin`` registers the shim as a fallback for ``import docutils`` (``enable``).

The docutils API itself (``docutils.core``, ``docutils.nodes`` and the rest) is
docutils', and docutils' documentation describes it.

docodin
=======

Versions
--------

``docodin.__version__``
   The package version, for example ``"1.0.0b1"``.  It is the version of the native
   library and programs too (``tests/test_release.py`` checks it).

``docodin.version() -> str``
   The version of the loaded native library.

Publishing with the docutils package
------------------------------------

These call the functions of the same name in ``docutils.core``, with
``parser=docodin.Parser()``.  ``writer_name`` is accepted as a synonym of ``writer``, and
``parser_name`` is ignored.

``docodin.publish_string(source, source_path=None, **kwargs)``
   Like ``docutils.core.publish_string``.

``docodin.publish_parts(source, source_path=None, **kwargs) -> dict``
   Like ``docutils.core.publish_parts``.

``docodin.publish_doctree(source, source_path=None, **kwargs)``
   Like ``docutils.core.publish_doctree``.

``docodin.publish_file(**kwargs)``
   Like ``docutils.core.publish_file``.

``docodin.parse(text, source="<string>", settings=None, **settings_overrides)``
   Parses ``text`` into a new ``docutils.nodes.document`` without applying transforms.
   Without ``settings``, docutils' default parser settings are used, with the keyword
   arguments applied.

The parser
----------

``docodin.Parser``
   A subclass of ``docutils.parsers.rst.Parser`` that parses with the native engine.  It
   falls back to docutils' Python parser when the parser's state classes or inliner are
   not the stock ones, when a stock state was patched, and with ``DOCODIN_NATIVE=0``.  On
   an installed docutils, the stock states are recorded when ``docodin.parser`` is first
   imported, so a patch applied before that import is not seen (DOD 7).
   ``docodin.OdinRSTParser`` is its name from docodin 0.1.

``docodin.patch_docutils()``
   Replaces ``docutils.parsers.rst.Parser.parse`` and
   ``docutils.parsers.rst.states.RSTStateMachine.run`` process-wide, so everything built
   on the loaded docutils parses with docodin, with the same fallback as
   ``docodin.Parser``.  Calling it again does nothing.

``docodin.unpatch_docutils()``
   Undoes ``patch_docutils``.

``docodin.is_patched() -> bool``
   Whether ``patch_docutils`` is in effect.

Publishing natively
-------------------

``docodin.publish_native(source, source_path=None, writer="html5", settings_overrides=None, *, parts=False, docutils_dir=None, native_only=False)``
   ``docutils.core.publish_string`` (with ``parts=True``, ``publish_parts``) run by the
   native pipeline.

   ``source``
      The reStructuredText, as ``str`` or ``bytes`` (decoded with ``input_encoding``).
   ``source_path``
      The source's path, used in messages and for relative paths.
   ``writer``
      ``pseudoxml``, ``xml``, ``html5`` (``html``, ``xhtml``), ``latex`` or ``xetex``
      natively; other writers through docutils.
   ``settings_overrides``
      docutils settings, as ``publish_string`` takes them (:doc:`settings`).
   ``parts``
      Return the ``publish_parts`` dictionary instead of the output.
   ``docutils_dir``
      The docutils package directory used in messages and stylesheet paths (default:
      that of the importable ``docutils``).
   ``native_only``
      Raise ``NeedsPythonError`` instead of publishing a document that needs a Python
      library with docutils.

   Returns the output as ``publish_string`` returns it (``bytes`` in
   ``output_encoding``, or ``str`` for ``"unicode"``), or the parts.  Raises
   ``NeedsPythonError`` (with ``native_only``), ``docutils.utils.SystemMessage`` (a
   message reached ``halt_level``), ``UnicodeEncodeError`` (the output encoding cannot
   encode the output), or what docutils raises for the document, with the same class and
   message.

``docodin.render_html(source, *, standalone=True, native_only=False, **settings_overrides) -> str``
   HTML5 through ``publish_native``: the whole document, or ``parts["body"]`` with
   ``standalone=False``.

``docodin.render_latex(source, *, standalone=True, native_only=False, **settings_overrides) -> str``
   LaTeX through ``publish_native``: the whole document, or ``parts["body"]`` with
   ``standalone=False``.

``docodin.NeedsPythonError``
   A ``RuntimeError`` raised with ``native_only=True`` when the document needs Python
   libraries.  ``needs`` is the list of ``PythonNeed``.

``docodin.PythonNeed``
   A named tuple: ``feature`` (``pygments``, ``pil``, ``url``, ``codec``, ``parser``,
   ``mathml-converter`` or ``writer``), ``detail`` (the language, image, URL, codec,
   parser, converter or writer), ``source`` (``""`` if unknown), ``line`` (0 if unknown)
   and ``text`` (the explanation).  ``str(need)`` is ``source:line: text``.

Internals
---------

``docodin.native()``
   The ``ctypes`` wrapper of the native library, loaded on first use.  Its methods are
   used by the package itself and are not a stable API.

docodin.shim
============

``docodin.shim.enable()``
   Registers docodin's docutils as a fallback: ``import docutils`` finds it only when no
   docutils is installed.  ``import docodin`` calls it.

``docodin.shim.install_shim(force=False)``
   With ``force=True``, docodin's docutils takes precedence over an installed docutils,
   and modules of a docutils already imported are dropped (objects created from them
   keep their classes).  Without ``force``, the same as ``enable``.

``docodin.shim.uninstall_shim()``
   Removes the import hook and drops docodin's ``docutils`` modules.

``docodin.shim.is_active() -> bool``
   Whether the loaded ``docutils`` is docodin's implementation.

docodin.sphinx
==============

A Sphinx extension: ``extensions = ["docodin.sphinx"]``.

``OdinSphinxRSTParser``
   Sphinx's ``RSTParser`` with docodin's native engine; it applies ``rst_prolog`` and
   ``rst_epilog`` and falls back to Sphinx's parser in the cases of
   ``docodin.Parser``.

``docodin_gc_tuning`` (configuration value, default ``False``)
   ``True`` tunes the garbage collector for the build (:doc:`../guide/sphinx`).

The extension is marked safe for parallel reading and writing.

docodin.sphinx_build
====================

``main(argv=None) -> int``
   The entry point of ``docodin-sphinx-build``: installs the shim, tunes the collector
   when ``DOCODIN_GC=tuned``, and runs Sphinx's ``main``.

``tune_garbage_collection()``
   Raises the collector's thresholds to ``GC_THRESHOLDS`` (``(50000, 20, 100)``) and
   makes every Sphinx application created afterwards collect and freeze its objects
   when it has started (its builder is initialised by then) and when the environment is
   updated.

docodin.conf
============

Helpers that read a Sphinx ``conf.py`` without Sphinx.

``find_conf_py(start_path=None)``
   The nearest ``conf.py`` in ``start_path`` (default: the current directory) or its
   parents, or ``None``.

``load_conf_py(conf_path) -> dict``
   The variables of a ``conf.py``: executed in an isolated namespace, or, if that fails
   (for example because an extension is not installed), read statically from its
   literal assignments.

``get_metadata(start_path=None) -> dict``
   ``title`` (``html_title`` or ``project``), ``project``, ``author``, ``version``,
   ``release``, ``copyright`` and ``conf_path`` of the nearest ``conf.py``.
