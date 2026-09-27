package reader

import "base:runtime"
import "core:mem/virtual"

import dt "../doctree"
import rst "../rst"

// The native reStructuredText reader: turns the parse tree of ``odin/rst``
// into a ``doctree.Doc`` like ``docutils.parsers.rst.Parser.parse`` into
// ``utils.new_document`` (``publish_doctree`` without transforms).
//
// It is a port of the Python host (``python/docodin/builder.py``): the
// native parser recognizes the markup and reports the parser's messages;
// the reader does what the docutils parser does besides: registration with
// the document, section nesting, directives and roles, and the
// bookkeeping of ``document.current_line`` and the reporter's line (which
// decide the ``source``/``line`` of nodes and messages).
//
// ``Machine`` stands for a docutils (nested) state machine, ``Context``
// for the per-document state (``DocumentContext`` and the parser ``memo``).

// A docutils ``StateMachineWS`` over a (nested) block of input lines.  It
// is not run line by line (the native parser did that): it carries the
// position, the input lines and the current node for directives, roles and
// the builder.
Machine :: struct {
	// ``input_lines``; nil: those of ``owner`` (views of an enclosing
	// parse), or the lazily split document input (the top machine)
	lines:                ^String_List,
	owner:                ^Machine,
	input_offset:         int,
	line_offset:          int,
	node:                 dt.Node,
	match_titles:         bool,
	parent:               ^Machine, // ``parent_state_machine``
	section_level_offset: int,
	// source line minus absolute line (docutils quirks: table cells,
	// substitution definitions spanning lines)
	line_delta:           int,
	// ``_linear_source`` is set: the input lines map 1:1 to the source
	linear:               bool,
	// the input is a disconnected block (substitution definitions, table
	// cells): insertions into directive content do not reach its input
	disconnected:         bool,
}

// An ``include`` insertion, for restoring docutils' view after the parse.
Insertion :: struct {
	offset: int,
	lines:  ^String_List,
}

// ``(path, clip options)`` of ``document.include_log``.
Include_Entry :: struct {
	path:  string,
	clips: [4]string, // start-line, end-line, start-after, end-before (repr)
}

Context :: struct {
	doc:              ^dt.Doc,
	arena:            virtual.Arena,
	allocator:        runtime.Allocator, // the arena: parse trees, lists, scratch
	flags:            rst.Parse_Flags,
	tab_width:        int,
	source:           string,
	text:             string, // the document input (lazy ``input_lines``)
	line_count:       int,
	top:              ^Machine,
	// the line of docutils' root state machine (the reporter's current
	// line), which stays behind the top machine's position in explicit
	// lists and nested constructs; 0: the top machine's position
	root_line:        int,
	// ``insert_input`` bookkeeping (see ``process_inserted_input``)
	insertions:       [dynamic]Insertion,
	last_removal_top: bool,
	removed_lines:    int,
	absolute_lines:   map[dt.Node]int, // node -> lines removed at its creation
	// builder state
	start_message:    dt.Node, // see ``early_message``
	inliner_parent:   dt.Node, // ``Inliner.parent``
	// parser ``memo``
	title_styles:     [dynamic]string,
	section_level:    int,
	// ``roles._roles``: roles by local name ("" = the default role)
	roles:            map[string]^Role,
	include_log:      [dynamic]Include_Entry,
	// ``include`` insertions the parser makes (see include.odin)
	insert_mode:      Insert_Mode,
	captured:         [dynamic]Captured_Insert,
	dry_run:          bool, // an include dry run: no side effects
	dry_run_failed:   bool, // the dry run would have had side effects
	moved_cursor:     Moved_Cursor,
	unported:         int, // registered directives not ported yet, seen
	// ``docutils.languages`` module of ``language_code`` (``LANGUAGE_MODULES``)
	language:         int,
	language_loaded:  bool,
	// ``RSTStateMachine.language`` (``RST_LANGUAGES``, ``NO_RST_LANGUAGE``)
	rst_language:     int,
	// ``directives._directives``: directives by (lowercase) local name
	directives:       map[string]^Directive_Spec,
	// the first Python exception docutils raises (see ``raise_exception``)
	exception:        string,
	exception_at:     int, // ``len(reporter.written)`` then
}

// What ``parse_document`` tells besides the document.
Parse_Info :: struct {
	unported_directives: int, // uses of directives that are not ported yet
	// The exception docutils raises while parsing ("Class: message"; ""
	// for none): the parse fails with it, and the messages written after
	// ``len(reporter.written) == exception_at`` would not exist.
	exception:           string,
	exception_at:        int,
}

// ``Parser.parse(text, new_document(source_path, settings))``.
parse :: proc(
	text: string,
	settings: dt.Settings,
	source_path: string,
	allocator := context.allocator,
) -> ^dt.Doc {
	doc, _ := parse_document(text, settings, source_path, allocator)
	return doc
}

// ``parse`` with information about the run.
parse_document :: proc(
	text: string,
	settings: dt.Settings,
	source_path: string,
	allocator := context.allocator,
) -> (
	doc: ^dt.Doc,
	info: Parse_Info,
) {
	doc = dt.new_document(source_path, settings, allocator)
	c: Context
	context_init(&c, doc)
	defer virtual.arena_destroy(&c.arena)
	context.temp_allocator = c.allocator
	c.text = text
	top := Machine {
		input_offset = 0,
		line_offset  = -1,
		node         = doc.root,
		match_titles = true,
		linear       = true,
	}
	// ``Parser.setup_parse`` / ``finish_parse``
	dt.attach_observer(doc, dt.observe_parse_message)
	defer dt.detach_observer(doc, dt.observe_parse_message)
	start(&c, &top)
	p := new_parser(&c, c.flags, int(doc.settings.line_length_limit))
	setup_include_hook(&c, &top, &p)
	tree_doc, count, final_offset := rst.parse_text(&p, text, 0, true)
	// ``RSTStateMachine.run`` (not run when a line is too long)
	if final_offset != -1 do load_rst_language(&c)
	c.line_count = count
	build_items(&c, &p.tree, rst.first_child(&p.tree, tree_doc), 0, &top, true)
	finish(&c, &top, final_offset, count)
	info.unported_directives = c.unported
	info.exception, info.exception_at = c.exception, c.exception_at
	return
}

// A Python exception docutils raises here, aborting the parse.  The native
// reader carries on; the first exception is reported in ``Parse_Info``.
raise_exception :: proc(c: ^Context, text: string) {
	if c.exception != "" do return
	c.exception = dt.clone(c.doc, text)
	c.exception_at = len(c.doc.reporter.written)
}

@(private = "file")
context_init :: proc(c: ^Context, doc: ^dt.Doc) {
	c.doc = doc
	if virtual.arena_init_growing(&c.arena) != nil do panic("reader: cannot reserve arena")
	c.allocator = virtual.arena_allocator(&c.arena)
	a := c.allocator
	s := &doc.settings
	c.tab_width = s.tab_width
	c.flags = parse_flags(s)
	c.source = dt.get_string(doc, doc.root, dt.K_SOURCE)
	if c.source == "" do c.source = doc.current_source.? or_else ""
	c.insertions = make([dynamic]Insertion, a)
	c.absolute_lines = make(map[dt.Node]int, 16, a)
	c.title_styles = make([dynamic]string, a)
	c.roles = make(map[string]^Role, 16, a)
	c.directives = make(map[string]^Directive_Spec, 16, a)
	c.include_log = make([dynamic]Include_Entry, a)
	c.captured = make([dynamic]Captured_Insert, a)
}

// The parser flags of the settings (``builder.parse_flags``).
@(private = "file")
parse_flags :: proc(s: ^dt.Settings) -> rst.Parse_Flags {
	flags := rst.Parse_Flags{.Match_Titles}
	if s.character_level_inline_markup do flags += {.Character_Level_Inline_Markup}
	if s.pep_references do flags += {.Pep_References}
	if s.rfc_references do flags += {.Rfc_References}
	// ``utils.get_trim_footnote_ref_space``
	if s.trim_footnote_reference_space || s.footnote_references == "superscript" {
		flags += {.Trim_Footnote_Reference_Space}
	}
	return flags
}

// A native parser working in the reader's arena.
new_parser :: proc(c: ^Context, flags: rst.Parse_Flags, line_length_limit: int) -> rst.Parser {
	return rst.Parser {
		allocator = c.allocator,
		settings = rst.settings_from_flags(flags, c.tab_width, line_length_limit),
	}
}

@(private = "file")
start :: proc(c: ^Context, sm: ^Machine) {
	c.top = sm
	r := &c.doc.reporter
	if r.source_and_line == nil {
		r.source_and_line = reporter_source_and_line
		r.source_line_data = c
	}
	c.doc.current_source = c.source if c.source != "" else nil
}

// ``reporter.get_source_and_line``: that of the top state machine.
@(private = "file")
reporter_source_and_line :: proc(
	doc: ^dt.Doc,
	data: rawptr,
	line: Maybe(int),
) -> (
	Maybe(string),
	Maybe(int),
) {
	c := (^Context)(data)
	lineno := line
	if lineno == nil && c.root_line != 0 do lineno = c.root_line
	src, ln, _ := get_source_and_line(c, c.top, lineno)
	return src, ln
}

// Leave the top state machine and ``document.current_*`` where docutils'
// own run leaves them (messages of transforms use them).
@(private = "file")
finish :: proc(c: ^Context, sm: ^Machine, final_offset_in, count_in: int) {
	final_offset, count := final_offset_in, count_in
	// the input lines include the lines the parser inserted
	if sm.lines != nil do count = sl_len(sm.lines)
	if final_offset < 0 do final_offset = -1 // parse aborted (line-length limit)
	if len(c.insertions) > 0 {
		restore_insertions(c, sm)
		if final_offset >= 0 {
			final_offset += c.removed_lines
			count += c.removed_lines
			// the input ended inside a top-level ``include`` directive:
			// docutils went on through the inserted lines, which end cleanly
			if final_offset > count && c.last_removal_top && ends_with_insertion(c, sm) {
				final_offset = count
			}
		}
	}
	sm.line_offset = final_offset
	c.root_line = 0
	c.doc.current_line = nil
	c.doc.current_source = nil
	if final_offset == count {
		src, _, _ := get_source_and_line(c, sm, nil)
		if s, ok := src.?; ok do c.doc.current_source = dt.clone(c.doc, s) // outlives the arena
	}
	keep_reporter_machine(c, sm)
}

// The top state machine as the reporter keeps it after the parse
// (docutils' ``reporter.get_source_and_line`` stays bound to it, and
// transforms report through it).  It lives in the document's arena.
@(private = "file")
Final_Machine :: struct {
	items:        []Line_Info, // the input lines; nil: they map 1:1 to the source
	input_offset: int,
	line_offset:  int,
	line_count:   int,
	source:       string,
}

@(private = "file")
keep_reporter_machine :: proc(c: ^Context, sm: ^Machine) {
	doc := c.doc
	m := new(Final_Machine, doc.allocator)
	m^ = {
		input_offset = sm.input_offset,
		line_offset  = sm.line_offset,
		line_count   = c.line_count,
		source       = dt.clone(doc, c.source),
	}
	if !is_linear(c, sm) {
		lines := input_lines(c, sm)
		m.items = make([]Line_Info, sl_len(lines), doc.allocator)
		for info, i in lines.items {
			m.items[i] = {dt.str(doc, dt.intern(doc, info.source)), info.offset}
		}
	}
	doc.reporter.source_and_line = final_source_and_line
	doc.reporter.source_line_data = m
}

// ``get_source_and_line`` of the kept top state machine.
@(private = "file")
final_source_and_line :: proc(
	doc: ^dt.Doc,
	data: rawptr,
	lineno: Maybe(int),
) -> (
	Maybe(string),
	Maybe(int),
) {
	m := (^Final_Machine)(data)
	ln := lineno.? or_else m.line_offset + m.input_offset + 1
	if m.items == nil {
		if 1 <= ln && ln <= m.line_count + 1 do return m.source, ln
		return nil, nil
	}
	offset := ln - m.input_offset - 1
	n := len(m.items)
	switch {
	case offset >= 0 && offset < n:
		return m.items[offset].source, m.items[offset].offset + 1
	case offset < 0 && offset >= -n:
		return m.items[n + offset].source, m.items[n + offset].offset + 1
	case offset == n && n > 0:
		src, prev := final_source_and_line(doc, data, offset + m.input_offset)
		if p, ok := prev.?; ok do return src, p + 1
	}
	return nil, nil
}

// Record a node whose ``line`` is an absolute line number (docutils sets
// it without source lookup), to be renumbered by ``restore_insertions``.
// ``removed``: the lines removed when the node got its line (default: now).
note_absolute_line :: proc(c: ^Context, n: dt.Node, removed := -1) {
	count := removed if removed >= 0 else c.removed_lines
	if count > 0 && n not_in c.absolute_lines do c.absolute_lines[n] = count
}

// --- machines -------------------------------------------------------------------

// ``state_machine.input_lines`` (materialized on first use).
input_lines :: proc(c: ^Context, m: ^Machine) -> ^String_List {
	if m.lines != nil do return m.lines
	if m.owner != nil {
		m.lines = input_lines(c, m.owner)
		return m.lines
	}
	m.lines = sl_make(rst.split_lines(c.text, c.tab_width, c.allocator), c.source, c.allocator)
	return m.lines
}

// Top-level string input whose lines map 1:1 to the source (no pending
// ``insert_input`` lines).
is_linear :: proc(c: ^Context, m: ^Machine) -> bool {
	if !m.linear do return false
	lines := m.lines
	if lines == nil && m.owner != nil do lines = m.owner.lines
	return lines == nil || sl_len(lines) == c.line_count
}

// ``state_machine.get_source_and_line(lineno)``; ``ok`` is false where
// docutils raises (``TypeError`` for a line past the end of the input).
get_source_and_line :: proc(
	c: ^Context,
	m: ^Machine,
	lineno: Maybe(int),
) -> (
	src: Maybe(string),
	line: Maybe(int),
	ok: bool,
) {
	ln := lineno.? or_else m.line_offset + m.input_offset + 1
	ln += m.line_delta
	if is_linear(c, m) {
		if 1 <= ln && ln <= c.line_count + 1 do return c.source, ln, true
		return nil, nil, true
	}
	// ``StateMachine.get_source_and_line``
	offset := ln - m.input_offset - 1
	info, has_offset, found := sl_info(input_lines(c, m), offset)
	if !found do return nil, nil, true
	if has_offset do return info.source, info.offset + 1, true
	// "just past the end": the line after the last one
	s, l, _ := get_source_and_line(c, m, offset + m.input_offset)
	prev, has_prev := l.?
	if !has_prev do return nil, nil, false
	return s, prev + 1, true
}

// ``(source, line)`` for node attributes.
srcline :: proc(c: ^Context, m: ^Machine, lineno: int) -> (Maybe(string), Maybe(int)) {
	if is_linear(c, m) do return c.source, lineno + m.line_delta
	src, ln, ok := get_source_and_line(c, m, lineno)
	if !ok do return c.source, lineno + m.line_delta
	return src, ln
}

// Set the ``source`` and ``line`` of ``n`` from ``srcline``.
set_srcline :: proc(c: ^Context, m: ^Machine, n: dt.Node, lineno: int) {
	src, ln := srcline(c, m, lineno)
	dt.set_source(c.doc, n, src)
	dt.set_line(c.doc, n, ln)
}

// Set ``document.current_source``/``current_line`` from ``srcline``.
set_current :: proc(c: ^Context, m: ^Machine, lineno: int) {
	c.doc.current_source, c.doc.current_line = srcline(c, m, lineno)
}

// ``state_machine.abs_line_number()``.
abs_line_number :: #force_inline proc "contextless" (m: ^Machine) -> int {
	return m.line_offset + m.input_offset + 1
}

// A state machine for a nested container: docutils creates one per nested
// parse; input lines and offsets are shared with the enclosing parse.
context_machine :: proc(sm: ^Machine, node: dt.Node) -> Machine {
	owner := sm.owner if sm.owner != nil else sm
	return Machine {
		lines = sm.lines,
		owner = owner,
		input_offset = sm.input_offset,
		line_offset = -1,
		node = node,
		parent = sm,
		line_delta = sm.line_delta,
		linear = sm.linear,
		disconnected = sm.disconnected,
	}
}

// --- parsing --------------------------------------------------------------------------

// Parse ``lines`` natively into ``sm.node`` (a nested parse); the include
// hook state tells which lines the parser inserted.
parse_lines :: proc(
	c: ^Context,
	sm: ^Machine,
	lines: ^String_List,
	match_titles: bool,
) -> ^Include_State {
	flags := c.flags
	if !match_titles do flags -= {.Match_Titles}
	root_line := 0
	if c.top != nil && c.top != sm {
		root_line = c.root_line if c.root_line != 0 else max(abs_line_number(c.top), 0)
	}
	p := new_parser(c, flags, 0) // only Parser.parse (string input) checks line lengths
	p.root_line = root_line
	hook := setup_include_hook(c, sm, &p)
	text := sl_join(lines, c.allocator)
	tree_doc, _, _ := rst.parse_text(&p, text, sm.input_offset, match_titles, sl_len(lines))
	build_items(c, &p.tree, rst.first_child(&p.tree, tree_doc), 0, sm, true)
	sm.line_offset = sl_len(lines)
	// where docutils' nested state machines left the document
	set_current_line(c, sm, p.cur_line)
	return hook
}

// ``RSTState.nested_parse(block, input_offset, node, match_titles)`` of a
// state of ``sm``; returns the new input offset.
nested_parse :: proc(
	c: ^Context,
	sm: ^Machine,
	block: ^String_List,
	input_offset: int,
	node: dt.Node,
	match_titles_in := false,
) -> int {
	match_titles := match_titles_in
	if node == sm.node && !dt.is(c.doc, node, {.document, .section}) do match_titles = false
	child := Machine {
		lines        = block,
		input_offset = input_offset,
		line_offset  = -1,
		node         = node,
		match_titles = match_titles,
		parent       = sm,
	}
	if match_titles {
		l_node := len(dt.section_hierarchy(c.doc, node))
		l_start := min(len(dt.section_hierarchy(c.doc, sm.node)), len(c.title_styles))
		child.section_level_offset = l_start - l_node
	}
	block_length := sl_len(block)
	hook := parse_lines(c, &child, block, match_titles)
	moved_past_insertions(c, sm, block, input_offset, hook)
	remove_insertions(c, &child, hook)
	if match_titles && node == sm.node {
		for m := sm; m != nil; m = m.parent do m.node = child.node
	}
	new_offset := child.input_offset + sl_len(block)
	if block.parent != nil && sl_len(block.parent) > 0 && sl_len(block) != block_length {
		sm.line_offset += sl_len(block) - block_length
	}
	return new_offset
}

// ``RSTState.inline_text(text, lineno)`` with ``container`` as
// ``Inliner.parent``: the nodes and the messages.
inline_text :: proc(
	c: ^Context,
	text: string,
	lineno: int,
	container: dt.Node,
) -> (
	nodes: [dynamic]dt.Node,
	msgs: [dynamic]dt.Node,
) {
	flags := c.flags - {.Match_Titles}
	p := new_parser(c, flags, 0)
	items := rst.parse_inline(&p, text, lineno)
	nodes = make([dynamic]dt.Node, c.allocator)
	msgs = make([dynamic]dt.Node, c.allocator)
	build_inline(c, &p.tree, items.first, lineno, container, &nodes, &msgs)
	return
}
