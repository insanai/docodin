# docodin

docodin is a drop-in replacement for [docutils](https://docutils.sourceforge.io/)
0.22, built on a reStructuredText engine written in [Odin](https://odin-lang.org/).
Sphinx, its extensions and every other docutils user run on it unchanged, with
identical output.

It has three parts:

- **A docutils implementation** (`python/docodin/shim/docutils`). The whole
  docutils package, written for docodin: nodes, parser, directives, roles,
  transforms, and every writer (HTML, LaTeX/XeTeX, manpage, ODT, XML, S5,
  PEP). It passes docutils' own test suite and Sphinx's test suite with the
  same results as docutils.
- **A native reST engine** (`odin/rst`). It parses the block and inline
  grammar exactly as docutils does, including every system message and line
  number, about 5× faster. The shim builds the Python document tree from its
  output.
- **Native tools** (`odin/check`, `odin/publish`, `cmd/`). `docodin-check`
  reports markup errors without Python: Elm-style reports with source excerpts
  and hints, or docutils' one-line format. `docodin` publishes documents
  without Python, with docutils' output, messages and exit status: the native
  document pipeline (reader, transforms, and the pseudo-XML, XML, HTML5, LaTeX
  and XeLaTeX writers); see [docs/NATIVE_PIPELINE.md](docs/NATIVE_PIPELINE.md).
  Documents that need a Python library (Pygments, PIL, ...) go through
  docutils automatically.

## Installation

```bash
uv pip install docodin          # or: pip install docodin
```

Wheels contain the native library for their platform. To build from source
you need the Odin compiler (`dev-2026-09` or newer) and a C toolchain (clang
on macOS, clang or cc on Linux):

```bash
uv build                        # sdist and platform wheel (hatchling)
scripts/build_odin.sh           # development: library, docodin-check, docodin, docodin-lsp
```

## Using docodin instead of docutils

docodin serves the `docutils` package itself. Programs keep importing
`docutils`, and there is no other API to learn.

| How | What happens |
|-----|--------------|
| `docodin-sphinx-build ARGS...` | `sphinx-build` running on docodin |
| `DOCODIN_DOCUTILS=1 any-command` | every Python process in the environment uses docodin (for example `sphinx-build`, `tox`, test runners) |
| docutils not installed | `import docutils` finds docodin automatically |
| `docodin.shim.install_shim(force=True)` | switch the current process, before docutils is imported |

The start-up hook behind `DOCODIN_DOCUTILS` (`docodin.pth`) costs about
0.1 ms and imports nothing unless docutils is requested.

Extensions that change the reST grammar still work exactly as with docutils.
That covers custom state classes, subclassed or monkeypatched parser states,
and patched `Inliner` dispatch. For those documents docodin parses with its
pure-Python state machine. `DOCODIN_NATIVE=0` forces the Python parser
everywhere, for debugging.

## Compatibility

- **docutils' test suite**: 465 passed, 17 skipped, 1862 subtests, identical to
  docutils. This holds natively and with `DOCODIN_NATIVE=0`.
- **Sphinx 9.1's test suite**: 2407 passed. The 7 failures are environment
  related and fail the same way with docutils.
- **Extensions and themes**: the test suites of myst-parser, sphinx-design,
  sphinx-tabs, sphinxcontrib-bibtex, sphinx-autodoc-typehints, sphinx-gallery,
  pydata-sphinx-theme, sphinx-book-theme, sphinxext-opengraph,
  sphinx-notfound-page, sphinx-rtd-theme and breathe give the same results as
  with docutils.
- **Documentation builds**: the furo, pydata, MyST and sphinx-design docs
  build to identical output with the html, latex, man and text builders, and
  CPython's documentation to identical HTML.
- **Differential testing**: generated and mutated documents are published by
  docutils and docodin with every writer under random settings. Outputs,
  warnings, and the source and line of every node must be identical
  (`tests/shim_differential.py`, `tests/fuzz_differential.py`).

## Performance

Linux x86-64 with 32 cores, Python 3.13, docutils 0.22.4 and Sphinx 9.1 (see
CHANGELOG.md):

| Workload | docutils | docodin |
|----------|----------|---------|
| Sphinx, CPython documentation (599 pages, `-j1`) | 65.6 s, 895 MB | 47.6 s (1.38×), 883 MB |
| The same with `DOCODIN_GC=tuned` (see below) | – | 38.4 s (1.71×), 1034 MB |
| Sphinx, CPython documentation (`-j auto`) | 32.7 s wall, 99.7 s CPU | 29.1 s wall, 74.7 s CPU |
| Publish the docutils documentation to HTML5 (60 files, in process) | 2.21 s | 0.96 s (shim), 0.20 s (`publish_native`) |
| The same, one command per file | 7.37 s (`python -m docutils`) | 0.22 s (`docodin`) |
| Check the docutils and Sphinx documentation for markup errors | 2.81 s | 0.03 s (`docodin-check -j1`) |

Sphinx output is identical. `DOCODIN_GC=tuned` (for `docodin-sphinx-build`,
or `docodin_gc_tuning = True` with the `docodin.sphinx` extension) tunes
Python's garbage collector. It is opt-in: projects whose output depends on
when objects are collected (duplicate labels, repeated generated ids) can
change, with docutils as with docodin.

## Native publishing

```bash
docodin doc.rst doc.html                     # as: python -m docutils doc.rst doc.html
docodin --writer=latex --documentclass=book doc.rst doc.tex
rst2xetex doc.rst doc.tex                    # rst2* names (links to docodin) pick the writer
docodin pdf doc.rst                          # LaTeX writer + pdflatex (or --engine=xelatex)
docodin --help --writer=latex                # the options of a writer
```

`docodin` takes docutils' front-end options (report, halt and exit-status
levels, title and docinfo switches, section numbering, backlinks, footnote
references, smart quotes, stripping, language, encodings, stylesheets, math
output, table styles, LaTeX document class and options, ...) and writes the
same output, messages and exit status as `python -m docutils`. It reads no
configuration files (`--config` runs it through Python, see below); `html` is
the html5 writer. Bad options get Elm-style reports with a hint.

From Python, `docodin.publish_native(source, writer="html5",
settings_overrides=...)` returns what `publish_string` returns (and
`publish_parts` with `parts=True`), raising docutils' exceptions.
`docodin.render_html` and `docodin.render_latex` return the whole document
or its body.

Some docutils features use Python libraries, which docodin does not
reimplement: Pygments (code with a language), PIL (image sizes for scaled
images and `:figwidth: image`), `urllib` (`:url:` options other than local
`file:` URLs), Python's codecs (encodings other than UTF-8, Latin-1 and
ASCII), parser and writer modules (`include` with `:parser:`, writers other
than the native ones) and external MathML converters. The native pipeline
detects where docutils would use one, and such documents are published by
docutils instead, so the result is always docutils' (with the libraries
that are installed):

- `publish_native`, `render_html` and `render_latex` use the importable
  docutils. Pass `native_only=True` to get a `docodin.NeedsPythonError`,
  listing each feature and its line, instead.
- `docodin` runs `python -m docodin` with the same arguments, standard
  streams and exit status. It uses `$DOCODIN_PYTHON`, else `python3`, if it
  imports docodin; `--config` and the `--dump-*` options go the same way.
  Without such a Python, it reports what needs Python and how to avoid it
  (for example `--syntax-highlight=none`) and exits with status 1:

```
-- NEEDS PYTHON ---------------------------------------------------- guide.rst:4

Highlighting "python" code needs Pygments.

docodin runs these with docutils' Python front end (`python -m docodin`), but
found no Python that imports docodin: it tries `$DOCODIN_PYTHON`, then
`python3`.

4| .. code:: python
   ^^^^^^^^^^^^^^^^
Hint: Install docodin's Python package (`pip install docodin`) or set
`DOCODIN_PYTHON` to a Python that has it, or write `--syntax-highlight=none` to
publish the code without highlighting.
```

## Native checker

```bash
docodin-check docs/*.rst                           # Elm-style reports
docodin-check --error-format=docutils docs/*.rst   # source:line: (LEVEL/n) text
docodin-check --report=info --exit-status=warning README.rst
```

```
-- UNCLOSED EMPHASIS ----------------------------------------- guide.rst:12:6

Inline emphasis start-string without end-string.

12| Some *emphasis without an end.
         ^
Hint: Close the emphasis with a matching `*`, or write `\*` for a literal
asterisk.
```

The checker reports what the parser detects, including in the reST content
of the standard directives. Directive execution, roles and reference
resolution need Python; use `docodin` or Sphinx for those.

## Editor support

`docodin-lsp` is a language server for reStructuredText. Editors start it and
talk to it over standard input and output (the Language Server Protocol);
it runs no Python. `scripts/build_odin.sh` builds it into `bin/`.

- **Diagnostics** as you type: docutils' own messages (text, level and line)
  from the native parser, directives, roles and reference transforms, such as
  `Unknown target name: "x".` or `Duplicate explicit target name`. Parser
  messages carry the checker's title and hint, and point at the offending
  inline markup.
- **Quick fixes** where the hint is mechanical: extend a title's underline
  (and overline) to the title's width, insert a missing blank line, escape an
  unmatched start-string, turn a `::` without a literal block into `:`.
- **Navigation**: go to definition and find references for hyperlink
  references (named, anonymous and embedded), section titles, substitutions,
  footnotes and citations, with docutils' name normalisation. Hover shows a
  target's URI or section, a substitution's definition, a footnote's text,
  and what a directive or role takes.
- **Structure**: document symbols (the section tree, with targets,
  substitution definitions, footnotes and citations), folding ranges
  (sections, directives, lists, literal blocks, tables, comments) and
  semantic tokens (titles and adornments, inline markup, roles, directive
  names, arguments and options, field names, targets, comments).
- **Completion**: directive names after `.. `, a directive's options, role
  names after `:`, and the reference names, substitutions and footnote labels
  the document defines.

Settings go in the client's `initializationOptions` (or the `docodin`
section of its workspace configuration):

| Setting | Default | Meaning |
|---------|---------|---------|
| `reportLevel` | `"warning"` | lowest level reported: `info`, `warning`, `error`, `severe`, `none` |
| `debounce` | `150` | milliseconds between the last edit and new diagnostics |
| `sphinx` | `false` | Sphinx's roles and directives (and domain names such as `py:func`) are known |
| `knownRoles`, `knownDirectives` | `[]` | further names defined by extensions |

docutils reports the roles and directives of Sphinx and its extensions as
unknown; `sphinx` and the known names silence those messages only.

**Neovim** (0.11 or later):

```lua
vim.lsp.config("docodin", {
  cmd = { "/path/to/docodin/bin/docodin-lsp" },
  filetypes = { "rst" },
  root_markers = { "conf.py", "docutils.conf", ".git" },
  init_options = { reportLevel = "warning", sphinx = true },
})
vim.lsp.enable("docodin")
```

With nvim-lspconfig on older versions:

```lua
local lspconfig = require("lspconfig")
local configs = require("lspconfig.configs")
if not configs.docodin then
  configs.docodin = {
    default_config = {
      cmd = { "/path/to/docodin/bin/docodin-lsp" },
      filetypes = { "rst" },
      root_dir = lspconfig.util.root_pattern("conf.py", "docutils.conf", ".git"),
      init_options = { reportLevel = "warning" },
    },
  }
end
lspconfig.docodin.setup({})
```

The emphasis and strong tokens have their own types; link them to a
highlight group, for example `vim.api.nvim_set_hl(0, "@lsp.type.emphasis.rst",
{ italic = true })`.

**VS Code**: any generic LSP client works. A minimal extension with
`vscode-languageclient` (activated `onLanguage:restructuredtext`):

```ts
import { LanguageClient } from "vscode-languageclient/node";

export function activate() {
  const client = new LanguageClient(
    "docodin", "docodin",
    { command: "/path/to/docodin/bin/docodin-lsp" },
    {
      documentSelector: [{ language: "restructuredtext" }],
      initializationOptions: { reportLevel: "warning", sphinx: true },
    },
  );
  client.start();
}
```

**Zed** starts language servers declared by extensions. A dev extension
(`zed: install dev extension`) declares the server in `extension.toml`:

```toml
id = "docodin"
name = "docodin"
version = "0.1.0"
schema_version = 1

[language_servers.docodin-lsp]
name = "docodin-lsp"
languages = ["reStructuredText"]
```

and returns the command from its `language_server_command`
(`zed::Command { command: "/path/to/docodin/bin/docodin-lsp".into(), args: vec![],
env: vec![] }`). The server is then configured in `settings.json`:

```json
{
  "languages": {
    "reStructuredText": { "language_servers": ["docodin-lsp", "..."] }
  },
  "lsp": {
    "docodin-lsp": {
      "initialization_options": { "reportLevel": "warning", "sphinx": true }
    }
  }
}
```

The reStructuredText language itself (file types, syntax highlighting) comes
from a reStructuredText extension such as zed-rst.

Limits: the server works on one file at a time (cross-document `:ref:` and
`:doc:` are not resolved), includes are read from disk, and unknown
languages of `code` directives are not reported (docutils asks Pygments,
which the native pipeline does not have).

## Layout

```
odin/rst/           reST parser (data-oriented parse tree)
odin/check/         checker core and Elm-style diagnostics
odin/doctree/       native docutils document tree, registry, reporter, JSON interchange
odin/reader/        native reader: docutils document trees, directives and roles
odin/transforms/    native docutils transforms
odin/writers/       native pseudo-XML, XML, HTML5 and LaTeX/XeLaTeX writers
odin/math/          native math2html and latex2mathml (package texmath)
odin/text/          native smart quotes
odin/publish/       native publisher (settings, reader, transforms, writer)
odin/lib/           C ABI library used by the Python package
cmd/                docodin-check and the docodin native CLI
python/docodin/     Python package: tree builder, shim, Sphinx integration
python/docodin/shim/docutils/   the docutils implementation
scripts/            build script, table and data generators
tests/              unit, parity, differential, conformance and benchmark tools
```

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the design.

## Known limits

- Two nested-include cases (in about 20,000 generated documents) differ in
  line numbers: an `include` two directive levels deep with more content
  after it in the outer directive.
- The native pipeline does not see directives, roles or transforms
  registered in Python; publish such documents with docutils (the shim).
- In `docodin` and `python -m docodin`, `html` is the html5 writer (in
  docutils it is html4css1).

Native publishing has no other limits: documents that need a Python
library are published by docutils (see [Native publishing](#native-publishing)).

## Tests

```bash
for t in odin/tests odin/{doctree,reader,transforms,writers,publish}/tests; do odin test $t; done
uv run python -m pytest tests
uv run python tests/shim_differential.py --cases 2000
uv run python tests/fuzz_differential.py --cases 10000
uv run python tests/lint_differential.py
uv run --no-project --python 3.14 --with docutils==0.22.4 python \
    tests/native_publish_differential.py --docutils-src ~/src/docutils-0.22.4 --fuzz 3000
```

## License

MIT
