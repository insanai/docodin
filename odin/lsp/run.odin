package lsp

// The server loop over standard input and output.
//
// A reader thread reads frames into a queue and records ``$/cancelRequest``
// at once, so a request still in the queue when it is cancelled is answered
// with ``RequestCancelled``.  The main thread owns the server state: it
// handles the messages in order and pushes the diagnostics that are due
// (a document's diagnostics wait ``Config.debounce`` after its last change,
// so a burst of edits is analysed once).

import "base:runtime"
import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

@(private = "file")
Queue :: struct {
	mutex:     sync.Mutex,
	cond:      sync.Cond,
	messages:  [dynamic]string, // frame bodies (heap)
	head:      int,
	eof:       bool,
	cancelled: map[string]bool, // ids (JSON text) of cancelled requests
}

@(private = "file")
Pop_Result :: enum u8 {
	Message,
	Timeout,
	Eof,
}

// Serve on standard input and output until ``exit``; the exit code.
run :: proc() -> int {
	q: Queue
	q.messages = make([dynamic]string, 0, 64)
	q.cancelled = make(map[string]bool)
	// the thread is not joined: it may be blocked reading when ``exit``
	// arrives, and the process ends with ``run``
	if thread.create_and_start_with_data(&q, read_loop) == nil do return 1

	s: Server
	server_init(&s, write_stdout, nil)
	defer server_destroy(&s)
	s.cancelled = is_cancelled
	s.cancel_data = &q
	for !s.exit {
		wait, due := next_deadline(&s)
		body, result := pop(&q, wait if due else -1)
		switch result {
		case .Message:
			handle(&s, body)
			delete(body)
		case .Timeout:
			publish_due(&s)
		case .Eof:
			return 1 // the client went away without ``exit``
		}
	}
	return s.exit_code
}

@(private = "file")
write_stdout :: proc(_: rawptr, body: string) {
	framed := frame(body)
	defer delete(framed)
	os.write(os.stdout, transmute([]byte)framed)
}

@(private = "file")
read_loop :: proc(data: rawptr) {
	q := (^Queue)(data)
	r: Frame_Reader
	frame_reader_init(&r, file_read, os.stdin)
	defer frame_reader_destroy(&r)
	for {
		body, ok := read_frame(&r, runtime.heap_allocator())
		sync.lock(&q.mutex)
		if !ok {
			q.eof = true
			sync.unlock(&q.mutex)
			sync.cond_signal(&q.cond)
			return
		}
		note_cancel(q, body)
		append(&q.messages, body)
		sync.unlock(&q.mutex)
		sync.cond_signal(&q.cond)
	}
}

// Record a ``$/cancelRequest`` (the queue is locked).
@(private = "file")
note_cancel :: proc(q: ^Queue, body: string) {
	if !strings.contains(body, `"$/cancelRequest"`) do return
	msg, err := json.parse_string(body, .JSON, true, context.temp_allocator)
	defer free_all(context.temp_allocator)
	if err != nil || get_string(msg, "method") != "$/cancelRequest" do return
	id := id_text(get(get(msg, "params"), "id"), context.temp_allocator)
	if id != "" do q.cancelled[strings.clone(id)] = true
}

@(private = "file")
is_cancelled :: proc(data: rawptr, id: string) -> bool {
	q := (^Queue)(data)
	sync.lock(&q.mutex)
	defer sync.unlock(&q.mutex)
	key, found := delete_key(&q.cancelled, id)
	if found do delete(key)
	return found
}

// The next message; waits at most ``wait`` (forever if negative).
@(private = "file")
pop :: proc(q: ^Queue, wait: time.Duration) -> (body: string, result: Pop_Result) {
	sync.lock(&q.mutex)
	defer sync.unlock(&q.mutex)
	deadline := time.tick_add(time.tick_now(), wait)
	for q.head >= len(q.messages) {
		if q.eof do return "", .Eof
		if wait < 0 {
			sync.cond_wait(&q.cond, &q.mutex)
			continue
		}
		left := time.tick_diff(time.tick_now(), deadline)
		if left <= 0 do return "", .Timeout
		sync.cond_wait_with_timeout(&q.cond, &q.mutex, left)
	}
	body = q.messages[q.head]
	q.head += 1
	if q.head == len(q.messages) {
		clear(&q.messages)
		q.head = 0
	}
	return body, .Message
}
