"""Sphinx builds with docodin produce the same output as with docutils."""

from __future__ import annotations

import os
from pathlib import Path

import pytest

sphinx = pytest.importorskip("sphinx")
import docodin
from sphinx.cmd.build import build_main

INDEX = """\
Project
=======

Welcome to **docodin**, a *fast* reStructuredText parser.

.. note::
   Directives are run by Sphinx as usual.

.. toctree::
   :maxdepth: 2

   usage

Code
----

.. code-block:: python

   import docodin

See :doc:`usage`, :ref:`usage-label` and |version|.

.. include:: snippet.rst
"""

USAGE = """\
.. _usage-label:

Usage
=====

.. py:function:: parse(text, source='<string>')

   Parse *text* and return a document.

   :param text: the source
   :returns: a :class:`docutils.nodes.document`

+-------+-------+
| a     | b     |
+=======+=======+
| 1     | 2     |
+-------+-------+
"""


def _project(tmp_path: Path, extension: bool) -> Path:
    src = tmp_path / ("ext" if extension else "stock") / "src"
    src.mkdir(parents=True)
    ext = '["docodin.sphinx"]' if extension else "[]"
    (src / "conf.py").write_text(f"project = 'P'\nversion = '1.0'\nextensions = {ext}\n"
                                 "rst_epilog = '.. |epilog| replace:: E'\n")
    (src / "index.rst").write_text(INDEX)
    (src / "usage.rst").write_text(USAGE)
    (src / "snippet.rst").write_text("Included *snippet* |epilog|.\n")
    return src


def _build(src: Path) -> dict[str, str]:
    out = src.parent / "out"
    assert build_main(["-b", "pseudoxml", "-q", "-E", "-N", str(src), str(out)]) == 0
    return {p.name: p.read_text() for p in out.glob("*.pseudoxml")}


def test_sphinx_extension_output_identical(tmp_path):
    stock = _build(_project(tmp_path, extension=False))
    ours = _build(_project(tmp_path, extension=True))
    assert ours.keys() == stock.keys() and ours
    for name in stock:
        assert ours[name].replace("/ext/", "/stock/") == stock[name], name


def test_sphinx_with_patch(tmp_path):
    stock = _build(_project(tmp_path, extension=False))
    docodin.patch_docutils()
    try:
        src = _project(tmp_path / "patched", extension=False)
        ours = _build(src)
    finally:
        docodin.unpatch_docutils()
    for name in stock:
        assert ours[name].replace(os.sep + "patched" + os.sep, os.sep) == stock[name], name
