package doctree

import "core:slice"

// Element attributes (``Element.attributes``), stored as a chain of
// ``Attr`` records per element in insertion order.
//
// The class's list attributes (``ids``, ``classes``, ``names``,
// ``dupnames`` and, for ``BackLinkable`` classes, ``backrefs``) exist on
// every element from its creation, as in docutils: until first written they
// have no record and read as the shared empty list.  ``Element.deleted``
// marks such a default attribute that was deleted.

Attr_Key :: union {
	Str,
	string,
}

@(private = "file")
key_id :: proc(doc: ^Doc, key: Attr_Key, create: bool) -> (Str, bool) {
	switch k in key {
	case Str:
		return k, true
	case string:
		if create do return intern(doc, k), true
		return lookup(doc, k)
	}
	return 0, false
}

@(private = "file")
find_attr :: proc(doc: ^Doc, n: Node, key: Str) -> u32 {
	for i := doc.nodes[n].attrs; i != 0; i = doc.attrs[i].next {
		if doc.attrs[i].key == key do return i
	}
	return 0
}

@(private = "file")
is_default_list :: proc(doc: ^Doc, n: Node, key: Str) -> bool {
	b, ok := basic_of(key)
	e := &doc.nodes[n]
	return ok && b in TAG_LIST_ATTRS[e.tag] && b not_in e.deleted
}

// ``key in element`` / ``Element.hasattr``.
has_attr :: proc(doc: ^Doc, n: Node, key: Attr_Key) -> bool {
	k, ok := key_id(doc, key, false)
	if !ok do return false
	return find_attr(doc, n, k) != 0 || is_default_list(doc, n, k)
}

// ``Element.get(key)``; ``ok`` is false if the attribute is missing.
get_attr :: proc(doc: ^Doc, n: Node, key: Attr_Key) -> (value: Attr_Value, ok: bool) {
	k := key_id(doc, key, false) or_return
	if i := find_attr(doc, n, k); i != 0 do return doc.attrs[i].value, true
	if is_default_list(doc, n, k) do return List(0), true
	return nil, false
}

// A string attribute, or ``default`` if it is missing or not a string.
get_string :: proc(doc: ^Doc, n: Node, key: Attr_Key, default := "") -> string {
	v, _ := get_attr(doc, n, key)
	s, is_str := v.(string)
	return s if is_str else default
}

// An int attribute, or ``default`` if it is missing or not an int.
get_int :: proc(doc: ^Doc, n: Node, key: Attr_Key, default := 0) -> int {
	v, _ := get_attr(doc, n, key)
	i, is_int := v.(int)
	return i if is_int else default
}

// ``element[key] = value``.  Strings are copied into the arena.
set_attr :: proc(doc: ^Doc, n: Node, key: Attr_Key, value: Attr_Value) {
	k, _ := key_id(doc, key, true)
	v := value
	if s, is_str := value.(string); is_str do v = clone(doc, s)
	if b, is_basic := basic_of(k); is_basic do doc.nodes[n].deleted -= {b}
	if i := find_attr(doc, n, k); i != 0 {
		doc.attrs[i].value = v
		return
	}
	idx := u32(len(doc.attrs))
	append(&doc.attrs, Attr{key = k, value = v})
	last := doc.nodes[n].attrs
	if last == 0 {
		doc.nodes[n].attrs = idx
		return
	}
	for doc.attrs[last].next != 0 do last = doc.attrs[last].next
	doc.attrs[last].next = idx
}

// ``Element.delattr(key)`` / ``del element[key]``.
delete_attr :: proc(doc: ^Doc, n: Node, key: Attr_Key) {
	k, ok := key_id(doc, key, false)
	if !ok do return
	if b, is_basic := basic_of(k); is_basic && b in TAG_LIST_ATTRS[doc.nodes[n].tag] {
		doc.nodes[n].deleted += {b}
	}
	prev: u32 = 0
	for i := doc.nodes[n].attrs; i != 0; i = doc.attrs[i].next {
		if doc.attrs[i].key != k {
			prev = i
			continue
		}
		if prev == 0 do doc.nodes[n].attrs = doc.attrs[i].next
		else do doc.attrs[prev].next = doc.attrs[i].next
		return
	}
}

// Attribute records of ``n`` in insertion order (``attributes.items()``),
// default list attributes included.
Attr_Item :: struct {
	key:   string,
	value: Attr_Value,
}

attributes :: proc(doc: ^Doc, n: Node, allocator := context.temp_allocator) -> []Attr_Item {
	out := make([dynamic]Attr_Item, 0, 8, allocator)
	e := doc.nodes[n]
	listed := TAG_LIST_ATTRS[e.tag] - e.deleted
	for b in listed {
		v, _ := get_attr(doc, n, basic_key(b))
		append(&out, Attr_Item{str(doc, basic_key(b)), v})
	}
	for i := e.attrs; i != 0; i = doc.attrs[i].next {
		a := doc.attrs[i]
		if b, is_basic := basic_of(a.key); is_basic && b in listed do continue
		append(&out, Attr_Item{str(doc, a.key), a.value})
	}
	return out[:]
}

// Copy the attributes of ``src`` node ``n`` to ``dst`` node ``m``: the
// class's list attributes get new lists, other values are shared (within
// one document), as in ``Element.copy``.
@(private)
copy_attrs :: proc(dst, src: ^Doc, m, n: Node) {
	t := src.nodes[n].tag
	for i := src.nodes[n].attrs; i != 0; i = src.attrs[i].next {
		a := src.attrs[i]
		key := a.key if dst == src else intern(dst, str(src, a.key))
		v := a.value
		if l, is_list := a.value.(List); is_list {
			b, is_basic := basic_of(a.key)
			if dst != src || (is_basic && b in TAG_LIST_ATTRS[t]) {
				items := make([dynamic]Str, 0, max(len(src.lists[l]), 2), dst.allocator)
				for x in src.lists[l] {
					append(&items, x if dst == src else intern(dst, str(src, x)))
				}
				v = List(len(dst.lists))
				append(&dst.lists, items)
			}
		}
		set_attr(dst, m, key, v)
	}
}

// ``Element.is_not_default(key)``: false for an empty list attribute of
// the class's ``list_attributes``.
is_not_default :: proc(doc: ^Doc, n: Node, key: Attr_Key) -> bool {
	k, ok := key_id(doc, key, false)
	if !ok do return true
	v, _ := get_attr(doc, n, k)
	l, is_list := v.(List)
	b, is_basic := basic_of(k)
	empty := is_list && len(doc.lists[l]) == 0
	return !(empty && is_basic && b in TAG_LIST_ATTRS[doc.nodes[n].tag])
}

// ``Element.attlist()``: the non-default attributes sorted by name.
attlist :: proc(doc: ^Doc, n: Node, allocator := context.temp_allocator) -> []Attr_Item {
	out := make([dynamic]Attr_Item, 0, 8, allocator)
	for i := doc.nodes[n].attrs; i != 0; i = doc.attrs[i].next {
		a := doc.attrs[i]
		if !is_not_default(doc, n, a.key) do continue
		append(&out, Attr_Item{str(doc, a.key), a.value})
	}
	slice.sort_by(out[:], proc(a, b: Attr_Item) -> bool {return a.key < b.key})
	return out[:]
}

// --- list attributes ---------------------------------------------------------------

// A new list holding ``values``.
new_list :: proc(doc: ^Doc, values: ..string) -> List {
	l := List(len(doc.lists))
	items := make([dynamic]Str, 0, max(len(values), 2), doc.allocator)
	for v in values do append(&items, intern(doc, v))
	append(&doc.lists, items)
	return l
}

// The items of a list.
list_items :: proc(doc: ^Doc, l: List) -> []Str {
	return doc.lists[l][:]
}

// The items of the list attribute ``key`` (empty if missing or not a list).
attr_list :: proc(doc: ^Doc, n: Node, key: Attr_Key) -> []Str {
	v, _ := get_attr(doc, n, key)
	l, is_list := v.(List)
	return doc.lists[l][:] if is_list else nil
}

// The list attribute ``key`` for writing: created (empty) if it is missing,
// still the shared default, or not a list.
list_for_write :: proc(doc: ^Doc, n: Node, key: Attr_Key) -> ^[dynamic]Str {
	k, _ := key_id(doc, key, true)
	v, _ := get_attr(doc, n, k)
	l, is_list := v.(List)
	if !is_list || l == 0 {
		l = new_list(doc)
		set_attr(doc, n, k, l)
	}
	return &doc.lists[l]
}

Str_Or_String :: union {
	Str,
	string,
}

@(private = "file")
as_str :: proc(doc: ^Doc, v: Str_Or_String) -> Str {
	switch x in v {
	case Str:
		return x
	case string:
		return intern(doc, x)
	}
	return 0
}

// ``element[key].append(value)``.
list_append :: proc(doc: ^Doc, n: Node, key: Attr_Key, value: Str_Or_String) {
	append(list_for_write(doc, n, key), as_str(doc, value))
}

// ``value in element[key]``.
list_contains :: proc(doc: ^Doc, n: Node, key: Attr_Key, value: Str_Or_String) -> bool {
	s := as_str(doc, value)
	for x in attr_list(doc, n, key) do if x == s do return true
	return false
}

// ``element[key].remove(value)``; false if absent (Python raises).
list_remove :: proc(doc: ^Doc, n: Node, key: Attr_Key, value: Str_Or_String) -> bool {
	if !list_contains(doc, n, key, value) do return false
	l := list_for_write(doc, n, key)
	s := as_str(doc, value)
	for x, i in l^ {
		if x == s {
			ordered_remove(l, i)
			return true
		}
	}
	return false
}

// ``element[key] = [values...]``.
set_list :: proc(doc: ^Doc, n: Node, key: Attr_Key, values: ..string) {
	set_attr(doc, n, key, new_list(doc, ..values))
}

// ``Element.append_attr_list(attr, values)``: append the values not yet
// in the list.
append_attr_list :: proc(doc: ^Doc, n: Node, key: Attr_Key, values: []Str) {
	for v in values {
		if !list_contains(doc, n, key, v) do list_append(doc, n, key, v)
	}
}

// ``Element.update_basic_atts(other)``: merge ``ids``, ``classes``,
// ``names`` and ``dupnames`` of ``other`` into ``n``.
update_basic_atts :: proc(doc: ^Doc, n, other: Node) {
	for b in Basic_List.ids ..= Basic_List.dupnames {
		k := basic_key(b)
		values := attr_list(doc, other, k)
		if len(values) > 0 do append_attr_list(doc, n, k, values)
	}
}

// ``Element.add_backref(refid)``.
add_backref :: proc(doc: ^Doc, n: Node, refid: Str_Or_String) {
	list_append(doc, n, K_BACKREFS, refid)
}
