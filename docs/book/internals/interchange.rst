.. _interchange:

=======================
The doctree interchange
=======================

The native transforms and writers were developed and are tested against docutils without
the native parser in between.  ``scripts/doctree_json.py`` runs docutils 0.22.4 and dumps
the document tree, with everything around it, to JSON.  ``doctree.load_json`` loads a dump
into a ``Doc``, and ``doctree.dump_json`` writes one.  This chapter specifies the format.

Making a dump
=============

.. code-block:: console

   $ PY="uv run --no-project --python 3.14 --with docutils==0.22.4 python"
   $ $PY scripts/doctree_json.py doc.rst --writer html5 --stage parsed \
         --set report_level=1 -o doc.json

The script drives docutils' ``Publisher`` the way ``publish`` does, with
``_disable_config`` set and the warning stream captured.  It dumps one of three stages:

``parsed``
   After ``reader.read`` and ``Transformer.populate_from_components``, before any
   transform.  The queue holds the reader, parser and writer transforms and the
   ``pending`` transforms of directives.
``transformed``
   After ``apply_transforms``, before the writer.
``output``
   ``transformed`` plus the writer's output and ``publish_parts``.

.. code-block:: text

   load_json :: proc(data: string, allocator := context.allocator) -> (^Doc, Load_Error)
   dump_json :: proc(doc: ^Doc, allocator := context.allocator) -> string
   Load_Error :: union { json.Error, Format_Error } // Format_Error{message}

A dump is written with ``json.dumps(dump, sort_keys=True, indent=1, ensure_ascii=False)``
and a final newline.  ``dump_json`` writes the same text, so a loaded dump dumps back byte
for byte.  A ``Doc`` that was not loaded from JSON dumps its ``Settings`` fields, and its
``expected`` holds its own ``pformat``.

Top-level keys
==============

.. list-table::
   :header-rows: 1
   :widths: 22 78

   * - Key
     - Content
   * - ``format``
     - ``"docodin-doctree/1"``
   * - ``stage``
     - ``"parsed"``, ``"transformed"`` or ``"output"``
   * - ``input``
     - ``{source_path, writer, overrides}`` of the run
   * - ``tree``
     - the ``document`` node record
   * - ``detached``
     - ``[{parent, node}]``: subtrees that are referenced but not in the tree
   * - ``registry``
     - the ``document`` registry
   * - ``transformer``
     - ``{queue, serialno}``
   * - ``reporter``
     - the reporter state
   * - ``settings``
     - every JSON-serialisable attribute of ``document.settings``
   * - ``expected``
     - docutils' results: ``pformat`` (``document.pformat()``), plus ``output`` and
       ``parts`` at stage ``output``

Node records
============

Each record has a ``tag``: the class name, or ``#text``.  Optional fields are omitted at
their default:

``source`` and ``line``
   Omitted for ``None``.
``document``
   ``true`` when ``_document`` is set.
``text``
   The data of a Text node.
``rawsource``
   The node's raw source.
``attributes``
   An object mapping each name to its value.  A value is a string, an integer, a
   boolean, null, a list of strings, or ``{"float": repr}``.  The class's list attributes
   are left out when they are empty.
``deleted``
   The class's list attributes that were deleted.
``referenced`` and ``resolved``
   ``true`` when set.
``internal``
   Python state kept outside ``attributes``: ``indent`` (of ``line``),
   ``indirect_reference_name``, and ``expect_referenced_by_id`` and
   ``expect_referenced_by_name`` as ``[[name, node]]``.
``pending``
   ``{transform, default_priority, details}``.  ``transform`` is the qualified class
   name.  A detail value is a plain value as above, ``{"node": i}`` or
   ``{"nodes": [i, ...]}``.
``children``
   The child records.

Node references
---------------

A reference to a node is its record index.  The tree is numbered in preorder, and the
detached subtrees are numbered after it.  Record ``i`` loads as the handle
``Node(i + 1)``.  A node outside the tree gets a number at its first reference, together
with its subtree and after its stale parent.  References are made in this order:

1. The tree records, in preorder.  Within a record, the ``internal`` maps come first
   (``_id``, then ``_name``), then the ``pending`` details by key.
2. ``registry.ids``, ``substitution_defs``, ``decoration``, then the name-to-nodes maps,
   then the node lists.
3. The transformer queue.
4. ``reporter.written``.
5. The detached records in turn: each record's parent comes before its node.

A node has one parent.  The dump therefore lists a detached node's child only when the
child's ``parent`` is that node; a child moved elsewhere is left out.  A stale parent of a
class that ``nodes.node_class_names`` does not name is recorded as null; this covers the
plain ``nodes.Element`` containers of directives.

The registry
============

Ordered dictionaries are ``[[key, value]]`` lists in insertion order:

- ``ids``, ``substitution_defs``: ``[[name, node]]``;
- ``nameids``: ``[[name, id or null]]``;
- ``nametypes``: ``[[name, bool]]``;
- ``substitution_names``: ``[[name, name]]``;
- ``id_counter``: ``[[prefix, n]]``;
- ``refnames``, ``refids``, ``footnote_refs``, ``citation_refs``: ``[[name, [nodes]]]``.

The node lists are ``indirect_targets``, ``autofootnotes``, ``autofootnote_refs``,
``symbol_footnotes``, ``symbol_footnote_refs``, ``footnotes``, ``citations``,
``parse_messages`` and ``transform_messages``.  The scalars are ``autofootnote_start``,
``symbol_footnote_start``, ``decoration``, ``current_source`` and ``current_line``.

The transformer
===============

``queue`` lists ``[priority string, transform, pending node or null, kwargs]`` in the
order docutils applies them, sorted by the priority string (``"%03d-%03d" % (priority,
serial)``).  ``Doc.pending_queue`` holds every entry, including the component transforms,
which have no node.

The reporter
============

The reporter state has these fields:

- ``source``, ``report_level``, ``halt_level``, ``debug``, ``max_level``;
- ``observers``: ``note_parse_message`` or ``note_transform_message``;
- ``written``: ``[{level, node, text}]``, the messages written to the warning stream;
- ``source_lines``: the line map behind ``Reporter.get_source_and_line``, or null.  It
  holds ``input_offset``, ``line_offset``, and ``runs`` of ``[source, first offset,
  count]`` built from the state machine's ``input_lines``.  The loaded reporter answers
  ``get_source_and_line`` from this map the way ``StateMachine.get_source_and_line``
  does.

Settings
========

The loader converts the fields of ``Settings`` from the dump.  ``None`` and ``False``
become ``""``, 0, ``false`` or an empty list.  A ``smart_quotes`` value of ``"alt..."`` sets
``smart_quotes_alt``.  ``warning_stream`` becomes ``.Collect``.  The complete settings
object is kept in ``Doc.interchange`` for ``dump_json``, together with ``stage``,
``input`` and ``expected``.

Limits
======

A float attribute loads as its repr string, which is the document tree's representation
of floats, so it dumps back as a string; such attributes do not occur in the corpus.  The
script refuses anything else it cannot represent: other attribute or detail types,
unknown instance state, and a tree node that is shared or has a stale parent.

Tests
=====

``odin/doctree/tests/interchange_test.odin`` loads every dump in
``fixtures/interchange``.  It compares ``pformat`` with ``expected.pformat`` and requires
``dump_json`` to reproduce the file.

``scripts/doctree_interchange_fixtures.py --docutils-src DIR`` regenerates these
fixtures: about 3.5 MB of small docutils functional inputs and documentation, plus fuzz
documents.  The docutils installation directory is written as ``<docutils>``
(``doctree_json.py --portable``), so the fixtures do not depend on the machine.  With
``--corpus OUT`` it dumps every functional input, every ``docs/**/*.rst`` file and 300
fuzz documents, with each writer and at each stage; the corpus test then runs with
``DOCTREE_INTERCHANGE_DIR=OUT odin test odin/doctree/tests``.
