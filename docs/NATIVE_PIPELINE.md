# Native pipeline: data-oriented design

This document specifies docodin's native (Odin) document pipeline. The pipeline has three stages:

- **Parse**: reStructuredText text becomes a parse tree (`odin/rst`).
- **Doctree**: the parse tree becomes a docutils document tree (`odin/doctree`). This stage does registration and runs directives and roles.
- **Transforms and writers**: transforms, then pseudo-XML, HTML5 and LaTeX output (`odin/transforms`, `odin/writers`).

The goal is the output of `docutils` 0.22 byte for byte, without Python. The Python shim (`python/docodin/shim`) stays the compatibility layer for Sphinx and extensions. The native pipeline serves the `docodin` command and `publish_*` calls that need no Python extensions.

## Principles

1. **Handles, not pointers.** Nodes are `distinct u32` indices into the tree's arrays, and `0` is the null handle. A handle cannot dangle into freed memory: every access is bounds-checked, and handles stay valid when arrays grow. Parents, siblings and children are handles as well.
2. **Struct of arrays for hot fields.** Traversals mostly read `kind` and the links. These live in an `#soa` array, so a walk touches a few dense arrays instead of whole 100-byte records. Cold data sits in side tables that only some nodes use: attributes, directive blocks, phrase-reference details.
3. **Strings are views or interned ids.** Text refers to the source buffer or to one arena. Names, ids and classes are interned (`Str :: distinct u32`), so the registry compares and hashes integers.
4. **One arena per document.** The whole pipeline allocates from one growing arena that is freed at once. Nothing is freed node by node, and there is no per-node heap traffic. Worker threads each own an arena (see `cmd/docodin-check`).
5. **Explicit, bounded mutation.** Transforms mutate through the `doctree` procedures: `append_child`, `insert_before`, `replace`, `remove_child` and `set_attr` (docutils' names with a suffix where they would shadow Odin builtins). These keep the links consistent. No code writes link fields directly.
6. **Same order, same output.** Registration, transforms (by priority, then insertion order), message numbering and id generation follow docutils exactly. Every stage is tested differentially against docutils.

## Parse tree (`odin/rst`)

```odin
Node :: distinct u32 // 0: none

Node_Data :: struct {
	kind:     Node_Kind,
	line:     i32,
	cur_line: i32,
	num:      [2]i32,
	parent, first, last, next: Node,
	text, raw, name: string, // views into the source or the arena
	extra:    u32, // index into Tree.phrases / Tree.directives (by kind), 0: none
}

Tree :: struct {
	nodes:      #soa[dynamic]Node_Data, // nodes[0] is the unused null slot
	phrases:    [dynamic]Phrase_Info,
	directives: [dynamic]Directive_Info,
}
```

Parser procedures take `^Tree` together with handles. `Node_List` is a `(first, last)` pair of handles. The C ABI serializer walks the tree by handles, and the wire format is unchanged.

## Document tree (`odin/doctree`)

```odin
Tag :: enum u8 { Text, document, section, title, ... } // docutils node classes
Str :: distinct u32                                    // interned string, 0: ""

Element :: struct {
	tag:    Tag,
	line:   i32,
	parent, first, last, next, prev: Node,
	source: Str,
	text:   string, // Text data or rawsource
	attrs:  u32,    // first attribute in Doc.attrs (list), 0: none
}

Attr :: struct {
	key:   Str,
	value: Attr_Value, // union{string, int, bool, List}
	next:  u32,
}
List :: distinct u32 // index into Doc.lists ([dynamic][dynamic]Str)

Doc :: struct {
	nodes:    #soa[dynamic]Element,
	attrs:    [dynamic]Attr,
	lists:    [dynamic][dynamic]Str,
	strings:  Interner,
	// docutils ``document`` registry
	ids, nameids:         map[Str]Node,
	nametypes:            map[Str]bool,
	refnames, refids:     map[Str][dynamic]Node,
	footnotes, citations, autofootnotes, symbol_footnotes: [dynamic]Node,
	footnote_refs, citation_refs: map[Str][dynamic]Node,
	autofootnote_refs, symbol_footnote_refs: [dynamic]Node,
	substitution_defs: map[Str]Node,
	substitution_names: map[Str]Str,
	id_counter:   map[Str]int,
	messages:     [dynamic]Node, // parse_messages / transform_messages
	pending:      [dynamic]Pending, // transforms queued by directives
	settings:     Settings,
}
```

The basic list attributes (`ids`, `classes`, `names`, `dupnames`, `backrefs`) take the `List` form. Attribute order follows docutils (`attlist()` sorts by name when printing). The node and registry procedures mirror `docutils.nodes`: `set_id`, `note_implicit_target`, `note_explicit_target`, `note_refname`, `make_id` and the others. `make_id` needs Unicode NFKD decomposition and Python's `str.lower()`, so `scripts/gen_doctree_tables.py` generates those tables from Python's `unicodedata`.

## Stages

1. `doctree.build(parse_tree) -> Doc`: a port of `python/docodin/builder.py` (tree building, registration, section nesting) with the native directive and role registry.
2. `transforms.apply(^Doc)`: the standard reader, parser and writer transforms in docutils priority order, with the same message texts and levels.
3. `writers.pseudoxml`, `writers.html5`, `writers.latex`: ports of the docutils writers (template parts included).

Features that need Python libraries fall back to docutils' behaviour when the library is missing, and a warning says so:
- Pygments highlighting behaves as with `syntax_highlight: none`.
- PIL image sizes are skipped.

## Verification

- Pseudo-XML of each stage is compared with docutils on the conformance corpus and the fuzz generator (`tests/fuzz_differential.py`).
- HTML5 and LaTeX output are compared on the docutils functional test inputs.
- The stage tests run in CI, with `odin test` for units.
