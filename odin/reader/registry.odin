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

// ``languages.en.directives``: English name -> canonical name.
@(private = "file")
EN_DIRECTIVES := [?][2]string {
	{"attention", "attention"},
	{"caution", "caution"},
	{"danger", "danger"},
	{"error", "error"},
	{"hint", "hint"},
	{"important", "important"},
	{"note", "note"},
	{"tip", "tip"},
	{"warning", "warning"},
	{"admonition", "admonition"},
	{"sidebar", "sidebar"},
	{"topic", "topic"},
	{"line-block", "line-block"},
	{"parsed-literal", "parsed-literal"},
	{"code", "code"},
	{"code-block", "code"},
	{"sourcecode", "code"},
	{"math", "math"},
	{"rubric", "rubric"},
	{"epigraph", "epigraph"},
	{"highlights", "highlights"},
	{"pull-quote", "pull-quote"},
	{"compound", "compound"},
	{"container", "container"},
	{"table", "table"},
	{"csv-table", "csv-table"},
	{"list-table", "list-table"},
	{"meta", "meta"},
	{"image", "image"},
	{"figure", "figure"},
	{"include", "include"},
	{"raw", "raw"},
	{"replace", "replace"},
	{"unicode", "unicode"},
	{"date", "date"},
	{"class", "class"},
	{"rst-class", "class"},
	{"role", "role"},
	{"default-role", "default-role"},
	{"title", "title"},
	{"contents", "contents"},
	{"sectnum", "sectnum"},
	{"section-numbering", "sectnum"},
	{"header", "header"},
	{"footer", "footer"},
	{"target-notes", "target-notes"},
	{"restructuredtext-test-directive", "restructuredtext-test-directive"},
}

// ``directives.directive(name, language, document)``: the spec (nil if
// unknown or not ported) and the lookup messages.
lookup_directive :: proc(c: ^Context, name: string) -> (^Directive_Spec, [dynamic]dt.Node) {
	msgs := make([dynamic]dt.Node, c.allocator)
	normname := dt.py_lower(name, c.allocator)
	canonical := ""
	found := false
	for e in EN_DIRECTIVES {
		if e[0] == normname {
			canonical, found = e[1], true
			break
		}
	}
	if !found {
		// not in the language module, nor in the English fallback
		text := concat(
			"No directive entry for \"", name, "\" in module \"", EN_MODULE, "\".\n",
			"Trying \"", name, "\" as canonical directive name.",
		)
		append(&msgs, dt.info(c.doc, text, {line = c.doc.current_line}))
		canonical = normname
	}
	for e in DIRECTIVE_REGISTRY {
		if e.name != canonical do continue
		if e.spec != nil && e.spec.run != nil do return e.spec, msgs
		c.unported += 1
		break
	}
	return nil, msgs
}
