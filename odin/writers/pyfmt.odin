package writers

import "core:math"
import "core:strconv"
import "core:strings"

// Python number formatting and parsing as the docutils writers use it:
// ``str(int)``, ``repr(float)``, ``"%g"``, ``"%.Nf"``, ``"%.1%"``,
// ``round()`` and ``nodes.parse_measure``.

// A Python ``int`` or ``float``.
Num :: union {
	int,
	f64,
}

as_f64 :: proc(n: Num) -> f64 {
	switch v in n {
	case int:
		return f64(v)
	case f64:
		return v
	}
	return 0
}

// ``str(n)``: an int, or the ``repr`` of a float.
write_num :: proc(b: ^strings.Builder, n: Num) {
	switch v in n {
	case int:
		strings.write_int(b, v)
	case f64:
		write_float_repr(b, v)
	}
}

num_str :: proc(n: Num, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	write_num(&b, n)
	return strings.to_string(b)
}

int_str :: proc(i: int, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_int(&b, i)
	return strings.to_string(b)
}

// Decimal digits of a float: ``value = 0.digits * 10**decpt``.
@(private = "file")
Digits :: struct {
	neg:    bool,
	digits: [32]u8,
	count:  int,
	decpt:  int,
}

// The digits of ``f`` rounded to ``sig`` significant digits (shortest
// round-trip digits for ``sig`` < 0), trailing zeros removed.
@(private = "file")
float_digits :: proc(f: f64, sig: int) -> Digits {
	d: Digits
	buf: [64]u8
	s := string(strconv.generic_ftoa(buf[:], f, 'e', sig - 1 if sig > 0 else -1, 64))
	// "+d.ddde+XX"
	d.neg = s[0] == '-'
	e := strings.index_byte(s, 'e')
	for c in transmute([]u8)s[1:e] {
		if c == '.' do continue
		d.digits[d.count] = c
		d.count += 1
	}
	exp, _ := strconv.parse_int(s[e + 1:])
	for d.count > 1 && d.digits[d.count - 1] == '0' do d.count -= 1
	d.decpt = exp + 1
	if d.count == 1 && d.digits[0] == '0' do d.decpt = 1
	return d
}

@(private = "file")
write_exponent_form :: proc(b: ^strings.Builder, d: ^Digits) {
	strings.write_byte(b, d.digits[0])
	if d.count > 1 {
		strings.write_byte(b, '.')
		strings.write_string(b, string(d.digits[1:d.count]))
	}
	exp := d.decpt - 1
	strings.write_string(b, "e-" if exp < 0 else "e+")
	if abs(exp) < 10 do strings.write_byte(b, '0')
	strings.write_int(b, abs(exp))
}

// Fixed notation of the digits, with at least ``min_frac`` fraction digits.
@(private = "file")
write_fixed_form :: proc(b: ^strings.Builder, d: ^Digits, min_frac: int) {
	if d.decpt <= 0 {
		strings.write_string(b, "0.")
		for _ in 0 ..< -d.decpt do strings.write_byte(b, '0')
		strings.write_string(b, string(d.digits[:d.count]))
		return
	}
	for i in 0 ..< d.decpt {
		strings.write_byte(b, d.digits[i] if i < d.count else '0')
	}
	frac := d.count - d.decpt
	if frac > 0 {
		strings.write_byte(b, '.')
		strings.write_string(b, string(d.digits[d.decpt:d.count]))
	} else if min_frac > 0 {
		strings.write_byte(b, '.')
		for _ in 0 ..< min_frac do strings.write_byte(b, '0')
	}
}

@(private = "file")
write_special :: proc(b: ^strings.Builder, f: f64) -> bool {
	switch {
	case math.is_nan(f):
		strings.write_string(b, "nan")
	case math.is_inf(f, 1):
		strings.write_string(b, "inf")
	case math.is_inf(f, -1):
		strings.write_string(b, "-inf")
	case:
		return false
	}
	return true
}

// ``repr(f)`` of a Python float.
write_float_repr :: proc(b: ^strings.Builder, f: f64) {
	if write_special(b, f) do return
	d := float_digits(f, -1)
	if d.neg do strings.write_byte(b, '-')
	if d.decpt <= -4 || d.decpt > 16 {
		write_exponent_form(b, &d)
	} else {
		write_fixed_form(b, &d, 1)
	}
}

// ``"%g" % f`` (``"%.{prec}g"``).
write_float_g :: proc(b: ^strings.Builder, f: f64, prec := 6) {
	if write_special(b, f) do return
	p := max(prec, 1)
	d := float_digits(f, p)
	if d.neg do strings.write_byte(b, '-')
	if d.decpt <= -4 || d.decpt > p {
		write_exponent_form(b, &d)
	} else {
		write_fixed_form(b, &d, 0)
	}
}

float_g :: proc(f: f64, prec := 6, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	write_float_g(&b, f, prec)
	return strings.to_string(b)
}

// ``"%.{prec}f" % f``.
write_float_f :: proc(b: ^strings.Builder, f: f64, prec: int) {
	if write_special(b, f) do return
	buf: [512]u8
	s := string(strconv.generic_ftoa(buf[:], f, 'f', prec, 64))
	strings.write_string(b, s[1:] if s[0] == '+' else s)
}

float_f :: proc(f: f64, prec: int, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	write_float_f(&b, f, prec)
	return strings.to_string(b)
}

// Python ``round(f)``: to the nearest integer, halves to even.
py_round :: proc(f: f64) -> int {
	fl := math.floor(f)
	diff := f - fl
	r := int(fl)
	if diff > 0.5 || (diff == 0.5 && r % 2 != 0) do r += 1
	return r
}

// ``int(s)`` / ``float(s)`` of the number part of a measure.
@(private = "file")
parse_number :: proc(s: string) -> (Num, bool) {
	if i, ok := strconv.parse_int(s, 10); ok {
		digits := s[1:] if len(s) > 0 && s[0] == '-' else s
		if len(digits) > 0 && strings.index_byte(digits, '.') < 0 do return i, true
	}
	if strings.count(s, ".") > 1 || s == "." || s == "-." do return nil, false
	f, ok := strconv.parse_f64(s)
	return f, ok
}

Unit_Pattern :: enum u8 {
	Default, // ``[a-zA-Zµ]*|%?``
	Star, // ``[*]?``
}

@(private = "file")
is_unit_char :: proc(r: rune) -> bool {
	return (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || r == 'µ'
}

// ``nodes.parse_measure(measure, unit_pattern)``: value and unit of a
// measure such as "3.5 em"; ``ok`` is false for an invalid measure.
parse_measure :: proc(measure: string, pattern := Unit_Pattern.Default) -> (Num, string, bool) {
	i := 0
	if i < len(measure) && measure[i] == '-' do i += 1
	start := i
	for i < len(measure) && ((measure[i] >= '0' && measure[i] <= '9') || measure[i] == '.') {
		i += 1
	}
	if i == start do return nil, "", false
	number := measure[:i]
	for i < len(measure) && measure[i] == ' ' do i += 1
	unit := measure[i:]
	switch pattern {
	case .Default:
		if unit != "%" {
			for r in unit do if !is_unit_char(r) do return nil, "", false
		}
	case .Star:
		if unit != "" && unit != "*" do return nil, "", false
	}
	value, ok := parse_number(number)
	if !ok do return nil, "", false
	return value, unit, true
}
