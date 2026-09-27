package texmath

// The TeX scanning helpers of ``latex2mathml`` (``tex_cmdname``, ``tex_number``,
// ``tex_token``, ``tex_group``, ``tex_token_or_group``, ``tex_optarg``) and
// ``toplevel_code``.  Each returns a leading part and the remainder of a string,
// reproducing the regular expressions of the originals.

import "core:strings"
import "core:unicode/utf8"

@(private = "file")
is_ascii_letter :: proc(c: byte) -> bool {
	return ('a' <= c && c <= 'z') || ('A' <= c && c <= 'Z')
}

// The first character of `s` ("" if empty) and the rest.
@(private = "file")
first_char :: proc(s: string) -> (string, string) {
	if len(s) == 0 {
		return "", ""
	}
	_, size := utf8.decode_rune_in_string(s)
	return s[:size], s[size:]
}

// ``tex_cmdname``: a run of ASCII letters (skipping following spaces and
// newlines), or one character.
tex_cmdname :: proc(s: string) -> (name: string, rest: string) {
	end := 0
	for end < len(s) && is_ascii_letter(s[end]) {
		end += 1
	}
	if end == 0 {
		return first_char(s)
	}
	rest = s[end:]
	for len(rest) > 0 && (rest[0] == ' ' || rest[0] == '\n') {
		rest = rest[1:]
	}
	return s[:end], rest
}

// ``tex_number``: the longest run of digits, dots and commas ending in a digit.
tex_number :: proc(s: string) -> (number: string, rest: string) {
	end, last_digit := 0, -1
	for end < len(s) && strings.index_byte("0123456789.,", s[end]) >= 0 {
		if s[end] != '.' && s[end] != ',' {
			last_digit = end
		}
		end += 1
	}
	if last_digit < 0 {
		return "", s
	}
	return s[:last_digit + 1], s[last_digit + 1:]
}

// ``tex_token``: a command (skipping following white space), a backslash and
// one character, or one character.
tex_token :: proc(s: string) -> (token: string, rest: string) {
	if len(s) > 1 && s[0] == '\\' {
		end := 1
		for end < len(s) && is_ascii_letter(s[end]) {
			end += 1
		}
		if end > 1 {
			rest = s[end:]
			for len(rest) > 0 {
				r, size := utf8.decode_rune_in_string(rest)
				if !is_space(r) {
					break
				}
				rest = rest[size:]
			}
			return s[:end], rest
		}
		_, size := utf8.decode_rune_in_string(s[1:])
		return s[:1 + size], s[1 + size:]
	}
	return first_char(s)
}

// ``tex_group``: the contents of a leading ``{...}`` group, or the first character.
tex_group :: proc(s: string) -> (group: string, rest: string, err: Error) {
	if !strings.has_prefix(s, "{") {
		group, rest = first_char(s)
		return
	}
	depth := 0
	escape := false
	for c, offset in transmute([]byte)s {
		switch {
		case escape:
			escape = false
		case c == '\\':
			escape = true
		case c == '{':
			depth += 1
		case c == '}':
			depth -= 1
		}
		if depth == 0 {
			return s[1:offset], s[offset + 1:], nil
		}
	}
	return "", "", Exception{.Math_Error, "Group without closing bracket!"}
}

// ``tex_token_or_group``: a group's contents or a token.
tex_token_or_group :: proc(s: string) -> (arg: string, rest: string, err: Error) {
	arg, rest = tex_token(s)
	if arg == "{" {
		return tex_group(py_strip(s, right = false))
	}
	return arg, rest, nil
}

// ``tex_optarg``: an optional ``[argument]`` after white space (no nested
// brackets; ``\]`` may be escaped), or "" if the string does not start with one.
tex_optarg :: proc(s: string) -> (optarg: string, rest: string, err: Error) {
	start := len(s) - len(py_strip(s, right = false))
	if start < len(s) && s[start] == '[' {
		if arg, remainder, found := match_optarg(s[start + 1:]); found {
			return arg, remainder, nil
		}
	}
	if !strings.has_prefix(s, "[") {
		return "", s, nil
	}
	message := strings.concatenate({`Could not extract optional argument from "`, s, `"!`})
	return "", "", Exception{.Math_Error, message}
}

// ``(\\]|[^\[\]]|\\])*\]``: characters other than brackets and escaped closing
// brackets up to ``]``; when that fails, the regular expression backtracks to
// the last escaped bracket, whose backslash then ends the argument.
@(private = "file")
match_optarg :: proc(s: string) -> (arg: string, rest: string, found: bool) {
	i, last_escape := 0, -1
	for i < len(s) {
		if s[i] == '\\' && i + 1 < len(s) && s[i + 1] == ']' {
			last_escape = i
			i += 2
		} else if s[i] != '[' && s[i] != ']' {
			i += 1
		} else {
			break
		}
	}
	if i < len(s) && s[i] == ']' {
		return s[:i], s[i + 1:], true
	}
	if last_escape >= 0 {
		return s[:last_escape + 1], s[last_escape + 2:], true
	}
	return "", "", false
}

// ``toplevel_code``: `code` with environments stripped out.
toplevel_code :: proc(code: string) -> string {
	b := strings.builder_make()
	rest := code
	for index := 0; ; index += 1 {
		chunk := rest
		next := strings.index(rest, "\\begin{")
		if next >= 0 {
			chunk = rest[:next]
		}
		if index > 0 {
			strings.write_string(&b, "\\begin{")
		}
		if end := strings.last_index(chunk, "\\end{"); end >= 0 {
			chunk = chunk[end + len("\\end{"):]
		}
		strings.write_string(&b, chunk)
		if next < 0 {
			break
		}
		rest = rest[next + len("\\begin{"):]
	}
	return strings.to_string(b)
}

// ``pick_math_environment``: "align*" for code with top-level line breaks, else
// "equation*" (without the star when numbered).
pick_math_environment :: proc(code: string, numbered := false) -> string {
	env := strings.contains(toplevel_code(code), "\\\\") ? "align" : "equation"
	return numbered ? env : strings.concatenate({env, "*"})
}
