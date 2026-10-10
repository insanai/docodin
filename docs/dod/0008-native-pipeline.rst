==============================================================================
DOD 8: The Native Pipeline: Reader, Transforms, Writers and Publisher
==============================================================================

:Authors: Vikrant Rathore
:State: committed
:Created: 2026-09-27
:Updated: 2026-10-11
:Discussion:
:Labels: native, tooling, compatibility

.. contents:: Contents
   :local:
   :depth: 1

Summary
=======

docodin publishes documents without Python through a native port of docutils' whole
publishing pipeline: the standalone reader with every standard directive and role, the
transformer with every standard transform, and the pseudo-XML, XML, HTML5, LaTeX and
XeLaTeX writers.  The output, the messages and the exit status are docutils', byte for
byte.  The pipeline powers the ``docodin`` command, ``docodin.publish_native`` and the
language server, and the stages are developed and tested one at a time against dumps of
docutils' own document trees.

Background
==========

The first native writers (DOD 2) produced their own HTML and LaTeX.  The output was
reasonable, but it was not docutils' output, so it was not a replacement: stylesheets,
templates, tests and downstream tools all expect docutils' markup.  To publish without
Python *and* keep the drop-in promise, every stage after the parser had to be ported
exactly.

Proposal
========

.. graphviz::
   :class: adaptive-diagram
   :align: center
   :caption: The publisher coordinates settings, reporting and failures across the native stages.
   :alt: Source and settings flow through parser, reader, ordered transforms and writer into output bytes, messages and an exit status; dependency needs are reported to the host.

   digraph native_pipeline {
   graph [bgcolor="white", pad="0.28", nodesep="0.4", ranksep="0.6", fontname="Helvetica", fontsize=17, fontcolor="#425574", color="#CBD5E1"];
   node [shape=box, style="rounded,filled", fontname="Helvetica", fontsize=16, margin="0.22,0.16", fillcolor="#EFF4FF", color="#B3C6F7", fontcolor="#18243D", penwidth=1.2];
   edge [fontname="Helvetica", fontsize=12, color="#526B97", fontcolor="#425574", arrowsize=0.75, penwidth=1.4];
   rankdir=TB;
   source [label="1  Source\nText + settings", group="left", fillcolor="#F4F6FA", color="#CDD5E2"];
   parse [label="2  rst.parse_text\nParse tree", group="middle"];
   reader [label="3  Native reader\ndoctree.Doc\nDocument registry", group="right"];
   transforms [label="4  Transforms\nResolve + validate", group="right"];
   writer [label="5  Writer\nOutput + parts", group="middle"];
   output [label="6  Publish result\nBytes + messages\nExit status", group="left", fillcolor="#E5F5EE", color="#8DC9B0"];
   {rank=same; source; parse; reader;}
   {rank=same; output; writer; transforms;}
   source -> parse -> reader;
   reader -> transforms;
   output -> writer -> transforms [style=invis, weight=100];
   transforms -> writer [constraint=false];
   writer -> output [constraint=false];
   source -> output [style=invis, weight=100];
   parse -> writer [style=invis, weight=100];
   needs [label="Python needs collected\nHost may publish with Python", fillcolor="#FFF3E6", color="#E3BB86"];
   output -> needs [style=dashed, label="dependency needed"];
   }


Stages
------

1. **Reader** (``odin/reader``): ``reader.parse(text, settings, source_path) -> ^Doc``.
   ``Parser.parse`` into ``new_document``, as a port of ``python/docodin/builder.py``:
   tree building, registration, section nesting, ``document.current_line`` bookkeeping
   and a ``StringList`` port.  It has the native directive and role registry: the
   localised directive and role names of ``docutils.parsers.rst.languages`` with the
   English fallback and docutils' lookup messages, ``parse_directive_block`` with the
   option converters, and every standard directive and role.  ``csv-table`` and ``raw``
   read files and ``file:`` URLs natively.  ``include`` works as in docutils: the
   parser's include hook lets the host dry-run the directive when the parser meets it,
   the parser inserts the lines after the directive block and parses them in the same
   state machine, and the host later runs the directive without inserting again.
2. **Transforms** (``odin/transforms``): ``transforms.apply(^Doc)`` runs the reader,
   parser and writer transforms in docutils' priority order, with docutils' message texts
   and levels.  The transformer has docutils' queue (priority, then insertion order) and
   every standard transform: universal, references, frontmatter, parts, misc,
   writer_aux, components and peps.
3. **Writers** (``odin/writers``): ``writers.write(doc, writer, settings) -> (output,
   parts, err)`` with ports of ``pseudoxml``, ``docutils_xml``, ``html5_polyglot``,
   ``latex2e`` and ``xetex`` and their ``publish_parts`` parts.  They use output buffers,
   dispatch tables indexed by ``doctree.Tag``, and docutils' templates and stylesheets
   embedded with ``#load``.  Where docutils raises, ``err`` names the Python exception.
4. **Publisher** (``odin/publish``): ``publish.publish(text, source_path, writer,
   overrides) -> (output, parts, messages, exit_status, err, needs)``, which is
   ``publish_string`` and ``publish_parts`` for the standalone reader and the
   reStructuredText parser.  Settings start from docutils' defaults for the writer (a
   table of every setting with its Python value, ``None`` included), and overrides given
   as strings are converted as docutils' validators convert command-line values.  The
   reporter collects the messages in the format of ``system_message.astext()``.  The
   first message at ``halt_level`` stops the run as docutils' ``SystemMessage`` does, and
   so does an exception docutils would raise.  ``exit_status`` is that of
   ``publish_cmdline``.  ``publish.read_document`` runs the same settings, reader and
   transforms without a writer and returns the document and its messages as records
   (DOD 14 uses it).

Supporting packages: ``odin/math`` (``math2html`` and ``latex2mathml`` with docutils'
exact output, trace messages and errors) and ``odin/text`` (smart quotes, every language
and attribute mode).

Development against docutils: the doctree interchange
-----------------------------------------------------

Each stage was ported and tested before the stage in front of it existed natively.
``scripts/doctree_json.py`` runs docutils 0.22.4 and dumps the document as JSON at one of
three stages (``parsed``: before any transform, with the transformer queue; ``transformed``:
before the writer; ``output``: with the writer's output and parts).
``doctree.load_json`` loads a dump into a ``Doc`` and ``doctree.dump_json`` writes one
back byte for byte.  The book's chapter on the native pipeline specifies the format.

The approximate writers removed
-------------------------------

Once the exact writers passed their differential tests, the earlier writers in
``odin/rst`` were deleted, together with their tests.

Alternatives
============

- **Keep the approximate writers** as a "native style".  Two HTML outputs would mean two
  sets of bugs and a promise broken in the default path.
- **Port only the writers** and keep Python for the reader and transforms.  The
  ``docodin`` command would still need Python for every document.
- **Generate Odin from docutils' Python.**  The code relies on Python's dynamic
  features throughout; a hand port with differential tests was more reliable.

Compatibility and fidelity
==========================

The pipeline's output is docutils' output.  Two documented differences remain: in the
native command and in ``python -m docodin`` the writer name ``html`` means html5 (it
means html4css1 in docutils), and the native command reads no configuration files (with
``--config`` it runs through Python, see DOD 9).  Directives, roles and transforms that
are registered in Python are not seen by the native pipeline; such documents are
published with the docutils package.

Verification
============

- The pseudo-XML of each stage is compared with docutils on the conformance corpus and
  on generated documents (``tests/fuzz_differential.py``).
- ``tests/native_reader_differential.py``, ``native_transforms_differential.py``,
  ``native_writers_differential.py`` and ``native_math_differential.py`` compare each
  stage with docutils' dumps.  The writers are compared byte for byte on docutils'
  functional tests with their settings (and against ``test/functional/expected``), on
  the functional inputs and ``docs/**/*.rst`` with several settings per writer, and on
  generated documents.
- ``tests/native_publish_differential.py`` compares ``publish`` end to end with
  ``Publisher.publish``: output, parts, the warning stream, the failure report and the
  exit status, including generated documents under random settings.
- ``tests/test_native_cli.py`` compares the ``docodin`` command with ``python -m
  docutils``.
- ``odin test`` in ``odin/doctree``, ``odin/reader``, ``odin/transforms``,
  ``odin/writers`` and ``odin/publish``.

Outcome
=======

Implemented in docodin 0.1.0: the writers first ("Add the native pseudo-XML and Docutils
XML writers", "Add the native HTML5 writer", "Add the native LaTeX and XeTeX writers"),
then the transforms, the reader, the publisher, and finally "Rewrite the docodin command
on the native publisher" and "Remove the approximate native writers".  docodin 0.2.0
added ``publish.read_document``.

References
==========

- ``odin/reader``, ``odin/transforms``, ``odin/writers``, ``odin/publish``,
  ``odin/math``, ``odin/text``, ``scripts/doctree_json.py``.
- DOD 9 (documents that need Python libraries).
