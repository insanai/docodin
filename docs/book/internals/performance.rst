.. _performance:

============================
Performance and benchmarks
============================

This chapter collects docodin's measurements: what was measured, on what, and how to
reproduce it.  Where docodin stands in for docutils, output is identical in every
measurement and only time and memory change.  The native book builder is a different
product: it builds the same project as Sphinx, with its own theme.

The native book builder (1.0.0b1)
=================================

The external release review of 10 October 2026 compared ``docodin book build --html``
with Sphinx on fresh HTML builds: Linux x86-64, AMD Ryzen 9 5950X (16 cores, 32 logical
CPUs), Sphinx 9.1.0 run serially (``-j 1``), docutils 0.22.4.  Each project was built
three times per tool in alternating order; the times are medians of the elapsed time of
a fresh process, start-up included, and the memory is the median peak resident size from
GNU ``time``.  All builds treated warnings as errors and exited with status 0.

.. list-table::
   :header-rows: 1
   :widths: 40 20 20 20

   * - Project
     - Sphinx
     - docodin
     - Speed-up
   * - The docodin Book (40 source pages)
     - 1.771 s, 82.4 MiB
     - 0.064 s, 23.6 MiB
     - 27.8 times
   * - A generated 151-page manual
     - 7.093 s, 186.8 MiB
     - 0.249 s, 107.5 MiB
     - 28.5 times

The generated manual has section headings, emphasis, strong text, literals, hyperlinks,
lists, admonitions, a toctree and cross-document references.  The comparison measures
speed on the features both support; it does not claim that the native builder runs
Sphinx's extensions or writes Sphinx's HTML.  The measurements below of Sphinx running
on docodin's docutils are a different path and must not be mixed with these.

docodin 0.2.0
=============

Linux x86-64 with 32 cores, Python 3.13, docutils 0.22.4 and Sphinx 9.1.

.. list-table::
   :header-rows: 1
   :widths: 46 24 30

   * - Workload
     - docutils
     - docodin 0.2.0
   * - Sphinx, CPython documentation (599 pages, ``-j1``)
     - 65.6 s, 895 MB
     - 47.6 s (1.38 times), 883 MB; identical HTML
   * - The same with ``DOCODIN_GC=tuned``
     - not applicable
     - 38.4 s (1.71 times), 1034 MB
   * - Sphinx, CPython documentation, ``-j auto``
     - 32.7 s wall, 99.7 s CPU
     - 29.1 s wall, 74.7 s CPU
   * - Publish the docutils documentation to HTML5 (60 files, in process)
     - 2.21 s
     - 0.96 s (the docutils package), 0.20 s (``publish_native``)
   * - The same, one command per file
     - 7.37 s (``python -m docutils``)
     - 0.22 s (``docodin``)
   * - Check the docutils and Sphinx documentation for markup errors
     - 2.81 s
     - 0.03 s (``docodin-check -j1``)

Reading the table:

- **Sphinx builds** gain less than the parser alone, because most of a Sphinx build is
  Sphinx's own work: the environment, cross-references, the builders.  docodin speeds up
  the docutils part: parsing, docutils' transforms and writers on a lighter tree, and
  smart quotes.
- **Publishing in process** with ``publish_native`` is eleven times faster than
  docutils: the whole pipeline is native.  Through docodin's docutils package it is 2.3
  times faster, with docutils' Python transforms and writers.
- **One command per file** is where the native command shines: Python's start-up and
  imports dominate ``python -m docutils`` for small files.
- **Checking** needs only the parser, which is where docodin is fastest.

docodin 0.1.0
=============

Linux x86-64, Python 3.13, docutils 0.22.4 and Sphinx 9.1:

.. list-table::
   :header-rows: 1
   :widths: 46 24 30

   * - Workload
     - docutils
     - docodin 0.1.0
   * - Sphinx, CPython documentation (599 pages, ``-j1``)
     - 64.3 s
     - 48.3 s (1.33 times)
   * - Sphinx, CPython documentation (``-j auto``, 32 cores)
     - 32.5 s, 99 s CPU
     - 29.1 s, 74 s CPU
   * - Publish the docutils documentation to HTML5 (60 files, in process)
     - 1.98 s
     - 0.90 s (the docutils package), 0.20 s (``publish_native``)
   * - The same, one command per file
     - 7.48 s (``python -m docutils``)
     - 0.23 s (``docodin``)
   * - Check the docutils and Sphinx documentation
     - 2.83 s (parser)
     - 0.05 s (``-j1``), 0.01 s (all cores)

In 0.1.0 the collector tuning was on by default, and the single-process Sphinx build
peaked at 999 MB against docutils' 890 MB (:doc:`memory`).

The parser
==========

Apple Silicon, macOS, Odin ``dev-2026-09`` with ``-o:speed``; ``rst.parse_text`` called
directly, best of five runs, on the 60 ``.rst`` files of docutils 0.22.4's documentation
(1.39 MB) concatenated and repeated 15 times (20.9 MB, 630,975 lines):

.. list-table::
   :header-rows: 1

   * - Parser
     - ``parse_text``
     - Throughput
     - Instructions
   * - docodin 0.1.0
     - 386 ms
     - 54 MB/s
     - 3.95 G (189 per byte)
   * - docodin 0.2.0
     - 2.8 times faster
     - (not recorded)
     - 3.1 times fewer

The steps between them (DOD 12):

- SIMD line splitting: ``split_lines`` from 51 ms to 20 ms (408 MB/s to 1.05 GB/s);
- URI and e-mail searches only before ``:`` and ``@``, and reference matching only at word
  chains that reach a ``_`` (the first experiment, with SIMD splitting: 225 ms);
- a candidate scanner that jumps between the bytes that can start inline markup;
- reference matching without large struct copies;
- line joins as views of the input;
- tab expansion over plain-ASCII runs: tab-indented documents 2.7 to 5 times faster.

Every step was checked with a hash over every field of every parse node, which had to
stay identical.  Also in 0.2.0, a quadratic case disappeared: a 600 KB line of ``|x``
went from minutes to 27 ms.

Latency
=======

The largest real document of docutils' documentation (``ref/rst/restructuredtext.rst``,
124 KB) parsed in 1.7 ms with 0.1.0.  ``docodin-lsp`` answers a change to it in about
6 ms, including the reader, the transforms and the analysis.  Source spans cost about 10 %
of parse time when they are on, and nothing when they are off.

Reproducing
===========

- ``uv run python tests/benchmark.py [CORPUS_DIR ...] [--repeat N]`` compares docodin's
  parser with docutils' on a corpus (each ``.rst`` or ``.txt`` file parsed separately),
  or on a generated corpus without arguments, and reports the best of ``--repeat`` runs.
- Sphinx builds are timed with ``/usr/bin/time`` around ``sphinx-build`` and
  ``docodin-sphinx-build`` on the same checkout, after a warm-up build, with a clean
  output directory for each run.
- Large benchmarks, such as CPython's documentation, run on a Linux machine with many
  cores; small ones on a laptop.  Always record the machine, the Python, docutils and
  Sphinx versions, and the command.
