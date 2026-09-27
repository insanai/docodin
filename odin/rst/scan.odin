package rst

import "base:intrinsics"
import "core:simd"

// Byte scanners on 16-byte ``core:simd`` blocks (NEON or SSE), used by the
// line splitter, the line indexes and the inliner.  A block is classified
// with lane comparisons; the scanners that look for rare bytes test the
// block with one reduction and only then locate the byte (the first lane of
// the 16-bit mask of lanes, bit ``k`` for byte ``i + k``).  Tails shorter
// than a block are scanned byte by byte.

@(private)
BLOCK :: 16

@(private = "file")
V :: simd.u8x16

@(private = "file")
load :: #force_inline proc "contextless" (s: string, i: int) -> V {
	return intrinsics.unaligned_load((^V)(raw_data(s)[i:]))
}

@(private = "file")
splat :: #force_inline proc "contextless" (b: u8) -> V {
	return V(b)
}

@(private = "file")
msbs :: #force_inline proc "contextless" (m: V) -> u16 {
	return transmute(u16)simd.extract_msbs(m)
}

@(private = "file")
in_range :: #force_inline proc "contextless" (v: V, lo, hi: u8) -> V {
	return simd.lanes_ge(v, splat(lo)) & simd.lanes_le(v, splat(hi))
}

// Bytes that may start a ``str.splitlines()`` boundary: \n \r \x1c-\x1e,
// and the lead bytes of U+0085 (C2) and U+2028/U+2029 (E2).
@(private)
line_break_mask :: #force_inline proc "contextless" (s: string, i: int) -> u16 {
	v := load(s, i)
	m := simd.lanes_eq(v, splat('\n')) | simd.lanes_eq(v, splat('\r')) | in_range(v, 0x1C, 0x1E)
	return msbs(m | simd.lanes_eq(v, splat(0xC2)) | simd.lanes_eq(v, splat(0xE2)))
}

// Bytes that ``string2lines`` rewrites: \t \v \f.
@(private)
tab_mask :: #force_inline proc "contextless" (s: string, i: int) -> u16 {
	v := load(s, i)
	return msbs(simd.lanes_eq(v, splat('\t')) | in_range(v, 0x0B, 0x0C))
}

// Number of '\n' bytes in ``s``.
@(private)
count_newlines :: proc "contextless" (s: string) -> int {
	count := 0
	i := 0
	for ; i + BLOCK <= len(s); i += BLOCK {
		count += int(intrinsics.count_ones(msbs(simd.lanes_eq(load(s, i), splat('\n')))))
	}
	for ; i < len(s); i += 1 do count += int(s[i] == '\n')
	return count
}

// Next '\n' or '\r' at or after ``i`` (``len(s)`` if none).
@(private)
next_cr_lf :: proc "contextless" (s: string, i: int) -> int {
	j := i
	for ; j + BLOCK <= len(s); j += BLOCK {
		v := load(s, j)
		m := simd.lanes_eq(v, splat('\n')) | simd.lanes_eq(v, splat('\r'))
		if simd.reduce_or(m) != 0 do return j + first_lane(m)
	}
	for ; j < len(s); j += 1 {
		if s[j] == '\n' || s[j] == '\r' do return j
	}
	return len(s)
}

// Whether ``s`` is ASCII.
@(private)
is_ascii :: proc "contextless" (s: string) -> bool {
	i := 0
	for ; i + BLOCK <= len(s); i += BLOCK {
		if simd.reduce_max(load(s, i)) >= 0x80 do return false
	}
	for ; i < len(s); i += 1 {
		if s[i] >= 0x80 do return false
	}
	return true
}

// Bytes at which inline markup can start other than word characters:
// * ` _ | [ :
@(private = "file")
inline_special_lanes :: #force_inline proc "contextless" (v: V) -> V {
	m := simd.lanes_eq(v, splat('*')) | simd.lanes_eq(v, splat('`'))
	m |= simd.lanes_eq(v, splat('_')) | simd.lanes_eq(v, splat('|'))
	return m | simd.lanes_eq(v, splat('[')) | simd.lanes_eq(v, splat(':'))
}

// Offset of the first lane set in ``m`` (which has one).
@(private = "file")
first_lane :: #force_inline proc "contextless" (m: V) -> int {
	return int(intrinsics.count_trailing_zeros(msbs(m)))
}

// Next inline candidate at or after ``i``: the first byte of ``* ` _ | [ :``
// (``len(s)`` if none).
@(private)
next_inline_special :: proc "contextless" (s: string, i: int) -> int {
	for j := i; j < len(s); {
		if j + BLOCK <= len(s) {
			m := inline_special_lanes(load(s, j))
			if simd.reduce_or(m) == 0 {
				j += BLOCK
				continue
			}
			j += first_lane(m)
		}
		switch s[j] {
		case '*', '`', '_', '|', '[', ':':
			return j
		}
		j += 1
	}
	return len(s)
}

// The start of the run of bytes before ``j`` (not before ``i``) that do not
// end a ``simplename`` chain.  A word start before it cannot begin a
// ``name_`` reference ending at or after ``j``: its chain ends earlier.
@(private)
chain_start :: proc "contextless" (s: string, i, j: int) -> int {
	k := j
	for k > i && !chain_breaks(s[k - 1]) do k -= 1
	return k
}

// Whether ``c`` ends a ``simplename`` chain before any '_' or ':': ASCII
// bytes other than [A-Za-z0-9] and the separators - . + (a non-ASCII byte
// may be part of a word character).
@(private = "file")
chain_breaks :: #force_inline proc "contextless" (c: byte) -> bool {
	switch c {
	case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '+', '-', '.', 0x80 ..= 0xFF:
		return false
	}
	return true
}

// Next ':' or '@' at or after ``i`` (``len(s)`` if none), and ``live``, the
// start of the run of URI scheme and e-mail local-part characters
// (``[-_!~*'{|}/#?^`&=+$%.a-zA-Z0-9\x00]``) before it.
@(private)
next_uri_anchor :: proc "contextless" (s: string, i: int) -> (anchor, live: int) {
	anchor = len(s)
	for j := i; j < len(s); {
		if j + BLOCK <= len(s) {
			v := load(s, j)
			m := simd.lanes_eq(v, splat(':')) | simd.lanes_eq(v, splat('@'))
			if simd.reduce_or(m) == 0 {
				j += BLOCK
				continue
			}
			j += first_lane(m)
		}
		if s[j] == ':' || s[j] == '@' {
			anchor = j
			break
		}
		j += 1
	}
	live = anchor
	for live > i && is_email_or_dot(s[live - 1]) do live -= 1
	return
}

@(private = "file")
is_email_or_dot :: #force_inline proc "contextless" (c: byte) -> bool {
	switch c {
	case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', 0, '!', '#' ..= '\'', '*', '+', '-' ..= '/', '=',
	     '?', '^' ..= '`', '{' ..= '~':
		return true
	}
	return false
}
