package reader

import dt "../doctree"
import rst "../rst"

// ``include`` insertions: lines ``state_machine.insert_input()`` adds to the
// input.
//
// docutils parses inserted lines in the state machine that ran the
// directive, as part of its input.  The native parser does the same through
// its include hook (``include_hook``): for each directive it meets, the hook
// dry-runs ``include`` (no side effects) and returns the lines it would
// insert; the parser inserts them and parses on, and the hook inserts them
// into the reader's input lines at the same place, so line lookups stay in
// step.  When the builder runs the directive for real, ``insert_input``
// is skipped.
//
// Nested parses (directive content) end before the enclosing parse goes
// on, so their insertions are removed again afterwards
// (``remove_insertions``) and restored for transforms at the end
// (``restore_insertions``), like the insertions the hook cannot make
// (``include`` inside substitution definitions or table cells), which are
// parsed separately (``process_inserted_input``).

// What ``insert_input`` does.
Insert_Mode :: enum u8 {
	Insert, // insert the lines
	Capture, // an include dry run: record them
	Skip, // the parser inserted them already
}

// The lines a dry run's ``insert_input`` received.
Captured_Insert :: struct {
	lines:  []string,
	source: string,
}

// A state machine's cursor moved past lines inserted by a nested parse
// (docutils ``next_line``): the next ``set_current_line`` with the native
// cursor ``cur`` uses this position instead.
Moved_Cursor :: struct {
	set:    bool,
	cur:    int,
	source: Maybe(string),
	line:   Maybe(int),
}

// ``document.include_log`` as the parser sees it: the index (in the parse's
// input lines) of the entry's end-of-inclusion comment, -1 for entries
// that end outside the parse.
@(private = "file")
Log_Entry :: struct {
	entry: Include_Entry,
	end:   int,
}

// The include hook of one native parse (of ``sm``'s input lines).
Include_State :: struct {
	c:        ^Context,
	sm:       ^Machine,
	inserted: [dynamic][2]int, // (index, number of lines) in insertion order
	log:      [dynamic]Log_Entry,
}

// Install the include hook for a parse of ``sm``'s lines by ``p``.
setup_include_hook :: proc(c: ^Context, sm: ^Machine, p: ^rst.Parser) -> ^Include_State {
	st := new(Include_State, c.allocator)
	st.c = c
	st.sm = sm
	st.inserted = make([dynamic][2]int, c.allocator)
	st.log = make([dynamic]Log_Entry, c.allocator)
	for e in c.include_log do append(&st.log, Log_Entry{e, -1})
	p.include_hook = include_hook
	p.hook_data = st
	return st
}

// The number of lines the parser inserted.
inserted_lines :: proc(st: ^Include_State) -> int {
	n := 0
	for ins in st.inserted do n += ins[1]
	return n
}

@(private = "file")
include_hook :: proc(
	data: rawptr,
	p: ^rst.Parser,
	_: ^rst.State_Machine,
	d: rst.Node,
) -> (
	lines: []string,
	insert: bool,
) {
	st := (^Include_State)(data)
	c, sm := st.c, st.sm
	if !is_include(c, rst.node_name(&p.tree, d)) do return nil, false
	info, _ := rst.directive_info(&p.tree, d)
	index := info.end_offset - sm.input_offset // the directive's last line
	captured, ok := dry_run(st, &p.tree, d, info, index)
	if !ok do return nil, false
	note_insertion(st, index + 1, len(captured.lines) + 2)
	saved := sm.line_offset
	sm.line_offset = index
	insert_input(c, sm, captured.lines, captured.source)
	sm.line_offset = saved
	return captured.lines, true
}

// Is ``name`` the (English) ``include`` directive?
@(private = "file")
is_include :: proc(c: ^Context, name: string) -> bool {
	return dt.py_lower(name, c.allocator) == "include"
}

// Run ``include`` without side effects: the lines it would insert.
@(private = "file")
dry_run :: proc(
	st: ^Include_State,
	t: ^rst.Tree,
	n: rst.Node,
	info: rst.Directive_Info,
	index: int,
) -> (
	captured: Captured_Insert,
	ok: bool,
) {
	c, sm := st.c, st.sm
	doc := c.doc
	saved_source, saved_line, saved_offset := doc.current_source, doc.current_line, sm.line_offset
	saved_log := c.include_log
	defer {
		doc.current_source, doc.current_line = saved_source, saved_line
		sm.line_offset = saved_offset
		c.include_log = saved_log
		c.dry_run, c.dry_run_failed, c.insert_mode = false, false, .Insert
		clear(&c.captured)
	}
	set_current(c, sm, info.end_offset + 1)
	sm.line_offset = index
	d := Directive {
		name       = rst.node_name(t, n),
		lineno     = rst.node_line(t, n),
		block_text = rst.node_raw(t, n),
		sm         = sm,
		spec       = &INCLUDE,
		options    = make(Options, c.allocator),
	}
	c.dry_run = true
	indented := block_lines(c, sm, info.lines, info.line_offset)
	if parse_directive_block(c, &d, indented, info.line_offset) != "" || c.dry_run_failed do return
	// no insertion: the run would create (and register) nodes
	for name in ([]string{"literal", "code", "parser"}) {
		if options_has(&d.options, name) do return
	}
	return run_dry(st, &d, index)
}

// Run the parsed directive with the include log the parser sees and
// ``insert_input`` captured.
@(private = "file")
run_dry :: proc(st: ^Include_State, d: ^Directive, index: int) -> (Captured_Insert, bool) {
	c := st.c
	c.include_log = make([dynamic]Include_Entry, c.allocator)
	for e in st.log do if e.end < 0 || e.end >= index do append(&c.include_log, e.entry)
	logged := len(c.include_log)
	c.insert_mode = .Capture
	_, err := INCLUDE.run(c, d)
	if err != nil || len(c.captured) == 0 do return {}, false
	added := c.include_log[logged:]
	for e, i in added do append(&st.log, Log_Entry{e, -1 if i < len(added) - 1 else -2})
	return c.captured[0], true
}

// ``count`` lines inserted at ``at``: later ends move down; the newest log
// entry ends at the inserted end-of-inclusion comment.
@(private = "file")
note_insertion :: proc(st: ^Include_State, at, count: int) {
	for &e in st.log {
		if e.end == -2 do e.end = at + count - 2
		else if e.end >= at do e.end += count
	}
	append(&st.inserted, [2]int{at, count})
}

// ``state_machine.insert_input(lines, source)``.
insert_input :: proc(c: ^Context, sm: ^Machine, lines: []string, source: string) {
	switch c.insert_mode {
	case .Capture:
		append(&c.captured, Captured_Insert{lines, source})
		return
	case .Skip:
		return
	case .Insert:
	}
	il := input_lines(c, sm)
	a := c.allocator
	after := concat("internal padding after ", source, allocator = a)
	before := concat("internal padding before ", source, allocator = a)
	sl_insert_line(il, sm.line_offset + 1, "", {after, len(lines)})
	sl_insert_line(il, sm.line_offset + 1, "", {before, -1})
	sl_insert_list(il, sm.line_offset + 2, sl_make(lines, source, a))
}

// After a nested parse of ``block`` (a slice of ``sm``'s lines) into which
// the parser inserted lines: docutils moves ``sm`` past them (``next_line``,
// which notes the source of the new line).
moved_past_insertions :: proc(
	c: ^Context,
	sm: ^Machine,
	block: ^String_List,
	input_offset: int,
	st: ^Include_State,
) {
	inserted := inserted_lines(st)
	connected := block.parent != nil && sl_len(block.parent) > 0
	if inserted == 0 || !(connected || sm.disconnected) do return
	if connected {
		note_line(c, input_lines(c, sm), sm.line_offset + inserted)
	} else { 	// the enclosing input is a disconnected block: the line is in ``block``
		note_line(c, block, sm.line_offset + sm.input_offset - input_offset + inserted)
	}
	c.moved_cursor = {
		set    = true,
		cur    = sm.line_offset + sm.input_offset + 1 + sm.line_delta, // the native cursor
		source = c.doc.current_source,
		line   = c.doc.current_line,
	}
}

// ``document.note_source`` of the line at ``index`` of ``lines``.
note_line :: proc(c: ^Context, lines: ^String_List, index: int) {
	info, has_offset, ok := sl_info(lines, index)
	if !ok {
		c.doc.current_source, c.doc.current_line = nil, nil
		return
	}
	c.doc.current_source = info.source
	c.doc.current_line = info.offset + 1 if has_offset else nil
}

// Drop the lines the parser inserted into a nested parse's input (the
// enclosing parse numbers its lines without them); ``restore_insertions``
// puts them back at the end.
remove_insertions :: proc(c: ^Context, sm: ^Machine, st: ^Include_State) {
	if len(st.inserted) == 0 do return
	lines := input_lines(c, sm)
	// insertions into a list the document's input lines do not see
	// (``disconnect()``-ed blocks: table cells) leave its numbering alone
	connected := reaches(lines, c.top.lines if c.top != nil else nil)
	#reverse for ins in st.inserted {
		at, count := ins[0], ins[1]
		if connected {
			block := sl_slice(lines, at, at + count)
			saved := sl_make_items(block.data[:], block.items[:], c.allocator)
			append(&c.insertions, Insertion{sm.input_offset + at, saved})
			c.last_removal_top = false
			c.removed_lines += count
		}
		for _ in 0 ..< count do sl_delete(lines, at)
	}
	clear(&st.inserted)
}

// Do insertions into ``lines`` reach ``top`` (through parent views)?
@(private = "file")
reaches :: proc(lines, top: ^String_List) -> bool {
	for l := lines; l != nil; l = l.parent if l.parent != nil && sl_len(l.parent) > 0 else nil {
		if l == top do return true
	}
	return false
}

// Parse the lines ``insert_input()`` put after the directive that ``sm``
// ran (where the parser could not insert them), then drop them again so
// that the absolute line offsets of the remaining (already parsed) input
// stay valid.
process_inserted_input :: proc(c: ^Context, sm: ^Machine, before: int) {
	lines := input_lines(c, sm)
	start := sm.line_offset + 1
	count := sl_len(lines) - before
	if count <= 0 do return
	// A connected slice: nested insertions propagate to the parent lists,
	// as in docutils, so reporter line lookups keep working.
	inserted := sl_slice(lines, start, start + count)
	child := Machine {
		lines                = inserted,
		input_offset         = sm.input_offset + start,
		line_offset          = -1,
		node                 = sm.node,
		match_titles         = sm.match_titles,
		parent               = sm.parent,
		section_level_offset = sm.section_level_offset,
	}
	remove_insertions(c, &child, parse_lines(c, &child, inserted, sm.match_titles))
	if sm.match_titles do sm.node = child.node
	// recorded in removal order, without the (already removed) nested ones
	saved := sl_make_items(inserted.data[:], inserted.items[:], c.allocator)
	append(&c.insertions, Insertion{sm.input_offset + start, saved})
	c.last_removal_top = sm == c.top
	for _ in 0 ..< count do sl_delete(lines, start)
	c.removed_lines += count
}

// Give transforms docutils' view of the input after removed insertions:
// the blocks go back into the input lines (latest removal first) and nodes
// that only carry an absolute line are renumbered.
restore_insertions :: proc(c: ^Context, sm: ^Machine) {
	lines := input_lines(c, sm)
	#reverse for ins in c.insertions {
		sl_insert_list(lines, ins.offset - sm.input_offset, ins.lines)
	}
	for n, removed in c.absolute_lines {
		if ln, ok := dt.line(c.doc, n); ok do dt.set_line(c.doc, n, ln + removed)
	}
	clear(&c.insertions)
	clear(&c.absolute_lines)
}

// The last input line is the padding ``insert_input()`` puts after an
// insertion.
ends_with_insertion :: proc(c: ^Context, sm: ^Machine) -> bool {
	lines := input_lines(c, sm)
	if sl_len(lines) == 0 do return false
	info, _, _ := sl_info(lines, sl_len(lines) - 1)
	return has_prefix(info.source, "internal padding after ")
}
