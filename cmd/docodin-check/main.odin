package main

// docodin-check: native reStructuredText checker.
//
// Parses reST files with the native parser and reports the markup errors
// (docutils system messages raised while parsing) in docutils' format:
//
//     source:line: (LEVEL/n) message
//
// Directives, interpreted text roles and reference resolution are
// processed by the docutils host (the ``docodin`` command), so their
// diagnostics are not reported here.

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:unicode/utf8"

import rst "../../odin/rst"

VERSION :: "0.2.0"

USAGE :: `Usage: docodin-check [options] [FILE ...]

Check reStructuredText files for markup errors at native speed.  Reads
standard input when no FILE (or "-") is given.  Messages are written to
standard error in docutils' format.

Options:
  --report=LEVEL          report messages at or above LEVEL (default: warning)
  --exit-status=LEVEL     exit with 1 if a message at or above LEVEL was
                          reported (default: error)
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
	report_level: int,
	exit_level:   int,
	flags:        rst.Parse_Flags,
	tab_width:    int,
	line_limit:   int,
	jobs:         int,
}

Job :: struct {
	path:      string, // "-" is standard input
	output:    string, // formatted messages
	max_level: int,
	failed:    bool,
}

Message :: struct {
	line:  int, // 0: none
	level: int,
	text:  string,
}

LEVEL_NAMES := [?]string{"DEBUG", "INFO", "WARNING", "ERROR", "SEVERE"}

main :: proc() {
	opts := Options {
		report_level = 2,
		exit_level   = 3,
		flags        = {.Match_Titles},
		tab_width    = 8,
		line_limit   = 10000,
		jobs         = os.get_processor_core_count(),
	}
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
		// options taking a value accept "--opt=V" and "--opt V"
		takes_value := key == "--report" || key == "--exit-status" || key == "--tab-width" ||
			key == "--line-length-limit" || key == "--jobs" || key == "-j"
		if takes_value && !has_value {
			if i + 1 >= len(args) do usage_error("option %s requires a value", key)
			i += 1
			value = args[i]
		}
		switch key {
		case "-h", "--help":
			fmt.print(USAGE)
			os.exit(0)
		case "--version":
			fmt.printfln("docodin-check %s (native reStructuredText checker)", VERSION)
			os.exit(0)
		case "--report":                        opts.report_level = parse_level(value)
		case "--exit-status":                   opts.exit_level = parse_level(value)
		case "--tab-width":                     opts.tab_width = parse_int(key, value, 1)
		case "--line-length-limit":             opts.line_limit = parse_int(key, value, 0)
		case "--jobs", "-j":                    opts.jobs = parse_int(key, value, 1)
		case "--pep-references":                opts.flags += {.Pep_References}
		case "--rfc-references":                opts.flags += {.Rfc_References}
		case "--character-level-inline-markup": opts.flags += {.Character_Level_Inline_Markup}
		case "--trim-footnote-reference-space": opts.flags += {.Trim_Footnote_Reference_Space}
		case:                                   usage_error("unknown option %s", key)
		}
	}
	if len(jobs) == 0 do append(&jobs, Job{path = "-"})

	run_jobs(jobs[:], &opts)

	status := 0
	for job in jobs {
		os.write_string(os.stderr, job.output)
		if job.failed || job.max_level >= opts.exit_level do status = 1
	}
	os.exit(status)
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
	source := "<stdin>" if job.path == "-" else job.path
	data: []byte
	err: os.Error
	if job.path == "-" {
		data, err = os.read_entire_file(os.stdin, scratch)
	} else {
		data, err = os.read_entire_file(job.path, scratch)
	}
	if err != nil {
		job.output = fmt.aprintfln("docodin-check: cannot read %s: %v", source, os.error_string(err), allocator = runtime.heap_allocator())
		job.failed = true
		return
	}
	// docutils decodes input as strict UTF-8 (a BOM is kept as U+FEFF)
	if bad := invalid_utf8_offset(data); bad >= 0 {
		job.output = fmt.aprintfln("docodin-check: cannot decode %s: invalid UTF-8 at byte %d", source, bad, allocator = runtime.heap_allocator())
		job.failed = true
		return
	}
	p := rst.Parser {
		allocator = scratch,
		settings  = rst.settings_from_flags(opts.flags, opts.tab_width, opts.line_limit),
	}
	doc, line_count, final_offset := rst.parse_text(&p, string(data), 0, true)

	c := Collector {
		p        = &p,
		messages = make([dynamic]Message, 0, 16, scratch),
	}
	collect_document(&c, doc)
	if final_offset >= 0 {
		// docutils resolves a line number <= 0 with ``input_lines.info(line - 1)``:
		// a negative index, counted from the end of the input
		for &m in c.messages do if m.line <= 0 && line_count + m.line > 0 do m.line += line_count
	}
	// docutils reports messages as they are created, which is source order
	// except for inline messages; report them by line
	slice.stable_sort_by(c.messages[:], proc(a, b: Message) -> bool {return a.line < b.line})

	b := strings.builder_make(runtime.heap_allocator())
	for m in c.messages {
		job.max_level = max(job.max_level, m.level)
		if m.level < opts.report_level do continue
		// ``system_message.astext()``
		strings.write_string(&b, source)
		strings.write_byte(&b, ':')
		if m.line > 0 do strings.write_int(&b, m.line)
		strings.write_string(&b, ": (")
		strings.write_string(&b, LEVEL_NAMES[clamp(m.level, 0, len(LEVEL_NAMES) - 1)])
		strings.write_byte(&b, '/')
		strings.write_int(&b, m.level)
		strings.write_string(&b, ") ")
		strings.write_string(&b, m.text)
		strings.write_byte(&b, '\n')
	}
	job.output = strings.to_string(b)
}

@(private = "file")
invalid_utf8_offset :: proc(data: []byte) -> int {
	for i := 0; i < len(data); {
		if data[i] < 0x80 {
			i += 1
			continue
		}
		r, size := utf8.decode_rune(data[i:])
		if r == utf8.RUNE_ERROR && size <= 1 do return i
		i += size
	}
	return -1
}

// --- message collection -----------------------------------------------------------

Style :: struct {
	chars: [2]u8,
	n:     int, // 1: underline only, 2: overline and underline
}

Collector :: struct {
	p:             ^rst.Parser,
	messages:      [dynamic]Message,
	title_styles:  [dynamic]Style,
	section_level: int,
}

// Context of a node's children during the walk.
Walk :: struct {
	line:  int,     // nearest enclosing line: docutils passes it to the inliner
	delta: int,     // source line minus absolute line (table cells, substitutions)
	ctx:   Context, // ``state_machine.node`` of directives among the children
	subst: bool,    // inside a substitution definition
}

@(private = "file")
collect_document :: proc(c: ^Collector, doc: ^rst.Node) {
	c.title_styles = make([dynamic]Style, 0, 8, c.messages.allocator)
	w := Walk{ctx = .Root}
	for n := doc.first; n != nil; n = n.next {
		if n.kind == .Section_Title {
			section_title(c, n)
		} else {
			collect(c, n, w)
		}
	}
}

@(private = "file")
collect :: proc(c: ^Collector, n: ^rst.Node, w: Walk) {
	line := int(n.line) if n.line > 0 else w.line
	#partial switch n.kind {
	case .System_Message:
		add_message(c, n)
		return
	case .Problematic:
		append(&c.messages, Message{line, int(n.num[0]), n.name})
		return
	case .Directive:
		run_directive(c, n, w)
		return
	case .Text:
		return
	}
	cw := Walk{line, w.delta, .Other, w.subst}
	#partial switch n.kind {
	case .Entry:
		cw.delta -= 1 // cells are nested-parsed with a 1-based offset
	case .Substitution_Definition:
		cw.delta += int(n.num[0])
		cw.subst = true
	}
	for ch := n.first; ch != nil; ch = ch.next do collect(c, ch, cw)
}

@(private = "file")
collect_children :: proc(c: ^Collector, n: ^rst.Node, w: Walk) {
	for ch := n.first; ch != nil; ch = ch.next do collect(c, ch, w)
}

@(private = "file")
add_message :: proc(c: ^Collector, n: ^rst.Node) {
	text := n.text
	if n.first != nil {
		// ``Element.astext()``: children joined by blank lines
		b := strings.builder_make(c.messages.allocator)
		strings.write_string(&b, text)
		for ch := n.first; ch != nil; ch = ch.next {
			strings.write_string(&b, "\n\n")
			strings.write_string(&b, ch.text if len(ch.text) > 0 else ch.raw)
		}
		text = strings.to_string(b)
	}
	append(&c.messages, Message{int(n.line), int(n.num[0]), text})
}

// ``RSTState.check_subsection`` at document level: title messages are
// reported first; an inconsistent title is dropped with an error.
@(private = "file")
section_title :: proc(c: ^Collector, n: ^rst.Node) {
	w := Walk{line = int(n.line), ctx = .Other}
	title := n.first
	if title != nil {
		for m := title.next; m != nil; m = m.next do collect(c, m, w)
	}
	style := Style{n = len(n.name)}
	for i in 0 ..< min(len(n.name), 2) do style.chars[i] = n.name[i]

	newlevel := len(c.title_styles) + 1
	for s, i in c.title_styles {
		if s == style {
			newlevel = i + 1
			break
		}
	}
	if newlevel > c.section_level + 1 {
		b := strings.builder_make(c.messages.allocator)
		fmt.sbprintf(&b, "Inconsistent title style: skip from level %d to %d.\n\n", c.section_level, newlevel)
		strings.write_string(&b, n.text)
		strings.write_string(&b, "\n\nEstablished title styles:")
		for s in c.title_styles {
			strings.write_byte(&b, ' ')
			strings.write_byte(&b, s.chars[0])
			if s.n == 2 {
				strings.write_byte(&b, '/')
				strings.write_byte(&b, s.chars[1])
			}
		}
		append(&c.messages, Message{int(n.line), rst.ERROR, strings.to_string(b)})
		return
	}
	c.section_level = newlevel
	if newlevel > len(c.title_styles) do append(&c.title_styles, style)
	if title != nil do collect(c, title, w)
}

// --- directives ----------------------------------------------------------------------

// Run the reStructuredText parts of a standard directive (see directives.odin).
@(private = "file")
run_directive :: proc(c: ^Collector, n: ^rst.Node, w: Walk) {
	spec, known := directive_spec(n.name)
	if !known do return
	info, has_info := n.extra.(^rst.Directive_Info)
	if !has_info || info == nil do return
	b, ok := parse_directive_block(info, spec)
	if !ok do return
	lineno := int(n.line)

	// the reporter's current line is the outermost machine's, which docutils
	// leaves at the end of the directive block while the directive runs
	saved_root_line := c.p.root_line
	if c.p.root_line == 0 do c.p.root_line = info.end_offset + 1
	defer c.p.root_line = saved_root_line

	has_content := len(b.content) > 0
	switch spec.kind {
	case .Admonition:
		if has_content do parse_content(c, &b, w, .Other)
	case .Generic_Admonition:
		if !has_content do return
		parse_title(c, b.arguments[0], lineno)
		parse_content(c, &b, w, .Other)
	case .Topic, .Sidebar:
		if w.ctx == .Other || !has_content do return
		if len(b.arguments) > 0 {
			parse_title(c, b.arguments[0], lineno)
			if subtitle, given := option_value(&b, "subtitle"); given do parse_title(c, subtitle, lineno)
		}
		parse_content(c, &b, w, .Sidebar if spec.kind == .Sidebar else .Other)
	case .Rubric:
		parse_title(c, b.arguments[0], lineno)
	case .Block_Quote:
		if !has_content do return
		out := rst.new_node(.Block_Quote, 0, c.p.allocator)
		sm := rst.make_state_machine(c.p, nil, 0, out)
		sm.line_delta = w.delta
		rst.block_quote(&sm, b.content, b.content_offset, out)
		collect_children(c, out, Walk{lineno, w.delta, .Other, false})
	case .Body:
		if !has_content do return
		if len(b.arguments) > 0 && !valid_class_value(b.arguments[0]) do return
		parse_content(c, &b, w, .Other)
	case .Parsed_Literal:
		if has_content do parse_title(c, strings.join(b.content, "\n", context.temp_allocator), lineno)
	case .Class:
		if !valid_class_value(b.arguments[0]) do return
		if has_content do parse_content(c, &b, w, .Anonymous)
	case .Replace:
		if w.subst && has_content do parse_content(c, &b, w, .Anonymous)
	case .Table:
		if !has_content do return
		if len(b.arguments) > 0 do parse_title(c, b.arguments[0], lineno)
		parse_content(c, &b, w, .Anonymous)
	case .Figure:
		if has_content do parse_content(c, &b, w, .Anonymous)
	case .Contents:
		if w.ctx != .Other && len(b.arguments) > 0 do parse_title(c, b.arguments[0], lineno)
	}
}

// ``state.nested_parse(content, content_offset, node)``
@(private = "file")
parse_content :: proc(c: ^Collector, b: ^Directive_Block, w: Walk, ctx: Context) {
	node := rst.new_node(.Block_Quote, 0, c.p.allocator) // anonymous container
	sm := rst.make_state_machine(c.p, nil, 0, node)
	sm.line_delta = w.delta
	rst.nested_parse(&sm, b.content, b.content_offset, node)
	collect_children(c, node, Walk{b.content_offset + 1, w.delta, ctx, false})
}

// ``state.inline_text(text, lineno)``
@(private = "file")
parse_title :: proc(c: ^Collector, text: string, lineno: int) {
	nodes := rst.parse_inline(c.p, text, lineno)
	w := Walk{line = lineno, ctx = .Other}
	for n := nodes.first; n != nil; n = n.next do collect(c, n, w)
}
