package doctree_tests

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

import dt ".."

// The doctree interchange: every dump of fixtures/interchange (written by
// scripts/doctree_interchange_fixtures.py with docutils) must load, give
// docutils' ``document.pformat()`` and dump back byte-identically.  Set
// DOCTREE_INTERCHANGE_DIR to a directory of dumps to check a whole corpus:
//
//     PY="uv run --no-project --python 3.14 --with docutils==0.22.4 python"
//     $PY scripts/doctree_interchange_fixtures.py --docutils-src DIR --corpus /tmp/corpus
//     DOCTREE_INTERCHANGE_DIR=/tmp/corpus odin test odin/doctree/tests -vet -strict-style

FIXTURE_DIR :: #directory + "/fixtures/interchange"

@(private = "file")
Outcome :: struct {
	files:    int,
	failures: int,
}

@(private = "file")
check_dump :: proc(t: ^testing.T, name, data: string, out: ^Outcome) {
	out.files += 1
	doc, err := dt.load_json(data)
	if err != nil {
		out.failures += 1
		testing.expectf(t, false, "%s: cannot load: %v", name, err)
		return
	}
	defer dt.destroy(doc)
	want := doc.interchange.expected.(json.Object)["pformat"].(json.String) or_else "<none>"
	got := dt.pformat(doc, doc.root, allocator = context.temp_allocator)
	dump := dt.dump_json(doc, context.temp_allocator)
	ok := true
	if got != want {
		ok = false
		testing.expectf(t, false, "%s: pformat differs at %s", name, first_difference(got, want))
	}
	if dump != data {
		ok = false
		testing.expectf(t, false, "%s: dump differs at %s", name, first_difference(dump, data))
	}
	if !ok do out.failures += 1
}

// Check every ``.json`` file of ``dir``.
@(private = "file")
check_dir :: proc(t: ^testing.T, dir: string) -> Outcome {
	out: Outcome
	files, err := os.read_all_directory_by_path(dir, context.allocator)
	if err != nil {
		testing.expectf(t, false, "%s: %v", dir, err)
		return out
	}
	defer os.file_info_slice_delete(files, context.allocator)
	slice.sort_by(files, proc(a, b: os.File_Info) -> bool {return a.name < b.name})
	for f in files {
		if !strings.has_suffix(f.name, ".json") do continue
		data, rerr := os.read_entire_file_from_path(f.fullpath, context.allocator)
		if rerr != nil {
			testing.expectf(t, false, "%s: %v", f.fullpath, rerr)
			continue
		}
		check_dump(t, f.name, string(data), &out)
		delete(data)
		free_all(context.temp_allocator)
		if out.failures >= 20 do break
	}
	return out
}

@(test)
test_interchange_fixtures :: proc(t: ^testing.T) {
	out := check_dir(t, FIXTURE_DIR)
	testing.expectf(t, out.files > 0, "no dumps in %s", FIXTURE_DIR)
	testing.expectf(t, out.failures == 0, "%d of %d dumps fail", out.failures, out.files)
}

@(test)
test_interchange_corpus :: proc(t: ^testing.T) {
	dir := os.get_env("DOCTREE_INTERCHANGE_DIR", context.allocator)
	defer delete(dir)
	if dir == "" do return
	out := check_dir(t, dir)
	fmt.printfln("interchange corpus %s: %d dumps, %d failures", dir, out.files, out.failures)
	testing.expectf(t, out.failures == 0, "%d of %d dumps fail", out.failures, out.files)
}

// A document built natively (a detached registered node, a stale parent, a
// pending transform with node details, internal state, a float and a
// written message) dumps, loads and dumps again identically.
@(test)
test_interchange_native :: proc(t: ^testing.T) {
	s := dt.default_settings()
	s.warning_stream = .Collect
	s.report_level = 1
	doc := dt.new_document("n.rst", s)
	defer dt.destroy(doc)
	sec := dt.new_element(doc, .section)
	dt.append_child(doc, doc.root, sec)
	dt.list_append(doc, sec, "names", "intro")
	dt.note_implicit_target(doc, sec)
	title := dt.new_element(doc, .title, "Intro", "Intro")
	dt.append_child(doc, sec, title)
	target := dt.new_element(doc, .target)
	dt.append_child(doc, sec, target)
	dt.list_append(doc, target, "names", "gone")
	dt.note_explicit_target(doc, target)
	dt.remove_child(doc, sec, target) // registered, not in the tree
	dt.set_attr(doc, sec, "width", "1.5") // a float, as its repr
	dt.delete_attr(doc, sec, "dupnames")
	details := []dt.Detail{{"node", dt.Node(title)}, {"depth", 2}, {"none", dt.Detail_None{}}}
	p := dt.new_pending(doc, "docutils.transforms.parts.Contents", 720, details)
	dt.append_child(doc, sec, p)
	dt.note_pending(doc, p)
	line := dt.new_element(doc, .line, "", "x")
	dt.append_child(doc, sec, line)
	doc.internals[line] = {indent = 2, indirect_reference_name = "ref"}
	dt.info(doc, "a message", {base_node = title})
	first := dt.dump_json(doc, context.temp_allocator)
	loaded, err := dt.load_json(first)
	testing.expectf(t, err == nil, "load: %v", err)
	if err != nil do return
	defer dt.destroy(loaded)
	second := dt.dump_json(loaded, context.temp_allocator)
	testing.expectf(t, first == second, "native round trip at %s", first_difference(second, first))
	got := dt.pformat(loaded, loaded.root, allocator = context.temp_allocator)
	want := dt.pformat(doc, doc.root, allocator = context.temp_allocator)
	testing.expect_value(t, got, want)
	testing.expect(t, strings.contains(first, `"detached": [`), "the removed target is detached")
}

// Invalid dumps are rejected with a message.
@(test)
test_interchange_errors :: proc(t: ^testing.T) {
	cases := [?]string {
		`{"format": "other"}`,
		`[1]`,
		`{"format": "docodin-doctree/1", "settings": {}, "detached": [],
		  "tree": {"tag": "bogus"}}`,
	}
	for c in cases {
		doc, err := dt.load_json(c)
		testing.expectf(t, doc == nil && err != nil, "accepted: %s", c)
		if doc != nil do dt.destroy(doc)
	}
}
