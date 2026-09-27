package main

// publish-differential: the native side of tests/native_publish_differential.py.
//
// Reads a JSON array of cases ``{name, text, source_path, writer, overrides, cwd}``
// (``overrides`` as docutils takes them: None, booleans, integers, strings, lists of
// strings and ``smartquotes_locales`` pairs), publishes each with ``publish.publish``
// in its working directory and prints one JSON object per line:
//
//     {"name", "output", "parts": [[name, value]...], "messages", "report", "status"}
//
// ``messages`` is the text written to the warning stream, ``report`` what
// ``publish_cmdline`` writes about a failure.
//
// Usage: publish-differential [--docutils-dir DIR] CASES.json

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strings"

import pb "../.."

Case :: struct {
	name:        string,
	text:        string,
	source_path: string,
	writer:      string,
	cwd:         string,
	overrides:   []pb.Override,
}

Outcome :: struct {
	name:     string,
	output:   string,
	parts:    [][2]string,
	messages: string,
	report:   string,
	status:   int,
}

main :: proc() {
	args := os.args[1:]
	docutils_dir := ""
	if len(args) >= 2 && args[0] == "--docutils-dir" {
		docutils_dir = args[1]
		args = args[2:]
	}
	if len(args) != 1 {
		fmt.eprintln("usage: publish-differential [--docutils-dir DIR] CASES.json")
		os.exit(2)
	}
	data, err := os.read_entire_file_from_path(args[0], context.allocator)
	if err != nil {
		fmt.eprintfln("%s: %v", args[0], err)
		os.exit(2)
	}
	value, perr := json.parse(data, parse_integers = true)
	if perr != nil {
		fmt.eprintfln("%s: %v", args[0], perr)
		os.exit(2)
	}
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do os.exit(2)
	scratch := virtual.arena_allocator(&arena)
	for v in value.(json.Array) or_else nil {
		c := case_of(v, scratch)
		os.set_working_directory(c.cwd)
		run_case(c, pb.Options{docutils_dir = docutils_dir}, scratch)
		free_all(scratch)
	}
}

run_case :: proc(c: Case, options: pb.Options, scratch: runtime.Allocator) {
	context.allocator = scratch
	context.temp_allocator = scratch
	output, parts, messages, status, err := pb.publish(c.text, c.source_path, c.writer,
		c.overrides, options)
	out := Outcome {
		name   = c.name,
		output = output,
		parts  = make([][2]string, len(parts.items)),
		report = pb.error_report(err),
		status = status,
	}
	for p, i in parts.items do out.parts[i] = {p.name, p.value}
	b := strings.builder_make()
	for m in messages do strings.write_string(&b, m.text)
	out.messages = strings.to_string(b)
	line, merr := json.marshal(out)
	if merr != nil {
		fmt.eprintfln("%s: cannot marshal: %v", c.name, merr)
		return
	}
	os.write(os.stdout, line)
	os.write_string(os.stdout, "\n")
}

case_of :: proc(v: json.Value, allocator := context.allocator) -> Case {
	obj := v.(json.Object) or_else nil
	c := Case {
		name        = obj["name"].(json.String) or_else "",
		text        = obj["text"].(json.String) or_else "",
		source_path = obj["source_path"].(json.String) or_else "",
		writer      = obj["writer"].(json.String) or_else "",
		cwd         = obj["cwd"].(json.String) or_else ".",
	}
	overrides := obj["overrides"].(json.Object) or_else nil
	list := make([dynamic]pb.Override, 0, len(overrides), allocator)
	for name, value in overrides {
		append(&list, pb.Override{name, setting_value(value, allocator)})
	}
	c.overrides = list[:]
	return c
}

// A docutils setting value: lists of strings, and pairs as "a:b" items.
setting_value :: proc(v: json.Value, allocator := context.allocator) -> pb.Value {
	#partial switch x in v {
	case json.Null:
		return pb.None{}
	case json.Boolean:
		return bool(x)
	case json.Integer:
		return int(x)
	case json.String:
		return string(x)
	case json.Array:
		items := make([]string, len(x), allocator)
		for e, i in x do items[i] = item_text(e, allocator)
		return items
	}
	return pb.None{}
}

@(private = "file")
item_text :: proc(v: json.Value, allocator := context.allocator) -> string {
	#partial switch x in v {
	case json.String:
		return x
	case json.Array:
		parts := make([]string, len(x), allocator)
		for e, i in x do parts[i] = item_text(e, allocator)
		return strings.join(parts, ":", allocator)
	}
	return ""
}
