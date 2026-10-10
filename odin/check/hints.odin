package check

// Titles and correction hints of the parser's diagnostics (Elm-style reports).

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"

// What the excerpt marks.
Mark :: enum u8 {
	Line,         // the message line
	Context_Line, // the message line, shown after the preceding line
	Last_Line,    // the last line of the source carried by the message
	None,
}

Match :: enum u8 {
	Prefix,
	Contains,
}

Diagnostic :: struct {
	pattern: string,
	match:   Match,
	title:   string,
	hint:    string,
	mark:    Mark,
}

// Specific patterns come before general ones.
@(rodata)
DIAGNOSTICS := [?]Diagnostic {
	// inline markup
	{"Inline emphasis start-string", .Prefix, "UNCLOSED EMPHASIS",
	 "Close the emphasis with a matching `*`, or write `\\*` for a literal asterisk.", .Line},
	{"Inline strong start-string", .Prefix, "UNCLOSED STRONG EMPHASIS",
	 "Close the strong emphasis with a matching `**`, or write `\\*\\*` for literal " +
	 "asterisks.", .Line},
	{"Inline literal start-string", .Prefix, "UNCLOSED INLINE LITERAL",
	 "Close the inline literal with a matching double backquote, or escape the backquotes with " +
	 "backslashes.", .Line},
	{"Inline interpreted text or phrase reference start-string", .Prefix,
	 "UNCLOSED INTERPRETED TEXT",
	 "Close it with a matching backquote. Inline code takes double backquotes: ``code``. " +
	 "Write `\\`` for a literal backquote.", .Line},
	{"Inline substitution_reference start-string", .Prefix, "UNCLOSED SUBSTITUTION REFERENCE",
	 "Close the substitution reference with `|` (as in `|name|`), or write `\\|` for a " +
	 "literal bar.",
	 .Line},
	{"Inline target start-string", .Prefix, "UNCLOSED INLINE TARGET",
	 "Close the inline target with a backquote, as in _`target text`.", .Line},
	{"Multiple roles in interpreted text", .Prefix, "MULTIPLE ROLES",
	 "Give interpreted text one role, either before it (:role:`text`) or after it (`text`:role:).",
	 .Line},
	{"Mismatch: both interpreted text role", .Prefix, "ROLE ON A REFERENCE",
	 "A reference cannot have a role: remove the role, or remove the trailing `_` to make the " +
	 "text interpreted text.", .Line},
	// blank lines and indentation
	{"Line block ends without a blank line.", .Prefix, "MISSING BLANK LINE",
	 "Put a blank line after the line block, or start this line with `| ` to continue it.",
	 .Context_Line},
	{"ends without a blank line; unexpected unindent.", .Contains, "MISSING BLANK LINE", "",
	 .Context_Line},
	{"Unexpected indentation.", .Prefix, "UNEXPECTED INDENTATION",
	 "Remove the extra indentation, or separate the indented text with a blank line to make " +
	 "it a block quote.", .Context_Line},
	{"Blank line required after table.", .Prefix, "MISSING BLANK LINE",
	 "Put a blank line after the bottom border of the table.", .Context_Line},
	{"Literal block expected; none found.", .Prefix, "MISSING LITERAL BLOCK",
	 "A paragraph ending in `::` introduces a literal block: add it after a blank line, " +
	 "indented. End the paragraph with a single `:` if no literal block follows.", .Context_Line},
	{"Inconsistent literal block quoting.", .Prefix, "INCONSISTENT QUOTED LITERAL BLOCK",
	 "Every line of an unindented (quoted) literal block must start with the same punctuation " +
	 "character.", .Line},
	// section titles and transitions
	{"Title underline too short.", .Prefix, "TITLE UNDERLINE TOO SHORT", "", .Last_Line},
	{"Title overline too short.", .Prefix, "TITLE OVERLINE TOO SHORT",
	 "Make the overline and the underline at least as long as the title text.", .Line},
	{"Title overline & underline mismatch.", .Prefix, "TITLE OVERLINE MISMATCH",
	 "Use the same character and the same length for the overline and the underline.", .Last_Line},
	{"Missing matching underline for section title overline.", .Prefix, "MISSING TITLE UNDERLINE",
	 "Add an underline that matches the overline below the title text, or remove the overline.",
	 .None},
	{"Incomplete section title.", .Prefix, "INCOMPLETE SECTION TITLE",
	 "A title with an overline needs the title text and a matching underline below it.", .None},
	{"Unexpected section title or transition.", .Prefix, "UNEXPECTED TRANSITION",
	 "Sections and transitions cannot be nested in lists, block quotes or directives. Move it " +
	 "to the top level, or add a blank line above the line of punctuation if it is not a title.",
	 .Last_Line},
	{"Unexpected section title.", .Prefix, "UNEXPECTED SECTION TITLE",
	 "Sections cannot be nested in lists, block quotes or directives. Move the title to the top " +
	 "level, or escape the first character of the underline (`\\=`) if it is not a title.",
	 .Last_Line},
	{"Invalid section title or transition marker.", .Prefix, "INVALID TITLE OR TRANSITION",
	 "A transition is a line of 4 or more punctuation characters between blank lines; a title " +
	 "needs its text between the overline and the underline.", .Line},
	{"Inconsistent title style:", .Prefix, "SECTION LEVEL SKIPPED",
	 "Title styles are assigned to section levels in the order they are first used. Use the " +
	 "style of an established level, or the next new level.", .None},
	{"Title level inconsistent", .Prefix, "INCONSISTENT TITLE LEVEL",
	 "Use the title style of an established section level.", .None},
	{"Possible title underline, too short for the title.", .Prefix, "POSSIBLE TITLE",
	 "If this is a section title, make the underline at least as long as the title; otherwise " +
	 "separate the text and the line of punctuation with a blank line.", .Last_Line},
	{"Unexpected possible title overline or transition.", .Prefix, "POSSIBLE TITLE OR TRANSITION",
	 "A transition needs 4 or more punctuation characters and blank lines around it.", .Line},
	{"Possible incomplete section title.", .Prefix, "POSSIBLE TITLE",
	 "A title with an overline needs the title text and a matching underline below it.", .Line},
	// tables
	{"Malformed table.", .Prefix, "MALFORMED TABLE",
	 "Check that every row has the same column boundaries and that the border lines are " +
	 "complete and aligned with the `+` and `|` characters.", .None},
	// lists and explicit markup
	{"Enumerated list start value not ordinal-1", .Prefix, "ENUMERATED LIST START",
	 "The list starts at the given ordinal. Start it at 1 (or a, A, i, I) if that was not " +
	 "intended.",
	 .Line},
	{"Invalid option list marker", .Prefix, "INVALID OPTION",
	 "Option lists take options like `-a`, `--long` or `/V`, optionally with an argument " +
	 "(`--file=PATH`); separate the description by at least two spaces.", .Line},
	{"malformed hyperlink target.", .Prefix, "MALFORMED HYPERLINK TARGET",
	 "Write hyperlink targets as `.. _name: URL` or `.. _name:`; escape colons in the name " +
	 "with a backslash.", .Line},
	{"malformed substitution definition.", .Prefix, "MALFORMED SUBSTITUTION DEFINITION",
	 "Write substitution definitions as `.. |name| directive:: arguments`, for example " +
	 "`.. |logo| image:: logo.png`.", .Line},
	{"Footnote content expected.", .Prefix, "EMPTY FOOTNOTE",
	 "Add the footnote text after the label: `.. [1] Footnote text.`", .Line},
	{"Citation content expected.", .Prefix, "EMPTY CITATION",
	 "Add the citation text after the label: `.. [CIT2002] Citation text.`", .Line},
	{"Nesting too deep; content ignored.", .Prefix, "NESTING TOO DEEP",
	 "Reduce the nesting depth of lists, block quotes and directives.", .None},
	{"exceeds the line-length-limit.", .Contains, "LINE TOO LONG",
	 "Shorten the line, or raise the limit with `--line-length-limit`.", .None},
	// sources
	{"Cannot decode the document", .Prefix, "SOURCE IS NOT UTF-8",
	 "Save the file as UTF-8: reStructuredText sources are read as UTF-8.", .None},
	{"Cannot read the document", .Prefix, "UNREADABLE SOURCE",
	 "Check that the file exists and that you may read it.", .None},
}

lookup_diagnostic :: proc(text: string) -> Diagnostic {
	for d in DIAGNOSTICS {
		switch d.match {
		case .Prefix:
			if strings.has_prefix(text, d.pattern) do return d
		case .Contains:
			if strings.contains(text, d.pattern) do return d
		}
	}
	return {mark = .Line}
}

// The hint for message ``m``; some depend on the message.
hint_text :: proc(d: Diagnostic, m: Message) -> string {
	switch d.title {
	case "TITLE UNDERLINE TOO SHORT":
		lines := strings.split_lines(m.literal)
		width := utf8.rune_count(strings.trim_space(lines[0])) if len(lines) > 0 else 0
		return fmt.aprintf(
			"Make the underline at least as long as the title text (%d characters).", width,
		)
	case "MISSING BLANK LINE":
		if d.hint != "" do return d.hint
		construct := m.text[:strings.index(m.text, " ends without")]
		return fmt.aprintf("Put a blank line before this line, or indent it to continue the %s.",
			strings.to_lower(construct))
	}
	return d.hint
}
