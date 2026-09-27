package transforms_differential

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

import dt "../../../doctree"
import rd "../../../reader"
import tf "../.."

// The native side of tests/native_transforms_differential.py: for each case file
// (a meta line and the docutils dumps at stage ``parsed``, after each transform and at
// the end, separated by U+001E), load the ``parsed`` dump, apply the queue one
// transform at a time and compare ``dump_json`` with each dump.  Prints ``PASS name``
// or ``FAIL name ...`` per case, then ``STATS {transform: {identical, total}}``.
//
//     transforms-differential [--list FILE] [--save DIR] CASE...

SEP :: "\x1e"

Counts :: struct {
	identical: int,
	total:     int,
}

State :: struct {
	stats: map[string]Counts,
	save:  string, // directory for the native dump of a failing step
	trace: bool, // print each step to stderr before applying it
}

main :: proc() {
	st := State {
		stats = make(map[string]Counts),
	}
	files := make([dynamic]string)
	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "--list":
			i += 1
			data, err := os.read_entire_file_from_path(args[i], context.allocator)
			if err != nil do fatal("cannot read %s", args[i])
			for line in strings.split_lines(string(data)) do if line != "" do append(&files, line)
		case "--trace":
			st.trace = true
		case "--save":
			i += 1
			st.save = args[i]
		case:
			append(&files, args[i])
		}
	}
	for f in files {
		check_file(&st, f)
		free_all(context.temp_allocator)
	}
	print_stats(&st)
}

fatal :: proc(format: string, args: ..any) {
	fmt.eprintfln(format, ..args)
	os.exit(2)
}

print_stats :: proc(st: ^State) {
	b := strings.builder_make()
	strings.write_string(&b, "STATS {")
	first := true
	for name, c in st.stats {
		if !first do strings.write_string(&b, ", ")
		first = false
		fmt.sbprintf(&b, `"%s": {{"identical": %d, "total": %d}}`, name, c.identical, c.total)
	}
	strings.write_string(&b, "}")
	fmt.println(strings.to_string(b))
}

count :: proc(st: ^State, transform: string, identical: bool) {
	c := st.stats[transform] or_else {}
	c.total += 1
	if identical do c.identical += 1
	if transform not_in st.stats {
		st.stats[strings.clone(transform)] = c
	} else {
		st.stats[transform] = c
	}
}

Meta :: struct {
	name:        string,
	steps:       []string,
	error:       bool,
	error_where: string,
	error_text:  string,
}

parse_meta :: proc(text: string) -> (m: Meta, ok: bool) {
	v, err := json.parse_string(text, allocator = context.temp_allocator)
	if err != nil do return {}, false
	obj := v.(json.Object) or_return
	m.name = obj["name"].(json.String) or_return
	steps := obj["steps"].(json.Array) or_return
	m.steps = make([]string, len(steps), context.temp_allocator)
	for s, i in steps do m.steps[i] = s.(json.String) or_return
	if e, is_obj := obj["error"].(json.Object); is_obj {
		m.error = true
		m.error_where = e["transform"].(json.String) or_else ""
		m.error_text = e["message"].(json.String) or_else ""
	}
	return m, true
}

check_file :: proc(st: ^State, path: string) {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		fmt.printfln("FAIL %s cannot read", path)
		return
	}
	defer delete(data)
	records := strings.split(string(data), SEP, context.temp_allocator)
	meta, ok := parse_meta(records[0])
	if !ok || len(records) < 2 + len(meta.steps) {
		fmt.printfln("FAIL %s malformed case file", path)
		return
	}
	doc, lerr := dt.load_json(records[1])
	if lerr != nil {
		fmt.printfln("FAIL %s cannot load: %v", meta.name, lerr)
		return
	}
	defer dt.destroy(doc)
	if msg := run_case(st, doc, meta, records[2:]); msg != "" {
		fmt.printfln("FAIL %s %s", meta.name, msg)
	} else {
		fmt.printfln("PASS %s", meta.name)
	}
}

// Apply the queue step by step; "" if every dump matches.
run_case :: proc(st: ^State, doc: ^dt.Doc, meta: Meta, dumps: []string) -> string {
	options := tf.options_from_interchange(doc)
	options.parse_rst = rd.parse
	if msg := check_components(doc, options); msg != "" do return msg
	r := tf.begin(doc, options)
	if msg := run_steps(st, &r, meta, dumps); msg != "" {
		tf.finish(&r)
		return msg
	}
	if meta.error {
		defer tf.finish(&r)
		name, ok := tf.step(&r)
		same := name == meta.error_where && !ok && r.err != nil
		count(st, meta.error_where, same)
		if same do return ""
		format := "docutils error in %s (%s); native: %s ok=%v"
		return fmt.tprintf(format, meta.error_where, meta.error_text, name, ok)
	}
	if name, more := tf.step(&r); more || name != "" {
		tf.finish(&r)
		return fmt.tprintf("native queue continues with %s", name)
	}
	_, err := tf.finish(&r)
	if err != nil do return fmt.tprintf("native error at the end: %v", err)
	final := dumps[len(meta.steps)]
	if ours := native_dump(doc); ours != final {
		save(st, meta.name, len(meta.steps), ours, final)
		return fmt.tprintf("final: %s", difference(ours, final))
	}
	return ""
}

// The steps docutils took, each compared with its dump.
run_steps :: proc(st: ^State, r: ^tf.Run, meta: Meta, dumps: []string) -> string {
	for want, i in meta.steps {
		if st.trace do fmt.eprintfln("step %d %s", i, want)
		name, ok := tf.step(r)
		if name != want do return fmt.tprintf("step %d: applied %s, docutils %s", i, name, want)
		if !ok {
			count(st, want, false)
			return fmt.tprintf("step %d %s: native error: %v", i, want, r.err)
		}
		ours := native_dump(r.doc)
		same := ours == dumps[i]
		count(st, want, same)
		if !same {
			save(st, meta.name, i, ours, dumps[i])
			return fmt.tprintf("step %d %s: %s", i, want, difference(ours, dumps[i]))
		}
	}
	return ""
}

// ``populate_from_components`` must queue the component transforms of the dump (those
// without a pending element, after the pending ones).
check_components :: proc(doc: ^dt.Doc, options: tf.Options) -> string {
	entries :: proc(queue: []dt.Queued_Pending) -> string {
		sorted := slice.clone(queue, context.temp_allocator)
		slice.sort_by(sorted, proc(a, b: dt.Queued_Pending) -> bool {return a.serial < b.serial})
		b := strings.builder_make(context.temp_allocator)
		for q in sorted {
			if q.node != 0 do continue
			fmt.sbprintf(&b, "%s %s; ", tf.priority_string(q.priority, q.serial), q.transform)
		}
		return strings.to_string(b)
	}
	saved := make([]dt.Queued_Pending, len(doc.pending_queue), context.temp_allocator)
	copy(saved, doc.pending_queue[:])
	saved_serial := doc.transform_serial
	components := 0
	for q in saved do if q.node == 0 do components += 1
	clear(&doc.pending_queue)
	doc.transform_serial = saved_serial - components
	tf.populate_from_components(doc, options.reader, options.writer)
	got, want := entries(doc.pending_queue[:]), entries(saved)
	clear(&doc.pending_queue)
	append(&doc.pending_queue, ..saved)
	doc.transform_serial = saved_serial
	if got != want do return fmt.tprintf("populate_from_components: %s, docutils %s", got, want)
	return ""
}

// ``dump_json`` as a step dump: stage "transformed", ``expected`` the document's own
// ``pformat``.
native_dump :: proc(doc: ^dt.Doc) -> string {
	doc.interchange.stage = "transformed"
	expected := make(json.Object, 1, context.temp_allocator)
	pformat := dt.pformat(doc, doc.root, allocator = context.temp_allocator)
	expected["pformat"] = json.String(pformat)
	saved := doc.interchange.expected
	doc.interchange.expected = expected
	defer doc.interchange.expected = saved
	return dt.dump_json(doc, context.temp_allocator)
}

save :: proc(st: ^State, name: string, step: int, ours, want: string) {
	if st.save == "" do return
	base := fmt.tprintf("%s/%s.%03d", st.save, name, step)
	_ = os.write_entire_file(fmt.tprintf("%s.native.json", base), transmute([]u8)ours)
	_ = os.write_entire_file(fmt.tprintf("%s.docutils.json", base), transmute([]u8)want)
}

// The first differing line, with the path of JSON keys that leads to it.
difference :: proc(a, b: string) -> string {
	la := strings.split_lines(a, context.temp_allocator)
	lb := strings.split_lines(b, context.temp_allocator)
	for i in 0 ..< min(len(la), len(lb)) {
		if la[i] == lb[i] do continue
		x, y := window(la[i], lb[i])
		return fmt.tprintf("line %d [%s]: native %q, docutils %q", i + 1, key_path(la[:i]), x, y)
	}
	return fmt.tprintf("lengths %d/%d", len(la), len(lb))
}

// The top-level key of the dump that the line after ``lines`` belongs to.
key_path :: proc(lines: []string) -> string {
	for i := len(lines) - 1; i >= 0; i -= 1 {
		l := lines[i]
		if strings.has_prefix(l, ` "`) {
			end := strings.index(l[2:], `"`)
			if end >= 0 do return l[2:][:end]
		}
	}
	return "?"
}

// The parts of two lines around their first difference.
window :: proc(a, b: string) -> (string, string) {
	i := 0
	for i < len(a) && i < len(b) && a[i] == b[i] do i += 1
	start := max(0, i - 60)
	for start > 0 && start < len(a) && (a[start] & 0xC0) == 0x80 do start -= 1
	return clip(a, start, i + 60), clip(b, start, i + 60)
}

clip :: proc(s: string, start, end: int) -> string {
	e := min(end, len(s))
	for e < len(s) && e > start && (s[e] & 0xC0) == 0x80 do e += 1
	return s[min(start, len(s)):e]
}
