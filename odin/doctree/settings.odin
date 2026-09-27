package doctree

// Runtime settings (``optparse.Values`` of docutils) used by the native
// pipeline, with the docutils 0.22 defaults of the general options
// (``frontend.OptionParser``, ``_settings.py``), the rST parser, the
// standalone reader and the writers.  Python ``None`` is represented as
// false, "" or an empty list; the comments give the docutils option.

Writer_Kind :: enum u8 {
	Pseudoxml,
	Html5,
	Latex,
}

// Where the reporter writes system messages (``warning_stream``).
Warning_Stream :: enum u8 {
	Stderr,  // None: ``sys.stderr``
	Collect, // only ``Reporter.written`` (for the CLI)
	Discard, // False
}

Settings :: struct {
	// general options
	report_level:                   int, // --report
	halt_level:                     int, // --halt
	exit_status_level:              int, // --exit-status
	debug:                          bool, // --debug
	warning_stream:                 Warning_Stream, // --warnings
	traceback:                      bool,
	id_prefix:                      string, // --id-prefix
	auto_id_prefix:                 string, // --auto-id-prefix
	language_code:                  string, // --language
	input_encoding:                 string,
	output_encoding:                string,
	output_encoding_error_handler:  string,
	error_encoding:                 string,
	error_encoding_error_handler:   string,
	title:                          string, // --title
	generator:                      bool, // --generator
	datestamp:                      string, // --date / --time
	source_link:                    bool,
	source_url:                     string,
	root_prefix:                    string,
	toc_backlinks:                  string, // "entry", "top" or "" (False)
	footnote_backlinks:             bool,
	sectnum_xform:                  bool, // --section-numbering
	strip_comments:                 bool,
	strip_elements_with_classes:    []string,
	strip_classes:                  []string,
	expose_internals:               []string,
	strict_visitor:                 bool,
	// rST parser
	tab_width:                      int,
	line_length_limit:              int,
	pep_references:                 bool,
	pep_base_url:                   string,
	pep_file_url_template:          string,
	rfc_references:                 bool,
	rfc_base_url:                   string,
	character_level_inline_markup:  bool,
	trim_footnote_reference_space:  bool,
	file_insertion_enabled:         bool,
	raw_enabled:                    bool,
	validate:                       bool,
	syntax_highlight:               string,
	smart_quotes:                   bool, // also "alt"/"alternative": see smart_quotes_alt
	smart_quotes_alt:               bool,
	smartquotes_locales:            []string,
	// standalone reader
	docinfo_xform:                  bool,
	doctitle_xform:                 bool,
	sectsubtitle_xform:             bool,
	// writers
	detailed:                       bool, // pseudoxml --detailed
	footnote_references:            string, // "brackets" (html5) / "superscript" (latex)
	attribution:                    string,
	stylesheet:                     []string,
	stylesheet_path:                []string,
	stylesheet_dirs:                []string,
	embed_stylesheet:               bool,
	table_style:                    []string,
	template:                       string,
	// html5
	math_output:                    string,
	initial_header_level:           int,
	xml_declaration:                bool,
	compact_lists:                  bool,
	compact_field_lists:            bool,
	section_self_link:              bool,
	cloak_email_addresses:          bool,
	embed_images:                   bool,
	image_loading:                  string,
	// latex
	documentclass:                  string,
	documentoptions:                string,
	docutils_footnotes:             bool,
	use_latex_citations:            bool,
	use_latex_toc:                  bool,
	use_latex_docinfo:              bool,
	use_latex_abstract:             bool,
	use_part_section:               bool,
	hyperlink_color:                string,
	hyperref_options:               string,
	font_encoding:                  string,
	graphicx_option:                string,
	latex_preamble:                 string,
	literal_block_env:              string,
	reference_label:                string,
	section_enumerator_separator:   string,
	section_prefix_for_enumerators: bool,
	compound_enumerators:           bool,
	legacy_class_functions:         bool,
	legacy_column_widths:           bool,
	use_verbatim_when_possible:     bool,
	use_bibtex:                     string,
}

LATEX_PREAMBLE :: `% PDF Standard Fonts
\usepackage{mathptmx} % Times
\usepackage[scaled=.90]{helvet}
\usepackage{courier}`

@(private = "file")
HTML5_STYLESHEETS := [?]string{"minimal.css", "plain.css"}
@(private = "file")
CURRENT_DIR := [?]string{"."}
@(private = "file")
LATEX_TABLE_STYLE := [?]string{"standard"}

// The docutils defaults for the rST parser, the standalone reader and the
// given writer (``frontend.get_default_settings(Parser, Reader, Writer)``).
// ``stylesheet_dirs`` of html5 holds "." only: the writer's own directory
// is the native writer's embedded stylesheet set.
default_settings :: proc(writer := Writer_Kind.Pseudoxml) -> Settings {
	s := Settings {
		report_level                  = 2,
		halt_level                    = 4,
		exit_status_level             = 5,
		warning_stream                = .Stderr,
		auto_id_prefix                = "%",
		language_code                 = "en",
		input_encoding                = "utf-8",
		output_encoding               = "utf-8",
		output_encoding_error_handler = "strict",
		error_encoding                = "utf-8",
		error_encoding_error_handler  = "backslashreplace",
		toc_backlinks                 = "entry",
		footnote_backlinks            = true,
		sectnum_xform                 = true,
		tab_width                     = 8,
		line_length_limit             = 10000,
		pep_base_url                  = "https://peps.python.org/",
		pep_file_url_template         = "pep-%04d",
		rfc_base_url                  = "https://tools.ietf.org/html/",
		file_insertion_enabled        = true,
		raw_enabled                   = true,
		syntax_highlight              = "long",
		docinfo_xform                 = true,
		doctitle_xform                = true,
	}
	switch writer {
	case .Pseudoxml:
	case .Html5:
		set_html5_defaults(&s)
	case .Latex:
		set_latex_defaults(&s)
	}
	return s
}

@(private = "file")
set_html5_defaults :: proc(s: ^Settings) {
	s.output_encoding_error_handler = "xmlcharrefreplace"
	s.footnote_references = "brackets"
	s.attribution = "dash"
	s.stylesheet_path = HTML5_STYLESHEETS[:]
	s.stylesheet_dirs = CURRENT_DIR[:]
	s.embed_stylesheet = true
	s.template = "template.txt"
	s.math_output = "MathML"
	s.initial_header_level = 2
	s.compact_lists = true
	s.compact_field_lists = true
}

@(private = "file")
set_latex_defaults :: proc(s: ^Settings) {
	s.footnote_references = "superscript"
	s.attribution = "dash"
	s.stylesheet_dirs = CURRENT_DIR[:]
	s.table_style = LATEX_TABLE_STYLE[:]
	s.template = "default.tex"
	s.documentclass = "article"
	s.documentoptions = "a4paper"
	s.docutils_footnotes = true
	s.use_latex_toc = true
	s.hyperlink_color = "blue"
	s.font_encoding = "T1"
	s.latex_preamble = LATEX_PREAMBLE
	s.section_enumerator_separator = "-"
}
