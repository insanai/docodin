package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

import "../../odin/check"
import pb "../../odin/publish"
import wr "../../odin/writers"

// Command-line parsing as docutils' ``OptionParser`` (``optparse``) does it:
// long options with ``=value`` or a separate value (unique prefixes accepted),
// short options with an attached or separate value, ``--`` ending the
// options, and at most two arguments, SOURCE and DESTINATION.  Usage errors
// are Elm-style reports with a hint.

Cli :: struct {
	writer_name: string,
	writer:      wr.Writer_Name,
	settings:    pb.Settings, // the defaults with the options applied
	overrides:   [dynamic]pb.Override, // the settings that differ from the defaults
	source:      string, // "" or "-": standard input
	warnings:    string, // ``--warnings`` file
	graphviz:    bool, // explicitly enable inline DOT rendering
	// the options (with their values) but ``--output-path``, for a run of
	// the Python front end with other positional arguments
	option_args: [dynamic]string,
	// the writer or options need docutils' Python front end
	needs:       [dynamic]pb.Python_Need,
}

USAGE_HEAD :: `Usage: docodin [--writer=NAME] [options] [SOURCE [DESTINATION]]
       docodin check [options] FILE...
       docodin pdf [options] SOURCE [OUTPUT.pdf]
       docodin book build [DIR] [-o OUTDIR] [--html] [--pdf] [--engine=NAME]
       docodin dod new|list|index|check [options]
       docodin sphinx [sphinx-build options] SOURCEDIR OUTPUTDIR

Convert reStructuredText into HTML5, LaTeX, XeLaTeX, Docutils XML or
pseudo-XML, exactly as docutils 0.22 does, without Python.  Reads SOURCE
(default: standard input, also "-") and writes DESTINATION (default: standard
output).  The programs rst2html, rst2latex, rst2xetex, rst2xml and
rst2pseudoxml, and the commands html, latex, xetex, xml and pseudoxml, select
the writer.  Configuration files are not read.

"docodin book build" builds a Sphinx project (HTML site and PDF book) and
"docodin dod" manages DocOdin Discussions (design records); see
"docodin book --help" and "docodin dod --help".  "docodin sphinx" runs
sphinx-build in Python, parsing with docodin ("python -m docodin sphinx").
`

parse_command_line :: proc(args: []string, default_writer: string) -> Cli {
	cli := Cli {
		writer_name = find_writer(args, default_writer),
	}
	w, ok := pb.writer_of(cli.writer_name)
	if !ok {
		// ``writers.get_writer_class`` imports a module of that name: the
		// options are those of the Python writer
		append(&cli.needs, pb.Python_Need{feature = .Writer, detail = cli.writer_name})
		return cli
	}
	cli.writer = w
	cli.settings = pb.default_settings(w, pb.tools_docutils_dir())
	positional := make([dynamic]string)
	parse_options(&cli, args, &positional)
	set_positional(&cli, positional[:])
	cli.overrides = changed_settings(&cli)
	return cli
}

// The ``--writer`` value (a first pass, as ``docutils`` makes).
@(private = "file")
find_writer :: proc(args: []string, default_writer: string) -> string {
	writer := default_writer
	for i := 0; i < len(args); i += 1 {
		if args[i] == "--" do break
		if strings.has_prefix(args[i], "--writer=") do writer = args[i][len("--writer="):]
		if args[i] == "--writer" && i + 1 < len(args) {
			writer = args[i + 1]
			i += 1
		}
	}
	return writer
}

@(private = "file")
parse_options :: proc(cli: ^Cli, args: []string, positional: ^[dynamic]string) {
	for i := 0; i < len(args); i += 1 {
		arg := args[i]
		if arg == "--" {
			append(positional, ..args[i + 1:])
			return
		}
		if !strings.has_prefix(arg, "-") || arg == "-" {
			append(positional, arg)
			continue
		}
		name, value, has_value := split_option(arg)
		o := lookup_option(cli, name)
		if o.dest != "output_path" do append(&cli.option_args, arg)
		if takes_value(o) && !has_value {
			if i + 1 >= len(args) do missing_value(name, o)
			i += 1
			value, has_value = args[i], true
			if o.dest != "output_path" do append(&cli.option_args, value)
		} else if !takes_value(o) && has_value {
			usage_error("UNEXPECTED VALUE", fmt.tprintf("The option `%s` takes no value.", name),
				fmt.tprintf("Write `%s` alone.", name))
		}
		apply_option(cli, o, name, value)
	}
}

// ``--name=value``, ``-Xvalue`` or a flag.
@(private = "file")
split_option :: proc(arg: string) -> (name, value: string, has_value: bool) {
	if strings.has_prefix(arg, "--") {
		if eq := strings.index_byte(arg, '='); eq >= 0 do return arg[:eq], arg[eq + 1:], true
		return arg, "", false
	}
	if len(arg) > 2 do return arg[:2], arg[2:], true
	return arg, "", false
}

// The option of ``name``: the exact name, else the only long option it
// abbreviates (``optparse``).
@(private = "file")
lookup_option :: proc(cli: ^Cli, name: string) -> ^Option {
	if o := find_option(name, cli.writer); o != nil do return o
	if strings.has_prefix(name, "--") && len(name) > 2 {
		matches := make([dynamic]string, context.temp_allocator)
		for &o in OPTIONS {
			if o.writers != {} && cli.writer not_in o.writers do continue
			for n in word_list(o.names) {
				if strings.has_prefix(n, name) && !slice.contains(matches[:], n) {
					append(&matches, n)
				}
			}
		}
		if len(matches) == 1 do return find_option(matches[0], cli.writer)
		if len(matches) > 1 {
			text := fmt.tprintf("The option `%s` is ambiguous.", name)
			hint := fmt.tprintf("Write one of %s in full.", quoted_list(matches[:]))
			usage_error("AMBIGUOUS OPTION", text, hint)
		}
	}
	unknown_option(name, cli)
}

@(private = "file")
apply_option :: proc(cli: ^Cli, o: ^Option, name, value: string) {
	switch o.action {
	case .Store:
		store_value(cli, o, name, value)
	case .Append:
		check_choice(o, name, value)
		append_items(cli, o, name, value)
	case .Store_True, .Store_False, .Store_Const, .No_Source_Link:
		apply_flag(cli, o)
	case .Warnings:
		cli.warnings = value
	case .Graphviz:
		cli.graphviz = true
	case .Ignore:
	case .Unsupported:
		append(&cli.needs, pb.Python_Need{feature = .Option, detail = name})
	case .Help:
		print_help(cli)
		os.exit(0)
	case .Version:
		fmt.printfln("docodin %s (Docutils %s, native)", VERSION, wr.DOCUTILS_VERSION)
		os.exit(0)
	}
}

// ``action="store"``: the value converted by the setting's validator.
@(private = "file")
store_value :: proc(cli: ^Cli, o: ^Option, name, value: string) {
	if o.dest == "" do return // --writer (see ``find_writer``)
	check_choice(o, name, value)
	if err := pb.set_validated(&cli.settings, cli.writer, o.dest, value); err != "" {
		invalid_value(name, value, err, word_list(o.choices))
	}
	if o.overrides != "" do cli.settings[o.overrides] = pb.None{}
	// ``validate_encoding_and_error_handler`` looks the codec up
	if pb.validator_of(o.dest, cli.writer) == .Encoding {
		encoding, _ := cli.settings[o.dest].(string)
		if !pb.native_codec(encoding) {
			append(&cli.needs, pb.Python_Need{feature = .Codec, detail = encoding})
		}
	}
}

@(private = "file")
apply_flag :: proc(cli: ^Cli, o: ^Option) {
	s := &cli.settings
	#partial switch o.action {
	case .Store_True, .Store_False:
		s[o.dest] = o.action == .Store_True
	case .Store_Const:
		s[o.dest] = const_value(o.const)
	case .No_Source_Link:
		s["source_link"] = pb.None{}
		s["source_url"] = pb.None{}
	}
}

@(private = "file")
const_value :: proc(c: Const) -> pb.Value {
	switch v in c {
	case pb.None:
		return v
	case bool:
		return v
	case int:
		return v
	case string:
		return v
	}
	return pb.None{}
}

// ``action="append"``: the validated items added to the setting's list
// (the default list too, as ``optparse`` extends it).
@(private = "file")
append_items :: proc(cli: ^Cli, o: ^Option, name, value: string) {
	items, err := pb.validate(pb.validator_of(o.dest, cli.writer), value)
	if err != "" do invalid_value(name, value, err, word_list(o.choices))
	list := make([dynamic]string)
	if old, is_list := cli.settings[o.dest].([]string); is_list do append(&list, ..old)
	if new, is_list := items.([]string); is_list do append(&list, ..new)
	cli.settings[o.dest] = list[:]
}

@(private = "file")
check_choice :: proc(o: ^Option, name, value: string) {
	if o.choices != "" && !has_word(o.choices, value) {
		invalid_value(name, value, "", word_list(o.choices))
	}
}

// SOURCE and DESTINATION (``OptionParser.check_args``).
@(private = "file")
set_positional :: proc(cli: ^Cli, args: []string) {
	if len(args) > 2 {
		text := fmt.tprintf("Maximum 2 arguments allowed, not %d: %s.", len(args),
			quoted_list(args))
		usage_error("TOO MANY ARGUMENTS", text,
			"Give one SOURCE and at most one DESTINATION; the other options start with `-`.")
	}
	if len(args) == 0 do return
	cli.source = args[0]
	if len(args) < 2 || args[1] == "-" do return
	if args[1] == args[0] {
		usage_error("SAME SOURCE AND DESTINATION",
			"Do not specify the same file for both source and destination.  It will clobber " +
			"the source file.", "Name another DESTINATION.")
	}
	given, has := cli.settings["output_path"].(string)
	if has && given != "" && given != args[1] {
		usage_error("TWO DESTINATIONS",
			"The --output-path option obsoletes the second positional argument (DESTINATION). " +
			"You cannot use them together.", "Drop one of them.")
	}
	cli.settings["output_path"] = args[1]
}

// The settings that differ from the writer's defaults, as overrides.
changed_settings :: proc(cli: ^Cli) -> [dynamic]pb.Override {
	defaults := pb.default_settings(cli.writer, pb.tools_docutils_dir())
	out := make([dynamic]pb.Override)
	for name, v in cli.settings {
		if d, ok := defaults[name]; ok && same_value(d, v) do continue
		append(&out, pb.Override{name, v})
	}
	return out
}

@(private = "file")
same_value :: proc(a, b: pb.Value) -> bool {
	switch x in a {
	case []string:
		y, ok := b.([]string)
		return ok && slice.equal(x, y)
	case pb.None:
		_, ok := b.(pb.None)
		return ok
	case bool:
		y, ok := b.(bool)
		return ok && x == y
	case int:
		y, ok := b.(int)
		return ok && x == y
	case string:
		y, ok := b.(string)
		return ok && x == y
	}
	return b == nil
}

// --- help --------------------------------------------------------------------------------

@(private = "file")
print_help :: proc(cli: ^Cli) {
	b := strings.builder_make()
	strings.write_string(&b, USAGE_HEAD)
	fmt.sbprintf(&b, "\nOptions (writer %s; `--help --writer=NAME` lists another's):\n",
		cli.writer_name)
	for &o in OPTIONS {
		if o.writers != {} && cli.writer not_in o.writers do continue
		write_option_help(&b, &o)
	}
	fmt.print(strings.to_string(b))
}

@(private = "file")
write_option_help :: proc(b: ^strings.Builder, o: ^Option) {
	start := strings.builder_len(b^)
	strings.write_string(b, "  ")
	for n, i in word_list(o.names) {
		if i > 0 do strings.write_string(b, ", ")
		strings.write_string(b, n)
	}
	if o.metavar != "" do fmt.sbprintf(b, "=%s", o.metavar)
	if o.help == "" {
		strings.write_byte(b, '\n')
		return
	}
	width := strings.builder_len(b^) - start
	if width > 28 {
		strings.write_byte(b, '\n')
		width = 0
	}
	col := width
	rest := o.help
	for word in strings.fields_iterator(&rest) {
		if col + 1 + len(word) > HELP_WIDTH && col > HELP_INDENT {
			strings.write_byte(b, '\n')
			col = 0
		}
		for col < HELP_INDENT {
			strings.write_byte(b, ' ')
			col += 1
		}
		if col > HELP_INDENT {
			strings.write_byte(b, ' ')
			col += 1
		}
		strings.write_string(b, word)
		col += len(word)
	}
	strings.write_byte(b, '\n')
}

@(private = "file")
HELP_INDENT :: 30
@(private = "file")
HELP_WIDTH :: 79

// --- usage errors ------------------------------------------------------------------------

// An Elm-style usage report on standard error; exit status 2 (as
// ``optparse``).
usage_error :: proc(title, text, hint: string) -> ! {
	b := strings.builder_make()
	check.format_report(&b, title, "docodin", text, hint, use_color("auto"))
	os.write_string(os.stderr, strings.to_string(b))
	os.exit(2)
}

unknown_option :: proc(name: string, cli: ^Cli) -> ! {
	text := fmt.tprintf("I do not know the option `%s`.", name)
	hint := "Run `docodin --help` to see the options."
	if cli != nil {
		if ws := option_writers(name); ws != {} {
			text = fmt.tprintf("The option `%s` is not an option of the %s writer.", name,
				cli.writer_name)
			plural := "s" if card(ws) > 1 else ""
			hint = fmt.tprintf(
				"It is an option of the %s writer%s; choose one with `--writer=%s`.",
				writer_list(ws), plural, first_writer(ws),
			)
		} else if near := nearest_option(name, cli.writer); near != "" {
			hint = fmt.tprintf("Did you mean `%s`?  Run `docodin --help` to see the options.",
				near)
		}
	}
	usage_error("UNKNOWN OPTION", text, hint)
}

@(private = "file")
missing_value :: proc(name: string, o: ^Option) -> ! {
	text := fmt.tprintf("The option `%s` needs a value.", name)
	hint := fmt.tprintf("Write `%s=%s`.", name, o.metavar)
	if o.choices != "" {
		hint = fmt.tprintf("%s  One of: %s.", hint, quoted_list(word_list(o.choices)))
	}
	usage_error("MISSING VALUE", text, hint)
}

invalid_value :: proc(name, value, err: string, choices: []string) -> ! {
	text := fmt.tprintf("`%s=%s` is not valid.", name, value)
	if err != "" do text = fmt.tprintf("%s\n\n    %s", text, err)
	hint := "See `docodin --help` for the values."
	if len(choices) > 0 do hint = fmt.tprintf("Use one of %s.", quoted_list(choices))
	usage_error("INVALID VALUE", text, hint)
}

@(private = "file")
quoted_list :: proc(items: []string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for s, i in items {
		if i > 0 do strings.write_string(&b, ", ")
		fmt.sbprintf(&b, "`%s`", s)
	}
	return strings.to_string(b)
}

@(private = "file")
writer_list :: proc(ws: Writers) -> string {
	names := make([dynamic]string, context.temp_allocator)
	for w in ws do append(&names, WRITER_NAMES[w])
	return strings.join(names[:], " and ", context.temp_allocator)
}

@(private = "file")
first_writer :: proc(ws: Writers) -> string {
	for w in ws do return WRITER_NAMES[w]
	return "html5"
}

@(private = "file")
WRITER_NAMES := [wr.Writer_Name]string {
	.Pseudoxml = "pseudoxml",
	.Xml       = "xml",
	.Html5     = "html5",
	.Latex     = "latex",
	.Xetex     = "xetex",
}

// The option name closest to ``name`` (edit distance at most 3; "" if none).
@(private = "file")
nearest_option :: proc(name: string, writer: wr.Writer_Name) -> string {
	best, best_distance := "", 4
	for o in OPTIONS {
		if o.writers != {} && writer not_in o.writers do continue
		for n in word_list(o.names) {
			if d := edit_distance(name, n); d < best_distance do best, best_distance = n, d
		}
	}
	return best
}

@(private = "file")
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
