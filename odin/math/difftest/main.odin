// Differential test driver of package texmath: reads a JSON list of TeX
// snippets and writes, for each, the results of the converters as JSON (see
// ``tests/native_math_differential.py``).
//
//     math-difftest snippets.json > results.json
package main

import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:os"

import texmath ".."

Outcome :: struct {
	value: string,
	exc:   string, // the Python exception type, if any
	msg:   string,
	trace: string, // math2html's messages on standard error
}

Case :: struct {
	mml0, mml1:        Outcome,
	h0, h1, hsimple:   Outcome,
	uni, env:          string,
}

outcome :: proc(value: string, err: texmath.Error, trace := "") -> Outcome {
	result := Outcome{value = value, trace = trace}
	if exception, raised := err.?; raised {
		result.exc = texmath.EXCEPTION_NAMES[exception.kind]
		result.msg = exception.message
	}
	return result
}

html :: proc(snippet: string, options: texmath.Math2html_Options) -> Outcome {
	result := texmath.convert_math2html(snippet, options)
	return outcome(result.html, result.err, result.trace)
}

run :: proc(snippet: string) -> Case {
	result: Case
	mml, err := texmath.tex2mathml(snippet, false)
	result.mml0 = outcome(mml, err)
	mml, err = texmath.tex2mathml(snippet, true)
	result.mml1 = outcome(mml, err)
	result.h0 = html(snippet, {display = false})
	result.h1 = html(snippet, {display = true})
	result.hsimple = html(snippet, {simplemath = true})
	result.uni = texmath.uni2tex_translate(snippet)
	result.env = texmath.pick_math_environment(snippet)
	return result
}

main :: proc() {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		os.exit(2)
	}
	context.allocator = virtual.arena_allocator(&arena)
	if len(os.args) != 2 {
		fmt.eprintln("usage: math-difftest snippets.json")
		os.exit(2)
	}
	data, read_err := os.read_entire_file(os.args[1], context.allocator)
	if read_err != nil {
		fmt.eprintln("cannot read", os.args[1])
		os.exit(2)
	}
	snippets: []string
	if json.unmarshal(data, &snippets) != nil {
		fmt.eprintln("not a JSON list of strings:", os.args[1])
		os.exit(2)
	}
	cases := make([]Case, len(snippets))
	for snippet, index in snippets {
		cases[index] = run(snippet)
	}
	output, marshal_err := json.marshal(cases)
	if marshal_err != nil {
		os.exit(2)
	}
	os.write(os.stdout, output)
}
