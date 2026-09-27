package lsp

// Completion (``textDocument/completion``) and the directive and role
// tables it offers (docutils' English names, ``languages.en``):
//
// * directive names after ``.. `` (and after ``.. |name| ``);
// * options of a known directive on the lines of its option block;
// * role names in ``:name`` at the start of a word;
// * reference names in `` `text `` and before ``_``, substitution names
//   after ``|``, footnote and citation labels after ``[``: the names the
//   document defines.

import "core:strings"

import rd "../reader"

Directive_Entry :: struct {
	name: string,
	spec: ^rd.Directive_Spec,
}

// ``languages.en.directives`` with the registry's specs.
DIRECTIVES := [?]Directive_Entry {
	{"attention", &rd.ATTENTION},
	{"caution", &rd.CAUTION},
	{"code", &rd.CODE_BLOCK},
	{"code-block", &rd.CODE_BLOCK},
	{"sourcecode", &rd.CODE_BLOCK},
	{"danger", &rd.DANGER},
	{"error", &rd.ERROR},
	{"important", &rd.IMPORTANT},
	{"note", &rd.NOTE},
	{"tip", &rd.TIP},
	{"hint", &rd.HINT},
	{"warning", &rd.WARNING},
	{"admonition", &rd.ADMONITION},
	{"sidebar", &rd.SIDEBAR},
	{"topic", &rd.TOPIC},
	{"line-block", &rd.LINE_BLOCK},
	{"parsed-literal", &rd.PARSED_LITERAL},
	{"math", &rd.MATH_BLOCK},
	{"rubric", &rd.RUBRIC},
	{"epigraph", &rd.EPIGRAPH},
	{"highlights", &rd.HIGHLIGHTS},
	{"pull-quote", &rd.PULL_QUOTE},
	{"compound", &rd.COMPOUND},
	{"container", &rd.CONTAINER},
	{"table", &rd.RST_TABLE},
	{"csv-table", &rd.CSV_TABLE},
	{"list-table", &rd.LIST_TABLE},
	{"meta", &rd.META},
	{"image", &rd.IMAGE},
	{"figure", &rd.FIGURE},
	{"include", &rd.INCLUDE},
	{"raw", &rd.RAW},
	{"replace", &rd.REPLACE},
	{"unicode", &rd.UNICODE},
	{"date", &rd.DATE},
	{"class", &rd.CLASS},
	{"role", &rd.ROLE},
	{"default-role", &rd.DEFAULT_ROLE},
	{"title", &rd.TITLE},
	{"contents", &rd.CONTENTS},
	{"sectnum", &rd.SECTNUM},
	{"section-numbering", &rd.SECTNUM},
	{"header", &rd.HEADER},
	{"footer", &rd.FOOTER},
	{"target-notes", &rd.TARGET_NOTES},
}

// ``languages.en.roles``: the role name and what it stands for.
@(rodata)
ROLES := [?][2]string {
	{"abbreviation", "abbreviation"},
	{"ab", "abbreviation"},
	{"acronym", "acronym"},
	{"ac", "acronym"},
	{"code", "code"},
	{"emphasis", "emphasis"},
	{"literal", "literal"},
	{"math", "math"},
	{"pep-reference", "pep-reference"},
	{"pep", "pep-reference"},
	{"rfc-reference", "rfc-reference"},
	{"rfc", "rfc-reference"},
	{"strong", "strong"},
	{"subscript", "subscript"},
	{"sub", "subscript"},
	{"superscript", "superscript"},
	{"sup", "superscript"},
	{"title-reference", "title-reference"},
	{"title", "title-reference"},
	{"t", "title-reference"},
	{"raw", "raw"},
}

find_directive :: proc(name: string) -> (Directive_Entry, bool) {
	lower := strings.to_lower(name, context.temp_allocator)
	for e in DIRECTIVES do if e.name == lower do return e, true
	return {}, false
}

directive_hover :: proc(name: string) -> string {
	e, ok := find_directive(name)
	if !ok do return strings.concatenate({"Unknown directive `", name, "`"})
	spec := e.spec
	b := strings.builder_make()
	strings.write_string(&b, "**Directive** `")
	strings.write_string(&b, e.name)
	strings.write_string(&b, "::`\n\n")
	strings.write_string(&b, "Arguments: ")
	strings.write_int(&b, spec.required_arguments)
	strings.write_string(&b, " required, ")
	strings.write_int(&b, spec.optional_arguments)
	strings.write_string(&b, " optional. Content: ")
	strings.write_string(&b, "yes" if spec.has_content else "no")
	strings.write_string(&b, ".")
	if len(spec.option_spec) > 0 {
		strings.write_string(&b, "\n\nOptions:")
		for o in spec.option_spec {
			strings.write_string(&b, " `:")
			strings.write_string(&b, o.name)
			strings.write_string(&b, ":`")
		}
	}
	return strings.to_string(b)
}

role_hover :: proc(name: string) -> string {
	for r in ROLES {
		if r[0] == name {
			return strings.concatenate({"**Role** `:", r[0], ":` (", r[1], ")"})
		}
	}
	return strings.concatenate({"Unknown role `", name, "` (not a standard docutils role)"})
}

// --- completion ------------------------------------------------------------------------

// LSP ``CompletionItemKind`` values.
@(private = "file")
Completion_Kind :: enum int {
	Function  = 3,
	Property  = 10,
	Keyword   = 14,
	Reference = 18,
	Variable  = 6,
}

@(private = "file")
Candidate :: struct {
	label:  string,
	insert: string,
	kind:   Completion_Kind,
	detail: string,
}

// ``textDocument/completion`` at ``p``: a ``CompletionList``.
completion :: proc(w: ^Json_Writer, s: ^Snapshot, p: Pos, enc: Encoding) {
	out := make([dynamic]Candidate, 0, 32)
	line := expanded(&s.ix, int(p.line))
	col := min(int(p.col), len(line))
	before := line[:col]
	switch {
	case complete_directive(&out, before):
	case complete_option(&out, &s.ix, int(p.line), before):
	case complete_names(&out, &s.analysis, before):
	case complete_role(&out, before):
	}
	// the candidates replace the word before the cursor
	replaced := Span{{p.line, i32(word_start(before))}, {p.line, i32(col)}}
	obj_begin(w)
	key_bool(w, "isIncomplete", false)
	key(w, "items")
	arr_begin(w)
	for c in out {
		obj_begin(w)
		key_str(w, "label", c.label)
		key_int(w, "kind", int(c.kind))
		if c.detail != "" do key_str(w, "detail", c.detail)
		key(w, "textEdit")
		obj_begin(w)
		key(w, "range")
		write_range(w, &s.ix, replaced, enc)
		key_str(w, "newText", c.insert)
		obj_end(w)
		obj_end(w)
	}
	arr_end(w)
	obj_end(w)
}

// The word being typed at the end of ``before``: letters, digits and the
// characters of reference names.
@(private = "file")
word_start :: proc(before: string) -> int {
	i := len(before)
	for i > 0 {
		c := before[i - 1]
		alnum := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
		if !alnum && c != '-' && c != '_' && c != '.' && c != '+' && c < 0x80 do break
		i -= 1
	}
	return i
}

// ``.. name`` or ``.. |sub| name``: directive names.
@(private = "file")
complete_directive :: proc(out: ^[dynamic]Candidate, before: string) -> bool {
	start := word_start(before)
	head := strings.trim_left(before[:start], " ")
	if head != ".. " {
		if !strings.has_prefix(head, ".. |") || !strings.has_suffix(head, "| ") do return false
	}
	for e in DIRECTIVES {
		insert := strings.concatenate({e.name, ":: "})
		append(out, Candidate{e.name, insert, .Function, "directive"})
	}
	return true
}

// ``:name`` on a line of a directive's option block.
@(private = "file")
complete_option :: proc(
	out: ^[dynamic]Candidate,
	ix: ^Line_Index,
	line: int,
	before: string,
) -> bool {
	start := word_start(before)
	head := before[:start]
	if !strings.has_suffix(head, ":") || strings.trim_space(head) != ":" do return false
	indent := len(head) - 1
	for l := line - 1; l >= 0; l -= 1 {
		text := expanded(ix, l)
		if is_blank(text) do return false
		body := strings.trim_left(text, " ")
		lindent := len(text) - len(body)
		if lindent >= indent do continue
		name, _, ok := directive_line(body)
		if !ok do return false
		e, known := find_directive(name)
		if !known do return false
		for o in e.spec.option_spec {
			label := strings.concatenate({":", o.name, ":"})
			insert := strings.concatenate({o.name, ": "})
			append(out, Candidate{label, insert, .Property, e.name})
		}
		return true
	}
	return false
}

// The directive name of an explicit markup line ``.. name::`` (or
// ``.. |sub| name::``).
@(private = "file")
directive_line :: proc(body: string) -> (name: string, end: int, ok: bool) {
	if !strings.has_prefix(body, ".. ") do return
	rest := body[3:]
	offset := 3
	if strings.has_prefix(rest, "|") {
		bar := strings.index_byte(rest[1:], '|')
		if bar < 0 do return
		offset += bar + 2
		rest = strings.trim_left(rest[bar + 2:], " ")
		offset = len(body) - len(rest)
	}
	colons := strings.index(rest, "::")
	if colons <= 0 do return
	return rest[:colons], offset + colons + 2, true
}

// Reference names, substitution names and labels the document defines.
@(private = "file")
complete_names :: proc(out: ^[dynamic]Candidate, a: ^Analysis, before: string) -> bool {
	start := word_start(before)
	trigger := before[start - 1] if start > 0 else 0
	switch trigger {
	case '|':
		for item in a.items {
			if item.kind != .Substitution_Definition do continue
			insert := strings.concatenate({item.label, "|"})
			append(out, Candidate{item.label, insert, .Variable, "substitution"})
		}
		return true
	case '[':
		for item in a.items {
			if item.kind != .Footnote && item.kind != .Citation do continue
			if item.label == "*" do continue
			insert := strings.concatenate({item.label, "]_"})
			append(out, Candidate{item.label, insert, .Reference, symbol_word(item.kind)})
		}
		return true
	case '`':
		if start >= 2 && before[start - 2] == ':' do return false // a role's text
		complete_targets(out, a)
		return true
	}
	return false
}

// The reference names of the document's targets, sections and citations.
@(private = "file")
complete_targets :: proc(out: ^[dynamic]Candidate, a: ^Analysis) {
	seen := make(map[string]bool)
	for item in a.items {
		if item.kind not_in NAMED_TARGETS || item.name == "" || item.name in seen do continue
		seen[item.name] = true
		insert := strings.concatenate({item.label, "`_"})
		append(out, Candidate{item.label, insert, .Reference, symbol_word(item.kind)})
	}
}

@(private = "file")
NAMED_TARGETS :: Item_Kinds {
	.Section, .Target, .Inline_Target, .Embedded_Target, .Name_Option, .Citation,
}

@(private = "file")
symbol_word :: proc(kind: Item_Kind) -> string {
	#partial switch kind {
	case .Section:
		return "section"
	case .Footnote:
		return "footnote"
	case .Citation:
		return "citation"
	}
	return "target"
}

// ``:name`` at the start of a word: role names.
@(private = "file")
complete_role :: proc(out: ^[dynamic]Candidate, before: string) -> bool {
	start := word_start(before)
	if start == 0 || before[start - 1] != ':' do return false
	if start >= 2 && before[start - 2] != ' ' && before[start - 2] != '(' do return false
	for r in ROLES {
		insert := strings.concatenate({r[0], ":`"})
		append(out, Candidate{r[0], insert, .Keyword, r[1]})
	}
	return true
}
