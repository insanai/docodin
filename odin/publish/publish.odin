package publish

import "base:runtime"
import "core:mem/virtual"
import "core:strings"

import dt "../doctree"
import rd "../reader"
import tf "../transforms"
import wr "../writers"

// ``docutils.core.publish_string`` / ``publish_parts`` natively: the
// standalone reader and the rST parser (``odin/reader``), the transforms
// (``odin/transforms``) and a writer (``odin/writers``: pseudoxml, xml,
// html5 with the aliases html and xhtml, latex and xetex), with docutils'
// settings, system messages, halting and exit status.
//
//     output, parts, messages, status, err := publish.publish(text, "doc.rst", "html5",
//         {{"report_level", "info"}, {"smart_quotes", true}})

// A system message written to the warning stream (``msg.astext()`` and a
// newline, as docutils writes it to ``stderr``).
Message :: struct {
	level: int,
	text:  string,
}

// An unknown writer or a setting its validator rejects (docutils: an
// ``ImportError`` or an ``optparse`` usage error).
Settings_Error :: struct {
	message: string,
	setting: string, // "" for the writer
}

// A system message reached ``halt_level``: docutils raises
// ``SystemMessage``.
System_Message :: struct {
	level: int,
	text:  string, // ``msg.astext()``
}

// Another exception of docutils, as ``io.error_string`` shows it
// ("NotImplementedError: visiting unimplemented node type: ...").
Exception :: struct {
	text: string,
}

// The output encoding cannot encode the output (``UnicodeEncodeError``).
Unicode_Error :: struct {
	using encode: Encode_Error,
	encoding:     string,
	handler:      string,
}

Error :: union {
	Settings_Error,
	System_Message,
	Exception,
	Unicode_Error,
}

Options :: struct {
	// The docutils package directory in settings and messages (the html5
	// ``stylesheet_dirs``, module paths of language messages); default
	// ``DEFAULT_DOCUTILS_DIR``.
	docutils_dir: string,
}

// ``publish_string(text, source_path, writer_name=writer,
// settings_overrides=overrides)`` with ``publish_parts``' parts.
//
// ``source_path`` "" stands for None (the document's source is
// "<string>"), "<stdin>" for standard input (``settings._source`` stays
// None).  ``output`` is the text of the encoded output (characters the
// output encoding cannot encode are replaced by the error handler); the
// CLI encodes it with ``encode_output``.  ``messages`` are those docutils
// writes to the warning stream, up to a halting one.  ``exit_status`` is
// the status of ``publish_cmdline`` (``enable_exit_status``): the highest
// message level plus 10 if it reached ``exit_status_level``, else 1 after
// an error, else 0.  Results are allocated with ``allocator``.
publish :: proc(
	text, source_path, writer: string,
	overrides: []Override,
	options := Options{},
	allocator := context.allocator,
) -> (
	output: string,
	parts: wr.Parts,
	messages: []Message,
	exit_status: int,
	err: Error,
) {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do panic("publish: cannot reserve arena")
	defer virtual.arena_destroy(&arena)
	scratch := virtual.arena_allocator(&arena)
	p := Pipeline {
		source_path  = source_path,
		options      = options,
		docutils_dir = options.docutils_dir,
		allocator    = allocator,
	}
	if p.docutils_dir == "" do p.docutils_dir = DEFAULT_DOCUTILS_DIR
	{
		context.allocator = scratch
		context.temp_allocator = scratch
		if prepare(&p, writer, overrides) do run(&p, text)
	}
	defer dt.destroy(p.doc)
	messages = collect_messages(&p)
	return p.output, p.parts, messages, exit_status_of(&p), clone_error(p.err, allocator)
}

// The writer of a name or alias (``html`` is html5).
writer_of :: proc(name: string) -> (wr.Writer_Name, bool) {
	if strings.to_lower(name, context.temp_allocator) == "html" do return .Html5, true
	return wr.writer_by_name(name)
}

@(private = "file")
unknown_writer :: proc(name: string, allocator: runtime.Allocator) -> string {
	return strings.concatenate({`Writer "`, name, `" not found.`}, allocator)
}

// --- the pipeline --------------------------------------------------------------------

@(private = "file")
Pipeline :: struct {
	source_path:  string,
	options:      Options,
	docutils_dir: string, // ``options.docutils_dir`` or the default
	allocator:    runtime.Allocator, // of the results
	writer:       wr.Writer_Name,
	settings:     Settings,
	doc:          ^dt.Doc,
	// docutils' ``Publisher.document`` is set (the reader finished)
	has_document: bool,
	output:       string,
	parts:        wr.Parts,
	err:          Error,
	written:      Maybe(int), // messages written before an exception
}

@(private = "file")
prepare :: proc(p: ^Pipeline, writer: string, overrides: []Override) -> bool {
	w, ok := writer_of(writer)
	if !ok {
		p.err = Settings_Error{unknown_writer(writer, context.allocator), ""}
		return false
	}
	p.writer = w
	p.settings = default_settings(w, p.docutils_dir)
	if e, bad := apply_overrides(&p.settings, w, overrides); e != "" {
		p.err = Settings_Error{e, bad.name}
		return false
	}
	source := source_setting(p.source_path)
	p.settings["_source"] = source if source != "" else None{}
	return true
}

// ``settings._source``: None for a string or standard input.
@(private = "file")
source_setting :: proc(source_path: string) -> string {
	return "" if source_path == "<stdin>" else source_path
}

@(private = "file")
run :: proc(p: ^Pipeline, text: string) {
	if !read(p, text) do return
	sectnum, ok := transform(p)
	if !ok do return
	write(p, sectnum)
}

// ``reader.read(source, parser, settings)``.
@(private = "file")
read :: proc(p: ^Pipeline, text: string) -> bool {
	settings := to_doctree(p.settings)
	settings.docutils_dir = p.options.docutils_dir
	parse_settings := settings
	// ``utils.get_trim_footnote_ref_space``: an explicit False wins over
	// "superscript" footnote references (the reader reads None as False).
	if trim, is_bool := p.settings["trim_footnote_reference_space"].(bool); is_bool && !trim {
		parse_settings.footnote_references = ""
	}
	document_source := p.source_path if p.source_path != "" else "<string>"
	info: rd.Parse_Info
	p.doc, info = rd.parse_document(text, parse_settings, document_source, context.allocator)
	p.doc.settings = settings
	r := &p.doc.reporter
	if info.exception != "" && !(r.halted && r.halt_written <= info.exception_at) {
		p.err = Exception{info.exception}
		p.written = info.exception_at
		return false
	}
	if halted(p) do return false
	// ``Reader.parse``: the transforms create nodes without a source or line
	p.doc.current_source = nil
	p.doc.current_line = nil
	p.has_document = true
	obj := to_json(p.settings)
	p.doc.interchange.settings = obj
	return true
}

// ``Transformer.populate_from_components`` and ``apply_transforms``.
@(private = "file")
transform :: proc(p: ^Pipeline) -> (Maybe(tf.Sectnum_Settings), bool) {
	doc := p.doc
	kind := doctree_writer(p.writer)
	options := tf.Options {
		reader          = .Standalone,
		writer          = kind,
		language_cached = contents_directive_used(doc),
		docutils_dir    = p.docutils_dir,
		source_path     = source_setting(p.source_path),
		parse_rst       = rd.parse,
	}
	tf.populate_from_components(doc, .Standalone, kind)
	result, err := tf.apply_all(doc, options)
	if halted(p) do return nil, false
	if e, failed := err.(tf.Transform_Error); failed {
		p.err = Exception{e.message}
		return nil, false
	}
	return result.sectnum, true
}

// The transforms of a writer are those of its ``doctree.Writer_Kind``.
@(private = "file")
doctree_writer :: proc(w: wr.Writer_Name) -> dt.Writer_Kind {
	switch w {
	case .Pseudoxml, .Xml:
		return .Pseudoxml
	case .Html5:
		return .Html5
	case .Latex, .Xetex:
		return .Latex
	}
	return .Pseudoxml
}

// A ``contents`` directive loaded the language module while parsing (its
// ``pending`` element is queued), so the transforms load it silently.
@(private = "file")
contents_directive_used :: proc(doc: ^dt.Doc) -> bool {
	contents := tf.TRANSFORMS[.Contents].name
	for q in doc.pending_queue {
		if q.node != 0 && q.transform == contents do return true
	}
	return false
}

// ``writer.write(document, destination)`` and ``assemble_parts``.
@(private = "file")
write :: proc(p: ^Pipeline, sectnum: Maybe(tf.Sectnum_Settings)) {
	ws := wr.settings_for(p.doc, p.writer)
	if s, ok := sectnum.?; ok {
		ws.sectnum_depth = s.depth
		ws.sectnum_start = s.start
	}
	output, parts, err := wr.write(p.doc, p.writer, ws, p.allocator)
	if halted(p) do return
	if strings.has_prefix(err, "UnicodeEncodeError") {
		output, err = handle_unencodable(p, output, ws)
	}
	if err != "" {
		if _, is_unicode := p.err.(Unicode_Error); !is_unicode do p.err = Exception{err}
		return
	}
	p.output, p.parts = output, parts
}

// ``Output.encode`` with an error handler the writers leave to docodin:
// the output (not encoded) with the unencodable characters replaced, or
// the ``UnicodeEncodeError``.
@(private = "file")
handle_unencodable :: proc(p: ^Pipeline, raw: string, ws: wr.Settings) -> (string, string) {
	codec := codec_of(ws.output_encoding)
	handler := ws.output_encoding_error_handler
	out, e := apply_error_handler(raw, codec, handler, p.allocator)
	if enc, failed := e.?; failed {
		p.err = Unicode_Error{enc, ws.output_encoding, handler}
		return "", "UnicodeEncodeError"
	}
	return out, ""
}

// A message reached the halt level: docutils raised ``SystemMessage``.
@(private = "file")
halted :: proc(p: ^Pipeline) -> bool {
	r := &p.doc.reporter
	if !r.halted do return false
	b := strings.builder_make()
	dt.write_astext(&b, p.doc, r.halt_message)
	level := dt.get_int(p.doc, r.halt_message, dt.K_LEVEL)
	p.err = System_Message{level, strings.to_string(b)}
	return true
}

@(private = "file")
collect_messages :: proc(p: ^Pipeline) -> []Message {
	if p.doc == nil do return nil
	r := &p.doc.reporter
	written := r.written[:r.halt_written] if r.halted else r.written[:]
	if n, raised := p.written.?; raised do written = r.written[:n]
	out := make([]Message, len(written), p.allocator)
	for m, i in written {
		out[i] = Message{int(m.level), strings.clone(m.text, p.allocator)}
	}
	return out
}

// ``Publisher.publish(enable_exit_status=True)``.
@(private = "file")
exit_status_of :: proc(p: ^Pipeline) -> int {
	if !p.has_document do return 1 if p.err != nil else 0
	r := &p.doc.reporter
	max_level := r.halt_max_level if r.halted else r.max_level
	if max_level >= as_int(p.settings["exit_status_level"]) do return max_level + 10
	return 1 if p.err != nil else 0
}

@(private = "file")
clone_error :: proc(err: Error, allocator: runtime.Allocator) -> Error {
	clone :: proc(s: string, a: runtime.Allocator) -> string {
		return strings.clone(s, a)
	}
	switch e in err {
	case Settings_Error:
		return Settings_Error{clone(e.message, allocator), clone(e.setting, allocator)}
	case System_Message:
		return System_Message{e.level, clone(e.text, allocator)}
	case Exception:
		return Exception{clone(e.text, allocator)}
	case Unicode_Error:
		u := e
		u.object = clone(e.object, allocator)
		u.chars = clone(e.chars, allocator)
		u.encoding = clone(e.encoding, allocator)
		u.handler = clone(e.handler, allocator)
		return u
	}
	return nil
}
