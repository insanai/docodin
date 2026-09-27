package transforms

import "core:strings"

import dt "../doctree"

// ``Node.walk`` and ``Node.walkabout`` with a ``NodeVisitor``, including
// the debug messages docutils reports on every dispatch (with the
// ``debug`` setting).

Visit :: enum u8 {
	Continue,
	Skip_Node, // ``SkipNode``: neither the children nor the departure
	Skip_Departure, // ``SkipDeparture``
}

// A visitor: ``visit``/``depart`` dispatch on the node, and name the
// method they call (``method.__name__``) for the debug messages.
Visitor :: struct {
	doc:         ^dt.Doc,
	visit:       proc(v: ^Visitor, n: dt.Node) -> Visit,
	depart:      proc(v: ^Visitor, n: dt.Node),
	visit_name:  proc(t: dt.Tag) -> string,
	depart_name: proc(t: dt.Tag) -> string,
}

// ``node.__class__.__name__``.
class_name :: proc(t: dt.Tag) -> string {
	return "Text" if t == .Text else dt.TAG_NAMES[t]
}

@(private = "file")
debug :: proc(doc: ^dt.Doc, parts: ..string) {
	if !doc.reporter.debug_flag do return
	dt.debug(doc, strings.concatenate(parts, context.temp_allocator))
}

@(private = "file")
dispatch_visit :: proc(v: ^Visitor, n: dt.Node) -> Visit {
	t := dt.tag(v.doc, n)
	if v.doc.reporter.debug_flag {
		method := v.visit_name(t)
		name := class_name(t)
		debug(v.doc, "docutils.nodes.NodeVisitor.dispatch_visit calling ", method, " for ", name)
	}
	return v.visit(v, n)
}

@(private = "file")
dispatch_departure :: proc(v: ^Visitor, n: dt.Node) {
	t := dt.tag(v.doc, n)
	if v.doc.reporter.debug_flag {
		method := v.depart_name(t)
		name := class_name(t)
		prefix := "docutils.nodes.NodeVisitor.dispatch_departure calling "
		debug(v.doc, prefix, method, " for ", name)
	}
	v.depart(v, n)
}

// ``Node.walk(visitor)``: visit ``n`` and (unless skipped) its children, as
// they were when the visit returned.
walk :: proc(v: ^Visitor, n: dt.Node) {
	doc := v.doc
	debug(doc, "docutils.nodes.Node.walk calling dispatch_visit for ", class_name(dt.tag(doc, n)))
	if dispatch_visit(v, n) == .Skip_Node do return
	for c in dt.children(doc, n) do walk(v, c)
}

// ``Node.walkabout(visitor)``: ``walk`` with departures.
walkabout :: proc(v: ^Visitor, n: dt.Node) {
	doc := v.doc
	name := class_name(dt.tag(doc, n))
	debug(doc, "docutils.nodes.Node.walkabout calling dispatch_visit for ", name)
	result := dispatch_visit(v, n)
	if result == .Skip_Node do return
	for c in dt.children(doc, n) do walkabout(v, c)
	if result == .Skip_Departure do return
	debug(doc, "docutils.nodes.Node.walkabout calling dispatch_departure for ", name)
	dispatch_departure(v, n)
}

// The method names of a ``SparseNodeVisitor`` subclass: ``_nop`` for the
// node classes, ``unknown_visit`` for others (plain ``Element``).
sparse_visit_name :: proc(t: dt.Tag) -> string {
	return "unknown_visit" if t == .Element else "_nop"
}
