package main

// docodin-lsp: a Language Server Protocol server for reStructuredText.
//
// Speaks JSON-RPC 2.0 on standard input and output.  Diagnostics are
// docutils' system messages (from the native reader and transforms), with
// the checker's hints and quick fixes; the server also answers document
// symbols, folding ranges, semantic tokens, definitions, references,
// hover and completion.  See odin/lsp.

import "core:fmt"
import "core:os"
import "core:strings"

import check "../../odin/check"
import lsp "../../odin/lsp"

USAGE :: `Usage: docodin-lsp [--stdio]

A language server for reStructuredText, speaking the Language Server
Protocol on standard input and output.  Editors start it themselves; see
"Editor support" in docodin's README.

Options:
  --stdio      communicate over standard input and output (the default)
  --version    print the version and exit
  -h, --help   print this help and exit
`

main :: proc() {
	for arg in os.args[1:] {
		switch arg {
		case "--stdio":
		case "--version":
			fmt.println("docodin-lsp", lsp.VERSION)
			os.exit(0)
		case "-h", "--help":
			fmt.print(USAGE)
			os.exit(0)
		case:
			unknown_option(arg)
		}
	}
	os.exit(lsp.run())
}

// An Elm-style report of an unknown command-line option.
unknown_option :: proc(arg: string) -> ! {
	b := strings.builder_make()
	text := fmt.tprintf("I do not know the option `%s`.", arg)
	hint :=
		"Run `docodin-lsp --help` to see the options. Editors start the server " +
		"without options."
	check.format_report(&b, "UNKNOWN OPTION", "docodin-lsp", text, hint, false)
	os.write_string(os.stderr, strings.to_string(b))
	os.exit(2)
}
