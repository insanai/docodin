package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"

import "../../odin/check"
import "../../odin/dod"

// ``docodin dod``: DocOdin Discussions, the numbered design records of
// docs/dod.

DOD_USAGE :: `Usage: docodin dod new "Title" [--number=N] [--labels=a,b] [--dir=DIR]
       docodin dod list [--state=STATE] [--label=LABEL] [--dir=DIR]
       docodin dod index [--dir=DIR]
       docodin dod check [--dir=DIR] [--error-format=FORMAT] [--color=WHEN]

Manage the DocOdin Discussions (DOD) in DIR (default: docs/dod).

  new     create NNNN-slug.rst from the template: the next free number (the
          records' and the dod/NNNN git branches'), the author from git's
          configuration, today's date, the state "prediscussion"
  list    a table of the records
  index   rewrite the records by state in index.rst (between the comments
          ".. dod-index-start" and ".. dod-index-end")
  check   check the file names, titles, fields, states, labels, dates,
          numbers and the index
`

@(private = "file")
Dod_Options :: struct {
	command: string,
	dir:     string,
	title:   string,
	number:  int, // 0: the next one
	labels:  string,
	state:   string,
	label:   string,
	format:     check.Error_Format,
	color:      bool,
	color_mode: string, // --color
}

run_dod :: proc(args: []string) -> int {
	opts := parse_dod_args(args)
	records, ok := dod.read_records(opts.dir)
	if !ok {
		usage_error("NO SUCH DIRECTORY", fmt.tprintf("I cannot read the directory `%s`.",
			opts.dir), "Name the DOD directory with `--dir=docs/dod`.")
	}
	switch opts.command {
	case "new":
		return dod_new(&opts, records)
	case "list":
		return dod_list(&opts, records)
	case "index":
		return dod_index(&opts, records)
	}
	return dod_check(&opts, records)
}

@(private = "file")
dod_new :: proc(opts: ^Dod_Options, records: []dod.Record) -> int {
	for l in split_labels(opts.labels) {
		if !slice.contains(dod.LABELS[:], l) {
			invalid_value("--labels", l, "", dod.LABELS[:])
		}
	}
	number := opts.number if opts.number > 0 else dod.next_number(opts.dir, records)
	for r in records {
		if r.number == number {
			usage_error("NUMBER TAKEN", fmt.tprintf("DOD %d is %s already.", number, r.file),
				"Leave out `--number` to take the next free number.")
		}
	}
	template := dod.DEFAULT_TEMPLATE
	template_path := join_path(opts.dir, dod.TEMPLATE_NAME)
	if data, err := os.read_entire_file_from_path(template_path, context.allocator); err == nil {
		template = string(data)
	}
	slug := dod.make_slug(opts.title)
	name := fmt.tprintf("%s-%s.rst", dod.pad4(number), slug)
	path := join_path(opts.dir, name)
	text := dod.fill_record(template, {number, opts.title, strings.join(split_labels(opts.labels),
		", "), dod.git_author(opts.dir), dod.today()})
	if err := os.write_entire_file(path, text); err != nil {
		fmt.eprintf("docodin: cannot write %s: %s\n", path, os.error_string(err))
		return 1
	}
	fmt.printf("Created %s (DOD %d: %s).\n\nNext steps:\n", path, number, opts.title)
	fmt.printf("  1. git switch -c dod/%s\n", dod.pad4(number))
	fmt.printf("  2. Write the Summary, Background and Proposal; set :Labels: and :Discussion:.\n")
	fmt.printf("  3. docodin dod index --dir=%s && docodin dod check --dir=%s\n", opts.dir,
		opts.dir)
	fmt.printf("  4. docodin book build %s, then open a pull request for discussion.\n", opts.dir)
	return 0
}

@(private = "file")
dod_list :: proc(opts: ^Dod_Options, records: []dod.Record) -> int {
	rows := make([dynamic][5]string)
	append(&rows, [5]string{"DOD", "STATE", "CREATED", "TITLE", "LABELS"})
	for &r in records {
		if row, ok := list_row(opts, &r); ok do append(&rows, row)
	}
	widths: [5]int
	for row in rows do for cell, i in row do widths[i] = max(widths[i], len(cell))
	b := strings.builder_make()
	for row in rows {
		for cell, i in row {
			strings.write_string(&b, cell)
			if i == 4 do break
			for _ in len(cell) ..< widths[i] + 2 do strings.write_byte(&b, ' ')
		}
		strings.write_byte(&b, '\n')
	}
	if len(rows) == 1 do strings.write_string(&b, "(no records)\n")
	fmt.print(strings.to_string(b))
	return 0
}

// The row of a record, unless the filters leave it out.
@(private = "file")
list_row :: proc(opts: ^Dod_Options, r: ^dod.Record) -> ([5]string, bool) {
	if r.number <= 0 do return {}, false
	state := dod.field_value(r, "State")
	labels := dod.record_labels(r)
	if opts.state != "" && state != opts.state do return {}, false
	if opts.label != "" && !slice.contains(labels, opts.label) do return {}, false
	_, title, ok := dod.split_title(r.title)
	if !ok do title = r.title
	row := [5]string{dod.itoa(r.number), state, dod.field_value(r, "Created"), title,
		strings.join(labels, ", ")}
	return row, true
}

@(private = "file")
dod_index :: proc(opts: ^Dod_Options, records: []dod.Record) -> int {
	path := join_path(opts.dir, "index.rst")
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		usage_error("NO INDEX", fmt.tprintf("I cannot read `%s`.", path),
			"The DOD directory needs an index.rst with the index markers.")
	}
	text, found := dod.update_index(string(data), records)
	if !found {
		usage_error("NO INDEX MARKERS", fmt.tprintf("`%s` has no `%s` and `%s` comments.", path,
			dod.INDEX_START, dod.INDEX_END),
			"Put the two comments where the records by state belong.")
	}
	if text == string(data) {
		fmt.printf("%s is up to date.\n", path)
		return 0
	}
	if werr := os.write_entire_file(path, text); werr != nil {
		fmt.eprintf("docodin: cannot write %s: %s\n", path, os.error_string(werr))
		return 1
	}
	fmt.printf("Updated %s.\n", path)
	return 0
}

@(private = "file")
dod_check :: proc(opts: ^Dod_Options, records: []dod.Record) -> int {
	problems := dod.check_records(opts.dir, records)
	b := strings.builder_make()
	status := 0
	for p in problems {
		if p.level >= 3 do status = 1
		source := p.path
		m := check.Message{line = p.line, level = p.level, text = p.text}
		switch opts.format {
		case .Docutils:
			check.format_docutils(&b, source, m)
		case .Elm:
			src: check.Source_Lines
			if data, err := os.read_entire_file_from_path(p.path, context.allocator); err == nil {
				src = check.source_lines(string(data), 8)
			}
			location := source
			if p.line > 0 do location = fmt.tprintf("%s:%d", source, p.line)
			check.format_line_report(&b, p.title, location, p.text, src, p.line, p.hint,
				opts.color)
			strings.write_byte(&b, '\n')
		}
	}
	os.write_string(os.stderr, strings.to_string(b))
	if len(problems) == 0 {
		fmt.printf("%d records checked, no problems.\n", count_records(records))
	}
	return status
}

@(private = "file")
count_records :: proc(records: []dod.Record) -> int {
	n := 0
	for r in records do if r.number > 0 do n += 1
	return n
}

@(private = "file")
split_labels :: proc(s: string) -> []string {
	out := make([dynamic]string)
	rest := s
	for part in strings.split_iterator(&rest, ",") {
		if l := strings.trim_space(part); l != "" do append(&out, l)
	}
	return out[:]
}

// --- arguments ----------------------------------------------------------------------------

@(private = "file")
parse_dod_args :: proc(args: []string) -> Dod_Options {
	if len(args) == 0 || args[0] == "-h" || args[0] == "--help" {
		fmt.print(DOD_USAGE)
		os.exit(0 if len(args) > 0 else 2)
	}
	opts := Dod_Options {
		command    = args[0],
		dir        = "docs/dod",
		color_mode = "auto",
	}
	check_dod_command(opts.command)
	positional := make([dynamic]string)
	rest := args[1:]
	for i := 0; i < len(rest); i += 1 {
		key, sep, value := strings.partition(rest[i], "=")
		if strings.has_prefix(key, "--") && sep == "" && dod_takes_value(key) {
			if i + 1 >= len(rest) {
				usage_error("MISSING VALUE", fmt.tprintf("The option `%s` needs a value.", key),
					fmt.tprintf("Write `%s=VALUE`.", key))
			}
			i += 1
			value = rest[i]
		}
		if !dod_option(&opts, key, value) {
			if strings.has_prefix(rest[i], "-") {
				usage_error("UNKNOWN OPTION",
					fmt.tprintf("I do not know the option `%s`.", rest[i]),
					"Run `docodin dod --help` to see the options.")
			}
			append(&positional, rest[i])
		}
	}
	finish_dod_options(&opts, positional[:])
	opts.color = use_color(opts.color_mode)
	return opts
}

@(private = "file")
check_dod_command :: proc(command: string) {
	commands := []string{"new", "list", "index", "check"}
	if slice.contains(commands, command) do return
	hint := "The commands are `new`, `list`, `index` and `check`."
	for c in commands {
		if edit_distance(c, command) > 2 do continue
		hint = fmt.tprintf("Did you mean `dod %s`?  %s", c, hint)
	}
	usage_error("UNKNOWN COMMAND", fmt.tprintf("I do not know `docodin dod %s`.", command), hint)
}

@(private = "file")
dod_takes_value :: proc(key: string) -> bool {
	switch key {
	case "--dir", "--number", "--labels", "--state", "--label", "--error-format", "--color":
		return true
	}
	return false
}

@(private = "file")
dod_option :: proc(opts: ^Dod_Options, key, value: string) -> bool {
	switch key {
	case "-h", "--help":
		fmt.print(DOD_USAGE)
		os.exit(0)
	case "--dir":
		opts.dir, _ = filepath.clean(value)
	case "--number":
		n, ok := strconv.parse_int(value)
		if !ok || n <= 0 {
			invalid_value("--number", value, "A record number is a positive integer.", nil)
		}
		opts.number = n
	case "--labels":
		opts.labels = value
	case "--state":
		opts.state = choice_value(key, value, dod.STATES[:])
	case "--label":
		opts.label = choice_value(key, value, dod.LABELS[:])
	case "--error-format":
		opts.format = error_format(value)
	case "--color":
		opts.color_mode = value
	case:
		return false
	}
	return true
}

@(private = "file")
choice_value :: proc(key, value: string, choices: []string) -> string {
	if !slice.contains(choices, value) do invalid_value(key, value, "", choices)
	return value
}

@(private = "file")
finish_dod_options :: proc(opts: ^Dod_Options, positional: []string) {
	if opts.command == "new" {
		if len(positional) != 1 {
			usage_error("MISSING TITLE", "`docodin dod new` needs the title of the record.",
				"Write `docodin dod new \"Native Sphinx builder\"` (quote the title).")
		}
		opts.title = strings.trim_space(positional[0])
		if opts.title == "" || dod.make_slug(opts.title) == "" {
			usage_error("EMPTY TITLE", "The title has no words.",
				"Write `docodin dod new \"Native Sphinx builder\"`.")
		}
		return
	}
	if len(positional) > 0 {
		usage_error("UNEXPECTED ARGUMENT", fmt.tprintf("`docodin dod %s` takes no argument `%s`.",
			opts.command, positional[0]), "Name the directory with `--dir=DIR`.")
	}
}
