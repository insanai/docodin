:orphan:

.. The DOD template.  `docodin dod new "Title"` copies it to NNNN-slug.rst with the next
   number, your name from git and today's date.  To write one by hand, copy this file,
   replace every placeholder, and keep the field names exactly as they are: `docodin dod
   check` validates them.  This file is excluded from the builds (conf.py).

==============================================================================
DOD 0: Title in a Few Words
==============================================================================

:Authors: Your Name
:State: prediscussion
:Created: YYYY-MM-DD
:Discussion:
:Labels: process

.. Optional fields, one per line after Labels:
   :Updated: YYYY-MM-DD
   :Supersedes: DOD n
   :Superseded-By: DOD n

.. contents:: Contents
   :local:
   :depth: 1

Summary
=======

Two to five sentences: what this record proposes or decides, and why a reader should care.
Someone who reads only this section should know what changes.

Background
==========

The situation today, with facts: what the code does now (name the files and packages),
measurements, and the problem or opportunity.  Link earlier records by number, for
example "DOD 4 introduced ...".

Proposal
========

The design.  Be concrete: data structures, interfaces, commands, file layout, the order of
work.  Split it into subsections as the topic needs.  A record that documents a decision
already taken may call this section "Discussion" instead.

Alternatives
============

The other designs considered, and why they were not chosen.  "Do nothing" is often one of
them.

Compatibility and fidelity
==========================

docodin's first rule is that its docutils path stays identical to docutils 0.22.4.  Say
what the proposal changes for users, for the docutils path (output, messages, node
positions) and for the native tools, and why that is safe.

Verification
============

How we will know it works: the tests, differential runs, benchmarks and their numbers.

Decision
========

Filled in when the discussion converges: what was decided, by whom, and what is left open.
A record that is already implemented may call this section "Outcome" and describe what
landed, with the commits or the release.

References
==========

- DOD 1: DocOdin Discussions (the process).
- Code, commits, issues and external sources this record relies on.
