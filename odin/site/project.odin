package site

import "base:runtime"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

import "../check"
import pb "../publish"

// A Sphinx project: its configuration and its source documents, found
// as Sphinx finds them (every ``.rst`` file under the source directory but
// those matching ``exclude_patterns``, ``templates_path`` and
// ``html_static_path``, hidden files and the output directory).
//
// Documents are ``Doc_Id`` handles into ``Site.docs`` (``docs[0]`` is the
// null slot).  Everything lives in the site's arena.

Doc_Id :: distinct u32

NO_DOC :: Doc_Id(0)

SOURCE_SUFFIX :: ".rst"

Source_Doc :: struct {
	name:   string, // the docname: the path relative to the source directory, no suffix
	path:   string, // the source file
	text:   string, // decoded, with universal newlines
	orphan: bool, // ``:orphan:`` metadata
}

Site :: struct {
	arena:     virtual.Arena,
	allocator: runtime.Allocator,
	srcdir:    string, // absolute
	outdir:    string, // absolute ("" until a build names it)
	conf:      Conf,
	docs:      [dynamic]Source_Doc,
	by_name:   map[string]Doc_Id,
	root:      Doc_Id, // ``root_doc``
	warnings:  [dynamic]Warning,
}

// Open the project in ``dir``: read ``conf.py`` and find the documents.
// ``outdir`` (may be "") is excluded from the search.
open_site :: proc(dir, outdir: string) -> (s: ^Site, err: string) {
	s = new(Site)
	if virtual.arena_init_growing(&s.arena) != nil do panic("site: cannot reserve arena")
	s.allocator = virtual.arena_allocator(&s.arena)
	context.allocator = s.allocator
	abs, _ := filepath.abs(dir)
	s.srcdir = abs
	if outdir != "" do s.outdir, _ = filepath.abs(outdir)
	s.docs = make([dynamic]Source_Doc)
	append(&s.docs, Source_Doc{})
	s.by_name = make(map[string]Doc_Id)
	s.warnings = make([dynamic]Warning)
	conf_path := join(s.srcdir, "conf.py")
	data, rerr := os.read_entire_file_from_path(conf_path, s.allocator)
	if rerr != nil do return s, strings.concatenate({"There is no conf.py in ", s.srcdir, "."})
	s.conf = parse_conf(string(data))
	find_documents(s)
	s.root = s.by_name[s.conf.root_doc]
	if s.root == NO_DOC {
		return s, strings.concatenate({"The root document ", s.conf.root_doc, SOURCE_SUFFIX,
			" is missing from ", s.srcdir, "."})
	}
	return s, ""
}

destroy_site :: proc(s: ^Site) {
	virtual.arena_destroy(&s.arena)
	free(s)
}

@(private = "file")
find_documents :: proc(s: ^Site) {
	names := make([dynamic]string)
	walk_sources(s, "", &names)
	slice.sort(names[:])
	for name in names {
		path := join(s.srcdir, strings.concatenate({name, SOURCE_SUFFIX}))
		text, ok := read_source(s, path)
		if !ok do continue
		doc := Source_Doc {
			name   = name,
			path   = path,
			text   = text,
			orphan = is_orphan(text),
		}
		append(&s.docs, doc)
		s.by_name[name] = Doc_Id(len(s.docs) - 1)
	}
}

// The decoded text of a source document.  A document that cannot be read
// or is not UTF-8 is a SEVERE problem, which stops the build: publishing
// its bytes as they are would write invalid pages.
@(private = "file")
read_source :: proc(s: ^Site, path: string) -> (text: string, ok: bool) {
	data, err := os.read_entire_file_from_path(path, s.allocator)
	if err != nil {
		warn_at(s, NO_DOC, path, 0, strings.concatenate({"Cannot read the document: ",
			os.error_string(err), "."}), 4)
		return "", false
	}
	decoded, derr := pb.decode(data, "utf-8-sig", "strict")
	if derr != "" {
		bad := check.invalid_utf8_offset(data)
		line := 1 + strings.count(string(data[:max(bad, 0)]), "\n")
		warn_at(s, NO_DOC, path, line, strings.concatenate({"Cannot decode the document: ",
			strings.trim_prefix(derr, "UnicodeDecodeError: "), "."}), 4)
		return "", false
	}
	return pb.universal_newlines(decoded), true
}

// The docnames under ``rel`` (a directory relative to the source).
@(private = "file")
walk_sources :: proc(s: ^Site, rel: string, names: ^[dynamic]string) {
	dir := join(s.srcdir, rel) if rel != "" else s.srcdir
	entries, err := os.read_all_directory_by_path(dir, s.allocator)
	if err != nil do return
	for fi in entries {
		if strings.has_prefix(fi.name, ".") do continue
		path := join(rel, fi.name) if rel != "" else fi.name
		if excluded(s, path) do continue
		if fi.type == .Directory {
			if s.outdir != "" && join(s.srcdir, path) == s.outdir do continue
			walk_sources(s, path, names)
		} else if strings.has_suffix(fi.name, SOURCE_SUFFIX) {
			append(names, path[:len(path) - len(SOURCE_SUFFIX)])
		}
	}
}

// A path (relative to the source directory, "/"-separated) Sphinx does
// not read.
excluded :: proc(s: ^Site, path: string) -> bool {
	for p in s.conf.exclude_patterns do if glob_match(p, path) do return true
	for p in s.conf.templates_path do if clean_rel(p) == path do return true
	for p in s.conf.html_static_path do if clean_rel(p) == path do return true
	return false
}

@(private = "file")
clean_rel :: proc(p: string) -> string {
	c, _ := filepath.clean(p, context.temp_allocator)
	return c
}

// ``:orphan:`` in the field list at the top of the document.
@(private = "file")
is_orphan :: proc(text: string) -> bool {
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		t := strings.trim_space(line)
		if t == "" do continue
		if !strings.has_prefix(t, ":") do return false
		if strings.has_prefix(t, ":orphan:") do return true
	}
	return false
}

// --- names and paths -----------------------------------------------------------------------

join :: proc(a, b: string) -> string {
	if a == "" do return b
	p, _ := filepath.join({a, b})
	return p
}

// The directory part of a docname ("" at the top).
doc_dir :: proc(name: string) -> string {
	i := strings.last_index_byte(name, '/')
	return name[:i] if i >= 0 else ""
}

// ``docname_join``: a docname given in ``base`` (relative to its
// directory, or absolute from the source directory with a leading "/"),
// normalized.
docname_join :: proc(base, target: string) -> string {
	t := target
	if strings.has_prefix(t, "/") do return normalize_docname(t[1:])
	dir := doc_dir(base)
	return normalize_docname(dir == "" ? t : strings.concatenate({dir, "/", t}))
}

// Resolve "." and ".." segments of a "/"-separated path.
normalize_docname :: proc(name: string) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	rest := name
	for seg in strings.split_iterator(&rest, "/") {
		switch seg {
		case "", ".":
		case "..":
			if len(parts) > 0 do pop(&parts)
		case:
			append(&parts, seg)
		}
	}
	return strings.join(parts[:], "/")
}

// The URL of page ``to`` from page ``from`` (both docnames; ".html"
// pages in a tree like the sources').
relative_url :: proc(from, to: string, suffix := ".html") -> string {
	return strings.concatenate({relative_path(from, to), suffix})
}

// ``to`` (a path relative to the output root) as seen from page ``from``.
relative_path :: proc(from, to: string) -> string {
	// skip the directories the two paths share
	common := 0
	for i := 0; i < len(from) && i < len(to) && from[i] == to[i]; i += 1 {
		if from[i] == '/' do common = i + 1
	}
	b := strings.builder_make()
	depth := strings.count(from[common:], "/")
	for _ in 0 ..< depth do strings.write_string(&b, "../")
	strings.write_string(&b, to[common:])
	return strings.to_string(b)
}

// --- glob patterns ---------------------------------------------------------------------------

// ``sphinx.util.matching``: ``*`` and ``?`` do not match "/", ``**``
// matches anything, ``[...]`` a character class.  A pattern also matches
// every path under a matching directory.
glob_match :: proc(pattern, path: string) -> bool {
	if match_here(pattern, path) do return true
	for i := 0; i < len(path); i += 1 {
		if path[i] == '/' && match_here(pattern, path[:i]) do return true
	}
	return false
}

@(private = "file")
match_here :: proc(p, s: string) -> bool {
	if p == "" do return s == ""
	switch p[0] {
	case '*':
		return match_star(p, s)
	case '?':
		return s != "" && s[0] != '/' && match_here(p[1:], s[1:])
	case '[':
		if end := strings.index_byte(p[1:], ']'); end > 0 && s != "" {
			return match_class(p[1:end + 1], s[0]) && match_here(p[end + 2:], s[1:])
		}
	}
	return s != "" && s[0] == p[0] && match_here(p[1:], s[1:])
}

// ``*`` (within a path segment) or ``**`` (across segments; "**/" also
// matches no directory) at the start of ``p``.
@(private = "file")
match_star :: proc(p, s: string) -> bool {
	if len(p) > 1 && p[1] == '*' {
		if len(p) > 2 && p[2] == '/' && match_here(p[3:], s) do return true
		for i in 0 ..= len(s) do if match_here(p[2:], s[i:]) do return true
		return false
	}
	for i in 0 ..= len(s) {
		if match_here(p[1:], s[i:]) do return true
		if i < len(s) && s[i] == '/' do return false
	}
	return false
}

@(private = "file")
match_class :: proc(class: string, c: u8) -> bool {
	negate := class != "" && (class[0] == '!' || class[0] == '^')
	body := class[1:] if negate else class
	found := false
	for i := 0; i < len(body); i += 1 {
		if i + 2 < len(body) && body[i + 1] == '-' {
			if body[i] <= c && c <= body[i + 2] do found = true
			i += 2
		} else if body[i] == c {
			found = true
		}
	}
	return found != negate
}

// Docnames matching a toctree glob (sorted, as Sphinx's ``patfilter``).
glob_docs :: proc(s: ^Site, pattern: string) -> []Doc_Id {
	out := make([dynamic]Doc_Id)
	for d, i in s.docs {
		if i > 0 && match_here(pattern, d.name) do append(&out, Doc_Id(i))
	}
	return out[:]
}

has_glob_chars :: proc(s: string) -> bool {
	return strings.contains_any(s, "*?[")
}
