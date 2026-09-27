package writers_tests

import "core:encoding/json"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

import dt "../../doctree"
import wr ".."

// The native writers against docutils: every dump at stage "output" of the
// doctree interchange fixtures (odin/doctree/tests/fixtures/interchange) is
// written with its writer, and the output and every ``publish_parts`` part
// must be docutils' byte for byte.  Set WRITERS_DUMP_DIR to a directory of
// dumps to check a corpus, e.g. one written by
// tests/native_writers_differential.py --keep (which also runs a faster
// differential runner, odin/writers/tests/differential, on its corpus).

FIXTURE_DIR :: #directory + "/../../doctree/tests/fixtures/interchange"

@(private = "file")
Outcome :: struct {
	files:    int,
	failures: int,
}

@(private = "file")
first_difference :: proc(a, b: string) -> int {
	i := 0
	for i < len(a) && i < len(b) && a[i] == b[i] do i += 1
	return i
}

@(private = "file")
check_part :: proc(t: ^testing.T, name, part, want, got: string) -> bool {
	if want == got do return true
	i := first_difference(want, got)
	testing.expectf(
		t,
		false,
		"%s: %s differs at %d: %q | %q",
		name,
		part,
		i,
		want[max(0, i - 30):min(len(want), i + 50)],
		got[max(0, i - 30):min(len(got), i + 50)],
	)
	return false
}

// With ``native``, the writer settings come from ``doctree.Settings`` (the
// settings of the native pipeline) instead of the dumped docutils settings.
@(private = "file")
check_dump :: proc(t: ^testing.T, name, data: string, out: ^Outcome, native := false) {
	doc, err := dt.load_json(data)
	if err != nil {
		testing.expectf(t, false, "%s: cannot load: %v", name, err)
		out.failures += 1
		return
	}
	defer dt.destroy(doc)
	expected := doc.interchange.expected.(json.Object) or_else nil
	want, has_output := expected["output"].(json.String)
	input := doc.interchange.input.(json.Object) or_else nil
	writer, known := wr.writer_by_name(input["writer"].(json.String) or_else "")
	if !has_output || !known do return
	out.files += 1
	if native do doc.interchange.settings = nil
	settings := wr.settings_for(doc, writer)
	output, parts, werr := wr.write(doc, writer, settings, context.temp_allocator)
	ok := werr == ""
	if !ok do testing.expectf(t, false, "%s: %s", name, werr)
	ok = ok && check_part(t, name, "output", want, output)
	want_parts := expected["parts"].(json.Object) or_else nil
	for key, value in want_parts {
		got, found := wr.part(parts, key)
		ok = ok && found && check_part(t, name, key, value.(json.String) or_else "", got)
	}
	ok = ok && len(parts.items) == len(want_parts)
	if !ok do out.failures += 1
}

@(private = "file")
check_dir :: proc(t: ^testing.T, dir: string, native := false) -> Outcome {
	out: Outcome
	files, err := os.read_all_directory_by_path(dir, context.allocator)
	if err != nil {
		testing.expectf(t, false, "%s: %v", dir, err)
		return out
	}
	defer os.file_info_slice_delete(files, context.allocator)
	slice.sort_by(files, proc(a, b: os.File_Info) -> bool {return a.name < b.name})
	for f in files {
		if !strings.has_suffix(f.name, ".json") {
			continue
		}
		data, rerr := os.read_entire_file_from_path(f.fullpath, context.allocator)
		if rerr != nil {
			testing.expectf(t, false, "%s: %v", f.fullpath, rerr)
			continue
		}
		check_dump(t, f.name, string(data), &out, native)
		delete(data)
		free_all(context.temp_allocator)
		if out.failures >= 20 do break
	}
	return out
}

@(test)
fixtures :: proc(t: ^testing.T) {
	out := check_dir(t, FIXTURE_DIR)
	testing.expect(t, out.files > 0, "no output fixtures")
	testing.expectf(t, out.failures == 0, "%d of %d dumps differ", out.failures, out.files)
}

// The fixtures were written with the default settings of each writer, which
// ``doctree.Settings`` represents.
@(test)
native_settings :: proc(t: ^testing.T) {
	out := check_dir(t, FIXTURE_DIR, native = true)
	testing.expectf(t, out.failures == 0, "%d of %d dumps differ", out.failures, out.files)
}

@(test)
corpus :: proc(t: ^testing.T) {
	dir := os.get_env("WRITERS_DUMP_DIR", context.temp_allocator)
	if dir == "" do return
	out := check_dir(t, dir)
	testing.expectf(t, out.failures == 0, "%d of %d dumps differ", out.failures, out.files)
}
