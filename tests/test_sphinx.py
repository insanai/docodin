"""Sphinx builds with docodin produce the same output as with docutils."""

from __future__ import annotations

import os
from pathlib import Path

import pytest

sphinx = pytest.importorskip("sphinx")
import docodin  # noqa: E402 - only when Sphinx is installed
from sphinx.cmd.build import build_main  # noqa: E402

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


@pytest.mark.parametrize("enabled", [True, False])
def test_extension_tunes_the_collector(tmp_path, enabled):
    import subprocess
    import sys

    (tmp_path / "conf.py").write_text(
        f"extensions = ['docodin.sphinx']\ndocodin_gc_tuning = {enabled}\n", encoding="utf-8")
    (tmp_path / "index.rst").write_text("Title\n=====\n\nText.\n", encoding="utf-8")
    code = ("import gc\nfrom sphinx.cmd.build import build_main\n"
            "from docodin.sphinx_build import GC_THRESHOLDS\n"
            f"rc = build_main(['-q', '-b', 'html', {str(tmp_path)!r}, {str(tmp_path / 'o')!r}])\n"
            "print(rc, gc.get_threshold() == GC_THRESHOLDS)")
    proc = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, check=False)
    assert proc.stdout.split() == ["0", str(enabled)], proc.stderr
