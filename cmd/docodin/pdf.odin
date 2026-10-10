package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

import pb "../../odin/publish"

// ``docodin pdf``: the LaTeX writer's output compiled with a TeX engine
// (pdflatex with the latex writer; xelatex or lualatex with the xetex
// writer), twice for the cross references.

PDF_USAGE :: `Usage: docodin pdf [--engine=NAME] [options] SOURCE [OUTPUT.pdf]

Write SOURCE with the latex writer (the xetex writer for xelatex and
lualatex) to OUTPUT.tex and compile it to OUTPUT.pdf (default: the name of
SOURCE in the current directory).  The options are those of
"docodin --writer=latex" (see "docodin --help --writer=latex").

Options:
  --engine=NAME   pdflatex (default if installed), xelatex or lualatex
`

@(private = "file")
TEX_DIRS := [?]string{"/Library/TeX/texbin", "/usr/local/texlive/bin", "/usr/bin"}

run_pdf :: proc(args: []string) -> int {
	engine, rest := split_engine(args)
	if slice_has(rest, "-h") || slice_has(rest, "--help") {
		fmt.print(PDF_USAGE)
		return 0
	}
	if engine == "" do engine = default_engine()
	name := strings.trim_suffix(filepath.base(engine), ".exe")
	writer := "xetex" if name == "xelatex" || name == "lualatex" else "latex"
	cli := parse_command_line(rest, writer)
	if cli.source == "" || cli.source == "-" {
		usage_error("MISSING SOURCE", "`docodin pdf` needs a source file.",
			"Write `docodin pdf doc.rst` (or `docodin pdf doc.rst out.pdf`).")
	}
	pdf := setting_string(&cli, "output_path", "")
	if pdf == "" do pdf = strings.concatenate({filepath.stem(cli.source), ".pdf"})
	dir := filepath.dir(pdf)
	tex, _ := filepath.join({dir, strings.concatenate({filepath.stem(pdf), ".tex"})})
	cli.settings["output_path"] = tex
	cli.overrides = changed_settings(&cli)
	if status := write_latex(&cli, writer, tex); status != 0 do return status
	return compile_pdf(engine, tex, dir, pdf)
}

@(private = "file")
split_engine :: proc(args: []string) -> (engine: string, rest: []string) {
	out := make([dynamic]string)
	for arg in args {
		if strings.has_prefix(arg, "--engine=") {
			engine = arg[len("--engine="):]
			continue
		}
		append(&out, arg)
	}
	return engine, out[:]
}

@(private = "file")
slice_has :: proc(items: []string, s: string) -> bool {
	for it in items do if it == s do return true
	return false
}

// pdflatex if it is installed, else xelatex.
@(private = "file")
default_engine :: proc() -> string {
	if _, ok := find_tex("pdflatex"); ok do return "pdflatex"
	return "xelatex"
}

// The engine's path: a TeX directory or the PATH.
@(private = "file")
find_tex :: proc(engine: string) -> (string, bool) {
	if strings.contains_rune(engine, '/') do return engine, os.is_file(engine)
	for dir in TEX_DIRS {
		p, _ := filepath.join({dir, engine})
		if os.is_file(p) do return p, true
	}
	path := os.get_env("PATH", context.temp_allocator)
	for dir in strings.split(path, ":", context.temp_allocator) {
		p, _ := filepath.join({dir, engine})
		if os.is_file(p) do return p, true
	}
	return engine, false
}

// Publish the LaTeX source to ``tex`` (messages to standard error).
@(private = "file")
write_latex :: proc(cli: ^Cli, writer, tex: string) -> int {
	if cli.graphviz && len(cli.needs) > 0 do return graphviz_python_error()
	if len(cli.needs) > 0 do return python_latex(cli, writer, tex, cli.needs[:])
	data, read_ok := read_input(cli.source)
	if !read_ok do return 1
	text, need, ok := decode_source(data, cli)
	if n, needed := need.?; needed do return python_latex(cli, writer, tex, {n})
	if !ok do return 1
	output, _, messages, status, err, needs := pb.publish(text, cli.source, cli.writer_name,
		cli.overrides[:], native_options(cli))
	if len(needs) > 0 {
		if cli.graphviz do return graphviz_python_error()
		return python_latex(cli, writer, tex, needs, text)
	}
	for m in messages do os.write_string(os.stderr, m.text)
	if err != nil {
		os.write_string(os.stderr, pb.error_report(err))
		return max(status, 1)
	}
	if werr := os.write_entire_file(tex, pb.encode_output(output, cli.settings)); werr != nil {
		fmt.eprintf("docodin: cannot write %s: %s\n", tex, os.error_string(werr))
		return 1
	}
	return 0
}

// The LaTeX source written by ``python -m docodin`` with the same options
// (a document that needs Python).
@(private = "file")
python_latex :: proc(
	cli: ^Cli,
	writer, tex: string,
	needs: []pb.Python_Need,
	text := "",
) -> int {
	args := make([dynamic]string)
	append(&args, ..cli.option_args[:])
	append(&args, "--", cli.source, tex)
	return python_fallback(args[:], writer, needs, nil, text, cli.source)
}

// Run the engine twice (labels and cross references), then remove the
// auxiliary files.
@(private = "file")
compile_pdf :: proc(engine, tex, dir, pdf: string) -> int {
	bin, found := find_tex(engine)
	if !found {
		usage_error("TEX ENGINE NOT FOUND", fmt.tprintf("I cannot find `%s`.", engine),
			"Install TeX Live (or MacTeX), or name the engine with `--engine=PATH`.")
	}
	out_dir := dir if dir != "" else "."
	desc := os.Process_Desc {
		command = {bin, "-interaction=nonstopmode", "-halt-on-error",
			strings.concatenate({"-output-directory=", out_dir}), tex},
	}
	for pass in 1 ..= 2 {
		state, stdout, _, exec_err := os.process_exec(desc, context.allocator)
		if exec_err != nil || !state.success {
			fmt.eprintf("docodin: %s failed (pass %d, exit code %d)\n", engine, pass,
				state.exit_code)
			os.write(os.stderr, stdout)
			return 1
		}
	}
	stem := filepath.stem(tex)
	for ext in ([]string{".aux", ".log", ".out", ".toc"}) {
		aux, _ := filepath.join({out_dir, strings.concatenate({stem, ext})})
		os.remove(aux)
	}
	fmt.eprintf("docodin: wrote %s\n", pdf)
	return 0
}
