package reader

import "core:fmt"
import "core:strings"

import dt "../doctree"
import tf "../transforms"

// The rST language module of the parser (``docutils.parsers.rst.languages``):
// the localized directive and role names, with English as the fallback.

// ``RSTStateMachine.language``: None.
NO_RST_LANGUAGE :: -1

RST_LANGUAGE_PACKAGE :: "docutils.parsers.rst.languages."

// ``languages.get_language(settings.language_code, reporter)`` of
// ``RSTStateMachine.run`` with an empty cache: each module name tried in
// vain is reported (info), then a missing localisation (warning, and no
// module: None) and the module used.  Before the parse, the messages have
// the document's source and no line.
load_rst_language :: proc(c: ^Context) {
	doc := c.doc
	code := doc.settings.language_code
	ta := context.temp_allocator
	at := dt.Message_Options {
		source = doc.reporter.source,
	}
	c.rst_language = NO_RST_LANGUAGE
	if doc.settings.rst_language_cached {
		for tag in tf.normalize_language_tag(code) {
			name, _ := strings.replace_all(tag, "-", "_", ta)
			if i, ok := find_rst_language(name); ok do c.rst_language = i
			if c.rst_language != NO_RST_LANGUAGE do return
		}
		return
	}
	for tag in tf.normalize_language_tag(code) {
		name, _ := strings.replace_all(tag, "-", "_", ta)
		if i, ok := find_rst_language(name); ok {
			c.rst_language = i
			break
		}
		dt.info(doc, concat(`Module "`, RST_LANGUAGE_PACKAGE, name, `" not found.`), at)
		dt.info(doc, concat(`Module "`, name, `" not found.`), at)
	}
	if c.rst_language == NO_RST_LANGUAGE {
		dt.warning(doc, fmt.tprintf(`rST localisation for language "%s" not found.`, code), at)
	}
	if code != "en" {
		msg := concat("Using ", rst_language_repr(c), ` for language "`, code, `".`)
		dt.info(doc, msg, at)
	}
}

@(private = "file")
find_rst_language :: proc(name: string) -> (int, bool) {
	for m, i in RST_LANGUAGES {
		if m.name == name do return i, true
	}
	return 0, false
}

// ``repr(module)``.
@(private = "file")
rst_language_repr :: proc(c: ^Context) -> string {
	if c.rst_language == NO_RST_LANGUAGE do return "None"
	name := RST_LANGUAGES[c.rst_language].name
	dir := c.doc.settings.docutils_dir
	if dir == "" do dir = "<docutils>"
	return concat("<module '", RST_LANGUAGE_PACKAGE, name, "' from '", dir,
		"/parsers/rst/languages/", name, ".py'>")
}

// ``language_module.__name__`` of the parser's module.
rst_language_module_name :: proc(c: ^Context) -> string {
	return concat(RST_LANGUAGE_PACKAGE, RST_LANGUAGES[c.rst_language].name)
}

Name_Kind :: enum u8 {
	Directive,
	Role,
}

// ``module.directives[normname]`` / ``module.roles[normname]``.
local_name :: proc(module: int, kind: Name_Kind, normname: string) -> (string, bool) {
	m := RST_LANGUAGES[module]
	names := RST_DIRECTIVE_NAMES[:] if kind == .Directive else RST_ROLE_NAMES[:]
	r := m.directives if kind == .Directive else m.roles
	for e in names[r[0]:r[0] + r[1]] {
		if e[0] == normname do return e[1], true
	}
	return "", false
}

// The English module (``_fallback_language_module``).
english_name :: proc(kind: Name_Kind, normname: string) -> (string, bool) {
	en, _ := find_rst_language("en")
	return local_name(en, kind, normname)
}

// The canonical name of a directive or role: the parser's language
// module, then English; ``msg`` is the text of the lookup's info message
// ("" for none), as ``directives.directive`` and ``roles.role`` report it.
canonical_name :: proc(c: ^Context, kind: Name_Kind, name, normname: string) -> (string, string) {
	what := "directive" if kind == .Directive else "role"
	lines := make([dynamic]string, 0, 2, context.temp_allocator)
	canonical := ""
	if c.rst_language == NO_RST_LANGUAGE {
		attr := "directives" if kind == .Directive else "roles"
		append(&lines, concat("Problem retrieving ", what, " entry from language module None: ",
			"'NoneType' object has no attribute '", attr, "'."))
	} else if found, ok := local_name(c.rst_language, kind, normname); ok {
		canonical = found
	} else {
		append(&lines, concat("No ", what, ` entry for "`, name, `" in module "`,
			rst_language_module_name(c), `".`))
	}
	if canonical == "" {
		if found, ok := english_name(kind, normname); ok {
			canonical = found
			append(&lines, concat("Using English fallback for ", what, ` "`, name, `".`))
		} else {
			canonical = normname
			append(&lines, concat(`Trying "`, name, `" as canonical `, what, " name."))
		}
	}
	return canonical, strings.join(lines[:], "\n", context.temp_allocator)
}
