package publish

import "core:fmt"
import "core:strings"

import wr "../writers"

// ``Publisher.report_Exception``: what ``publish_cmdline`` writes to the
// warning stream when the run fails.  (docutils names its Python version;
// the native pipeline has none.)

PYTHON_VERSION :: "none: docodin native"

@(private = "file")
LEVEL_NAMES := [5]string{"DEBUG", "INFO", "WARNING", "ERROR", "SEVERE"}

// The report of ``err`` ("" for none).
error_report :: proc(err: Error, allocator := context.allocator) -> string {
	switch e in err {
	case System_Message:
		name := LEVEL_NAMES[clamp(e.level, 0, 4)]
		return fmt.aprintf("Exiting due to level-%d (%s) system message.\n", e.level, name,
			allocator = allocator)
	case Exception:
		return exception_report(e.text, allocator)
	case Unicode_Error:
		return unicode_report(e, allocator)
	case Settings_Error:
		return strings.concatenate({e.message, "\n"}, allocator)
	}
	return ""
}

// A report of an exception text ("Class: message").
exception_report :: proc(text: string, allocator := context.allocator) -> string {
	return fmt.aprintf(
		"%s\n" +
		"Exiting due to error.  Use \"--traceback\" to diagnose.\n" +
		"Please report errors to <docutils-users@lists.sourceforge.net>.\n" +
		"Include \"--traceback\" output, Docutils version (%s),\n" +
		"Python version (%s), your OS type & version, and the command line used.\n",
		text, wr.DOCUTILS_VERSION, PYTHON_VERSION,
		allocator = allocator,
	)
}

// ``report_UnicodeError``.
@(private = "file")
unicode_report :: proc(e: Unicode_Error, allocator := context.allocator) -> string {
	refs := strings.builder_make(context.temp_allocator)
	escapes := strings.builder_make(context.temp_allocator)
	for r in e.chars {
		fmt.sbprintf(&refs, "&#%d;", int(r))
		switch {
		case r < 0x100:
			fmt.sbprintf(&escapes, "\\\\x%02x", int(r))
		case r < 0x10000:
			fmt.sbprintf(&escapes, "\\\\u%04x", int(r))
		case:
			fmt.sbprintf(&escapes, "\\\\U%08x", int(r))
		}
	}
	return fmt.aprintf(
		"UnicodeEncodeError: %s\n\n" +
		"The specified output encoding (%s) cannot\n" +
		"handle all of the output.\n" +
		"Try setting \"--output-encoding-error-handler\" to\n\n" +
		"* \"xmlcharrefreplace\" (for HTML & XML output);\n" +
		"  the output will contain \"b'%s'\" and should be usable.\n" +
		"* \"backslashreplace\" (for other output formats);\n" +
		"  look for \"b'%s'\" in the output.\n" +
		"* \"replace\"; look for \"?\" in the output.\n\n" +
		"\"--output-encoding-error-handler\" is currently set to \"%s\".\n\n" +
		"Exiting due to error.  Use \"--traceback\" to diagnose.\n" +
		"If the advice above doesn't eliminate the error,\n" +
		"please report it to <docutils-users@lists.sourceforge.net>.\n" +
		"Include \"--traceback\" output, Docutils version (%s),\n" +
		"Python version (%s), your OS type & version, and the\n" +
		"command line used.\n",
		encode_error_text(e.encode, context.temp_allocator), e.encoding,
		strings.to_string(refs), strings.to_string(escapes), e.handler,
		wr.DOCUTILS_VERSION, PYTHON_VERSION,
		allocator = allocator,
	)
}

// The text of the encoded output: ``to_bytes`` with the codec of
// ``output_encoding`` (the output's characters are encodable).
encode_output :: proc(output: string, settings: Settings, allocator := context.allocator) -> []u8 {
	encoding, _ := settings["output_encoding"].(string)
	codec := codec_of(encoding)
	if codec == .Unknown do codec = .Utf8
	return to_bytes(output, codec, allocator)
}
