package texmath

// ``unichar2tex.uni2tex_table`` (`UNI2TEX_TABLE`, used by the LaTeX writer) and
// the ``tex2unichar`` dictionaries (`TEX2UNICHAR_MATHALPHA` and co.).

import "core:strings"

// The LaTeX for character `r` (``uni2tex_table.get(ord(r))``).
uni2tex :: proc "contextless" (r: rune) -> (tex: string, found: bool) {
	return lookup_rune(UNI2TEX_TABLE[:], r)
}

// ``s.translate(uni2tex_table)``.
uni2tex_translate :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(0, len(s), allocator)
	for r in s {
		if tex, found := uni2tex(r); found {
			strings.write_string(&b, tex)
		} else {
			strings.write_rune(&b, r)
		}
	}
	return strings.to_string(b)
}

// The character for a command name in a ``tex2unichar`` table (like
// ``tex2unichar.mathalpha['alpha']``).
tex2unichar :: proc "contextless" (table: []Str_Entry, name: string) -> (string, bool) {
	return lookup(table, name)
}
