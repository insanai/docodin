package dod

import "core:os"
import "core:slice"
import "core:strings"

// ``docodin dod check``: the records' file names, titles and metadata, the
// uniqueness of their numbers, and whether the index is up to date.

check_records :: proc(
	dir: string,
	records: []Record,
	allocator := context.allocator,
) -> []Problem {
	context.allocator = allocator
	out := make([dynamic]Problem)
	seen := make(map[int]string, 16, context.temp_allocator)
	for &r in records {
		check_name(&out, &r)
		check_title(&out, &r)
		check_fields(&out, &r)
		check_values(&out, &r, records)
		if r.number < 0 do continue
		if other, dup := seen[r.number]; dup {
			append(&out, Problem{r.path, 0, 3, "DUPLICATE NUMBER",
				strings.concatenate({"DOD ", itoa(r.number), " is also ", other, "."}),
				"Give one of them the next free number: `docodin dod new` picks it."})
		}
		seen[r.number] = r.file
	}
	check_index(&out, dir, records)
	return out[:]
}

@(private = "file")
check_name :: proc(out: ^[dynamic]Problem, r: ^Record) {
	if r.number < 0 {
		append(out, Problem{r.path, 0, 3, "BAD FILE NAME",
			strings.concatenate({"`", r.file, "` is not named NNNN-slug.rst."}),
			"Name records with four digits and a slug: `0007-native-sphinx-builder.rst`."})
		return
	}
	if r.slug == "" || r.slug != make_slug(r.slug, context.temp_allocator) {
		append(out, Problem{r.path, 0, 2, "BAD SLUG",
			strings.concatenate({"The slug `", r.slug, "` is not lowercase words joined by `-`."}),
			strings.concatenate({"Rename the file `", pad4(r.number), "-",
				make_slug(r.slug, context.temp_allocator), ".rst`."})})
	}
}

@(private = "file")
check_title :: proc(out: ^[dynamic]Problem, r: ^Record) {
	if r.title_line == 0 {
		append(out, Problem{r.path, 0, 3, "MISSING TITLE", "The record has no title.",
			"Start it with the title `DOD n: Title` between two lines of `=`."})
		return
	}
	n, text, ok := split_title(r.title)
	expected := strings.concatenate({"DOD ", itoa(r.number), ": "})
	switch {
	case !ok:
		append(out, Problem{r.path, r.title_line, 3, "BAD TITLE",
			strings.concatenate({"The title `", r.title, "` is not `DOD n: Title`."}),
			strings.concatenate({"Write `", expected, r.title, "`."})})
	case r.number >= 0 && n != r.number:
		append(out, Problem{r.path, r.title_line, 3, "NUMBER MISMATCH",
			strings.concatenate({"The title says DOD ", itoa(n), " but the file is ", r.file,
				"."}),
			strings.concatenate({"Write `", expected, text, "`."})})
	case text == "" || strings.has_suffix(text, ".") || strings.contains(text, "  "):
		append(out, Problem{r.path, r.title_line, 2, "TITLE FORMAT",
			strings.concatenate({"The title `", r.title, "` is not `DOD n: Title` with a title ",
				"of single-spaced words and no final period."}),
			"Write the title like a heading: `DOD 7: Native Sphinx Builder`."})
	}
}

@(private = "file")
check_fields :: proc(out: ^[dynamic]Problem, r: ^Record) {
	for f in r.fields {
		if slice.contains(FIELDS[:], f.name) do continue
		hint := strings.concatenate({"The fields are ", strings.join(FIELDS[:], ", ",
			context.temp_allocator), "."})
		if near := nearest(f.name, FIELDS[:]); near != "" {
			hint = strings.concatenate({"Did you mean `:", near, ":`?  ", hint})
		}
		append(out, Problem{r.path, f.line, 3, "UNKNOWN FIELD",
			strings.concatenate({"`:", f.name, ":` is not a DOD field."}), hint})
	}
	for name in REQUIRED {
		if _, ok := field(r, name); ok do continue
		line := r.title_line + 2 if r.title_line > 0 else 0
		append(out, Problem{r.path, line, 3, "MISSING FIELD",
			strings.concatenate({"The record has no `:", name, ":` field."}),
			strings.concatenate({"Add `:", name, ":` to the field list after the title",
				" (`:Discussion:` may be empty)."})})
	}
}

@(private = "file")
check_values :: proc(out: ^[dynamic]Problem, r: ^Record, records: []Record) {
	for f in r.fields do check_value(out, r, f, records)
	created, updated := field_value(r, "Created"), field_value(r, "Updated")
	if valid_date(created) && valid_date(updated) && updated < created {
		f, _ := field(r, "Updated")
		append(out, Problem{r.path, f.line, 2, "UPDATED BEFORE CREATED",
			strings.concatenate({"The record was updated (", updated, ") before it was created (",
				created, ")."}), "Check both dates."})
	}
}

@(private = "file")
check_value :: proc(out: ^[dynamic]Problem, r: ^Record, f: Field, records: []Record) {
	switch f.name {
	case "State":
		if slice.contains(STATES[:], f.value) do return
		append(out, Problem{r.path, f.line, 3, "UNKNOWN STATE",
			strings.concatenate({"`", f.value, "` is not a DOD state."}),
			one_of(f.value, STATES[:])})
	case "Created", "Updated":
		if valid_date(f.value) do return
		append(out, Problem{r.path, f.line, 3, "BAD DATE",
			strings.concatenate({"`", f.value, "` is not a date YYYY-MM-DD."}),
			"Write the date as 2026-09-27."})
	case "Labels":
		check_labels(out, r, f)
	case "Authors":
		if f.value != "" do return
		append(out, Problem{r.path, f.line, 3, "NO AUTHOR", "The record has no author.",
			"Write `:Authors: Name`."})
	case "Supersedes", "Superseded-By":
		check_reference(out, r, f, records)
	}
}

@(private = "file")
check_labels :: proc(out: ^[dynamic]Problem, r: ^Record, f: Field) {
	labels := record_labels(r)
	if len(labels) == 0 {
		append(out, Problem{r.path, f.line, 2, "NO LABELS", "The record has no labels.",
			one_of("", LABELS[:])})
	}
	for l in labels {
		if slice.contains(LABELS[:], l) do continue
		append(out, Problem{r.path, f.line, 3, "UNKNOWN LABEL",
			strings.concatenate({"`", l, "` is not a DOD label."}), one_of(l, LABELS[:])})
	}
}

@(private = "file")
check_reference :: proc(out: ^[dynamic]Problem, r: ^Record, f: Field, records: []Record) {
	n, _, ok := split_title(strings.concatenate({f.value, ": x"}, context.temp_allocator))
	if !ok {
		append(out, Problem{r.path, f.line, 3, "BAD REFERENCE",
			strings.concatenate({"`", f.value, "` is not `DOD n`."}), "Write `DOD 3`."})
		return
	}
	for other in records do if other.number == n do return
	append(out, Problem{r.path, f.line, 3, "UNKNOWN RECORD",
		strings.concatenate({"There is no DOD ", itoa(n), "."}), "Name an existing record."})
}

@(private = "file")
check_index :: proc(out: ^[dynamic]Problem, dir: string, records: []Record) {
	path := strings.concatenate({dir, "/index.rst"})
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil do return
	text := string(data)
	updated, found := update_index(text, records)
	if !found {
		append(out, Problem{path, 0, 2, "NO INDEX MARKERS",
			strings.concatenate({"index.rst has no `", INDEX_START, "` and `", INDEX_END,
				"` comments."}),
			"Put the two comments where `docodin dod index` writes the records by state."})
	} else if updated != text {
		append(out, Problem{path, 0, 2, "INDEX OUT OF DATE",
			"The records by state in index.rst are out of date.", "Run `docodin dod index`."})
	}
}

// "Use one of ...", with the nearest choice first.
@(private = "file")
one_of :: proc(value: string, choices: []string) -> string {
	list := strings.join(choices, ", ", context.temp_allocator)
	if near := nearest(value, choices); near != "" {
		return strings.concatenate({"Did you mean `", near, "`?  Use one of ", list, "."})
	}
	return strings.concatenate({"Use one of ", list, "."})
}

// The choice closest to ``value`` (case-insensitive, at most 2 edits or
// a prefix), "" for none.
nearest :: proc(value: string, choices: []string) -> string {
	if value == "" do return ""
	v := strings.to_lower(value, context.temp_allocator)
	best, best_d := "", 3
	for c in choices {
		lc := strings.to_lower(c, context.temp_allocator)
		d := distance(v, lc)
		if strings.has_prefix(lc, v) do d = min(d, 1)
		if d < best_d do best, best_d = c, d
	}
	return best
}

@(private = "file")
distance :: proc(a, b: string) -> int {
	prev := make([]int, len(b) + 1, context.temp_allocator)
	cur := make([]int, len(b) + 1, context.temp_allocator)
	for j in 0 ..= len(b) do prev[j] = j
	for i in 1 ..= len(a) {
		cur[0] = i
		for j in 1 ..= len(b) {
			cost := 0 if a[i - 1] == b[j - 1] else 1
			cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
		}
		prev, cur = cur, prev
	}
	return prev[len(b)]
}
