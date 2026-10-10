package site

import "core:os"
import "core:path/filepath"
import "core:strings"

import "../check"

// The warnings of a build: the system messages of the documents (docutils'
// own and those of the Sphinx directives) and the problems found when
// resolving references across documents.  They are shown as docutils shows
// system messages, or as Elm-style reports with a source excerpt.

Warning :: struct {
	level:  int, // 2 WARNING, 3 ERROR, 4 SEVERE
	doc:    Doc_Id, // NO_DOC: the project
	source: string,
	line:   int, // 0: none
	text:   string, // the message; further paragraphs after a blank line
}

// A warning about document ``doc`` (at ``line``, 0 for none).
warn :: proc(s: ^Site, doc: Doc_Id, text: string, line: int, level := 2) {
	source := s.docs[doc].path if doc != NO_DOC else s.srcdir
	warn_at(s, doc, source, line, text, level)
}

warn_at :: proc(s: ^Site, doc: Doc_Id, source: string, line: int, text: string, level: int) {
	for w in s.warnings {
		if w.source == source && w.line == line && w.text == text do return
	}
	w := Warning{level, doc, strings.clone(source, s.allocator), line,
		strings.clone(text, s.allocator)}
	append(&s.warnings, w)
}

// The highest warning level (0 without warnings).
max_level :: proc(s: ^Site) -> int {
	level := 0
	for w in s.warnings do level = max(level, w.level)
	return level
}

// Write the warnings to ``b``: docutils' format, or Elm style.
format_warnings :: proc(
	b: ^strings.Builder,
	s: ^Site,
	format: check.Error_Format,
	color: bool,
) {
	for w in s.warnings {
		text, rest, _ := strings.partition(w.text, "\n\n")
		m := check.Message {
			line    = w.line,
			level   = w.level,
			text    = text,
			literal = rest,
		}
		source := display_path(w.source)
		switch format {
		case .Docutils:
			check.format_docutils(b, source, m)
		case .Elm:
			src: check.Source_Lines
			if w.doc != NO_DOC && w.source == s.docs[w.doc].path {
				src = check.source_lines(s.docs[w.doc].text, 8)
			}
			check.format_elm(b, source, src, m, color)
		}
	}
}

// A path relative to the working directory when it lies below it.
display_path :: proc(path: string) -> string {
	cwd, err := os.get_working_directory(context.temp_allocator)
	if err != nil do return path
	rel, rerr := filepath.rel(cwd, path, context.temp_allocator)
	if rerr != nil || strings.has_prefix(rel, "..") do return path
	return rel
}
