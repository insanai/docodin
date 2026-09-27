package lsp

// JSON-RPC 2.0 framing over a byte stream (the LSP base protocol):
//
//     Content-Length: 52\r\n
//     \r\n
//     {"jsonrpc":"2.0","id":1,"method":"initialize",...}
//
// Header names are case-insensitive; headers other than Content-Length
// (Content-Type) are ignored.

import "core:os"
import "core:strconv"
import "core:strings"

// Largest message accepted (a document is sent whole on open).
MAX_MESSAGE_SIZE :: 256 * 1024 * 1024

// Reads frames from a byte source.  ``read`` returns the bytes read, 0 at
// the end of the input.
Frame_Reader :: struct {
	read:  Read_Proc,
	data:  rawptr,
	buf:   [dynamic]byte, // unread input
	start: int,           // first unread byte of ``buf``
	eof:   bool,
}

Read_Proc :: proc(data: rawptr, buf: []byte) -> int

frame_reader_init :: proc(r: ^Frame_Reader, read: Read_Proc, data: rawptr) {
	r.read = read
	r.data = data
	r.buf = make([dynamic]byte, 0, 64 * 1024)
}

frame_reader_destroy :: proc(r: ^Frame_Reader) {
	delete(r.buf)
}

// A byte source over a file (standard input).
file_read :: proc(data: rawptr, buf: []byte) -> int {
	n, err := os.read((^os.File)(data), buf)
	if err != nil || n < 0 do return 0
	return n
}

// The body of the next frame, allocated with ``allocator``; ``ok`` is false
// at the end of the input or on a malformed header.
read_frame :: proc(r: ^Frame_Reader, allocator := context.allocator) -> (body: string, ok: bool) {
	header_end := -1
	for {
		header_end = find_header_end(r)
		if header_end >= 0 do break
		if !fill(r) do return "", false
	}
	length := content_length(string(r.buf[r.start:header_end]))
	if length < 0 || length > MAX_MESSAGE_SIZE do return "", false
	body_start := header_end + 4
	for len(r.buf) - body_start < length {
		if !fill(r) do return "", false
		// ``fill`` may compact the buffer
		header_end = find_header_end(r)
		body_start = header_end + 4
	}
	body = strings.clone(string(r.buf[body_start:body_start + length]), allocator)
	r.start = body_start + length
	return body, true
}

@(private = "file")
find_header_end :: proc(r: ^Frame_Reader) -> int {
	idx := strings.index(string(r.buf[r.start:]), "\r\n\r\n")
	return idx if idx < 0 else r.start + idx
}

// Read more input, dropping the consumed part of the buffer first.
@(private = "file")
fill :: proc(r: ^Frame_Reader) -> bool {
	if r.eof do return false
	if r.start > 0 {
		remaining := len(r.buf) - r.start
		copy(r.buf[:remaining], r.buf[r.start:])
		resize(&r.buf, remaining)
		r.start = 0
	}
	chunk: [64 * 1024]byte
	n := r.read(r.data, chunk[:])
	if n <= 0 {
		r.eof = true
		return false
	}
	append(&r.buf, ..chunk[:n])
	return true
}

// The Content-Length of a header block, or -1.
@(private = "file")
content_length :: proc(headers: string) -> int {
	rest := headers
	for line in strings.split_lines_iterator(&rest) {
		colon := strings.index_byte(line, ':')
		if colon < 0 do continue
		name := strings.trim_space(line[:colon])
		if !strings.equal_fold(name, "Content-Length") do continue
		n, ok := strconv.parse_int(strings.trim_space(line[colon + 1:]), 10)
		return n if ok && n >= 0 else -1
	}
	return -1
}

// ``body`` with its header, ready to write.
frame :: proc(body: string, allocator := context.allocator) -> string {
	b := strings.builder_make(0, len(body) + 32, allocator)
	strings.write_string(&b, "Content-Length: ")
	strings.write_int(&b, len(body))
	strings.write_string(&b, "\r\n\r\n")
	strings.write_string(&b, body)
	return strings.to_string(b)
}
