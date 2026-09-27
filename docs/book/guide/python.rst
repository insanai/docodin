.. _python:

=====================
docodin from Python
=====================

There are two ways to use docodin from Python.  The first is docutils' own API, which
docodin implements: nothing in your program changes.  The second is ``publish_native``
and its helpers, which run docodin's native pipeline and give docutils' results without
running docutils' Python code.

The docutils API
================

When docodin's docutils package is active (:doc:`installation`), ``import docutils`` is
docodin, and every docutils function works as documented by docutils:

.. code-block:: python

   from docutils.core import publish_parts

   parts = publish_parts(source, writer="html5",
                         settings_overrides={"report_level": 4})
   print(parts["body"])

The ``docodin`` package also offers docutils' publishing functions with docodin's parser,
for programs that use an installed docutils:

.. code-block:: python

   import docodin

   html = docodin.publish_string(source, writer="html5")
   parts = docodin.publish_parts(source, writer="latex")
   doctree = docodin.publish_doctree(source)
   docodin.publish_file(source_path="in.rst", destination_path="out.html", writer="html5")

They take the arguments of their docutils namesakes (``writer_name`` is accepted for
``writer``) and pass ``parser=docodin.Parser()``.  ``docodin.parse(text)`` parses into a
new document without applying transforms, which is useful for inspecting the raw tree.

``docodin.Parser`` is a drop-in ``docutils.parsers.rst.Parser``.  Give it wherever
docutils accepts a parser:

.. code-block:: python

   from docutils.core import publish_string
   import docodin

   output = publish_string(source, parser=docodin.Parser(), writer="html5")

To make every parse in the process use docodin's engine without replacing the installed
docutils package, patch it once:

.. code-block:: python

   import docodin

   docodin.patch_docutils()      # docutils' Parser.parse and RSTStateMachine.run
   assert docodin.is_patched()
   docodin.unpatch_docutils()

Publishing natively
===================

``docodin.publish_native`` is ``publish_string``, or ``publish_parts`` with
``parts=True``, run by the native pipeline: the standalone reader, the reStructuredText
parser, the transforms and a native writer.

.. code-block:: python

   import docodin

   html = docodin.publish_native(source, writer="html5")          # bytes
   parts = docodin.publish_native(source, writer="latex", parts=True)
   out = docodin.publish_native(source, "guide.rst", writer="xml",
                                settings_overrides={"output_encoding": "unicode"})

- The native writers are ``pseudoxml``, ``xml``, ``html5`` (also ``html`` and
  ``xhtml``), ``latex`` and ``xetex``.  Other writers are published by docutils.
- ``settings_overrides`` takes docutils' settings, as ``publish_string`` does.  Messages
  go to the ``warning_stream`` setting, as in docutils: standard error by default, none
  for ``False``, a file for a path, or any object with ``write``.
- The result is what ``publish_string`` returns: bytes in ``output_encoding``, or a string
  when ``output_encoding`` is ``"unicode"``; with ``parts=True``, the parts dictionary.
- Errors are docutils' exceptions: ``docutils.utils.SystemMessage`` when a message
  reaches ``halt_level``, ``UnicodeEncodeError`` when the output encoding cannot encode
  the output, and whatever docutils raises for the document, with the same class and
  message.

Two helpers return text directly:

.. code-block:: python

   page = docodin.render_html(source)                     # the whole HTML page
   body = docodin.render_html(source, standalone=False)   # parts["body"]
   tex = docodin.render_latex(source, use_latex_toc=False)

Keyword arguments other than ``standalone`` and ``native_only`` are settings overrides.

Documents that need Python
--------------------------

When a document uses a feature for which docutils calls a Python library, for example a
``code`` directive with a language (Pygments) or a scaled image (PIL), the native
pipeline cannot produce docutils' result.  ``publish_native`` then publishes the document
with the importable docutils, with the same arguments, so the result is still docutils'.
To find such documents instead, pass ``native_only=True``:

.. code-block:: python

   try:
       html = docodin.publish_native(source, writer="html5", native_only=True)
   except docodin.NeedsPythonError as error:
       for need in error.needs:
           print(need.feature, need.detail, need.line, need.text)

Each ``docodin.PythonNeed`` has ``feature`` (``pygments``, ``pil``, ``url``, ``codec``,
``parser``, ``mathml-converter`` or ``writer``), ``detail`` (the language, image, URL,
codec, parser, converter or writer), ``source``, ``line`` and an explanation in ``text``.
:doc:`../internals/python-needs` lists exactly when each need arises.

What the native path does not see
---------------------------------

Directives, roles and transforms registered in Python are unknown to the native
pipeline.  Publish documents that use them with the docutils API
(``docodin.publish_string`` or ``docutils.core``).

Lower-level access
==================

``docodin.version()`` returns the version of the loaded native library, and
``docodin.native()`` its ``ctypes`` wrapper, whose methods (``parse``, ``split_lines``,
``parse_inline``, ``publish``, ``educate``) are what the package itself uses.  They are
internal, and may change between releases.
