package site

import "core:os"
import "core:strings"

import dt "../doctree"
import rd "../reader"

// The Sphinx roles.  Cross references are ``inline`` placeholders (classes
// "xref", domain and type, as Sphinx writes unresolved ones) carrying:
ATTR_REFTYPE :: "docodin_reftype" // doc, ref, term, numref, download
ATTR_REFTARGET :: "docodin_reftarget" // docname, label, term or file path
ATTR_REFEXPLICIT :: "docodin_refexplicit" // the text is an explicit title

// ``XRefRole``: :doc:, :ref:, :term:, :numref: (and :option:, :envvar:,
// :keyword:, which have no targets natively and stay literal text).
xref_role :: proc(
	c: ^rd.Context,
	r: ^rd.Role,
	rawtext, text: string,
	lineno: int,
	opts: ^rd.Options,
	out, msgs: rd.Node_Out,
) {
	b := build_of(c)
	title, target, explicit := split_explicit_title(text)
	title, target = unescaped(title), unescaped(target)
	kind := r.name
	switch kind {
	case "option", "envvar", "keyword":
		append(out, text_element(c, .literal, rawtext, title, "xref", "std", domain_class(kind)))
		return
	case "doc":
		target = docname_join(current_name(b), strings.trim_suffix(target, SOURCE_SUFFIX))
	case "term":
		target = strings.to_lower(dt.whitespace_normalize_name(target), c.allocator)
	case:
		target = dt.fully_normalize_name(target, c.allocator)
	}
	n := text_element(c, .inline, rawtext, title, "xref", "std", domain_class(kind))
	dt.set_attr(c.doc, n, ATTR_REFTYPE, kind)
	dt.set_attr(c.doc, n, ATTR_REFTARGET, target)
	dt.set_attr(c.doc, n, ATTR_REFEXPLICIT, explicit)
	role_srcline(c, n, lineno)
	append(out, n)
}

@(private = "file")
domain_class :: proc(kind: string) -> string {
	return strings.concatenate({"std-", kind}, context.temp_allocator)
}

// :download:`text <path>`: a file offered for download (a link to a copy
// in the HTML output).
download_role :: proc(
	c: ^rd.Context,
	r: ^rd.Role,
	rawtext, text: string,
	lineno: int,
	opts: ^rd.Options,
	out, msgs: rd.Node_Out,
) {
	b := build_of(c)
	title, target, explicit := split_explicit_title(text)
	title, target = unescaped(title), unescaped(target)
	if !explicit do title = target
	path := join(b.site.srcdir, target[1:]) if strings.has_prefix(target, "/") else
		join(doc_source_dir(b), target)
	lit := text_element(c, .literal, rawtext, title, "xref", "download")
	n := dt.new_element(c.doc, .inline, rawtext)
	dt.list_append(c.doc, n, dt.K_CLASSES, "download")
	dt.append_child(c.doc, n, lit)
	dt.set_attr(c.doc, n, ATTR_REFTYPE, "download")
	dt.set_attr(c.doc, n, ATTR_REFTARGET, path)
	role_srcline(c, n, lineno)
	if !os.is_file(path) {
		msg := dt.warning(c.doc, strings.concatenate({"download file not readable: ", path},
			context.temp_allocator), {line = lineno})
		_ = msg
	}
	append(out, n)
}

// :abbr:`LIFO (last-in, first-out)`: an ``<abbr>`` with the explanation
// as its title in HTML, the explanation in parentheses in LaTeX.
abbr_role :: proc(
	c: ^rd.Context,
	r: ^rd.Role,
	rawtext, text: string,
	lineno: int,
	opts: ^rd.Options,
	out, msgs: rd.Node_Out,
) {
	b := build_of(c)
	t := strings.trim_space(unescaped(text))
	abbr, explanation := t, ""
	if strings.has_suffix(t, ")") {
		if open := strings.index_byte(t, '('); open > 0 {
			abbr = strings.trim_space(t[:open])
			explanation = strings.trim_space(t[open + 1:len(t) - 1])
		}
	}
	if explanation == "" {
		append(out, text_element(c, .abbreviation, rawtext, abbr))
		return
	}
	if b.format == .Latex {
		append(out, text_element(c, .abbreviation, rawtext, abbr))
		append(out, dt.new_text(c.doc, strings.concatenate({" (", explanation, ")"}, c.allocator)))
		return
	}
	html := strings.concatenate({`<abbr title="`, html_escape(explanation), `">`,
		html_escape(abbr), "</abbr>"}, c.allocator)
	n := dt.new_element(c.doc, .raw, rawtext, html)
	dt.set_attr(c.doc, n, "format", "html")
	dt.set_attr(c.doc, n, dt.K_XML_SPACE, "preserve")
	append(out, n)
}

// :samp: and :file:: literal text where ``{var}`` is emphasized.
samp_role :: proc(
	c: ^rd.Context,
	r: ^rd.Role,
	rawtext, text: string,
	lineno: int,
	opts: ^rd.Options,
	out, msgs: rd.Node_Out,
) {
	doc := c.doc
	n := dt.new_element(doc, .literal, rawtext)
	dt.list_append(doc, n, dt.K_CLASSES, r.name)
	sb := strings.builder_make(c.allocator)
	flush :: proc(c: ^rd.Context, n: dt.Node, sb: ^strings.Builder, emphasis: bool) {
		if strings.builder_len(sb^) == 0 do return
		s := strings.clone(strings.to_string(sb^), c.allocator)
		strings.builder_reset(sb)
		if emphasis {
			dt.append_child(c.doc, n, text_element(c, .emphasis, s, s))
		} else {
			dt.append_child(c.doc, n, dt.new_text(c.doc, s))
		}
	}
	in_var := false
	for i := 0; i < len(text); i += 1 {
		ch := text[i]
		switch {
		case ch == 0 && i + 1 < len(text):
			i += 1
			strings.write_byte(&sb, text[i])
		case ch == '{' && !in_var:
			flush(c, n, &sb, false)
			in_var = true
		case ch == '}' && in_var:
			flush(c, n, &sb, true)
			in_var = false
		case:
			strings.write_byte(&sb, ch)
		}
	}
	flush(c, n, &sb, false)
	append(out, n)
}

// :command:, :program:, :kbd: ...: the role's element with its name as class.
simple_role :: proc(
	c: ^rd.Context,
	r: ^rd.Role,
	rawtext, text: string,
	lineno: int,
	opts: ^rd.Options,
	out, msgs: rd.Node_Out,
) {
	append(out, text_element(c, r.tag, rawtext, unescaped(text), r.name))
}

// :guilabel: (an ``&`` marks the accelerator key) and :menuselection:
// ("-->" separates the entries).
guilabel_role :: proc(
	c: ^rd.Context,
	r: ^rd.Role,
	rawtext, text: string,
	lineno: int,
	opts: ^rd.Options,
	out, msgs: rd.Node_Out,
) {
	doc := c.doc
	t := unescaped(text)
	if r.name == "menuselection" {
		t, _ = strings.replace_all(t, "-->", "‣", c.allocator)
	}
	n := dt.new_element(doc, .inline, rawtext)
	dt.list_append(doc, n, dt.K_CLASSES, r.name)
	start := 0
	for i := 0; i < len(t); i += 1 {
		if t[i] != '&' || i + 1 >= len(t) do continue
		if i > start do dt.append_child(doc, n, dt.new_text(doc, t[start:i]))
		if t[i + 1] == '&' {
			dt.append_child(doc, n, dt.new_text(doc, "&"))
		} else {
			dt.append_child(doc, n, text_element(c, .inline, t[i + 1:i + 2], t[i + 1:i + 2],
				"accelerator"))
		}
		i += 1
		start = i + 1
	}
	if start < len(t) do dt.append_child(doc, n, dt.new_text(doc, t[start:]))
	append(out, n)
}

// Text escaped for HTML content and attribute values.
html_escape :: proc(s: string, allocator := context.temp_allocator) -> string {
	if !strings.contains_any(s, "&<>\"") do return s
	b := strings.builder_make(allocator)
	for ch in s {
		switch ch {
		case '&':
			strings.write_string(&b, "&amp;")
		case '<':
			strings.write_string(&b, "&lt;")
		case '>':
			strings.write_string(&b, "&gt;")
		case '"':
			strings.write_string(&b, "&quot;")
		case:
			strings.write_rune(&b, ch)
		}
	}
	return strings.to_string(b)
}
