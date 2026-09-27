"""Tests of the docodin docutils shim (``python/docodin/shim/docutils``).

The shim replaces the docutils package: each test runs in a subprocess, so
the other tests keep using whichever docutils the environment provides.
Output is compared with real docutils when it is installed.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path
from typing import Any

import pytest

ROOT = Path(__file__).resolve().parent.parent
FUNCTIONAL = ROOT / "tests" / "conformance"

DOCUMENT = """\
==========
 Document
==========

:Author: A. Writer
:Version: 1

.. contents::

Section *one*
=============

Paragraph with **strong**, ``literal``, a reference_, [1]_ and |sub|.

.. _reference: https://example.org
.. [1] A footnote.
.. |sub| replace:: substitution

.. note:: An admonition with a list:

   - item
   - item

.. table:: Grid

   +-----+-----+
   | a   | b   |
   +=====+=====+
   | 1   | 2   |
   +-----+-----+

.. csv-table:: CSV
   :header: x, y

   1, 2

.. math:: a^2 + b^2 = c^2

.. code:: python

   print("hi")

Section two
===========

term
   definition

-o, --option  description
"""

def _publish(mode: str, text: str) -> dict[str, Any]:
    script = """\
import json, sys
if sys.argv[1] == "shim":
    import docodin.shim
    docodin.shim.install_shim(force=True)
import docutils, docutils.core
text = sys.stdin.read()
out = {"shim": getattr(docutils, "__docodin_shim__", False)}
for writer in ("pseudoxml", "xml", "html5", "html4", "latex", "xetex", "manpage"):
    out[writer] = docutils.core.publish_string(
        text, writer_name=writer,
        settings_overrides={"_disable_config": True, "report_level": 5,
                            "embed_stylesheet": False, "stylesheet_path": ""}).decode()
print(json.dumps(out))
"""
    proc = subprocess.run([sys.executable, "-c", script, mode], input=text, capture_output=True,
                          text=True, check=True, env={"PYTHONPATH": str(ROOT / "python")})
    return json.loads(proc.stdout)


def _real_docutils_available() -> bool:
    proc = subprocess.run([sys.executable, "-c", "import docutils; print(docutils.__file__)"],
                          capture_output=True, text=True, check=False)
    return proc.returncode == 0 and "/shim/" not in proc.stdout


def test_install_shim_replaces_docutils() -> None:
    script = """\
import sys
import docodin.shim
docodin.shim.install_shim(force=True)
import docutils, docutils.nodes, docutils.parsers.rst.states, docutils.writers.html5_polyglot
assert docutils.__docodin_shim__ and docodin.shim.is_active()
assert docutils.nodes.document.__module__ == "docutils.nodes"
assert "shim" in docutils.__file__
docodin.shim.uninstall_shim()
assert "docutils" not in sys.modules
print("ok")
"""
    proc = subprocess.run([sys.executable, "-c", script], capture_output=True, text=True,
                          check=False, env={"PYTHONPATH": str(ROOT / "python")})
    assert proc.stdout.strip() == "ok", proc.stderr


def test_shim_publishes_all_writers() -> None:
    out = _publish("shim", DOCUMENT)
    assert out["shim"] is True
    assert '<section id="section-one">' in out["html5"]
    assert "\\section{Section \\emph{one}" in out["latex"]
    assert "<footnote auto" not in out["pseudoxml"] and "<footnote" in out["pseudoxml"]
    assert ".SH Author\nA. Writer" in out["manpage"]


@pytest.mark.skipif(not _real_docutils_available(), reason="real docutils not installed")
def test_shim_output_matches_docutils() -> None:
    real, shim = _publish("real", DOCUMENT), _publish("shim", DOCUMENT)
    assert shim["shim"] and not real["shim"]
    for writer in ("pseudoxml", "xml", "html5", "html4", "latex", "xetex", "manpage"):
        assert _masked(shim[writer]) == _masked(real[writer]), writer


def _masked(output: str) -> list[str]:
    """Output lines without stylesheet links (they carry the installation paths)."""
    return [line for line in output.splitlines() if 'rel="stylesheet"' not in line]


def test_sphinx_conf_discovery_and_metadata(tmp_path: Any) -> None:
    """Verify Sphinx conf.py metadata extraction in python and the native CLI compiler."""
    from docodin.conf import find_conf_py, get_metadata

    conf_dir = Path(tmp_path) / "docs"
    conf_dir.mkdir(parents=True)
    conf_file = conf_dir / "conf.py"
    conf_file.write_text(
        "project = 'Sphinx Test Doc'\n"
        "author = 'Insan.ai Engineers'\n"
        "version = '1.0'\n"
        "release = '1.0.0'\n"
        "html_title = 'Sphinx Test Doc Documentation'\n",
        encoding="utf-8",
    )

    doc_file = conf_dir / "index.rst"
    doc_file.write_text(
        "Welcome\n=======\n\nDocOdin native test.\n",
        encoding="utf-8",
    )

    # 1. Test Python metadata extraction
    found = find_conf_py(doc_file)
    assert found == conf_file

    meta = get_metadata(doc_file)
    assert meta["project"] == "Sphinx Test Doc"
    assert meta["title"] == "Sphinx Test Doc Documentation"
    assert meta["author"] == "Insan.ai Engineers"

    # 2. Test Standalone Odin CLI auto-extracting conf.py metadata
    cli_bin = Path(__file__).resolve().parent.parent / "bin" / "docodin"
    if cli_bin.is_file():
        out_html = conf_dir / "index.html"
        result = subprocess.run(
            [str(cli_bin), "html", str(doc_file), "-o", str(out_html)],
            capture_output=True,
            text=True,
        )
        assert result.returncode == 0
        html_content = out_html.read_text(encoding="utf-8")
        assert "Sphinx Test Doc Documentation" in html_content
        assert '<h1 id="welcome">Welcome</h1>' in html_content


def _python(code: str, **env: str) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, "-c", code], capture_output=True, text=True,
                          check=False, env={"PYTHONPATH": str(ROOT / "python"), **env})


def test_startup_hook_is_lazy_and_opt_in() -> None:
    """``docodin.pth`` imports ``docodin_autoload`` in every interpreter."""
    lazy = _python("import sys, docodin_autoload\n"
                   "print('docodin' in sys.modules, 'docutils' in sys.modules)")
    assert lazy.stdout.split() == ["False", "False"], lazy.stderr
    forced = _python("import docodin_autoload, docutils\nprint(docutils.__docodin_shim__)",
                     DOCODIN_DOCUTILS="1")
    assert forced.stdout.strip() == "True", forced.stderr


@pytest.mark.skipif(not _real_docutils_available(), reason="real docutils not installed")
def test_startup_hook_keeps_installed_docutils() -> None:
    kept = _python("import docodin_autoload, docutils\n"
                   "print(getattr(docutils, '__docodin_shim__', False))")
    assert kept.stdout.strip() == "False", kept.stderr


def test_sphinx_build_wrapper_uses_the_shim(tmp_path: Path) -> None:
    pytest.importorskip("sphinx")
    (tmp_path / "conf.py").write_text("project = 'P'\n", encoding="utf-8")
    (tmp_path / "index.rst").write_text("Title\n=====\n\nHello *world*.\n", encoding="utf-8")
    code = ("import sys, docodin.sphinx_build as b\n"
            f"rc = b.main(['-q', '-b', 'html', {str(tmp_path)!r}, {str(tmp_path / 'out')!r}])\n"
            "import docutils\nprint(rc, docutils.__docodin_shim__)")
    proc = _python(code)
    assert proc.stdout.split() == ["0", "True"], proc.stderr
    assert "<em>world</em>" in (tmp_path / "out" / "index.html").read_text(encoding="utf-8")
