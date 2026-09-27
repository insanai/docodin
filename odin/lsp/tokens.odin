package lsp

// Semantic tokens (``textDocument/semanticTokens/full``).
//
// Token types are LSP's standard types where one fits, so themes colour
// them without configuration; emphasis and strong have their own types.

import "core:slice"

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

// A single-line token in the parser's coordinates.
Token :: struct {
	line, col, length: i32,
	type:              Token_Type,
	mods:              Token_Modifiers,
}

// Add a token for ``span``; a span over several lines becomes one token
// per line (each line's content).
add_token_span :: proc(
	a: ^Analysis,
	ix: ^Line_Index,
	span: Span,
	type: Token_Type,
	mods := Token_Modifiers{},
) {
	if type == .None || span.start.line < 0 do return
	for l := span.start.line; l <= span.end.line; l += 1 {
		text := expanded(ix, int(l))
		indent := i32(len(text) - len(lstrip_spaces(text)))
		start := span.start.col if l == span.start.line else indent
		end := span.end.col if l == span.end.line else i32(len(text))
		if end > start do append(&a.tokens, Token{l, start, end - start, type, mods})
	}
}

@(private = "file")
lstrip_spaces :: proc(s: string) -> string {
	i := 0
	for i < len(s) && s[i] == ' ' do i += 1
	return s[i:]
}

// The tokens in document order without overlaps (the first token wins).
sorted_tokens :: proc(a: ^Analysis) -> []Token {
	slice.stable_sort_by(a.tokens[:], proc(x, y: Token) -> bool {
		return x.line < y.line || (x.line == y.line && x.col < y.col)
	})
	out := make([dynamic]Token, 0, len(a.tokens))
	for t in a.tokens {
		if len(out) > 0 {
			prev := out[len(out) - 1]
			if prev.line == t.line && t.col < prev.col + prev.length do continue
		}
		append(&out, t)
	}
	return out[:]
}

// The LSP encoding of the tokens: five integers per token, positions
// relative to the previous token.
encode_tokens :: proc(w: ^Json_Writer, ix: ^Line_Index, tokens: []Token, enc: Encoding) {
	arr_begin(w)
	prev_line, prev_char := 0, 0
	for t in tokens {
		start := to_lsp(ix, {t.line, t.col}, enc)
		end := to_lsp(ix, {t.line, t.col + t.length}, enc)
		if end.character <= start.character do continue
		delta_line := start.line - prev_line
		delta_char := start.character - (prev_char if delta_line == 0 else 0)
		int_value(w, delta_line)
		int_value(w, delta_char)
		int_value(w, end.character - start.character)
		int_value(w, int(t.type))
		int_value(w, int(transmute(u8)t.mods))
		prev_line, prev_char = start.line, start.character
	}
	arr_end(w)
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
