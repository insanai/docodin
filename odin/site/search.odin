package site

import "core:slice"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

import dt "../doctree"

// The client-side search index: an inverted index of the words of every
// page (weighted: title 20, section titles 5, text 1 per occurrence), the
// section titles with their anchors, and each page's text for the result
// snippets.  ``docodin.js`` loads it (``searchindex.js``, the same JSON as
// ``searchindex.json`` assigned to ``window.DOCODIN_SEARCH_INDEX``, which
// works from ``file:`` URLs too).
//
//     {"docs": [{"n": "guide/intro", "t": "Title", "x": "text"}],
//      "sections": [[0, "Section title", "anchor"]],
//      "terms": {"word": [[0, 21], [3, 1]]}}

Search_Doc :: struct {
	name, title, text: string,
}

Search_Section :: struct {
	doc:           int,
	title, anchor: string,
}

Search_Index :: struct {
	docs:     [dynamic]Search_Doc,
	sections: [dynamic]Search_Section,
	terms:    map[string][dynamic][2]int, // word -> (doc, weight)
}

SEARCH_TEXT_LIMIT :: 40_000

TITLE_WEIGHT :: 20
SECTION_WEIGHT :: 5

@(private = "file")
STOPWORDS := [?]string {
	"a", "an", "and", "are", "as", "at", "be", "but", "by", "for", "if", "in", "into", "is",
	"it", "no", "not", "of", "on", "or", "such", "that", "the", "their", "then", "there",
	"these", "they", "this", "to", "was", "will", "with",
}

search_index_make :: proc(b: ^Build) -> Search_Index {
	return {
		docs = make([dynamic]Search_Doc),
		sections = make([dynamic]Search_Section),
		terms = make(map[string][dynamic][2]int),
	}
}

// Index page ``id`` (after ``prepare_html_page``).
search_index_add :: proc(ix: ^Search_Index, b: ^Build, id: Doc_Id) {
	page := b.pages[id]
	doc := page.doc
	k := len(ix.docs)
	counts := make(map[string]int, 256, context.temp_allocator)
	add_words(&counts, page.title, TITLE_WEIGHT)
	index_sections(ix, b, k, page.toc, &counts)
	text := collapse_space(page_text(doc))
	add_words(&counts, text, 1)
	if len(text) > SEARCH_TEXT_LIMIT do text = utf8_prefix(text, SEARCH_TEXT_LIMIT)
	append(&ix.docs, Search_Doc{b.site.docs[id].name, page.title, text})
	for word, weight in counts {
		list, found := &ix.terms[word]
		if !found {
			ix.terms[strings.clone(word)] = make([dynamic][2]int)
			list = &ix.terms[word]
		}
		append(list, [2]int{k, weight})
	}
}

@(private = "file")
index_sections :: proc(
	ix: ^Search_Index,
	b: ^Build,
	k: int,
	first: Toc_Id,
	counts: ^map[string]int,
) {
	for it := first; it != 0; it = b.toc[it].next {
		item := b.toc[it]
		if item.kind != .Section do continue
		if item.id != "" {
			append(&ix.sections, Search_Section{k, item.title, item.id})
			add_words(counts, item.title, SECTION_WEIGHT)
		}
		index_sections(ix, b, k, item.first, counts)
	}
}

// The text of the page but system messages and raw output.
@(private = "file")
page_text :: proc(doc: ^dt.Doc) -> string {
	sb := strings.builder_make()
	for n in dt.traverse(doc, doc.root, dt.Tag_Set{.Text}) {
		skip := false
		for p := dt.parent(doc, n); p != 0; p = dt.parent(doc, p) {
			if dt.is(doc, p, {.system_message, .raw, .comment, .generated}) do skip = true
		}
		if skip do continue
		strings.write_string(&sb, doc.nodes[n].text)
		strings.write_byte(&sb, ' ')
	}
	return strings.to_string(sb)
}

@(private = "file")
collapse_space :: proc(s: string) -> string {
	sb := strings.builder_make()
	space := false
	for r in s {
		if unicode.is_space(r) {
			space = strings.builder_len(sb) > 0
			continue
		}
		if space do strings.write_byte(&sb, ' ')
		space = false
		strings.write_rune(&sb, r)
	}
	return strings.to_string(sb)
}

@(private = "file")
utf8_prefix :: proc(s: string, n: int) -> string {
	end := n
	for end > 0 && !utf8.rune_start(s[end]) do end -= 1
	return s[:end]
}

// Add the words of ``text`` (lowercase, two characters or more, no stop
// words) with ``weight`` each.
@(private = "file")
add_words :: proc(counts: ^map[string]int, text: string, weight: int) {
	for word in search_words(text, context.temp_allocator) do counts[word] += weight
}

// The words of a text as the index and ``docodin.js`` split them.
search_words :: proc(text: string, allocator := context.allocator) -> []string {
	out := make([dynamic]string, allocator)
	sb := strings.builder_make(context.temp_allocator)
	flush :: proc(sb: ^strings.Builder, out: ^[dynamic]string, allocator := context.allocator) {
		word := strings.to_string(sb^)
		if utf8.rune_count(word) >= 2 && !slice.contains(STOPWORDS[:], word) {
			append(out, strings.clone(word, allocator))
		}
		strings.builder_reset(sb)
	}
	for r in text {
		if unicode.is_letter(r) || unicode.is_digit(r) || r == '_' {
			strings.write_rune(&sb, unicode.to_lower(r))
		} else {
			flush(&sb, &out, allocator)
		}
	}
	flush(&sb, &out, allocator)
	return out[:]
}

// The index as JSON (terms sorted, for reproducible output).
search_index_json :: proc(ix: ^Search_Index) -> string {
	sb := strings.builder_make()
	strings.write_string(&sb, "{\"docs\":[")
	for d, i in ix.docs {
		if i > 0 do strings.write_byte(&sb, ',')
		strings.write_string(&sb, "{\"n\":")
		json_string(&sb, d.name)
		strings.write_string(&sb, ",\"t\":")
		json_string(&sb, d.title)
		strings.write_string(&sb, ",\"x\":")
		json_string(&sb, d.text)
		strings.write_byte(&sb, '}')
	}
	strings.write_string(&sb, "],\"sections\":[")
	for s, i in ix.sections {
		if i > 0 do strings.write_byte(&sb, ',')
		strings.write_byte(&sb, '[')
		strings.write_int(&sb, s.doc)
		strings.write_byte(&sb, ',')
		json_string(&sb, s.title)
		strings.write_byte(&sb, ',')
		json_string(&sb, s.anchor)
		strings.write_byte(&sb, ']')
	}
	strings.write_string(&sb, "],\"terms\":{")
	write_terms(&sb, ix)
	strings.write_string(&sb, "}}")
	return strings.to_string(sb)
}

@(private = "file")
write_terms :: proc(sb: ^strings.Builder, ix: ^Search_Index) {
	words := make([dynamic]string, 0, len(ix.terms), context.temp_allocator)
	for w in ix.terms do append(&words, w)
	slice.sort(words[:])
	for word, i in words {
		if i > 0 do strings.write_byte(sb, ',')
		json_string(sb, word)
		strings.write_string(sb, ":[")
		for p, j in ix.terms[word] {
			if j > 0 do strings.write_byte(sb, ',')
			strings.write_byte(sb, '[')
			strings.write_int(sb, p[0])
			strings.write_byte(sb, ',')
			strings.write_int(sb, p[1])
			strings.write_byte(sb, ']')
		}
		strings.write_byte(sb, ']')
	}
}

// A JSON string literal (also safe inside a <script>).
json_string :: proc(sb: ^strings.Builder, s: string) {
	strings.write_byte(sb, '"')
	for r in s {
		switch r {
		case '"':
			strings.write_string(sb, "\\\"")
		case '\\':
			strings.write_string(sb, "\\\\")
		case '\n':
			strings.write_string(sb, "\\n")
		case '<':
			strings.write_string(sb, "\\u003c")
		case 0x2028:
			strings.write_string(sb, "\\u2028")
		case 0x2029:
			strings.write_string(sb, "\\u2029")
		case:
			if r < 0x20 {
				hex := "0123456789abcdef"
				strings.write_string(sb, "\\u00")
				strings.write_byte(sb, hex[r >> 4])
				strings.write_byte(sb, hex[r & 15])
			} else {
				strings.write_rune(sb, r)
			}
		}
	}
	strings.write_byte(sb, '"')
}
