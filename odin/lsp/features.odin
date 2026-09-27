package lsp

// Requests on one document: symbols, folding ranges, semantic tokens,
// definitions, references and hover.  Each writes the ``result`` of its
// response.

import "core:encoding/json"
import "core:strings"

import rst "../rst"

// LSP ``SymbolKind`` values.
@(private = "file")
Symbol_Kind :: enum int {
	Namespace   = 3,
	Variable    = 13,
	Key         = 20,
	Enum_Member = 22,
}

write_range :: proc(w: ^Json_Writer, idx: ^rst.Line_Index, span: Span) {
	obj_begin(w)
	key(w, "start")
	write_position(w, to_lsp(idx, span.start))
	key(w, "end")
	write_position(w, to_lsp(idx, span.end))
	obj_end(w)
}

write_position :: proc(w: ^Json_Writer, p: Lsp_Pos) {
	obj_begin(w)
	key_int(w, "line", p.line)
	key_int(w, "character", p.character)
	obj_end(w)
}

write_location :: proc(w: ^Json_Writer, uri: string, idx: ^rst.Line_Index, span: Span) {
	obj_begin(w)
	key_str(w, "uri", uri)
	key(w, "range")
	write_range(w, idx, span)
	obj_end(w)
}

// --- document symbols ------------------------------------------------------------------

@(private = "file")
SYMBOL_KINDS :: Item_Kinds {
	.Section, .Target, .Inline_Target, .Name_Option, .Substitution_Definition, .Footnote,
	.Citation,
}

// ``textDocument/documentSymbol``: the section hierarchy, with the targets,
// substitution definitions, footnotes and citations of each section.
document_symbols :: proc(w: ^Json_Writer, s: ^Snapshot) {
	items := s.analysis.items[:]
	children := make([][dynamic]i32, len(items) + 1)
	for item, i in items {
		if item.kind not_in SYMBOL_KINDS do continue
		append(&children[item.parent + 1], i32(i))
	}
	write_symbols(w, s, children, NO_ITEM)
}

@(private = "file")
write_symbols :: proc(
	w: ^Json_Writer,
	s: ^Snapshot,
	children: [][dynamic]i32,
	parent: i32,
) {
	arr_begin(w)
	for idx in children[parent + 1] {
		item := s.analysis.items[idx]
		obj_begin(w)
		key_str(w, "name", symbol_name(item))
		if detail := symbol_detail(item); detail != "" do key_str(w, "detail", detail)
		key_int(w, "kind", int(symbol_kind(item.kind)))
		// the range starts at the start of its line
		full := item.full
		full.start = from_lsp(&s.idx, {to_lsp(&s.idx, full.start).line, 0})
		key(w, "range")
		write_range(w, &s.idx, full)
		key(w, "selectionRange")
		write_range(w, &s.idx, item.span)
		if len(children[idx + 1]) > 0 {
			key(w, "children")
			write_symbols(w, s, children, idx)
		}
		obj_end(w)
	}
	arr_end(w)
}

@(private = "file")
symbol_name :: proc(item: Item) -> string {
	#partial switch item.kind {
	case .Substitution_Definition:
		return strings.concatenate({"|", item.label, "|"})
	case .Footnote, .Citation:
		return strings.concatenate({"[", item.label, "]"})
	case .Section:
		return item.label if item.label != "" else "(untitled)"
	}
	return item.label
}

@(private = "file")
symbol_detail :: proc(item: Item) -> string {
	#partial switch item.kind {
	case .Target, .Inline_Target, .Name_Option:
		if item.indirect do return strings.concatenate({item.value, "_"})
		return item.value
	case .Citation:
		return "citation"
	case .Footnote:
		return "footnote"
	}
	return ""
}

@(private = "file")
symbol_kind :: proc(kind: Item_Kind) -> Symbol_Kind {
	#partial switch kind {
	case .Section:
		return .Namespace
	case .Substitution_Definition:
		return .Variable
	case .Footnote, .Citation:
		return .Enum_Member
	}
	return .Key
}

// --- folding ranges --------------------------------------------------------------------

folding_ranges :: proc(w: ^Json_Writer, s: ^Snapshot) {
	arr_begin(w)
	for f in s.analysis.folds {
		obj_begin(w)
		key_int(w, "startLine", int(f.start))
		key_int(w, "endLine", int(f.end))
		if f.kind == .Comment do key_str(w, "kind", "comment")
		obj_end(w)
	}
	arr_end(w)
}

// --- definitions and references ------------------------------------------------------------

// ``textDocument/definition``: the definition of the name at ``p``.
definition :: proc(w: ^Json_Writer, s: ^Snapshot, uri: string, p: i32) {
	def := definition_of(&s.analysis, item_at(&s.analysis, p))
	if def == NO_ITEM {
		null_value(w)
		return
	}
	write_location(w, uri, &s.idx, s.analysis.items[def].span)
}

// ``textDocument/references``: the uses of the name at ``p`` (and its
// definition with ``include_declaration``).
references :: proc(
	w: ^Json_Writer,
	s: ^Snapshot,
	uri: string,
	p: i32,
	include_declaration: bool,
) {
	a := &s.analysis
	def := definition_of(a, item_at(a, p))
	arr_begin(w)
	if def != NO_ITEM {
		if include_declaration do write_location(w, uri, &s.idx, a.items[def].span)
		for r in references_of(a, def) do write_location(w, uri, &s.idx, a.items[r].span)
	}
	arr_end(w)
}

// --- hover ---------------------------------------------------------------------------------

hover :: proc(w: ^Json_Writer, s: ^Snapshot, p: i32) {
	a := &s.analysis
	idx := item_at(a, p)
	text := hover_text(a, idx)
	if text == "" {
		null_value(w)
		return
	}
	obj_begin(w)
	key(w, "contents")
	obj_begin(w)
	key_str(w, "kind", "markdown")
	key_str(w, "value", text)
	obj_end(w)
	key(w, "range")
	write_range(w, &s.idx, a.items[idx].span)
	obj_end(w)
}

// The hover text of the item ``idx`` ("" for none).
hover_text :: proc(a: ^Analysis, idx: i32) -> string {
	if idx == NO_ITEM do return ""
	item := a.items[idx]
	#partial switch item.kind {
	case .Role:
		return role_hover(item.name)
	case .Directive:
		return directive_hover(item.name)
	case .Reference:
		if item.value != "" && !item.indirect && item.target == NO_ITEM {
			return strings.concatenate({"**Hyperlink** → <", item.value, ">"})
		}
	}
	if item.kind in USE_KINDS {
		if item.target == NO_ITEM do return unresolved_hover(item)
		return definition_hover(a.items[item.target])
	}
	return definition_hover(item)
}

@(private = "file")
unresolved_hover :: proc(item: Item) -> string {
	#partial switch item.kind {
	case .Substitution_Reference:
		return strings.concatenate({"Undefined substitution `|", item.label, "|`"})
	case .Anonymous_Reference:
		return "No anonymous target for this reference"
	}
	return strings.concatenate({"Unknown target name `", item.label, "`"})
}

@(private = "file")
definition_hover :: proc(item: Item) -> string {
	#partial switch item.kind {
	case .Section:
		return strings.concatenate({"**Section** ", item.label})
	case .Target, .Inline_Target, .Anonymous_Target, .Embedded_Target, .Name_Option:
		head := "**Hyperlink target**"
		if item.label != "" do head = strings.concatenate({head, " `", item.label, "`"})
		if item.value == "" do return strings.concatenate({head, " (internal)"})
		if item.indirect do return strings.concatenate({head, " → `", item.value, "`_"})
		return strings.concatenate({head, " → <", item.value, ">"})
	case .Substitution_Definition:
		parts := []string{"**Substitution** `|", item.label, "|`\n\n```rst\n", item.value, "\n```"}
		return strings.concatenate(parts)
	case .Footnote, .Citation:
		what := "**Footnote**" if item.kind == .Footnote else "**Citation**"
		return strings.concatenate({what, " [", item.label, "]\n\n", item.value})
	}
	return ""
}

// The request's position: a byte offset.
request_pos :: proc(s: ^Snapshot, params: json.Value) -> i32 {
	return from_lsp(&s.idx, lsp_pos(get(params, "position")))
}
