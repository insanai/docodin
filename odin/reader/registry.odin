package reader

import dt "../doctree"

// The directive registry (``directives._directive_registry``) and the
// English directive names (``languages.en.directives``).
//
// A directive is registered by its canonical name with a
// ``Directive_Spec``; the files ``dir_*.odin`` define the standard ones.
// Directives not ported yet (images, tables, ``meta``) are registered
// without ``run``: they are reported like unknown directives until they
// plug in their spec here.

Registry_Entry :: struct {
	name: string,
	spec: ^Directive_Spec,
}

@(private = "file")
DIRECTIVE_REGISTRY := [?]Registry_Entry {
	{"attention", &ATTENTION},
	{"caution", &CAUTION},
	{"code", &CODE_BLOCK},
	{"danger", &DANGER},
	{"error", &ERROR},
	{"important", &IMPORTANT},
	{"note", &NOTE},
	{"tip", &TIP},
	{"hint", &HINT},
	{"warning", &WARNING},
	{"admonition", &ADMONITION},
	{"sidebar", &SIDEBAR},
	{"topic", &TOPIC},
	{"line-block", &LINE_BLOCK},
	{"parsed-literal", &PARSED_LITERAL},
	{"math", &MATH_BLOCK},
	{"rubric", &RUBRIC},
	{"epigraph", &EPIGRAPH},
	{"highlights", &HIGHLIGHTS},
	{"pull-quote", &PULL_QUOTE},
	{"compound", &COMPOUND},
	{"container", &CONTAINER},
	{"table", &RST_TABLE},
	{"csv-table", &CSV_TABLE},
	{"list-table", &LIST_TABLE},
	{"image", &IMAGE},
	{"figure", &FIGURE},
	{"contents", &CONTENTS},
	{"sectnum", &SECTNUM},
	{"header", &HEADER},
	{"footer", &FOOTER},
	{"target-notes", &TARGET_NOTES},
	{"meta", &META},
	{"raw", &RAW},
	{"include", &INCLUDE},
	{"replace", &REPLACE},
	{"unicode", &UNICODE},
	{"class", &CLASS},
	{"role", &ROLE},
	{"default-role", &DEFAULT_ROLE},
	{"title", &TITLE},
	{"date", &DATE},
	{"restructuredtext-test-directive", &TEST_DIRECTIVE},
}

// Directives and roles beyond docutils' own, such as Sphinx's (see
// ``odin/site``).  They are looked up as the directives and roles that
// ``directives.register_directive`` and ``roles.register_local_role`` add:
// before the language module and the standard registry, without lookup
// messages.  A reader without an extension is plain docutils.
Extension :: struct {
	directives: []Registry_Entry, // by lowercase name
	roles:      []Role, // ``kind = .Extension``, by lowercase ``name``
	data:       rawptr, // the extension's state, for its directives and roles
}

// ``directives.directive(name, language, document)``: the spec (nil if
// unknown or not ported) and the lookup messages.
lookup_directive :: proc(c: ^Context, name: string) -> (^Directive_Spec, [dynamic]dt.Node) {
	msgs := make([dynamic]dt.Node, c.allocator)
	normname := dt.py_lower(name, c.allocator)
	if spec, cached := c.directives[normname]; cached do return spec, msgs
	if ext := c.extension; ext != nil {
		for e in ext.directives {
			if e.name != normname do continue
			c.directives[normname] = e.spec
			return e.spec, msgs
		}
	}
	canonical, text := canonical_name(c, .Directive, name, normname)
	if text != "" do append(&msgs, dt.info(c.doc, text, {line = c.doc.current_line}))
	for e in DIRECTIVE_REGISTRY {
		if e.name != canonical do continue
		if e.spec != nil && e.spec.run != nil {
			c.directives[normname] = e.spec
			return e.spec, msgs
		}
		c.unported += 1
		break
	}
	return nil, msgs
}
