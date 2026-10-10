package writers

import "core:os"
import "core:strings"

import dt "../doctree"

// The writers' data files (templates, stylesheets, LaTeX packages), embedded
// from the shim's writer directories, and the path helpers of
// ``docutils.utils`` and ``DoctreeTranslator.uri2path``.

SHIM_WRITERS :: "../../python/docodin/shim/docutils/writers/"

Writer_Dir :: enum u8 {
	Html5, // writers/html5_polyglot
	Latex, // writers/latex2e
}

WRITER_DIR_NAMES := [Writer_Dir]string {
	.Html5 = "writers/html5_polyglot",
	.Latex = "writers/latex2e",
}

// The writer directory of the native pipeline (``stylesheet_dirs``).
NATIVE_DIR_PREFIX :: "<docodin>/"

Data_File :: struct {
	dir:     Writer_Dir,
	name:    string,
	content: string,
}

@(rodata)
DATA_FILES := [?]Data_File {
	{.Html5, "minimal.css", #load(SHIM_WRITERS + "html5_polyglot/minimal.css", string)},
	{.Html5, "plain.css", #load(SHIM_WRITERS + "html5_polyglot/plain.css", string)},
	{.Html5, "math.css", #load(SHIM_WRITERS + "html5_polyglot/math.css", string)},
	{.Html5, "responsive.css", #load(SHIM_WRITERS + "html5_polyglot/responsive.css", string)},
	{.Html5, "tuftig.css", #load(SHIM_WRITERS + "html5_polyglot/tuftig.css", string)},
	{
		.Html5,
		"italic-field-names.css",
		#load(SHIM_WRITERS + "html5_polyglot/italic-field-names.css", string),
	},
	{.Html5, "template.txt", #load(SHIM_WRITERS + "html5_polyglot/template.txt", string)},
	{.Latex, "default.tex", #load(SHIM_WRITERS + "latex2e/default.tex", string)},
	{.Latex, "titlepage.tex", #load(SHIM_WRITERS + "latex2e/titlepage.tex", string)},
	{.Latex, "titlingpage.tex", #load(SHIM_WRITERS + "latex2e/titlingpage.tex", string)},
	{.Latex, "xelatex.tex", #load(SHIM_WRITERS + "latex2e/xelatex.tex", string)},
	{.Latex, "docutils.sty", #load(SHIM_WRITERS + "latex2e/docutils.sty", string)},
}

// The embedded file ``name`` of a writer directory.
data_file :: proc(dir: Writer_Dir, name: string) -> (string, bool) {
	for f in DATA_FILES {
		if f.dir == dir && f.name == name do return f.content, true
	}
	return "", false
}

// Is ``dir`` a docutils (or native) writer directory of kind ``kind``?
is_writer_dir :: proc(dir: string, kind: Writer_Dir) -> bool {
	d := strings.trim_right(dir, "/")
	return strings.has_suffix(d, WRITER_DIR_NAMES[kind])
}

@(private = "file")
embedded_path :: proc(path: string) -> (string, bool) {
	slash := strings.last_index_byte(path, '/')
	if slash < 0 do return "", false
	for kind in Writer_Dir {
		if is_writer_dir(path[:slash], kind) {
			if s, ok := data_file(kind, path[slash + 1:]); ok do return s, true
		}
	}
	return "", false
}

// Does ``path`` name a file (an embedded data file or a file on disk)?
file_exists :: proc(path: string) -> bool {
	if _, ok := embedded_path(path); ok do return true
	return os.exists(path)
}

// The text of ``path`` (``Path(path).read_text()``): an embedded data file
// or a file on disk.  On failure, ``err`` is the Python ``OSError`` text.
read_text :: proc(path: string, allocator := context.allocator) -> (text: string, err: string) {
	if s, ok := embedded_path(path); ok do return s, ""
	data, rerr := os.read_entire_file_from_path(path, allocator)
	if rerr != nil do return "", os_error_text(path, rerr)
	return string(data), ""
}

// The path to link to for ``path``: an embedded data file that is not on
// disk (the native tools run without docutils' data directory) is linked by
// its name, as ``find_file_in_dirs`` keeps a file it does not find.
link_path :: proc(path: string) -> string {
	if _, ok := embedded_path(path); ok && !os.exists(path) do return path_name(path)
	return path
}

// ``str(OSError)`` of a failed ``open(path)``.
os_error_text :: proc(path: string, err: os.Error) -> string {
	b := strings.builder_make(context.temp_allocator)
	switch {
	case os.is_directory(path):
		strings.write_string(&b, "[Errno 21] Is a directory: ")
	case os.exists(path):
		strings.write_string(&b, "[Errno 13] Permission denied: ")
	case:
		strings.write_string(&b, "[Errno 2] No such file or directory: ")
	}
	write_py_str_repr(&b, path)
	return strings.to_string(b)
}

// ``repr(s)`` of a Python ``str``.
write_py_str_repr :: proc(b: ^strings.Builder, s: string) {
	dt.write_py_repr(b, s)
}

// --- paths -------------------------------------------------------------------------------

is_absolute :: proc(path: string) -> bool {
	return strings.has_prefix(path, "/")
}

// ``PurePosixPath(*parts).as_posix()``: joined, without empty and "."
// components; "." for an empty path.
pure_path :: proc(parts: ..string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	for part in parts {
		if is_absolute(part) {
			strings.builder_reset(&b)
			strings.write_byte(&b, '/')
		}
		rest := part
		for comp in strings.split_iterator(&rest, "/") {
			if comp == "" || comp == "." do continue
			n := strings.builder_len(b)
			if n > 0 && b.buf[n - 1] != '/' do strings.write_byte(&b, '/')
			strings.write_string(&b, comp)
		}
	}
	if strings.builder_len(b) == 0 do return "."
	return strings.to_string(b)
}

// Final component, stem and suffix of a path (``PurePath.name/stem/suffix``).
path_name :: proc(path: string) -> string {
	p := strings.trim_right(path, "/")
	return p[strings.last_index_byte(p, '/') + 1:]
}

path_suffix :: proc(path: string) -> string {
	name := path_name(path)
	i := strings.last_index_byte(name, '.')
	return name[i:] if i > 0 else ""
}

path_stem :: proc(path: string) -> string {
	name := path_name(path)
	return name[:len(name) - len(path_suffix(path))]
}

// ``PurePath.parent``.
path_parent :: proc(path: string) -> string {
	p := pure_path(path)
	i := strings.last_index_byte(p, '/')
	switch {
	case i < 0:
		return "."
	case i == 0:
		return "/"
	}
	return p[:i]
}

// ``os.path.abspath``: absolute and normalized (".." resolved lexically).
abspath :: proc(path: string, allocator := context.temp_allocator) -> string {
	full := path
	if !is_absolute(path) {
		cwd, _ := os.get_working_directory(context.temp_allocator)
		full = cat(cwd, "/", path)
	}
	comps := make([dynamic]string, 0, 16, context.temp_allocator)
	rest := full
	for comp in strings.split_iterator(&rest, "/") {
		switch comp {
		case "", ".":
		case "..":
			if len(comps) > 0 do pop(&comps)
		case:
			append(&comps, comp)
		}
	}
	joined := strings.join(comps[:], "/", context.temp_allocator)
	return strings.concatenate({"/", joined}, allocator)
}

// ``utils.relative_path(source, target)``: a path to ``target`` relative
// to the file ``source`` ("<cwd>/dummy_file" for "").
relative_path :: proc(source, target: string, allocator := context.temp_allocator) -> string {
	start := abspath(source if source != "" else "dummy_file")
	src := strings.split(start, "/", context.temp_allocator)
	tgt := strings.split(abspath(target), "/", context.temp_allocator)
	if len(src) < 2 || len(tgt) < 2 || src[1] != tgt[1] {
		return strings.join(tgt, "/", allocator)
	}
	i := 0
	for i < len(src) && i < len(tgt) && src[i] == tgt[i] do i += 1
	parts := make([dynamic]string, 0, 16, context.temp_allocator)
	for _ in 0 ..< len(src) - i - 1 do append(&parts, "..")
	append(&parts, ..tgt[i:])
	return strings.join(parts[:], "/", allocator)
}

// ``utils.find_file_in_dirs(path, dirs)``.
find_file_in_dirs :: proc(path: string, dirs: []string) -> string {
	if is_absolute(path) do return pure_path(path)
	for d in dirs {
		f := pure_path(expanduser(d), path)
		if file_exists(f) do return f
	}
	return pure_path(path)
}

@(private = "file")
expanduser :: proc(path: string) -> string {
	if path != "~" && !strings.has_prefix(path, "~/") do return path
	home := os.get_env("HOME", context.temp_allocator)
	if home == "" do return path
	return cat(home, path[1:])
}

// ``DoctreeTranslator.uri2path(uri, output_path)``: the filesystem path
// (``as_posix``) of a URI reference; ``err`` is the ``ValueError`` text.
uri2path :: proc(uri, output_path, root_prefix: string) -> (path: string, err: string) {
	if strings.has_prefix(uri, "file:") do return path_from_file_uri(uri)
	u := strings.trim_left(uri, "\x00\x01\x02\x03\x04\x05\x06\x07\x08\t\n\v\f\r ")
	if url_scheme(u) != "" {
		return "", strings.concatenate({"Cannot get file path corresponding to ", uri, "."})
	}
	p := url_unquote(url_path(u))
	if root_prefix != "" && strings.has_prefix(p, "/") {
		return pure_path(root_prefix, p[1:]), ""
	}
	if output_path != "" && !is_absolute(p) {
		dest_dir := abspath(path_parent(output_path))
		return pure_path(relative_path("", pure_path(dest_dir, p))), ""
	}
	return pure_path(p), ""
}

@(private = "file")
path_from_file_uri :: proc(uri: string) -> (string, string) {
	p := uri[5:]
	switch {
	case strings.has_prefix(p, "///"):
		p = p[2:]
	case strings.has_prefix(p, "//localhost/"):
		p = p[11:]
	}
	p = url_unquote(p)
	if !is_absolute(p) {
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, "URI is not absolute: ")
		write_py_str_repr(&b, uri)
		return "", strings.to_string(b)
	}
	return pure_path(p), ""
}

// The scheme of ``urllib.parse.urlsplit(url)`` ("" if there is none).
url_scheme :: proc(url: string) -> string {
	i := strings.index_byte(url, ':')
	if i <= 0 do return ""
	c0 := url[0]
	if !((c0 >= 'a' && c0 <= 'z') || (c0 >= 'A' && c0 <= 'Z')) do return ""
	for c in transmute([]u8)url[:i] {
		ok := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
		if !ok && c != '+' && c != '-' && c != '.' do return ""
	}
	return url[:i]
}

// The path of ``urlsplit(url)`` (no scheme): without the netloc, query and
// fragment; tabs and newlines removed.
@(private = "file")
url_path :: proc(url: string) -> string {
	u, _ := strings.remove_all(url, "\t", context.temp_allocator)
	u, _ = strings.remove_all(u, "\n", context.temp_allocator)
	u, _ = strings.remove_all(u, "\r", context.temp_allocator)
	if strings.has_prefix(u, "//") {
		end := strings.index_any(u[2:], "/?#")
		u = u[2 + end:] if end >= 0 else ""
	}
	if end := strings.index_any(u, "?#"); end >= 0 do u = u[:end]
	return u
}

// ``urllib.parse.unquote``.
url_unquote :: proc(s: string) -> string {
	if strings.index_byte(s, '%') < 0 do return s
	out := make([dynamic]u8, 0, len(s), context.temp_allocator)
	for i := 0; i < len(s); i += 1 {
		if s[i] == '%' && i + 2 < len(s) && is_hex(s[i + 1]) && is_hex(s[i + 2]) {
			append(&out, hex_value(s[i + 1]) << 4 | hex_value(s[i + 2]))
			i += 2
			continue
		}
		append(&out, s[i])
	}
	return string(out[:])
}

is_hex :: proc(c: u8) -> bool {
	return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
}

hex_value :: proc(c: u8) -> u8 {
	switch c {
	case '0' ..= '9':
		return c - '0'
	case 'a' ..= 'f':
		return c - 'a' + 10
	}
	return c - 'A' + 10
}
