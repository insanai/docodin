.. _language-server:

=====================
The language server
=====================

``docodin-lsp`` (``odin/lsp``, ``cmd/docodin-lsp``) serves the Language Server Protocol
over standard input and output, as ruff's server does.  :doc:`../guide/editors` shows how
to use it; this chapter shows how it works (DOD 14).

The loop
========

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
