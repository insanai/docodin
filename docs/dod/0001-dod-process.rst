==============================================================================
DOD 1: DocOdin Discussions
==============================================================================

:Authors: Vikrant Rathore
:State: committed
:Created: 2026-09-27
:Discussion:
:Labels: process, documentation

.. contents:: Contents
   :local:
   :depth: 1

Summary
=======

A DocOdin Discussion (DOD) is a short, numbered design record written in
reStructuredText and kept in the repository under ``docs/dod``.  Every decision that
shapes docodin, such as a new native stage, a change to how the shim is activated or a
new command, gets a DOD.  The record states the problem, the proposal, the alternatives,
what it means for docutils fidelity and how it is verified, and it keeps its state as it
moves from idea to implemented design.  This record defines the process: states, labels,
numbering, the file format, the ``docodin dod`` commands, review, and how the records
relate to the book and the changelog.

.. note::

   In this repository "DOD" always means a DocOdin Discussion.  docodin's native code
   also follows data-oriented design; the documentation writes that out in full and never
   abbreviates it, so the two cannot be confused.

Background
==========

docodin grew quickly.  Its first design was written as a Typst specification (SDS 0001),
the native pipeline and the 0.2.0 research as Markdown memos, and many smaller decisions
lived only in commit messages.  That had three costs:

- The reasons behind a design were scattered.  Someone reading ``odin/rst`` could not tell
  why the parse tree stores handles instead of pointers without finding the right commit.
- The documents used three formats, none of them reStructuredText, in a project whose
  whole purpose is reStructuredText.  They could not be checked with ``docodin-check``,
  built with Sphinx, or built by docodin itself.
- Proposals and implemented designs looked the same.  The early specification described
  native writers that were later replaced, but nothing said so.

A numbered record with an explicit state solves all three.  The format is plain
reStructuredText, so the records are built by the same tools they describe.

When to write a DOD
===================

Write a DOD when a change is hard to undo, visible to users, or needs a reason that the
code cannot hold.  For example:

- a new native stage, package or command, or a change to one (a new writer, ``docodin-lsp``);
- anything that can change the docutils path: the wire format between Odin and Python,
  the shim's activation, the fallback rules;
- a trade-off with measured costs, such as the garbage-collector tuning, the memory
  work or the SIMD scanner;
- packaging, release and platform decisions;
- changes to the project's rules and processes, including this one.

Bug fixes, refactorings that keep behaviour and interfaces, test additions and
documentation fixes do not need a DOD.  When in doubt, write a short one: a DOD may be a
few paragraphs.

States
======

Every DOD is in exactly one state, recorded in its ``:State:`` field.

``prediscussion``
   The author is still writing.  The record may be incomplete and is not ready for
   review.  Work happens on a branch.

``ideation``
   A placeholder that names a topic and its scope, so the idea and its number are not
   lost.  Nobody is working on it; anyone may pick it up and move it to
   ``prediscussion``.

``discussion``
   Ready for review.  The record is open in a pull request, and ``:Discussion:`` links to
   it.

``published``
   The discussion has converged and the record is merged.  It is the agreed design, but
   it is not (fully) implemented yet.

``committed``
   The design is implemented and released or merged.  The record now describes how
   docodin works and why.

``abandoned``
   The idea was rejected, overtaken or dropped.  The record stays, with the reason, so
   the same idea is not proposed again without new arguments.

The transitions:

.. code-block:: text

      (new idea)                         (topic, no author yet)
          |                                      |
          | create                               | placeholder
          v                                      v
    prediscussion  <------- start work ------- ideation
          |                                      |
          | ready for review                     | drop
          v                                      |
      discussion  -------- reject ----------+    |
          |                                 |    |
          | converge                        v    v
          v                                abandoned
      published  --------- obsolete ---------->^
          |
          | implement
          v
      committed

.. list-table::
   :header-rows: 1
   :widths: 20 20 60

   * - From
     - To
     - When
   * - (new)
     - ``prediscussion``
     - An author starts writing (``docodin dod new``).
   * - (new)
     - ``ideation``
     - Someone records a topic that nobody works on yet.
   * - ``ideation``
     - ``prediscussion``
     - An author picks the topic up.
   * - ``prediscussion``
     - ``discussion``
     - The record is complete and a pull request is open.
   * - ``discussion``
     - ``published``
     - The reviewers agree and the record is merged.
   * - ``published``
     - ``committed``
     - The design is implemented and merged.
   * - ``ideation``, ``discussion``, ``published``
     - ``abandoned``
     - The idea is dropped, rejected or overtaken; the record says why.

A ``committed`` record is not edited to describe a different design: a new DOD
supersedes it (see `Changing a record`_).

Labels
======

``:Labels:`` holds one or more of these labels, separated by commas.  ``docodin dod check``
rejects any other label, so that the labels stay useful for filtering.

.. list-table::
   :header-rows: 1
   :widths: 22 78

   * - Label
     - Use it for
   * - ``parser``
     - the native reStructuredText parser (``odin/rst``) and the parse tree
   * - ``shim``
     - the docutils implementation in ``python/docodin/shim`` and its import hook
   * - ``native``
     - the native pipeline: reader, transforms, writers, publisher, math, smart quotes
   * - ``performance``
     - speed and memory
   * - ``tooling``
     - the commands: ``docodin``, ``docodin-check``, ``docodin book``, ``docodin dod``
   * - ``editor``
     - ``docodin-lsp`` and editor integration
   * - ``documentation``
     - the book, the DODs and the documentation system
   * - ``process``
     - how the project works: rules, reviews, this process
   * - ``release``
     - packaging, versions, wheels, platforms
   * - ``compatibility``
     - fidelity to docutils and Sphinx, and the behaviour users rely on

Numbering and files
===================

- A DOD has a number that never changes and is never reused, even if the record is
  abandoned.  Numbers are written without leading zeros in text ("DOD 7") and with four
  digits in file names.
- The file is ``docs/dod/NNNN-slug.rst``, where the slug is the title in lower case with
  words joined by hyphens, for example ``0016-garbage-collector-tuning.rst``.
- The next number is one more than the highest number in ``docs/dod``.  Because two
  people can reserve a number at the same time on different branches, ``docodin dod new``
  also looks at the remote branches named ``dod/NNNN`` when git is available, and uses the
  next free number.  Push the branch early to reserve the number.
- ``0000-template.rst`` is the template.  It is excluded from the builds.

Format
======

A DOD is a reStructuredText document.  It uses only the markup that both Sphinx and
docodin's native book builder understand (the book's chapter on maintaining the
documentation lists it).  The title and the field list come first, exactly like this:

.. code-block:: rst

   ==============================================================================
   DOD 7: Title Words
   ==============================================================================

   :Authors: Name <email>
   :State: discussion
   :Created: 2026-09-27
   :Updated: 2026-10-02
   :Discussion: https://example.org/pull/42
   :Labels: parser, performance
   :Supersedes: DOD 3

The fields:

``Authors``
   One or more ``Name <email>`` entries, separated by commas.
``State``
   One of the six states.
``Created``, ``Updated``
   ISO dates.  ``Updated`` is optional; set it when a published or committed record gets a
   substantive change.
``Discussion``
   The link to the pull request or thread, or empty.
``Labels``
   Labels from the table above.
``Supersedes``, ``Superseded-By``
   Optional.  They link two records that replace each other; set both.

The body uses these sections, in this order: Summary, Background, Proposal (or
Discussion), Alternatives, Compatibility and fidelity, Verification, Decision (or
Outcome), References.  A short record may merge or leave out sections, but
*Compatibility and fidelity* is required for every record that touches the docutils
path: docodin's first promise is that it behaves exactly like docutils 0.22.4, and every
design must say why it keeps that promise.

Workflow
========

The ``docodin dod`` command does the bookkeeping.  It is part of the native ``docodin``
command and needs no Python.

1. **Create the record.**

   .. code-block:: console

      $ git switch -c dod/0019
      $ docodin dod new "Incremental checking in the language server" --labels editor,performance

   ``docodin dod new`` picks the next number (or the one given with ``--number``), writes
   ``docs/dod/0019-incremental-checking-in-the-language-server.rst`` from the template
   with your name and e-mail from ``git config`` and today's date, and prints the next
   steps.  ``--dir`` names another directory than ``docs/dod``.

2. **Write it** in ``prediscussion``.  Check the markup as you go:

   .. code-block:: console

      $ docodin-check docs/dod/0019-*.rst
      $ docodin dod check

   ``docodin dod check`` validates every record: the title line, the required fields,
   the state and label names, dates, and that numbers are unique and match the file
   names.

3. **Open it for review.**  Set the state to ``discussion``, open a pull request, and put
   its link in ``:Discussion:``.

4. **Converge and merge.**  When the reviewers agree, fill in *Decision*, set the state
   to ``published`` (or ``abandoned``), regenerate the index and merge:

   .. code-block:: console

      $ docodin dod index
      $ docodin dod list --state published

   ``docodin dod index`` rewrites the "By state" section of ``docs/dod/index.rst``
   between the comments ``.. dod-index-start`` and ``.. dod-index-end``; the rest of the
   file is left alone.  ``docodin dod list`` prints a table of the records and can
   filter them with ``--state`` and ``--label``.

5. **Implement it.**  The implementation commits refer to the record ("as in DOD 19")
   when that helps a reader.  When the work lands, set the state to ``committed``, write
   the *Outcome*, update the book and the changelog, and run ``docodin dod index`` again.

Review
======

Anyone may review a DOD.  A review looks at:

- **Fidelity.**  Does anything reach the docutils path?  If so, which differential test
  proves it identical?  "It should not change anything" is not an answer; name the test.
- **Measurements.**  Performance claims come with the machine, the corpus, the command
  and the numbers, before and after.
- **Scope.**  Is the record about one decision?  Split it otherwise.
- **Honesty of the state.**  A record is ``committed`` only when the code is merged, and
  its *Outcome* says what was left out.

The author resolves every comment, in the record or in the thread, before the state
moves to ``published``.

Changing a record
=================

- A ``prediscussion``, ``ideation`` or ``discussion`` record changes freely.
- A ``published`` or ``committed`` record gets corrections (typos, broken links, wrong
  numbers) directly; set ``:Updated:``.
- A different design never overwrites a ``published`` or ``committed`` record.  Write a
  new DOD that supersedes it, set ``:Supersedes:`` in the new record and
  ``:Superseded-By:`` in the old one, and leave the old text as it was.

DODs, the book and the changelog
================================

The three kinds of documentation answer different questions:

.. list-table::
   :header-rows: 1
   :widths: 24 38 38

   * - Document
     - Answers
     - Written when
   * - The docodin Book (``docs/book``)
     - How docodin works and how to use it, today.
     - Updated with every change that users or contributors can see.
   * - DocOdin Discussions (``docs/dod``)
     - Why docodin works that way, what else was considered, and how it was verified.
     - Before and while a design is built; frozen when it is committed.
   * - ``CHANGELOG.rst``
     - What changed in each release.
     - At release time, from the merged work.

The book cites records by number ("see DOD 12") where a chapter would otherwise have to
repeat a design argument.  A committed DOD does not have to be kept up to date with later
code; the book does.  Both projects are built by docodin itself (``docodin book build
docs/book``, ``docodin book build docs/dod``) and by Sphinx, to HTML and PDF.

Alternatives
============

- **Issues or a wiki.**  They live outside the repository, are not versioned with the
  code, and are not reStructuredText.
- **Keep the Typst specification format.**  Typst makes beautiful PDFs, but it cannot be
  checked or built by docodin, and it needs a second toolchain.
- **Markdown memos.**  They were the second format in use, and they have the same
  problem: docodin is a reStructuredText tool and should document itself in
  reStructuredText.
- **Architecture decision records without states.**  They record the decision but not
  its lifecycle; the ``ideation`` and ``abandoned`` states are useful on their own.

Compatibility and fidelity
==========================

The process changes no code.  The ``docodin dod`` commands only read and write files in
``docs/dod``.

Verification
============

- ``docodin dod check`` passes on every commit.
- ``docodin-check`` reports no warnings for any record.
- ``sphinx-build -W`` and ``docodin book build`` build ``docs/dod`` to HTML and PDF.

Outcome
=======

Adopted with docodin 0.2.0.  The earlier documents were converted: the Typst
specification became DOD 2, the Markdown design memo for 0.2.0 became DOD 12, and the
architecture and native pipeline documents became chapters of the book and records
here.  All Markdown and Typst files were removed from the repository (DOD 18).

References
==========

- ``docs/dod/0000-template.rst``, the template.
- DOD 18: The documentation system.
