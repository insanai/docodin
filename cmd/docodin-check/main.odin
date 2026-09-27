package main

// docodin-check: native reStructuredText checker.
//
// Parses reST files with the native parser and reports their markup errors
// (see odin/check) as Elm-style reports, or in docutils' format:
//
//     source:line: (LEVEL/n) message

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"

import "../../odin/check"

VERSION :: "0.3.0"

USAGE :: `Usage: docodin-check [options] [FILE ...]

Check reStructuredText files for markup errors at native speed.  Reads
standard input when no FILE (or "-") is given.  Reports are written to
standard error.

Options:
  --report=LEVEL          report messages at or above LEVEL (default: warning)
  --exit-status=LEVEL     exit with 1 if a message at or above LEVEL was
                          reported (default: error)
  --error-format=FORMAT   elm: explained reports with source excerpts and
                          hints (default); docutils: "source:line: (LEVEL/n)
                          message" lines
  --color=WHEN            colorize elm reports: auto (default), always, never
  --tab-width=N           tab stop width (default: 8)
  --line-length-limit=N   maximal line length (default: 10000)
  --pep-references        recognize PEP references
  --rfc-references        recognize RFC references
  --character-level-inline-markup
  --trim-footnote-reference-space
  -j N, --jobs=N          number of worker threads (default: CPU count)
  --version               print the version and exit
  -h, --help              print this help and exit

LEVEL is one of info, warning, error, severe, none or 1-5.

Only parser diagnostics are reported: directives, roles and reference
resolution are handled by the docutils host (the docodin command).
`

Options :: struct {
	parse:        check.Options,
	report_level: int,
	exit_level:   int,
	format:       check.Error_Format,
	color:        bool,
	jobs:         int,
}

Job :: struct {
	path:      string, // "-" is standard input
	output:    string, // formatted reports
	counts:    [5]int, // reported messages per level
	max_level: int,
	failed:    bool,
}

main :: proc() {
	opts := parse_args()
	jobs := opts.jobs_list
	run_jobs(jobs, &opts.options)

	status := 0
	counts: [5]int
	for job in jobs {
		os.write_string(os.stderr, job.output)
		for n, level in job.counts do counts[level] += n
		if job.failed || job.max_level >= opts.exit_level do status = 1
	}
	if opts.format == .Elm do write_summary(counts, len(jobs))
	os.exit(status)
}

// --- command line ----------------------------------------------------------------

Args :: struct {
	using options: Options,
	jobs_list:     []Job,
}

@(private = "file")
parse_args :: proc() -> Args {
	opts := Options {
		parse        = check.DEFAULT_OPTIONS,
		report_level = 2,
		exit_level   = 3,
		jobs         = os.get_processor_core_count(),
	}
	color_mode := "auto"
	jobs := make([dynamic]Job)
	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		arg := args[i]
		if !strings.has_prefix(arg, "-") || arg == "-" {
			append(&jobs, Job{path = arg})
			continue
		}
		if arg == "--" {
			for p in args[i + 1:] do append(&jobs, Job{path = p})
			break
		}
		key, value, has_value := split_option(arg)
		if takes_value(key) && !has_value {
			if i + 1 >= len(args) do usage_error("option %s requires a value", key)
			i += 1
			value = args[i]
		}
		if key == "--color" {
			color_mode = value
			continue
		}
		apply_option(&opts, key, value)
	}
	if len(jobs) == 0 do append(&jobs, Job{path = "-"})
	opts.color = use_color(color_mode)
	return {opts, jobs[:]}
}

@(private = "file")
takes_value :: proc(key: string) -> bool {
	switch key {
	case "--report", "--exit-status", "--error-format", "--color", "--tab-width",
	     "--line-length-limit", "--jobs", "-j":
		return true
	}
	return false
}

@(private = "file")
apply_option :: proc(opts: ^Options, key, value: string) {
	switch key {
	case "-h", "--help":
		fmt.print(USAGE)
		os.exit(0)
	case "--version":
		fmt.printfln("docodin-check %s (native reStructuredText checker)", VERSION)
		os.exit(0)
	case "--report":                        opts.report_level = parse_level(value)
	case "--exit-status":                   opts.exit_level = parse_level(value)
	case "--error-format":                  opts.format = parse_format(value)
	case "--tab-width":                     opts.parse.tab_width = parse_int(key, value, 1)
	case "--line-length-limit":             opts.parse.line_limit = parse_int(key, value, 0)
	case "--jobs", "-j":                    opts.jobs = parse_int(key, value, 1)
	case "--pep-references":                opts.parse.flags += {.Pep_References}
	case "--rfc-references":                opts.parse.flags += {.Rfc_References}
	case "--character-level-inline-markup": opts.parse.flags += {.Character_Level_Inline_Markup}
	case "--trim-footnote-reference-space": opts.parse.flags += {.Trim_Footnote_Reference_Space}
	case:                                   usage_error("unknown option %s", key)
	}
}

@(private = "file")
split_option :: proc(arg: string) -> (key, value: string, has_value: bool) {
	if eq := strings.index_byte(arg, '='); eq >= 0 do return arg[:eq], arg[eq + 1:], true
	if strings.has_prefix(arg, "-j") && len(arg) > 2 do return "-j", arg[2:], true // -jN
	return arg, "", false
}

@(private = "file")
usage_error :: proc(format: string, args: ..any) -> ! {
	fmt.eprint("docodin-check: ")
	fmt.eprintfln(format, ..args)
	fmt.eprintln("Try 'docodin-check --help' for more information.")
	os.exit(2)
}

@(private = "file")
parse_int :: proc(key, value: string, minimum: int) -> int {
	n, ok := strconv.parse_int(value, 10)
	if !ok || n < minimum do usage_error("invalid value for %s: %q", key, value)
	return n
}

// docutils ``validate_threshold``: level names or numbers.
@(private = "file")
parse_level :: proc(value: string) -> int {
	switch strings.to_lower(value, context.temp_allocator) {
	case "info":    return 1
	case "warning": return 2
	case "error":   return 3
	case "severe":  return 4
	case "none":    return 5
	}
	n, ok := strconv.parse_int(value, 10)
	if !ok || n < 0 || n > 5 do usage_error("unknown level %q", value)
	return n
}

@(private = "file")
parse_format :: proc(value: string) -> check.Error_Format {
	switch value {
	case "elm":      return .Elm
	case "docutils": return .Docutils
	}
	usage_error("unknown error format %q (use elm or docutils)", value)
}

// ``auto``: standard error is a terminal, and neither NO_COLOR nor TERM=dumb
// is set (https://no-color.org).
@(private = "file")
use_color :: proc(mode: string) -> bool {
	switch mode {
	case "always": return true
	case "never":  return false
	case "auto":
		if os.get_env("NO_COLOR", context.temp_allocator) != "" do return false
		if os.get_env("TERM", context.temp_allocator) == "dumb" do return false
		return os.is_tty(os.stderr)
	}
	usage_error("unknown color mode %q (use auto, always or never)", mode)
}

@(private = "file")
write_summary :: proc(counts: [5]int, files: int) {
	total := 0
	for n, level in counts do if level > 0 do total += n
	if total == 0 do return
	parts := make([dynamic]string, context.temp_allocator)
	names := [5]string{"", "info message", "warning", "error", "severe error"}
	#reverse for n, level in counts {
		if level == 0 || n == 0 do continue
		append(&parts, fmt.tprintf("%d %s%s", n, names[level], "" if n == 1 else "s"))
	}
	fmt.eprintfln("Found %s in %d file%s.", strings.join(parts[:], ", ", context.temp_allocator),
		files, "" if files == 1 else "s")
}

// --- workers -------------------------------------------------------------------

Pool :: struct {
	jobs: []Job,
	opts: ^Options,
	next: int, // atomic
}

@(private = "file")
run_jobs :: proc(jobs: []Job, opts: ^Options) {
	pool := Pool{jobs = jobs, opts = opts}
	workers := clamp(opts.jobs, 1, len(jobs))
	if workers == 1 {
		worker(&pool)
		return
	}
	threads := make([]^thread.Thread, workers - 1, context.temp_allocator)
	for &t in threads do t = thread.create_and_start_with_poly_data(&pool, worker)
	worker(&pool)
	for t in threads {
		thread.join(t)
		thread.destroy(t)
	}
}

@(private = "file")
worker :: proc(pool: ^Pool) {
	arena: virtual.Arena
	if err := virtual.arena_init_growing(&arena); err != nil {
		fmt.eprintln("docodin-check: out of memory")
		os.exit(2)
	}
	defer virtual.arena_destroy(&arena)
	scratch := virtual.arena_allocator(&arena)
	for {
		i := sync.atomic_add(&pool.next, 1)
		if i >= len(pool.jobs) do break
		check_file(&pool.jobs[i], pool.opts, scratch)
		free_all(scratch)
	}
}

@(private = "file")
check_file :: proc(job: ^Job, opts: ^Options, scratch: runtime.Allocator) {
	context.allocator = scratch
	context.temp_allocator = scratch
	heap := runtime.heap_allocator()
	source := "<stdin>" if job.path == "-" else job.path
	data: []byte
	err: os.Error
	if job.path == "-" {
		data, err = os.read_entire_file(os.stdin, scratch)
	} else {
		data, err = os.read_entire_file(job.path, scratch)
	}
	if err != nil {
		job.output = fmt.aprintfln("docodin-check: cannot read %s: %v", source, os.error_string(err),
			allocator = heap)
		job.failed = true
		return
	}
	if bad := check.invalid_utf8_offset(data); bad >= 0 {
		job.output = fmt.aprintfln("docodin-check: cannot decode %s: invalid UTF-8 at byte %d",
			source, bad, allocator = heap)
		job.failed = true
		return
	}
	text := string(data)
	messages := check.check_text(text, opts.parse)
	src: check.Source_Lines
	if opts.format == .Elm do src = check.source_lines(text, opts.parse.tab_width)
	b := strings.builder_make(heap)
	for m in messages {
		job.max_level = max(job.max_level, m.level)
		if m.level < opts.report_level do continue
		job.counts[clamp(m.level, 0, 4)] += 1
		switch opts.format {
		case .Elm:      check.format_elm(&b, source, src, m, opts.color)
		case .Docutils: check.format_docutils(&b, source, m)
		}
	}
	job.output = strings.to_string(b)
}
