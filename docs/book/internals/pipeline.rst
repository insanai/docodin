.. _pipeline:

===================
The native pipeline
===================

The native pipeline publishes a document as docutils' ``publish_string`` and
``publish_parts`` do, without Python: the standalone reader, the reStructuredText parser,
the transforms and the writers, with docutils' output, messages and exit status, byte
for byte (DOD 8).  It serves the ``docodin`` command, ``docodin-check``'s sibling
``docodin check``, ``docodin.publish_native`` and the language server.

.. code-block:: text

   text --rst.parse_text--> rst.Tree --reader--> doctree.Doc --transforms--> doctree.Doc
        --writers.write--> output, parts
   (publish.publish drives the stages: settings, reporter, halting, exit status, needs)

Stage 1: the reader
===================

``reader.parse(text, settings, source_path) -> ^Doc`` (``odin/reader``) runs
``Parser.parse`` into ``new_document``.  It is a port of ``python/docodin/builder.py``:
tree building, registration, section nesting, ``document.current_line`` bookkeeping and
a ``StringList`` port.

- **Directives and roles.**  The native registry has every standard directive and role,
  with the localised names of ``docutils.parsers.rst.languages`` (and the English
  fallback, with docutils' lookup messages), ``parse_directive_block`` with the option
  converters, and docutils' error messages.  The directives live in ``dir_*.odin``
  (body elements, images, include, meta, miscellaneous, parts, tables) and the roles in
  ``roles.odin``.
- **Files.**  ``csv-table`` and ``raw`` read files and local ``file:`` URLs natively.
  ``odin/imageinfo`` reads bounded raster headers for ``:figwidth: image`` and the HTML5
  writer's ``:scale:`` without decoding pixels.  Unsupported headers record a Python
  need (:doc:`python-needs`).
- **include.**  The parser's include hook (``rst.Parser.include_hook``) lets the reader
  run the directive dry when the parser meets it; the parser inserts the lines after the
  directive block and parses them in the same state machine (``rst.insert_input``).  The
  reader inserts them into its input lines at the same place and later runs the directive
  without inserting again.  The standard include files (``<isonum.txt>`` and the others)
  are embedded (``odin/reader/std_include.odin``): a path below a
  ``parsers/rst/include`` directory that is not on disk is read from the embedded copy.
- **The parse tree.**  ``reader.parse_document`` can keep the parse tree when it is given
  a ``tree_allocator`` (the language server uses it, with spans).

Stage 2: the transforms
=======================

``transforms.apply(^Doc)`` (``odin/transforms``) runs the standard reader, parser and
writer transforms in docutils' priority order.  The transformer is docutils': a queue
ordered by priority, then by insertion, with the ``pending`` transforms that directives
queue.  Every standard transform is ported: universal (decorations, exposed internals,
messages, stripped comments and classes, smart quotes, validation), references (substitutions,
footnotes, targets, anonymous and indirect references, dangling references), frontmatter
(document title, section subtitles, docinfo), parts (``sectnum``, ``contents``), misc
(class, transitions), writer_aux (admonitions), components (filter) and peps.  Language
modules are loaded as docutils loads them, with the same messages.  Where docutils
raises, the transform returns an error that names the Python exception.

Stage 3: the writers
====================

``writers.write(doc, writer, settings) -> (output, parts, err)`` (``odin/writers``) ports
``pseudoxml``, ``docutils_xml``, ``html5_polyglot``, ``latex2e`` and ``xetex``, with their
``publish_parts`` parts.  :doc:`writers` describes them.

Stage 4: the publisher
======================

``publish.publish(text, source_path, writer, overrides) -> (output, parts, messages,
exit_status, err, needs)`` (``odin/publish``) is ``publish_string`` and ``publish_parts``
for the standalone reader and the reStructuredText parser.

Settings
   The settings start from docutils' defaults for the writer: a table of every setting
   with its Python value, ``None`` included (:doc:`../reference/settings`).  The
   overrides apply in order.  A string for a setting that has a docutils validator is
   converted as the validator converts command-line values (``validate_threshold``,
   ``validate_boolean``, encodings with an error handler, comma-separated lists, and so
   on).  The transforms and writers read the settings as those of a loaded dump, which
   keeps Python's distinctions (``None`` against ``False`` against ``""``); the reader
   reads their ``doctree.Settings``.

Reporter
   Messages are collected as docutils' ``Reporter`` writes them, in the stderr format of
   ``system_message.astext()``.

Halting
   The first message at ``halt_level`` stops the run as docutils' ``SystemMessage``
   does, and so does an exception docutils would raise (a parse exception, a transform
   error, a writer error); the messages after it are dropped.

Exit status
   ``exit_status`` is that of ``publish_cmdline``: the highest message level plus 10 if
   it reached ``exit_status_level``, else 1 after an error.

Errors and output
   ``error_report`` gives docutils' report of a failure, and ``encode_output`` the
   output's bytes in ``output_encoding`` with its error handler.

Encodings
   ``publish`` decodes UTF-8, UTF-8-sig, Latin-1 and ASCII natively, and encodes the
   output also in UTF-16 and UTF-32.  Other codecs are Python needs.

The ``docodin`` command (``cmd/docodin``) and ``docodin_publish`` of the library
(``docodin.publish_native`` in Python) are built on ``publish``.

Reading without writing
-----------------------

``publish.read_document(text, source_path, writer, overrides, options) -> Read_Result``
runs the same settings, reader and transforms without the writer.  It returns the
transformed document; the messages written to the warning stream as records (level,
source, line, the message's text without the ``source:line: (LEVEL/n)`` head, and its
``system_message`` node); the error that stopped the run; the Python needs; and, with
``keep_tree``, the reader's parse tree (not after an ``include`` inserted lines).  The
language server is built on it.

Python needs
============

Where docutils would use a Python library, the stage records a Python need, and the
pipeline goes on as docutils does without the library.  ``publish`` returns the needs,
and the hosts publish such documents with docutils.  :doc:`python-needs` has the
details.

Verification
============

- The pseudo-XML of each stage is compared with docutils on the conformance corpus and on
  generated documents (``tests/fuzz_differential.py``).
- ``tests/native_reader_differential.py``, ``native_transforms_differential.py``,
  ``native_writers_differential.py`` and ``native_math_differential.py`` test each stage
  against docutils' dumps (:doc:`interchange`).
- ``tests/native_publish_differential.py`` compares ``publish`` end to end with docutils'
  ``Publisher.publish``: output, parts, the warning stream, the failure report and the
  exit status, on docutils' functional inputs and ``docs/**/*.rst`` with every writer and
  settings variants, and on generated documents under random settings (halt and exit
  status levels, command-line style strings).
- ``tests/test_native_cli.py`` compares the ``docodin`` command with ``python -m
  docutils``.
- ``odin test`` in ``odin/doctree``, ``odin/reader``, ``odin/transforms``,
  ``odin/writers`` and ``odin/publish``.
