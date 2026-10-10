.. _language-server:

=====================
The language server
=====================

``docodin-lsp`` (``odin/lsp``, ``cmd/docodin-lsp``) serves the Language Server Protocol
over standard input and output, as ruff's server does.  :doc:`../guide/editors` shows how
to use it; this chapter shows how it works (DOD 14).

The loop
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


A reader thread reads the ``Content-Length`` frames and records ``$/cancelRequest`` at
once.  The main thread owns the state and handles the messages in order, each in a
scratch arena that is reset afterwards.  Diagnostics are pushed ``debounce`` milliseconds
after the last change, or pulled with ``textDocument/diagnostic`` when the client
supports it.

The server answers ``initialize``, ``shutdown`` and ``exit``, the document notifications
(``didOpen``, ``didChange``, ``didSave``, ``didClose``), and the requests
``textDocument/diagnostic``, ``codeAction``, ``completion``, ``definition``,
``references``, ``hover``, ``documentSymbol``, ``foldingRange`` and ``semanticTokens``.

Documents
=========

The text of each open document is kept on the heap and edited in place, for full and
incremental changes, with UTF-16 or UTF-8 positions.  Each version gets a snapshot in its
own arena, built on first use: the whole file is parsed again (1 to 2 ms for large
documents; DOD 12 explains why incremental parsing is not needed).  Positions inside the
server are byte offsets into the text; ``rst.Line_Index`` converts them to and from LSP
positions (:doc:`spans`).

Analysis
========

``publish.read_document`` runs the native reader and the standard transforms as
``publish`` does, without a writer (``report_level`` 1, ``halt_level`` 5).  The reader
keeps its parse tree, with spans, so each change is parsed once.  One walk of that parse
tree fills flat tables:

- **items**: the definitions and uses of names (targets, section titles, substitutions,
  footnotes, citations, anonymous references);
- **semantic tokens**;
- **folding ranges**;
- **inline markup problems**, with their columns.

The reStructuredText content of standard directives is parsed as the directives parse
it.  Names are matched with ``fully_normalize_name``; anonymous references, auto-numbered
and auto-symbol footnotes are matched in order.  Positions are the nodes' source spans,
and lines come from the tree's line table.  A document whose ``include`` inserted lines
is parsed again for the analysis, because the kept tree then does not match the source.

Diagnostics
===========

``read_document`` returns the messages as records, so the texts, levels and lines are
docutils'.  The parse tree's problematic nodes give the column of inline markup errors.
The checker gives the Elm title (the diagnostic's ``code``) and the hint; mechanical hints
come with a quick fix.  docutils' level and line travel in the diagnostic's ``data``.

Messages about roles and directives that the configuration declares known (``sphinx``,
``knownRoles``, ``knownDirectives``), "Unknown interpreted text role", "Unknown directive
type" and the lookup messages before them, are not reported.

Verification
============

- ``odin test odin/lsp/tests``: the protocol and each feature.
- ``tests/test_lsp.py`` drives the binary and compares its diagnostics with docutils'
  messages on fixed cases and generated documents; it checks code actions (an underline
  fix clears the warning), definition, references, hover, symbols, folding, semantic
  tokens, completion and UTF-16 positions.
