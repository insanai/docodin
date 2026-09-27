package dod

import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"

// DocOdin Discussions (DOD): numbered design records, one reStructuredText
// file each ("NNNN-slug.rst", four digits), titled "DOD n: Title" with a
// field list of metadata right after the title:
//
//     ==============================================================================
//     DOD 7: Title Words
//     ==============================================================================
//
//     :Authors: Name <email>
//     :State: discussion
//     :Created: 2026-09-27
//     :Discussion: https://...
//     :Labels: parser, native
//
// This package reads the records, checks them, creates new ones from the
// template and writes the "By state" index.

STATES := [?]string {
	"prediscussion", "ideation", "discussion", "published", "committed", "abandoned",
}

LABELS := [?]string {
	"parser", "shim", "native", "performance", "tooling", "editor", "documentation", "process",
	"release", "compatibility",
}

FIELDS := [?]string {
	"Authors", "State", "Created", "Updated", "Discussion", "Labels", "Supersedes",
	"Superseded-By",
}

REQUIRED := [?]string{"Authors", "State", "Created", "Discussion", "Labels"}

TEMPLATE_NAME :: "0000-template.rst"
INDEX_START :: ".. dod-index-start"
INDEX_END :: ".. dod-index-end"

Field :: struct {
	name:  string,
	value: string,
	line:  int, // 1-based
}

Record :: struct {
	path:       string,
	file:       string, // the base name
	number:     int, // from the file name (-1: not "NNNN-slug.rst")
	slug:       string,
	text:       string,
	title:      string, // "DOD 7: Title Words"
	title_line: int, // 0: no title
	fields:     [dynamic]Field,
}

// A problem found by ``check``.
Problem :: struct {
	path:  string,
	line:  int, // 0: the file
	level: int, // 2 warning, 3 error
	title: string, // Elm report title
	text:  string,
	hint:  string,
}

// The records of ``dir`` (the template excluded), by number.
read_records :: proc(dir: string, allocator := context.allocator) -> ([]Record, bool) {
	context.allocator = allocator
	entries, err := os.read_all_directory_by_path(dir, allocator)
	if err != nil do return nil, false
	out := make([dynamic]Record)
	for fi in entries {
		if !strings.has_suffix(fi.name, ".rst") || fi.name == "index.rst" do continue
		if fi.name == TEMPLATE_NAME || fi.type == .Directory do continue
		data, rerr := os.read_entire_file_from_path(fi.fullpath, allocator)
		if rerr != nil do continue
		append(&out, parse_record(fi.fullpath, string(data)))
	}
	slice.sort_by(out[:], proc(a, b: Record) -> bool {
		return a.number < b.number || (a.number == b.number && a.file < b.file)
	})
	return out[:], true
}

// A record from its file (lines with "\n" or "\r\n").
parse_record :: proc(path, text: string) -> Record {
	r := Record {
		path   = path,
		file   = filepath.base(path),
		text   = text,
		fields = make([dynamic]Field),
	}
	r.number, r.slug = parse_file_name(r.file)
	lines := strings.split_lines(text)
	i := parse_title(&r, lines)
	parse_fields(&r, lines, i)
	return r
}

// "0007-some-slug.rst": 7 and "some-slug" (-1 when the name differs).
parse_file_name :: proc(name: string) -> (number: int, slug: string) {
	stem := strings.trim_suffix(name, ".rst")
	if len(stem) < 6 || stem[4] != '-' do return -1, stem
	for c in transmute([]u8)stem[:4] do if c < '0' || c > '9' do return -1, stem
	n, _ := strconv.parse_int(stem[:4])
	return n, stem[5:]
}

// The title (overlined or not); the index of the line after it.
@(private = "file")
parse_title :: proc(r: ^Record, lines: []string) -> int {
	i := 0
	for i < len(lines) {
		t := strings.trim_space(lines[i])
		if t == "" || t == ":orphan:" || strings.has_prefix(t, "..") {
			i += 1
			continue
		}
		break
	}
	if i >= len(lines) do return i
	if is_adornment(lines[i]) && i + 1 < len(lines) {
		r.title, r.title_line = strings.trim_space(lines[i + 1]), i + 2
		return i + 3
	}
	r.title, r.title_line = strings.trim_space(lines[i]), i + 1
	return i + 2
}

is_adornment :: proc(line: string) -> bool {
	t := strings.trim_right_space(line)
	if len(t) < 3 do return false
	for c in transmute([]u8)t do if c != t[0] do return false
	return strings.index_byte("=-~^\"'`#*+:.", t[0]) >= 0
}

// The field list after the title (continuation lines are indented).
@(private = "file")
parse_fields :: proc(r: ^Record, lines: []string, start: int) {
	i := start
	for i < len(lines) && strings.trim_space(lines[i]) == "" do i += 1
	for ; i < len(lines); i += 1 {
		line := lines[i]
		if strings.trim_space(line) == "" do break
		if line[0] == ' ' || line[0] == '\t' {
			if n := len(r.fields); n > 0 {
				f := &r.fields[n - 1]
				f.value = strings.trim_space(strings.concatenate({f.value, " ",
					strings.trim_space(line)}))
			}
			continue
		}
		if !strings.has_prefix(line, ":") do break
		end := strings.index_byte(line[1:], ':')
		if end < 0 do break
		name := line[1:end + 1]
		value := strings.trim_space(line[end + 2:])
		append(&r.fields, Field{name, value, i + 1})
	}
}

field :: proc(r: ^Record, name: string) -> (Field, bool) {
	for f in r.fields do if f.name == name do return f, true
	return {}, false
}

field_value :: proc(r: ^Record, name: string) -> string {
	f, _ := field(r, name)
	return f.value
}

// The labels of a record.
record_labels :: proc(r: ^Record, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	rest := field_value(r, "Labels")
	for part in strings.split_iterator(&rest, ",") {
		if l := strings.trim_space(part); l != "" do append(&out, l)
	}
	return out[:]
}

// "DOD 7: Title" -> 7, "Title".
split_title :: proc(title: string) -> (number: int, text: string, ok: bool) {
	if !strings.has_prefix(title, "DOD ") do return 0, "", false
	colon := strings.index(title, ": ")
	if colon < 0 do return 0, "", false
	n, is_num := strconv.parse_int(title[4:colon])
	if !is_num do return 0, "", false
	return n, strings.trim_space(title[colon + 2:]), true
}

// A date "YYYY-MM-DD" that exists.
valid_date :: proc(s: string) -> bool {
	if len(s) != 10 || s[4] != '-' || s[7] != '-' do return false
	y, ok1 := strconv.parse_int(s[:4])
	m, ok2 := strconv.parse_int(s[5:7])
	d, ok3 := strconv.parse_int(s[8:])
	if !(ok1 && ok2 && ok3) || m < 1 || m > 12 do return false
	return 1 <= d && d <= days_in_month(y, m)
}

@(private = "file")
days_in_month :: proc(y, m: int) -> int {
	days := [?]int{31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}
	leap := y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)
	return 29 if m == 2 && leap else days[m - 1]
}

// A file name slug from a title: lowercase words joined by "-".
make_slug :: proc(title: string, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	dash := false
	for r in strings.to_lower(title, context.temp_allocator) {
		ok := (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9')
		if !ok {
			dash = strings.builder_len(sb) > 0
			continue
		}
		if dash do strings.write_byte(&sb, '-')
		dash = false
		strings.write_rune(&sb, r)
	}
	return strings.to_string(sb)
}

// "0007".
pad4 :: proc(n: int, allocator := context.temp_allocator) -> string {
	buf: [16]u8
	s := strconv.write_int(buf[:], i64(n), 10)
	sb := strings.builder_make(allocator)
	for _ in len(s) ..< 4 do strings.write_byte(&sb, '0')
	strings.write_string(&sb, s)
	return strings.to_string(sb)
}

itoa :: proc(n: int, allocator := context.temp_allocator) -> string {
	buf: [24]u8
	return strings.clone(strconv.write_int(buf[:], i64(n), 10), allocator)
}
