package lsp

// Settings, from ``initializationOptions`` or from the ``docodin`` section of
// ``workspace/didChangeConfiguration``:
//
//     {
//       "reportLevel": "warning",       // info, warning, error, severe, none or 0-5
//       "debounce": 150,                // ms from the last change to diagnostics
//       "sphinx": false,                // Sphinx's roles and directives are known
//       "knownRoles": ["ref"],          // roles defined outside docutils
//       "knownDirectives": ["toctree"]  // directives defined outside docutils
//     }
//
// Diagnostics are docutils' messages, and docutils does not know the roles
// and directives of Sphinx or of extensions: the messages about those
// declared known ("Unknown interpreted text role", "Unknown directive
// type" and the lookups before them) are not reported.

import "base:runtime"
import "core:encoding/json"
import "core:strings"
import "core:time"

Config :: struct {
	report_level:     int, // lowest docutils level reported (default: 2, warnings)
	debounce:         time.Duration, // delay of pushed diagnostics after a change
	sphinx:           bool,
	known_roles:      [dynamic]string, // lowercase (heap)
	known_directives: [dynamic]string,
}

DEFAULT_CONFIG :: Config {
	report_level = 2,
	debounce     = 150 * time.Millisecond,
}

// Sphinx's standard roles and directives (the domains' names contain ":";
// the default domain's names are listed).
@(rodata)
SPHINX_ROLES := [?]string {
	"any", "doc", "download", "envvar", "eq", "keyword", "numref", "option", "ref", "term",
	"token", "abbr", "command", "dfn", "file", "guilabel", "kbd", "mailheader", "makevar",
	"manpage", "menuselection", "mimetype", "newsgroup", "program", "regexp", "samp",
	"attr", "class", "const", "data", "exc", "func", "meth", "mod", "obj", "type",
	"confval", "cve", "cwe", "deco", "expr", "member", "macro", "struct", "union", "enum",
	"enumerator", "var", "texpr", "concept",
}

@(rodata)
SPHINX_DIRECTIVES := [?]string {
	"toctree", "literalinclude", "glossary", "index", "only", "tabularcolumns", "centered",
	"hlist", "versionadded", "versionchanged", "deprecated", "versionremoved", "seealso",
	"productionlist", "highlight", "sectionauthor", "moduleauthor", "codeauthor", "todo",
	"todolist", "autosummary", "automodule", "autoclass", "autoexception", "autofunction",
	"automethod", "autoattribute", "autodata", "autoproperty", "autodecorator",
	"currentmodule", "module", "function", "class", "method", "classmethod", "staticmethod",
	"attribute", "property", "data", "exception", "decorator", "decoratormethod", "type",
	"program", "option", "envvar", "describe", "object", "default-domain", "default-role",
	"confval", "graphviz", "digraph", "graph", "inheritance-diagram", "doctest", "testcode",
	"testoutput", "testsetup", "testcleanup", "ifconfig", "plot",
}

// Apply the settings present in ``options``.
configure_from :: proc(c: ^Config, options: json.Value) {
	#partial switch v in get(options, "reportLevel") {
	case json.Integer:
		c.report_level = clamp(int(v), 0, 5)
	case json.String:
		if level, ok := level_by_name(string(v)); ok do c.report_level = level
	}
	if has(options, "debounce") {
		c.debounce = time.Duration(max(get_int(options, "debounce"), 0)) * time.Millisecond
	}
	if has(options, "sphinx") do c.sphinx = get_bool(options, "sphinx")
	if has(options, "knownRoles") do set_names(&c.known_roles, get_array(options, "knownRoles"))
	if has(options, "knownDirectives") {
		set_names(&c.known_directives, get_array(options, "knownDirectives"))
	}
}

@(private = "file")
level_by_name :: proc(name: string) -> (int, bool) {
	names := [?]string{"debug", "info", "warning", "error", "severe", "none"}
	lower := strings.to_lower(name, context.temp_allocator)
	for n, i in names do if n == lower do return i, true
	return 0, false
}

@(private = "file")
set_names :: proc(list: ^[dynamic]string, names: json.Array) {
	heap := runtime.heap_allocator()
	for n in list do delete(n, heap)
	clear(list)
	if list.allocator.procedure == nil do list^ = make([dynamic]string, heap)
	for v in names {
		if s, ok := v.(json.String); ok do append(list, strings.to_lower(string(s), heap))
	}
}

config_destroy :: proc(c: ^Config) {
	heap := runtime.heap_allocator()
	for n in c.known_roles do delete(n, heap)
	for n in c.known_directives do delete(n, heap)
	delete(c.known_roles)
	delete(c.known_directives)
}

// A message about a role or directive the configuration declares known.
known_elsewhere :: proc(c: ^Config, message: string) -> bool {
	is_role := strings.has_prefix(message, "Unknown interpreted text role") ||
		strings.has_prefix(message, "No role entry for")
	is_directive := strings.has_prefix(message, "Unknown directive type") ||
		strings.has_prefix(message, "No directive entry for")
	if !is_role && !is_directive do return false
	_, _, rest := strings.partition(message, `"`)
	name, _, _ := strings.partition(rest, `"`)
	name = strings.to_lower(name, context.temp_allocator)
	if is_role {
		return listed(c.known_roles[:], name) || (c.sphinx && sphinx_name(SPHINX_ROLES[:], name))
	}
	return listed(c.known_directives[:], name) ||
		(c.sphinx && sphinx_name(SPHINX_DIRECTIVES[:], name))
}

@(private = "file")
listed :: proc(names: []string, name: string) -> bool {
	for n in names do if n == name do return true
	return false
}

// Sphinx's names: the listed ones and those of a domain ("py:func").
@(private = "file")
sphinx_name :: proc(names: []string, name: string) -> bool {
	return strings.contains_rune(name, ':') || listed(names, name)
}
