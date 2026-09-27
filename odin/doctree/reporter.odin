package doctree

import "core:fmt"
import "core:os"
import "core:strings"

// ``docutils.utils.Reporter``: system message generation and reporting.
//
// Reaching the halt level raises ``SystemMessage`` in docutils; here the
// reporter records it in ``halted``/``halt_message`` and the caller stops.

Level :: enum u8 {
	DEBUG,
	INFO,
	WARNING,
	ERROR,
	SEVERE,
}

LEVEL_NAMES := [Level]string {
	.DEBUG   = "DEBUG",
	.INFO    = "INFO",
	.WARNING = "WARNING",
	.ERROR   = "ERROR",
	.SEVERE  = "SEVERE",
}

// Called with each new system message (``Reporter.attach_observer``).
Observer :: proc(doc: ^Doc, msg: Node)

// ``Reporter.get_source_and_line`` (patched in by the rST state machine):
// the source and line of an absolute line number (or of the current line).
Source_Line_Proc :: proc(doc: ^Doc, data: rawptr, line: Maybe(int)) -> (Maybe(string), Maybe(int))

// A message as written to the warning stream (``msg.astext()``); ``node``
// is 0 for a message of another reporter writing to the same stream (the
// document of a nested parse).
Written_Message :: struct {
	level: Level,
	node:  Node,
	text:  string,
}

Reporter :: struct {
	source:           string,
	report_level:     int,
	halt_level:       int,
	debug_flag:       bool,
	stream:           Warning_Stream,
	observers:        [dynamic]Observer,
	source_and_line:  Source_Line_Proc,
	source_line_data: rawptr,
	max_level:        int, // highest level generated so far, -1: none
	// The first message that reached ``halt_level`` (where docutils raises
	// ``SystemMessage``), and the reporter's state then: ``max_level`` and
	// the number of ``written`` messages (the halting one included).
	halted:           bool,
	halt_message:     Node,
	halt_max_level:   int,
	halt_written:     int,
	written:          [dynamic]Written_Message,
}

// Keyword arguments of ``Reporter.system_message``.
Message_Options :: struct {
	base_node: Node, // source and line default to those of this node
	source:    Maybe(string),
	line:      Maybe(int),
	backrefs:  []string,
	children:  []Node, // added after the message paragraph
}

// ``utils.new_reporter(source_path, settings)``.
init_reporter :: proc(doc: ^Doc, source: string) {
	s := &doc.settings
	doc.reporter = Reporter {
		source       = clone(doc, source),
		report_level = s.report_level,
		halt_level   = s.halt_level,
		debug_flag   = s.debug,
		stream       = s.warning_stream,
		observers    = make([dynamic]Observer, doc.allocator),
		max_level    = -1,
		written      = make([dynamic]Written_Message, doc.allocator),
	}
}

attach_observer :: proc(doc: ^Doc, observer: Observer) {
	append(&doc.reporter.observers, observer)
}

detach_observer :: proc(doc: ^Doc, observer: Observer) {
	obs := &doc.reporter.observers
	for o, i in obs {
		if o == observer {
			ordered_remove(obs, i)
			return
		}
	}
}

// ``utils.get_source_line(node)``: the source and line of ``n`` or of its
// closest ancestor that has either.
get_source_line :: proc(doc: ^Doc, n: Node) -> (src: Maybe(string), ln: Maybe(int)) {
	for m := n; m != 0; m = doc.nodes[m].parent {
		e := &doc.nodes[m]
		has_src := .Has_Source in e.flags && doc.strings[e.source] != ""
		has_line := .Has_Line in e.flags && e.line != 0
		if !has_src && !has_line do continue
		if .Has_Source in e.flags do src = doc.strings[e.source]
		if .Has_Line in e.flags do ln = int(e.line)
		return
	}
	return nil, nil
}

// The source and line attributes of a new message (as computed in
// ``Reporter.system_message``).
@(private = "file")
message_location :: proc(
	doc: ^Doc,
	opts: Message_Options,
) -> (
	src: Maybe(string),
	ln: Maybe(int),
) {
	src, ln = opts.source, opts.line
	if opts.base_node != 0 {
		bsrc, bline := get_source_line(doc, opts.base_node)
		if src == nil do src = bsrc
		if ln == nil do ln = bline
	}
	if src == nil {
		r := &doc.reporter
		if r.source_and_line != nil {
			hsrc, hline := r.source_and_line(doc, r.source_line_data, ln)
			if hsrc != nil do src = hsrc
			if hline != nil do ln = hline
		}
	}
	if src == nil do src = doc.reporter.source
	return
}

// ``Reporter.system_message(level, message, *children, **kwargs)``.
system_message :: proc(
	doc: ^Doc,
	level: Level,
	message: string,
	opts := Message_Options{},
) -> Node {
	msg := new_message(doc, level, message, opts)
	report(doc, level, msg)
	return msg
}

// The reporting part of ``Reporter.system_message`` for the message
// ``msg``: written to the stream, the halt level (``SystemMessage``), the
// observers and ``max_level``.
report :: proc(doc: ^Doc, level: Level, msg: Node) {
	r := &doc.reporter
	lv := int(level)
	loud := lv >= r.report_level || (r.debug_flag && level == .DEBUG) || lv >= r.halt_level
	if r.stream != .Discard && loud do write_message(doc, level, msg)
	if lv >= r.halt_level {
		if !r.halted {
			r.halted = true
			r.halt_message = msg
			r.halt_max_level = r.max_level
			r.halt_written = len(r.written)
		}
		return
	}
	if level > .DEBUG || r.debug_flag {
		for o in r.observers do o(doc, msg)
	}
	r.max_level = max(lv, r.max_level)
}

// The ``system_message`` element (``nodes.system_message(message,
// *children, level=, type=, **attributes)``).
@(private = "file")
new_message :: proc(doc: ^Doc, level: Level, message: string, opts: Message_Options) -> Node {
	src, ln := message_location(doc, opts)
	msg := alloc_node(doc, .system_message, "")
	if message != "" do append_child(doc, msg, new_element(doc, .paragraph, "", message))
	extend_children(doc, msg, opts.children)
	set_attr(doc, msg, K_LEVEL, int(level))
	set_attr(doc, msg, K_TYPE, LEVEL_NAMES[level])
	if len(opts.backrefs) > 0 do set_list(doc, msg, K_BACKREFS, ..opts.backrefs)
	if s, ok := src.?; ok do set_attr(doc, msg, K_SOURCE, s)
	if l, ok := ln.?; ok do set_attr(doc, msg, K_LINE, l)
	return msg
}

@(private = "file")
write_message :: proc(doc: ^Doc, level: Level, msg: Node) {
	b := strings.builder_make(doc.allocator)
	write_astext(&b, doc, msg)
	strings.write_byte(&b, '\n')
	text := strings.to_string(b)
	append(&doc.reporter.written, Written_Message{level, msg, text})
	if doc.reporter.stream == .Stderr do fmt.fprint(os.stderr, text)
}

// ``Reporter.debug``: a message only with the ``debug`` setting (else 0).
debug :: proc(doc: ^Doc, message: string, opts := Message_Options{}) -> Node {
	if !doc.reporter.debug_flag do return 0
	return system_message(doc, .DEBUG, message, opts)
}

info :: proc(doc: ^Doc, message: string, opts := Message_Options{}) -> Node {
	return system_message(doc, .INFO, message, opts)
}

warning :: proc(doc: ^Doc, message: string, opts := Message_Options{}) -> Node {
	return system_message(doc, .WARNING, message, opts)
}

error :: proc(doc: ^Doc, message: string, opts := Message_Options{}) -> Node {
	return system_message(doc, .ERROR, message, opts)
}

severe :: proc(doc: ^Doc, message: string, opts := Message_Options{}) -> Node {
	return system_message(doc, .SEVERE, message, opts)
}

// Observer adding messages to ``document.parse_messages``.
observe_parse_message :: proc(doc: ^Doc, msg: Node) {
	note_parse_message(doc, msg)
}

// Observer adding messages to ``document.transform_messages``.
observe_transform_message :: proc(doc: ^Doc, msg: Node) {
	note_transform_message(doc, msg)
}
