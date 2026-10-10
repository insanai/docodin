.. _storage:

========================
Data-oriented storage
========================

docodin's native code keeps its trees in flat arrays, links them with integer handles,
and allocates from arenas.  This chapter describes the rules and the two trees: the parse
tree of ``odin/rst`` and the document tree of ``odin/doctree``.  DOD 4 records the
decision.

Principles
==========

.. graphviz::
   :class: adaptive-diagram
   :align: center
   :caption: Handles select dense hot arrays; optional data lives in side tables owned by the document.
   :alt: A tree-local node handle indexes kind, links and location arrays, with optional attributes and directive details in arena-owned side tables.

   digraph storage {
   graph [bgcolor="white", pad="0.28", nodesep="0.4", ranksep="0.6", fontname="Helvetica", fontsize=17, fontcolor="#425574", color="#CBD5E1"];
   node [shape=box, style="rounded,filled", fontname="Helvetica", fontsize=16, margin="0.22,0.16", fillcolor="#EFF4FF", color="#B3C6F7", fontcolor="#18243D", penwidth=1.2];
   edge [fontname="Helvetica", fontsize=12, color="#526B97", fontcolor="#425574", arrowsize=0.75, penwidth=1.4];
   rankdir=TB;
   owner [label="Document arena\nOwns arrays and temporary text", fillcolor="#DBE7FF", color="#7DA1ED"];
   handle [label="Node handle: 7\ndistinct u32", fillcolor="#E5F5EE", color="#8DC9B0"];
   subgraph cluster_hot {
    label="HOT FIELDS / STRUCT OF ARRAYS"; style="rounded"; bgcolor="#F7FAFF";
    kinds [label="kind[]\nsection | title | text\n..."];
    links [label="parent[]\nfirst[] / next[]\nInteger handles"];
    lines [label="line[] / spans[]\nSource locations"];
   }
   subgraph cluster_cold {
    label="COLD DATA / SIDE TABLES"; style="rounded"; bgcolor="#FAF8FF";
    attrs [label="Attributes / registry\nInterned strings", fillcolor="#EEE9FB", color="#C0AEE7"];
    details [label="Directive details\nPhrase references\nOnly when needed", fillcolor="#EEE9FB", color="#C0AEE7"];
   }
   source [label="Source buffer\nBorrowed text views", fillcolor="#F4F6FA", color="#CDD5E2"];
   owner -> handle [label="tree-local access"];
   handle -> kinds [label="checked index"];
   handle -> links [label="checked index"];
   handle -> lines [label="checked index"];
   kinds -> attrs [label="side-table index", style=dashed];
   links -> details [style=dashed];
   source -> details [label="text view", style=dashed];
   }


1. **Handles, not pointers.**  A node is a ``distinct u32`` index into its tree's arrays,
   and ``0`` is the null handle.  Parents, siblings and children are handles as well.
   Every access is bounds-checked, handles stay valid when arrays grow, and a handle
   cannot point into freed memory.
2. **Struct of arrays for hot fields.**  Traversals mostly read the kind and the links.
   These live in an ``#soa`` array, so a walk touches a few dense arrays instead of whole
   records of about a hundred bytes.  Cold data sits in side tables that only some nodes
   use: attributes, directive blocks, phrase-reference details.
3. **Strings are views or interned ids.**  Text refers to the source buffer or to the
   arena.  Names, ids and classes are interned (``Str :: distinct u32``), so the registry
   compares and hashes integers.
4. **One arena per document.**  The pipeline allocates from one growing arena that is
   released at once.  Nothing is freed node by node, and there is no per-node heap
   traffic.  Worker threads each own an arena.
5. **Explicit, bounded mutation.**  Transforms change the document tree only through the
   ``doctree`` procedures ``append_child``, ``insert_before``, ``replace``,
   ``remove_child`` and ``set_attr`` (docutils' names, with a suffix where they would
   shadow Odin built-ins).  They keep the links consistent; no code writes link fields
   directly.
6. **Same order, same output.**  Registration, transforms (by priority, then insertion
   order), message numbering and id generation follow docutils exactly.

The parse tree
==============

.. code-block:: text

   Node :: distinct u32 // 0: none

   Node_Data :: struct {
       kind:     Node_Kind,
       line:     i32,    // absolute 1-based line, 0: unknown
       cur_line: i32,    // docutils' document.current_line when it attaches the node
       num:      [2]i32,
       parent, first, last, next: Node,
       text, raw, name: string, // views into the source or the arena
       extra:    u32,    // index into Tree.phrases (references) or Tree.directives
   }

   Tree :: struct {
       nodes:       #soa[dynamic]Node_Data, // nodes[0] is the unused null slot
       phrases:     [dynamic]Phrase_Info,    // [0] unused
       directives:  [dynamic]Directive_Info, // [0] unused
       text:        string,                  // the input of parse_text
       line_starts: []u32,                   // the line table
       spans:       [dynamic]Span,           // with Parse_Flag.Spans, by handle
   }

Parser procedures take ``^Tree`` with handles.  A ``Node_List`` is a pair of handles
(first, last).  ``cur_line`` is recorded where the host needs it: system messages,
comments, tables, option list items, line blocks, block quotes, targets, footnotes and
citations, and the nodes that carry inline markup.  The C ABI serialiser walks the tree
by handles and writes the wire format.

The document tree
=================

.. code-block:: text

   Tag :: enum u8 { Text, document, section, title, ... } // docutils' node classes
   Str :: distinct u32                                    // interned string, 0: ""

   Element :: struct {
       tag:     Tag,
       flags:   Node_Flags,
       deleted: Basic_Lists, // default list attributes removed with delete_attr
       line:    i32,
       gen:     u32,         // bumped on every change of the child list (findall)
       parent, first, last, next, prev: Node,
       source:  Str,
       attrs:   u32,         // first attribute in Doc.attrs, 0: none
       ...
   }

   Attr :: struct {
       key:   Str,
       value: Attr_Value, // a string, integer, boolean or List
       next:  u32,
   }
   List :: distinct u32   // index into Doc.lists ([dynamic][dynamic]Str)

   Doc :: struct {
       arena:     virtual.Arena,
       nodes:     #soa[dynamic]Element,
       attrs:     [dynamic]Attr,
       lists:     [dynamic][dynamic]Str,
       strings:   [dynamic]string,     // the interner
       string_ids: map[string]Str,
       pendings:  [dynamic]Pending,     // transforms queued by directives
       root:      Node,                 // the document element
       settings:  Settings,
       reporter:  Reporter,
       // docutils' document registry: ids, nameids, nametypes, refnames, refids,
       // footnotes, citations, autofootnotes, symbol footnotes and their references,
       // substitution definitions and names, id counters, parse and transform messages,
       // internal state (indent, indirect_reference_name, expect_referenced_by_*)
       ...
   }

The basic list attributes (``ids``, ``classes``, ``names``, ``dupnames``, ``backrefs``)
take the ``List`` form.  Attribute order follows docutils (``attlist()`` sorts by name
when printing).  The node and registry procedures mirror ``docutils.nodes``:
``set_id``, ``note_implicit_target``, ``note_explicit_target``, ``note_refname``,
``make_id`` and the others.  ``make_id`` needs Unicode NFKD decomposition and Python's
``str.lower()``; ``scripts/gen_doctree_tables.py`` generates those tables from Python's
``unicodedata``.

The ``gen`` counter makes ``findall`` behave as docutils' generator does while a
transform changes the tree under it.

Arenas
======

Documents
   A ``Doc`` owns a ``core:mem/virtual`` arena.  The reader, the transforms and the
   writer allocate from it, and the whole document is released at once.

The C ABI
   Calls from Python use a per-thread **bump arena** (``odin/lib/bump.odin``), owned by
   one thread and therefore without locks.  Blocks are mapped from the operating system
   (not from the C heap, which may keep freed memory), start at 1 MB and double up to
   64 MB.  The arena is reset when the outermost call returns, so calls may re-enter
   through the include callback.  ``bump_reset`` keeps the largest block of at most 4 MB
   (``BUMP_RETAIN_MAX``): steady-state parsing maps no memory, and a large parse does not
   leave a large block resident.

   Between calls an arena holds no memory.  When the outermost call returns,
   ``bump_park`` resets the arena and moves its kept block to a process-wide cache of
   ``BUMP_CACHE_MAX`` (8) blocks, or unmaps it when the cache is full; the next outermost
   call on any thread takes a block back with ``bump_unpark``.  The cache is the only
   shared mutable state, guarded by an atomic mutex.  A thread that exits therefore owns
   nothing, and a host that creates and retires threads keeps at most 32 MB cached
   (DOD 19).  Before 1.0.0b1 each thread kept its block after it exited, about 1 MB per
   retired thread.

Threads
   ``docodin-check`` gives each worker thread its own arena.  The language server
   handles each message in a scratch arena that is reset afterwards, and gives each
   document version a snapshot arena.

Safety
======

- Bounds checks stay on in release builds.
- Tables are ``@(rodata)``; the only shared mutable state is the locked cache of arena
  blocks, so the library can be called from many threads at once.
- Recursion is bounded (``MAX_NESTING``, and ``MAX_DEPTH`` in the math converters).
- All generated Unicode tables come from one CPython version (3.14, Unicode 16),
  recorded in each table's header.
