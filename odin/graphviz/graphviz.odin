package graphviz

import "core:fmt"
import "core:hash"
import "core:os"
import "core:path/filepath"
import "core:strings"

import dt "../doctree"
import rd "../reader"

// Sphinx-compatible inline DOT, explicitly enabled by a host. Plain
// docutils publication keeps its standard directive registry.
Renderer :: struct {
	directory: string, // persistent assets beside the host's output
	format:    string, // svg for HTML, pdf for TeX
	relative:  bool, // a standalone HTML file refers to its sibling assets
	themed:    bool, // native HTML hosts can switch the branded diagram palette
}

IMAGE_ATTRIBUTE :: "docodin_graphviz"

@(private = "file")
OPTIONS := [?]rd.Option_Spec {
	{"alt", rd.unchanged},
	{"caption", rd.unchanged},
	{"name", rd.unchanged},
	{"class", rd.class_option},
	{"align", align_option},
}

GRAPHVIZ := rd.Directive_Spec {
	has_content = true,
	option_spec = OPTIONS[:],
	run         = run_extension,
}

GRAPH := rd.Directive_Spec {
	required_arguments = 1,
	has_content        = true,
	option_spec        = OPTIONS[:],
	run                = run_extension,
}

DIGRAPH := GRAPH

@(private = "file")
DIRECTIVES := [?]rd.Registry_Entry {
	{"graphviz", &GRAPHVIZ},
	{"graph", &GRAPH},
	{"digraph", &DIGRAPH},
}

extension :: proc(renderer: ^Renderer) -> rd.Extension {
	return {directives = DIRECTIVES[:], data = renderer}
}

@(private = "file")
align_option :: proc(c: ^rd.Context, argument: Maybe(string)) -> (rd.Option_Value, string) {
	value := argument.? or_else ""
	if value == "left" || value == "center" || value == "right" do return value, ""
	return "", "alignment must be left, center or right"
}

@(private = "file")
run_extension :: proc(c: ^rd.Context, d: ^rd.Directive) -> (rd.Nodes, rd.Failure) {
	return run(c, d, (^Renderer)(c.extension.data)^)
}

run :: proc(c: ^rd.Context, d: ^rd.Directive, renderer: Renderer) -> (rd.Nodes, rd.Failure) {
	code := rd.content_text(c, d)
	if strings.trim_space(code) == "" {
		return nil, rd.directive_error(.WARNING, "Graphviz requires inline DOT content.")
	}
	if d.name == "graph" || d.name == "digraph" {
		code = strings.concatenate({d.name, " ", d.arguments[0], " {\n", code, "\n}"})
	}
	path, err := render(code, renderer)
	if err != "" do return nil, rd.directive_error(.ERROR, err)
	if renderer.relative do path, _ = filepath.join({"_graphviz", filepath.base(path)})
	out := figure(c, d, path, code)
	if renderer.themed && renderer.format == "svg" && adaptive(d) {
		dark, derr := render(dark_palette(code), renderer)
		if derr != "" do return nil, rd.directive_error(.ERROR, derr)
		doc := c.doc
		light := dt.first_child(doc, out[0])
		dt.list_append(doc, light, dt.K_CLASSES, "graphviz-light")
		image := image_node(c, d, dark, code)
		dt.list_append(doc, image, dt.K_CLASSES, "graphviz-dark")
		dt.insert_before(doc, light, image)
	}
	return out, nil
}

@(private = "file")
adaptive :: proc(d: ^rd.Directive) -> bool {
	for cl in rd.options_list(&d.options, "class") do if cl == "adaptive-diagram" do return true
	return false
}

// Opt-in branded diagrams retain blue/native, purple/Python, green/result
// and amber/review meanings while changing surface, text and line contrast.
@(private = "file")
dark_palette :: proc(code: string) -> string {
	colors := [?][2]string {
		{"white", "#111829"}, {"#18243D", "#E6EAF4"}, {"#CBD5E1", "#35445F"},
		{"#EFF4FF", "#1B2B48"}, {"#B3C6F7", "#577BB4"},
		{"#526B97", "#93ACD5"}, {"#425574", "#B3C2DC"},
		{"#F4F6FA", "#1B2537"}, {"#CDD5E2", "#4A5D7C"},
		{"#DBE7FF", "#203961"}, {"#7DA1ED", "#82AAEF"},
		{"#E5F5EE", "#153B32"}, {"#8DC9B0", "#60BA9D"},
		{"#FFF3E6", "#3F2D1B"}, {"#E3BB86", "#D5A365"},
		{"#EEE9FB", "#302346"}, {"#C0AEE7", "#AA8ED8"},
		{"#F7FAFF", "#141F33"}, {"#FAF8FF", "#211B34"}, {"#9CACCA", "#6682AD"},
	}
	text := code
	for pair in colors {
		from := strings.concatenate({"\"", pair[0], "\""})
		to := strings.concatenate({"\"", pair[1], "\""})
		text, _ = strings.replace_all(text, from, to)
	}
	return text
}

// The command is an argument vector, never a shell string. Assets are
// keyed by DOT content; a failed render cannot leave a valid cache entry.
render :: proc(code: string, renderer: Renderer) -> (path, err: string) {
	if renderer.format != "svg" && renderer.format != "pdf" {
		return "", "Graphviz output must be SVG or PDF."
	}
	if e := os.make_directory_all(renderer.directory); e != nil && !os.is_directory(renderer.directory) {
		return "", strings.concatenate({"Cannot create Graphviz directory: ", os.error_string(e)})
	}
	directory, _ := filepath.abs(renderer.directory)
	stem := fmt.tprintf("graphviz-%016x", hash.fnv64a(transmute([]u8)code))
	path, _ = filepath.join({directory, strings.concatenate({stem, ".", renderer.format})})
	if os.is_file(path) do return path, ""
	source, _ := filepath.join({directory, strings.concatenate({stem, ".dot"})})
	if e := os.write_entire_file(source, transmute([]u8)code); e != nil {
		return "", strings.concatenate({"Cannot write Graphviz source: ", os.error_string(e)})
	}
	work, werr := os.make_directory_temp(directory, "render-*", context.temp_allocator)
	if werr != nil do return "", "Cannot create Graphviz working directory."
	defer os.remove_all(work)
	source, _ = filepath.join({work, "input.dot"})
	if e := os.write_entire_file(source, transmute([]u8)code); e != nil {
		return "", "Cannot write temporary Graphviz source."
	}
	temporary, _ := filepath.join({work, strings.concatenate({"output.", renderer.format})})
	state, _, stderr, e := os.process_exec(os.Process_Desc {
		command = {"dot", strings.concatenate({"-T", renderer.format}), "-o", temporary, source},
	}, context.temp_allocator)
	if e != nil || !state.success {
		os.remove(temporary)
		return "", strings.concatenate({"Graphviz failed; install Graphviz and check the DOT: ",
			strings.trim_space(string(stderr))})
	}
	if rename_err := os.rename(temporary, path); rename_err != nil {
		os.remove(temporary)
		return "", strings.concatenate({"Cannot save Graphviz output: ", os.error_string(rename_err)})
	}
	return path, ""
}

@(private = "file")
figure :: proc(c: ^rd.Context, d: ^rd.Directive, path, code: string) -> rd.Nodes {
	doc := c.doc
	image := image_node(c, d, path, code)
	node := dt.new_element(doc, .figure)
	dt.append_child(doc, node, image)
	align := rd.options_string(&d.options, "align")
	dt.set_attr(doc, node, "align", align if align != "" else "center")
	rd.d_set_source_line(c, d, node, d.lineno)
	rd.add_name(c, d, node)
	out := rd.result_of(c, node)
	if caption := rd.options_string(&d.options, "caption"); caption != "" {
		children, messages := rd.d_inline_text(c, d, caption, d.lineno)
		dt.append_child(doc, node, rd.element(c, .caption, caption, children[:]))
		append(&out, ..messages[:])
	}
	return out
}

@(private = "file")
image_node :: proc(c: ^rd.Context, d: ^rd.Directive, path, code: string) -> dt.Node {
	doc := c.doc
	image := dt.new_element(doc, .image)
	dt.set_attr(doc, image, "uri", path)
	dt.set_attr(doc, image, "width", "100%")
	alt := rd.options_string(&d.options, "alt")
	dt.set_attr(doc, image, "alt", alt if alt != "" else code)
	dt.set_attr(doc, image, IMAGE_ATTRIBUTE, true)
	dt.list_append(doc, image, dt.K_CLASSES, "graphviz")
	for cl in rd.options_list(&d.options, "class") do dt.list_append(doc, image, dt.K_CLASSES, cl)
	rd.d_set_source_line(c, d, image, d.lineno)
	return image
}
