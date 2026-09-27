package lsp

// Reference resolution, as docutils' registry and reference transforms
// resolve names in one document:
//
// * named references: explicit targets (hyperlink targets, inline targets,
//   embedded URIs, ``:name:`` options, footnote and citation labels) first,
//   then implicit targets (section titles); names are compared after
//   ``fully_normalize_name``, and the first definition of a name wins;
// * anonymous references: the anonymous targets, in order;
// * footnote references: numbered labels by name, ``[#]_`` and ``[*]_``
//   the auto-numbered and auto-symbol footnotes in order;
// * citation references: citations by name;
// * substitution references: the definition of the same name, else of the
//   same name in lowercase (``Substitutions``).

import dt "../doctree"

// The definitions by kind of name.
@(private = "file")
Names :: struct {
	explicit:       map[string]i32,
	implicit:       map[string]i32,
	subs:           map[string]i32,
	subs_lower:     map[string]i32,
	// in document order, and the next one to take
	autos:          [dynamic]i32,
	symbols:        [dynamic]i32,
	anonymous:      [dynamic]i32,
	next_auto:      int,
	next_symbol:    int,
	next_anonymous: int,
}

resolve :: proc(a: ^Analysis) {
	names := Names {
		explicit   = make(map[string]i32),
		implicit   = make(map[string]i32),
		subs       = make(map[string]i32),
		subs_lower = make(map[string]i32),
		autos      = make([dynamic]i32),
		symbols    = make([dynamic]i32),
		anonymous  = make([dynamic]i32),
	}
	for item, i in a.items do note_definition(&names, item, i32(i))
	for &item in a.items {
		#partial switch item.kind {
		case .Reference:
			if item.name == "" do continue
			item.target = lookup(names.explicit, item.name)
			if item.target == NO_ITEM do item.target = lookup(names.implicit, item.name)
		case .Anonymous_Reference:
			item.target = take(names.anonymous[:], &names.next_anonymous)
		case .Footnote_Reference:
			item.target = footnote_target(a, &names, item)
		case .Citation_Reference:
			item.target = lookup(names.explicit, item.name)
		case .Substitution_Reference:
			item.target = lookup(names.subs, item.name)
			if item.target == NO_ITEM {
				item.target = lookup(names.subs_lower, dt.py_lower(item.name))
			}
		}
	}
}

@(private = "file")
note_definition :: proc(names: ^Names, item: Item, idx: i32) {
	#partial switch item.kind {
	case .Section:
		note_name(&names.implicit, item.name, idx)
	case .Target, .Inline_Target, .Embedded_Target, .Name_Option, .Citation:
		note_name(&names.explicit, item.name, idx)
	case .Footnote:
		switch item.label {
		case "#":
			append(&names.autos, idx)
		case "*":
			append(&names.symbols, idx)
		case:
			note_name(&names.explicit, item.name, idx)
		}
	case .Anonymous_Target:
		append(&names.anonymous, idx)
	case .Substitution_Definition:
		note_name(&names.subs, item.name, idx)
		note_name(&names.subs_lower, dt.py_lower(item.name), idx)
	}
}

@(private = "file")
footnote_target :: proc(a: ^Analysis, names: ^Names, item: Item) -> i32 {
	switch item.label {
	case "#":
		return take(names.autos[:], &names.next_auto)
	case "*":
		return take(names.symbols[:], &names.next_symbol)
	}
	def := lookup(names.explicit, item.name)
	return def if def != NO_ITEM && a.items[def].kind == .Footnote else NO_ITEM
}

@(private = "file")
note_name :: proc(m: ^map[string]i32, name: string, idx: i32) {
	if name == "" || name in m do return
	m[name] = idx
}

@(private = "file")
lookup :: proc(m: map[string]i32, name: string) -> i32 {
	return m[name] or_else NO_ITEM
}

@(private = "file")
take :: proc(list: []i32, next: ^int) -> i32 {
	if next^ >= len(list) do return NO_ITEM
	next^ += 1
	return list[next^ - 1]
}

// The item at ``p``: a use before a definition with the same span (an
// embedded URI), else the smallest span.
item_at :: proc(a: ^Analysis, p: i32) -> i32 {
	best := NO_ITEM
	for item, i in a.items {
		if !span_contains(item.span, p) do continue
		if best == NO_ITEM || better_item(item, a.items[best]) do best = i32(i)
	}
	return best
}

@(private = "file")
better_item :: proc(x, y: Item) -> bool {
	if x.span == y.span do return x.kind in USE_KINDS && y.kind not_in USE_KINDS
	return y.span.start < x.span.start || x.span.end < y.span.end
}

// The definition an item stands for: the target of a use, the item itself
// for a definition.
definition_of :: proc(a: ^Analysis, idx: i32) -> i32 {
	if idx == NO_ITEM do return NO_ITEM
	item := a.items[idx]
	if item.kind in USE_KINDS do return item.target
	if item.kind in DEFINITION_KINDS do return idx
	return NO_ITEM
}

// The uses of the definition ``def``.
references_of :: proc(a: ^Analysis, def: i32, allocator := context.allocator) -> []i32 {
	out := make([dynamic]i32, 0, 8, allocator)
	for item, i in a.items {
		if item.kind in USE_KINDS && item.target == def do append(&out, i32(i))
	}
	return out[:]
}
