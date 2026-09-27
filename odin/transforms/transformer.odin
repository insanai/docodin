package transforms

import "core:fmt"
import "core:mem/virtual"
import "core:slice"
import "core:strings"

import dt "../doctree"

// ``docutils.transforms.Transformer`` and the standard transforms of the
// standalone and PEP readers, the rST parser and the pseudo-XML, HTML5 and
// LaTeX writers.
//
// The queue is ``Doc.pending_queue`` (``Transformer.transforms``): entries
// with a priority string ``"%03d-%03d" % (priority, serial)``, applied
// lowest string first.  Transforms that queue further transforms (with
// ``note_pending`` or ``add_transform``) take part in the same run, as in
// ``Transformer.apply_transforms``.  A transform is a row of ``TRANSFORMS``:
// its qualified docutils class name, ``default_priority`` and ``apply``
// procedure.

Transform_Kind :: enum u8 {
	// universal
	Decorations,
	Expose_Internals,
	Messages,
	Filter_Messages,
	Test_Messages,
	Strip_Comments,
	Strip_Classes_And_Elements,
	Smart_Quotes,
	Validate,
	// references
	Propagate_Targets,
	Anonymous_Hyperlinks,
	Indirect_Hyperlinks,
	Footnotes,
	External_Targets,
	Internal_Targets,
	Dangling_References,
	Substitutions,
	Target_Notes,
	Citation_References,
	// frontmatter
	Doc_Title,
	Section_Sub_Title,
	Doc_Info,
	// parts
	Sect_Num,
	Contents,
	// misc
	Class_Attribute,
	Transitions,
	Call_Back,
	// components, writer_aux
	Filter,
	Admonitions,
	// peps
	Pep_Headers,
	Pep_Contents,
	Pep_Target_Notes,
	Pep_Zero,
}

// ``Transform.apply(**kwargs)`` of a transform instantiated with
// ``startnode`` (the ``pending`` element, or 0).
Apply_Proc :: proc(r: ^Run, startnode: dt.Node, kwargs: []dt.Detail)

Transform_Info :: struct {
	name:     string, // qualified class name
	priority: int, // ``default_priority``
	apply:    Apply_Proc,
}

@(private = "file")
U :: "docutils.transforms.universal."
@(private = "file")
R :: "docutils.transforms.references."
@(private = "file")
F :: "docutils.transforms.frontmatter."
@(private = "file")
P :: "docutils.transforms.parts."
@(private = "file")
M :: "docutils.transforms.misc."
@(private = "file")
E :: "docutils.transforms.peps."

@(rodata)
TRANSFORMS := [Transform_Kind]Transform_Info {
	.Decorations                = {U + "Decorations", 820, decorations},
	.Expose_Internals           = {U + "ExposeInternals", 840, expose_internals},
	.Messages                   = {U + "Messages", 860, messages},
	.Filter_Messages            = {U + "FilterMessages", 870, filter_messages},
	.Test_Messages              = {U + "TestMessages", 880, test_messages},
	.Strip_Comments             = {U + "StripComments", 740, strip_comments},
	.Strip_Classes_And_Elements = {U + "StripClassesAndElements", 420, strip_classes},
	.Smart_Quotes               = {U + "SmartQuotes", 855, smart_quotes},
	.Validate                   = {U + "Validate", 835, validate_document},
	.Propagate_Targets          = {R + "PropagateTargets", 260, propagate_targets},
	.Anonymous_Hyperlinks       = {R + "AnonymousHyperlinks", 440, anonymous_hyperlinks},
	.Indirect_Hyperlinks        = {R + "IndirectHyperlinks", 460, indirect_hyperlinks},
	.Footnotes                  = {R + "Footnotes", 620, footnotes},
	.External_Targets           = {R + "ExternalTargets", 640, external_targets},
	.Internal_Targets           = {R + "InternalTargets", 660, internal_targets},
	.Dangling_References        = {R + "DanglingReferences", 850, dangling_references},
	.Substitutions              = {R + "Substitutions", 220, substitutions},
	.Target_Notes               = {R + "TargetNotes", 540, target_notes},
	.Citation_References        = {R + "CitationReferences", 770, citation_references},
	.Doc_Title                  = {F + "DocTitle", 320, doc_title},
	.Section_Sub_Title          = {F + "SectionSubTitle", 350, section_sub_title},
	.Doc_Info                   = {F + "DocInfo", 340, doc_info},
	.Sect_Num                   = {P + "SectNum", 710, sect_num},
	.Contents                   = {P + "Contents", 720, contents},
	.Class_Attribute            = {M + "ClassAttribute", 210, class_attribute},
	.Transitions                = {M + "Transitions", 830, transitions},
	.Call_Back                  = {M + "CallBack", 990, call_back},
	.Filter                     = {"docutils.transforms.components.Filter", 780, filter},
	.Admonitions                = {"docutils.transforms.writer_aux.Admonitions", 920, admonitions},
	.Pep_Headers                = {E + "Headers", 360, pep_headers},
	.Pep_Contents               = {E + "Contents", 380, pep_contents},
	.Pep_Target_Notes           = {E + "TargetNotes", 520, pep_target_notes},
	.Pep_Zero                   = {E + "PEPZero", 760, pep_zero},
}

// The transform of a qualified class name.
transform_of :: proc(name: string) -> (Transform_Kind, bool) {
	for info, kind in TRANSFORMS {
		if info.name == name do return kind, true
	}
	return {}, false
}

// ``nodes.pending(transform_class, details)``.
new_pending_of :: proc(doc: ^dt.Doc, kind: Transform_Kind, details: []dt.Detail = nil) -> dt.Node {
	return dt.new_pending(doc, TRANSFORMS[kind].name, TRANSFORMS[kind].priority, details)
}

// --- components ------------------------------------------------------------------

Reader_Kind :: enum u8 {
	Standalone,
	Pep,
}

// ``get_transforms()`` of the readers, the rST parser and the writers.
@(rodata)
READER_TRANSFORMS := [Reader_Kind][]Transform_Kind {
	.Standalone = {
		.Decorations, .Expose_Internals, .Strip_Comments, .Substitutions, .Propagate_Targets,
		.Doc_Title, .Section_Sub_Title, .Doc_Info, .Anonymous_Hyperlinks, .Indirect_Hyperlinks,
		.Footnotes, .External_Targets, .Internal_Targets, .Dangling_References, .Transitions,
	},
	.Pep = {
		.Decorations, .Expose_Internals, .Strip_Comments, .Substitutions, .Propagate_Targets,
		.Anonymous_Hyperlinks, .Indirect_Hyperlinks, .Footnotes, .External_Targets,
		.Internal_Targets, .Dangling_References, .Transitions, .Pep_Headers, .Pep_Contents,
		.Pep_Target_Notes,
	},
}

@(rodata)
PARSER_TRANSFORMS := []Transform_Kind{.Validate, .Smart_Quotes}

@(rodata)
WRITER_TRANSFORMS := [dt.Writer_Kind][]Transform_Kind {
	.Pseudoxml = {.Messages, .Filter_Messages, .Strip_Classes_And_Elements},
	.Html5     = {.Messages, .Filter_Messages, .Strip_Classes_And_Elements, .Admonitions},
	.Latex     = {
		.Messages, .Filter_Messages, .Strip_Classes_And_Elements, .Admonitions,
		.Citation_References,
	},
}

// ``Component.supported`` of the components (for ``components.Filter``).
@(rodata)
READER_SUPPORTED := [Reader_Kind][]string {
	.Standalone = {"standalone"},
	.Pep        = {"pep"},
}

@(rodata)
PARSER_SUPPORTED := []string{"rst", "restructuredtext", "rest", "restx", "rtxt", "rstx"}

@(rodata)
WRITER_SUPPORTED := [dt.Writer_Kind][]string {
	.Pseudoxml = {"pseudoxml", "pprint", "pformat"},
	.Html5     = {"html5", "xhtml", "html"},
	.Latex     = {"latex", "latex2e"},
}

// ``Transformer.add_transform(transform_class, priority, **kwargs)``.
add_transform :: proc(
	doc: ^dt.Doc,
	kind: Transform_Kind,
	priority: Maybe(int) = nil,
	kwargs: []dt.Detail = nil,
) {
	doc.transform_serial += 1
	q := dt.Queued_Pending {
		priority  = priority.? or_else TRANSFORMS[kind].priority,
		serial    = doc.transform_serial,
		transform = TRANSFORMS[kind].name,
		kwargs    = make([dynamic]dt.Detail, 0, len(kwargs), doc.allocator),
	}
	for d in kwargs do append(&q.kwargs, d)
	append(&doc.pending_queue, q)
}

// ``Transformer.populate_from_components((source, reader, parser, writer,
// destination))``: the transforms of the reader, the rST parser and the
// writer.  (The input and output have none.)
populate_from_components :: proc(doc: ^dt.Doc, reader: Reader_Kind, writer: dt.Writer_Kind) {
	for k in READER_TRANSFORMS[reader] do add_transform(doc, k)
	for k in PARSER_TRANSFORMS do add_transform(doc, k)
	for k in WRITER_TRANSFORMS[writer] do add_transform(doc, k)
}

// --- running -------------------------------------------------------------------

// ``"%03d-%03d" % (priority, serial)``.
priority_string :: proc(priority, serial: int, allocator := context.temp_allocator) -> string {
	return fmt.aprintf("%03d-%03d", priority, serial, allocator = allocator)
}

@(private = "file")
Sort_Entry :: struct {
	key: string,
	q:   dt.Queued_Pending,
}

// ``self.transforms.sort(reverse=True)``: the next transform is the last.
@(private = "file")
sort_queue :: proc(doc: ^dt.Doc) {
	entries := make([]Sort_Entry, len(doc.pending_queue), context.temp_allocator)
	for q, i in doc.pending_queue do entries[i] = {priority_string(q.priority, q.serial), q}
	slice.sort_by(entries, proc(a, b: Sort_Entry) -> bool {return a.key > b.key})
	for e, i in entries do doc.pending_queue[i] = e.q
}

// ``Transformer.apply_transforms()``: apply the queued transforms in
// priority order.  The reporter's transform-message observer is attached
// meanwhile.  Stops at the first error (an exception in docutils); the
// reporter reaching its halt level is one (``SystemMessage``).
apply_all :: proc(doc: ^dt.Doc, options := Options{}) -> (Result, Error) {
	r := begin(doc, options)
	for _ in step(&r) {}
	return finish(&r)
}

// Start applying the queue: ``begin``, ``step`` until it returns false,
// ``finish``.
begin :: proc(doc: ^dt.Doc, options := Options{}) -> Run {
	r := run_make(doc, options)
	dt.attach_observer(doc, dt.observe_transform_message)
	return r
}

// Apply the next transform of the queue; false when the queue is empty or
// the run failed.  ``name`` is the transform's qualified class name.
step :: proc(r: ^Run) -> (name: string, ok: bool) {
	doc := r.doc
	if r.err != nil || len(doc.pending_queue) == 0 do return "", false
	context.temp_allocator = virtual.arena_allocator(&r.scratch)
	defer free_all(context.temp_allocator)
	if len(doc.pending_queue) != r.sorted_count do sort_queue(doc)
	q := pop(&doc.pending_queue)
	r.sorted_count = len(doc.pending_queue)
	kind, known := transform_of(q.transform)
	if !known {
		fail(r, "unknown transform %s", q.transform)
		return q.transform, false
	}
	instantiate(r)
	TRANSFORMS[kind].apply(r, q.node, q.kwargs[:])
	if r.err == nil && doc.reporter.halted do fail_halted(r)
	return q.transform, r.err == nil
}

// End the run: the observer is detached (unless the run failed).
finish :: proc(r: ^Run) -> (Result, Error) {
	if r.err == nil do dt.detach_observer(r.doc, dt.observe_transform_message)
	virtual.arena_destroy(&r.scratch)
	return r.result, r.err
}

@(private = "file")
fail_halted :: proc(r: ^Run) {
	b := strings.builder_make(r.doc.allocator)
	dt.write_astext(&b, r.doc, r.doc.reporter.halt_message)
	r.err = Transform_Error{strings.to_string(b)}
}

// The transform raised an exception (docutils would abort the run).
fail :: proc(r: ^Run, format: string, args: ..any) {
	if r.err != nil do return
	r.err = Transform_Error{fmt.aprintf(format, ..args, allocator = r.doc.allocator)}
}

// ``Transform.__init__``: the language module is loaded (and cached) on the
// first instantiation.
@(private = "file")
instantiate :: proc(r: ^Run) {
	if !r.language_loaded do load_language(r)
}
