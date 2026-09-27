package transforms

import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:strings"
import "core:time"

import dt "../doctree"

// The state of one ``apply_all`` run: what docutils keeps in the
// ``Transformer``, the transform instances and process-wide caches.

// ``Parser().parse(text, utils.new_document(source_path, settings))``: the
// rST parser, for ``DocInfo``'s re-parse of an author name mistaken for an
// enumerated list (``reader.parse``).  Without it that field stays as is.
Parse_Proc :: proc(
	text: string,
	settings: dt.Settings,
	source_path: string,
	allocator := context.allocator,
) -> ^dt.Doc

Options :: struct {
	reader:          Reader_Kind,
	writer:          dt.Writer_Kind,
	// The language module of ``language_code`` was loaded while parsing
	// (by a ``contents`` directive): loading it again reports nothing.
	language_cached: bool,
	// Directory of the docutils package in module reprs of messages.
	docutils_dir:    string,
	// ``settings._source`` of a document not loaded from a dump.
	source_path:     string,
	parse_rst:       Parse_Proc,
	// The time of ``datestamp`` (default: now).
	now:             Maybe(time.Time),
}

// Settings the ``SectNum`` transform stores for the writer when
// ``sectnum_xform`` is off (``settings.sectnum_*``).
Sectnum_Settings :: struct {
	depth:  Maybe(int),
	start:  int,
	prefix: string,
	suffix: string,
}

Result :: struct {
	sectnum: Maybe(Sectnum_Settings),
}

// An exception of docutils that aborts the run (``DataError``,
// ``SystemMessage`` at the halt level, errors of the transform itself).
Transform_Error :: struct {
	message: string,
}

Error :: union {
	Transform_Error,
}

Run :: struct {
	doc:             ^dt.Doc,
	options:         Options,
	result:          Result,
	err:             Error,
	language_loaded: bool,
	language:        int, // index in ``LANGUAGE_MODULES``
	// ``substitution_reference['ref-origin']`` (a node-valued attribute)
	ref_origin:      map[dt.Node]dt.Node,
	// quotes of ``smartquotes_locales`` (``smartchars.quotes.update``)
	locale_quotes:   [dynamic]Locale_Quotes,
	// the queue is sorted while it has this length (``Transformer.sorted``)
	sorted_count:    int,
	scratch:         virtual.Arena, // the temp allocator of a step
}

run_make :: proc(doc: ^dt.Doc, options: Options) -> Run {
	r := Run {
		doc     = doc,
		options = options,
	}
	if r.options.docutils_dir == "" do r.options.docutils_dir = "<docutils>"
	r.ref_origin = make(map[dt.Node]dt.Node, 16, doc.allocator)
	r.locale_quotes = make([dynamic]Locale_Quotes, doc.allocator)
	r.sorted_count = -1
	if virtual.arena_init_growing(&r.scratch) != nil do panic("transforms: cannot reserve arena")
	return r
}

// The options of a document loaded from a dump: its reader (``input.reader``,
// default standalone) and writer, and whether its ``contents`` directives
// loaded the language module.
options_from_interchange :: proc(doc: ^dt.Doc) -> Options {
	o: Options
	input, _ := doc.interchange.input.(json.Object)
	switch input["writer"].(json.String) or_else "" {
	case "html", "html5":
		o.writer = .Html5
	case "latex", "latex2e":
		o.writer = .Latex
	}
	if (input["reader"].(json.String) or_else "") == "pep" do o.reader = .Pep
	contents := TRANSFORMS[.Contents].name
	for q in doc.pending_queue {
		if q.node != 0 && q.transform == contents do o.language_cached = true
	}
	return o
}

// --- settings ------------------------------------------------------------------

// A setting as docutils holds it: the loaded dump's value (``None`` is
// ``json.Null``); ``ok`` is false for a document not loaded from a dump or
// a setting the dump lacks.
raw_setting :: proc(doc: ^dt.Doc, name: string) -> (json.Value, bool) {
	obj, is_obj := doc.interchange.settings.(json.Object)
	if !is_obj do return nil, false
	v, ok := obj[name]
	return v, ok
}

// Python truthiness of a JSON value.
json_truthy :: proc(v: json.Value) -> bool {
	switch x in v {
	case json.Null:
		return false
	case json.Boolean:
		return x
	case json.Integer:
		return x != 0
	case json.Float:
		return x != 0
	case json.String:
		return x != ""
	case json.Array:
		return len(x) > 0
	case json.Object:
		return len(x) > 0
	}
	return false
}

// Store a setting of a loaded document (dumped with the document).
set_raw_setting :: proc(doc: ^dt.Doc, name: string, value: json.Value) {
	obj, is_obj := &doc.interchange.settings.(json.Object)
	if !is_obj do return
	key := name
	if name not_in obj^ do key = dt.clone(doc, name)
	obj[key] = value
}

// Is the setting ``None`` (or missing) in a loaded document?
setting_is_none :: proc(doc: ^dt.Doc, name: string) -> bool {
	v, ok := raw_setting(doc, name)
	if !ok do return true
	_, null := v.(json.Null)
	return null
}

// ``settings.setdefault(name, default)`` of a boolean setting: ``value``
// (the field of ``Settings``) unless the loaded setting is ``None``, which
// becomes ``default``.
setdefault_bool :: proc(doc: ^dt.Doc, name: string, value, default: bool) -> bool {
	if _, loaded := doc.interchange.settings.(json.Object); !loaded do return value
	if !setting_is_none(doc, name) do return value
	set_raw_setting(doc, name, json.Boolean(default))
	return default
}

// ``utils.get_trim_footnote_ref_space(settings)``.
trim_footnote_ref_space :: proc(doc: ^dt.Doc) -> bool {
	s := &doc.settings
	_, loaded := doc.interchange.settings.(json.Object)
	if loaded && setting_is_none(doc, "trim_footnote_reference_space") {
		return s.footnote_references == "superscript"
	}
	if !loaded && !s.trim_footnote_reference_space {
		return s.footnote_references == "superscript"
	}
	return s.trim_footnote_reference_space
}

// ``settings.title`` (None: ``ok`` false).
title_setting :: proc(doc: ^dt.Doc) -> (string, bool) {
	if _, loaded := doc.interchange.settings.(json.Object); !loaded {
		return doc.settings.title, doc.settings.title != ""
	}
	if setting_is_none(doc, "title") do return "", false
	return doc.settings.title, true
}

// ``settings._source``.
source_setting :: proc(r: ^Run) -> string {
	v, _ := raw_setting(r.doc, "_source")
	if s, ok := v.(json.String); ok do return s
	return r.options.source_path
}

// --- language modules ----------------------------------------------------------

Biblio_Field :: struct {
	name:      string,
	canonical: Label,
}

// What the transforms read from a ``docutils.languages`` module.
Language_Module :: struct {
	name:       string,
	labels:     [Label]string,
	missing:    bit_set[Label],
	fields:     []Biblio_Field,
	separators: []string,
}

@(private = "file")
find_module :: proc(name: string) -> (int, bool) {
	lo, hi := 0, len(LANGUAGE_MODULES)
	for lo < hi {
		mid := (lo + hi) / 2
		switch m := LANGUAGE_MODULES[mid].name; {
		case name < m:
			hi = mid
		case name > m:
			lo = mid + 1
		case:
			return mid, true
		}
	}
	return 0, false
}

// The language module of the run.
language :: proc(r: ^Run) -> ^Language_Module {
	return &LANGUAGE_MODULES[r.language]
}

// ``languages.get_language(language_code, reporter)`` with an empty cache:
// every subtag combination is tried as a module name, with an info message
// for each that is missing; English is the fallback.  With
// ``language_cached`` the module is found silently.
load_language :: proc(r: ^Run) {
	r.language_loaded = true
	doc := r.doc
	code := doc.settings.language_code
	loud := !r.options.language_cached
	ta := context.temp_allocator
	found := false
	for tag in normalize_language_tag(code) {
		name, _ := strings.replace_all(tag, "-", "_", ta)
		if i, ok := find_module(name); ok {
			r.language, found = i, true
			break
		}
		if loud {
			full := strings.concatenate({"docutils.languages.", name}, ta)
			dt.info(doc, strings.concatenate({`Module "`, full, `" not found.`}, ta))
			dt.info(doc, strings.concatenate({`Module "`, name, `" not found.`}, ta))
		}
	}
	if !found {
		if loud {
			msg := `Language "%s" not supported: Docutils-generated text will be in English.`
			dt.warning(doc, fmt.tprintf(msg, code))
		}
		r.language, _ = find_module("en")
	}
	if loud && code != "en" {
		name := LANGUAGE_MODULES[r.language].name
		repr := strings.concatenate(
			{"<module 'docutils.languages.", name, "' from '", r.options.docutils_dir,
			 "/languages/", name, ".py'>"},
			ta,
		)
		dt.info(doc, strings.concatenate({"Using ", repr, ` for language "`, code, `".`}, ta))
	}
}

// ``utils.normalize_language_tag(tag)``: the tag and its subtag
// combinations, lowercased and joined by hyphens, most specific first.
normalize_language_tag :: proc(tag: string, allocator := context.temp_allocator) -> []string {
	ta := context.temp_allocator
	t, _ := strings.replace_all(dt.py_lower(tag), "-", "_", ta)
	t = mark_singletons(t)
	subtags := strings.split(t, "_", ta)
	base, rest := subtags[0], subtags[1:]
	out := make([dynamic]string, 0, 4, allocator)
	for n := len(rest); n > 0; n -= 1 {
		combinations(&out, base, rest, n, allocator)
	}
	append(&out, base)
	return out[:]
}

// ``re.sub(r'_([a-zA-Z0-9])_', r'_\1-', tag)``.
@(private = "file")
mark_singletons :: proc(t: string) -> string {
	b := transmute([]u8)strings.clone(t, context.temp_allocator)
	i := 0
	for i + 2 < len(b) {
		if b[i] == '_' && b[i + 2] == '_' && is_alnum(b[i + 1]) {
			b[i + 2] = '-'
			i += 3
		} else {
			i += 1
		}
	}
	return string(b)
}

@(private = "file")
is_alnum :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
}

// ``itertools.combinations(rest, n)`` in lexicographic index order, each
// appended as ``base-a-b...``.
@(private = "file")
combinations :: proc(
	out: ^[dynamic]string,
	base: string,
	rest: []string,
	n: int,
	allocator := context.temp_allocator,
) {
	idx := make([]int, n, context.temp_allocator)
	for i in 0 ..< n do idx[i] = i
	for {
		parts := make([dynamic]string, 0, n + 1, context.temp_allocator)
		append(&parts, base)
		for i in idx do append(&parts, rest[i])
		append(out, strings.join(parts[:], "-", allocator))
		// advance to the next combination
		i := n - 1
		for i >= 0 && idx[i] == i + len(rest) - n do i -= 1
		if i < 0 do return
		idx[i] += 1
		for j in i + 1 ..< n do idx[j] = idx[j - 1] + 1
	}
}
