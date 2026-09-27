package transforms

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"

import dt "../doctree"
import "../text"

// ``universal.SmartQuotes``: typographic quotes, dashes and ellipses in the
// text of block-level text elements, by the language of each block.  The
// educating itself is ``text.educate_token`` (``utils.smartquotes``).

// A ``smartquotes_locales`` entry (``smartchars.quotes.update``).
Locale_Quotes :: struct {
	tag:    string,
	quotes: text.Quotes,
}

@(private = "file")
SKIPPED :: dt.Category.FixedTextElement

@(private = "file")
LITERAL_TAGS :: dt.Tag_Set{.image, .literal, .math, .raw, .problematic}

@(private = "file")
Smart :: struct {
	r:           ^Run,
	doc:         ^dt.Doc,
	alternative: bool,
	unsupported: map[string]struct{},
}

// ``SmartQuotes``: with the ``smart_quotes`` setting.
smart_quotes :: proc(r: ^Run, _: dt.Node, _: []dt.Detail) {
	doc := r.doc
	if !setdefault_bool(doc, "smart_quotes", doc.settings.smart_quotes, false) do return
	add_locales(r)
	s := Smart {
		r           = r,
		doc         = doc,
		alternative = doc.settings.smart_quotes_alt,
		unsupported = make(map[string]struct{}, 4, context.temp_allocator),
	}
	it := dt.findall(doc, doc.root, dt.tags_of(.TextElement))
	for node in dt.next(&it) {
		if dt.is_a(doc, node, SKIPPED) || dt.is_a(doc, node, .Special) do continue
		if dt.is_a(doc, dt.parent(doc, node), .TextElement) do continue
		educate_block(&s, node)
	}
}

// ``smartquotes_locales``: "language:quotes" with four quote characters or
// four colon-separated quotes.
@(private = "file")
add_locales :: proc(r: ^Run) {
	for entry in r.doc.settings.smartquotes_locales {
		colon := strings.index_byte(entry, ':')
		if colon < 0 do continue
		tag, marks := entry[:colon], entry[colon + 1:]
		q: [4]string
		if parts := strings.split(marks, ":", context.temp_allocator); len(parts) == 4 {
			for p, i in parts do q[i] = dt.clone(r.doc, p)
		} else if utf8.rune_count_in_string(marks) == 4 {
			i := 0
			for _, pos in marks {
				_, w := utf8.decode_rune_in_string(marks[pos:])
				q[i] = dt.clone(r.doc, marks[pos:][:w])
				i += 1
			}
		} else {
			continue
		}
		quotes := text.Quotes{q[0], q[1], q[2], q[3]}
		set_locale(r, dt.clone(r.doc, tag), quotes)
	}
}

@(private = "file")
set_locale :: proc(r: ^Run, tag: string, quotes: text.Quotes) {
	for &l in r.locale_quotes {
		if l.tag == tag {
			l.quotes = quotes
			return
		}
	}
	append(&r.locale_quotes, Locale_Quotes{tag, quotes})
}

// ``tag in smartchars.quotes``.
@(private = "file")
has_quotes :: proc(r: ^Run, tag: string) -> bool {
	for l in r.locale_quotes do if l.tag == tag do return true
	lo, hi := 0, len(text.LANGUAGE_QUOTES)
	for lo < hi {
		mid := (lo + hi) / 2
		switch t := text.LANGUAGE_QUOTES[mid].tag; {
		case tag < t:
			hi = mid
		case tag > t:
			lo = mid + 1
		case:
			return true
		}
	}
	return false
}

// ``smartchars(language)``: the quotes of ``language.lower()``.
@(private = "file")
quotes_of :: proc(r: ^Run, language: string) -> text.Quotes {
	key := dt.py_lower(language)
	for l in r.locale_quotes do if l.tag == key do return l.quotes
	return text.quotes_for(language)
}

// The language of a block: the first supported subtag combination of its
// language (with the ``-x-altquot`` variant toggled for "alternative"
// quotes), "" (ASCII quotes, with a warning) if none is supported.
@(private = "file")
block_language :: proc(s: ^Smart, node: dt.Node) -> string {
	doc := s.doc
	lang := dt.get_language_code(doc, node, doc.settings.language_code)
	if s.alternative {
		if strings.contains(lang, "-x-altquot") {
			lang, _ = strings.remove_all(lang, "-x-altquot", context.temp_allocator)
		} else {
			lang = strings.concatenate({lang, "-x-altquot"}, context.temp_allocator)
		}
	}
	for tag in normalize_language_tag(lang) {
		if has_quotes(s.r, tag) do return tag
	}
	if lang not_in s.unsupported {
		msg := fmt.tprintf(`No smart quotes defined for language "%s".`, lang)
		dt.warning(doc, msg, {base_node = node})
		s.unsupported[lang] = {}
	}
	return ""
}

@(private = "file")
educate_block :: proc(s: ^Smart, node: dt.Node) {
	doc := s.doc
	txtnodes := make([dynamic]dt.Node, 0, 8, context.temp_allocator)
	for t in dt.traverse(doc, node, dt.Tag_Set{.Text}) {
		if dt.tag(doc, dt.parent(doc, t)) != .option_string do append(&txtnodes, t)
	}
	lang := block_language(s, node)
	e := text.educator_make("qDe", lang, quotes_of(s.r, lang))
	for t in txtnodes {
		kind, data := token_of(doc, t)
		educated := text.educate_token(&e, kind, data)
		dt.replace(doc, dt.parent(doc, t), t, dt.new_text(doc, educated))
	}
}

@(private = "file")
is_literal :: proc(doc: ^dt.Doc, n: dt.Node) -> bool {
	if n == 0 do return false
	return dt.is(doc, n, LITERAL_TAGS) || dt.is_a(doc, n, SKIPPED) || dt.is_a(doc, n, .Special)
}

// The class of ``re.sub('(?<=\x00)([-\\\'".`])', ...)``: the Python string
// literal turns ``\\\'`` into the regex escape ``\'`` (a quote), so a
// backslash is not among them.
@(private = "file")
ESCAPED_ACTIVE :: "-'\".`"

// ``SmartQuotes.get_tokens``: text in literal elements stays literal;
// escaped quotes and dashes get their backslash back.
@(private = "file")
token_of :: proc(doc: ^dt.Doc, t: dt.Node) -> (text.Token_Kind, string) {
	p := dt.parent(doc, t)
	data := dt.text(doc, t)
	if is_literal(doc, p) || is_literal(doc, dt.parent(doc, p)) do return .Literal, data
	if strings.index_byte(data, 0) < 0 do return .Text, data
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< len(data) {
		c := data[i]
		if i > 0 && data[i - 1] == 0 && strings.index_byte(ESCAPED_ACTIVE, c) >= 0 {
			strings.write_byte(&b, '\\')
		}
		strings.write_byte(&b, c)
	}
	return .Text, strings.to_string(b)
}
