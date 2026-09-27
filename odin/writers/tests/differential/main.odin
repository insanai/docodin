package main

// writers-differential: compare the native writers with docutils.
//
// Reads doctree interchange dumps at stage "output" (scripts/doctree_json.py
// --stage output), writes each document with the dump's writer and compares
// the output and every ``publish_parts`` part with docutils' (the dump's
// ``expected``).  Prints one line per dump:
//
//     PASS <path>
//     FAIL <path> <part> <offset>: <expected excerpt> | <actual excerpt>
//     SKIP <path> <reason>
//     ERROR <path> <message>
//
// Usage: writers-differential [--save DIR] LIST
//
// LIST names one dump per line, optionally followed by a tab and the working
// directory to write it in (the directory it was dumped in, for relative
// paths of images and stylesheets).  With --save, the output of each failing
// dump is written to DIR/<name>.out.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

import dt "../../../doctree"
import wr "../.."

Totals :: struct {
	pass, fail, skip, error: int,
	writing:                 time.Duration, // time spent in ``write``
}

main :: proc() {
	args := os.args[1:]
	save := ""
	if len(args) >= 2 && args[0] == "--save" {
		save = args[1]
		args = args[2:]
	}
	if len(args) != 1 {
		fmt.eprintln("usage: writers-differential [--save DIR] LIST")
		os.exit(2)
	}
	data, err := os.read_entire_file_from_path(args[0], context.allocator)
	if err != nil {
		fmt.eprintfln("%s: %v", args[0], err)
		os.exit(2)
	}
	start, _ := os.get_working_directory(context.allocator)
	totals: Totals
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		if line == "" do continue
		path, _, cwd := strings.partition(line, "\t")
		os.set_working_directory(cwd if cwd != "" else start)
		abs := path if strings.has_prefix(path, "/") else strings.concatenate({start, "/", path})
		check(abs, save, &totals)
		free_all(context.temp_allocator)
	}
	fmt.printfln(
		"TOTAL pass=%d fail=%d skip=%d error=%d write=%.3fs",
		totals.pass,
		totals.fail,
		totals.skip,
		totals.error,
		time.duration_seconds(totals.writing),
	)
}

check :: proc(path, save: string, totals: ^Totals) {
	data, rerr := os.read_entire_file_from_path(path, context.temp_allocator)
	if rerr != nil {
		totals.error += 1
		fmt.printfln("ERROR %s cannot read: %v", path, rerr)
		return
	}
	doc, lerr := dt.load_json(string(data))
	if lerr != nil {
		totals.error += 1
		fmt.printfln("ERROR %s cannot load: %v", path, lerr)
		return
	}
	defer dt.destroy(doc)
	expected, has_expected := doc.interchange.expected.(json.Object)
	want_output, has_output := expected["output"].(json.String)
	input, _ := doc.interchange.input.(json.Object)
	writer_name, _ := input["writer"].(json.String)
	writer, known := wr.writer_by_name(writer_name)
	switch {
	case !has_expected || !has_output:
		totals.skip += 1
		fmt.printfln("SKIP %s no expected output", path)
		return
	case !known:
		totals.skip += 1
		fmt.printfln("SKIP %s writer %s", path, writer_name)
		return
	}
	settings := wr.settings_for(doc, writer)
	start := time.tick_now()
	output, parts, werr := wr.write(doc, writer, settings, context.temp_allocator)
	totals.writing += time.tick_since(start)
	if werr != "" {
		totals.fail += 1
		fmt.printfln("FAIL %s error %s", path, one_line(werr))
		return
	}
	if !compare(path, "output", want_output, output) || !compare_parts(path, expected, parts) {
		totals.fail += 1
		if save != "" do save_output(save, path, output)
		return
	}
	totals.pass += 1
	fmt.printfln("PASS %s", path)
}

compare_parts :: proc(path: string, expected: json.Object, parts: wr.Parts) -> bool {
	want_parts, _ := expected["parts"].(json.Object)
	for name, v in want_parts {
		want, _ := v.(json.String)
		got, ok := wr.part(parts, name)
		if !ok {
			fmt.printfln("FAIL %s %s missing", path, name)
			return false
		}
		if !compare(path, name, want, got) do return false
	}
	for p in parts.items {
		if p.name not_in want_parts {
			fmt.printfln("FAIL %s %s unexpected", path, p.name)
			return false
		}
	}
	return true
}

compare :: proc(path, name, want, got: string) -> bool {
	if want == got do return true
	i := 0
	for i < len(want) && i < len(got) && want[i] == got[i] do i += 1
	fmt.printfln(
		"FAIL %s %s %d: %s | %s",
		path,
		name,
		i,
		excerpt(want, i),
		excerpt(got, i),
	)
	return false
}

excerpt :: proc(s: string, i: int) -> string {
	a := max(0, i - 40)
	b := min(len(s), i + 60)
	return one_line(s[a:b])
}

one_line :: proc(s: string) -> string {
	out, _ := strings.replace_all(s, "\n", "\\n", context.temp_allocator)
	return out
}

save_output :: proc(dir, path, output: string) {
	name := path[strings.last_index_byte(path, '/') + 1:]
	out := strings.concatenate({dir, "/", name, ".out"}, context.temp_allocator)
	_ = os.write_entire_file(out, transmute([]u8)output)
}
