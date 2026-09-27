package writers

import "core:encoding/base64"
import "core:os"
import "core:strings"

import dt "../doctree"
import texmath "../math"

// HTML5 visitors of images and mathematics
// (``_html_base_media.MediaTranslatorMixin``).  Image sizes are never read
// from the image file: docutils needs PIL for that, and without it warns as
// the native writer does.  Where docutils would read the size, the writer
// records a Python need.

VIDEO_TYPES :: [?]string{"video/mp4", "video/webm", "video/ogg"}

// ``mimetypes.guess_type(uri)[0]`` for the media types of Python's default
// table that the writer distinguishes or embeds.  As in Python, the
// system's ``mime.types`` files (``mimetypes.knownfiles``) override them.
@(private = "file")
MIME_TYPES := [?][2]string {
	{".avif", "image/avif"},
	{".bmp", "image/bmp"},
	{".gif", "image/gif"},
	{".heic", "image/heic"},
	{".ico", "image/vnd.microsoft.icon"},
	{".jpe", "image/jpeg"},
	{".jpeg", "image/jpeg"},
	{".jpg", "image/jpeg"},
	{".m4v", "video/x-m4v"},
	{".mov", "video/quicktime"},
	{".mp4", "video/mp4"},
	{".mpeg", "video/mpeg"},
	{".mpg", "video/mpeg"},
	{".ogg", "audio/ogg"},
	{".ogv", "video/ogg"},
	{".pdf", "application/pdf"},
	{".png", "image/png"},
	{".svg", "image/svg+xml"},
	{".swf", "application/x-shockwave-flash"},
	{".tif", "image/tiff"},
	{".tiff", "image/tiff"},
	{".webm", "video/webm"},
	{".webp", "image/webp"},
}

@(private = "file")
KNOWN_FILES := [?]string {
	"/etc/mime.types",
	"/etc/httpd/mime.types",
	"/etc/httpd/conf/mime.types",
	"/etc/apache/mime.types",
	"/etc/apache2/mime.types",
	"/usr/local/etc/httpd/conf/mime.types",
	"/usr/local/lib/netscape/mime.types",
	"/usr/local/etc/mime.types",
}

// The type of an extension in the system's ``mime.types`` files (the last
// file listing it wins).
@(private = "file")
system_mime_type :: proc(ext: string) -> (mimetype: string, found: bool) {
	for path in KNOWN_FILES {
		data, err := os.read_entire_file_from_path(path, context.temp_allocator)
		if err != nil do continue
		text := string(data)
		for line in strings.split_lines_iterator(&text) {
			content, _, _ := strings.partition(line, "#")
			words := strings.fields(content, context.temp_allocator)
			if len(words) < 2 do continue
			for w in words[1:] {
				if len(w) + 1 == len(ext) && ext[1:] == w {
					mimetype, found = words[0], true
				}
			}
		}
	}
	return
}

@(private = "file")
lookup_mime_type :: proc(ext: string) -> (string, bool) {
	if m, ok := system_mime_type(ext); ok do return m, true
	for m in MIME_TYPES do if m[0] == ext do return m[1], true
	return "", false
}

guess_mime_type :: proc(uri: string) -> string {
	slash := strings.last_index_byte(uri, '/')
	name := uri[slash + 1:]
	dot := strings.last_index_byte(name, '.')
	if dot < 0 do return ""
	ext := name[dot:]
	if m, ok := lookup_mime_type(ext); ok do return m
	m, _ := lookup_mime_type(strings.to_lower(ext, context.temp_allocator))
	return m
}

is_video :: proc(mimetype: string) -> bool {
	types := VIDEO_TYPES
	return contains(types[:], mimetype)
}

// A size dimension: value and unit (``nodes.parse_measure``).
@(private = "file")
Measure :: struct {
	name:  string,
	value: Num,
	unit:  string,
}

// ``image_size(node)`` with ``scaled_size_atts``: the size attributes.
@(private = "file")
image_size :: proc(t: ^Html, n: dt.Node, atts: ^[dynamic]Att) -> bool {
	doc := t.doc
	measures := make([dynamic]Measure, 0, 2, context.temp_allocator)
	for name in ([?]string{"width", "height"}) {
		v, ok := dt.get_attr(doc, n, name)
		if !ok do continue
		value, unit, valid := parse_measure(attr_text(doc, v))
		if !valid {
			t.err = "ValueError: no valid measure"
			return false
		}
		append(&measures, Measure{name, value, unit})
	}
	scale := 100.0
	if v, ok := dt.get_attr(doc, n, "scale"); ok {
		if len(measures) < 2 {
			// ``read_size_with_PIL``: its result (and the warning's text) depends on PIL
			dt.note_python_need_at(doc, n, .Pil, attr(doc, n, "uri"))
			warn_cannot_scale(t, n)
		}
		scale = attr_float(v)
	}
	factor := scale / 100
	style := make([dynamic]string, 0, 2, context.temp_allocator)
	for m in measures {
		value := as_f64(m.value) * factor
		if m.unit != "" {
			decl := cat(m.name, ": ", float_g(value), m.unit, ";")
			append(&style, decl)
		} else {
			append(atts, Att{m.name, int_str(py_round(value))})
		}
	}
	if len(style) > 0 {
		append(atts, Att{"style", strings.join(style[:], " ", context.temp_allocator)})
	}
	return true
}

// A number attribute as a float.
@(private = "file")
attr_float :: proc(v: dt.Attr_Value) -> f64 {
	#partial switch x in v {
	case int:
		return f64(x)
	case string:
		value, _, ok := parse_measure(x)
		if ok do return as_f64(value)
	}
	return 100
}

// ``read_size_with_PIL`` without PIL: the warning.
@(private = "file")
warn_cannot_scale :: proc(t: ^Html, n: dt.Node) {
	uri := attr(t.doc, n, "uri")
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "Cannot scale image!\n  Could not get size from \"")
	strings.write_string(&b, uri)
	strings.write_string(&b, "\":\n  Requires Python Imaging Library.")
	if is_video(guess_mime_type(uri)) {
		strings.write_string(&b, "\n  PIL cannot read video images.")
	}
	if !t.s.file_insertion_enabled {
		strings.write_string(&b, "\n  Reading external files disabled.")
	}
	msg := dt.warning(t.doc, strings.to_string(b), {base_node = n})
	append(&t.messages, msg)
}

html_visit_image :: proc(t: ^Html, n: dt.Node) -> Visit {
	doc := t.doc
	uri := attr(doc, n, "uri")
	mimetype := guess_mime_type(uri)
	atts := make([dynamic]Att, 0, 6, context.temp_allocator)
	if !image_size(t, n, &atts) do return .Skip_Node
	classes: []string
	if v, ok := dt.get_attr(doc, n, "align"); ok {
		classes = one_str(cat("align-", attr_text(doc, v)))
	}
	loading := "link" if is_video(mimetype) else t.image_loading
	if v, ok := dt.get_attr(doc, n, "loading"); ok do loading = attr_text(doc, v)
	element := ""
	switch loading {
	case "lazy":
		append(&atts, Att{"loading", "lazy"})
	case "embed":
		uri, element = embed_image(t, n, mimetype, &atts, classes)
	}
	p := dt.parent(doc, n)
	block :=
		!dt.is_a(doc, p, .TextElement) ||
		(dt.tag(doc, p) == .reference && !dt.is_a(doc, dt.parent(doc, p), .TextElement))
	suffix := "\n" if block else ""
	image_element(t, n, uri, mimetype, element, suffix, &atts, classes)
	if block do report_messages(t, n)
	return .Continue
}

// ``_embed_image``: a "data:" URI or the SVG element.
@(private = "file")
embed_image :: proc(
	t: ^Html,
	n: dt.Node,
	mimetype: string,
	atts: ^[dynamic]Att,
	classes: []string,
) -> (
	uri: string,
	element: string,
) {
	uri = attr(t.doc, n, "uri")
	path, err := uri2path(uri, t.s.output_path, t.s.root_prefix)
	data: []u8
	if err == "" {
		rerr: os.Error
		data, rerr = os.read_entire_file_from_path(path, context.temp_allocator)
		if rerr != nil do err = os_error_text(path, rerr)
	}
	if err != "" {
		msg := cat("Cannot embed image \"", uri, "\":\n  ", err)
		append(&t.messages, dt.error(t.doc, msg, {base_node = n}))
		return uri, ""
	}
	if mimetype == "image/svg+xml" do return uri, prepare_svg(t, string(data), n, atts[:], classes)
	encoded, _ := base64.encode(data, allocator = context.temp_allocator)
	return cat("data:", mimetype if mimetype != "" else "None", ";base64,", encoded), ""
}

// ``_image_element``.
@(private = "file")
image_element :: proc(
	t: ^Html,
	n: dt.Node,
	uri, mimetype, element, suffix: string,
	atts: ^[dynamic]Att,
	classes: []string,
) {
	doc := t.doc
	alt := attr(doc, n, "alt", attr(doc, n, "uri"))
	if is_video(mimetype) {
		append(atts, Att{"title", alt})
		if has_class(doc, n, "controls") {
			dt.list_remove(doc, n, dt.K_CLASSES, "controls")
			append(atts, Att{"controls", "controls"})
		}
		append(atts, Att{"src", uri})
		starttag(t, n, "video", suffix, classes = classes, atts = atts[:])
		begin(&t.body)
		w(&t.body, "<a href=\"")
		w(&t.body, attr(doc, n, "uri"))
		w(&t.body, "\">")
		w(&t.body, alt)
		w(&t.body, "</a>")
		w(&t.body, suffix)
		w(&t.body, "</video>")
		w(&t.body, suffix)
		return
	}
	if mimetype == "application/x-shockwave-flash" {
		append(atts, Att{"type", mimetype}, Att{"data", uri})
		starttag(t, n, "object", "", classes = classes, atts = atts[:])
		put_all(&t.body, alt, "</object>", suffix)
		return
	}
	if element != "" {
		put_all(&t.body, element, suffix)
		return
	}
	append(atts, Att{"alt", alt}, Att{"src", uri})
	emptytag(t, n, "img", suffix, classes = classes, atts = atts[:])
}

// --- mathematics ------------------------------------------------------------------------

// ``math_tags``: inline tag and block tag of the math output formats.
Math_Format :: enum u8 {
	Html,
	Latex,
	Mathjax,
	Mathml,
	Problematic,
}

@(private = "file")
MATH_FORMATS := [Math_Format][3]string {
	.Html        = {"html", "span", "div"},
	.Latex       = {"latex", "tt", "pre"},
	.Mathjax     = {"mathjax", "span", "div"},
	.Mathml      = {"mathml", "", "div"},
	.Problematic = {"problematic", "span", "pre"},
}

// The class values of ``math_tags``.  ``starttag`` appends the classes of
// the math nodes to these lists, as it does to docutils' class attribute.
init_math_classes :: proc(t: ^Html) {
	for &l in t.math_classes do l = make([dynamic]string, 0, 4, context.temp_allocator)
	append(&t.math_classes[.Html], "formula")
	append(&t.math_classes[.Latex], "math")
	append(&t.math_classes[.Mathjax], "math")
	append(&t.math_classes[.Problematic], "math", "problematic")
}

@(private = "file")
math_format :: proc(name: string) -> Math_Format {
	for f in Math_Format do if MATH_FORMATS[f][0] == name do return f
	return .Problematic
}

html_visit_math :: proc(t: ^Html, n: dt.Node) -> Visit {
	is_block := dt.tag(t.doc, n) == .math_block
	format := t.math_output
	code := texmath.uni2tex_translate(astext(t.doc, n), context.temp_allocator)
	switch format {
	case "html":
		code = math_to_html(t, code, is_block)
	case "latex":
		code = encoded(code)
	case "mathjax":
		code = math_to_mathjax(t, n, code, is_block)
	case "mathml":
		code, format = math_to_mathml(t, n, code, is_block)
	}
	if t.err != "" do return .Skip_Node
	f := math_format(format)
	tag := MATH_FORMATS[f][2] if is_block else MATH_FORMATS[f][1]
	suffix := "\n" if is_block else ""
	if tag != "" do starttag(t, n, tag, suffix, classes_store = &t.math_classes[f])
	put_all(&t.body, code, suffix)
	if tag != "" {
		begin(&t.body)
		w(&t.body, "</")
		w(&t.body, tag)
		wb(&t.body, '>')
		w(&t.body, suffix)
	}
	return .Skip_Children
}

html_depart_math_block :: proc(t: ^Html, n: dt.Node) {
	report_messages(t, n)
}

// ``wrap_math_code(code, as_block)``.
wrap_math_code :: proc(code: string, as_block: bool) -> string {
	if !as_block do return cat("$", code, "$")
	env := texmath.pick_math_environment(code)
	return cat("\\begin{", env, "}\n", code, "\n\\end{", env, "}")
}

@(private = "file")
math_to_mathjax :: proc(t: ^Html, n: dt.Node, code: string, is_block: bool) -> string {
	if chunks(&t.math_header) == 0 {
		if t.math_options != "" {
			t.mathjax_url = t.math_options
		} else {
			dt.warning(
				t.doc,
				"No MathJax URL specified, using local fallback (see config.html).",
				{base_node = n},
			)
		}
		if strings.index_byte(t.mathjax_url, '?') < 0 {
			t.mathjax_url = cat(t.mathjax_url, "?config=TeX-AMS_CHTML")
		}
		begin(&t.math_header)
		w(&t.math_header, "<script type=\"text/javascript\" src=\"")
		w(&t.math_header, t.mathjax_url)
		w(&t.math_header, "\"></script>\n")
	}
	wrapped := wrap_math_code(code, true) if is_block else cat("\\(", code, "\\)")
	return encoded(wrapped)
}
