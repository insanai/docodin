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
	internals:    map[Node]Node_Internals, // line.indent, indirect_reference_name, expect_referenced_by_*
	settings:     Settings,
}
```

The basic list attributes (`ids`, `classes`, `names`, `dupnames`, `backrefs`) take the `List` form. Attribute order follows docutils (`attlist()` sorts by name when printing). The node and registry procedures mirror `docutils.nodes`: `set_id`, `note_implicit_target`, `note_explicit_target`, `note_refname`, `make_id` and the others. `make_id` needs Unicode NFKD decomposition and Python's `str.lower()`, so `scripts/gen_doctree_tables.py` generates those tables from Python's `unicodedata`.

## Doctree interchange

Transforms and writers are developed and tested against docutils without the native parser. `scripts/doctree_json.py` runs docutils 0.22.4 and dumps the document to JSON. `doctree.load_json` loads a dump into a `Doc`, and `doctree.dump_json` writes one.

```sh
PY="uv run --no-project --python 3.14 --with docutils==0.22.4 python"
$PY scripts/doctree_json.py doc.rst --writer html5 --stage parsed --set report_level=1 -o doc.json
```

The script drives the `Publisher` the way `publish` does, with `_disable_config` set and the warning stream captured. It dumps one of three stages:

- `parsed`: after `reader.read` and `Transformer.populate_from_components`, before any transform. The queue holds the reader, parser and writer transforms and the `pending` transforms of directives.
- `transformed`: after `apply_transforms`, before the writer.
- `output`: `transformed` plus the writer's output and `publish_parts`.

```odin
load_json :: proc(data: string, allocator := context.allocator) -> (^Doc, Load_Error)
dump_json :: proc(doc: ^Doc, allocator := context.allocator) -> string
Load_Error :: union { json.Error, Format_Error } // Format_Error{message}
```

A dump is written with `json.dumps(dump, sort_keys=True, indent=1, ensure_ascii=False)` and a final newline. `dump_json` writes the same text, so a loaded dump dumps back byte for byte. A `Doc` that was not loaded from JSON dumps its `Settings` fields, and its `expected` holds its own `pformat`. Top-level keys:

| Key | Content |
|---|---|
| `format` | `"docodin-doctree/1"` |
| `stage` | `"parsed"`, `"transformed"` or `"output"` |
| `input` | `{source_path, writer, overrides}` of the run |
| `tree` | the `document` node record |
| `detached` | `[{parent, node}]`: subtrees that are referenced but not in the tree |
| `registry` | the `document` registry |
| `transformer` | `{queue, serialno}` |
| `reporter` | the reporter state |
| `settings` | every JSON-serializable attribute of `document.settings` |
| `expected` | docutils' results: `pformat` (`document.pformat()`), plus `output` and `parts` at stage `output` |

**Node records.** Each record has a `tag`: the class name, or `#text`. Optional fields are omitted at their default:
- `source` and `line`: omitted for None.
- `document`: true when `_document` is set.
- `text`: the data of a Text node.
- `rawsource`
- `attributes`: an object mapping each name to its value. A value is a string, an integer, a boolean, null, a list of strings, or `{"float": repr}`. The class's list attributes are left out when they are empty.
- `deleted`: the class's list attributes that were deleted.
- `referenced` and `resolved`: true when set.
- `internal`: Python state kept outside `attributes`. It holds `indent` (`line`), `indirect_reference_name`, and `expect_referenced_by_id` and `expect_referenced_by_name` as `[[name, node]]`.
- `pending`: `{transform, default_priority, details}`. `transform` is the qualified class name. A detail value is a plain value as above, `{"node": i}` or `{"nodes": [i...]}`.
- `children`

**Node references** are record indices. The tree is numbered in preorder, and the detached subtrees are numbered after it. Record `i` loads as the handle `Node(i + 1)`. A node outside the tree gets a number at its first reference, together with its subtree and after its stale parent. References are made in this order:
1. The tree records, in preorder. Within a record, the `internal` maps come first (`_id`, then `_name`), then the `pending` details by key.
2. `registry.ids`, `substitution_defs`, `decoration`, then the name-to-nodes maps, then the node lists.
3. The transformer queue.
4. `reporter.written`.
5. The detached records in turn: each record's parent comes before its node.

A node has one parent. The dump therefore lists a detached node's child only when the child's `parent` is that node, and a child moved elsewhere is left out. A stale parent of a class that `nodes.node_class_names` does not name is recorded as null. This covers the plain `nodes.Element` containers of directives.

**Registry.** Ordered dicts are `[[key, value]]` lists in insertion order:
- `ids`, `substitution_defs`: `[[name, node]]`.
- `nameids`: `[[name, id or null]]`.
- `nametypes`: `[[name, bool]]`.
- `substitution_names`: `[[name, name]]`.
- `id_counter`: `[[prefix, n]]`.
- `refnames`, `refids`, `footnote_refs`, `citation_refs`: `[[name, [nodes]]]`.

The following are node lists:
- `indirect_targets`
- `autofootnotes`, `autofootnote_refs`
- `symbol_footnotes`, `symbol_footnote_refs`
- `footnotes`, `citations`
- `parse_messages`, `transform_messages`

The scalars are `autofootnote_start`, `symbol_footnote_start`, `decoration`, `current_source` and `current_line`.

**Transformer.** `queue` lists `[priority string, transform, pending node or null, kwargs]` in the order docutils applies them, sorted by the priority string (`"%03d-%03d" % (priority, serial)`). `Doc.pending_queue` holds every entry, including the component transforms, which have no node.

**Reporter.** The reporter state has these fields:
- `source`, `report_level`, `halt_level`, `debug`, `max_level`.
- `observers`: `note_parse_message` or `note_transform_message`.
- `written`: `[{level, node, text}]`, the messages written to the warning stream.
- `source_lines`: the line map behind `Reporter.get_source_and_line`, or null. It holds `input_offset`, `line_offset`, and `runs` of `[source, first offset, count]` built from the state machine's `input_lines`. The loaded reporter answers `get_source_and_line` from this map the way `StateMachine.get_source_and_line` does.

**Settings.** The loader converts the fields of `Settings` from the dump. None and False become "", 0, false or an empty list. A `smart_quotes` value of `"alt…"` sets `smart_quotes_alt`. `warning_stream` becomes `.Collect`. The complete settings object is kept in `Doc.interchange` for `dump_json`, together with `stage`, `input` and `expected`.

**Limits.** A float attribute loads as its repr string, which is the doctree's representation of floats, so it dumps back as a string. Such attributes do not occur in the corpus. The script refuses anything else it cannot represent: other attribute or detail types, unknown instance state, and a tree node that is shared or has a stale parent.

**Tests.** `odin/doctree/tests/interchange_test.odin` loads every dump in `fixtures/interchange`. It compares `pformat` with `expected.pformat` and requires `dump_json` to reproduce the file. `scripts/doctree_interchange_fixtures.py --docutils-src DIR` regenerates these fixtures, about 3.5 MB of small docutils functional inputs and documentation plus fuzz documents. The docutils installation directory is written as `<docutils>` (`doctree_json.py --portable`), so the fixtures do not depend on the machine. With `--corpus OUT`, it dumps every functional input, every `docs/**/*.rst` file and 300 fuzz documents, with each writer and at each stage. The corpus test then runs with `DOCTREE_INTERCHANGE_DIR=OUT odin test odin/doctree/tests`.

## Stages

1. `reader.parse(text, settings, source_path) -> ^Doc` (`odin/reader`): `Parser.parse` into `new_document`. A port of `python/docodin/builder.py` (tree building, registration, section nesting, `document.current_line` bookkeeping, a `StringList` port) with the native directive and role registry: the English directive and role names, `parse_directive_block` with the option converters, and all standard directives and roles. The `csv-table` directive reads files and `file:` URLs only; figures get no width from `:figwidth: image` (no PIL).

   `include` works as in docutils: the parser's include hook (`rst.Parser.include_hook`) lets the host dry-run the directive when the parser meets it, and the parser inserts the lines after the directive block and parses them in the same state machine (`rst.insert_input`). The host inserts them into its input lines at the same place and later runs the directive without inserting again. The Python host (`python/docodin/_include.py`) does the same through a C callback of `docodin_parse`.
2. `transforms.apply(^Doc)`: the standard reader, parser and writer transforms in docutils priority order, with the same message texts and levels.
3. `writers.write(doc, writer, settings) -> (output, parts, err)` (`odin/writers`): ports of the docutils writers `pseudoxml`, `docutils_xml`, `html5_polyglot`, `latex2e` and `xetex`, with their `publish_parts` parts. `writers.settings_for(doc, writer)` reads the writer settings from `Doc.settings`, or from the dumped docutils settings of an interchange document. Where docutils raises, `err` names the Python exception.

Features that need Python libraries fall back to docutils' behaviour when the library is missing, and a warning says so:
- Pygments highlighting behaves as with `syntax_highlight: none`.
- PIL image sizes are skipped.

## Verification

- Pseudo-XML of each stage is compared with docutils on the conformance corpus and the fuzz generator (`tests/fuzz_differential.py`).
- Writer output and parts are compared byte for byte by `tests/native_writers_differential.py`: the docutils functional tests with their settings (also against `test/functional/expected`), the functional inputs and `docs/**/*.rst` with several settings variants per writer, and generated documents. `odin test odin/writers/tests` checks the `output` fixtures of the interchange.
- The stage tests run in CI, with `odin test` for units.
