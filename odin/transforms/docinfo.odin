package transforms

import "core:fmt"
import "core:strings"

import dt "../doctree"

// ``DocInfo``: RCS keyword cleanup and the "Authors" field.

// --- RCS keywords -----------------------------------------------------------------

// The ``rcs_keyword_substitutions`` patterns, as scanners:
//
// * ``Date``: ``\$Date: (\d\d\d\d)[-/](\d\d)[-/](\d\d)[ T][\d:]+[^$]* \$``
//   (ignoring case) -> ``\1-\2-\3``
// * ``RCSfile``: ``\$RCSfile: (.+),v \$`` (ignoring case) -> ``\1``
// * ``Keyword``: ``\$[a-zA-Z]+: (.+) \$`` -> ``\1``
// * the PEP reader's ``RCSfile`` and ``Keyword`` anchored at the end (``$``).
Rcs_Pattern :: enum u8 {
	Date,
	Rcsfile,
	Keyword,
	Rcsfile_End,
	Keyword_End,
}

@(rodata)
DOCINFO_RCS_KEYWORDS := []Rcs_Pattern{.Date, .Rcsfile, .Keyword}

@(rodata)
PEP_RCS_KEYWORDS := []Rcs_Pattern{.Rcsfile_End, .Keyword_End}

// A match of a pattern: ``text[start:end]``, replaced by ``replacement``.
@(private = "file")
Rcs_Match :: struct {
	start, end:  int,
	replacement: string,
}

@(private = "file")
is_digit :: proc(c: u8) -> bool {
	return c >= '0' && c <= '9'
}

@(private = "file")
is_letter :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

// ``text[i:]`` starts with ``prefix``, ASCII case ignored.
@(private = "file")
has_prefix_fold :: proc(text: string, i: int, prefix: string) -> bool {
	if i + len(prefix) > len(text) do return false
	return strings.equal_fold(text[i:][:len(prefix)], prefix)
}

// The end of the line of ``text`` at ``i`` (``.`` does not match "\n").
@(private = "file")
line_end :: proc(text: string, i: int) -> int {
	nl := strings.index_byte(text[i:], '\n')
	return len(text) if nl < 0 else i + nl
}

// ``(.+)<suffix>`` greedy from ``start`` on the line: the start of the
// last ``suffix`` (ASCII case ignored with ``fold``) after at least one
// character, -1 if there is none.
@(private = "file")
greedy_until :: proc(text: string, start: int, suffix: string, fold: bool, anchored: bool) -> int {
	end := line_end(text, start)
	if anchored {
		// ``$``: at the end, or before a final newline
		if end != len(text) && end != len(text) - 1 do return -1
		j := end - len(suffix)
		if j < start + 1 do return -1
		ok := strings.equal_fold(text[j:end], suffix) if fold else text[j:end] == suffix
		return j if ok else -1
	}
	for j := end - len(suffix); j >= start + 1; j -= 1 {
		candidate := text[j:][:len(suffix)]
		ok := strings.equal_fold(candidate, suffix) if fold else candidate == suffix
		if ok do return j
	}
	return -1
}

// ``(\d\d\d\d)[-/](\d\d)[-/](\d\d)[ T]`` (the ``T`` ignoring case).
@(private = "file")
is_date_time :: proc(d: string) -> bool {
	for k in ([]int{0, 1, 2, 3, 5, 6, 8, 9}) do if !is_digit(d[k]) do return false
	is_sep :: proc(c: u8) -> bool {return c == '-' || c == '/'}
	return is_sep(d[4]) && is_sep(d[7]) && (d[10] == ' ' || d[10] == 'T' || d[10] == 't')
}

@(private = "file")
match_date :: proc(text: string, i: int) -> (Rcs_Match, bool) {
	p := i + len("$Date: ")
	if !has_prefix_fold(text, i, "$Date: ") || p + 12 > len(text) do return {}, false
	d := text[p:]
	if !is_date_time(d) do return {}, false
	q := p + 11
	if !is_digit(text[q]) && text[q] != ':' do return {}, false
	dollar := strings.index_byte(text[q + 1:], '$')
	if dollar < 0 do return {}, false
	k := q + 1 + dollar
	if k - 1 < q + 1 || text[k - 1] != ' ' do return {}, false
	replacement := strings.concatenate({d[0:4], "-", d[5:7], "-", d[8:10]}, context.temp_allocator)
	return {i, k + 1, replacement}, true
}

@(private = "file")
match_rcsfile :: proc(text: string, i: int, anchored: bool) -> (Rcs_Match, bool) {
	if !has_prefix_fold(text, i, "$RCSfile: ") do return {}, false
	start := i + len("$RCSfile: ")
	j := greedy_until(text, start, ",v $", true, anchored)
	if j < 0 do return {}, false
	return {i, j + len(",v $"), text[start:j]}, true
}

@(private = "file")
match_keyword :: proc(text: string, i: int, anchored: bool) -> (Rcs_Match, bool) {
	p := i + 1
	for p < len(text) && is_letter(text[p]) do p += 1
	if p == i + 1 || !strings.has_prefix(text[p:], ": ") do return {}, false
	start := p + 2
	j := greedy_until(text, start, " $", false, anchored)
	if j < 0 do return {}, false
	return {i, j + 2, text[start:j]}, true
}

// The leftmost match of ``pattern`` in ``text[from:]``.
@(private = "file")
rcs_search :: proc(text: string, from: int, pattern: Rcs_Pattern) -> (Rcs_Match, bool) {
	for i := from; i < len(text); i += 1 {
		if text[i] != '$' do continue
		m: Rcs_Match
		ok: bool
		switch pattern {
		case .Date:
			m, ok = match_date(text, i)
		case .Rcsfile:
			m, ok = match_rcsfile(text, i, false)
		case .Rcsfile_End:
			m, ok = match_rcsfile(text, i, true)
		case .Keyword:
			m, ok = match_keyword(text, i, false)
		case .Keyword_End:
			m, ok = match_keyword(text, i, true)
		}
		if ok do return m, true
	}
	return {}, false
}

// ``pattern.sub(replacement, text)``.
@(private = "file")
rcs_sub :: proc(text: string, pattern: Rcs_Pattern) -> string {
	b := strings.builder_make(context.temp_allocator)
	pos := 0
	for {
		m, ok := rcs_search(text, pos, pattern)
		if !ok do break
		strings.write_string(&b, text[pos:m.start])
		strings.write_string(&b, m.replacement)
		pos = m.end
	}
	strings.write_string(&b, text[pos:])
	return strings.to_string(b)
}

// ``utils.clean_rcs_keywords(paragraph, patterns)``: the first pattern that
// matches the paragraph's lone text is substituted.
clean_rcs_keywords :: proc(doc: ^dt.Doc, paragraph: dt.Node, patterns: []Rcs_Pattern) {
	text_node := dt.first_child(doc, paragraph)
	if length(doc, paragraph) != 1 || dt.tag(doc, text_node) != .Text do return
	text := dt.text(doc, text_node)
	for p in patterns {
		if _, ok := rcs_search(text, 0, p); !ok do continue
		set_child_at(doc, paragraph, 0, dt.new_text(doc, rcs_sub(text, p)))
		return
	}
}

// --- authors ----------------------------------------------------------------------------

// ``DocInfo.extract_authors``: the "Authors" field as an ``authors``
// element; false (with a warning in the field) if it has no usable form.
extract_authors :: proc(st: ^Docinfo_State, field: dt.Node, name: string) -> bool {
	doc := st.doc
	body := dt.child_at(doc, field, 1)
	authors: [][]dt.Node
	ok: bool
	if length(doc, body) == 1 {
		first := dt.first_child(doc, body)
		#partial switch dt.tag(doc, first) {
		case .paragraph:
			authors, ok = authors_from_one_paragraph(st, body)
		case .bullet_list:
			authors, ok = authors_from_bullet_list(doc, first)
		}
	} else {
		authors, ok = authors_from_paragraphs(doc, body)
	}
	if ok {
		authornodes := make([dynamic]dt.Node, 0, len(authors), context.temp_allocator)
		for author in authors {
			if len(author) == 0 do continue
			el := dt.new_element(doc, .author)
			dt.extend_children(doc, el, author)
			append(&authornodes, el)
		}
		if len(authornodes) >= 1 {
			el := dt.new_element(doc, .authors)
			dt.extend_children(doc, el, authornodes[:])
			dt.append_child(doc, st.docinfo, el)
			return true
		}
	}
	separators := strings.concatenate(language(st.r).separators, context.temp_allocator)
	text := fmt.tprintf(AUTHORS_WARNING, name, name, separators)
	append_to_last(doc, field, dt.warning(doc, text, {base_node = field}))
	return false
}

@(private = "file")
AUTHORS_WARNING ::
	"Cannot extract \"%s\" from bibliographic field:\n" +
	"Bibliographic field \"%s\" must contain either\n" +
	" a single paragraph (with author names separated by a character from the set \"%s\"),\n" +
	" multiple paragraphs (one per author),\n" +
	" or a bullet list with one author name per item.\n" +
	"Note: Leading initials can cause (mis)recognizing names as enumerated list."

// Author names separated by one of the language's author separators (not
// escaped), each as a new Text node.
@(private = "file")
authors_from_one_paragraph :: proc(st: ^Docinfo_State, body: dt.Node) -> ([][]dt.Node, bool) {
	doc := st.doc
	ta := context.temp_allocator
	b := strings.builder_make(ta)
	for t in dt.traverse(doc, body, dt.Tag_Set{.Text}) do strings.write_string(&b, dt.text(doc, t))
	text := strings.to_string(b)
	if text == "" do return nil, false
	names: []string
	for sep in language(st.r).separators {
		names = split_unescaped(text, sep)
		if len(names) > 1 do break
	}
	out := make([dynamic][]dt.Node, 0, len(names), ta)
	for n in names {
		s := py_strip(n)
		if s == "" do continue
		author := make([]dt.Node, 1, ta)
		author[0] = dt.new_text(doc, s)
		append(&out, author)
	}
	return out[:], true
}

// ``re.split('(?<!\x00)' + sep, text)``.
@(private = "file")
split_unescaped :: proc(text, sep: string) -> []string {
	out := make([dynamic]string, 0, 4, context.temp_allocator)
	start, i := 0, 0
	for i <= len(text) - len(sep) {
		if text[i:][:len(sep)] == sep && (i == 0 || text[i - 1] != 0) {
			append(&out, text[start:i])
			i += len(sep)
			start = i
		} else {
			i += 1
		}
	}
	append(&out, text[start:])
	return out[:]
}

@(private = "file")
authors_from_bullet_list :: proc(doc: ^dt.Doc, list: dt.Node) -> ([][]dt.Node, bool) {
	out := make([dynamic][]dt.Node, 0, 4, context.temp_allocator)
	for item in dt.children(doc, list) {
		if dt.tag(doc, item) == .comment do continue
		first := dt.first_child(doc, item)
		if length(doc, item) != 1 || !dt.is(doc, first, {.paragraph}) do return nil, false
		append(&out, dt.children(doc, first))
	}
	return out[:], len(out) > 0
}

@(private = "file")
authors_from_paragraphs :: proc(doc: ^dt.Doc, body: dt.Node) -> ([][]dt.Node, bool) {
	out := make([dynamic][]dt.Node, 0, 4, context.temp_allocator)
	for item in dt.children(doc, body) {
		#partial switch dt.tag(doc, item) {
		case .comment:
		case .paragraph:
			append(&out, dt.children(doc, item))
		case:
			return nil, false
		}
	}
	return out[:], true
}
