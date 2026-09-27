package lsp

// Semantic tokens (``textDocument/semanticTokens/full``).
//
// Token types are LSP's standard types where one fits, so themes colour
// them without configuration; emphasis and strong have their own types.

import "core:slice"

import rst "../rst"

Token_Type :: enum u8 {
	Namespace,   // section titles
	Operator,    // title adornments, transitions
	String,      // inline literals
	Comment,     // comments
	Function,    // directive names
	Parameter,   // directive arguments
	Property,    // directive options, field names
	Macro,       // interpreted text roles
	Variable,    // substitution references and definitions
	Type,        // hyperlink references
	Enum_Member, // footnote and citation references and labels
	Decorator,   // hyperlink targets
	Emphasis,
	Strong,
	None,        // not a token
}

Token_Modifier :: enum u8 {
	Declaration,
}

Token_Modifiers :: bit_set[Token_Modifier;u8]

@(rodata)
TOKEN_TYPE_NAMES := [Token_Type]string {
	.Namespace   = "namespace",
	.Operator    = "operator",
	.String      = "string",
	.Comment     = "comment",
	.Function    = "function",
	.Parameter   = "parameter",
	.Property    = "property",
	.Macro       = "macro",
	.Variable    = "variable",
	.Type        = "type",
	.Enum_Member = "enumMember",
	.Decorator   = "decorator",
	.Emphasis    = "emphasis",
	.Strong      = "strong",
	.None        = "",
}

@(rodata)
TOKEN_MODIFIER_NAMES := [Token_Modifier]string {
	.Declaration = "declaration",
}

// A token: a source span (possibly over several lines).
Token :: struct {
	span: Span,
	type: Token_Type,
	mods: Token_Modifiers,
}

// The tokens in document order without overlaps (the first token wins).
sorted_tokens :: proc(a: ^Analysis) -> []Token {
	slice.stable_sort_by(a.tokens[:], proc(x, y: Token) -> bool {
		return x.span.start < y.span.start
	})
	out := make([dynamic]Token, 0, len(a.tokens))
	for t in a.tokens {
		if len(out) > 0 && t.span.start < out[len(out) - 1].span.end do continue
		append(&out, t)
	}
	return out[:]
}

// The LSP encoding of the tokens: five integers per token, positions
// relative to the previous token.  A token over several lines becomes one
// token per line: the line's text after its indentation.
encode_tokens :: proc(w: ^Json_Writer, idx: ^rst.Line_Index, tokens: []Token) {
	e := Token_Encoder{w = w}
	arr_begin(w)
	for t in tokens {
		start, end := to_lsp(idx, t.span.start), to_lsp(idx, t.span.end)
		for line in start.line ..= end.line {
			first := start.character
			if line > start.line do first = indentation(idx, line)
			last := end.character
			if line < end.line do last = to_lsp(idx, line_end(idx, line)).character
			emit(&e, line, first, last, t)
		}
	}
	arr_end(w)
}

@(private = "file")
Token_Encoder :: struct {
	w:                    ^Json_Writer,
	prev_line, prev_char: int,
}

@(private = "file")
emit :: proc(e: ^Token_Encoder, line, first, last: int, t: Token) {
	if last <= first do return
	delta_line := line - e.prev_line
	int_value(e.w, delta_line)
	int_value(e.w, first - (e.prev_char if delta_line == 0 else 0))
	int_value(e.w, last - first)
	int_value(e.w, int(t.type))
	int_value(e.w, int(transmute(u8)t.mods))
	e.prev_line, e.prev_char = line, first
}

// The offset of the end of an LSP line (before its line break).
line_end :: proc(idx: ^rst.Line_Index, line: int) -> i32 {
	return from_lsp(idx, {line, max(int)})
}

// The column after the indentation (spaces and tabs) of an LSP line.
@(private = "file")
indentation :: proc(idx: ^rst.Line_Index, line: int) -> int {
	start := int(from_lsp(idx, {line, 0}))
	at := start
	for at < len(idx.text) && (idx.text[at] == ' ' || idx.text[at] == '\t') do at += 1
	return at - start // spaces and tabs count one column in every encoding
}

// The ``SemanticTokensLegend``.
write_legend :: proc(w: ^Json_Writer) {
	obj_begin(w)
	key(w, "tokenTypes")
	arr_begin(w)
	for name, t in TOKEN_TYPE_NAMES do if t != .None do str_value(w, name)
	arr_end(w)
	key(w, "tokenModifiers")
	arr_begin(w)
	for name in TOKEN_MODIFIER_NAMES do str_value(w, name)
	arr_end(w)
	obj_end(w)
}
