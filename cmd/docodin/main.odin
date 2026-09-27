package main

import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strings"

import rst "../../odin/rst"

VERSION :: "0.2.0"

USAGE :: `Usage: docodin [command] [options] <input.rst> [-o output]

Native reStructuredText compiler and toolchain written in Odin.

Commands:
  html     Render reST to standalone HTML5 (default if output is .html)
  latex    Render reST to LaTeX 2e (default if output is .tex)
  pdf      Render reST directly to PDF via MacTeX (pdflatex / xelatex)
  check    Check reST file(s) for markup errors

Options:
  -o, --output=PATH       Output destination file path
  --title=TITLE           Document title override (default: from first heading or conf.py)
  --author=AUTHOR         Document author (default: from conf.py or empty)
  --date=DATE             Document date (for LaTeX)
  --no-standalone         Emit HTML/LaTeX body fragment without page/document wrapper
  --no-css                Do not embed default CSS stylesheet in HTML
  --engine=NAME           TeX engine: pdflatex or xelatex (default: auto-detected)
  -v, --version           Print version and exit
  -h, --help              Print this help and exit

If input is in a directory with a Sphinx 'conf.py', project metadata (title, author)
is automatically extracted from conf.py unless explicitly overridden.
`

Command :: enum {
	Auto,
	Html,
	Latex,
	Pdf,
	Check,
}

Config :: struct {
	cmd:         Command,
	input_path:  string,
	output_path: string,
	title:       string,
	author:      string,
	date:        string,
	standalone:  bool,
	embed_css:   bool,
	engine:      string,
}

main :: proc() {
	cfg := Config{
		cmd         = .Auto,
		standalone  = true,
		embed_css   = true,
	}

	args := os.args[1:]
	if len(args) == 0 {
		fmt.print(USAGE)
		os.exit(0)
	}

	pos_args := make([dynamic]string, context.temp_allocator)

	for i := 0; i < len(args); i += 1 {
		arg := args[i]
		if arg == "-h" || arg == "--help" {
			fmt.print(USAGE)
			os.exit(0)
		} else if arg == "-v" || arg == "--version" {
			fmt.printf("docodin %s (native toolchain)\n", VERSION)
			os.exit(0)
		} else if arg == "html" && len(pos_args) == 0 {
			cfg.cmd = .Html
		} else if arg == "latex" && len(pos_args) == 0 {
			cfg.cmd = .Latex
		} else if arg == "pdf" && len(pos_args) == 0 {
			cfg.cmd = .Pdf
		} else if arg == "check" && len(pos_args) == 0 {
			cfg.cmd = .Check
		} else if arg == "-o" && i + 1 < len(args) {
			i += 1
			cfg.output_path = args[i]
		} else if strings.has_prefix(arg, "--output=") {
			cfg.output_path = arg[len("--output="):]
		} else if strings.has_prefix(arg, "--title=") {
			cfg.title = arg[len("--title="):]
		} else if strings.has_prefix(arg, "--author=") {
			cfg.author = arg[len("--author="):]
		} else if strings.has_prefix(arg, "--date=") {
			cfg.date = arg[len("--date="):]
		} else if strings.has_prefix(arg, "--engine=") {
			cfg.engine = arg[len("--engine="):]
		} else if arg == "--no-standalone" {
			cfg.standalone = false
		} else if arg == "--no-css" {
			cfg.embed_css = false
		} else if !strings.has_prefix(arg, "-") {
			append(&pos_args, arg)
		} else {
			fmt.eprintf("docodin: unknown option '%s'\n", arg)
			os.exit(1)
		}
	}

	if len(pos_args) == 0 {
		fmt.eprintln("docodin: no input file specified.")
		os.exit(1)
	}

	cfg.input_path = pos_args[0]

	// If check command, run checker logic
	if cfg.cmd == .Check {
		run_checker(pos_args[:])
		return
	}

	// Auto-detect format from output extension if not explicitly set
	if cfg.cmd == .Auto {
		ext := strings.to_lower(filepath.ext(cfg.output_path), context.temp_allocator)
		if ext == ".html" || ext == ".htm" {
			cfg.cmd = .Html
		} else if ext == ".tex" {
			cfg.cmd = .Latex
		} else if ext == ".pdf" {
			cfg.cmd = .Pdf
		} else {
			cfg.cmd = .Html // default format
		}
	}

	// Read input file
	input_data, err := os.read_entire_file(cfg.input_path, context.allocator)
	if err != nil {
		fmt.eprintf("docodin: cannot read input file '%s': %v\n", cfg.input_path, os.error_string(err))
		os.exit(1)
	}

	// Check for conf.py in same directory or parent directory to extract project metadata
	extract_conf_py_metadata(&cfg)

	// Initialize arena for parse
	arena: virtual.Arena
	if a_err := virtual.arena_init_growing(&arena); a_err != nil {
		fmt.eprintln("docodin: out of memory")
		os.exit(2)
	}
	defer virtual.arena_destroy(&arena)
	alloc := virtual.arena_allocator(&arena)

	p := rst.Parser{
		allocator = alloc,
		settings  = rst.DEFAULT_SETTINGS,
	}

	doc, _, _ := rst.parse_text(&p, string(input_data), 0, true)

	switch cfg.cmd {
	case .Html:
		html_cfg := rst.Html_Config{
			title      = cfg.title,
			author     = cfg.author,
			standalone = cfg.standalone,
			embed_css  = cfg.embed_css,
		}
		result := rst.write_html(doc, &p, html_cfg)
		write_output(cfg.output_path, result)

	case .Latex:
		latex_cfg := rst.Latex_Config{
			title      = cfg.title,
			author     = cfg.author,
			date       = cfg.date,
			standalone = cfg.standalone,
		}
		result := rst.write_latex(doc, &p, latex_cfg)
		write_output(cfg.output_path, result)

	case .Pdf:
		compile_pdf(doc, &p, &cfg)

	case .Check, .Auto:
		// handled above
	}
}

write_output :: proc(path: string, content: string) {
	if len(path) == 0 || path == "-" {
		fmt.print(content)
		return
	}
	err := os.write_entire_file(path, content)
	if err != nil {
		fmt.eprintf("docodin: error writing output to '%s': %v\n", path, os.error_string(err))
		os.exit(1)
	}
	fmt.eprintf("docodin: generated '%s' (%d bytes)\n", path, len(content))
}

extract_conf_py_metadata :: proc(cfg: ^Config) {
	dir := filepath.dir(cfg.input_path)
	p1, _ := filepath.join([]string{dir, "conf.py"}, context.temp_allocator)
	p2, _ := filepath.join([]string{dir, "..", "conf.py"}, context.temp_allocator)
	conf_paths := [2]string{p1, p2}

	for cp in conf_paths {
		data, err := os.read_entire_file(cp, context.temp_allocator)
		if err == nil {
			content := string(data)
			if len(cfg.title) == 0 {
				if ht := extract_py_string_var(content, "html_title"); len(ht) > 0 {
					cfg.title = ht
				} else if proj := extract_py_string_var(content, "project"); len(proj) > 0 {
					cfg.title = proj
				}
			}
			if len(cfg.author) == 0 {
				if auth := extract_py_string_var(content, "author"); len(auth) > 0 {
					cfg.author = auth
				}
			}
			break
		}
	}
}

Prefix_Quote :: struct {
	p: string,
	q: byte,
}

extract_py_string_var :: proc(content: string, var_name: string) -> string {
	lines := strings.split_lines(content, context.temp_allocator)
	prefixes := [4]Prefix_Quote{
		{strings.concatenate({var_name, " = '"}, context.temp_allocator), '\''},
		{strings.concatenate({var_name, " = \""}, context.temp_allocator), '"'},
		{strings.concatenate({var_name, "='"}, context.temp_allocator), '\''},
		{strings.concatenate({var_name, "=\""}, context.temp_allocator), '"'},
	}

	for line in lines {
		trimmed := strings.trim_space(line)
		for pq in prefixes {
			if strings.has_prefix(trimmed, pq.p) {
				rest := trimmed[len(pq.p):]
				end_idx := strings.index_byte(rest, pq.q)
				if end_idx >= 0 {
					return rest[:end_idx]
				}
			}
		}
	}
	return ""
}

find_tex_binary :: proc(preferred: string) -> (path: string, ok: bool) {
	candidates := make([dynamic]string, context.temp_allocator)
	if len(preferred) > 0 {
		append(&candidates, preferred)
		pref_path, _ := filepath.join([]string{"/Library/TeX/texbin", preferred}, context.temp_allocator)
		append(&candidates, pref_path)
	}
	append(&candidates, "/Library/TeX/texbin/xelatex")
	append(&candidates, "/Library/TeX/texbin/pdflatex")
	append(&candidates, "xelatex")
	append(&candidates, "pdflatex")

	for c in candidates {
		if os.is_file(c) {
			return c, true
		}
	}
	if len(preferred) > 0 do return preferred, true
	return "pdflatex", true
}

compile_pdf :: proc(doc: ^rst.Node, p: ^rst.Parser, cfg: ^Config) {
	out_pdf := cfg.output_path
	if len(out_pdf) == 0 {
		ext := filepath.ext(cfg.input_path)
		stem := cfg.input_path[:len(cfg.input_path) - len(ext)]
		base := filepath.base(stem)
		out_pdf = strings.concatenate({base, ".pdf"}, context.temp_allocator)
	}

	tex_bin, found_tex := find_tex_binary(cfg.engine)
	if !found_tex {
		fmt.eprintln("docodin: could not find TeX engine (xelatex/pdflatex) in /Library/TeX/texbin or PATH")
		os.exit(1)
	}

	latex_cfg := rst.Latex_Config{
		title      = cfg.title,
		author     = cfg.author,
		date       = cfg.date,
		standalone = true,
	}
	tex_content := rst.write_latex(doc, p, latex_cfg)

	out_dir := filepath.dir(out_pdf)
	if len(out_dir) == 0 do out_dir = "."
	pdf_ext := filepath.ext(out_pdf)
	pdf_stem := out_pdf[:len(out_pdf) - len(pdf_ext)]
	base_name := filepath.base(pdf_stem)

	tex_filename := strings.concatenate({base_name, ".tex"}, context.temp_allocator)
	tmp_tex, _ := filepath.join([]string{out_dir, tex_filename}, context.temp_allocator)

	err := os.write_entire_file(tmp_tex, tex_content)
	if err != nil {
		fmt.eprintf("docodin: failed to write intermediate LaTeX file '%s': %v\n", tmp_tex, os.error_string(err))
		os.exit(1)
	}

	fmt.eprintf("docodin: compiling PDF via MacTeX (%s)...\n", tex_bin)

	cmd_args := []string{
		tex_bin,
		"-interaction=nonstopmode",
		"-halt-on-error",
		strings.concatenate({"-output-directory=", out_dir}, context.temp_allocator),
		tmp_tex,
	}

	desc := os.Process_Desc{
		command = cmd_args,
	}

	state, _, _, exec_err := os.process_exec(desc, context.allocator)
	if exec_err != nil || !state.success {
		fmt.eprintf("docodin: TeX compilation failed (exit code %d)\n", state.exit_code)
		os.exit(1)
	}

	// Second pass for labels/crossrefs
	state2, _, _, exec_err2 := os.process_exec(desc, context.allocator)
	if exec_err2 != nil || !state2.success {
		fmt.eprintf("docodin: TeX second pass compilation failed (exit code %d)\n", state2.exit_code)
		os.exit(1)
	}

	// Clean auxiliary files
	exts := [4]string{".aux", ".log", ".out", ".toc"}
	for ext in exts {
		aux_name := strings.concatenate({base_name, ext}, context.temp_allocator)
		aux_file, _ := filepath.join([]string{out_dir, aux_name}, context.temp_allocator)
		os.remove(aux_file)
	}

	fmt.eprintf("docodin: successfully generated PDF '%s'\n", out_pdf)
}

run_checker :: proc(files: []string) {
	for f in files {
		data, err := os.read_entire_file(f, context.allocator)
		if err != nil {
			fmt.eprintf("docodin: cannot read %s: %v\n", f, os.error_string(err))
			continue
		}
		p := rst.Parser{
			allocator = context.allocator,
			settings  = rst.DEFAULT_SETTINGS,
		}
		doc, _, _ := rst.parse_text(&p, string(data), 0, true)
		has_errors := false
		for n := doc.first; n != nil; n = n.next {
			if n.kind == .System_Message {
				fmt.eprintf("%s:%d: (%s) %s\n", f, n.line, n.name, n.text)
				has_errors = true
			}
		}
		if !has_errors {
			fmt.printf("%s: OK\n", f)
		}
	}
}
