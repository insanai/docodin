package lsp

// Diagnostics: the system messages docutils reports for the document,
// with their texts, levels and lines, from the native pipeline (reader,
// directives, roles and the standard transforms: odin/reader and
// odin/transforms, as ``publish`` runs them).  The checker (odin/check)
// adds what docutils' messages lack: the column of inline markup errors,
// and the Elm title and hint of each message.  Mechanical hints come with
// a quick fix (see code_actions.odin).

import "base:runtime"
import "core:strings"

import check "../check"
import dt "../doctree"
import pb "../publish"
import rd "../reader"
import rst "../rst"
import tf "../transforms"

Diagnostic :: struct {
	span:    Span,
	level:   int,    // docutils level (0 DEBUG ... 4 SEVERE)
	line:    int,    // docutils' line (1-based; 0: none)
	code:    string, // the Elm title ("" if none)
	message: string, // docutils' message (with its details) and the hint
	fix:     Fix,
}

Fix_Kind :: enum u8 {
	None,
	Extend_Adornment,    // lengthen a title's underline (and overline)
	Insert_Blank_Line,   // before the message line
	Escape_Start_String, // escape an unmatched inline start-string
	Single_Colon,        // "::" without a literal block becomes ":"
}

// A replacement of ``span`` (parser coordinates) by ``text``.
Edit :: struct {
	span: Span,
	text: string,
}

Fix :: struct {
	kind:  Fix_Kind,
	title: string,
	edits: [2]Edit,
	count: int,
}

// A system message as docutils writes it.
Docutils_Message :: struct {
	level:  int,
	line:   int,    // 1-based; 0: none
	source: string,
	body:   string, // the text after "source:line: (LEVEL/n) "
	first:  string, // the message paragraph
	detail: string, // the second paragraph (the source excerpt of some messages)
}

// The messages docutils reports for ``text`` (``publish_string`` with
// ``report_level=1`` and ``halt_level=5``), and the exception it raises,
// if any.  Allocated with ``allocator``.
docutils_messages :: proc(
	text, source_path: string,
	allocator: runtime.Allocator,
) -> (
	msgs: []Docutils_Message,
	exception: string,
) {
	context.allocator = allocator
	context.temp_allocator = allocator
	settings := pb.default_settings(.Pseudoxml)
	overrides := [?]pb.Override{{"report_level", 1}, {"halt_level", 5}}
	if err, _ := pb.apply_overrides(&settings, .Pseudoxml, overrides[:]); err != "" do return
	dts := pb.to_doctree(settings)
	doc, info := rd.parse_document(text, dts, source_path, allocator)
	defer dt.destroy(doc)
	doc.settings = dts
	exception = strings.clone(info.exception)
	if exception == "" do run_transforms(doc, settings, source_path)
	out := make([dynamic]Docutils_Message, 0, len(doc.reporter.written))
	for w in doc.reporter.written {
		m := read_message(doc, w)
		if !library_missing(doc, m) do append(&out, m)
	}
	return out[:], exception
}

// The native pipeline reports what docutils reports without Pygments;
// docutils installations for editing (Sphinx) have it.
@(private = "file")
library_missing :: proc(doc: ^dt.Doc, m: Docutils_Message) -> bool {
	if m.first != "Cannot analyze code. Pygments package not found." do return false
	for need in doc.python_needs do if need.feature == .Pygments do return true
	return false
}

// ``Transformer.populate_from_components`` and ``apply_transforms`` for
// the standalone reader and the pseudo-XML writer.
@(private = "file")
run_transforms :: proc(doc: ^dt.Doc, settings: pb.Settings, source_path: string) {
	doc.current_source = nil
	doc.current_line = nil
	doc.interchange.settings = pb.to_json(settings)
	contents := tf.TRANSFORMS[.Contents].name
	cached := false
	for q in doc.pending_queue do if q.node != 0 && q.transform == contents do cached = true
	options := tf.Options {
		reader          = .Standalone,
		writer          = .Pseudoxml,
		language_cached = cached,
		docutils_dir    = pb.DEFAULT_DOCUTILS_DIR,
		source_path     = source_path,
		parse_rst       = rd.parse,
	}
	tf.populate_from_components(doc, .Standalone, .Pseudoxml)
	_, _ = tf.apply_all(doc, options)
}

@(private = "file")
read_message :: proc(doc: ^dt.Doc, w: dt.Written_Message) -> Docutils_Message {
	m := Docutils_Message {
		level = int(w.level),
	}
	if w.node != 0 {
		m.line = dt.get_int(doc, w.node, dt.K_LINE)
		m.source = strings.clone(dt.get_string(doc, w.node, dt.K_SOURCE))
	}
	text := strings.trim_right(w.text, "\n")
	marker := strings.concatenate({"(", dt.LEVEL_NAMES[w.level], "/", level_digit(m.level), ") "})
	if at := strings.index(text, marker); at >= 0 do text = text[at + len(marker):]
	m.body = strings.clone(text)
	first, _, rest := strings.partition(m.body, "\n\n")
	m.first = first
	m.detail, _, _ = strings.partition(rest, "\n\n")
	return m
}

@(private = "file")
level_digit :: proc(level: int) -> string {
	digits := [5]string{"0", "1", "2", "3", "4"}
	return digits[clamp(level, 0, 4)]
}

// The diagnostics of snapshot ``s`` with the settings ``cfg``.
build_diagnostics :: proc(s: ^Snapshot, cfg: ^Config) -> [dynamic]Diagnostic {
	context.allocator = s.allocator
	context.temp_allocator = s.allocator
	out := make([dynamic]Diagnostic, 0, 8)
	msgs, exception := docutils_messages(s.text, s.path, s.allocator)
	reported := make([dynamic]Docutils_Message, 0, len(msgs))
	for m in msgs {
		if m.level >= cfg.report_level && !known_elsewhere(cfg, m.first) do append(&reported, m)
	}
	// the checker parses again: only for documents with messages
	checks: []check.Message
	if len(reported) > 0 do checks = check.check_text(s.text, check.DEFAULT_OPTIONS)
	used := make([]bool, len(checks))
	for m in reported {
		ck := match_check(checks, used, m)
		cm := check.Message {
			line    = m.line,
			level   = m.level,
			text    = m.first,
			literal = m.detail,
		}
		if ck >= 0 do cm = checks[ck]
		d := Diagnostic {
			level   = m.level,
			line    = m.line,
			message = m.body,
		}
		info := check.lookup_diagnostic(m.first)
		d.code = info.title
		if hint := check.hint_text(info, cm); hint != "" {
			d.message = strings.concatenate({m.body, "\n\nHint: ", hint})
		}
		d.span = message_span(s, m, cm)
		d.fix = fix_for(s, d, m, cm)
		append(&out, d)
	}
	if exception != "" {
		text := strings.concatenate({"docutils stops with an exception: ", exception})
		d := Diagnostic {
			span    = line_content_span(&s.ix, 0),
			level   = rst.SEVERE,
			message = text,
		}
		append(&out, d)
	}
	return out
}

// The checker's message for a docutils message (same line, level and
// text), or -1.
@(private = "file")
match_check :: proc(checks: []check.Message, used: []bool, m: Docutils_Message) -> int {
	for c, i in checks {
		if used[i] || c.line != m.line || c.level != m.level || c.text != m.first do continue
		used[i] = true
		return i
	}
	return -1
}

// Where a message points: the offending inline text, the construct it
// names, or its line.
@(private = "file")
message_span :: proc(s: ^Snapshot, m: Docutils_Message, cm: check.Message) -> Span {
	ix := &s.ix
	if m.source != "" && m.source != s.path {
		// a message of an included file: the include directive
		for item in s.analysis.items {
			if item.kind == .Directive && item.name == "include" do return item.span
		}
		return line_content_span(ix, 0)
	}
	if cm.span.text != "" {
		if span, ok := inline_span(ix, cm); ok do return span
	}
	if span, ok := named_span(s, m); ok do return span
	line := clamp(m.line - 1, 0, max(line_count(ix) - 1, 0))
	return line_content_span(ix, line)
}

// The offending inline text of a checker message (as ``format_elm``
// finds it).
@(private = "file")
inline_span :: proc(ix: ^Line_Index, cm: check.Message) -> (Span, bool) {
	line := cm.line + cm.span.row - 1
	text := expanded(ix, line)
	start := len(text) - cm.span.from_line_end
	if start < 0 || !strings.has_prefix(text[start:], cm.span.text) {
		start = strings.index(text, cm.span.text)
		if start < 0 do return {}, false
	}
	l := i32(line)
	return {{l, i32(start)}, {l, i32(start + len(cm.span.text))}}, true
}

// Messages about a name ("Unknown target name: "x".", "Duplicate explicit
// target name: "x".", ...): the markup with that name at or after the
// message line.
@(private = "file")
named_span :: proc(s: ^Snapshot, m: Docutils_Message) -> (Span, bool) {
	open := strings.index_byte(m.first, '"')
	if open < 0 do return {}, false
	close := strings.index_byte(m.first[open + 1:], '"')
	if close < 0 do return {}, false
	quoted := m.first[open + 1:][:close]
	name := dt.fully_normalize_name(quoted)
	kinds := named_kinds(m.first)
	from := i32(m.line - 1)
	for item in s.analysis.items {
		if item.kind not_in kinds || item.span.start.line < from do continue
		if item.name == name || item.label == quoted do return item.span, true
	}
	return {}, false
}

@(private = "file")
named_kinds :: proc(text: string) -> Item_Kinds {
	switch {
	case strings.has_prefix(text, "Unknown directive type"):
		return {.Directive}
	case strings.has_prefix(text, "Unknown interpreted text role"):
		return {.Role}
	case strings.has_prefix(text, "Undefined substitution"):
		return {.Substitution_Reference}
	case strings.has_prefix(text, "Unknown target name"):
		return {.Reference, .Footnote_Reference, .Citation_Reference}
	case strings.contains(text, "implicit target"):
		return {.Section}
	}
	return DEFINITION_KINDS - {.Section}
}

// --- quick fixes -----------------------------------------------------------------------

@(private = "file")
fix_for :: proc(s: ^Snapshot, d: Diagnostic, m: Docutils_Message, cm: check.Message) -> Fix {
	switch d.code {
	case "TITLE UNDERLINE TOO SHORT", "TITLE OVERLINE TOO SHORT":
		return extend_adornment(&s.ix, m.line - 1)
	case "POSSIBLE TITLE":
		if strings.has_prefix(m.first, "Possible title underline") {
			return extend_adornment(&s.ix, m.line - 1)
		}
	case "MISSING BLANK LINE", "UNEXPECTED INDENTATION":
		return insert_blank_line(&s.ix, m.line - 1)
	case "UNCLOSED EMPHASIS", "UNCLOSED STRONG EMPHASIS", "UNCLOSED INLINE LITERAL",
	     "UNCLOSED INTERPRETED TEXT", "UNCLOSED SUBSTITUTION REFERENCE", "UNCLOSED INLINE TARGET":
		if cm.span.text != "" do return escape_start_string(&s.ix, d.span)
	case "MISSING LITERAL BLOCK":
		return single_colon(&s.ix, m.line - 1)
	}
	return {}
}

// The title near ``line`` (a title line followed by its underline).
@(private = "file")
find_title :: proc(ix: ^Line_Index, line: int) -> (title: int, ok: bool) {
	for t in ([?]int{line - 1, line, line - 2, line + 1}) {
		if t < 0 || t + 1 >= line_count(ix) do continue
		text := expanded(ix, t)
		if is_blank(text) || is_adornment(text) do continue
		if is_adornment(expanded(ix, t + 1)) do return t, true
	}
	return 0, false
}

@(private = "file")
extend_adornment :: proc(ix: ^Line_Index, line: int) -> Fix {
	t, ok := find_title(ix, line)
	if !ok do return {}
	under := expanded(ix, t + 1)
	over := expanded(ix, t - 1)
	has_over := t > 0 && is_adornment(over) && over[0] == under[0]
	width := max(rst.column_width(expanded(ix, t)), len(under))
	if has_over do width = max(width, len(over))
	adornment := strings.repeat(under[:1], width)
	fix := Fix {
		kind  = .Extend_Adornment,
		title = "Extend the title adornment to the title's width",
		count = 1,
	}
	fix.edits[0] = {whole_line(ix, t + 1), adornment}
	if has_over {
		fix.edits[1] = {whole_line(ix, t - 1), adornment}
		fix.count = 2
	}
	return fix
}

@(private = "file")
whole_line :: proc(ix: ^Line_Index, line: int) -> Span {
	l := i32(line)
	return {{l, 0}, {l, i32(len(expanded(ix, line)))}}
}

@(private = "file")
insert_blank_line :: proc(ix: ^Line_Index, line: int) -> Fix {
	if line <= 0 || line >= line_count(ix) do return {}
	at := Pos{i32(line), 0}
	fix := Fix {
		kind  = .Insert_Blank_Line,
		title = "Insert a blank line",
		count = 1,
	}
	fix.edits[0] = {{at, at}, "\n"}
	return fix
}

@(private = "file")
escape_start_string :: proc(ix: ^Line_Index, span: Span) -> Fix {
	text := expanded(ix, int(span.start.line))
	if span.start.line != span.end.line || int(span.end.col) > len(text) do return {}
	start := text[span.start.col:span.end.col]
	b := strings.builder_make()
	for c in start {
		strings.write_byte(&b, '\\')
		strings.write_rune(&b, c)
	}
	fix := Fix {
		kind  = .Escape_Start_String,
		title = "Escape the start-string",
		count = 1,
	}
	fix.edits[0] = {span, strings.to_string(b)}
	return fix
}

// "Literal block expected; none found.": the paragraph before the message
// line ends with "::".
@(private = "file")
single_colon :: proc(ix: ^Line_Index, line: int) -> Fix {
	l := trim_blank_end(ix, line - 1, 0)
	text := expanded(ix, l)
	if !strings.has_suffix(text, "::") do return {}
	start := len(text) - 2
	replacement := ":"
	if strings.has_suffix(text, " ::") {
		start -= 1
		replacement = ""
	}
	fix := Fix {
		kind  = .Single_Colon,
		title = "End the paragraph with a single colon",
		count = 1,
	}
	fix.edits[0] = {{{i32(l), i32(start)}, {i32(l), i32(len(text))}}, replacement}
	return fix
}

// LSP severity of a docutils level.
severity :: proc(level: int) -> int {
	switch level {
	case 0:
		return 4 // Hint
	case 1:
		return 3 // Information
	case 2:
		return 2 // Warning
	}
	return 1 // Error
}
