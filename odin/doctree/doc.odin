package doctree

import "base:runtime"
import "core:mem/virtual"

// The docutils document tree (``docutils.nodes``), stored data-oriented.
//
// Nodes are ``Node`` handles into ``Doc.nodes``, an ``#soa`` array of the
// hot fields (tag, links, line).  Attributes, list attributes and the
// internal data of ``pending`` elements sit in side tables.  Names, ids and
// attribute keys are interned (``Str``).  Everything a ``Doc`` owns is
// allocated from its arena and freed at once by ``destroy``.
//
// Differences from the Python object model, all deliberate:
//
// * A node is linked into one parent at a time: appending a node that is
//   already a child elsewhere moves it (docutils would list it twice).
// * A removed node keeps its ``parent`` handle, as in docutils (``remove``
//   does not clear ``Node.parent``), but is no longer among its children.
// * Attribute values are ``string``, ``int``, ``bool``, ``List`` (a list of
//   interned strings) or ``Attr_None`` (Python ``None``).

// Handle of a node in ``Doc.nodes``; 0 is the null handle.
Node :: distinct u32

// Interned string; 0 is the empty string.
Str :: distinct u32

// Handle of a list of interned strings in ``Doc.lists``; 0 is the shared,
// immutable empty list.
List :: distinct u32

// Python's ``None`` as an attribute value.
Attr_None :: struct {}

Attr_Value :: union {
	string,
	int,
	bool,
	List,
	Attr_None,
}

// The basic list attributes (``Element.list_attributes`` + ``backrefs``).
Basic_List :: enum u8 {
	ids,
	classes,
	names,
	dupnames,
	backrefs,
}
Basic_Lists :: bit_set[Basic_List; u8]

Tag_Set :: bit_set[Tag; u128]
Categories :: bit_set[Category; u32]

// Internal (non-attribute) node state of docutils' Python objects.
Node_Flag :: enum u8 {
	Has_Document, // ``Node._document`` is set
	Has_Source,   // ``Node.source`` is not None
	Has_Line,     // ``Node.line`` is not None
	Referenced,   // ``Targetable.referenced``
	Resolved,     // ``Resolvable.resolved``
}
Node_Flags :: bit_set[Node_Flag; u8]

Element :: struct {
	tag:     Tag,
	flags:   Node_Flags,
	deleted: Basic_Lists, // default list attributes removed with ``delete_attr``
	line:    i32,
	gen:     u32, // bumped on every change of the child list (see ``Findall``)
	parent:  Node,
	first:   Node,
	last:    Node,
	next:    Node,
	prev:    Node,
	source:  Str,
	attrs:   u32, // first attribute in ``Doc.attrs``, 0: none
	extra:   u32, // ``pending``: index in ``Doc.pendings``
	text:    string, // Text data, or the element's ``rawsource``
}

Attr :: struct {
	key:   Str,
	value: Attr_Value,
	next:  u32,
}

// A value in the ``details`` of a ``pending`` element.
Detail_None :: struct {}
Detail_Value :: union {
	string,
	int,
	bool,
	Node,
	[]Node,
	[]string,
	Detail_None,
}

Detail :: struct {
	key:   string,
	value: Detail_Value,
}

// Internal data of a ``pending`` element (``pending.transform``/``details``).
// ``transform`` is the qualified class name, e.g.
// ``docutils.transforms.parts.Contents``.
Pending :: struct {
	transform:        string,
	default_priority: int,
	details:          [dynamic]Detail,
}

// An entry of ``Transformer.transforms``: ``(priority string, transform
// class, pending node, kwargs)``.  ``note_pending`` queues the transform of
// a ``pending`` element; the transforms of the reader, parser and writer
// (``populate_from_components``) have no node.  ``transform`` is the
// qualified class name; the priority string is ``"%03d-%03d" % (priority,
// serial)``.
Queued_Pending :: struct {
	priority:  int,
	serial:    int,
	node:      Node, // the ``pending`` element, 0: none
	transform: string,
	kwargs:    [dynamic]Detail, // keyword arguments of ``Transform.apply``
}

// A name (or id) mapped to a node.
Name_Ref :: struct {
	name: Str,
	node: Node,
}

// Python instance state of a node outside ``attributes``: ``line.indent``
// (parser), ``indirect_reference_name`` of targets and references (parser,
// used by the reference transforms) and the ``expect_referenced_by_id`` and
// ``expect_referenced_by_name`` maps that ``PropagateTargets`` gives the
// node after a target.  Empty maps are the same as missing ones.
Node_Internals :: struct {
	indent:                    Maybe(int),
	indirect_reference_name:   Maybe(string),
	expect_referenced_by_id:   [dynamic]Name_Ref,
	expect_referenced_by_name: [dynamic]Name_Ref,
}

// Insertion-ordered map with ``Str`` keys (a Python ``dict``).
Ordered_Map :: struct($V: typeid) {
	index:  map[Str]int,
	keys:   [dynamic]Str,
	values: [dynamic]V,
}

// Deleted key slot of an ``Ordered_Map``.
TOMBSTONE :: Str(max(u32))

Doc :: struct {
	arena:                virtual.Arena,
	allocator:            runtime.Allocator, // the arena
	owner:                runtime.Allocator, // allocated this struct
	nodes:                #soa[dynamic]Element,
	attrs:                [dynamic]Attr,
	lists:                [dynamic][dynamic]Str,
	strings:              [dynamic]string,
	string_ids:           map[string]Str,
	pendings:             [dynamic]Pending,
	root:                 Node, // the ``document`` element
	settings:             Settings,
	reporter:             Reporter,
	// ``document`` state
	current_source:       Maybe(string),
	current_line:         Maybe(int),
	decoration:           Node,
	// ``document`` registry
	ids:                  Ordered_Map(Node),
	nameids:              Ordered_Map(Str), // 0: None (a "dupname")
	nametypes:            Ordered_Map(bool),
	refnames:             Ordered_Map([dynamic]Node),
	refids:               Ordered_Map([dynamic]Node),
	indirect_targets:     [dynamic]Node,
	substitution_defs:    Ordered_Map(Node),
	substitution_names:   Ordered_Map(Str),
	footnote_refs:        Ordered_Map([dynamic]Node),
	citation_refs:        Ordered_Map([dynamic]Node),
	autofootnotes:        [dynamic]Node,
	autofootnote_refs:    [dynamic]Node,
	symbol_footnotes:     [dynamic]Node,
	symbol_footnote_refs: [dynamic]Node,
	footnotes:            [dynamic]Node,
	citations:            [dynamic]Node,
	autofootnote_start:   int,
	symbol_footnote_start: int,
	id_counter:           Ordered_Map(int),
	parse_messages:       [dynamic]Node,
	transform_messages:   [dynamic]Node,
	pending_queue:        [dynamic]Queued_Pending, // ``Transformer.transforms``
	transform_serial:     int, // ``Transformer.serialno``
	internals:            map[Node]Node_Internals,
	interchange:          Interchange, // what a JSON dump carries besides the document
	// where docutils would use a Python library (see python_needs.odin)
	python_needs:         [dynamic]Python_Need,
}

// Interned at fixed ids by ``make_doc``.
WELL_KNOWN := [?]string {
	"",
	"ids",
	"classes",
	"names",
	"dupnames",
	"backrefs",
	"source",
	"refname",
	"refid",
	"refuri",
	"level",
	"type",
	"line",
	"xml:space",
	"delimiter",
	"alt",
	"title",
}

K_IDS :: Str(1)
K_CLASSES :: Str(2)
K_NAMES :: Str(3)
K_DUPNAMES :: Str(4)
K_BACKREFS :: Str(5)
K_SOURCE :: Str(6)
K_REFNAME :: Str(7)
K_REFID :: Str(8)
K_REFURI :: Str(9)
K_LEVEL :: Str(10)
K_TYPE :: Str(11)
K_LINE :: Str(12)
K_XML_SPACE :: Str(13)
K_DELIMITER :: Str(14)
K_ALT :: Str(15)
K_TITLE :: Str(16)

// The key of a basic list attribute.
basic_key :: #force_inline proc "contextless" (b: Basic_List) -> Str {
	return Str(int(b) + 1)
}

// The basic list attribute named ``key``, if it is one.
basic_of :: #force_inline proc "contextless" (key: Str) -> (Basic_List, bool) {
	if key >= K_IDS && key <= K_BACKREFS do return Basic_List(int(key) - 1), true
	return {}, false
}

// Create an empty ``Doc`` (no root yet) with its own arena.
make_doc :: proc(settings: Settings, allocator := context.allocator) -> ^Doc {
	doc := new(Doc, allocator)
	doc.owner = allocator
	if virtual.arena_init_growing(&doc.arena) != nil do panic("doctree: cannot reserve arena")
	a := virtual.arena_allocator(&doc.arena)
	doc.allocator = a
	doc.nodes = make(#soa[dynamic]Element, 1, 256, a)
	doc.attrs = make([dynamic]Attr, 1, 256, a)
	doc.lists = make([dynamic][dynamic]Str, 1, 64, a)
	doc.pendings = make([dynamic]Pending, 1, 4, a)
	doc.strings = make([dynamic]string, 0, 256, a)
	doc.string_ids = make(map[string]Str, 256, a)
	doc.python_needs = make([dynamic]Python_Need, a)
	for s in WELL_KNOWN do intern(doc, s)
	doc.settings = settings
	doc.autofootnote_start = 1
	init_registry(doc)
	init_reporter(doc, "")
	return doc
}

@(private = "file")
om_init :: proc(m: ^Ordered_Map($V), a: runtime.Allocator) {
	m.index = make(map[Str]int, 16, a)
	m.keys = make([dynamic]Str, a)
	m.values = make([dynamic]V, a)
}

@(private = "file")
init_registry :: proc(doc: ^Doc) {
	a := doc.allocator
	om_init(&doc.ids, a)
	om_init(&doc.nameids, a)
	om_init(&doc.nametypes, a)
	om_init(&doc.refnames, a)
	om_init(&doc.refids, a)
	om_init(&doc.substitution_defs, a)
	om_init(&doc.substitution_names, a)
	om_init(&doc.footnote_refs, a)
	om_init(&doc.citation_refs, a)
	om_init(&doc.id_counter, a)
	lists := [?]^[dynamic]Node {
		&doc.indirect_targets,
		&doc.autofootnotes,
		&doc.autofootnote_refs,
		&doc.symbol_footnotes,
		&doc.symbol_footnote_refs,
		&doc.footnotes,
		&doc.citations,
		&doc.parse_messages,
		&doc.transform_messages,
	}
	for l in lists do l^ = make([dynamic]Node, a)
	doc.pending_queue = make([dynamic]Queued_Pending, a)
	doc.internals = make(map[Node]Node_Internals, a)
}

// Free everything the document owns.
destroy :: proc(doc: ^Doc) {
	if doc == nil do return
	owner := doc.owner
	virtual.arena_destroy(&doc.arena)
	free(doc, owner)
}

// --- interner -----------------------------------------------------------------

// Intern ``s`` (copied into the arena).
intern :: proc(doc: ^Doc, s: string) -> Str {
	if id, ok := doc.string_ids[s]; ok do return id
	own := clone(doc, s)
	id := Str(len(doc.strings))
	append(&doc.strings, own)
	doc.string_ids[own] = id
	return id
}

// The id of ``s`` if it is interned.
lookup :: proc(doc: ^Doc, s: string) -> (Str, bool) {
	id, ok := doc.string_ids[s]
	return id, ok
}

// The text of an interned string.
str :: #force_inline proc(doc: ^Doc, s: Str) -> string {
	return doc.strings[s]
}

// Copy ``s`` into the document's arena.
clone :: proc(doc: ^Doc, s: string) -> string {
	if len(s) == 0 do return ""
	buf := make([]u8, len(s), doc.allocator)
	copy(buf, s)
	return string(buf)
}

// --- ordered maps ---------------------------------------------------------------

om_get :: proc(m: ^Ordered_Map($V), key: Str) -> (V, bool) {
	i, ok := m.index[key]
	if !ok do return {}, false
	return m.values[i], true
}

om_has :: proc(m: ^Ordered_Map($V), key: Str) -> bool {
	return key in m.index
}

// Pointer to the value of ``key``, inserted (zero) if missing (``setdefault``).
om_ptr :: proc(m: ^Ordered_Map($V), key: Str) -> ^V {
	i, ok := m.index[key]
	if !ok {
		i = len(m.keys)
		append(&m.keys, key)
		append(&m.values, V{})
		m.index[key] = i
	}
	return &m.values[i]
}

om_set :: proc(m: ^Ordered_Map($V), key: Str, value: V) {
	om_ptr(m, key)^ = value
}

// Remove ``key``, keeping the order of the others (``del d[key]``).
om_delete :: proc(m: ^Ordered_Map($V), key: Str) {
	i, ok := m.index[key]
	if !ok do return
	delete_key(&m.index, key)
	m.keys[i] = TOMBSTONE
}

// Number of keys.
om_len :: proc(m: ^Ordered_Map($V)) -> int {
	return len(m.index)
}

// --- nodes ----------------------------------------------------------------------------

@(private)
alloc_node :: proc(doc: ^Doc, tag: Tag, text: string) -> Node {
	n := Node(len(doc.nodes))
	append_soa(&doc.nodes, Element{tag = tag, text = clone(doc, text)})
	return n
}

tag :: #force_inline proc(doc: ^Doc, n: Node) -> Tag {
	return doc.nodes[n].tag
}

// Is ``n`` an instance of any of the classes in ``tags`` (``isinstance``)?
is :: #force_inline proc(doc: ^Doc, n: Node, tags: Tag_Set) -> bool {
	return n != 0 && doc.nodes[n].tag in tags
}

// Is ``n`` an instance of the category ``c`` (``isinstance(n, nodes.Body)``)?
is_a :: #force_inline proc(doc: ^Doc, n: Node, c: Category) -> bool {
	return n != 0 && c in TAG_CATEGORIES[doc.nodes[n].tag]
}

// All tags of a category, e.g. ``tags_of(.Body)``.
tags_of :: #force_inline proc "contextless" (c: Category) -> Tag_Set {
	return CATEGORY_TAGS[c]
}

tagname :: #force_inline proc(doc: ^Doc, n: Node) -> string {
	return TAG_NAMES[doc.nodes[n].tag]
}

parent :: #force_inline proc(doc: ^Doc, n: Node) -> Node {
	return doc.nodes[n].parent
}

first_child :: #force_inline proc(doc: ^Doc, n: Node) -> Node {
	return doc.nodes[n].first
}

last_child :: #force_inline proc(doc: ^Doc, n: Node) -> Node {
	return doc.nodes[n].last
}

next_sibling :: #force_inline proc(doc: ^Doc, n: Node) -> Node {
	return doc.nodes[n].next
}

prev_sibling :: #force_inline proc(doc: ^Doc, n: Node) -> Node {
	return doc.nodes[n].prev
}

// Text data of a Text node, ``rawsource`` of an element.
text :: #force_inline proc(doc: ^Doc, n: Node) -> string {
	return doc.nodes[n].text
}

set_text :: proc(doc: ^Doc, n: Node, s: string) {
	doc.nodes[n].text = clone(doc, s)
}

// ``Node.line``; ``ok`` is false for None.
line :: proc(doc: ^Doc, n: Node) -> (int, bool) {
	e := &doc.nodes[n]
	return int(e.line), .Has_Line in e.flags
}

set_line :: proc(doc: ^Doc, n: Node, value: Maybe(int)) {
	e := &doc.nodes[n]
	if v, ok := value.?; ok {
		e.line = i32(v)
		e.flags += {.Has_Line}
	} else {
		e.line = 0
		e.flags -= {.Has_Line}
	}
}

// ``Node.source``; ``ok`` is false for None.
source :: proc(doc: ^Doc, n: Node) -> (string, bool) {
	e := &doc.nodes[n]
	return doc.strings[e.source], .Has_Source in e.flags
}

set_source :: proc(doc: ^Doc, n: Node, value: Maybe(string)) {
	e := &doc.nodes[n]
	if v, ok := value.?; ok {
		e.source = intern(doc, v)
		e.flags += {.Has_Source}
	} else {
		e.source = 0
		e.flags -= {.Has_Source}
	}
}

has_flag :: #force_inline proc(doc: ^Doc, n: Node, f: Node_Flag) -> bool {
	return f in doc.nodes[n].flags
}

set_flag :: proc(doc: ^Doc, n: Node, f: Node_Flag, on := true) {
	if on {
		doc.nodes[n].flags += {f}
	} else {
		doc.nodes[n].flags -= {f}
	}
}

// Is ``n`` part of a document (``Node.document`` is not None)?
in_document :: proc(doc: ^Doc, n: Node) -> bool {
	for m := n; m != 0; m = doc.nodes[m].parent {
		if .Has_Document in doc.nodes[m].flags do return true
	}
	return false
}

// Number of nodes allocated (including the null slot).
node_count :: proc(doc: ^Doc) -> int {
	return len(doc.nodes)
}
