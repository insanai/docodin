package transforms

import "core:fmt"
import "core:os"
import "core:strings"

import dt "../doctree"

// ``docutils.transforms.peps``: the transforms of the PEP reader.

@(private = "file")
PEP_CVS_URL :: "http://hg.python.org/peps/file/default/pep-%04d.txt"

@(private = "file")
NON_MASKED_ADDRESSES := [?]string {
	"peps@python.org",
	"python-list@python.org",
	"python-dev@python.org",
}

// The name of ``peps.TargetNotes.cleanup_callback`` as a ``CallBack`` detail.
PEP_CLEANUP_CALLBACK :: "docutils.transforms.peps.TargetNotes.cleanup_callback"

// ``settings.pep_base_url + 'pep-%04d' % n``.
@(private = "file")
pep_url :: proc(doc: ^dt.Doc, n: int) -> string {
	return fmt.tprintf("%spep-%04d", doc.settings.pep_base_url, n)
}

@(private = "file")
new_reference :: proc(doc: ^dt.Doc, raw, text, refuri: string) -> dt.Node {
	ref := dt.new_element(doc, .reference, raw, text)
	dt.set_attr(doc, ref, dt.K_REFURI, refuri)
	return ref
}

// ``int(s)`` of a Python ``str`` (ASCII digits, sign, underscores).
py_int :: proc(s: string) -> (int, bool) {
	t := py_strip(s)
	neg := strings.has_prefix(t, "-")
	if neg || strings.has_prefix(t, "+") do t = t[1:]
	if len(t) == 0 || t[0] == '_' || t[len(t) - 1] == '_' do return 0, false
	n := 0
	for i in 0 ..< len(t) {
		c := t[i]
		if c == '_' && t[i - 1] != '_' do continue
		if c < '0' || c > '9' do return 0, false
		n = n * 10 + int(c - '0')
	}
	return -n if neg else n, true
}

// --- Headers -----------------------------------------------------------------------

@(private = "file")
Pep :: struct {
	r:       ^Run,
	doc:     ^dt.Doc,
	number:  Maybe(int),
	cvs_url: string,
}

// ``peps.Headers``: process the fields of the PEP's RFC 2822 header.
pep_headers :: proc(r: ^Run, _: dt.Node, _: []dt.Detail) {
	doc := r.doc
	if length(doc, doc.root) == 0 {
		fail(r, "Document tree is empty.")
		return
	}
	header := dt.first_child(doc, doc.root)
	rfc2822 := dt.list_contains(doc, header, dt.K_CLASSES, "rfc2822")
	if dt.tag(doc, header) != .field_list || !rfc2822 {
		fail(r, "Document does not begin with an RFC-2822 header; it is not a PEP.")
		return
	}
	p := Pep {
		r   = r,
		doc = doc,
	}
	if !find_pep_number(&p, header) {
		fail(r, `Document does not contain an RFC-2822 "PEP" header.`)
		return
	}
	if n, ok := p.number.?; ok && n == 0 {
		pending := new_pending_of(doc, .Pep_Zero)
		dt.insert_child(doc, doc.root, 1, pending)
		dt.note_pending(doc, pending)
	}
	second := dt.child_at(doc, header, 1)
	if second == 0 || field_label(doc, second) != "title" {
		fail(r, "No title!")
		return
	}
	for field in dt.children(doc, header) {
		if !pep_field(&p, field) do return
	}
}

// The lowercased name of a field.
@(private = "file")
field_label :: proc(doc: ^dt.Doc, field: dt.Node) -> string {
	return dt.py_lower(dt.astext(doc, dt.child_at(doc, field, 0)))
}

@(private = "file")
find_pep_number :: proc(p: ^Pep, header: dt.Node) -> bool {
	doc := p.doc
	for field in dt.children(doc, header) {
		if field_label(doc, field) != "pep" do continue
		value := dt.astext(doc, dt.child_at(doc, field, 1))
		if n, ok := py_int(value); ok {
			p.number = n
			p.cvs_url = fmt.tprintf(PEP_CVS_URL, n)
			return true
		}
		format := `"PEP" header must contain an integer; "%s" is an invalid value.`
		text := fmt.tprintf(format, value)
		msg := dt.warning(doc, text, {base_node = field})
		msgid := dt.set_id(doc, msg)
		prb := dt.new_element(doc, .problematic, value, value if value != "" else "(none)")
		dt.set_attr(doc, prb, dt.K_REFID, dt.str(doc, msgid))
		dt.add_backref(doc, msg, dt.set_id(doc, prb))
		body := dt.child_at(doc, field, 1)
		if length(doc, body) > 0 {
			set_children(doc, dt.first_child(doc, body), {prb})
		} else {
			para := dt.new_element(doc, .paragraph)
			dt.append_child(doc, para, prb)
			dt.append_child(doc, body, para)
			dt.setup_child(doc, field, body) // ``field[1] += paragraph``
		}
		return true
	}
	return false
}

// One header field; false after an error.
@(private = "file")
pep_field :: proc(p: ^Pep, field: dt.Node) -> bool {
	doc := p.doc
	name := field_label(doc, field)
	body := dt.child_at(doc, field, 1)
	switch n := length(doc, body); {
	case n > 1:
		pep_field_error(p, field, "PEP header field body contains multiple elements:\n%s")
		return false
	case n == 1:
		if !dt.is(doc, dt.first_child(doc, body), {.paragraph}) {
			format := "PEP header field body may only contain a single paragraph:\n%s"
			pep_field_error(p, field, format)
			return false
		}
	case name == "last-modified":
		if p.cvs_url != "" {
			para := dt.new_element(doc, .paragraph)
			dt.append_child(doc, para, new_reference(doc, "", source_date(doc), p.cvs_url))
			dt.append_child(doc, body, para)
		}
	case:
		return true
	}
	para := dt.first_child(doc, body)
	if para == 0 {
		fail(p.r, "IndexError: list index out of range")
		return false
	}
	return pep_field_value(p, name, body, para)
}

@(private = "file")
pep_field_error :: proc(p: ^Pep, field: dt.Node, format: string) {
	listing := dt.pformat(p.doc, field, level = 1, allocator = context.temp_allocator)
	fail(p.r, format, listing)
}

// ``time.strftime('%d-%b-%Y', time.localtime(os.stat(document['source'])[8]))``
// (in UTC), "unknown" if the source cannot be read.
@(private = "file")
source_date :: proc(doc: ^dt.Doc) -> string {
	info, err := os.stat(dt.get_string(doc, doc.root, dt.K_SOURCE), context.temp_allocator)
	if err != nil do return "unknown"
	return strftime("%d-%b-%Y", info.modification_time)
}

@(private = "file")
pep_field_value :: proc(p: ^Pep, name: string, body, para: dt.Node) -> bool {
	doc := p.doc
	switch name {
	case "author":
		for n in dt.children(doc, para) {
			if dt.tag(doc, n) == .reference do replace_self(doc, n, mask_email(doc, n))
		}
	case "discussions-to":
		for n in dt.children(doc, para) {
			if dt.tag(doc, n) == .reference do replace_self(doc, n, mask_email(doc, n, p.number))
		}
	case "replaces", "replaced-by", "requires":
		return pep_list(p, body, para)
	case "last-modified":
		clean_rcs_keywords(doc, para, PEP_RCS_KEYWORDS)
		if p.cvs_url != "" {
			date := dt.astext(doc, para)
			set_children(doc, para, {new_reference(doc, "", date, p.cvs_url)})
		}
	case "content-type":
		pep_type := dt.astext(doc, para)
		set_children(doc, para, {new_reference(doc, "", pep_type, pep_url(doc, 12))})
	case "version":
		clean_rcs_keywords(doc, para, PEP_RCS_KEYWORDS)
	}
	return true
}

// "Replaces", "Replaced-By", "Requires": links to the PEPs.
@(private = "file")
pep_list :: proc(p: ^Pep, body, para: dt.Node) -> bool {
	doc := p.doc
	newbody := make([dynamic]dt.Node, 0, 8, context.temp_allocator)
	for refpep in split_pep_list(dt.astext(doc, body)) {
		pepno, ok := py_int(refpep)
		if !ok {
			fail(p.r, "ValueError: invalid literal for int() with base 10: %q", refpep)
			return false
		}
		if len(newbody) > 0 do append(&newbody, dt.new_text(doc, " "))
		append(&newbody, new_reference(doc, refpep, refpep, pep_url(doc, pepno)))
	}
	set_children(doc, para, newbody[:])
	return true
}

// ``re.split(r',?\s+', text)``.
@(private = "file")
split_pep_list :: proc(text: string) -> []string {
	out := make([dynamic]string, 0, 4, context.temp_allocator)
	start, i := 0, 0
	for i < len(text) {
		j := i
		if text[j] == ',' do j += 1
		k := j
		for k < len(text) && is_space_byte(text[k]) do k += 1
		if k > j {
			append(&out, text[start:i])
			start, i = k, k
		} else {
			i += 1
		}
	}
	append(&out, text[start:])
	return out[:]
}

@(private = "file")
is_space_byte :: proc(c: u8) -> bool {
	return c == ' ' || (c >= '\t' && c <= '\r') || (c >= 0x1c && c <= 0x1f)
}

// ``peps.mask_email(ref, pepno)``: an e-mail reference as masked text (or
// kept, for the public lists); with a PEP number the reference stays, with
// a subject.
mask_email :: proc(doc: ^dt.Doc, ref: dt.Node, pepno: Maybe(int) = nil) -> dt.Node {
	refuri := dt.get_string(doc, ref, dt.K_REFURI)
	if !dt.has_attr(doc, ref, dt.K_REFURI) || !strings.has_prefix(refuri, "mailto:") do return ref
	replacement: dt.Node
	address := refuri[min(8, len(refuri)):]
	masked := true
	for a in NON_MASKED_ADDRESSES do if a == address do masked = false
	if !masked {
		replacement = dt.first_child(doc, ref)
	} else {
		ta := context.temp_allocator
		text, _ := strings.replace_all(dt.astext(doc, ref), "@", "&#32;&#97;t&#32;", ta)
		replacement = dt.new_element(doc, .raw, "", text)
		dt.set_attr(doc, replacement, "format", "html")
	}
	n, has_pep := pepno.?
	if !has_pep do return replacement
	dt.set_attr(doc, ref, dt.K_REFURI, fmt.tprintf("%s?subject=PEP%%20%d", refuri, n))
	set_children(doc, ref, {replacement})
	return ref
}

// --- Contents, TargetNotes -------------------------------------------------------------

// ``peps.Contents``: an empty table of contents (with a pending
// ``parts.Contents``) after the header.
pep_contents :: proc(r: ^Run, _: dt.Node, _: []dt.Detail) {
	doc := r.doc
	label := language(r).labels[.contents]
	topic := dt.new_element(doc, .topic)
	dt.append_child(doc, topic, dt.new_element(doc, .title, "", label))
	dt.set_list(doc, topic, dt.K_CLASSES, "contents")
	name := dt.fully_normalize_name(label)
	if !dt.has_name(doc, name) do dt.list_append(doc, topic, dt.K_NAMES, name)
	dt.note_implicit_target(doc, topic)
	pending := new_pending_of(doc, .Contents)
	dt.append_child(doc, topic, pending)
	dt.insert_child(doc, doc.root, 1, topic)
	dt.note_pending(doc, pending)
}

// ``peps.TargetNotes``: a pending ``references.TargetNotes`` at the end of
// the "References" section (created if missing), run next.
pep_target_notes :: proc(r: ^Run, _: dt.Node, _: []dt.Detail) {
	doc := r.doc
	refsect: dt.Node
	copyright := 0
	for i := length(doc, doc.root) - 1; i >= 0; i -= 1 {
		section := dt.child_at(doc, doc.root, i)
		if dt.tag(doc, section) != .section do break
		words := dt.py_split(dt.py_lower(dt.astext(doc, dt.first_child(doc, section))))
		if contains_string(words, "references") {
			refsect = section
			break
		} else if contains_string(words, "copyright") {
			copyright = i
		}
	}
	if refsect == 0 {
		refsect = dt.new_element(doc, .section)
		dt.append_child(doc, refsect, dt.new_element(doc, .title, "", "References"))
		dt.set_id(doc, refsect)
		if copyright != 0 {
			dt.insert_child(doc, doc.root, copyright, refsect)
		} else {
			dt.append_child(doc, doc.root, refsect)
		}
	}
	notes := new_pending_of(doc, .Target_Notes)
	dt.append_child(doc, refsect, notes)
	dt.note_pending(doc, notes, 0)
	details := []dt.Detail{{"callback", PEP_CLEANUP_CALLBACK}}
	callback := new_pending_of(doc, .Call_Back, details)
	dt.append_child(doc, refsect, callback)
	dt.note_pending(doc, callback, 1)
}

@(private = "file")
contains_string :: proc(list: []string, s: string) -> bool {
	for x in list do if x == s do return true
	return false
}

// ``TargetNotes.cleanup_callback``: remove an empty "References" section.
pep_cleanup_callback :: proc(r: ^Run, pending: dt.Node) {
	doc := r.doc
	section := dt.parent(doc, pending)
	if length(doc, section) == 2 do py_remove(r, section)
}

// --- PEPZero ---------------------------------------------------------------------------

@(private = "file")
Zero_Visitor :: struct {
	using base: Visitor,
	pep_table:  bool,
	entry:      int,
}

// ``peps.PEPZero``: mask e-mail addresses and link the PEP numbers of the
// index tables.
pep_zero :: proc(r: ^Run, pending: dt.Node, _: []dt.Detail) {
	doc := r.doc
	v := Zero_Visitor {
		base = {
			doc = doc,
			visit = zero_visit,
			visit_name = zero_visit_name,
			depart_name = sparse_visit_name,
		},
	}
	walk(&v, doc.root)
	py_remove(r, pending)
}

@(private = "file")
zero_visit_name :: proc(t: dt.Tag) -> string {
	#partial switch t {
	case .reference, .field_list, .tgroup, .colspec, .row, .entry:
		return strings.concatenate({"visit_", dt.TAG_NAMES[t]}, context.temp_allocator)
	}
	return sparse_visit_name(t)
}

@(private = "file")
zero_visit :: proc(base: ^Visitor, n: dt.Node) -> Visit {
	v := (^Zero_Visitor)(base)
	doc := v.doc
	#partial switch dt.tag(doc, n) {
	case .reference:
		replace_self(doc, n, mask_email(doc, n))
	case .field_list:
		if dt.list_contains(doc, n, dt.K_CLASSES, "rfc2822") do return .Skip_Node
	case .tgroup:
		v.pep_table = dt.get_int(doc, n, "cols") == 4
		v.entry = 0
	case .colspec, .entry:
		v.entry += 1
		if v.pep_table && v.entry == 2 do number_column(doc, n)
	case .row:
		v.entry = 0
	}
	return .Continue
}

// The second column of a PEP table: class "num", and PEP numbers linked.
@(private = "file")
number_column :: proc(doc: ^dt.Doc, n: dt.Node) {
	if dt.tag(doc, n) == .colspec {
		dt.list_append(doc, n, dt.K_CLASSES, "num")
	} else if length(doc, n) == 1 {
		link_pep_number(doc, n)
	}
}

@(private = "file")
link_pep_number :: proc(doc: ^dt.Doc, entry: dt.Node) {
	dt.list_append(doc, entry, dt.K_CLASSES, "num")
	p := dt.first_child(doc, entry)
	if !dt.is(doc, p, {.paragraph}) || length(doc, p) != 1 do return
	text := dt.astext(doc, p)
	pep, ok := py_int(text)
	if !ok do return
	set_child_at(doc, p, 0, new_reference(doc, text, text, pep_url(doc, pep)))
}
