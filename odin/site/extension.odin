package site

import "core:strings"

import dt "../doctree"
import rd "../reader"

// The Sphinx directives and roles of the native builder, registered with
// the reader as its ``Extension``.  They build docutils nodes only (the
// writers know nothing of Sphinx): cross references are ``inline``
// placeholders with the ``docodin_ref*`` attributes, toctrees ``compound``
// placeholders with ``docodin_toctree``, until ``resolve.odin`` replaces them
// once every document is read.

@(private = "file")
DIRECTIVES := [?]rd.Registry_Entry {
	{"toctree", &TOCTREE},
	{"code-block", &CODE_BLOCK},
	{"sourcecode", &CODE_BLOCK},
	{"literalinclude", &LITERALINCLUDE},
	{"highlight", &HIGHLIGHT},
	{"glossary", &GLOSSARY},
	{"seealso", &SEEALSO},
	{"versionadded", &VERSIONADDED},
	{"versionchanged", &VERSIONCHANGED},
	{"deprecated", &DEPRECATED},
	{"versionremoved", &VERSIONREMOVED},
	{"only", &ONLY},
	{"index", &INDEX},
	{"centered", &CENTERED},
	{"hlist", &HLIST},
	{"productionlist", &PRODUCTIONLIST},
	{"graphviz", &GRAPHVIZ},
	{"graph", &GRAPH},
	{"digraph", &DIGRAPH},
	{"tabularcolumns", &IGNORED},
	{"sectionauthor", &IGNORED_ARG},
	{"codeauthor", &IGNORED_ARG},
}

// The roles; ``tag`` and ``name`` (a class) describe the simple ones.
@(private = "file")
ROLES := [?]rd.Role {
	{kind = .Extension, name = "doc", run = xref_role},
	{kind = .Extension, name = "ref", run = xref_role},
	{kind = .Extension, name = "term", run = xref_role},
	{kind = .Extension, name = "numref", run = xref_role},
	{kind = .Extension, name = "keyword", run = xref_role},
	{kind = .Extension, name = "option", run = xref_role},
	{kind = .Extension, name = "envvar", run = xref_role},
	{kind = .Extension, name = "download", run = download_role},
	{kind = .Extension, name = "abbr", run = abbr_role},
	{kind = .Extension, name = "file", run = samp_role},
	{kind = .Extension, name = "samp", run = samp_role},
	{kind = .Extension, name = "command", tag = .strong, run = simple_role},
	{kind = .Extension, name = "program", tag = .strong, run = simple_role},
	{kind = .Extension, name = "dfn", tag = .emphasis, run = simple_role},
	{kind = .Extension, name = "mimetype", tag = .emphasis, run = simple_role},
	{kind = .Extension, name = "makevar", tag = .strong, run = simple_role},
	{kind = .Extension, name = "kbd", tag = .literal, run = simple_role},
	{kind = .Extension, name = "regexp", tag = .literal, run = simple_role},
	{kind = .Extension, name = "guilabel", tag = .inline, run = guilabel_role},
	{kind = .Extension, name = "menuselection", tag = .inline, run = guilabel_role},
}

// The reader extension of a build (its state is the build).
sphinx_extension :: proc(b: ^Build) -> rd.Extension {
	return {directives = DIRECTIVES[:], roles = ROLES[:], data = b}
}

// The build a directive or role runs in.
build_of :: proc(c: ^rd.Context) -> ^Build {
	return (^Build)(c.extension.data)
}

// The docname of the document being read.
current_name :: proc(b: ^Build) -> string {
	return b.site.docs[b.current].name
}

// A warning of the document being read, as a system message.
directive_warning :: proc(c: ^rd.Context, lineno: int, parts: ..string) {
	dt.warning(c.doc, strings.concatenate(parts, context.temp_allocator), {line = lineno})
}

// Sphinx's ``explicit_title_re``: "title <target>" (backslash-escaped "<"
// is part of the title).
split_explicit_title :: proc(text: string) -> (title, target: string, explicit: bool) {
	t := strings.trim_right_space(text)
	if !strings.has_suffix(t, ">") do return text, text, false
	open := strings.last_index_byte(t, '<')
	if open <= 0 || strings.index_byte(t[open + 1:len(t) - 1], '<') >= 0 {
		return text, text, false
	}
	if t[open - 1] == 0 do return text, text, false // an escaped "<"
	title = strings.trim_right_space(t[:open])
	if title == "" do return text, text, false
	return title, t[open + 1:len(t) - 1], true
}

// A class-bearing element with text children (``tag(rawtext, text,
// classes=[...])``).
text_element :: proc(
	c: ^rd.Context,
	tag: dt.Tag,
	rawtext, text: string,
	classes: ..string,
) -> dt.Node {
	n := dt.new_element(c.doc, tag, rawtext, text)
	for cl in classes do dt.list_append(c.doc, n, dt.K_CLASSES, cl)
	return n
}

// ``nodes.Text`` with the backslash escapes of role text resolved.
unescaped :: proc(text: string) -> string {
	return dt.unescape(text, true)
}

// Set the source and line of ``n`` from a role's line number.
role_srcline :: proc(c: ^rd.Context, n: dt.Node, lineno: int) {
	src, ln, _ := rd.get_source_and_line(c, c.top, lineno)
	dt.set_source(c.doc, n, src)
	dt.set_line(c.doc, n, ln)
}
