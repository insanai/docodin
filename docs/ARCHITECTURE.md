# docodin architecture

docodin replaces the docutils reStructuredText *parser*. docutils'
`docutils/parsers/rst/states.py` is a regex-driven state machine. It is
reimplemented in Odin and reproduces docutils 0.22 exactly: the same tree
shapes, system messages, and line numbers.

Everything that is Python code in the docutils ecosystem stays in Python:
- directives, roles, and transforms
- writers
- Sphinx and its extensions

Those run unchanged on top of a document tree that is indistinguishable from
the one docutils builds.

```
          reST text / StringList
                   │
                   ▼
   ┌──────────────────────────────────┐   odin/rst      (package rst)
   │ string2lines · state machine     │   recognition of every construct,
   │ body · explicit · tables · inline│   all parser system messages
   └──────────────────────────────────┘
                   │ parse tree (rst.Node), arena-allocated
                   ▼
   ┌──────────────────────────────────┐   odin/lib      (libdocodin)
   │ marshal serializer · C ABI       │   per-thread bump arena
   └──────────────────────────────────┘
                   │ bytes (CPython marshal format)
                   ▼
   ┌──────────────────────────────────┐   python/docodin
   │ TreeBuilder: docutils.nodes,     │   document registry (note_*),
   │ sections, directives, roles      │   directives/roles in real
   └──────────────────────────────────┘   docutils state objects
                   │ docutils document
                   ▼
      docutils / Sphinx transforms and writers (unchanged)
```

## Division of work

The **native parser** (`odin/rst`) does everything that depends only on the
text. That includes:
- line splitting and tab expansion (`string2lines`)
- indentation and the block state machine
- section title and transition detection
- lists: bullet, enumerated, definition, field, option, and line blocks
- literal, doctest, and quoted literal blocks
- block quotes and attributions
- grid and simple tables
- footnotes, citations, and hyperlink targets
- substitution definitions and comments
- directive block extraction
- the complete inliner, including URI, e-mail, PEP, and RFC recognition,
  escapes, and embedded links

It creates every system message the docutils parser creates, with identical
text, level, and line.

The **host** (`python/docodin/builder.py`) does what needs Python objects or
Python code:
- It builds `docutils.nodes` from the parse tree.
- It registers names, ids, references, footnotes, citations, and
  substitutions with the `document` in docutils' order, which produces the
  same ids and the same duplicate-name messages.
- It nests sections (`check_subsection`).
- It runs directives and interpreted text roles.

Directives run with state and state-machine objects that subclass the
docutils classes (`OdinBody`, `OdinStateMachine`), so directive code written
for docutils or Sphinx behaves identically. When a directive calls
`nested_parse`, `inline_text`, or `parse_directive_block`, the call is routed
back to the native parser.

## Odin packages

### `odin/rst`: the parser

| File | Contents |
|------|----------|
| `nodes.odin` | `Node` (intrusive child list; kind, flags `bit_set`, line, text/raw/name, `Extra` union for phrase references and directives), `Attrs`, node lists |
| `node_kinds.odin` | generated `Node_Kind` enum (the wire numbering) and docutils tag names |
| `source.odin` | `Settings`, `split_lines` (exact `string2lines`), line-length limit |
| `statemachine.odin` | `Parser`, `State_Machine` (cursor over a line slice, like `StateMachineWS`), indented-block extraction, messages, `nested_parse` |
| `body.odin` | Body/Text/Line states, lists, block quotes, literal blocks, section titles |
| `explicit.odin` | footnotes, citations, targets, substitution definitions, directives, comments |
| `tables.odin` | grid and simple table parsers (docutils `tableparser` semantics, on code points) |
| `inline.odin` | the `Inliner`: start/end-string recognition, roles, references, implicit links |
| `patterns.odin` | hand-written matchers for the docutils regexes (bullets, enumerators, field and option markers, table borders, …) |
| `chars.odin`, `unicode_tables.odin` | Python-compatible character classes (`str.isspace`, `\w`, docutils' punctuation tables); generated from CPython's `unicodedata` |
| `text_util.odin` | `escape2null`/`unescape`, whitespace normalization, URI normalization |
| `document.odin` | `Parse_Flags` and the `parse_text` entry point |

The regexes are compiled by hand into matchers that reproduce Python's
backtracking order where it matters. Examples are option markers, field
markers, and the inline start-string rules.

### `odin/lib`: the shared library

- `export.odin` defines the C ABI:
  - `docodin_parse`, `docodin_parse_inline`, `docodin_split_lines`
  - `docodin_free`, `docodin_version`, `docodin_abi_version`
  - `docodin_init`, the library initializer
- `bump.odin` is the per-thread allocator (see below).
- `serialize.odin` writes the parse tree in CPython `marshal` format, so
  `marshal.loads` builds the tuples, lists, strings, and ints in C. There is
  no per-node ctypes traffic and no JSON parsing.

The library is compiled with `-build-mode:obj -use-single-module` and linked
by the system toolchain, with `docodin_init` registered via `-Wl,-init`.
Odin's `-build-mode:shared` currently produces an invalid entry-point
reference on macOS. `docodin_init` runs `runtime._startup_runtime()` so that
global initializers run on load.

### `cmd/docodin-check`: the native checker

The checker parses files with `rst.parse_text` and walks the tree, collecting
system messages and inline `problematic` messages. It then reproduces the
parts of docutils' parser that live outside the state machine:
- title-level consistency (`check_subsection`)
- the reST content of the standard directives: admonitions, `topic`,
  `sidebar`, `container`, `compound`, `table`, `list-table`, `figure`,
  `class`, `replace`, `parsed-literal`, `rubric`, `contents`, `header`/`footer`,
  and the block-quote directives

It parses directive arguments and options with docutils' own rules
(`parse_directive_block`) and checks the directive placement rules for topic
and sidebar. Files are processed in parallel. Each worker thread has its own
`virtual.Arena`, and the arena is reset after every file.

## Memory model

- **One arena per parse.** Every node, line slice, and string produced by a
  parse lives in the calling thread's `Bump_Arena`. The arena is reset before
  the C call returns. Nothing is freed piecemeal, and nothing survives
  between calls except the result buffer. The caller owns that buffer and
  releases it with `docodin_free`.
- **Lock-free.** The arena is `@(thread_local)` and needs no mutex. Steady
  state involves no heap calls: the reset keeps the most recent block (up to
  64 MB), and the last allocation can grow in place.
- **Thread safety.** There is no global mutable state; the Unicode and
  character tables are `@(rodata)`. The library can be called from many
  threads at once. Sphinx's parallel reading is marked safe.
- **Zero copy where possible.** Lines are slices of the input. Only lines
  containing tabs, `\v`, or `\f` are rewritten. Nodes store slices, and
  strings are copied only when text is transformed (unescaping, whitespace
  normalization).
- **Bounds checks stay on in release builds.** Adversarial input can produce a
  wrong parse at worst, never memory corruption. Recursion is bounded:
  - `MAX_NESTING` (160) limits block nesting, where docutils itself fails
    with a `RecursionError`.
  - `MAX_LINE_BLOCK_DEPTH` limits line-block nesting.

  Beyond these limits the content is reported with an ERROR message instead
  of overflowing the native or Python stack.

## Fidelity details

docutils' behaviour includes several quirks that affect output, and the
parser reproduces them deliberately:

- **Line numbers of nested parses.**
  - Table cells are parsed with a 1-based `input_offset` (`line_delta = -1`).
  - Substitution definitions drop their name lines without adjusting the
    offset (`line_delta = blockindex`).
  - `State_Machine.line_delta` carries both adjustments, so message lines
    come out as docutils computes them.
- **The reporter's "current line".** Messages without an explicit line use
  the outermost state machine's position. The second and later items of
  list-like constructs are parsed in a nested machine, which freezes that
  position, and `frozen_line` models this. The final `line_offset` of the
  top machine is returned to the host, because messages created by
  transforms use it.
- **End-of-input handling.** EOF inside the Text or Line state ends the run,
  exactly like docutils.
- **`document.current_line`.** Every docutils state machine reports its
  cursor moves to `document.note_source`. A node attached without an
  explicit line then takes that value, and so do system messages, which the
  reporter never gives a Python-level line.
  - `Parser.cur_line` follows the same rules. `observe` runs on every
    `next_line`, `previous_line`, and `goto_line`, with Python's indexing
    semantics: one past the end has no line; beyond that there is no source
    either.
  - The value is recorded on the nodes whose attachment depends on it. The
    host sets it before attaching them and after every nested parse.
  - As a result, `node.source`/`node.line` match docutils for every node.
- **Cell line numbers.** `isolate_grid_table` sometimes backs up one line too
  far (a docutils bug), which lowers `tableline`. The line delta of the cells
  is computed per table, because docutils takes cell lines from the source
  positions of the lines.
- **`include`.** docutils keeps inserted lines in `input_lines`, so later
  absolute line numbers grow by the inserted length. The host parses
  inserted lines and removes them again, which keeps the native items'
  numbering valid. When the parse ends, it re-inserts them and renumbers the
  nodes that carry absolute lines (targets, `parsed-literal`). Transforms
  then see exactly docutils' state.
- **Non-positive lines.** docutils resolves a line number ≤ 0 through
  `input_lines.info(line - 1)`, a negative index, so the message is reported
  near the end of the input. The checker applies the same mapping.
- **Raw lines.** Sphinx passes a `StringList` that already carries
  `rst_prolog`/`rst_epilog`. The `Raw_Lines` flag parses those lines as given,
  without `string2lines`.

## Python host

- **`_native.py`** loads the library, checks the ABI version, and decodes
  results with `marshal.loads`.
- **`builder.py`** provides:
  - `DocumentContext`: one parse into one document.
  - `OdinStateMachine`: materializes its `input_lines` lazily. When the input
    is linear (a whole string), source and line lookups are simple
    arithmetic.
  - `TreeBuilder`: dispatch tables indexed by node kind.
  - Fast node constructors: these avoid `Element.__init__` for fresh
    unattached nodes and produce identical objects.
- **`parser.py`** provides:
  - `Parser`, a `docutils.parsers.rst.Parser` subclass.
  - `patch_docutils()`, which replaces `Parser.parse` and
    `RSTStateMachine.run` process-wide.
  - A fallback to the Python parser for custom state classes or inliners.
- **`sphinx.py`** provides `OdinSphinxRSTParser`. It uses the string fast
  path when there is no prolog or epilog.
- **`__main__.py`** provides the `docodin` command. It is `publish_cmdline`
  with the docodin parser and accepts every docutils option.

## Generated code

| Generator | Output |
|-----------|--------|
| `scripts/gen_unicode_tables.py` | `odin/rst/unicode_tables.odin`: character classes from CPython's `unicodedata` and docutils' punctuation tables |
| `scripts/gen_node_kinds.py` | `odin/rst/node_kinds.odin`: node kinds and tag names |

## Verification

- **`odin/tests`** holds the Odin unit tests (`odin test odin/tests`). They
  cover line splitting, block and inline structure, message lines, the
  nesting bound, and a check that every parser allocation goes through the
  parser's allocator.
- **`tests/test_conformance.py` and `tests/conformance/run_docutils_suite.py`**
  run docutils' parser test suite; all 913 cases pass.
- **`tests/test_parity.py`, `test_docutils_api.py`, and `test_sphinx.py`**
  run documents through docodin and docutils and compare the results:
  - the doctree
  - publish output for each writer
  - Sphinx builds
- **`tests/fuzz_differential.py`** runs grammar-based and mutation fuzzing
  and compares the full pseudo-XML with docutils.
- **`tests/test_checker.py` and `tests/lint_differential.py`** compare
  `docodin-check` with docutils' parser messages.
- **`tests/benchmark.py`** measures parse, doctree, and publish times against
  docutils.
