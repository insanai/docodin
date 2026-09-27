.. _editors:

==============
Editor support
==============

``docodin-lsp`` is a language server for reStructuredText.  Editors start it and talk to
it over standard input and output, using the Language Server Protocol (LSP).  It runs no
Python, parses each change once, and answers in about 6 ms for a 124 KB document.
``scripts/build_odin.sh`` builds it into ``bin/``.

What it provides
================

Diagnostics as you type
   docutils' own messages (text, level and line) from the native parser, directives,
   roles and reference transforms, such as ``Unknown target name: "x".`` or ``Duplicate
   explicit target name``.  Parser messages carry the checker's title as the diagnostic
   code and its hint, and point at the offending inline markup.

Quick fixes
   Where the hint is mechanical: extend a title's underline (and overline) to the
   title's width, insert a missing blank line, escape an unmatched start-string, turn a
   ``::`` without a literal block into ``:``.

Navigation
   Go to definition and find references for hyperlink references (named, anonymous and
   embedded), section titles, substitutions, footnotes and citations, with docutils'
   name normalisation.  Hover shows a target's URI or section, a substitution's
   definition, a footnote's text, and what a directive or role takes.

Structure
   Document symbols (the section tree, with targets, substitution definitions, footnotes
   and citations), folding ranges (sections, directives, lists, literal blocks, tables,
   comments) and semantic tokens (titles and adornments, inline markup, roles, directive
   names, arguments and options, field names, targets, comments).

Completion
   Directive names after ``..``, a directive's options, role names after ``:``, and the
   reference names, substitutions and footnote labels that the document defines.

Settings
========

Settings go in the client's ``initializationOptions``, or in the ``docodin`` section of
its workspace configuration:

.. list-table::
   :header-rows: 1
   :widths: 32 18 50

   * - Setting
     - Default
     - Meaning
   * - ``reportLevel``
     - ``"warning"``
     - the lowest level reported: ``info``, ``warning``, ``error``, ``severe``,
       ``none``, or a number from 0 to 5
   * - ``debounce``
     - ``150``
     - milliseconds between the last edit and new diagnostics
   * - ``sphinx``
     - ``false``
     - Sphinx's standard roles and directives (and domain names such as ``py:func``)
       are known
   * - ``knownRoles``, ``knownDirectives``
     - ``[]``
     - further role and directive names, defined by extensions

docutils reports the roles and directives of Sphinx and its extensions as unknown.
``sphinx`` and the known names silence those messages only; everything else is still
reported.

Neovim
======

Neovim 0.11 or later:

.. code-block:: lua

   vim.lsp.config("docodin", {
     cmd = { "/path/to/docodin/bin/docodin-lsp" },
     filetypes = { "rst" },
     root_markers = { "conf.py", "docutils.conf", ".git" },
     init_options = { reportLevel = "warning", sphinx = true },
   })
   vim.lsp.enable("docodin")

With nvim-lspconfig on older versions:

.. code-block:: lua

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

The emphasis and strong tokens have their own semantic token types; link them to a
highlight group, for example:

.. code-block:: lua

   vim.api.nvim_set_hl(0, "@lsp.type.emphasis.rst", { italic = true })
   vim.api.nvim_set_hl(0, "@lsp.type.strong.rst", { bold = true })

VS Code
=======

Any generic LSP client works.  A minimal extension with ``vscode-languageclient``,
activated ``onLanguage:restructuredtext``:

.. code-block:: ts

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

Zed
===

Zed starts language servers that extensions declare.  A development extension (``zed:
install dev extension``) declares the server in ``extension.toml``:

.. code-block:: toml

   id = "docodin"
   name = "docodin"
   version = "0.1.0"
   schema_version = 1

   [language_servers.docodin-lsp]
   name = "docodin-lsp"
   languages = ["reStructuredText"]

and returns the command from its ``language_server_command``
(``zed::Command { command: "/path/to/docodin/bin/docodin-lsp".into(), args: vec![], env:
vec![] }``).  The server is then configured in ``settings.json``:

.. code-block:: json

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

The reStructuredText language itself (file types, syntax highlighting) comes from a
reStructuredText extension such as zed-rst.

Other editors
=============

Any editor with an LSP client can run ``docodin-lsp``: start ``/path/to/docodin/bin/docodin-lsp``
(``--stdio`` is the default and may be given), for files of the reStructuredText
language, with the settings above as initialisation options.

Limits
======

- The server works on one file at a time: cross-document ``:ref:`` and ``:doc:`` are not
  resolved.
- Included files are read from disk, not from unsaved editor buffers.
- Unknown languages of ``code`` directives are not reported: docutils asks Pygments,
  which the native pipeline does not have.

:doc:`../internals/language-server` explains how the server works.
