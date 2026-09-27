# docodin architecture

docodin replaces docutils 0.22 in two ways:

- **Inside Python.** `python/docodin/shim/docutils` is a complete docutils
  package: nodes, frontend, io, readers, parser, directives, roles,
  transforms, writers and utilities. It is served under the name `docutils`,
  so Sphinx and its extensions run on it unchanged. Its reStructuredText
  parser is docodin's native engine.
- **Without Python.** A native Odin pipeline (reader, transforms, writers)
  publishes documents byte for byte like docutils. It powers the `docodin`
  command, `docodin-check` and `docodin.publish_native`.

```
                           reST text
                               │
                 ┌─────────────▼─────────────┐   odin/rst: the parser
                 │ string2lines · states      │   (data-oriented parse tree,
                 │ body · explicit · tables   │    every parser message)
                 │ lists · inline             │
                 └──────┬──────────────┬──────┘
         C ABI (marshal)│              │ Odin API
                        ▼              ▼
   python/docodin ─────────────┐   ┌──────────────────────── odin/reader
   builder.py: docutils.nodes, │   │ doctree.Doc, registry, directives, roles
   registry, sections, the     │   └──────────────┬─────────
   directives and roles of     │                  ▼          odin/transforms
   docutils/Sphinx/extensions  │        Transformer and every standard transform
              │                │                  ▼          odin/writers (+ odin/math)
              ▼                │        pseudoxml · xml · html5 · latex · xetex
   the shim's (or Sphinx's)    │                  ▼          odin/publish
   transforms and writers      │        publish(): output, parts, messages, exit status
                               │
   shim fallback: pure-Python parser states when extensions change the grammar
```

## The docutils implementation (`python/docodin/shim`)

- **Layout.** The package mirrors docutils' module layout. Every public
  class, function and attribute has its docutils name, signature and module
  path (`__module__ == "docutils.nodes"`, …), so pickled Sphinx environments,
  `isinstance` checks and subclassing work as with docutils. Large modules
  are split into private submodules (`nodes/_base.py`, `writers/_html_base_*.py`,
  `latex2e/_*.py`, `utils/math/_math2html_*.py`) and re-exported.
- **Data.** Language modules, character tables, URI schemes, smart-quote
  tables, math tables, the writers' stylesheets and templates and the
  standard include files are generated or copied from docutils by
  `scripts/gen_shim_data.py`.
- **Import hook.** `docodin.shim` defines a meta-path finder that maps
  `docutils` and `docutils.*` to the shim's files.
  - `install_shim(force=True)` puts it first, so it takes precedence over an
    installed docutils.
  - `enable()` registers it as a fallback.
  - `docodin.pth` imports `docodin_autoload` in every interpreter. With
    `DOCODIN_DOCUTILS=1` it installs the shim; otherwise it only adds a lazy
    fallback finder. It costs about 0.1 ms and imports nothing else.
  - `docodin-sphinx-build` installs the shim and runs `sphinx-build`.
- **Parsing.** `Parser.parse` and `RSTStateMachine.run` hand the input to
  the native engine through `docodin.builder`. Directives and roles, which
  are Python code from docutils, Sphinx or extensions, run on state and
  state-machine objects that subclass the docutils classes (`_machine.py`).
  When they call `nested_parse`, `inline_text` or `parse_directive_block`,
  the calls return to the native engine.
- **Fallback parser.** The shim also contains the complete block parser in
  Python (`parsers/rst/states.py`, `_body.py`, `_explicit.py`). A document is
  parsed with it when:
  - the state classes are not the stock ones;
  - the initial state is not `Body` or `RFC2822Body`;
  - a custom `Inliner` class is used;
  - an extension replaced or wrapped a method or pattern of a stock state
    class or of `Inliner`. `_fallback.Snapshot` compares the classes with a
    snapshot taken at import.
  - `DOCODIN_NATIVE=0` is set.

  Two replacements keep the native path. sphinx-autodoc-typehints replaces
  `Body.doctest` and wraps `Text.indent`; the builder replays those
  replacements on the natively built constructs.
- **Native helpers.** SmartQuotes educates text in Odin
  (`docodin_educate`). The Python version remains the reference and the
  fallback.

## Odin packages

| Package | Contents |
|---------|----------|
| `odin/rst` | The parser. `nodes.odin` is the data-oriented parse tree: `Node` handles into a `Tree` with an `#soa` node array and side tables for directive and phrase-reference data. The package also holds the state machine (`statemachine.odin`), the body, list, explicit-markup and table states, the inliner, hand-written matchers for docutils' regexes (`patterns.odin`) and generated Python-compatible character classes. |
| `odin/check` | The checker core: collects parser messages, including those inside the reST content of standard directives, and renders them in the Elm style (`format_elm`: excerpt, markers, hint) or in docutils' format. |
| `odin/doctree` | The docutils document tree: `Node` handles into an `#soa` element array, interned strings, attribute side tables, the complete `document` registry, the reporter, settings and pseudo-XML. It also has the JSON interchange with docutils (`json.odin`, `json_dump.odin`). |
| `odin/reader` | `Parser.parse` into a `doctree.Doc`: a port of `builder.py` (registration, sections, include handling) with the complete standard directive and role set and docutils' language tables. |
| `odin/transforms` | The Transformer (priority queue, docutils' ordering rules) and every standard transform: universal, references, frontmatter, parts, misc, writer_aux, components, peps. |
| `odin/writers` | The pseudoxml, xml, html5, latex and xetex writers with their parts. They use output buffers, dispatch tables indexed by `doctree.Tag`, and templates and stylesheets embedded with `#load`. |
| `odin/math` (`texmath`) | `math2html` and `latex2mathml`, with docutils' exact output, trace messages and errors. |
| `odin/text` | Smart quotes (`educate_tokens`), all languages and attribute modes. |
| `odin/publish` | `publish()`: settings with docutils' validators, reader, transforms, writer, reporter and halting, and the exit status of `publish_cmdline`. |
| `odin/lib` | The C ABI for Python: `docodin_parse` (with an include callback), `docodin_parse_inline`, `docodin_split_lines`, `docodin_educate`, `docodin_publish`, `docodin_free`, and the version and init functions. Results use CPython's `marshal` format, so `marshal.loads` builds them in C. |
| `cmd/docodin` | The native `docodin` command (docutils front-end options, `check`, `pdf`). |
| `cmd/docodin-check` | The parallel checker. |

## Memory and safety

- **Handles, not pointers.** Parse trees and document trees store nodes in
  `#soa` arrays and link them with `distinct u32` handles. Access is
  bounds-checked, handles survive array growth, and no pointer into a growable
  array is kept.
- **Arenas.** Each parse, document and write uses one arena that is freed at
  once. The C ABI uses a per-thread bump arena, reset when the outermost call
  returns, so calls may re-enter through the include callback. The checker
  gives each worker thread its own arena.
- **No shared mutable state.** Tables are `@(rodata)`. The library can be
  called from many threads, and Sphinx's parallel reading is safe.
- **Bounds checks stay on in release builds.** Recursion is bounded
  (`MAX_NESTING`, math `MAX_DEPTH`). Where docutils would fail with a
  `RecursionError`, docodin reports an error message instead.
- **Unicode.** All generated Unicode tables come from one CPython version
  (3.14, Unicode 16), recorded in each table's header.

## Fidelity

The engine reproduces docutils' behaviour, including its quirks:

- **Line numbers of nested parses.** Table cells use a 1-based
  `input_offset`, and substitution definitions drop lines without adjusting
  the offset. `line_delta` carries both adjustments.
- **The reporter's line and `document.current_line`.** The parser tracks the
  outermost state machine's position (frozen inside list-like constructs), and
  the cursor on every `next_line`, `previous_line` and `goto_line`. It records
  them where docutils attaches nodes, so every node's `source` and `line`
  match.
- **`include`.** Included lines are inserted into the input of the state
  machine that runs the directive and parsed there, with docutils' padding
  lines, as `insert_input` does. The Python host dry-runs docutils' own
  `Include` through a native callback. Errors are raised by the real run, in
  document order.
- **Message order.** Messages that docutils creates before parsing a
  construct's content (for example "Unexpected indentation." after a
  paragraph, or an enumerated list's start value) are created first.
- **Python semantics.** The native code reproduces:
  - `str` methods, `repr`, float formatting;
  - `unicodedata` normalisation for `make_id`;
  - dict ordering in the registry;
  - `findall` under mutation;
  - the exception texts docutils lets through.

## Verification

| Test | What it compares |
|------|------------------|
| docutils' own test suite with the shim (native and `DOCODIN_NATIVE=0`) | 465 tests, identical to docutils |
| Sphinx's test suite with the shim | identical pass/fail lists (stock, native, forced Python) |
| `tests/shim_differential.py` | shim against docutils: every writer, random settings, outputs, warnings and node positions |
| `tests/fuzz_differential.py` (also `--directives`) | parser against docutils: pseudo-XML, messages, node positions, includes |
| `tests/test_parity.py`, `test_python_states.py`, `test_ecosystem.py` | host corner cases, customised grammars, extension patches |
| `tests/native_{reader,transforms,writers,publish,math}_differential.py` | each native stage against docutils dumps (`scripts/doctree_json.py`), then the whole pipeline against `publish_string`/`publish_parts` |
| `tests/smartquotes_differential.py` | native smart quotes against the Python reference |
| `tests/lint_differential.py`, `test_checker.py` | the checker against docutils' parser messages |
| `odin test` in each package | unit tests and interchange fixtures |

The differential scripts that produce docutils dumps run under CPython 3.14
(`uv run --no-project --python 3.14 --with docutils==0.22.4 python`), the
version the native tables target.

## Known limits

- **Two nested-include cases** (in about 20,000 generated documents) differ
  in line numbers. They occur when an `include` sits two directive levels
  deep and more content follows in the outer directive.
- **Native pipeline only:**
  - Pygments highlighting behaves as `syntax_highlight: none`.
  - PIL image sizes are not read.
  - URLs other than `file:` are not fetched.
  - Only the codecs utf-8, latin-1 and ascii are supported.
  - `html` means html5 (in docutils it is html4css1).

  The Python shim has none of these limits.
