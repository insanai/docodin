package dod

import "core:os"
import "core:strings"
import "core:time"

// ``docodin dod index`` and ``docodin dod new``.

// ``text`` (index.rst) with the records by state between the markers;
// false when the markers are missing.
update_index :: proc(
	text: string,
	records: []Record,
	allocator := context.allocator,
) -> (
	string,
	bool,
) {
	start := strings.index(text, INDEX_START)
	end := strings.index(text, INDEX_END)
	if start < 0 || end < start do return text, false
	head := text[:start + len(INDEX_START)]
	sb := strings.builder_make(allocator)
	strings.write_string(&sb, head)
	strings.write_string(&sb, "\n\n")
	strings.write_string(&sb, index_body(records))
	strings.write_string(&sb, text[end:])
	return strings.to_string(sb), true
}

// The order of the states in the index: the settled records first.
INDEX_ORDER := [?]string {
	"committed", "published", "discussion", "ideation", "prediscussion", "abandoned",
}

// The records by state: a section per state (underlined with "-") listing
// the records as ``:doc:`DOD n: Title <file>```.
index_body :: proc(records: []Record) -> string {
	sb := strings.builder_make(context.temp_allocator)
	any := false
	for state in INDEX_ORDER {
		first := true
		for &r in records {
			if r.number <= 0 || field_value(&r, "State") != state do continue
			if first {
				heading := capitalize(state)
				strings.write_string(&sb, heading)
				strings.write_byte(&sb, '\n')
				underline := strings.repeat("-", len(heading), context.temp_allocator)
				strings.write_string(&sb, underline)
				strings.write_string(&sb, "\n\n")
				first = false
			}
			strings.write_string(&sb, "- :doc:`")
			strings.write_string(&sb, r.title)
			strings.write_string(&sb, " <")
			strings.write_string(&sb, strings.trim_suffix(r.file, ".rst"))
			strings.write_string(&sb, ">`\n")
			any = true
		}
		if !first do strings.write_string(&sb, "\n")
	}
	if !any do strings.write_string(&sb, "There are no records yet.\n\n")
	return strings.to_string(sb)
}

@(private = "file")
capitalize :: proc(s: string) -> string {
	if s == "" do return s
	return strings.concatenate({strings.to_upper(s[:1], context.temp_allocator), s[1:]},
		context.temp_allocator)
}

// --- new records ---------------------------------------------------------------------------

// The next number: one more than the records' and the ``dod/NNNN`` git
// branches' (local and remote) of the repository holding ``dir``.
next_number :: proc(dir: string, records: []Record) -> int {
	highest := 0
	for r in records do highest = max(highest, r.number)
	for n in branch_numbers(dir) do highest = max(highest, n)
	return highest + 1
}

@(private = "file")
branch_numbers :: proc(dir: string) -> []int {
	out := make([dynamic]int, context.temp_allocator)
	command := []string{"git", "-C", dir, "branch", "-a", "--format=%(refname:short)"}
	state, stdout, _, err := os.process_exec(os.Process_Desc{command = command},
		context.temp_allocator)
	if err != nil || !state.success do return out[:]
	rest := string(stdout)
	for line in strings.split_lines_iterator(&rest) {
		i := strings.index(line, "dod/")
		if i < 0 || len(line) < i + 8 do continue
		n, _ := parse_file_name(strings.concatenate({line[i + 4:i + 8], "-x.rst"},
			context.temp_allocator))
		if n >= 0 do append(&out, n)
	}
	return out[:]
}

// "Name <email>" from git's configuration ("" without git).
git_author :: proc(dir: string) -> string {
	name := git_config(dir, "user.name")
	email := git_config(dir, "user.email")
	if name == "" do return email
	if email == "" do return name
	return strings.concatenate({name, " <", email, ">"})
}

@(private = "file")
git_config :: proc(dir, key: string) -> string {
	command := []string{"git", "-C", dir, "config", "--get", key}
	state, stdout, _, err := os.process_exec(os.Process_Desc{command = command},
		context.temp_allocator)
	if err != nil || !state.success do return ""
	return strings.clone(strings.trim_space(string(stdout)))
}

// Today as YYYY-MM-DD.
today :: proc() -> string {
	y, m, d := time.date(time.now())
	sb := strings.builder_make()
	strings.write_string(&sb, itoa(y))
	strings.write_byte(&sb, '-')
	if int(m) < 10 do strings.write_byte(&sb, '0')
	strings.write_string(&sb, itoa(int(m)))
	strings.write_byte(&sb, '-')
	if d < 10 do strings.write_byte(&sb, '0')
	strings.write_string(&sb, itoa(d))
	return strings.to_string(sb)
}

New_Record :: struct {
	number: int,
	title:  string,
	labels: string,
	author: string,
	date:   string,
}

DEFAULT_TEMPLATE :: `==============================================================================
DOD 0: Title
==============================================================================

:Authors: Name <email>
:State: prediscussion
:Created: YYYY-MM-DD
:Discussion:
:Labels:

Summary
=======

Background
==========

Proposal
========

Alternatives
============

Compatibility and fidelity
==========================

Verification
============

Decision
========

References
==========
`

// The text of a new record from ``template`` (the template record, or
// ``DEFAULT_TEMPLATE``): its title and metadata set, ``:orphan:`` and
// ``:Updated:`` removed.
fill_record :: proc(template: string, n: New_Record) -> string {
	sb := strings.builder_make()
	title := strings.concatenate({"DOD ", itoa(n.number), ": ", n.title})
	rule := strings.repeat("=", max(78, len(title)), context.temp_allocator)
	rest := template_body(template)
	titled, in_field := false, false
	for line in strings.split_lines_iterator(&rest) {
		t := strings.trim_space(line)
		// the continuation lines of a field whose value is replaced
		if in_field && is_continuation(line) do continue
		in_field = strings.has_prefix(line, ":")
		out := line
		switch {
		case !titled && is_adornment(line) && t[0] == '=':
			out = rule
		case !titled && strings.has_prefix(t, "DOD "):
			out, titled = title, true
		case strings.has_prefix(line, ":Updated:"):
			continue
		case in_field:
			out = field_line(line, n)
		}
		strings.write_string(&sb, out)
		strings.write_byte(&sb, '\n')
	}
	return strings.to_string(sb)
}

// An indented, non-blank line.
@(private = "file")
is_continuation :: proc(line: string) -> bool {
	return strings.trim_space(line) != "" && (line[0] == ' ' || line[0] == '\t')
}

// The template from its title on: without ``:orphan:`` and the comments
// about the template before the title.
@(private = "file")
template_body :: proc(template: string) -> string {
	rest := template
	offset := 0
	for line in strings.split_lines_iterator(&rest) {
		if is_adornment(line) || strings.has_prefix(strings.trim_space(line), "DOD ") {
			return template[offset:]
		}
		offset = len(template) - len(rest)
	}
	return template
}

@(private = "file")
field_line :: proc(line: string, n: New_Record) -> string {
	set :: proc(name, value: string) -> string {
		if value == "" do return strings.concatenate({":", name, ":"})
		return strings.concatenate({":", name, ": ", value})
	}
	switch {
	case strings.has_prefix(line, ":Authors:"):
		return set("Authors", n.author)
	case strings.has_prefix(line, ":State:"):
		return set("State", "prediscussion")
	case strings.has_prefix(line, ":Created:"):
		return set("Created", n.date)
	case strings.has_prefix(line, ":Discussion:"):
		return set("Discussion", "")
	case strings.has_prefix(line, ":Labels:") && n.labels != "":
		return set("Labels", n.labels)
	}
	return line
}
