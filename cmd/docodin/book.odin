package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "../../odin/check"
import "../../odin/site"

// ``docodin book build``: a Sphinx project built natively, as an HTML site
// in the docodin theme and as a PDF book.

BOOK_USAGE :: `Usage: docodin book build [DIR] [options]

Build the Sphinx project in DIR (default: the current directory) without
Python: an HTML site in the docodin theme (OUTDIR/html) and a PDF book
(OUTDIR/latex).  conf.py is read, not run: its plain assignments count.
Without --html or --pdf, both are built (the PDF when a TeX engine is found).

Options:
  -o, --output=OUTDIR     the output directory (default: DIR/_build)
  --html                  build the HTML site
  --pdf                   build the PDF book
  --engine=NAME           lualatex (default: conf.py's latex_engine) or xelatex
  --error-format=FORMAT   elm (explained reports, default) or docutils
  --color=WHEN            colorize elm reports: auto (default), always, never
  --exit-status=LEVEL     exit with 10 + the highest level of the warnings if
                          it is LEVEL or above (default: none), as docutils
  -W                      the same as --exit-status=warning
  -q, --quiet             print warnings only
  -h, --help              print this help and exit
`

@(private = "file")
Book_Options :: struct {
	dir:        string,
	outdir:     string,
	html:       bool,
	pdf:        bool,
	explicit:   bool, // --html or --pdf was given
	engine:     string,
	format:     check.Error_Format,
	color:      bool,
	color_mode: string, // --color
	exit_level: int,
	quiet:      bool,
}

run_book :: proc(args: []string) -> int {
	if len(args) == 0 || args[0] != "build" {
		if len(args) > 0 && (args[0] == "-h" || args[0] == "--help") {
			fmt.print(BOOK_USAGE)
			return 0
		}
		given := args[0] if len(args) > 0 else ""
		text := "`docodin book` needs a subcommand." if given == "" else
			fmt.tprintf("I do not know the subcommand `book %s`.", given)
		usage_error("UNKNOWN COMMAND", text, "Write `docodin book build [DIR]`.")
	}
	opts := parse_book_args(args[1:])
	s, err := site.open_site(opts.dir, opts.outdir)
	if err != "" {
		usage_error("NOT A SPHINX PROJECT", err,
			"Name the directory that holds conf.py and the root document: " +
			"`docodin book build docs/book`.")
	}
	defer site.destroy_site(s)
	if opts.engine == "" do opts.engine = s.conf.latex_engine
	status := build_outputs(s, &opts)
	report_warnings(s, &opts)
	if status != 0 do return status
	// ``publish_cmdline``'s exit status: the highest level plus 10 if it
	// reached ``--exit-status``
	if level := site.max_level(s); level >= opts.exit_level do return level + 10
	return 0
}

// Build the PDF (first, so that the site can offer it) and the site.
@(private = "file")
build_outputs :: proc(s: ^site.Site, opts: ^Book_Options) -> int {
	pdf := ""
	if opts.pdf {
		_, found := site.find_program(opts.engine)
		if found || opts.explicit {
			path, ok := build_pdf(s, opts)
			if !ok do return 1
			pdf = path
		} else if !opts.quiet {
			fmt.eprintf("docodin: no %s found, the PDF book is skipped\n", opts.engine)
		}
	}
	if opts.html {
		dir := join_path(opts.outdir, "html")
		if !site.write_html(s, dir, {pdf = pdf}) do return 1
		if !opts.quiet do fmt.eprintf("docodin: wrote the HTML site to %s\n", dir)
	}
	return 0
}

@(private = "file")
build_pdf :: proc(s: ^site.Site, opts: ^Book_Options) -> (string, bool) {
	dir := join_path(opts.outdir, "latex")
	name := s.conf.pdf_filename
	if name == "" do name = strings.concatenate({slug(s.conf.project), ".pdf"})
	tex := join_path(dir, strings.concatenate({filepath.stem(name), ".tex"}))
	if !site.write_book_tex(s, dir, tex) do return "", false
	pdf, err := site.compile_tex(opts.engine, tex)
	if e, failed := err.?; failed {
		b := strings.builder_make()
		src: check.Source_Lines
		if e.line > 0 {
			data, rerr := os.read_entire_file_from_path(e.source, context.allocator)
			if rerr == nil {
				src = check.source_lines(string(data), 8)
			}
		}
		location := "docodin"
		if e.source != "" do location = site.display_path(e.source)
		if e.line > 0 do location = fmt.tprintf("%s:%d", location, e.line)
		check.format_line_report(&b, e.title, location, e.text, src, e.line, e.hint, opts.color)
		os.write_string(os.stderr, strings.to_string(b))
		return "", false
	}
	if !opts.quiet do fmt.eprintf("docodin: wrote the PDF book %s\n", pdf)
	return pdf, true
}

@(private = "file")
report_warnings :: proc(s: ^site.Site, opts: ^Book_Options) {
	if len(s.warnings) == 0 do return
	b := strings.builder_make()
	site.format_warnings(&b, s, opts.format, opts.color)
	os.write_string(os.stderr, strings.to_string(b))
	if !opts.quiet {
		n := len(s.warnings)
		fmt.eprintf("docodin: %d warning%s\n", n, "" if n == 1 else "s")
	}
}

@(private = "file")
parse_book_args :: proc(args: []string) -> Book_Options {
	opts := Book_Options {
		exit_level = 5,
		color_mode = "auto",
	}
	positional := make([dynamic]string)
	for i := 0; i < len(args); i += 1 {
		arg := args[i]
		key, has_value, value := strings.partition(arg, "=")
		if book_flag_option(&opts, key) do continue
		if !takes_book_value(key) {
			if strings.has_prefix(arg, "-") do book_unknown_option(arg)
			append(&positional, arg)
			continue
		}
		if has_value == "" {
			if i + 1 >= len(args) {
				usage_error("MISSING VALUE", fmt.tprintf("The option `%s` needs a value.", key),
					fmt.tprintf("Write `%s=VALUE`.", key))
			}
			i += 1
			value = args[i]
		}
		book_value_option(&opts, key, value)
	}
	finish_book_options(&opts, positional[:])
	return opts
}

@(private = "file")
takes_book_value :: proc(key: string) -> bool {
	switch key {
	case "-o", "--output", "--engine", "--error-format", "--color", "--exit-status":
		return true
	}
	return false
}

// An option without value; false when ``key`` is not one.
@(private = "file")
book_flag_option :: proc(opts: ^Book_Options, key: string) -> bool {
	switch key {
	case "-h", "--help":
		fmt.print(BOOK_USAGE)
		os.exit(0)
	case "--html":
		opts.html, opts.explicit = true, true
	case "--pdf":
		opts.pdf, opts.explicit = true, true
	case "-W":
		opts.exit_level = 2
	case "-q", "--quiet":
		opts.quiet = true
	case:
		return false
	}
	return true
}

@(private = "file")
book_value_option :: proc(opts: ^Book_Options, key, value: string) {
	switch key {
	case "-o", "--output":
		opts.outdir = value
	case "--engine":
		opts.engine = engine_option(value)
	case "--error-format":
		opts.format = error_format(value)
	case "--color":
		opts.color_mode = value
	case "--exit-status":
		opts.exit_level = check_level(key, value)
	}
}

@(private = "file")
finish_book_options :: proc(opts: ^Book_Options, positional: []string) {
	if len(positional) > 1 {
		usage_error("TOO MANY ARGUMENTS",
			fmt.tprintf("`docodin book build` takes one directory, not %d.", len(positional)),
			"Write `docodin book build DIR -o OUTDIR`.")
	}
	opts.dir = positional[0] if len(positional) == 1 else "."
	if !os.is_dir(opts.dir) {
		usage_error("NO SUCH DIRECTORY", fmt.tprintf("I cannot find the directory `%s`.",
			opts.dir), "Name the directory of the Sphinx project (it holds conf.py).")
	}
	if opts.outdir == "" do opts.outdir = join_path(opts.dir, "_build")
	if !opts.explicit do opts.html, opts.pdf = true, true
	opts.color = use_color(opts.color_mode)
}

@(private = "file")
engine_option :: proc(value: string) -> string {
	switch value {
	case "lualatex", "xelatex":
		return value
	}
	if strings.contains_rune(value, '/') do return value
	invalid_value("--engine", value, "", {"lualatex", "xelatex"})
}

@(private = "file")
book_unknown_option :: proc(arg: string) -> ! {
	options := []string{"--output", "--html", "--pdf", "--engine", "--error-format", "--color",
		"--exit-status", "--quiet", "--help"}
	hint := "Run `docodin book build --help` to see the options."
	name, _, _ := strings.partition(arg, "=")
	for o in options {
		if strings.has_prefix(o, name) || edit_distance(o, name) <= 2 {
			hint = fmt.tprintf("Did you mean `%s`?  %s", o, hint)
			break
		}
	}
	usage_error("UNKNOWN OPTION", fmt.tprintf("I do not know the option `%s`.", arg), hint)
}

// Levenshtein distance (small strings).
edit_distance :: proc(a, b: string) -> int {
	prev := make([]int, len(b) + 1, context.temp_allocator)
	cur := make([]int, len(b) + 1, context.temp_allocator)
	for j in 0 ..= len(b) do prev[j] = j
	for i in 1 ..= len(a) {
		cur[0] = i
		for j in 1 ..= len(b) {
			cost := 0 if a[i - 1] == b[j - 1] else 1
			cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
		}
		prev, cur = cur, prev
	}
	return prev[len(b)]
}

join_path :: proc(a, b: string) -> string {
	p, _ := filepath.join({a, b})
	return p
}

// A file name from a title: lowercase words joined by "-".
slug :: proc(title: string) -> string {
	sb := strings.builder_make()
	dash := false
	for r in strings.to_lower(title) {
		ok := (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9')
		if !ok {
			dash = strings.builder_len(sb) > 0
			continue
		}
		if dash do strings.write_byte(&sb, '-')
		dash = false
		strings.write_rune(&sb, r)
	}
	return strings.to_string(sb)
}
