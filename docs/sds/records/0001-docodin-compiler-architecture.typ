#let sds-number = "0001"
#let sds-title = "DocOdin Compiler Architecture and Specifications"
#let sds-state = "committed"
#let sds-created = "2026-09-27"
#let sds-last-updated = "2026-09-27"
#let sds-category = "Architectural Proposal"
#let sds-status = "Implemented specification"
#let sds-discussion = "Repository discussion; DocOdin drop-in replacement."
#let sds-summary = "A high-performance, data-oriented reStructuredText compiler written in Odin, providing mathematical syntax guarantees, linear-time execution, native HTML5 and LaTeX/PDF backends, and a zero-dependency drop-in docutils replacement."
#let sds-authors = ("DocOdin Contributors",)
#let sds-labels = ("compiler", "rst", "odin", "data-oriented", "docutils", "sphinx", "mactex")

#import "../../shared/sds.typ": *
#import "@preview/fletcher:0.5.8" as fletcher: diagram, node, edge
#show: doc => sds-document(sds-number, sds-title, doc,
  state: sds-state, created: sds-created, updated: sds-last-updated,
  category: sds-category, authors: sds-authors, labels: sds-labels,
  status: sds-status, discussion: sds-discussion)

= Abstract

DocOdin is an idiomatic, data-oriented reStructuredText (reST) compiler written in Odin. It replaces the traditional Python-based Docutils parsing engine, delivering strict mathematical determinism, $O(N)$ linear time complexity, and a $5times$ to $50times$ throughput increase. This specification establishes the architecture of DocOdin across two primary operational modes: first, as a completely standalone, zero-Python toolchain compiling reST directly to semantic HTML5, LaTeX, and publication-quality PDF via MacTeX; and second, as a comprehensive, zero-external-dependency drop-in replacement for `docutils` within the Sphinx ecosystem. Following the editorial standards of SDS 1, this document formalizes the indentation calculus, the title lattice, the table geometry, the contiguous bump arena memory model, and the verification guarantees that ensure byte-for-byte fidelity with the reStructuredText specification.

#sds-contents()

= Motivation

For over two decades, `docutils` has served as the reference implementation and de facto specification for reStructuredText. While robust and extensible, Docutils suffers from fundamental architectural liabilities:

1. *Algorithmic Inefficiency:* The Python implementation in `docutils/parsers/rst/states.py` relies on hundreds of dynamically compiled, backtracking regular expressions executed inside nested state machines. Lexing and block identification account for 70% to 80% of total document compilation time.
2. *Deep Object Allocation Overhead:* In Docutils, every syntax element, line slice, character offset, and intermediate token is instantiated as an individual Python heap object. A 10,000-line document generates over 250,000 Python object allocations, overwhelming the CPython garbage collector and destroying CPU cache locality.
3. *Fragile Toolchain Dependencies:* Python-based documentation pipelines require complex virtual environments (`.venv`), fragile interpreter version alignments, and heavy wheel distributions, preventing seamless usage in lightweight CI/CD or embedded environments.
4. *Lack of Standalone Native Compilation:* Authors seeking to compile technical papers or software manuals to PDF must assemble convoluted multi-tool pipelines (Python + Docutils + Sphinx + WeasyPrint/LaTeX) rather than invoking a single, fast native compiler binary.

DocOdin solves these challenges by treating reStructuredText as a formal language compiled through data-oriented principles in Odin.

= Terminology and Scope

- *reST:* reStructuredText, an indentation-sensitive markup language.
- *AST:* Abstract Syntax Tree, represented as contiguous nodes in linear memory.
- *DOD:* Data-Oriented Design, structuring code around cache locality, linear memory streams, and minimal pointer chasing.
- *DFA:* Deterministic Finite Automaton.
- *Bump Arena:* A memory allocator that advances a pointer linearly within pre-allocated memory blocks, with $O(1)$ allocation and bulk deallocation.
- *MacTeX:* The native TeX Live distribution on macOS (`pdflatex`, `xelatex`).

This specification governs the Odin native engine (`odin/rst`), the C-ABI export layer (`odin/lib`), the standalone command-line compiler (`cmd/docodin`), the native verification checker (`cmd/docodin-check`), and the Python compatibility shim (`python/docodin/shim`).

= Mathematical and Algorithmic Foundations

#diagram-card(caption: [Figure 1. The DocOdin Compiler Pipeline: From raw reST text to multi-target outputs through linear-time automata and contiguous arena allocation.])[
  #fletcher.diagram(
    spacing: (1.2cm, 1.0cm), node-stroke: 0.7pt,
    node((0,0), [Source Text\ (`.rst` UTF-8)], name: <src>, fill: rgb("e0f2fe")),
    node((1,0), [Indentation Calculus\ & Line Slicing], name: <indent>, fill: rgb("f1f5f9")),
    node((2,0), [Block State Automaton\ (Transitions & Grids)], name: <blocks>, fill: rgb("fef3c7")),
    node((3,0), [Linear Bump Arena\ AST (`rst.Node`)], name: <ast>, fill: rgb("dcfce7")),
    node((4,-0.8), [HTML5 Writer\ (`Semantic CSS`)], name: <html5>, fill: rgb("ede9fe")),
    node((4,0), [LaTeX 2e Writer\ (`MacTeX Engine`)], name: <latex>, fill: rgb("ede9fe")),
    node((4,0.8), [CPython Marshal Bridge\ (`docodin.shim`)], name: <python>, fill: rgb("ede9fe")),
    edge(<src>, <indent>, "->"), edge(<indent>, <blocks>, "->"),
    edge(<blocks>, <ast>, "->"), edge(<ast>, <html5>, "->"),
    edge(<ast>, <latex>, "->"), edge(<ast>, <python>, "->"),
  )
]

== Indentation Calculus

reStructuredText is an off-side rule language. Let an input document $D$ be a sequence of lines $L = (l_1, l_2, dots.h, l_n)$. Each line has an indentation depth function $I: L -> NN_0$ defined by:

$ I(l_i) = sum_(j=1)^k "width"(c_j) $

where $c_j$ are leading whitespace characters. Tab stop expansion follows modular arithmetic with tab width $T in NN$ (default $T = 8$):

$ "col"(c, T) = c + (T - (c mod T)) $

The active indentation context is maintained as a strictly monotonic stack:

$ S = [d_0, d_1, dots.h, d_m] quad "where" quad 0 = d_0 < d_1 < dots.h < d_m $

When line $l_(i+1)$ has indentation $I(l_(i+1)) = d'$:
1. If $d' > d_m$: push $d'$ onto $S$ (block open).
2. If $d' = d_m$: current block continuation.
3. If $d' < d_m$: pop elements from $S$ until $d_k = d'$ (block close). If no such $d_k$ exists, emit an inconsistent indentation system message.

Because every line is visited once and each indentation level is pushed and popped at most once, indentation analysis has strictly bounded runtime:

$ T_("indent")(N) = cal(O)(N) $

== Section Hierarchy Lattice

Section headings in reST are demarcated by punctuation adornments (underlines and optional overlines). Let an adornment style be a tuple $A = (c, o)$ where $c in cal(P)_("punct")$ is the character and $o in {1, 2}$ is the adornment count ($1 = "underline only", 2 = "overline and underline"$).

The sequence of observed unique adornments forms an ordered set:

$ cal(L) = (A_1, A_2, dots.h, A_k) $

Let the section depth of $A_i$ be $"depth"(A_i) = i$. The title hierarchy satisfies the invariant:

$ "level"(l_(i+1)) <= "level"(l_i) + 1 $

A transition from level $p$ to $q$ where $q > p + 1$ violates the lattice property and is detected in $cal(O)(1)$ time, triggering a deterministic title inconsistency warning without halting AST construction.

== Planar Grid Table Geometry

A grid table is a discrete 2D matrix $M in Sigma^(R times C)$ bounded by corner intersections (`+`), horizontal segments (`-` or `=`), and vertical dividers (`|`).

Let intersections be coordinate pairs $V = {(r, c) | M[r, c] = '+'}$. A valid table cell is defined by a rectangular bounding box with top-left $(r_1, c_1)$ and bottom-right $(r_2, c_2)$. The column span $gamma$ and row span $rho$ are computed via interval projection across the partition grid:

$ gamma = |{ c_k | c_1 <= c_k < c_2 }|, quad rho = |{ r_k | r_1 <= r_k < r_2 }| $

DocOdin validates table topology in a single pass over the table lines:
$ sum_(i=1)^gamma W_i = c_2 - c_1 - 1 $

= Data-Oriented Memory Model

DocOdin rejects the traditional object-per-node paradigm in favor of contiguous memory arenas.

== Lock-Free Bump Allocator

Every parse transaction operates within a dedicated `Bump_Arena`. The arena consists of a linked chain of contiguous memory blocks:

```odin
Bump_Block :: struct {
    prev: ^Bump_Block,
    size: int,
    used: int,
}

Bump_Arena :: struct {
    block:      ^Bump_Block,
    last_alloc: rawptr,
}
```

Allocation is a simple pointer addition and alignment check:

$ "offset"' = ("used" + "align" - 1) & ~("align" - 1) $
$ "ptr" = "base" + "offset"' $

When a document compilation completes, `bump_reset` resets the arena in $cal(O)(1)$ time by clearing `used = 0` on the retained head block (retaining up to 64 MB). No individual `free()` or garbage collection sweep is ever performed.

== Zero-Copy UTF-8 String Slicing

All node text, element identifiers, directive names, and raw sources are represented as zero-copy Odin string slices:

```odin
string :: struct {
    data: [^]u8,
    len:  int,
}
```

These slices point directly into the read-only memory buffer of the source document. Heap allocation of strings occurs exclusively when text transformations are required (e.g. whitespace unescaping or tab expansion).

= Standalone Toolchain Architecture (Option A)

The `bin/docodin` executable is a standalone, self-contained binary with zero runtime dependencies.

== Semantic HTML5 Writer

The native HTML5 writer (`odin/rst/writer_html.odin`) traverses the AST and produces accessible, clean HTML5:
- Hierarchical `<section>` and `<h1-h6>` elements with deterministic slug generation.
- Responsive, modern embedded CSS styling (`DEFAULT_HTML_CSS`) with zero external font or script requests.
- Full table rendering with `<colgroup>`, `<thead>`, `<tbody>`, `colspan`, and `rowspan`.
- Semantic admonition callout boxes (`note`, `warning`, `tip`, `important`, `danger`).

== LaTeX 2e & MacTeX Pipeline

The native LaTeX writer (`odin/rst/writer_latex.odin`) generates valid, clean LaTeX 2e markup:
- Automatic character escaping for TeX metacharacters (`\`, `%`, `$`, `&`, `#`, `_`, `{`, `}`, `~`, `^`).
- Clean environments: `longtable`, `booktabs`, `amsmath`, `hyperref`, and `geometry`.
- Direct PDF compilation: When invoked with `docodin pdf input.rst -o output.pdf`, DocOdin auto-locates `/Library/TeX/texbin/xelatex` or `pdflatex`, writes an intermediate `.tex` file, and executes a two-pass compilation to resolve cross-references and table of contents automatically.

== Seamless `conf.py` Integration

When compiling in a directory containing a Sphinx `conf.py` file, DocOdin automatically extracts configuration metadata:
- `project = "..."` -> Document title.
- `author = "..."` -> Author metadata.
- `version = "..."` -> Document version.

This enables existing Sphinx documentation repositories to be compiled natively with DocOdin without altering a single file.

= Drop-in Docutils Replacement (Option B)

To function as a drop-in replacement for `docutils` in Python and Sphinx without requiring upstream `docutils` to be installed, DocOdin provides `docodin.shim`:

1. *Pure Native Bridge:* The Odin shared library (`libdocodin.dylib` / `.so`) exports C-ABI functions (`docodin_parse`, `docodin_free`). Results are serialized into CPython `marshal` bytecode directly inside the Odin arena, enabling C-speed deserialization in Python.
2. *Full `docutils` Namespace Emulation:* When `import docutils` is executed, the `docodin.shim` package provides complete implementations of:
   - `docutils.nodes`: All AST element classes, `NodeVisitor`, `walk()`, `findall()`.
   - `docutils.core`: `Publisher`, `publish_string()`, `publish_parts()`, `publish_doctree()`.
   - `docutils.parsers.rst`: `Directive`, `Parser`, `directives`, `roles`.
   - `docutils.statemachine`: `StringList`, `StateMachineWS`.
   - `docutils.transforms` & `docutils.writers`.
3. *Zero Required Dependencies:* `pyproject.toml` declares `dependencies = []`. DocOdin has zero mandatory runtime dependencies.

= Verification and Correctness

DocOdin enforces multi-tier verification:

1. *Unit Test Suite:* Tested via `odin test odin/tests` covering parser state transitions, memory boundaries, and native HTML/LaTeX writers.
2. *Differential Parity Testing:* 913 test cases from Docutils 0.22.4 parser test suite (`tests/conformance/run_docutils_suite.py`) verified to produce byte-for-byte identical pseudo-XML.
3. *Sphinx Extension Parity:* Real Sphinx projects built with `docodin.sphinx` produce identical output to stock Docutils.
4. *Bounded Stack Safety:* Nesting is explicitly capped at `MAX_NESTING = 160`, turning recursive attacks into clean diagnostics rather than stack overflows.

= Conclusion

DocOdin proves that a modern, data-oriented compiler architecture in Odin can replace legacy dynamic language tooling. By combining mathematical automata, contiguous memory arenas, and multi-target code generation, DocOdin delivers native speed, zero dependencies, and complete backward compatibility for the Python documentation ecosystem.
