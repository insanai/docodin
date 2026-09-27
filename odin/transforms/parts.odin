package transforms

import "core:encoding/json"
import "core:fmt"
import "core:strings"

import dt "../doctree"

// ``docutils.transforms.parts``: ``SectNum`` and ``Contents``.

// --- SectNum ----------------------------------------------------------------------

@(private = "file")
Sectnum :: struct {
	doc:      ^dt.Doc,
	maxdepth: int,
	start:    int,
	prefix:   string,
	suffix:   string,
}

// ``SectNum``: number the section titles (with ``sectnum_xform``), else
// leave the numbering options to the writer.
sect_num :: proc(r: ^Run, pending: dt.Node, _: []dt.Detail) {
	doc := r.doc
	depth, has_depth := detail_int(doc, pending, "depth")
	s := Sectnum {
		doc = doc,
	}
	s.start = detail_int(doc, pending, "start") or_else 1
	s.prefix = detail_string(doc, pending, "prefix") or_else ""
	s.suffix = detail_string(doc, pending, "suffix") or_else ""
	py_remove(r, pending)
	if doc.settings.sectnum_xform {
		s.maxdepth = depth if has_depth else max(int)
		update_section_numbers(&s, doc.root, nil, 0)
		return
	}
	stored := Sectnum_Settings {
		start  = s.start,
		prefix = s.prefix,
		suffix = s.suffix,
	}
	if has_depth do stored.depth = depth
	r.result.sectnum = stored
	set_raw_setting(doc, "sectnum_depth", json.Integer(depth) if has_depth else json.Null{})
	set_raw_setting(doc, "sectnum_start", json.Integer(s.start))
	set_raw_setting(doc, "sectnum_prefix", json.String(dt.clone(doc, s.prefix)))
	set_raw_setting(doc, "sectnum_suffix", json.String(dt.clone(doc, s.suffix)))
}

@(private = "file")
update_section_numbers :: proc(s: ^Sectnum, node: dt.Node, prefix: []string, depth_in: int) {
	doc := s.doc
	ta := context.temp_allocator
	depth := depth_in + 1
	sectnum := 1 if len(prefix) > 0 else s.start
	for child in dt.children(doc, node) {
		if dt.tag(doc, child) != .section do continue
		numbers := make([]string, len(prefix) + 1, ta)
		copy(numbers, prefix)
		numbers[len(prefix)] = fmt.tprintf("%d", sectnum)
		title := dt.first_child(doc, child)
		label := strings.concatenate(
			{s.prefix, strings.join(numbers, ".", ta), s.suffix, "   "},
			ta,
		)
		generated := dt.new_element(doc, .generated, "", label)
		dt.set_list(doc, generated, dt.K_CLASSES, "sectnum")
		dt.insert_child(doc, title, 0, generated)
		dt.set_attr(doc, title, "auto", 1)
		if depth < s.maxdepth do update_section_numbers(s, child, numbers, depth)
		sectnum += 1
	}
}

// --- Contents --------------------------------------------------------------------

@(private = "file")
Contents :: struct {
	doc:       ^dt.Doc,
	pending:   dt.Node,
	toc_id:    dt.Str,
	backlinks: string, // "entry", "top" or "" (None/False)
	depth:     int,
}

// ``Contents``: a table of contents (a nested bullet list of references
// to the sections) replaces the pending element in its topic; an empty
// one removes the topic.  Not done when the writer builds the table
// (``use_latex_toc``).
contents :: proc(r: ^Run, pending: dt.Node, _: []dt.Detail) {
	doc := r.doc
	if doc.settings.use_latex_toc do return
	startnode := doc.root
	if _, local := dt.get_detail(doc, pending, "local"); local {
		startnode = dt.parent(doc, dt.parent(doc, pending))
		for !dt.is(doc, startnode, {.section, .document}) {
			if startnode == 0 {
				fail(r, "AttributeError: 'NoneType' object has no attribute 'parent'")
				return
			}
			startnode = dt.parent(doc, startnode)
		}
	}
	toc_id, has_id := first_item(doc, dt.parent(doc, pending), dt.K_IDS)
	if !has_id {
		fail(r, "IndexError: list index out of range")
		return
	}
	c := Contents {
		doc     = doc,
		pending = pending,
		toc_id  = toc_id,
		depth   = detail_int(doc, pending, "depth") or_else max(int),
	}
	if v, ok := dt.get_detail(doc, pending, "backlinks"); ok {
		c.backlinks = v.(string) or_else ""
	} else {
		c.backlinks = doc.settings.toc_backlinks
	}
	toc := build_contents(&c, startnode, 0)
	if toc != 0 {
		py_replace_self(r, pending, toc)
	} else {
		topic := dt.parent(doc, pending)
		py_remove(r, topic)
	}
}

@(private = "file")
build_contents :: proc(c: ^Contents, node: dt.Node, level_in: int) -> dt.Node {
	doc := c.doc
	level := level_in + 1
	entries := make([dynamic]dt.Node, 0, 8, context.temp_allocator)
	auto := false
	for section in dt.children(doc, node) {
		if dt.tag(doc, section) != .section do continue
		title := dt.first_child(doc, section)
		auto = attr_truthy(doc, title, "auto")
		entrytext := copy_and_filter(doc, title)
		reference := dt.new_element(doc, .reference)
		dt.extend_children(doc, reference, entrytext)
		sid, _ := first_item(doc, section, dt.K_IDS)
		dt.set_attr(doc, reference, dt.K_REFID, dt.str(doc, sid))
		ref_id := dt.set_id(doc, reference, suggested_prefix = "toc-entry")
		entry := dt.new_element(doc, .paragraph)
		dt.append_child(doc, entry, reference)
		item := dt.new_element(doc, .list_item)
		dt.append_child(doc, item, entry)
		if (c.backlinks == "entry" || c.backlinks == "top") &&
		   dt.next_node(doc, title, dt.Tag_Set{.reference}) == 0 {
			id := ref_id if c.backlinks == "entry" else c.toc_id
			dt.set_attr(doc, title, dt.K_REFID, dt.str(doc, id))
		}
		if level < c.depth {
			sub := build_contents(c, section, level)
			if sub != 0 do dt.append_child(doc, item, sub)
		}
		append(&entries, item)
	}
	if len(entries) == 0 do return 0
	contents := dt.new_element(doc, .bullet_list)
	dt.extend_children(doc, contents, entries[:])
	if auto do dt.list_append(doc, contents, dt.K_CLASSES, "auto-toc")
	return contents
}

// --- ContentsFilter ----------------------------------------------------------------

// ``ContentsFilter`` (a ``TreeCopyVisitor``): a copy of a title without
// references, footnote and citation references, targets and images (their
// ``alt`` text stays).
@(private = "file")
Copy_Visitor :: struct {
	using base: Visitor,
	parent:     dt.Node, // 0: the initial list
	stack:      [dynamic]dt.Node,
	roots:      [dynamic]dt.Node,
}

@(private = "file")
copy_and_filter :: proc(doc: ^dt.Doc, title: dt.Node) -> []dt.Node {
	v := Copy_Visitor {
		base = {
			doc = doc,
			visit = filter_visit,
			depart = filter_depart,
			visit_name = filter_visit_name,
			depart_name = filter_depart_name,
		},
		stack = make([dynamic]dt.Node, context.temp_allocator),
		roots = make([dynamic]dt.Node, context.temp_allocator),
	}
	walkabout(&v, title)
	return dt.children(doc, v.roots[0])
}

@(private = "file")
copy_append :: proc(v: ^Copy_Visitor, n: dt.Node) {
	if v.parent == 0 {
		append(&v.roots, n)
	} else {
		dt.append_child(v.doc, v.parent, n)
	}
}

@(private = "file")
filter_visit :: proc(base: ^Visitor, n: dt.Node) -> Visit {
	v := (^Copy_Visitor)(base)
	doc := v.doc
	#partial switch dt.tag(doc, n) {
	case .citation_reference, .footnote_reference:
		return .Skip_Node
	case .image:
		if alt, ok := dt.get_attr(doc, n, dt.K_ALT); ok {
			b := strings.builder_make(context.temp_allocator)
			dt.write_py_str(&b, doc, alt)
			copy_append(v, dt.new_text(doc, strings.to_string(b)))
		}
		return .Skip_Node
	case .problematic, .reference, .target:
		return .Skip_Departure
	}
	copy := dt.copy_node(doc, n)
	copy_append(v, copy)
	append(&v.stack, v.parent)
	v.parent = copy
	return .Continue
}

@(private = "file")
filter_depart :: proc(base: ^Visitor, n: dt.Node) {
	v := (^Copy_Visitor)(base)
	v.parent = pop(&v.stack)
}

@(private = "file")
filter_visit_name :: proc(t: dt.Tag) -> string {
	#partial switch t {
	case .citation_reference:
		return "visit_citation_reference"
	case .footnote_reference:
		return "visit_footnote_reference"
	case .image:
		return "visit_image"
	case .problematic, .reference, .target:
		return "ignore_node_but_process_children"
	case .Element:
		return "unknown_visit"
	}
	return "_call_default_visit"
}

@(private = "file")
filter_depart_name :: proc(t: dt.Tag) -> string {
	return "unknown_departure" if t == .Element else "_call_default_departure"
}
