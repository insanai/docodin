package main

// docodin: the native reStructuredText toolchain.
//
//     docodin [--writer=NAME] [options] [SOURCE [DESTINATION]]
//     docodin check [options] FILE...
//     docodin pdf [options] SOURCE [OUTPUT.pdf]
//     docodin book build [DIR] [options]
//     docodin dod new|list|index|check [options]
//     docodin sphinx [sphinx-build options] SOURCEDIR OUTPUTDIR
//
// Publishing works as ``docutils`` (``python -m docutils``) does, with the
// same output, messages and exit status: the standalone reader and the rST
// parser with the pseudoxml, xml, html5, latex and xetex writers
// (``odin/publish``).  ``rst2html``-style names of the program select the
// writer, as do the commands ``html``, ``latex``, ``xetex``, ``xml`` and
// ``pseudoxml``.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "../../odin/check"
import pb "../../odin/publish"
import "../../odin/version"

VERSION :: version.VERSION

// The publisher's options: the docutils data (stylesheets, templates and
// standard include files) are embedded, see ``pb.tools_docutils_dir``.
native_options :: proc() -> pb.Options {
	return {docutils_dir = pb.tools_docutils_dir()}
}

Command :: enum u8 {
	Publish,
	Check,
	Pdf,
	Book,
	Dod,
	Sphinx,
}

main :: proc() {
	args := os.args[1:]
	cmd := Command.Publish
	writer := program_writer(os.args[0])
	if len(args) > 0 {
		switch args[0] {
		case "check":
			cmd, args = .Check, args[1:]
		case "pdf":
			cmd, args = .Pdf, args[1:]
		case "book":
			cmd, args = .Book, args[1:]
		case "dod":
			cmd, args = .Dod, args[1:]
		case "sphinx":
			cmd, args = .Sphinx, args[1:]
		case:
			if w, ok := command_writer(args[0]); ok do writer, args = w, args[1:]
		}
	}
	switch cmd {
	case .Check:
		os.exit(run_check(args))
	case .Pdf:
		os.exit(run_pdf(args))
	case .Book:
		os.exit(run_book(args))
	case .Dod:
		os.exit(run_dod(args))
	case .Sphinx:
		os.exit(run_sphinx(args))
	case .Publish:
		os.exit(run_publish(args, writer))
	}
}

// The writer of an ``rst2*`` program name (html5 for others).
program_writer :: proc(argv0: string) -> string {
	name := filepath.stem(filepath.base(argv0))
	if strings.has_prefix(name, "rst2") {
		if _, ok := pb.writer_of(name[4:]); ok do return name[4:]
	}
	return "html5"
}

// A writer named as the command (``docodin latex doc.rst``), with the
// commands ``python -m docodin`` takes (``rst2man`` and the writers that
// need Python are run there).
command_writer :: proc(arg: string) -> (string, bool) {
	switch arg {
	case "html", "html5", "xhtml", "latex", "latex2e", "xetex", "xml", "pseudoxml":
		return arg, true
	case "rst2html", "rst2html5":
		return "html5", true
	case "rst2latex", "rst2xetex", "rst2xml", "rst2pseudoxml", "rst2odt", "rst2s5":
		return arg[4:], true
	case "rst2man":
		return "manpage", true
	}
	return "", false
}

// --- publish -----------------------------------------------------------------------------

@(private = "file")
run_publish :: proc(args: []string, default_writer: string) -> int {
	cli := parse_command_line(args, default_writer)
	if len(cli.needs) > 0 do return python_fallback(args, default_writer, cli.needs[:])
	source := cli.source if cli.source != "" else "-"
	data, read_ok := read_input(source)
	if !read_ok do return 1
	input: Maybe([]u8)
	if source == "-" do input = data
	text, need, ok := decode_source(data, &cli)
	if n, needed := need.?; needed do return python_fallback(args, default_writer, {n}, input)
	if !ok do return 1
	source_path := "<stdin>" if source == "-" else source
	output, _, messages, status, err, needs := pb.publish(text, source_path, cli.writer_name,
		cli.overrides[:], native_options())
	if len(needs) > 0 {
		return python_fallback(args, default_writer, needs, input, text, source_path)
	}
	write_messages(&cli, messages, err)
	if _, failed := err.(pb.Settings_Error); failed do return 2
	if err == nil && !write_destination(&cli, output) do return 1
	return status
}

// ``FileInput.read`` of a path or of standard input ("-"): the bytes; on
// failure, docutils' report.
read_input :: proc(path: string) -> ([]u8, bool) {
	data: []byte
	rerr: os.Error
	if path == "-" {
		data, rerr = os.read_entire_file(os.stdin, context.allocator)
	} else {
		data, rerr = os.read_entire_file_from_path(path, context.allocator)
	}
	if rerr != nil {
		reason := os_error_text(path, rerr)
		fmt.eprintf("Unable to open source file for reading:\n  InputError: %s\n", reason)
		return nil, false
	}
	return data, true
}

// The source decoded with ``input_encoding`` and with universal newlines.
// A codec or error handler the native code lacks is a Python need; on
// failure, docutils' report.
decode_source :: proc(
	data: []u8,
	cli: ^Cli,
) -> (
	text: string,
	need: Maybe(pb.Python_Need),
	ok: bool,
) {
	encoding := setting_string(cli, "input_encoding", "utf-8")
	handler := setting_string(cli, "input_encoding_error_handler", "strict")
	if !pb.native_decoder(encoding) {
		return "", pb.Python_Need{feature = .Codec, detail = encoding}, false
	}
	decoded, derr := pb.decode(data, encoding, handler)
	if derr == "" do return pb.universal_newlines(decoded), nil, true
	if !pb.native_decode_handler(handler) {
		return "", pb.Python_Need{feature = .Codec, detail = handler}, false
	}
	msg := fmt.tprintf(
		"UnicodeError: Unable to decode input data.  Tried the following encodings: " +
		"'%s'.\n(%s)",
		encoding, derr,
	)
	os.write_string(os.stderr, pb.exception_report(msg))
	return "", nil, false
}

// ``str(OSError)``.
os_error_text :: proc(path: string, err: os.Error) -> string {
	switch {
	case os.is_directory(path):
		return fmt.tprintf("[Errno 21] Is a directory: '%s'", path)
	case os.exists(path):
		return fmt.tprintf("[Errno 13] Permission denied: '%s'", path)
	}
	return fmt.tprintf("[Errno 2] No such file or directory: '%s'", path)
}

// The messages (to standard error or the ``--warnings`` file) and the
// report of a failure.
@(private = "file")
write_messages :: proc(cli: ^Cli, messages: []pb.Message, err: pb.Error) {
	b := strings.builder_make()
	for m in messages do strings.write_string(&b, m.text)
	if cli.warnings != "" {
		if werr := os.write_entire_file(cli.warnings, b.buf[:]); werr != nil {
			fmt.eprintf("docodin: cannot write %s: %s\n", cli.warnings, os.error_string(werr))
		}
	} else {
		os.write_string(os.stderr, strings.to_string(b))
	}
	#partial switch e in err {
	case pb.Settings_Error:
		usage_error("INVALID SETTING", e.message, "")
	case nil:
	case:
		os.write_string(os.stderr, pb.error_report(err))
	}
}

// Write the encoded output to the destination (standard output if none).
@(private = "file")
write_destination :: proc(cli: ^Cli, output: string) -> bool {
	data := pb.encode_output(output, cli.settings)
	path := setting_string(cli, "output_path", "")
	if path == "" || path == "-" {
		os.write(os.stdout, data)
		return true
	}
	if werr := os.write_entire_file(path, data); werr != nil {
		fmt.eprintf(
			"Unable to open destination file for writing:\n  OutputError: %s\n",
			os_error_text(path, werr),
		)
		return false
	}
	return true
}

// A string setting of the command line ("" for None).
setting_string :: proc(cli: ^Cli, name, default: string) -> string {
	v, ok := cli.settings[name]
	if !ok do return default
	s, _ := v.(string)
	return s
}

// --- check -------------------------------------------------------------------------------

CHECK_USAGE :: `Usage: docodin check [options] FILE...

Report the markup errors the reStructuredText parser detects (see
docodin-check for the parallel checker).

Options:
  --error-format=FORMAT   elm (explained reports, default) or docutils
  --color=WHEN            colorize elm reports: auto (default), always, never
  --report=LEVEL          report messages at or above LEVEL (default: warning)
  --exit-status=LEVEL     exit with 1 if a message at or above LEVEL was
                          reported (default: error)
  -h, --help              print this help and exit
`

@(private = "file")
Check_Options :: struct {
	format:       check.Error_Format,
	color:        bool,
	report_level: int,
	exit_level:   int,
	files:        [dynamic]string,
}

@(private = "file")
run_check :: proc(args: []string) -> int {
	opts := parse_check_args(args)
	status := 0
	for f in opts.files {
		data, err := os.read_entire_file_from_path(f, context.allocator)
		if err != nil {
			fmt.eprintf("docodin: cannot read %s: %s\n", f, os_error_text(f, err))
			status = 1
			continue
		}
		text := string(data)
		b := strings.builder_make()
		src: check.Source_Lines
		if opts.format == .Elm do src = check.source_lines(text, check.DEFAULT_OPTIONS.tab_width)
		for m in check.check_text(text, check.DEFAULT_OPTIONS) {
			if m.level >= opts.exit_level do status = 1
			if m.level < opts.report_level do continue
			switch opts.format {
			case .Elm:
				check.format_elm(&b, f, src, m, opts.color)
			case .Docutils:
				check.format_docutils(&b, f, m)
			}
		}
		os.write_string(os.stderr, strings.to_string(b))
	}
	return status
}

@(private = "file")
parse_check_args :: proc(args: []string) -> Check_Options {
	opts := Check_Options {
		report_level = 2,
		exit_level   = 3,
		files        = make([dynamic]string),
	}
	color := "auto"
	for arg in args {
		key, _, value := strings.partition(arg, "=")
		switch key {
		case "-h", "--help":
			fmt.print(CHECK_USAGE)
			os.exit(0)
		case "--error-format":
			opts.format = error_format(value)
		case "--color":
			color = value
		case "--report":
			opts.report_level = check_level(key, value)
		case "--exit-status":
			opts.exit_level = check_level(key, value)
		case:
			if strings.has_prefix(arg, "-") && arg != "-" do unknown_option(arg, nil)
			append(&opts.files, arg)
		}
	}
	if len(opts.files) == 0 {
		usage_error("MISSING FILE", "`docodin check` needs files to check.",
			"Write `docodin check doc.rst`.")
	}
	opts.color = use_color(color)
	return opts
}

error_format :: proc(value: string) -> check.Error_Format {
	switch value {
	case "elm":
		return .Elm
	case "docutils":
		return .Docutils
	}
	invalid_value("--error-format", value, "", {"elm", "docutils"})
}

check_level :: proc(key, value: string) -> int {
	level, err := pb.parse_threshold(value)
	if err != "" do invalid_value(key, value, err, LEVEL_NAMES)
	return level.(int)
}

LEVEL_NAMES := []string{"info", "warning", "error", "severe", "none"}

// ``auto``: standard error is a terminal, and neither NO_COLOR nor
// TERM=dumb is set (https://no-color.org).
use_color :: proc(mode: string) -> bool {
	switch mode {
	case "always":
		return true
	case "never":
		return false
	case "auto":
		if os.get_env("NO_COLOR", context.temp_allocator) != "" do return false
		if os.get_env("TERM", context.temp_allocator) == "dumb" do return false
		return os.is_tty(os.stderr)
	}
	invalid_value("--color", mode, "", {"auto", "always", "never"})
}
