package reader

import "core:strings"

// A port of CPython's ``csv.reader`` state machine (``Modules/_csv.c``,
// ``QUOTE_MINIMAL``, ``strict``, ``lineterminator`` "\n") for the
// ``csv-table`` directive: rows of fields, or the ``csv.Error`` text.

Csv_Dialect :: struct {
	delimiter:        rune,
	quotechar:        rune,
	escapechar:       rune, // 0: none
	doublequote:      bool,
	skipinitialspace: bool,
}

@(private = "file")
Csv_State :: enum u8 {
	Start_Record,
	Start_Field,
	Escaped_Char,
	In_Field,
	In_Quoted_Field,
	Escape_In_Quoted_Field,
	Quote_In_Quoted_Field,
	Eat_Crnl,
	After_Escaped_Crnl,
}

@(private = "file")
Csv_Reader :: struct {
	dialect: Csv_Dialect,
	state:   Csv_State,
	field:   strings.Builder,
	fields:  [dynamic]string,
	err:     string,
}

@(private = "file")
NEWLINE_IN_UNQUOTED_FIELD :: "new-line character seen in unquoted field - " +
	"do you need to open the file with newline=''?"

// The end of a line (``EOL`` of ``_csv.c``).
@(private = "file")
EOL :: rune(-2)

// ``csv.reader((line + '\n' for line in lines), dialect)``.
csv_read :: proc(
	lines: []string,
	dialect: Csv_Dialect,
	allocator := context.temp_allocator,
) -> (rows: [dynamic][]string, err: string) {
	rows = make([dynamic][]string, allocator)
	r := Csv_Reader {
		dialect = dialect,
		field   = strings.builder_make(allocator),
		fields  = make([dynamic]string, allocator),
	}
	i := 0
	for i < len(lines) {
		// one record: lines until the state machine is back at the start
		for {
			if i >= len(lines) {
				unfinished := len(r.field.buf) > 0 || r.state == .In_Quoted_Field
				if unfinished do return rows, "unexpected end of data"
				return rows, ""
			}
			for ch in lines[i] do if !process_char(&r, ch) do return rows, r.err
			i += 1
			if !process_char(&r, '\n') || !process_char(&r, EOL) do return rows, r.err
			if r.state == .Start_Record do break
		}
		append(&rows, r.fields[:])
		r.fields = make([dynamic]string, allocator)
	}
	return rows, ""
}

@(private = "file")
save_field :: proc(r: ^Csv_Reader) {
	append(&r.fields, strings.clone(strings.to_string(r.field), r.fields.allocator))
	strings.builder_reset(&r.field)
}

@(private = "file")
end_of_field_state :: proc(ch: rune) -> Csv_State {
	return .Start_Record if ch == EOL else .Eat_Crnl
}

// ``parse_process_char``: false with ``r.err`` on a ``csv.Error``.
@(private = "file")
process_char :: proc(r: ^Csv_Reader, ch: rune) -> bool {
	return STATE_HANDLERS[r.state](r, ch)
}

// The character handlers of the states.
@(private = "file")
STATE_HANDLERS := [Csv_State]proc(r: ^Csv_Reader, ch: rune) -> bool {
	.Start_Record           = start_record,
	.Start_Field            = start_field,
	.Escaped_Char           = escaped_char,
	.In_Field               = in_field,
	.In_Quoted_Field        = in_quoted_field,
	.Escape_In_Quoted_Field = escape_in_quoted_field,
	.Quote_In_Quoted_Field  = quote_in_quoted_field,
	.Eat_Crnl               = eat_crnl,
	.After_Escaped_Crnl     = after_escaped_crnl,
}

@(private = "file")
start_record :: proc(r: ^Csv_Reader, ch: rune) -> bool {
	if ch == EOL do return true // empty line: an empty row
	if ch == '\n' || ch == '\r' {
		r.state = .Eat_Crnl
		return true
	}
	r.state = .Start_Field
	return start_field(r, ch)
}

@(private = "file")
escaped_char :: proc(r: ^Csv_Reader, ch: rune) -> bool {
	if ch == '\n' || ch == '\r' {
		strings.write_rune(&r.field, ch)
		r.state = .After_Escaped_Crnl
		return true
	}
	strings.write_rune(&r.field, '\n' if ch == EOL else ch)
	r.state = .In_Field
	return true
}

@(private = "file")
after_escaped_crnl :: proc(r: ^Csv_Reader, ch: rune) -> bool {
	if ch == EOL do return true
	return in_field(r, ch)
}

@(private = "file")
in_quoted_field :: proc(r: ^Csv_Reader, ch: rune) -> bool {
	d := &r.dialect
	switch {
	case ch == EOL:
	case d.escapechar != 0 && ch == d.escapechar:
		r.state = .Escape_In_Quoted_Field
	case ch == d.quotechar:
		r.state = .Quote_In_Quoted_Field if d.doublequote else .In_Field
	case:
		strings.write_rune(&r.field, ch)
	}
	return true
}

@(private = "file")
escape_in_quoted_field :: proc(r: ^Csv_Reader, ch: rune) -> bool {
	strings.write_rune(&r.field, '\n' if ch == EOL else ch)
	r.state = .In_Quoted_Field
	return true
}

@(private = "file")
eat_crnl :: proc(r: ^Csv_Reader, ch: rune) -> bool {
	if ch == EOL {
		r.state = .Start_Record
	} else if ch != '\n' && ch != '\r' {
		r.err = NEWLINE_IN_UNQUOTED_FIELD
		return false
	}
	return true
}

@(private = "file")
start_field :: proc(r: ^Csv_Reader, ch: rune) -> bool {
	d := &r.dialect
	switch {
	case ch == '\n' || ch == '\r' || ch == EOL:
		save_field(r)
		r.state = end_of_field_state(ch)
	case ch == d.quotechar:
		r.state = .In_Quoted_Field
	case d.escapechar != 0 && ch == d.escapechar:
		r.state = .Escaped_Char
	case ch == ' ' && d.skipinitialspace:
	case ch == d.delimiter:
		save_field(r)
	case:
		strings.write_rune(&r.field, ch)
		r.state = .In_Field
	}
	return true
}

@(private = "file")
in_field :: proc(r: ^Csv_Reader, ch: rune) -> bool {
	d := &r.dialect
	switch {
	case ch == '\n' || ch == '\r' || ch == EOL:
		save_field(r)
		r.state = end_of_field_state(ch)
	case d.escapechar != 0 && ch == d.escapechar:
		r.state = .Escaped_Char
	case ch == d.delimiter:
		save_field(r)
		r.state = .Start_Field
	case:
		strings.write_rune(&r.field, ch)
	}
	return true
}

@(private = "file")
quote_in_quoted_field :: proc(r: ^Csv_Reader, ch: rune) -> bool {
	d := &r.dialect
	switch {
	case ch == d.quotechar:
		strings.write_rune(&r.field, ch)
		r.state = .In_Quoted_Field
	case ch == d.delimiter:
		save_field(r)
		r.state = .Start_Field
	case ch == '\n' || ch == '\r' || ch == EOL:
		save_field(r)
		r.state = end_of_field_state(ch)
	case:
		b := strings.builder_make(context.temp_allocator)
		strings.write_byte(&b, '\'')
		strings.write_rune(&b, d.delimiter)
		strings.write_string(&b, "' expected after '")
		strings.write_rune(&b, d.quotechar)
		strings.write_byte(&b, '\'')
		r.err = strings.to_string(b)
		return false
	}
	return true
}
