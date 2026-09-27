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
}
Parse_Flags :: bit_set[Parse_Flag; u32]

settings_from_flags :: proc "contextless" (flags: Parse_Flags, tab_width, line_length_limit: int) -> Settings {
	return Settings {
		tab_width                     = tab_width,
		line_length_limit             = line_length_limit,
		character_level_inline_markup = .Character_Level_Inline_Markup in flags,
		pep_references                = .Pep_References in flags,
		rfc_references                = .Rfc_References in flags,
		trim_footnote_reference_space = .Trim_Footnote_Reference_Space in flags,
		rfc2822                       = .Rfc2822 in flags,
	}
}

// Split '\n'-joined lines exactly (``line_count`` lines); whitespace-only
// lines become empty (docutils treats them as blank everywhere).
split_raw_lines :: proc(text: string, line_count: int, allocator: runtime.Allocator) -> []string {
	lines := make([]string, max(line_count, 0), allocator)
	rest := text
	for i in 0 ..< len(lines) {
		nl := strings.index_byte(rest, '\n')
		line := rest if nl < 0 else rest[:nl]
		rest = "" if nl < 0 else rest[nl + 1:]
		if len(strip(line)) == 0 do line = ""
		lines[i] = line
	}
	return lines
}

// Parse reStructuredText into a ``Document`` node (docutils
// ``Parser.parse`` / ``RSTState.nested_parse`` equivalent).
// ``final_offset`` is the top state machine's final ``line_offset`` (docutils
// leaves it at len(lines) or len(lines)+1, which determines the reporter's
// "current line" for messages created after parsing).
parse_text :: proc(p: ^Parser, text: string, input_offset: int, match_titles: bool, raw_line_count := -1) -> (doc: ^Node, line_count: int, final_offset: int) {
	doc = new_node(.Document, 0, p.allocator)
	lines: []string
	if raw_line_count >= 0 {
		lines = split_raw_lines(text, raw_line_count, p.allocator)
	} else {
		lines = split_lines(text, p.settings.tab_width, p.allocator)
	}
	line_count = len(lines)
	if p.settings.line_length_limit > 0 {
		if bad := find_overlong_line(lines, p.settings.line_length_limit); bad > 0 {
			msg := strings.concatenate({"Line ", int_str(bad, p.allocator), " exceeds the line-length-limit."}, p.allocator)
			append_child(doc, make_message(p, ERROR, msg, 0))
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
	final_offset = sm.line_offset
	return
}
