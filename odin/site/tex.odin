package site

import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

// Running the TeX engine on the book: twice (a third time when LaTeX asks
// for it), from ``/Library/TeX/texbin``, the usual TeX Live directories or
// the PATH.  A failure is reported with the error of the log and the line
// of the LaTeX source it points at.

@(private = "file")
PROGRAM_DIRS := [?]string {
	"/Library/TeX/texbin",
	"/usr/local/texlive/bin",
	"/opt/homebrew/bin",
	"/usr/local/bin",
	"/usr/bin",
}

// A program's path: a directory above or the PATH.
find_program :: proc(name: string) -> (string, bool) {
	if strings.contains_rune(name, '/') do return name, os.is_file(name)
	for dir in PROGRAM_DIRS {
		p := join(dir, name)
		if os.is_file(p) do return p, true
	}
	path := os.get_env("PATH", context.temp_allocator)
	for dir in strings.split(path, ":", context.temp_allocator) {
		if dir == "" do continue
		p := join(dir, name)
		if os.is_file(p) do return p, true
	}
	return name, false
}

// Why the engine failed: an Elm report's parts; ``line`` is a line of
// ``source`` (the LaTeX file), 0 for none.
Tex_Error :: struct {
	title:  string,
	text:   string,
	source: string,
	line:   int,
	hint:   string,
}

// Compile ``tex`` into a PDF next to it with ``engine``; the PDF's path.
compile_tex :: proc(engine, tex: string) -> (pdf: string, err: Maybe(Tex_Error)) {
	bin, found := find_program(engine)
	if !found {
		return "", Tex_Error {
			title = "TEX ENGINE NOT FOUND",
			text = strings.concatenate({"I cannot find `", engine, "` to typeset the book."}),
			hint = "Install TeX Live (or MacTeX), put it on the PATH, or name another engine " +
			"with `--engine=xelatex`.",
		}
	}
	dir := filepath.dir(tex)
	stem := filepath.stem(tex)
	log := join(dir, strings.concatenate({stem, ".log"}))
	command := []string {
		bin, "-interaction=nonstopmode", "-halt-on-error", "-file-line-error",
		strings.concatenate({"-output-directory=", dir}), tex,
	}
	// long log lines, so that messages are not wrapped
	env := make([dynamic]string)
	if current, err := os.environ(context.allocator); err == nil do append(&env, ..current)
	append(&env, "max_print_line=100000", "error_line=254", "half_error_line=238")
	for pass in 1 ..= 3 {
		desc := os.Process_Desc {
			command = command,
			env     = env[:],
		}
		state, stdout, _, exec_err := os.process_exec(desc, context.allocator)
		if exec_err != nil || !state.success {
			return "", log_error(engine, tex, log, string(stdout), pass)
		}
		if pass >= 2 && !needs_rerun(log) do break
	}
	return join(dir, strings.concatenate({stem, ".pdf"})), nil
}

@(private = "file")
needs_rerun :: proc(log: string) -> bool {
	data, err := os.read_entire_file_from_path(log, context.temp_allocator)
	if err != nil do return false
	text := string(data)
	return strings.contains(text, "Rerun to get") || strings.contains(text, "may have changed")
}

// The first error of the log ("! ..." or "file:line: ..." with
// ``-file-line-error``), with its line in the LaTeX source.
@(private = "file")
log_error :: proc(engine, tex, log, stdout: string, pass: int) -> Tex_Error {
	e := Tex_Error {
		title  = "TEX ERROR",
		source = tex,
		hint   = strings.concatenate({"The whole log is in ", log, "."}),
	}
	data, rerr := os.read_entire_file_from_path(log, context.allocator)
	text := string(data) if rerr == nil else stdout
	lines := strings.split_lines(text)
	for line, i in lines {
		msg, lineno, ok := error_line(line, filepath.base(tex))
		if !ok do continue
		e.text = strings.concatenate({engine, " stopped (pass ", itoa(pass), "):\n\n    ", msg})
		e.line = lineno
		for next in lines[i + 1:min(i + 8, len(lines))] {
			if n, ok2 := source_line_number(next); ok2 && e.line == 0 do e.line = n
		}
		if strings.contains(msg, "not found") && strings.contains(msg, ".sty") {
			e.hint = strings.concatenate({"Install the missing LaTeX package ",
				"(`tlmgr install ...`). ", e.hint})
		}
		return e
	}
	e.text = strings.concatenate({engine, " failed (pass ", itoa(pass), ") without an error ",
		"in its log."})
	return e
}

// "! message" or "path.tex:12: message".
@(private = "file")
error_line :: proc(line, tex_base: string) -> (msg: string, lineno: int, ok: bool) {
	if strings.has_prefix(line, "! ") do return line[2:], 0, true
	if i := strings.index(line, ".tex:"); i >= 0 {
		rest := line[i + 5:]
		colon := strings.index_byte(rest, ':')
		if colon <= 0 do return "", 0, false
		n, is_num := strconv.parse_int(rest[:colon])
		if !is_num do return "", 0, false
		lineno = n if strings.contains(line[:i + 4], tex_base) else 0
		return strings.trim_space(rest[colon + 1:]), lineno, true
	}
	return "", 0, false
}

// "l.123 ..." after a TeX error.
@(private = "file")
source_line_number :: proc(line: string) -> (int, bool) {
	if !strings.has_prefix(line, "l.") do return 0, false
	end := 2
	for end < len(line) && line[end] >= '0' && line[end] <= '9' do end += 1
	return strconv.parse_int(line[2:end])
}

itoa :: proc(n: int) -> string {
	return rd_itoa(n)
}
