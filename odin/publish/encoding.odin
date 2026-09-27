package publish

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"

// The codecs of ``input_encoding`` and ``output_encoding`` that docodin
// supports, with Python's names and error handlers: ``Output.encode`` of
// the output and ``Input.decode`` of a source file.

Codec :: enum u8 {
	Unknown,
	Utf8,
	Utf8_Sig,
	Utf16, // with a byte order mark, little endian
	Utf16_Le,
	Utf16_Be,
	Utf32,
	Utf32_Le,
	Utf32_Be,
	Ascii,
	Latin1,
}

// Python's name of a codec (in ``UnicodeError`` messages).
CODEC_NAMES := [Codec]string {
	.Unknown  = "",
	.Utf8     = "utf-8",
	.Utf8_Sig = "utf-8-sig",
	.Utf16    = "utf-16",
	.Utf16_Le = "utf-16-le",
	.Utf16_Be = "utf-16-be",
	.Utf32    = "utf-32",
	.Utf32_Le = "utf-32-le",
	.Utf32_Be = "utf-32-be",
	.Ascii    = "ascii",
	.Latin1   = "latin-1",
}

// ``codecs.lookup(name)``: the name normalized (``encodings
// .normalize_encoding``, lowercased) and resolved through the aliases.
codec_of :: proc(name: string) -> Codec {
	normalized := normalize_encoding(name)
	for a in CODEC_ALIASES {
		if a.name == normalized do return a.codec
	}
	return .Unknown
}

@(private = "file")
Codec_Alias :: struct {
	name:  string,
	codec: Codec,
}

// ``encodings.aliases`` of the supported codecs (normalized names).
@(private = "file", rodata)
CODEC_ALIASES := [?]Codec_Alias {
	{"utf_8", .Utf8}, {"utf8", .Utf8}, {"u8", .Utf8}, {"utf", .Utf8}, {"utf8_ucs2", .Utf8},
	{"utf8_ucs4", .Utf8}, {"cp65001", .Utf8},
	{"utf_8_sig", .Utf8_Sig},
	{"utf_16", .Utf16}, {"utf16", .Utf16}, {"u16", .Utf16},
	{"utf_16_le", .Utf16_Le}, {"utf_16le", .Utf16_Le}, {"unicodelittleunmarked", .Utf16_Le},
	{"utf_16_be", .Utf16_Be}, {"utf_16be", .Utf16_Be}, {"unicodebigunmarked", .Utf16_Be},
	{"utf_32", .Utf32}, {"utf32", .Utf32}, {"u32", .Utf32},
	{"utf_32_le", .Utf32_Le}, {"utf_32le", .Utf32_Le},
	{"utf_32_be", .Utf32_Be}, {"utf_32be", .Utf32_Be},
	{"ascii", .Ascii}, {"646", .Ascii}, {"ansi_x3.4_1968", .Ascii}, {"ansi_x3_4_1968", .Ascii},
	{"ansi_x3.4_1986", .Ascii}, {"cp367", .Ascii}, {"csascii", .Ascii}, {"ibm367", .Ascii},
	{"iso646_us", .Ascii}, {"iso_646.irv_1991", .Ascii}, {"iso_ir_6", .Ascii}, {"us", .Ascii},
	{"us_ascii", .Ascii},
	{"latin_1", .Latin1}, {"latin1", .Latin1}, {"latin", .Latin1}, {"l1", .Latin1},
	{"8859", .Latin1}, {"cp819", .Latin1}, {"csisolatin1", .Latin1}, {"ibm819", .Latin1},
	{"iso8859", .Latin1}, {"iso8859_1", .Latin1}, {"iso_8859_1", .Latin1},
	{"iso_8859_1_1987", .Latin1}, {"iso_ir_100", .Latin1},
}

// Lowercased, runs of characters other than letters, digits and "." as
// one "_", without leading and trailing "_".
@(private = "file")
normalize_encoding :: proc(name: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	pending := false
	for c in transmute([]u8)name {
		keep := (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '.'
		upper := c >= 'A' && c <= 'Z'
		if !keep && !upper {
			pending = strings.builder_len(b) > 0
			continue
		}
		if pending do strings.write_byte(&b, '_')
		pending = false
		strings.write_byte(&b, c + 32 if upper else c)
	}
	return strings.to_string(b)
}

// The largest code point a codec encodes.
codec_limit :: proc(c: Codec) -> rune {
	#partial switch c {
	case .Ascii:
		return 0x7F
	case .Latin1:
		return 0xFF
	}
	return max(rune)
}

// A ``UnicodeEncodeError``: the characters ``start ..< end`` (code point
// positions in ``object``) cannot be encoded.
Encode_Error :: struct {
	codec:  Codec,
	object: string,
	start:  int,
	end:    int,
	chars:  string, // ``object[start:end]``
}

// ``text.encode(codec, handler).decode(codec)``: the characters the codec
// cannot encode replaced as ``handler`` does ("strict": an error).
apply_error_handler :: proc(
	text: string,
	codec: Codec,
	handler: string,
	allocator := context.allocator,
) -> (
	out: string,
	err: Maybe(Encode_Error),
) {
	limit := codec_limit(codec)
	b := strings.builder_make(0, len(text), allocator)
	pos := 0
	for i := 0; i < len(text); {
		r, w := utf8.decode_rune_in_string(text[i:])
		if r <= limit {
			strings.write_string(&b, text[i:i + w])
			i += w
			pos += 1
			continue
		}
		run_end, count := unencodable_run(text, i, limit)
		if !replace_run(&b, text[i:run_end], handler) {
			e := Encode_Error{codec, text, pos, pos + count, text[i:run_end]}
			return "", e
		}
		i = run_end
		pos += count
	}
	return strings.to_string(b), nil
}

// The end (byte offset) and length (characters) of the run of characters
// above ``limit`` at ``start``.
@(private = "file")
unencodable_run :: proc(text: string, start: int, limit: rune) -> (end, count: int) {
	end = start
	for end < len(text) {
		r, w := utf8.decode_rune_in_string(text[end:])
		if r <= limit do break
		end += w
		count += 1
	}
	return
}

// Write the replacement of ``chars``; false for "strict" (and the handlers
// docodin does not support).
@(private = "file")
replace_run :: proc(b: ^strings.Builder, chars: string, handler: string) -> bool {
	for r in chars {
		switch handler {
		case "ignore":
		case "replace":
			strings.write_byte(b, '?')
		case "xmlcharrefreplace":
			fmt.sbprintf(b, "&#%d;", int(r))
		case "backslashreplace":
			write_backslashed(b, r)
		case:
			return false
		}
	}
	return true
}

// ``\xNN``, ``\uNNNN`` or ``\UNNNNNNNN``.
@(private = "file")
write_backslashed :: proc(b: ^strings.Builder, r: rune) {
	switch {
	case r < 0x100:
		fmt.sbprintf(b, "\\x%02x", int(r))
	case r < 0x10000:
		fmt.sbprintf(b, "\\u%04x", int(r))
	case:
		fmt.sbprintf(b, "\\U%08x", int(r))
	}
}

// ``str(UnicodeEncodeError)``.
encode_error_text :: proc(e: Encode_Error, allocator := context.allocator) -> string {
	limit := 128 if e.codec == .Ascii else 256
	if e.end - e.start == 1 {
		r, _ := utf8.decode_rune_in_string(e.chars)
		return fmt.aprintf(
			"'%s' codec can't encode character %s in position %d: ordinal not in range(%d)",
			CODEC_NAMES[e.codec], char_repr(r), e.start, limit,
			allocator = allocator,
		)
	}
	return fmt.aprintf(
		"'%s' codec can't encode characters in position %d-%d: ordinal not in range(%d)",
		CODEC_NAMES[e.codec], e.start, e.end - 1, limit,
		allocator = allocator,
	)
}

// The character in ``UnicodeEncodeError`` messages: always escaped.
@(private = "file")
char_repr :: proc(r: rune) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '\'')
	write_backslashed(&b, r)
	strings.write_byte(&b, '\'')
	return strings.to_string(b)
}

// ``data.encode(codec)`` of text the codec can encode (after
// ``apply_error_handler``).
to_bytes :: proc(text: string, codec: Codec, allocator := context.allocator) -> []u8 {
	#partial switch codec {
	case .Utf8:
		return transmute([]u8)strings.clone(text, allocator)
	case .Utf8_Sig:
		return transmute([]u8)strings.concatenate({"\xef\xbb\xbf", text}, allocator)
	case .Ascii, .Latin1:
		out := make([dynamic]u8, 0, len(text), allocator)
		for r in text do append(&out, u8(r))
		return out[:]
	}
	return wide_bytes(text, codec, allocator)
}

// UTF-16 and UTF-32 (the plain codecs write a little-endian byte order
// mark).
@(private = "file")
wide_bytes :: proc(text: string, codec: Codec, allocator := context.allocator) -> []u8 {
	out := make([dynamic]u8, 0, 4 * len(text) + 4, allocator)
	big := codec == .Utf16_Be || codec == .Utf32_Be
	wide := codec == .Utf32 || codec == .Utf32_Le || codec == .Utf32_Be
	if codec == .Utf16 || codec == .Utf32 do put_unit(&out, 0xFEFF, 4 if wide else 2, false)
	for r in text {
		if wide {
			put_unit(&out, u32(r), 4, big)
		} else if r >= 0x10000 {
			v := u32(r) - 0x10000
			put_unit(&out, 0xD800 + (v >> 10), 2, big)
			put_unit(&out, 0xDC00 + (v & 0x3FF), 2, big)
		} else {
			put_unit(&out, u32(r), 2, big)
		}
	}
	return out[:]
}

@(private = "file")
put_unit :: proc(out: ^[dynamic]u8, v: u32, size: int, big: bool) {
	for k in 0 ..< size {
		shift := u32(8 * (size - 1 - k) if big else 8 * k)
		append(out, u8(v >> shift))
	}
}

// ``Input.decode``: the text of ``data`` in ``encoding``, with
// ``handler`` ("strict", "replace" or "ignore") for bytes that are not
// valid.  On failure, ``err`` is ``str(UnicodeDecodeError)``.
decode :: proc(
	data: []u8,
	encoding, handler: string,
	allocator := context.allocator,
) -> (
	text: string,
	err: string,
) {
	codec := codec_of(encoding)
	#partial switch codec {
	case .Latin1:
		b := strings.builder_make(0, len(data), allocator)
		for c in data do strings.write_rune(&b, rune(c))
		return strings.to_string(b), ""
	case .Utf8, .Utf8_Sig, .Ascii:
		return decode_utf8(data, codec, handler, allocator)
	}
	return "", fmt.aprintf("LookupError: decoding from %s is not supported", encoding)
}

@(private = "file")
decode_utf8 :: proc(
	data: []u8,
	codec: Codec,
	handler: string,
	allocator := context.allocator,
) -> (
	string,
	string,
) {
	s := string(data)
	if codec == .Utf8_Sig do s = strings.trim_prefix(s, "\xef\xbb\xbf")
	limit := codec_limit(codec)
	b := strings.builder_make(0, len(s), allocator)
	for i := 0; i < len(s); {
		r, w := utf8.decode_rune_in_string(s[i:])
		if (r != utf8.RUNE_ERROR || w > 1) && r <= limit {
			strings.write_string(&b, s[i:i + w])
			i += w
			continue
		}
		switch handler {
		case "replace":
			strings.write_rune(&b, utf8.RUNE_ERROR)
		case "ignore":
		case:
			return "", decode_error_text(s, i, codec)
		}
		i += 1
	}
	return strings.to_string(b), ""
}

// ``str(UnicodeDecodeError)`` of the byte at ``i``.
@(private = "file")
decode_error_text :: proc(s: string, i: int, codec: Codec) -> string {
	c := s[i]
	reason := "invalid start byte"
	switch {
	case codec == .Ascii:
		reason = "ordinal not in range(128)"
	case c >= 0xC2 && c <= 0xF4:
		_, w := utf8.decode_rune_in_string(s[i:])
		reason = "unexpected end of data" if i + w >= len(s) else "invalid continuation byte"
	}
	name := CODEC_NAMES[codec] if codec != .Utf8_Sig else "utf-8"
	return fmt.aprintf(
		"UnicodeDecodeError: '%s' codec can't decode byte 0x%02x in position %d: %s",
		name, c, i, reason,
	)
}

// Newlines as Python's text mode reads them ("\r\n" and "\r" as "\n").
universal_newlines :: proc(text: string, allocator := context.allocator) -> string {
	if strings.index_byte(text, '\r') < 0 do return text
	b := strings.builder_make(0, len(text), allocator)
	for i := 0; i < len(text); i += 1 {
		c := text[i]
		if c != '\r' {
			strings.write_byte(&b, c)
			continue
		}
		strings.write_byte(&b, '\n')
		if i + 1 < len(text) && text[i + 1] == '\n' do i += 1
	}
	return strings.to_string(b)
}
