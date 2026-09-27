package writers

import "core:strings"

// ``docutils.languages.get_language`` and ``utils.normalize_language_tag``.

Language_Module :: struct {
	name:              string, // module name, e.g. "pt_br"
	labels:            [Label]string,
	author_separators: []string,
}

// ``utils.normalize_language_tag(tag)``: the tag and its combinations of
// subtags, most specific first, e.g. "de-at-1901", "de-at", "de-1901", "de".
normalize_language_tag :: proc(tag: string) -> []string {
	t, _ := strings.replace_all(strings.to_lower(tag, context.temp_allocator), "-", "_")
	// ``re.sub(r'_([a-zA-Z0-9])_', r'_\1-', tag)``: a singleton marks the
	// following subtag as non-standard.
	b := transmute([]u8)strings.clone(t, context.temp_allocator)
	for i := 0; i + 2 < len(b); i += 1 {
		c := b[i + 1]
		alnum := (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')
		if b[i] == '_' && alnum && b[i + 2] == '_' {
			b[i + 2] = '-'
			i += 2
		}
	}
	subtags := strings.split(string(b), "_", context.temp_allocator)
	base, rest := subtags[0], subtags[1:]
	out := make([dynamic]string, 0, 8, context.temp_allocator)
	for n := len(rest); n > 0; n -= 1 {
		combinations(&out, base, rest, n)
	}
	append(&out, base)
	return out[:]
}

// Append ``"-".join((base, *combo))`` for the ``n``-combinations of
// ``items`` in ``itertools.combinations`` order.
@(private = "file")
combinations :: proc(out: ^[dynamic]string, base: string, items: []string, n: int) {
	idx := make([]int, n, context.temp_allocator)
	for i in 0 ..< n do idx[i] = i
	for {
		parts := make([dynamic]string, 0, n + 1, context.temp_allocator)
		append(&parts, base)
		for i in idx do append(&parts, items[i])
		append(out, strings.join(parts[:], "-", context.temp_allocator))
		i := n - 1
		for i >= 0 && idx[i] == i + len(items) - n do i -= 1
		if i < 0 do return
		idx[i] += 1
		for j in i + 1 ..< n do idx[j] = idx[j - 1] + 1
	}
}

// ``languages.get_language(language_code)``: the language module, English if
// there is none.
get_language :: proc(language_code: string) -> ^Language_Module {
	for tag in normalize_language_tag(language_code) {
		name, _ := strings.replace_all(tag, "-", "_", context.temp_allocator)
		if m := find_language(name); m != nil do return m
	}
	return find_language("en")
}

@(private = "file")
find_language :: proc(name: string) -> ^Language_Module {
	for &m in LANGUAGE_MODULES {
		if m.name == name do return &m
	}
	return nil
}
