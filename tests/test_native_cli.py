"""Tests of the native ``docodin`` command (``bin/docodin``) against ``python -m docutils``.

Each case runs both programs with the same arguments in the same directory and
compares the standard output, the files written, the standard error (docutils'
Python version and installation directory normalized) and the exit status.  The
reference is docutils 0.22.4 through ``uv`` (without configuration files).
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
BINARY = ROOT / "bin" / "docodin"
UV = shutil.which("uv")
REFERENCE = [UV or "uv", "run", "--no-project", "--python", "3.14", "--with", "docutils==0.22.4",
             "python", "-m", "docutils"]

pytestmark = [
    pytest.mark.skipif(not BINARY.is_file(), reason="bin/docodin not built"),
    pytest.mark.skipif(UV is None, reason="uv is needed for the docutils reference"),
]

DOC = """\
=========
 A Title
=========

:Author: A. Writer
:Version: 1.0

.. contents::

Section *one*
=============

Text with "quotes" -- and a footnote [#]_ and `a link`_.

.. [#] The footnote.
.. _a link: https://example.org

.. comment to strip

.. class:: x y

Classy paragraph.

Math :math:`a^2 + b^2` and ``literal``.

Second
======

=====  =====
A      B
=====  =====
1      2
=====  =====

`unclosed
"""

UNICODE_DOC = "Title\n=====\n\nCafé — naïve ✓.\n"

CASES = {
    "html5": ["doc.rst"],
    "html5 file destination": ["doc.rst", "out.html"],
    "pseudoxml verbose": ["--writer=pseudoxml", "-v", "doc.rst"],
    "xml indents": ["--writer=xml", "--indents", "--no-doctype", "doc.rst"],
    "latex options": ["--writer=latex", "--documentclass=book", "--table-style=booktabs",
                      "--use-latex-docinfo", "--documentoptions=12pt", "doc.rst"],
    "latex docutils toc": ["--writer=latex", "--use-docutils-toc", "--no-section-numbering",
                           "doc.rst"],
    "xetex language": ["--writer=xetex", "--language=de", "doc.rst"],
    "halt": ["--writer=pseudoxml", "--halt=warning", "doc.rst"],
    "strict": ["--writer=pseudoxml", "--strict", "doc.rst"],
    "exit status": ["--writer=pseudoxml", "--exit-status=warning", "doc.rst"],
    "quiet": ["--writer=pseudoxml", "--quiet", "--exit-status=info", "doc.rst"],
    "title switches": ["--writer=pseudoxml", "--no-doc-title", "--no-doc-info",
                       "--section-subtitles", "doc.rst"],
    "backlinks": ["--toc-top-backlinks", "--no-footnote-backlinks",
                  "--footnote-references=superscript", "doc.rst"],
    "no toc backlinks": ["--writer=pseudoxml", "--no-toc-backlinks", "doc.rst"],
    "smart quotes and stripping": ["--writer=pseudoxml", "--smart-quotes=yes",
                                   "--strip-comments", "--strip-class=x",
                                   "--strip-elements-with-class=y", "doc.rst"],
    "stylesheets": ["--stylesheet=a.css,b.css", "--link-stylesheet", "doc.rst", "out/doc.html"],
    "math and headers": ["--math-output=MathJax", "--initial-header-level=3",
                         "--table-style=booktabs", "doc.rst"],
    "html title and credits": ["--title=Given", "--generator", "--source-link",
                               "--cloak-email-addresses", "doc.rst"],
    "output encoding strict": ["--writer=pseudoxml", "--output-encoding=ascii", "unicode.rst"],
    "output encoding handler": ["--writer=pseudoxml", "--output-encoding=ascii:backslashreplace",
                                "unicode.rst"],
    "output encoding latin-1": ["--output-encoding=latin-1", "unicode.rst"],
    "abbreviated option": ["--writer=pseudoxml", "--rep=info", "doc.rst"],
    "standard input": ["--writer=pseudoxml", "-"],
    "missing source": ["--writer=pseudoxml", "missing.rst"],
}


def run(argv: list[str], cwd: Path, stdin: str) -> tuple[bytes, str, int, dict[str, bytes]]:
    env = {**os.environ, "DOCUTILSCONFIG": "", "PYTHONWARNINGS": "ignore"}
    proc = subprocess.run(argv, cwd=cwd, input=stdin.encode(), capture_output=True, env=env,
                          check=False, timeout=120)
    stderr = proc.stderr.decode("utf-8", "replace")
    stderr = re.sub(r"Python version \([^)]*\)", "Python version (-)", stderr)
    files = {str(p.relative_to(cwd)): p.read_bytes() for p in sorted(cwd.rglob("*.html"))}
    return proc.stdout, stderr, proc.returncode, files


def workdir(base: Path, name: str) -> Path:
    d = base / name
    (d / "out").mkdir(parents=True)
    (d / "doc.rst").write_text(DOC, encoding="utf-8")
    (d / "unicode.rst").write_text(UNICODE_DOC, encoding="utf-8")
    return d


@pytest.mark.parametrize("name", sorted(CASES))
def test_same_as_docutils(tmp_path: Path, name: str) -> None:
    args = CASES[name]
    ours = run([str(BINARY), *args], workdir(tmp_path, "native"), DOC)
    theirs = run([*REFERENCE, *args], workdir(tmp_path, "docutils"), DOC)
    assert ours[2] == theirs[2], (ours[1], theirs[1])
    assert ours[1] == theirs[1]
    assert ours[0].decode("latin-1") == theirs[0].decode("latin-1")
    assert ours[3] == theirs[3]


def usage_error(*args: str) -> str:
    proc = subprocess.run([str(BINARY), *args], capture_output=True, text=True, check=False)
    assert proc.returncode == 2
    assert proc.stdout == ""
    return proc.stderr


def test_usage_errors_are_explained() -> None:
    err = usage_error("--reprt=info", "doc.rst")
    assert err.startswith("-- UNKNOWN OPTION ")
    assert "Did you mean `--report`?" in err
    err = usage_error("--documentclass=book")
    assert "It is an option of the latex and xetex writers" in err
    assert "`--writer=latex`" in err
    err = usage_error("--report=loud")
    assert err.startswith("-- INVALID VALUE ") and "`info`" in err
    err = usage_error("--halt")
    assert err.startswith("-- MISSING VALUE ")
    err = usage_error("--date=today")
    assert err.startswith("-- UNEXPECTED VALUE ")
    err = usage_error("a.rst", "b.html", "c")
    assert err.startswith("-- TOO MANY ARGUMENTS ")
    err = usage_error("--config=docutils.conf")
    assert err.startswith("-- UNSUPPORTED OPTION ")
    err = usage_error("--writer=odt")
    assert 'Writer "odt" not found.' in err


def test_writer_commands_and_help(tmp_path: Path) -> None:
    (tmp_path / "doc.rst").write_text("Title\n=====\n\nText.\n", encoding="utf-8")
    latex = subprocess.run([str(BINARY), "latex", "doc.rst"], cwd=tmp_path, capture_output=True,
                           check=True)
    assert latex.stdout.startswith(b"\\documentclass[a4paper]{article}\n% generated by Docutils")
    link = tmp_path / "rst2pseudoxml"
    link.symlink_to(BINARY)
    pseudo = subprocess.run([str(link), "doc.rst"], cwd=tmp_path, capture_output=True, check=True)
    assert pseudo.stdout.startswith(b'<document ids="title"')
    helptext = subprocess.run([str(BINARY), "--help", "--writer=latex"], capture_output=True,
                              text=True, check=True).stdout
    assert "--documentclass=<documentclass>" in helptext
    assert "--math-output" not in helptext


def test_check_command(tmp_path: Path) -> None:
    (tmp_path / "bad.rst").write_text("Para *emphasis\n", encoding="utf-8")
    proc = subprocess.run([str(BINARY), "check", "--error-format=docutils", "--exit-status=warning",
                           "bad.rst"], cwd=tmp_path, capture_output=True, text=True, check=False)
    assert proc.returncode == 1
    assert proc.stderr == ("bad.rst:1: (WARNING/2) Inline emphasis start-string without "
                           "end-string.\n")
    elm = subprocess.run([str(BINARY), "check", "--color=never", "bad.rst"], cwd=tmp_path,
                         capture_output=True, text=True, check=False)
    assert elm.returncode == 0
    assert elm.stderr.startswith("-- UNCLOSED EMPHASIS ")
