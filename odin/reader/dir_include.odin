package reader

import "core:os"
import "core:strings"
import "core:unicode/utf8"

import dt "../doctree"
import rst "../rst"

// The ``include`` directive (``directives.misc.Include``) and the file
// access shared with ``raw``: ``adapt_path``, ``utils.relative_path`` and
// ``io.FileInput`` (UTF-8, universal newlines).

// The directory of the standard include files (``<isonum.txt>``); empty:
// the shim's copy next to the sources.
standard_include_path := ""

@(private = "file")
DEFAULT_INCLUDE_PATH :: #directory + "/../../python/docodin/shim/docutils/parsers/rst/include"

@(private = "file")
INCLUDE_OPTIONS := [?]Option_Spec {
	{"literal", flag},
	{"code", unchanged},
	{"encoding", encoding},
	{"parser", parser_name},
	{"tab-width", int_option},
	{"start-line", int_option},
	{"end-line", int_option},
	{"start-after", unchanged_required},
	{"end-before", unchanged_required},
	{"number-lines", none_or_int},
	{"class", class_option},
	{"name", unchanged},
}

INCLUDE := Directive_Spec {
	required_arguments        = 1,
	final_argument_whitespace = true,
	option_spec               = INCLUDE_OPTIONS[:],
	run                       = run_include,
}

// ``(start-line, end-line, start-after, end-before)`` of ``Include``.
@(private = "file")
Clip_Options :: struct {
	start_line, end_line:    Maybe(int),
	start_after, end_before: string,
}

@(private = "file")
run_include :: proc(c: ^Context, d: ^Directive) -> (Nodes, Failure) {
	s := &c.doc.settings
	if !s.file_insertion_enabled {
		return nil, directive_error(.WARNING, "\"", d.name, "\" directive disabled.")
	}
	tab_width := s.tab_width
	if v, ok := options_get(&d.options, "tab-width"); ok do tab_width = v.(int) or_else tab_width
	clips := clip_options(&d.options)
	source := include_source(c, d)
	options_set(&d.options, "source", source)
	text, err := read_file(c, d, source)
	if e, failed := err.?; failed do return nil, e
	text, err = clip_text(d, text, clips)
	if e, failed := err.?; failed do return nil, e
	if options_has(&d.options, "literal") do return as_literal_block(c, d, text, tab_width), nil
	if options_has(&d.options, "code") do return as_code_block(c, d, text, tab_width)
	if v, _ := options_get(&d.options, "parser"); v != nil {
		if _, is_none := v.(Opt_None); !is_none {
			msg := "\" directive:\nthe native reader includes reStructuredText only."
			return nil, directive_error(.SEVERE, "Problem with \"", d.name, msg)
		}
	}
	return nil, insert_into_input_lines(c, d, text, tab_width, clips)
}

// The path of the included file: ``<name>`` is a standard include file.
@(private = "file")
include_source :: proc(c: ^Context, d: ^Directive) -> string {
	p, _ := path(c, d.arguments[0])
	file_path := p.(string)
	root_prefix := c.doc.settings.root_prefix
	if has_prefix(file_path, "<") && has_suffix(file_path, ">") && len(file_path) >= 2 {
		file_path = concat("/", file_path[1:len(file_path) - 1])
		root_prefix = standard_include_path
		if root_prefix == "" && c.doc.settings.docutils_dir != "" {
			root_prefix = concat(c.doc.settings.docutils_dir, "/parsers/rst/include")
		}
		if root_prefix == "" do root_prefix = DEFAULT_INCLUDE_PATH
	}
	return adapt_path(c, file_path, root_prefix)
}

@(private = "file")
clip_options :: proc(opts: ^Options) -> (clips: Clip_Options) {
	if v, ok := options_get(opts, "start-line"); ok do clips.start_line = v.(int) or_else 0
	if v, ok := options_get(opts, "end-line"); ok do clips.end_line = v.(int) or_else 0
	clips.start_after = options_string(opts, "start-after")
	clips.end_before = options_string(opts, "end-before")
	return
}

// Clip the included text (``Include.read_file``).
@(private = "file")
clip_text :: proc(
	d: ^Directive,
	text_in: string,
	clips: Clip_Options,
) -> (string, Maybe(Directive_Error)) {
	text := text_in
	start, has_start := clips.start_line.?
	if (has_start && start != 0) || clips.end_line != nil {
		lines := dt.py_splitlines(text)
		n := len(lines)
		a := py_bound(start, n) if has_start else 0
		b := py_bound(clips.end_line.? or_else n, n)
		text = strings.join(lines[a:max(a, b)], "\n", context.temp_allocator)
	}
	if clips.start_after != "" {
		i := strings.index(text, clips.start_after)
		if i < 0 {
			msg := "\" directive:\nText not found."
			return "", directive_error(
				.SEVERE, "Problem with \"start-after\" option of \"", d.name, msg,
			)
		}
		text = text[i + len(clips.start_after):]
	}
	if clips.end_before != "" {
		i := strings.index(text, clips.end_before)
		if i < 0 {
			msg := "\" directive:\nText not found."
			return "", directive_error(
				.SEVERE, "Problem with \"end-before\" option of \"", d.name, msg,
			)
		}
		text = text[:i]
	}
	return text, nil
}

// A Python slice bound.
@(private = "file")
py_bound :: proc(i, n: int) -> int {
	j := i < 0 ? i + n : i
	return clamp(j, 0, n)
}

@(private = "file")
as_literal_block :: proc(
	c: ^Context,
	d: ^Directive,
	text_in: string,
	tab_width: int,
) -> [dynamic]dt.Node {
	doc := c.doc
	source := options_string(&d.options, "source")
	text := expandtabs(text_in, tab_width) if tab_width >= 0 else text_in
	node := dt.new_element(doc, .literal_block, "")
	dt.set_attr(doc, node, dt.K_SOURCE, source)
	for cl in options_list(&d.options, "class") do dt.list_append(doc, node, dt.K_CLASSES, cl)
	dt.set_source(doc, node, source)
	start := 0
	if v, ok := options_get(&d.options, "start-line"); ok do start = v.(int) or_else 0
	dt.set_line(doc, node, start + 1)
	add_name(c, d, node)
	if v, ok := options_get(&d.options, "number-lines"); ok {
		firstline := v.(int) or_else 1
		if firstline == 0 do firstline = 1
		text = strings.trim_suffix(text, "\n")
		lastline := firstline + len(dt.py_splitlines(text))
		add_numbered_lines(c, node, text, firstline, lastline, true)
	} else {
		dt.append_child(doc, node, dt.new_text(doc, text))
	}
	return result_of(c, node)
}

@(private = "file")
as_code_block :: proc(
	c: ^Context,
	d: ^Directive,
	text_in: string,
	tab_width: int,
) -> (
	[dynamic]dt.Node,
	Maybe(Directive_Error),
) {
	text := expandtabs(text_in, tab_width) if tab_width >= 0 else text_in
	code, _ := options_pop(&d.options, "code")
	args := make([]string, 1, c.allocator)
	args[0] = code.(string) or_else ""
	lines := []string{strings.trim_suffix(text, "\n")}
	codeblock := d^
	codeblock.arguments = args
	codeblock.content = sl_make(lines, c.source, c.allocator)
	return run_code_block(c, &codeblock)
}

@(private = "file")
insert_into_input_lines :: proc(
	c: ^Context,
	d: ^Directive,
	text: string,
	tab_width: int,
	clips: Clip_Options,
) -> Maybe(Directive_Error) {
	source := options_string(&d.options, "source")
	textlines := rst.split_lines(text, tab_width, c.allocator)
	limit := c.doc.settings.line_length_limit
	for line, i in textlines {
		if cp_len(line) <= limit do continue
		start := 0
		if v, ok := options_get(&d.options, "start-line"); ok do start = v.(int) or_else 0
		line_no := itoa(i + 1 + start)
		return directive_error(
			.WARNING, "\"", source, "\": line ", line_no, " exceeds the line-length-limit.",
		)
	}
	clip_key := clip_repr(clips)
	if len(c.include_log) == 0 { 	// new document, initialize with document source
		current := relative_path(c, c.doc.current_source.? or_else "")
		append(&c.include_log, Include_Entry{current, {"None", "None", "''", "''"}})
	}
	for e in c.include_log {
		if e.path != source || e.clips != clip_key do continue
		b := strings.builder_make(c.allocator)
		strings.write_string(&b, source)
		#reverse for entry in c.include_log {
			strings.write_string(&b, "\n> ")
			strings.write_string(&b, entry.path)
		}
		msg := "\" directive:\n"
		return directive_error(
			.WARNING, "circular inclusion in \"", d.name, msg, strings.to_string(b),
		)
	}
	append(&c.include_log, Include_Entry{dt.clone(c.doc, source), clip_key})
	lines := make([dynamic]string, 0, len(textlines) + 2, c.allocator)
	append(&lines, ..textlines)
	append(
		&lines, "", concat(".. end of inclusion from \"", source, "\"", allocator = c.allocator),
	)
	insert_input(c, d.sm, lines[:], source)
	return nil
}

// The clip options as comparable values (their ``repr``).
@(private = "file")
clip_repr :: proc(clips: Clip_Options) -> [4]string {
	int_repr :: proc(v: Maybe(int)) -> string {
		i, ok := v.?
		return itoa(i) if ok else "None"
	}
	return {
		int_repr(clips.start_line),
		int_repr(clips.end_line),
		py_repr(clips.start_after),
		py_repr(clips.end_before),
	}
}

// ``adapt_path(path, document.current_source, root_prefix)``.
adapt_path :: proc(c: ^Context, file_path: string, root_prefix := "") -> string {
	base: string
	p := file_path
	if root_prefix != "" && has_prefix(p, "/") {
		base = root_prefix
		p = p[1:]
	} else {
		base = path_parent(c.doc.current_source.? or_else "")
	}
	joined := p if has_prefix(p, "/") else concat(base, "/", p)
	return relative_path(c, joined)
}

// ``Path(p).parent``.
@(private = "file")
path_parent :: proc(p: string) -> string {
	s := strings.trim_right(p, "/")
	if s == "" do return "/" if has_prefix(p, "/") else "."
	i := strings.last_index_byte(s, '/')
	if i < 0 do return "."
	if i == 0 do return "/"
	return strings.trim_right(s[:i], "/")
}

// ``utils.relative_path(None, target)``: ``target`` relative to the
// working directory (absolute if they share no prefix).
relative_path :: proc(c: ^Context, target: string) -> string {
	cwd, _ := os.get_working_directory(c.allocator)
	source_parts := strings.split(abspath(concat(cwd, "/dummy_file")), "/", c.allocator)
	target_parts := strings.split(abspath(target, cwd), "/", c.allocator)
	if len(source_parts) < 2 || len(target_parts) < 2 || source_parts[1] != target_parts[1] {
		return strings.join(target_parts, "/", c.allocator)
	}
	k := 0
	common := min(len(source_parts), len(target_parts))
	for k < common && source_parts[k] == target_parts[k] do k += 1
	parts := make([dynamic]string, c.allocator)
	for _ in 0 ..< len(source_parts) - k - 1 do append(&parts, "..")
	append(&parts, ..target_parts[k:])
	return strings.join(parts[:], "/", c.allocator)
}

// ``os.path.abspath``: ``normpath(join(cwd, p))``.
@(private = "file")
abspath :: proc(p: string, cwd := "") -> string {
	full := p if has_prefix(p, "/") else concat(cwd, "/", p)
	out := make([dynamic]string, context.temp_allocator)
	for part in strings.split(full, "/", context.temp_allocator) {
		switch part {
		case "", ".":
		case "..":
			if len(out) > 0 do pop(&out)
		case:
			append(&out, part)
		}
	}
	return concat("/", strings.join(out[:], "/", context.temp_allocator))
}

// ``io.FileInput(source_path=path).read()``: the text, or the
// ``DirectiveError`` docutils raises.  ``raw``: the ``raw`` directive's
// message texts.
read_file :: proc(c: ^Context, d: ^Directive, file_path: string) -> (string, Failure) {
	errno, strerror := 0, ""
	switch {
	case !os.exists(file_path):
		errno, strerror = 2, "No such file or directory"
	case os.is_dir(file_path):
		errno, strerror = 21, "Is a directory"
	}
	data: []u8
	if errno == 0 {
		err: os.Error
		data, err = os.read_entire_file(file_path, c.allocator)
		if err != nil do errno, strerror = 13, "Permission denied"
	}
	if errno != 0 {
		detail := concat(
			"InputError: [Errno ", itoa(errno), "] ", strerror, ": ", py_repr(file_path),
		)
		return "", directive_error(
			.SEVERE, "Problems with \"", d.name, "\" directive path:\n", detail, ".",
		)
	}
	encoding := options_string(&d.options, "encoding")
	if encoding == "" do encoding = c.doc.settings.input_encoding
	text, detail := decode(c, data, encoding)
	if detail != "" {
		return "", directive_error(.SEVERE, "Problem with \"", d.name, "\" directive:\n", detail)
	}
	return universal_newlines(c, text), nil
}

// Decode ``data`` (``str(data, encoding)``): the text, or the text of the
// ``UnicodeDecodeError``.
@(private = "file")
decode :: proc(c: ^Context, data: []u8, encoding: string) -> (text: string, err: string) {
	switch normalize_encoding(encoding) {
	case "latin-1":
		b := strings.builder_make(0, len(data) * 2, c.allocator)
		for ch in data do strings.write_rune(&b, rune(ch))
		return strings.to_string(b), ""
	case "ascii":
		for ch, i in data {
			if ch < 0x80 do continue
			return "", concat(
				"UnicodeDecodeError: 'ascii' codec can't decode byte 0x", hex2(ch),
				" in position ", itoa(i), ": ordinal not in range(128)",
			)
		}
		return string(data), ""
	case "utf-8-sig":
		s := string(data)
		return decode_utf8(strings.trim_prefix(s, "\uFEFF"), "utf-8-sig")
	}
	return decode_utf8(string(data), "utf-8")
}

@(private = "file")
decode_utf8 :: proc(s: string, codec: string) -> (string, string) {
	bad := invalid_utf8_at(s)
	if bad < 0 do return s, ""
	return "", concat(
		"UnicodeDecodeError: '", codec, "' codec can't decode byte 0x", hex2(s[bad]),
		" in position ", itoa(bad), ": ", utf8_error_reason(s, bad),
	)
}

// The reason CPython's UTF-8 decoder gives for the invalid sequence at ``i``.
@(private = "file")
utf8_error_reason :: proc(s: string, i: int) -> string {
	lead := s[i]
	if lead < 0xC2 || lead > 0xF4 do return "invalid start byte"
	if i + 1 >= len(s) do return "unexpected end of data"
	return "invalid continuation byte"
}

// The byte offset of the first invalid UTF-8 sequence, -1 if none.
@(private = "file")
invalid_utf8_at :: proc(s: string) -> int {
	for i := 0; i < len(s); {
		r, w := utf8.decode_rune_in_string(s[i:])
		if r == utf8.RUNE_ERROR && w <= 1 do return i
		i += w
	}
	return -1
}

@(private = "file")
hex2 :: proc(b: u8) -> string {
	HEX := "0123456789abcdef"
	buf := make([]u8, 2, context.temp_allocator)
	buf[0], buf[1] = HEX[b >> 4], HEX[b & 0xF]
	return string(buf)
}

// Python's text mode: "\r\n" and "\r" become "\n".
@(private = "file")
universal_newlines :: proc(c: ^Context, s: string) -> string {
	if strings.index_byte(s, '\r') < 0 do return s
	b := strings.builder_make(0, len(s), c.allocator)
	for i := 0; i < len(s); i += 1 {
		if s[i] != '\r' {
			strings.write_byte(&b, s[i])
			continue
		}
		strings.write_byte(&b, '\n')
		if i + 1 < len(s) && s[i + 1] == '\n' do i += 1
	}
	return strings.to_string(b)
}

// Python ``str.expandtabs(tabsize)``.
expandtabs :: proc(s: string, tabsize: int) -> string {
	if strings.index_byte(s, '\t') < 0 do return s
	b := strings.builder_make(context.temp_allocator)
	col := 0
	for r in s {
		switch r {
		case '\t':
			if tabsize > 0 {
				n := tabsize - col % tabsize
				for _ in 0 ..< n do strings.write_byte(&b, ' ')
				col += n
			}
		case '\n', '\r':
			strings.write_rune(&b, r)
			col = 0
		case:
			strings.write_rune(&b, r)
			col += 1
		}
	}
	return strings.to_string(b)
}

// ``urlopen(url).read()`` decoded (``io.StringInput``) for ``file:`` URLs;
// the native reader fetches no other URLs.  On failure: the exception
// class and ``str(error)``.
read_url :: proc(c: ^Context, d: ^Directive, url: string) -> (text: string, class, err: string) {
	// ``urllib.request.Request``: a URL without a scheme is a ``ValueError``
	colon := strings.index_byte(url, ':')
	if colon <= 0 || strings.contains_rune(url[:colon], '/') {
		return "", "ValueError", concat("unknown url type: ", py_repr(url))
	}
	file_path, local := file_url_path(c, url)
	if !local do return "", "URLError", "<urlopen error the native reader fetches file: URLs only>"
	switch {
	case !os.exists(file_path):
		return "", "URLError", concat(
			"<urlopen error [Errno 2] No such file or directory: ", py_repr(file_path), ">",
		)
	case os.is_dir(file_path):
		return "", "IsADirectoryError", concat("[Errno 21] Is a directory: ", py_repr(file_path))
	}
	data, read_err := os.read_entire_file(file_path, c.allocator)
	if read_err != nil {
		return "", "PermissionError", concat("[Errno 13] Permission denied: ", py_repr(file_path))
	}
	encoding := options_string(&d.options, "encoding")
	if encoding == "" do encoding = c.doc.settings.input_encoding
	decoded, detail := decode(c, data, encoding)
	if detail != "" do return "", "UnicodeError", detail
	return decoded, "", ""
}

// The local path of a ``file:`` URL (``url2pathname`` of its path).
@(private = "file")
file_url_path :: proc(c: ^Context, url: string) -> (string, bool) {
	if !has_prefix(dt.py_lower(url, c.allocator), "file:") do return "", false
	rest := url[5:]
	if has_prefix(rest, "//") {
		rest = rest[2:]
		slash := strings.index_byte(rest, '/')
		host := rest if slash < 0 else rest[:slash]
		if host != "" && dt.py_lower(host, c.allocator) != "localhost" do return "", false
		rest = rest[len(host):]
	}
	return percent_decode(c, rest), true
}

@(private = "file")
percent_decode :: proc(c: ^Context, s: string) -> string {
	if strings.index_byte(s, '%') < 0 do return s
	b := strings.builder_make(0, len(s), c.allocator)
	hexval :: proc(ch: u8) -> int {
		switch ch {
		case '0' ..= '9': return int(ch - '0')
		case 'a' ..= 'f': return int(ch - 'a') + 10
		case 'A' ..= 'F': return int(ch - 'A') + 10
		}
		return -1
	}
	for i := 0; i < len(s); i += 1 {
		if s[i] == '%' && i + 2 < len(s) + 0 && hexval(s[i + 1]) >= 0 && hexval(s[i + 2]) >= 0 {
			strings.write_byte(&b, u8(hexval(s[i + 1]) * 16 + hexval(s[i + 2])))
			i += 2
			continue
		}
		strings.write_byte(&b, s[i])
	}
	return strings.to_string(b)
}
