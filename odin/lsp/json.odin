package lsp

// JSON for the protocol: incoming messages are parsed with
// ``core:encoding/json`` and read through the accessors below; outgoing
// messages are written directly into a builder by ``Json_Writer``.

import "core:encoding/json"
import "core:strings"

// --- reading ---------------------------------------------------------------------------

get :: proc(v: json.Value, key: string) -> json.Value {
	obj, ok := v.(json.Object)
	if !ok do return nil
	return obj[key]
}

// ``v[k0][k1]...``
get_path :: proc(v: json.Value, keys: ..string) -> json.Value {
	cur := v
	for k in keys do cur = get(cur, k)
	return cur
}

get_string :: proc(v: json.Value, key: string) -> string {
	s, _ := get(v, key).(json.String)
	return string(s)
}

get_int :: proc(v: json.Value, key: string, default := 0) -> int {
	#partial switch n in get(v, key) {
	case json.Integer:
		return int(n)
	case json.Float:
		return int(n)
	}
	return default
}

get_bool :: proc(v: json.Value, key: string) -> bool {
	b, _ := get(v, key).(json.Boolean)
	return bool(b)
}

get_array :: proc(v: json.Value, key: string) -> json.Array {
	a, _ := get(v, key).(json.Array)
	return a
}

has :: proc(v: json.Value, key: string) -> bool {
	obj, ok := v.(json.Object)
	if !ok do return false
	_, present := obj[key]
	return present
}

// The JSON text of a request id (a number or a string), "" for none.
id_text :: proc(v: json.Value, allocator := context.allocator) -> string {
	#partial switch id in v {
	case json.Integer:
		b := strings.builder_make(allocator)
		strings.write_i64(&b, i64(id))
		return strings.to_string(b)
	case json.Float:
		b := strings.builder_make(allocator)
		strings.write_i64(&b, i64(id))
		return strings.to_string(b)
	case json.String:
		b := strings.builder_make(allocator)
		write_json_string(&b, string(id))
		return strings.to_string(b)
	}
	return ""
}

// --- writing ---------------------------------------------------------------------------

// Writes JSON into ``b``; separators are inserted automatically:
//
//     w := json_writer(allocator)
//     obj_begin(&w); key(&w, "a"); int_value(&w, 1); obj_end(&w)
Json_Writer :: struct {
	b:         strings.Builder,
	need_sep:  bool, // a value was written at the current level
	after_key: bool,
}

json_writer :: proc(allocator := context.allocator) -> Json_Writer {
	return {b = strings.builder_make(0, 256, allocator)}
}

json_text :: proc(w: ^Json_Writer) -> string {
	return strings.to_string(w.b)
}

@(private = "file")
sep :: proc(w: ^Json_Writer) {
	if w.after_key {
		w.after_key = false
	} else if w.need_sep {
		strings.write_byte(&w.b, ',')
	}
	w.need_sep = true
}

obj_begin :: proc(w: ^Json_Writer) {
	sep(w)
	strings.write_byte(&w.b, '{')
	w.need_sep = false
}

obj_end :: proc(w: ^Json_Writer) {
	strings.write_byte(&w.b, '}')
	w.need_sep = true
}

arr_begin :: proc(w: ^Json_Writer) {
	sep(w)
	strings.write_byte(&w.b, '[')
	w.need_sep = false
}

arr_end :: proc(w: ^Json_Writer) {
	strings.write_byte(&w.b, ']')
	w.need_sep = true
}

key :: proc(w: ^Json_Writer, name: string) {
	sep(w)
	write_json_string(&w.b, name)
	strings.write_byte(&w.b, ':')
	w.after_key = true
}

str_value :: proc(w: ^Json_Writer, s: string) {
	sep(w)
	write_json_string(&w.b, s)
}

int_value :: proc(w: ^Json_Writer, n: int) {
	sep(w)
	strings.write_int(&w.b, n)
}

bool_value :: proc(w: ^Json_Writer, v: bool) {
	sep(w)
	strings.write_string(&w.b, "true" if v else "false")
}

null_value :: proc(w: ^Json_Writer) {
	sep(w)
	strings.write_string(&w.b, "null")
}

// A value given as JSON text.
raw_value :: proc(w: ^Json_Writer, text: string) {
	sep(w)
	strings.write_string(&w.b, text)
}

// ``"name": value`` shorthands.
key_str :: proc(w: ^Json_Writer, name, value: string) {
	key(w, name)
	str_value(w, value)
}

key_int :: proc(w: ^Json_Writer, name: string, value: int) {
	key(w, name)
	int_value(w, value)
}

key_bool :: proc(w: ^Json_Writer, name: string, value: bool) {
	key(w, name)
	bool_value(w, value)
}

write_json_string :: proc(b: ^strings.Builder, s: string) {
	hex := "0123456789abcdef"
	strings.write_byte(b, '"')
	start := 0
	for i in 0 ..< len(s) {
		c := s[i]
		if c >= 0x20 && c != '"' && c != '\\' do continue
		strings.write_string(b, s[start:i])
		start = i + 1
		switch c {
		case '"':  strings.write_string(b, `\"`)
		case '\\': strings.write_string(b, `\\`)
		case '\n': strings.write_string(b, `\n`)
		case '\r': strings.write_string(b, `\r`)
		case '\t': strings.write_string(b, `\t`)
		case:
			strings.write_string(b, `\u00`)
			strings.write_byte(b, hex[c >> 4])
			strings.write_byte(b, hex[c & 0xF])
		}
	}
	strings.write_string(b, s[start:])
	strings.write_byte(b, '"')
}
