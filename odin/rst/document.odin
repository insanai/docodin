package rst

import "base:runtime"
import "core:strings"

Parse_Flag :: enum u32 {
	Match_Titles,
	Raw_Lines, // input is '\n'-joined StringList lines: no string2lines processing
	Character_Level_Inline_Markup,
	Pep_References,
	Rfc_References,
	Trim_Footnote_Reference_Space,
	Rfc2822,
	Spans, // record the source position of every node (``node_span``)
}
Parse_Flags :: bit_set[Parse_Flag; u32]

settings_from_flags :: proc "contextless" (
	flags: Parse_Flags,
	tab_width, line_length_limit: int,
) -> Settings {
	return Settings {
		tab_width                     = tab_width,
		line_length_limit             = line_length_limit,
		character_level_inline_markup = .Character_Level_Inline_Markup in flags,
		pep_references                = .Pep_References in flags,
		rfc_references                = .Rfc_References in flags,
		trim_footnote_reference_space = .Trim_Footnote_Reference_Space in flags,
		rfc2822                       = .Rfc2822 in flags,
		spans                         = .Spans in flags,
	}
}

// Split '\n'-joined lines exactly (``line_count`` lines); whitespace-only
// lines become empty (docutils treats them as blank everywhere).  ``starts``
// is the line table (see ``split_lines_table``).
split_raw_lines :: proc(
	text: string,
	line_count: int,
	allocator: runtime.Allocator,
) -> (
	lines: []string,
	starts: []u32,
) {
	lines = make([]string, max(line_count, 0), allocator)
	starts = make([]u32, len(lines) + 1, allocator)
	offset := 0
	for i in 0 ..< len(lines) {
		rest := text[min(offset, len(text)):]
		nl := strings.index_byte(rest, '\n')
		line := rest if nl < 0 else rest[:nl]
		starts[i] = u32(min(offset, len(text)))
		offset += len(line) + 1
		if len(strip(line)) == 0 do line = rest[:0]
		lines[i] = line
	}
	starts[len(lines)] = u32(len(text))
	return
}

// Parse reStructuredText into a ``Document`` node (docutils
// ``Parser.parse`` / ``RSTState.nested_parse`` equivalent).
// ``final_offset`` is the top state machine's final ``line_offset`` (docutils
// leaves it at len(lines) or len(lines)+1, which determines the reporter's
// "current line" for messages created after parsing).
parse_text :: proc(
	p: ^Parser,
	text: string,
	input_offset: int,
	match_titles: bool,
	raw_line_count := -1,
) -> (
	doc: Node,
	line_count: int,
	final_offset: int,
) {
	tree_init(&p.tree, p.allocator, estimated_node_count(len(text)))
	t := &p.tree
	doc = new_node(t, .Document, 0)
	lines: []string
	if raw_line_count >= 0 {
		lines, t.line_starts = split_raw_lines(text, raw_line_count, p.allocator)
	} else {
		lines, t.line_starts = split_lines_table(text, p.settings.tab_width, p.allocator)
	}
	t.text = text
	if p.settings.spans do spans_begin(p, text, lines, doc)
	line_count = len(lines)
	if p.settings.line_length_limit > 0 {
		if bad := find_overlong_line(lines, p.settings.line_length_limit); bad > 0 {
			lineno := int_str(bad, p.allocator)
			parts := []string{"Line ", lineno, " exceeds the line-length-limit."}
			msg := strings.concatenate(parts, p.allocator)
			append_child(t, doc, make_message(p, ERROR, msg, 0))
			final_offset = -1
			return
		}
	}
	sm := make_state_machine(p, lines, input_offset, doc, match_titles)
	p.root = &sm
	defer p.root = nil
	if p.settings.rfc2822 {
		run_rfc2822_body(&sm)
	} else {
		run_body(&sm)
	}
	// docutils' input lines include the inserted ones
	final_offset = sm.line_offset + (sm.input_offset - input_offset)
	p.inserted = sm.inserted
	return
}

// Initial node capacity for ``text_len`` bytes of input.  Documents produce a
// node per 12 to 40 bytes, about 25 on average (docutils' docs: 25.6).  One
// per 16 bytes covers nearly all real documents without growing the tree
// (growing copies it, and an arena keeps the old copy); the few denser ones
// grow once.
@(private = "file")
estimated_node_count :: #force_inline proc "contextless" (text_len: int) -> int {
	return text_len / 16 + 64
}
