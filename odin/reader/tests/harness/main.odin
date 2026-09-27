package reader_harness

import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"

import dt "../../../doctree"
import reader "../.."

// Differential test harness of the native reader (see
// tests/native_reader_differential.py).
//
// Reads documents from standard input and writes, for each, the pseudo-XML
// of ``reader.parse``, the ``(tag, source, line)`` of every element and the
// warning stream.  Records (little-endian u32 lengths):
//
//     in:  len path, len text, u8 report_level, u8 file_insertion_enabled,
//          u8 settings (``Setting_Flag`` bits)
//     out: len payload
//
// Usage: harness [standard include directory]

main :: proc() {
	if len(os.args) > 1 do reader.standard_include_path = os.args[1]
	input := read_all_stdin()
	out := os.to_stream(os.stdout)
	rest := input
	for len(rest) > 0 {
		source_path := take(&rest)
		text := take(&rest)
		settings := dt.default_settings()
		settings.report_level = int(rest[0])
		settings.file_insertion_enabled = rest[1] != 0
		apply_flags(&settings, transmute(Setting_Flags)rest[2])
		rest = rest[3:]
		payload := run(string(text), string(source_path), settings)
		write_u32(out, len(payload))
		io.write_string(out, payload)
		free_all(context.temp_allocator)
	}
}

// All of standard input (a pipe may deliver it in pieces).
@(private = "file")
read_all_stdin :: proc() -> []u8 {
	data := make([dynamic]u8, 0, 1 << 20)
	buf: [1 << 16]u8
	for {
		n, err := os.read(os.stdin, buf[:])
		if n > 0 do append(&data, ..buf[:n])
		if err != nil || n == 0 do break
	}
	if len(data) == 0 do fmt.eprintln("harness: no input")
	return data[:]
}

@(private = "file")
take :: proc(rest: ^[]u8) -> []u8 {
	n := int(rest[0]) | int(rest[1]) << 8 | int(rest[2]) << 16 | int(rest[3]) << 24
	data := rest[4:4 + n]
	rest^ = rest[4 + n:]
	return data
}

@(private = "file")
write_u32 :: proc(w: io.Stream, n: int) {
	buf := [4]u8{u8(n), u8(n >> 8), u8(n >> 16), u8(n >> 24)}
	io.write(w, buf[:])
}

// Settings that differ from the defaults (tests/native_reader_differential.py).
Setting_Flag :: enum u8 {
	Pep_References,
	Rfc_References,
	Character_Level_Inline_Markup,
	Trim_Footnote_Reference_Space,
	Raw_Disabled,
	Id_Prefix, // id_prefix "p-", auto_id_prefix "id"
}
Setting_Flags :: bit_set[Setting_Flag; u8]

apply_flags :: proc(s: ^dt.Settings, flags: Setting_Flags) {
	s.pep_references = .Pep_References in flags
	s.rfc_references = .Rfc_References in flags
	s.character_level_inline_markup = .Character_Level_Inline_Markup in flags
	s.trim_footnote_reference_space = .Trim_Footnote_Reference_Space in flags
	s.raw_enabled = .Raw_Disabled not_in flags
	if .Id_Prefix in flags {
		s.id_prefix = "p-"
		s.auto_id_prefix = "id"
	}
}

// The comparison text of a document: pformat, positions and warnings.
run :: proc(text, source_path: string, settings_in: dt.Settings) -> string {
	settings := settings_in
	settings.halt_level = 5
	settings.warning_stream = .Collect
	settings.syntax_highlight = "none"
	doc, info := reader.parse_document(text, settings, source_path)
	defer dt.destroy(doc)
	b := strings.builder_make(context.temp_allocator)
	if info.unported_directives > 0 do strings.write_string(&b, "--unported--\n")
	strings.write_string(&b, dt.pformat(doc, doc.root, allocator = context.temp_allocator))
	strings.write_string(&b, "--positions--\n")
	for n in dt.traverse(doc, doc.root, dt.tags_of(.Element)) {
		strings.write_string(&b, dt.tagname(doc, n))
		strings.write_byte(&b, '\t')
		if src, ok := dt.source(doc, n); ok {
			dt.write_py_repr(&b, src)
		} else {
			strings.write_string(&b, "None")
		}
		strings.write_byte(&b, '\t')
		if ln, ok := dt.line(doc, n); ok {
			dt.write_int(&b, ln)
		} else {
			strings.write_string(&b, "None")
		}
		strings.write_byte(&b, '\n')
	}
	strings.write_string(&b, "--stream--\n")
	for m in doc.reporter.written do strings.write_string(&b, m.text)
	return strings.to_string(b)
}
