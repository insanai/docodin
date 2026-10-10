package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "../../odin/check"
import pb "../../odin/publish"

// Documents that need Python.  Where docutils would use a Python library
// (Pygments, PIL, ``urllib``, codecs, parser and writer modules, external
// MathML converters) or its front end (configuration files, dumps), the
// command runs again as ``python -m docodin`` (docutils' front end on
// docodin) with the same arguments, standard streams and exit status.  The
// Python is ``$DOCODIN_PYTHON``, else the ``python3`` or ``python`` next to
// this program (the environment a wheel installed it into), else ``python3``
// on the PATH, if it imports docodin; without one, a report says what needs
// Python.

// ``docodin sphinx ARGS``: sphinx-build in Python, parsing with docodin
// (``python -m docodin sphinx``).
run_sphinx :: proc(args: []string) -> int {
	python, found := find_python()
	if !found {
		usage_error("NO PYTHON", "`docodin sphinx` runs Sphinx, which needs a Python " +
			"that imports docodin, and I found none.",
			"Install docodin and Sphinx (`pip install docodin[sphinx]`), or name the " +
			"Python with `DOCODIN_PYTHON=/path/to/python`.")
	}
	argv := make([dynamic]string)
	append(&argv, "sphinx")
	append(&argv, ..args)
	return run_python(python, argv[:], nil)
}

// Run ``python -m docodin`` with ``args`` (the writer first, as the program
// name or command chose it), or report the needs; ``input`` is the
// standard input the native run read already.  The exit status.
python_fallback :: proc(
	args: []string,
	writer: string,
	needs: []pb.Python_Need,
	input: Maybe([]u8) = nil,
	text := "",
	source_path := "",
) -> int {
	python, found := find_python()
	if !found {
		report_needs(needs, text, source_path)
		return 1
	}
	argv := make([dynamic]string)
	append(&argv, strings.concatenate({"--writer=", writer}))
	append(&argv, ..args)
	return run_python(python, argv[:], input)
}

// A Python that imports docodin: ``$DOCODIN_PYTHON``, the environment's
// own Python, then ``python3``.
find_python :: proc() -> (string, bool) {
	candidates := make([dynamic]string, context.temp_allocator)
	if env := os.get_env("DOCODIN_PYTHON", context.temp_allocator); env != "" {
		append(&candidates, env)
	}
	if dir, err := os.get_executable_directory(context.temp_allocator); err == nil {
		for name in ([]string{"python3", "python"}) {
			p, _ := filepath.join({dir, name}, context.temp_allocator)
			append(&candidates, p)
		}
	}
	append(&candidates, "python3")
	for name in candidates {
		exe, found := executable_path(name)
		if found && imports_docodin(exe) do return exe, true
	}
	return "", false
}

// The path of a program: ``name`` itself if it has a "/", else the first
// file of that name in a directory of the PATH.
@(private = "file")
executable_path :: proc(name: string) -> (string, bool) {
	if strings.contains_rune(name, '/') do return name, os.is_file(name)
	path := os.get_env("PATH", context.temp_allocator)
	for dir in strings.split(path, ":", context.temp_allocator) {
		if dir == "" do continue
		p, _ := filepath.join({dir, name}, context.temp_allocator)
		if os.is_file(p) do return p, true
	}
	return "", false
}

@(private = "file")
imports_docodin :: proc(python: string) -> bool {
	desc := os.Process_Desc {
		command = {python, "-c", "import docodin"},
	}
	process, err := os.process_start(desc)
	if err != nil do return false
	state, werr := os.process_wait(process)
	return werr == nil && state.exited && state.exit_code == 0
}

// ``python -m docodin ARGS`` with this process's standard streams (the
// standard input from ``input`` if the native run read it); its exit
// status.
@(private = "file")
run_python :: proc(python: string, args: []string, input: Maybe([]u8)) -> int {
	command := make([dynamic]string)
	append(&command, python, "-m", "docodin")
	append(&command, ..args)
	desc := os.Process_Desc {
		command = command[:],
		stdin   = os.stdin,
		stdout  = os.stdout,
		stderr  = os.stderr,
	}
	data, feed := input.?
	r, w: ^os.File
	if feed {
		perr: os.Error
		r, w, perr = os.pipe()
		if perr != nil do return cannot_run(python, perr)
		desc.stdin = r
	}
	process, err := os.process_start(desc)
	if feed {
		os.close(r)
		if err == nil do feed_input(w, data)
		os.close(w)
	}
	if err != nil do return cannot_run(python, err)
	state, werr := os.process_wait(process)
	if werr != nil do return cannot_run(python, werr)
	return state.exit_code
}

// Write the input to the child's standard input; a child that exits
// without reading it closes the pipe (no ``SIGPIPE``).
@(private = "file")
feed_input :: proc(w: ^os.File, data: []u8) {
	ignore_sigpipe()
	rest := data
	for len(rest) > 0 {
		n, err := os.write(w, rest)
		if err != nil || n <= 0 do return
		rest = rest[n:]
	}
}

@(private = "file")
cannot_run :: proc(python: string, err: os.Error) -> int {
	fmt.eprintf("docodin: cannot run %s -m docodin: %s\n", python, os.error_string(err))
	return 1
}

// An Elm-style report for each need: what needs Python, where, and how to
// do without it.
@(private = "file")
report_needs :: proc(needs: []pb.Python_Need, text, source_path: string) {
	b := strings.builder_make()
	color := use_color("auto")
	for need in needs {
		location := "docodin"
		if need.source != "" {
			location = need.source
			if need.line > 0 do location = fmt.tprintf("%s:%d", need.source, need.line)
		}
		explanation := fmt.tprintf(
			"%s\n\ndocodin runs these with docutils' Python front end " +
			"(`python -m docodin`), but found no Python that imports docodin: it tries " +
			"`$DOCODIN_PYTHON`, the Python next to docodin, then `python3`.",
			pb.python_need_text(need, context.temp_allocator),
		)
		hint := strings.concatenate({
			"Install docodin's Python package (`pip install docodin`) or set " +
			"`DOCODIN_PYTHON` to a Python that has it, ", pb.python_need_hint(need),
		})
		src := need_source_lines(need, text, source_path)
		check.format_line_report(&b, "NEEDS PYTHON", location, explanation, src, need.line,
			hint, color)
	}
	os.write_string(os.stderr, strings.to_string(b))
}

// The lines of the file a need is in: the document's ``text`` or an
// included file.
@(private = "file")
need_source_lines :: proc(need: pb.Python_Need, text, source_path: string) -> check.Source_Lines {
	tab_width := check.DEFAULT_OPTIONS.tab_width
	if need.line <= 0 || need.source == "" do return {}
	if need.source == source_path do return check.source_lines(text, tab_width)
	data, err := os.read_entire_file_from_path(need.source, context.allocator)
	if err != nil do return {}
	return check.source_lines(string(data), tab_width)
}
