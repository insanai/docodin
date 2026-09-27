==============================================================================
DOD 4: Data-Oriented Storage: Handles, Struct of Arrays and Arenas
==============================================================================

:Authors: Vikrant Rathore
:State: committed
:Created: 2026-09-27
:Discussion:
:Labels: parser, native, performance

.. contents:: Contents
   :local:
   :depth: 1

Summary
=======

All of docodin's native trees, the parse tree (``odin/rst``) and the docutils document
tree (``odin/doctree``), store their nodes in struct-of-arrays arrays and link them with
32-bit handles instead of pointers.  Text is a view into the source or an interned
string id.  Every parse, document and write allocates from one arena that is released at
once.  This makes the native code memory-safe without a garbage collector, fast to
traverse, and cheap to allocate and free.

Background
==========

The first parse tree was a classic pointer tree: each node a struct, children and
siblings linked by pointers.  That has three problems in a language without a garbage
collector:

- a pointer into a growable array dangles when the array grows;
- traversals, which mostly read a node's kind and links, load whole records of about a
  hundred bytes;
- freeing a tree means walking it, or leaking it.

docutils' Python objects have the opposite problem: they are safe, but each node is
several heap objects that the collector tracks.

Proposal
========

The six principles
------------------

1. **Handles, not pointers.**  A node is a ``distinct u32`` index into its tree's arrays,
   and ``0`` is the null handle.  Parents, children and siblings are handles too.  Every
   access is bounds-checked, and handles stay valid when the arrays grow, so a handle
   cannot point into freed memory.
2. **Struct of arrays for the hot fields.**  Traversals read the kind and the links.
   These live in an ``#soa`` array, so a walk touches a few dense arrays instead of whole
   records.  Cold data sits in side tables that only some nodes use: attributes,
   directive blocks, phrase-reference details.
3. **Strings are views or interned ids.**  Text refers to the source buffer or to the
   arena.  Names, ids and classes are interned (``Str :: distinct u32``), so the
   document registry compares and hashes integers.
4. **One arena per document.**  A parse, a document and a write each allocate from one
   growing arena that is released at once.  Nothing is freed node by node.  Worker
   threads each own an arena.
5. **Explicit, bounded mutation.**  Transforms change the document tree only through the
   ``doctree`` procedures (``append_child``, ``insert_before``, ``replace``,
   ``remove_child``, ``set_attr`` and their relatives, named after docutils' methods),
   which keep the links consistent.  No code writes a link field directly.
6. **Same order, same output.**  Registration, transforms, message numbering and id
   generation follow docutils' order exactly (DOD 3).

The parse tree
--------------

.. code-block:: text

   Node :: distinct u32 // 0: none

   Node_Data :: struct {
       kind:     Node_Kind,
       line:     i32,
       cur_line: i32,        // docutils' document.current_line where it attaches the node
       num:      [2]i32,
       parent, first, last, next: Node,
       text, raw, name: string, // views into the source or the arena
       extra:    u32,        // index into Tree.phrases or Tree.directives, 0: none
   }

   Tree :: struct {
       nodes:       #soa[dynamic]Node_Data, // nodes[0] is the unused null slot
       phrases:     [dynamic]Phrase_Info,
       directives:  [dynamic]Directive_Info,
       text:        string,        // the input
       line_starts: []u32,         // the line table
       spans:       [dynamic]Span, // source spans, with Parse_Flag.Spans (DOD 13)
   }

Parser procedures take ``^Tree`` with handles; a ``Node_List`` is a pair of handles
(first, last).  The C ABI serialiser walks the tree by handles.

The document tree
-----------------

.. code-block:: text

   Tag :: enum u8 { Text, document, section, title, ... } // docutils' node classes
   Str :: distinct u32                                    // interned string, 0: ""

   Element :: struct {
       tag:    Tag,
       line:   i32,
       parent, first, last, next, prev: Node,
       source: Str,
       attrs:  u32, // first attribute in Doc.attrs, 0: none
       ...
   }

   Doc :: struct {
       nodes:    #soa[dynamic]Element,
       attrs:    [dynamic]Attr,          // key, value, next: a list per node
       lists:    [dynamic][dynamic]Str,  // ids, classes, names, dupnames, backrefs
       strings:  ...,                    // the interner
       // docutils' document registry: ids, nameids, nametypes, refnames, refids,
       // footnotes, citations, substitutions, id counters, messages, pending transforms
       ...
   }

The registry procedures mirror ``docutils.nodes`` (``set_id``, ``note_implicit_target``,
``note_explicit_target``, ``note_refname``, ``make_id`` and the rest).  ``make_id`` needs
Unicode NFKD decomposition and Python's ``str.lower``; ``scripts/gen_doctree_tables.py``
generates those tables from Python's ``unicodedata``.

Memory and safety rules
-----------------------

- **Bounds checks stay on in release builds.**  The cost is small, and an out-of-range
  handle becomes a clean crash instead of memory corruption.
- **No shared mutable state.**  Tables are ``@(rodata)``.  The library can be called from
  many threads, so Sphinx's parallel reading is safe.
- **The C ABI** uses a per-thread bump arena (``odin/lib/bump.odin``) that is reset when
  the outermost call returns, so calls may re-enter through the include callback.  The
  checker gives each worker thread its own arena.

Alternatives
============

- **Pointer trees with a general-purpose allocator.**  Unsafe when arrays grow, slower to
  traverse and to free.
- **Reference counting**, or a persistent tree such as rowan's green nodes.  They solve
  incremental editing, which docodin does not need yet (DOD 12, DOD 17), at a constant
  cost everywhere.
- **Array of structs** with handles.  Safe, but traversals load whole records.

Compatibility and fidelity
==========================

Storage is invisible to users.  The change from pointers to handles
("Store the parse tree as handles into a struct-of-arrays tree") kept the wire format and
every output identical; the differential suites and docutils' test suite verified it.

Verification
============

- ``odin test`` in every package, with the interchange fixtures of ``odin/doctree``.
- The differential suites of DOD 3 and DOD 8.
- Parse-tree hashes (DOD 12) compare every field of every node across changes.

Outcome
=======

Implemented for the parse tree in docodin 0.1.0 (the pointer tree was converted), and
used from the start for ``odin/doctree``, the reader, the transforms and the writers.
docodin 0.2.0 added the line table and source spans on top of it (DOD 13).

References
==========

- ``odin/rst/nodes.odin``, ``odin/doctree/doc.odin``, ``odin/lib/bump.odin``.
- The book's chapter on data-oriented storage.
