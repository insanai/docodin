package dod_tests

import "core:strings"
import "core:testing"

import dod ".."

// Unit tests of the DocOdin Discussions: records, checks, the index and
// new records.  tests/test_book.py runs `docodin dod` end to end.

@(private = "file")
RECORD :: `==============================================================================
DOD 7: Native Sphinx Builder
==============================================================================

:Authors: Ada <ada@example.org>
:State: discussion
:Created: 2026-09-01
:Updated: 2026-09-20
:Discussion: https://example.org/pr/1
:Labels: tooling,
   native

Summary
=======
`

@(test)
parse_a_record :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	r := dod.parse_record("docs/dod/0007-native-sphinx-builder.rst", RECORD)
	testing.expect_value(t, r.number, 7)
	testing.expect_value(t, r.slug, "native-sphinx-builder")
	testing.expect_value(t, r.title, "DOD 7: Native Sphinx Builder")
	testing.expect_value(t, r.title_line, 2)
	testing.expect_value(t, dod.field_value(&r, "State"), "discussion")
	labels := dod.record_labels(&r)
	testing.expect_value(t, len(labels), 2)
	testing.expect_value(t, labels[1], "native")
	f, _ := dod.field(&r, "Created")
	testing.expect_value(t, f.line, 7)
}

@(test)
dates_and_names :: proc(t: ^testing.T) {
	testing.expect(t, dod.valid_date("2024-02-29"))
	testing.expect(t, !dod.valid_date("2023-02-29"))
	testing.expect(t, !dod.valid_date("2026-13-01"))
	testing.expect(t, !dod.valid_date("26-01-01"))
	n, slug := dod.parse_file_name("0012-parser-research.rst")
	testing.expect_value(t, n, 12)
	testing.expect_value(t, slug, "parser-research")
	n, _ = dod.parse_file_name("notes.rst")
	testing.expect_value(t, n, -1)
	testing.expect_value(t, dod.make_slug("A Native Sphinx builder!", context.temp_allocator),
		"a-native-sphinx-builder")
	testing.expect_value(t, dod.pad4(7), "0007")
	testing.expect_value(t, dod.nearest("Autor", dod.FIELDS[:]), "Authors")
}

@(private = "file")
problem_titles :: proc(problems: []dod.Problem) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for p in problems {
		strings.write_string(&sb, p.title)
		strings.write_byte(&sb, ';')
	}
	return strings.to_string(sb)
}

@(test)
check_finds_problems :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	bad := `DOD 8: Wrong number
====================

:Author: Ada
:State: finished
:Created: 2026-02-30
:Labels: parser, magic
`
	records := []dod.Record {
		dod.parse_record("d/0007-native-sphinx-builder.rst", RECORD),
		dod.parse_record("d/0009-Bad_Name.rst", bad),
		dod.parse_record("d/0007-again.rst", RECORD),
	}
	titles := problem_titles(dod.check_records("/nonexistent", records))
	for want in ([]string{"BAD SLUG", "NUMBER MISMATCH", "UNKNOWN FIELD", "MISSING FIELD",
		"UNKNOWN STATE", "BAD DATE", "UNKNOWN LABEL", "DUPLICATE NUMBER"}) {
		testing.expectf(t, strings.contains(titles, want), "%s not in %s", want, titles)
	}
	good := dod.check_records("/nonexistent", records[:1])
	testing.expect_value(t, len(good), 0)
}

@(test)
index_by_state :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	records := []dod.Record{dod.parse_record("d/0007-native-sphinx-builder.rst", RECORD)}
	text := "Title\n=====\n\n.. dod-index-start\n\nold\n\n.. dod-index-end\n\nAfter.\n"
	out, found := dod.update_index(text, records)
	testing.expect(t, found)
	want := "Title\n=====\n\n.. dod-index-start\n\nDiscussion\n----------\n\n" +
		"- :doc:`DOD 7: Native Sphinx Builder <0007-native-sphinx-builder>`\n\n" +
		".. dod-index-end\n\nAfter.\n"
	testing.expect_value(t, out, want)
	again, _ := dod.update_index(out, records)
	testing.expect_value(t, again, out)
	_, found = dod.update_index("no markers", records)
	testing.expect(t, !found)
}

@(test)
new_record_from_template :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	template := ":orphan:\n\n.. The template, a comment\n   on two lines.\n\n" + dod.DEFAULT_TEMPLATE
	text := dod.fill_record(template, {12, "Native Sphinx builder", "tooling, native",
		"Ada <ada@example.org>", "2026-09-27"})
	r := dod.parse_record("d/0012-native-sphinx-builder.rst", text)
	testing.expect_value(t, r.title, "DOD 12: Native Sphinx builder")
	testing.expect_value(t, dod.field_value(&r, "Authors"), "Ada <ada@example.org>")
	testing.expect_value(t, dod.field_value(&r, "Created"), "2026-09-27")
	testing.expect_value(t, dod.field_value(&r, "Labels"), "tooling, native")
	testing.expect(t, !strings.contains(text, "orphan"))
	testing.expect(t, !strings.contains(text, "The template"))
	testing.expect(t, strings.has_prefix(text, "====="))
	problems := dod.check_records("/nonexistent", {r})
	testing.expect_value(t, len(problems), 0)
}

@(test)
next_number_skips_taken :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	records := []dod.Record{dod.parse_record("d/0007-native-sphinx-builder.rst", RECORD)}
	testing.expect(t, dod.next_number("/nonexistent", records) >= 8)
}
