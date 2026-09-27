package check

// Rendering of diagnostics.
//
// docutils format (``system_message.astext()``, one line per message):
//
//     guide.rst:12: (WARNING/2) Inline emphasis start-string without end-string.
//
// Elm format (the default of the command-line tools): a titled report with a
// source excerpt, markers under the offending text and a hint on how to fix it:
//
//     -- UNCLOSED EMPHASIS ------------------------------------------ guide.rst:12:9
//
//     Inline emphasis start-string without end-string.
//
//     12| Some *emphasis without an end.
//              ^
//     Hint: Close the emphasis with a matching `*`, or write `\*` for a literal
//     asterisk.

import "core:strings"
import "core:unicode/utf8"

import rst "../rst"

Error_Format :: enum u8 {
	Elm,
	Docutils,
}

REPORT_WIDTH :: 80
MAX_EXCERPT_LINES :: 6

// ANSI styles; empty when colors are off.
@(private = "file")
Palette :: struct {
	header, marker, hint, dim, reset: string,
}

@(private = "file")
palette :: proc(color: bool, level: int) -> Palette {
	if !color do return {}
	header := "\x1b[36m" // info: cyan
	if level == rst.WARNING do header = "\x1b[33m"
	if level >= rst.ERROR do header = "\x1b[31m"
	return {header, "\x1b[31m", "\x1b[4m", "\x1b[2m", "\x1b[0m"}
}

// ``system_message.astext()``: "source:line: (LEVEL/n) text", followed by
// the message's child elements separated by blank lines.
format_docutils :: proc(b: ^strings.Builder, source: string, m: Message) {
	strings.write_string(b, source)
	strings.write_byte(b, ':')
	if m.line > 0 do strings.write_int(b, m.line)
	strings.write_string(b, ": (")
	strings.write_string(b, level_name(m.level))
	strings.write_byte(b, '/')
	strings.write_int(b, m.level)
	strings.write_string(b, ") ")
	strings.write_string(b, m.text)
	if m.literal != "" {
		strings.write_string(b, "\n\n")
		strings.write_string(b, m.literal)
	}
	for d in m.details {
		strings.write_string(b, "\n\n")
		strings.write_string(b, d)
	}
	strings.write_byte(b, '\n')
}

// Source lines of a document, tab-expanded like the parser's input.
Source_Lines :: struct {
	lines:     []string,
	tab_width: int,
}

source_lines :: proc(text: string, tab_width: int) -> Source_Lines {
	lines := strings.split_lines(text)
	if len(lines) > 0 && lines[len(lines) - 1] == "" do lines = lines[:len(lines) - 1]
	for &line in lines do line = expand_tabs(strings.trim_right_space(line), tab_width)
	return {lines, tab_width}
}

@(private = "file")
expand_tabs :: proc(line: string, tab_width: int) -> string {
	if strings.index_byte(line, '\t') < 0 do return line
	b := strings.builder_make()
	col := 0
	for r in line {
		if r == '\t' {
			n := tab_width - col % tab_width
			for _ in 0 ..< n do strings.write_byte(&b, ' ')
			col += n
		} else {
			strings.write_rune(&b, r)
			col += 1
		}
	}
	return strings.to_string(b)
}

// Lines [first, last] (1-based) of the excerpt, and the marked columns
// (display columns, [mark_start, mark_end)) on line ``mark_line``.
@(private = "file")
Excerpt :: struct {
	first, last:          int,
	mark_line:            int, // 0: no markers
	mark_start, mark_end: int,
}

format_elm :: proc(
	b: ^strings.Builder,
	source: string,
	src: Source_Lines,
	m: Message,
	color: bool,
) {
	d := lookup_diagnostic(m.text)
	pal := palette(color, m.level)
	ex := excerpt(src, m, d.mark)
	location := source
	if m.line > 0 {
		location = strings.concatenate({source, ":", int_string(m.line)})
		if ex.mark_line == m.line && m.span.text != "" {
			location = strings.concatenate({location, ":", int_string(ex.mark_start + 1)})
		}
	}
	write_header(b, d.title if d.title != "" else level_name(m.level), location, pal)
	write_wrapped(b, m.text, 0)
	for detail in m.details {
		strings.write_byte(b, '\n')
		write_wrapped(b, detail, 0)
	}
	if ex.first > 0 {
		strings.write_byte(b, '\n')
		write_excerpt(b, src, ex, pal)
	}
	if hint := hint_text(d, m); hint != "" {
		if ex.first <= 0 do strings.write_byte(b, '\n')
		strings.write_string(b, pal.hint)
		strings.write_string(b, "Hint")
		strings.write_string(b, pal.reset)
		strings.write_string(b, ": ")
		write_wrapped(b, hint, len("Hint: "))
	}
	strings.write_byte(b, '\n')
}

// An Elm-style report without a source excerpt: the usage errors of the
// command-line tools.  ``location`` names the tool or the file; ``hint``
// may be "".
format_report :: proc(b: ^strings.Builder, title, location, text, hint: string, color: bool) {
	format_line_report(b, title, location, text, {}, 0, hint, color)
}

// An Elm-style report showing line ``line`` of ``src`` (none for 0 or a
// line ``src`` lacks), for conditions of the tools rather than markup
// errors (a document that needs Python).
format_line_report :: proc(
	b: ^strings.Builder,
	title, location, text: string,
	src: Source_Lines,
	line: int,
	hint: string,
	color: bool,
) {
	pal := palette(color, rst.ERROR)
	write_header(b, title, location, pal)
	write_wrapped(b, text, 0)
	shown := line >= 1 && line <= len(src.lines)
	if shown {
		ex := Excerpt{first = line, last = line}
		mark_content(src, line, &ex)
		strings.write_byte(b, '\n')
		write_excerpt(b, src, ex, pal)
	}
	if hint != "" {
		if !shown do strings.write_byte(b, '\n')
		strings.write_string(b, pal.hint)
		strings.write_string(b, "Hint")
		strings.write_string(b, pal.reset)
		strings.write_string(b, ": ")
		write_wrapped(b, hint, len("Hint: "))
		strings.write_byte(b, '\n')
	}
}

@(private = "file")
write_header :: proc(b: ^strings.Builder, title, location: string, pal: Palette) {
	strings.write_string(b, pal.header)
	strings.write_string(b, "-- ")
	strings.write_string(b, title)
	strings.write_byte(b, ' ')
	used := 3 + utf8.rune_count(title) + 1 + 1 + utf8.rune_count(location)
	for _ in 0 ..< max(REPORT_WIDTH - used, 3) do strings.write_byte(b, '-')
	strings.write_byte(b, ' ')
	strings.write_string(b, location)
	strings.write_string(b, pal.reset)
	strings.write_string(b, "\n\n")
}

// Word-wrap ``text`` to the report width; the first line starts at column
// ``col``.  Lines of ``text`` that start with spaces (examples) are kept as
// they are.
@(private = "file")
write_wrapped :: proc(b: ^strings.Builder, text: string, col: int) {
	col := col
	for line, i in strings.split_lines(text) {
		if i > 0 {
			strings.write_byte(b, '\n')
			col = 0
		}
		if strings.has_prefix(line, " ") {
			strings.write_string(b, line)
			continue
		}
		first := true
		for word in strings.fields(line) {
			n := utf8.rune_count(word)
			if !first && col + 1 + n > REPORT_WIDTH {
				strings.write_byte(b, '\n')
				col = 0
			} else if !first {
				strings.write_byte(b, ' ')
				col += 1
			}
			strings.write_string(b, word)
			col += n
			first = false
		}
	}
	strings.write_byte(b, '\n')
}

@(private = "file")
write_excerpt :: proc(b: ^strings.Builder, src: Source_Lines, ex: Excerpt, pal: Palette) {
	gutter := len(int_string(ex.last))
	elide_from, elide_to := 0, -1
	if ex.last - ex.first + 1 > MAX_EXCERPT_LINES {
		// keep the first lines, the marked line and the last lines
		elide_from = ex.first + 3
		elide_to = ex.last - 2
		if ex.mark_line >= elide_from && ex.mark_line <= elide_to do elide_to = ex.mark_line - 1
	}
	for n in ex.first ..= ex.last {
		if n >= elide_from && n <= elide_to {
			if n == elide_from {
				strings.write_string(b, pal.dim)
				for _ in 0 ..< gutter do strings.write_byte(b, '.')
				strings.write_string(b, "|\n")
				strings.write_string(b, pal.reset)
			}
			continue
		}
		num := int_string(n)
		for _ in len(num) ..< gutter do strings.write_byte(b, ' ')
		strings.write_string(b, num)
		strings.write_byte(b, '|')
		if line := src.lines[n - 1]; line != "" {
			strings.write_byte(b, ' ')
			strings.write_string(b, line)
		}
		strings.write_byte(b, '\n')
		if n == ex.mark_line && ex.mark_end > ex.mark_start {
			for _ in 0 ..< gutter + 2 + ex.mark_start do strings.write_byte(b, ' ')
			strings.write_string(b, pal.marker)
			for _ in ex.mark_start ..< ex.mark_end do strings.write_byte(b, '^')
			strings.write_string(b, pal.reset)
			strings.write_byte(b, '\n')
		}
	}
}

// --- locating the excerpt --------------------------------------------------------------

@(private = "file")
excerpt :: proc(src: Source_Lines, m: Message, mark: Mark) -> (ex: Excerpt) {
	n := len(src.lines)
	if m.line <= 0 || m.line > n + 1 do return
	if m.span.text != "" && span_excerpt(src, m, &ex) do return
	if m.literal != "" && literal_excerpt(src, m, mark, &ex) do return
	line := min(m.line, n)
	ex = {first = line, last = line}
	if mark == .Context_Line {
		// unindent and indentation problems: show the preceding line
		prev := line - 1
		for prev > 0 && is_blank_line(src.lines[prev - 1]) do prev -= 1
		if prev > 0 && line - prev <= 2 do ex.first = prev
	}
	if mark != .None do mark_content(src, line, &ex)
	return
}

// Inline markup: mark the offending text in its source line.
@(private = "file")
span_excerpt :: proc(src: Source_Lines, m: Message, ex: ^Excerpt) -> bool {
	line := m.line + m.span.row
	if line < 1 || line > len(src.lines) do return false
	text := src.lines[line - 1]
	start := len(text) - m.span.from_line_end
	if start < 0 || !strings.has_prefix(text[start:], m.span.text) {
		// the inline source differs from the line (e.g. a "::" suffix)
		start = strings.index(text, m.span.text)
		if start < 0 do return false
	}
	col := utf8.rune_count(text[:start])
	ex^ = {m.line, line, line, col, col + max(utf8.rune_count(m.span.text), 1)}
	return true
}

// Messages carrying the offending source (titles, tables, markers): show it
// where it occurs near the message line.
@(private = "file")
literal_excerpt :: proc(src: Source_Lines, m: Message, mark: Mark, ex: ^Excerpt) -> bool {
	block := strings.split_lines(m.literal)
	first := strings.trim_space(block[0])
	if first == "" do return false
	lo := max(m.line - len(block) - 1, 1)
	hi := min(m.line + 1, len(src.lines))
	for start in lo ..= hi {
		if !block_matches(src, start, block) do continue
		ex^ = {first = start, last = start + len(block) - 1}
		switch mark {
		case .Last_Line:
			mark_content(src, ex.last, ex)
		case .Line, .Context_Line:
			mark_content(src, clamp(m.line, ex.first, ex.last), ex)
		case .None:
		}
		return true
	}
	return false
}

@(private = "file")
block_matches :: proc(src: Source_Lines, start: int, block: []string) -> bool {
	if start + len(block) - 1 > len(src.lines) do return false
	for line, i in block {
		if strings.trim_space(line) != strings.trim_space(src.lines[start + i - 1]) do return false
	}
	return true
}

// Mark the non-blank part of ``line``.
@(private = "file")
mark_content :: proc(src: Source_Lines, line: int, ex: ^Excerpt) {
	if line < 1 || line > len(src.lines) do return
	text := src.lines[line - 1]
	trimmed := strings.trim_left_space(text)
	if trimmed == "" do return
	ex.mark_line = line
	ex.mark_start = utf8.rune_count(text[:len(text) - len(trimmed)])
	ex.mark_end = utf8.rune_count(text)
}

@(private = "file")
is_blank_line :: proc(line: string) -> bool {
	return len(strings.trim_space(line)) == 0
}

@(private = "file")
int_string :: proc(n: int) -> string {
	buf: [32]byte
	return strings.clone(rst.itoa(buf[:], n))
}
