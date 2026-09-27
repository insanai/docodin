package doctree_tests

import "core:encoding/json"
import "core:fmt"
import "core:hash"
import "core:mem/virtual"
import "core:strings"
import "core:testing"

import dt ".."

// Differential test of the Unicode-dependent helpers against docutils and
// CPython (fixtures/unicode.json): ``make_id``, ``fully_normalize_name``,
// ``whitespace_normalize_name``, ``repr``, ``splitlines`` and ``lower`` on
// every code point (in blocks of 128) and on random strings.

UNICODE_JSON :: #load("fixtures/unicode.json", string)

@(private = "file")
fnv :: proc(s: string) -> string {
	return fmt.tprintf("%016x", hash.fnv64a(transmute([]u8)s))
}

@(private = "file")
repr :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	dt.write_py_repr(&b, s)
	return strings.to_string(b)
}

@(private = "file")
block :: proc(lo, hi: int) -> string {
	b := strings.builder_make(context.temp_allocator)
	for c in lo ..< hi {
		if c < 0xD800 || c > 0xDFFF do strings.write_rune(&b, rune(c))
	}
	return strings.to_string(b)
}

@(private = "file")
Checker :: struct {
	t:        ^testing.T,
	failures: int,
}

@(private = "file")
expect_eq :: proc(c: ^Checker, what: string, input: string, got, want: string) {
	if got == want do return
	c.failures += 1
	if c.failures <= 20 {
		testing.expectf(c.t, false, "%s(%q): got %q, want %q", what, input, got, want)
	}
}

@(private = "file")
check_block :: proc(c: ^Checker, v: json.Array) {
	lo, hi := jint(v[0]), jint(v[1])
	s := block(lo, hi)
	name := fmt.tprintf("block %X", lo)
	expect_eq(c, "make_id", name, dt.make_id(s), jstr(v[2]))
	expect_eq(c, "fully_normalize_name", name, fnv(dt.fully_normalize_name(s)), jstr(v[3]))
	ws := dt.whitespace_normalize_name(s)
	expect_eq(c, "whitespace_normalize_name", name, fnv(ws), jstr(v[4]))
	expect_eq(c, "repr", name, fnv(repr(s)), jstr(v[5]))
	lines := strings.join(dt.py_splitlines(s, true), "\x00", context.temp_allocator)
	expect_eq(c, "splitlines", name, fnv(lines), jstr(v[6]))
}

@(private = "file")
check_string :: proc(c: ^Checker, v: json.Array) {
	s := jstr(v[0])
	expect_eq(c, "make_id", s, dt.make_id(s), jstr(v[1]))
	expect_eq(c, "fully_normalize_name", s, dt.fully_normalize_name(s), jstr(v[2]))
	expect_eq(c, "whitespace_normalize_name", s, dt.whitespace_normalize_name(s), jstr(v[3]))
	expect_eq(c, "repr", s, repr(s), jstr(v[4]))
	want := make([dynamic]string, context.temp_allocator)
	for l in jarr(v[5]) do append(&want, jstr(l))
	got := dt.py_splitlines(s, true)
	expect_eq(
		c,
		"splitlines",
		s,
		strings.join(got, "|", context.temp_allocator),
		strings.join(want[:], "|", context.temp_allocator),
	)
	expect_eq(c, "lower", s, dt.py_lower(s), jstr(v[6]))
}

@(test)
test_unicode_helpers_match_cpython :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	root, err := json.parse_string(UNICODE_JSON, .JSON, true)
	testing.expect_value(t, err, json.Error.None)
	obj := root.(json.Object)
	c := Checker{t = t}
	for v in jarr(obj["blocks"]) {
		check_block(&c, jarr(v))
		free_all(context.temp_allocator)
	}
	for v in jarr(obj["strings"]) {
		check_string(&c, jarr(v))
		free_all(context.temp_allocator)
	}
	testing.expectf(t, c.failures == 0, "%d mismatches", c.failures)
}
