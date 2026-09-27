package lsp

// Diagnostics: the system messages docutils reports for the document,
// with their texts, levels and lines, from the native pipeline (reader,
// directives, roles and the standard transforms, as ``publish`` runs them:
// ``publish.read_document``).  The analysis adds what docutils' messages
// lack: the columns of inline markup errors (the parse tree's problematic
// nodes) and of the names they report; the checker (odin/check) the Elm
// title and hint of each message.  Mechanical hints come with a quick fix
// (see code_actions.odin).

import "base:runtime"
import "core:strings"

import check "../check"
import dt "../doctree"
import pb "../publish"
import rd "../reader"
import rst "../rst"

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

// A replacement of ``span`` (byte offsets) by ``text``.
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

// What docutils' pipeline gives the server for one version of a document.
Reading :: struct {
	messages:  []Docutils_Message,
	exception: string, // the exception docutils raises ("" for none)
	tree:      rd.Parse_Tree, // the parse tree of the reader
}

// Read ``text`` as ``publish_string`` does, with ``report_level=1`` and
// ``halt_level=5``: the messages, the exception docutils raises, if any, and
// the parse tree.  Allocated with ``allocator`` (an arena).
read_with_docutils :: proc(text, source_path: string, allocator: runtime.Allocator) -> Reading {
	context.allocator = allocator
	context.temp_allocator = allocator
	overrides := [?]pb.Override{{"report_level", 1}, {"halt_level", 5}}
	options := pb.Read_Options {
		keep_tree = true,
	}
	r := pb.read_document(text, source_path, "pseudoxml", overrides[:], options, allocator)
	defer dt.destroy(r.doc)
	out := make([dynamic]Docutils_Message, 0, len(r.messages))
	for dm in r.messages {
		first, _, rest := strings.partition(dm.text, "\n\n")
		detail, _, _ := strings.partition(rest, "\n\n")
		m := Docutils_Message{dm.level, dm.line, dm.source, dm.text, first, detail}
		if !library_missing(r.needs, m) do append(&out, m)
	}
	reading := Reading {
		messages = out[:],
		tree     = r.tree,
	}
	if e, raised := r.err.(pb.Exception); raised do reading.exception = e.text
	return reading
}

// The native pipeline reports what docutils reports without Pygments;
// docutils installations for editing (Sphinx) have it.
@(private = "file")
library_missing :: proc(needs: []pb.Python_Need, m: Docutils_Message) -> bool {
	if m.first != "Cannot analyze code. Pygments package not found." do return false
	for need in needs do if need.feature == .Pygments do return true
	return false
}

// The diagnostics of snapshot ``s`` with the settings ``cfg``.
build_diagnostics :: proc(s: ^Snapshot, cfg: ^Config) -> [dynamic]Diagnostic {
	context.allocator = s.allocator
	context.temp_allocator = s.allocator
	out := make([dynamic]Diagnostic, 0, 8)
	used := make([]bool, len(s.analysis.problems))
	for m in s.reading.messages {
		if m.level < cfg.report_level || known_elsewhere(cfg, m.first) do continue
		cm := check.Message {
			line    = m.line,
			level   = m.level,
			text    = m.first,
			literal = m.detail,
		}
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
		problem := match_problem(s.analysis.problems[:], used, m)
		d.span = message_span(s, m, problem)
		d.fix = fix_for(s, d, m, problem != nil)
		append(&out, d)
	}
	if s.reading.exception != "" {
		text := strings.concatenate({"docutils stops with an exception: ", s.reading.exception})
		d := Diagnostic {
			span    = content_span(&s.analysis.tree, 1),
			level   = rst.SEVERE,
			message = text,
		}
		append(&out, d)
	}
	return out
}

// The inline markup problem of a message (same line and text).
@(private = "file")
match_problem :: proc(problems: []Problem, used: []bool, m: Docutils_Message) -> ^Problem {
	for &pr, i in problems {
		if used[i] || int(pr.line) != m.line || pr.message != m.first do continue
		used[i] = true
		return &pr
	}
	return nil
}

// Where a message points: the offending inline text, the construct it
// names, or its line.
@(private = "file")
message_span :: proc(s: ^Snapshot, m: Docutils_Message, problem: ^Problem) -> Span {
	t := &s.analysis.tree
	if m.source != "" && m.source != s.path {
		// a message of an included file: the include directive
		for item in s.analysis.items {
			if item.kind == .Directive && item.name == "include" do return item.span
		}
		return content_span(t, 1)
	}
	if problem != nil do return problem.span
	if span, ok := named_span(s, m); ok do return span
	return content_span(t, clamp(m.line, 1, max(rst.line_count(t), 1)))
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
	t := &s.analysis.tree
	from := i32(t.line_starts[clamp(m.line - 1, 0, len(t.line_starts) - 1)])
	for item in s.analysis.items {
		if item.kind not_in kinds || item.span.start < from do continue
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
fix_for :: proc(s: ^Snapshot, d: Diagnostic, m: Docutils_Message, inline: bool) -> Fix {
	t := &s.analysis.tree
	switch d.code {
	case "TITLE UNDERLINE TOO SHORT", "TITLE OVERLINE TOO SHORT":
		return extend_adornment(t, m.line)
	case "POSSIBLE TITLE":
		if strings.has_prefix(m.first, "Possible title underline") {
			return extend_adornment(t, m.line)
		}
	case "MISSING BLANK LINE", "UNEXPECTED INDENTATION":
		return insert_blank_line(t, m.line)
	case "UNCLOSED EMPHASIS", "UNCLOSED STRONG EMPHASIS", "UNCLOSED INLINE LITERAL",
	     "UNCLOSED INTERPRETED TEXT", "UNCLOSED SUBSTITUTION REFERENCE", "UNCLOSED INLINE TARGET":
		if inline do return escape_start_string(t, d.span)
	case "MISSING LITERAL BLOCK":
		return single_colon(t, m.line)
	}
	return {}
}

// The title near ``line`` (a title line followed by its underline).
@(private = "file")
find_title :: proc(t: ^rst.Tree, line: int) -> (title: int, ok: bool) {
	for l in ([?]int{line - 1, line, line - 2, line + 1}) {
		if l < 1 || l + 1 > rst.line_count(t) do continue
		text := line_text(t, l)
		if is_blank(text) || is_adornment(text) do continue
		if is_adornment(line_text(t, l + 1)) do return l, true
	}
	return 0, false
}

// Lengthen the underline (and the overline) of the title near ``line``.
@(private = "file")
extend_adornment :: proc(t: ^rst.Tree, line: int) -> Fix {
	title, ok := find_title(t, line)
	if !ok do return {}
	under := line_text(t, title + 1)
	over := line_text(t, title - 1)
	has_over := title > 1 && is_adornment(over) && over[0] == under[0]
	width := max(rst.column_width(line_text(t, title)), len(under))
	if has_over do width = max(width, len(over))
	adornment := strings.repeat(under[:1], width)
	fix := Fix {
		kind  = .Extend_Adornment,
		title = "Extend the title adornment to the title's width",
		count = 1,
	}
	fix.edits[0] = {whole_line(t, title + 1), adornment}
	if has_over {
		fix.edits[1] = {whole_line(t, title - 1), adornment}
		fix.count = 2
	}
	return fix
}

@(private = "file")
insert_blank_line :: proc(t: ^rst.Tree, line: int) -> Fix {
	if line <= 1 || line > rst.line_count(t) do return {}
	at := i32(t.line_starts[line - 1])
	fix := Fix {
		kind  = .Insert_Blank_Line,
		title = "Insert a blank line",
		count = 1,
	}
	fix.edits[0] = {{at, at}, "\n"}
	return fix
}

@(private = "file")
escape_start_string :: proc(t: ^rst.Tree, span: Span) -> Fix {
	start := t.text[span.start:span.end]
	if strings.contains_any(start, "\r\n") || start == "" do return {}
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
single_colon :: proc(t: ^rst.Tree, line: int) -> Fix {
	l := last_nonblank(t, line - 1, 0)
	content := content_span(t, l)
	text := t.text[content.start:content.end]
	if !strings.has_suffix(text, "::") do return {}
	start := content.end - 2
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
	fix.edits[0] = {{start, content.end}, replacement}
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
