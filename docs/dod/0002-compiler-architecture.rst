==============================================================================
DOD 2: The docodin Compiler Architecture
==============================================================================

:Authors: Vikrant Rathore
:State: committed
:Created: 2026-09-27
:Updated: 2026-10-11
:Discussion:
:Labels: parser, native, shim, compatibility

.. contents:: Contents
   :local:
   :depth: 1

Summary
=======

docodin treats reStructuredText as a formal language and compiles it with a native engine
written in Odin, following data-oriented principles.  The engine serves two purposes:

- **A standalone toolchain** (called Option A in the original specification): native
  commands that turn reStructuredText into HTML5, LaTeX and PDF without Python.
- **A drop-in replacement for docutils** (Option B): a ``docutils`` package for Python
  whose reStructuredText parser is the native engine, so that Sphinx and every other
  docutils user run on docodin unchanged.

This record is the first design of docodin.  It was written as the Typst specification
"SDS 0001: DocOdin Compiler Architecture and Specifications" and is kept here in full,
converted to reStructuredText.  The *Outcome* section says how the implementation
differs from this first design; later records (DOD 3 to DOD 10) describe the designs that
replaced parts of it.

Background
==========

For more than twenty years docutils has been the reference implementation, and in
practice the specification, of reStructuredText.  It is robust and extensible, but its
architecture has costs that matter for large documentation projects:

1. **Algorithmic cost.**  The parser in ``docutils/parsers/rst/states.py`` runs hundreds
   of dynamically compiled, backtracking regular expressions inside nested state
   machines.  Recognising blocks and inline markup is most of the time of a document's
   compilation.
2. **Allocation cost.**  Every syntax element, line slice and intermediate token is a
   separate Python heap object.  A document of ten thousand lines creates hundreds of
   thousands of objects, which the garbage collector has to track, and which scatter the
   working set across memory.
3. **Toolchain weight.**  A Python documentation pipeline needs a virtual environment, a
   matching interpreter and a set of wheels.  That is heavy for small CI jobs and for
   embedded use.
4. **No native compilation.**  Turning a manual into a PDF means assembling Python,
   docutils, Sphinx and a TeX distribution, rather than calling one fast binary.

Terminology and scope
=====================

reST
   reStructuredText, an indentation-sensitive markup language.
AST
   The abstract syntax tree, stored as contiguous nodes in linear memory.
Data-oriented design
   Structuring code around the layout of data: cache locality, linear memory, few
   pointers to chase.
DFA
   A deterministic finite automaton.
Bump arena
   An allocator that advances a pointer through preallocated blocks: constant-time
   allocation, and everything is released at once.
TeX engine
   ``pdflatex``, ``xelatex`` or ``lualatex`` from a TeX distribution (MacTeX on macOS, TeX
   Live elsewhere).

The design covers the native engine (``odin/rst``), the C ABI layer (``odin/lib``), the
standalone command (``cmd/docodin``), the native checker (``cmd/docodin-check``) and the
Python compatibility layer (``python/docodin/shim``).

Proposal
========

The pipeline
------------

.. graphviz::
   :class: adaptive-diagram
   :align: center
   :caption: One parser feeds two toolchains; the Sphinx path still builds and processes Python nodes.
   :alt: The Odin parser feeds the native reader, transforms and writers, or a marshal bridge into Python nodes and Sphinx.

   digraph architecture {
   newrank=true;
   graph [bgcolor="white", pad="0.28", nodesep="0.4", ranksep="0.6", fontname="Helvetica", fontsize=17, fontcolor="#425574", color="#CBD5E1"];
   node [shape=box, style="rounded,filled", fontname="Helvetica", fontsize=16, margin="0.22,0.16", fillcolor="#EFF4FF", color="#B3C6F7", fontcolor="#18243D", penwidth=1.2];
   edge [fontname="Helvetica", fontsize=12, color="#526B97", fontcolor="#425574", arrowsize=0.75, penwidth=1.4];
   rankdir=TB;
   source [label="reStructuredText source", fillcolor="#F4F6FA", color="#CDD5E2"];
   parser [label="Odin parser\nodin/rst\nFlat parse tree + messages", fillcolor="#DBE7FF", color="#7DA1ED"];
   source -> parser;
   subgraph cluster_native {
     label="NATIVE TOOLCHAIN"; style="rounded"; bgcolor="#F7FAFF";
     reader [label="Native reader\ndoctree + registry" ];
     transform [label="Native transforms\nReferences, contents, validation"];
     writer [label="Native writers\nHTML, LaTeX, XML"];
     native_out [label="Native output\nHTML / PDF / XML", fillcolor="#E5F5EE", color="#8DC9B0"];
     reader -> transform -> writer -> native_out;
   }
   subgraph cluster_python {
     label="PYTHON / SPHINX"; style="rounded"; bgcolor="#FAF8FF";
     wire [label="C ABI / marshal\nNative result buffer", fillcolor="#EEE9FB", color="#C0AEE7"];
     builder [label="Python builder\nOrdinary docutils nodes", fillcolor="#EEE9FB", color="#C0AEE7"];
     sphinx [label="Python transforms + writers\nSphinx and extensions", fillcolor="#EEE9FB", color="#C0AEE7"];
     python_out [label="Sphinx outputs\nWithin measured support", fillcolor="#E5F5EE", color="#8DC9B0"];
     wire -> builder -> sphinx -> python_out;
   }
   parser -> reader [label="Odin API"];
   parser -> wire [label="C ABI"];
   {rank=same; reader; wire;}
   {rank=same; transform; builder;}
   {rank=same; writer; sphinx;}
   {rank=same; native_out; python_out;}
   }


Indentation calculus
--------------------

reStructuredText is an off-side rule language.  Let a document :math:`D` be a sequence of
lines :math:`L = (l_1, l_2, \ldots, l_n)`.  The indentation of a line is the width of its
leading white space :math:`c_1 \ldots c_k`:

.. math::

   I(l_i) = \sum_{j=1}^{k} \mathrm{width}(c_j)

Tabs advance to the next tab stop of width :math:`T` (8 by default).  A tab at column
:math:`c` moves to

.. math::

   \mathrm{col}(c, T) = c + (T - (c \bmod T))

The open indentation levels form a strictly increasing stack

.. math::

   S = [d_0, d_1, \ldots, d_m], \qquad 0 = d_0 < d_1 < \ldots < d_m

When the next line :math:`l_{i+1}` has indentation :math:`d'`:

1. if :math:`d' > d_m`, push :math:`d'` (a block opens);
2. if :math:`d' = d_m`, the current block continues;
3. if :math:`d' < d_m`, pop until :math:`d_k = d'` (blocks close).  If no level equals
   :math:`d'`, the indentation is inconsistent and a system message is reported.

Every line is visited once, and every level is pushed and popped at most once, so the
analysis is linear:

.. math::

   T_{\mathrm{indent}}(N) = O(N)

Section hierarchy lattice
-------------------------

Section titles are marked by punctuation adornments: an underline, and optionally an
overline.  An adornment style is a pair :math:`A = (c, o)`, where :math:`c` is the
punctuation character and :math:`o \in \{1, 2\}` counts the adornment lines (1: underline
only, 2: overline and underline).  The distinct styles, in the order they first appear,
form the ordered set

.. math::

   \mathcal{L} = (A_1, A_2, \ldots, A_k)

and the depth of style :math:`A_i` is :math:`i`.  Titles must satisfy

.. math::

   \mathrm{level}(t_{i+1}) \le \mathrm{level}(t_i) + 1

A jump from level :math:`p` to level :math:`q > p + 1` breaks the lattice.  It is detected
in constant time and reported as an inconsistent title level, without stopping the
construction of the tree.

Grid table geometry
-------------------

A grid table is a character matrix :math:`M` of :math:`R` rows and :math:`C` columns,
bounded by corners (``+``), horizontal borders (``-`` or ``=``) and vertical borders
(``|``).  The corners are the coordinates

.. math::

   V = \{ (r, c) \mid M[r, c] = \mathrm{+} \}

A cell is a rectangle with top-left corner :math:`(r_1, c_1)` and bottom-right corner
:math:`(r_2, c_2)`.  Its column span :math:`\gamma` and row span :math:`\rho` count the
grid lines it crosses:

.. math::

   \gamma = \left| \{ c_k \mid c_1 \le c_k < c_2 \} \right|, \qquad
   \rho = \left| \{ r_k \mid r_1 \le r_k < r_2 \} \right|

and the widths of the columns it spans add up to its inner width:

.. math::

   \sum_{i=1}^{\gamma} W_i = c_2 - c_1 - 1

The table's topology is validated in one pass over its lines.

Memory model
------------

docodin does not allocate an object per node.  Each parse works in its own bump arena, a
chain of contiguous blocks:

.. code-block:: text

   Bump_Block :: struct {
       prev: ^Bump_Block,
       size: int,
       used: int,
   }

   Bump_Arena :: struct {
       block:      ^Bump_Block,
       last_alloc: rawptr,
   }

Allocation rounds the used size up to the alignment and adds:

.. math::

   \mathrm{offset}' = (\mathrm{used} + \mathrm{align} - 1) \;\&\; \lnot(\mathrm{align} - 1),
   \qquad \mathrm{ptr} = \mathrm{base} + \mathrm{offset}'

When a document is done, ``bump_reset`` resets the arena in constant time.  Nothing is
freed object by object, and there is no garbage collection.

Text is not copied.  Node text, identifiers, directive names and raw sources are Odin
strings, that is views (pointer and length) into the source buffer.  New strings are
allocated only where the text changes, for example when escapes are removed or tabs are
expanded.

Option A: the standalone toolchain
----------------------------------

``bin/docodin`` is a self-contained binary without runtime dependencies.

- **HTML5.**  Sections become ``<section>`` elements with headings and deterministic
  identifiers; tables get ``<colgroup>``, ``<thead>``, ``<tbody>``, ``colspan`` and
  ``rowspan``; admonitions become styled boxes; the stylesheet is embedded, and the
  page loads no external fonts or scripts.
- **LaTeX and PDF.**  The LaTeX writer escapes TeX's special characters and uses
  ``longtable``, ``booktabs``, ``amsmath``, ``hyperref`` and ``geometry``.
  ``docodin pdf`` writes the ``.tex`` file, finds a TeX engine and runs it twice, so that
  cross-references and the table of contents resolve.
- **Sphinx projects.**  In a directory with a Sphinx ``conf.py``, the project's
  ``project``, ``author`` and ``version`` become the document's metadata, so existing
  Sphinx projects can be compiled without changes.

Option B: the drop-in docutils replacement
------------------------------------------

To replace docutils in Python and Sphinx, even where docutils is not installed, docodin
provides ``docodin.shim``:

1. **Native bridge.**  The Odin library (``libdocodin.dylib``, ``libdocodin.so``)
   exports C functions (``docodin_parse``, ``docodin_free``).  Results are serialised in
   CPython's ``marshal`` format inside the Odin arena, so Python decodes them in C.
2. **The docutils namespace.**  ``import docutils`` finds complete implementations of
   ``docutils.nodes`` (the node classes, ``NodeVisitor``, ``walk``, ``findall``),
   ``docutils.core`` (``Publisher``, ``publish_string``, ``publish_parts``,
   ``publish_doctree``), ``docutils.parsers.rst`` (``Directive``, ``Parser``, the
   directive and role registries), ``docutils.statemachine`` (``StringList``,
   ``StateMachineWS``), ``docutils.transforms`` and ``docutils.writers``.
3. **No dependencies.**  ``pyproject.toml`` declares ``dependencies = []``.

Alternatives
============

- **Speed up docutils in place** (profiling and caching its regular expressions).  The
  object-per-node model and the regex state machines would remain, and so would most of
  the cost.
- **A parser generator or a tree-sitter grammar.**  reStructuredText is not
  context-free: the meaning of an indented block depends on the line before it, section
  levels depend on the order of title styles, and enumerated lists depend on ordinals.
  A generated parser cannot reproduce docutils' behaviour exactly (DOD 12 has the
  details).
- **Vendoring docutils** for Option B.  Rejected in favour of an implementation written
  for docodin (DOD 6).

Compatibility and fidelity
==========================

Both options promise docutils' behaviour.  The original specification stated this as
"byte-for-byte fidelity with the reStructuredText specification"; in practice the
specification is docutils 0.22.4 itself, and DOD 3 makes the rule precise.

Verification
============

The specification required four tiers of verification:

1. **Unit tests** with ``odin test odin/tests``: parser state transitions, memory limits,
   the native writers.
2. **Differential parity**: the parser test cases of docutils 0.22.4
   (``tests/conformance/run_docutils_suite.py``) produce identical pseudo-XML.
3. **Sphinx parity**: real Sphinx projects built with ``docodin.sphinx`` give the same
   output as with docutils.
4. **Bounded nesting**: ``MAX_NESTING = 160`` turns deeply nested input into a clean
   error message instead of a stack overflow.

Outcome
=======

The architecture was implemented, and it is still the shape of docodin: a native parser
with a data-oriented tree, a marshal bridge into a docutils package written for docodin,
native tools, and bounded recursion.  Several parts changed as the work went on:

- **Exact writers instead of approximate ones.**  The first native HTML5 and LaTeX
  writers (``odin/rst/writer_html.odin``, ``writer_latex.odin``) produced their own,
  cleaner markup.  That broke the promise of docutils' output, so they were removed
  (commit "Remove the approximate native writers") and replaced by ports of docutils'
  reader, transforms and writers with identical output (DOD 8).  The native pipeline
  publishes exactly what ``python -m docutils`` publishes.
- **Handles instead of pointers.**  The first parse tree linked nodes with pointers.  It
  became a struct-of-arrays tree addressed by 32-bit handles (DOD 4).
- **The bump arena** kept its shape (``odin/lib/bump.odin``), but its blocks are now
  mapped from the operating system, and ``bump_reset`` keeps at most one block of 4 MB
  between calls instead of up to 64 MB (DOD 15).
- **The shim** became a complete docutils package with every writer, served through an
  import hook (DOD 6), with a pure-Python parser for extensions that change the grammar
  (DOD 7).
- **Sphinx metadata** discovery exists in ``python/docodin/conf.py``.  The native
  ``docodin`` command itself reads no configuration files, like ``python -m docutils``
  with ``--config`` unset; the multi-document ``docodin book`` builder reads a project's
  ``conf.py`` (DOD 18).
- **The speed-up.**  The specification expected five to fifty times more throughput.
  Measured on real projects (docodin 0.2.0): the native parser is about five times
  faster than docutils' parser; a Sphinx build of CPython's documentation is 1.38 times
  faster as a whole, because Sphinx's own work does not change; publishing the docutils
  documentation natively is eleven times faster in process, and checking it is about
  ninety times faster.  The book's performance chapter has the figures.
- **PDF engines.**  ``docodin pdf`` uses ``pdflatex`` when it is installed and
  ``xelatex`` otherwise; ``--engine`` also accepts ``lualatex``.

References
==========

- The original Typst specification, ``docs/sds/records/0001-docodin-compiler-architecture.typ``
  (removed after this conversion; in the history before docodin 0.2.0's documentation
  change).
- DOD 3 to DOD 10, which refine this design.
