==============================================================================
DOD 14: A Native Language Server, docodin-lsp
==============================================================================

:Authors: Vikrant Rathore
:State: committed
:Created: 2026-09-27
:Updated: 2026-10-11
:Discussion:
:Labels: editor, tooling

.. contents:: Contents
   :local:
   :depth: 1

Summary
=======

``docodin-lsp`` is a language server for reStructuredText, written in Odin, that runs
no Python.  Editors start it and speak the Language Server Protocol with it over standard
input and output.  It reports docutils' own messages as you type, with the checker's
Elm-style titles and hints and quick fixes, and it gives editors docutils' exact document
structure: symbols, folding, semantic tokens, go to definition, references, hover and
completion.  It parses each change once, in about 6 ms for a 124 KB document.

Background
==========

DOD 12 surveyed reStructuredText editor tooling: approximate tree-sitter grammars for
colour, and esbonio for features, whose diagnostics come from a Sphinx build in a Python
subprocess.  Nothing gave diagnostics from the exact grammar as you type, semantic tokens,
folding or references.  docodin had the grammar, the messages and the hints (DOD 5), and
0.2.0 added positions (DOD 13).

Proposal
========

.. graphviz::
   :class: adaptive-diagram
   :align: center
   :caption: Top to bottom: a document change builds a versioned snapshot used by diagnostics and requests.
   :alt: Editor sends didChange; server runs native analysis and receives a tree, symbols and messages; diagnostics and later hover replies use the current snapshot.

   digraph lsp_sequence {
   graph [bgcolor="white", pad="0.28", nodesep="0.4", ranksep="0.6", fontname="Helvetica", fontsize=17, fontcolor="#425574", color="#CBD5E1"];
   node [shape=box, style="rounded,filled", fontname="Helvetica", fontsize=16, margin="0.22,0.16", fillcolor="#EFF4FF", color="#B3C6F7", fontcolor="#18243D", penwidth=1.2];
   edge [fontname="Helvetica", fontsize=12, color="#526B97", fontcolor="#425574", arrowsize=0.75, penwidth=1.4];
   rankdir=TB;
   node [fontsize=15];
   editor [label="EDITOR", fillcolor="#DBE7FF", color="#7DA1ED", group="editor"];
   server [label="LSP SERVER", fillcolor="#EEE9FB", color="#C0AEE7", group="server"];
   engine [label="NATIVE ANALYSIS", fillcolor="#E5F5EE", color="#8DC9B0", group="engine"];
   {rank=same; editor; server; engine;}
   node [shape=point, width=0.04, height=0.04, label="", color="#9CACCA", fillcolor="#9CACCA"];
   e1 [group="editor"]; e2 [group="editor"]; e3 [group="editor"]; e4 [group="editor"]; e5 [group="editor"]; e6 [group="editor"];
   s1 [group="server"]; s2 [group="server"]; s3 [group="server"]; s4 [group="server"]; s5 [group="server"]; s6 [group="server"];
   p1 [group="engine"]; p2 [group="engine"]; p3 [group="engine"]; p4 [group="engine"]; p5 [group="engine"]; p6 [group="engine"];
   edge [arrowhead=none, style=dashed, color="#CBD5E1"];
   editor -> e1 -> e2 -> e3 -> e4 -> e5 -> e6;
   server -> s1 -> s2 -> s3 -> s4 -> s5 -> s6;
   engine -> p1 -> p2 -> p3 -> p4 -> p5 -> p6;
   {rank=same; e1; s1; p1;}
   {rank=same; e2; s2; p2;}
   {rank=same; e3; s3; p3;}
   {rank=same; e4; s4; p4;}
   {rank=same; e5; s5; p5;}
   {rank=same; e6; s6; p6;}
   edge [arrowhead=normal, style=solid, color="#526B97", fontsize=14];
   e1 -> s1 [label="1  didChange: text + version", constraint=false];
   s2 -> p2 [label="2  read_document + spans", constraint=false];
   p3 -> s3 [label="3  Tree, symbols, messages", style=dashed, constraint=false];
   s4 -> e4 [label="4  Diagnostics after debounce", constraint=false];
   e5 -> s5 [label="5  Hover / definition request", constraint=false];
   s6 -> e6 [label="6  Reply from current snapshot", style=dashed, constraint=false];
   }


The loop
--------

The server works like ruff's: a reader thread reads the ``Content-Length`` frames and
records ``$/cancelRequest`` at once.  The main thread owns the state and handles the
messages in order, each in a scratch arena that is reset afterwards.  Diagnostics are
pushed ``debounce`` milliseconds after the last change, or pulled with
``textDocument/diagnostic`` when the client supports it.

Documents
---------

The text is kept on the heap and edited in place (full and incremental changes, UTF-16
or UTF-8 positions).  Each version gets a snapshot in its own arena, built on first use:
the whole file is parsed again.  Positions are byte offsets into the text, converted to
and from LSP positions by ``rst.Line_Index``.

Analysis
--------

``publish.read_document`` runs the native reader and the standard transforms as
``publish`` does, without a writer (``report_level`` 1, ``halt_level`` 5), keeps the
reader's parse tree with spans, and returns the messages as records, so their texts,
levels and lines are docutils'.  One walk of the parse tree fills flat tables: items
(definitions and uses of names), semantic tokens, folding ranges and inline markup
problems.  The reStructuredText content of standard directives is parsed as the
directives parse it.  Names are matched with ``fully_normalize_name``; anonymous
references and auto-numbered and auto-symbol footnotes are matched in order.  A document
whose ``include`` inserted lines is parsed again for the analysis.

Features
--------

- **Diagnostics**: docutils' messages from the parser, directives, roles and reference
  transforms (for example ``Unknown target name: "x".``).  The checker gives the title
  (the diagnostic's ``code``) and the hint; inline markup errors point at the offending
  markup; docutils' level and line travel in ``data``.
- **Quick fixes** where the hint is mechanical: extend a title's underline (and overline),
  insert a missing blank line, escape an unmatched start-string, turn a ``::`` without a
  literal block into ``:``.
- **Navigation**: definition and references for hyperlink references (named, anonymous
  and embedded), section titles, substitutions, footnotes and citations.  Hover shows a
  target's URI or section, a substitution's definition, a footnote's text, and what a
  directive or role takes.
- **Structure**: document symbols (the section tree with targets, substitution
  definitions, footnotes and citations), folding ranges, semantic tokens.
- **Completion**: directive names, a directive's options, role names, and the document's
  reference names, substitutions and footnote labels.

Settings
--------

In ``initializationOptions``, or the ``docodin`` section of the workspace configuration:
``reportLevel`` (``info``, ``warning``, ``error``, ``severe``, ``none``, or 0 to 5;
default ``warning``), ``debounce`` (default 150 ms), ``sphinx`` (Sphinx's standard roles
and directives are known), ``knownRoles`` and ``knownDirectives``.  docutils reports the
roles and directives of Sphinx and its extensions as unknown; these settings silence only
those messages.

Alternatives
============

- **A worker pool over snapshots** (ruff).  Unnecessary at the measured latency; one
  thread keeps the server simple.
- **Incremental parsing.**  Not needed at this size (DOD 12); recorded as DOD 17.
- **Diagnostics from a Sphinx build** (esbonio).  Slow, needs Python, and reports only
  after a build.

Compatibility and fidelity
==========================

The server only reads.  Its diagnostics are docutils' messages; ``tests/test_lsp.py``
compares them with docutils.

Verification
============

- ``odin test odin/lsp/tests``: the protocol and each feature.
- ``tests/test_lsp.py`` drives the binary: diagnostics compared with docutils' messages on
  fixed cases and generated documents, code actions (an underline fix clears the
  warning), definition, references, hover, symbols, folding, semantic tokens, completion
  and UTF-16 positions.

Outcome
=======

Released in docodin 0.2.0.  Not built from DOD 12's plan: rename, and the cross-file index
for ``:ref:`` and ``:doc:`` with a Sphinx manifest.  Known limits: one file at a time;
includes are read from disk; unknown languages of ``code`` directives are not reported
(docutils asks Pygments, which the native pipeline does not have).

References
==========

- ``odin/lsp``, ``cmd/docodin-lsp``, ``odin/publish/read.odin``.
- The book's chapter on editor support.
