"""Sphinx ecosystem behaviour on the docutils shim.

Each test runs in a subprocess (with the shim, and with real docutils when it is
installed) and compares the results; tests needing a Sphinx extension skip when
it is missing.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path
from typing import Any

import pytest

ROOT = Path(__file__).resolve().parent.parent

_PRELUDE = """\
import json, sys
if sys.argv[1] == "shim":
    import docodin.shim
    docodin.shim.install_shim(force=True)
"""

# sphinx-autodoc-typehints (patches._patch_line_numbers) replaces ``Body.doctest``
# and wraps ``Text.indent`` to put line numbers on doctest blocks and definition lists.
_TRANSITION_PATCHES = """\
from docutils import nodes
from docutils.core import publish_doctree
from docutils.parsers.rst.states import Body, Text

orig_text_indent = Text.indent

def text_indent(self, *args):
    _, line = self.state_machine.get_source_and_line()
    result = orig_text_indent(self, *args)
    node = self.parent[-1]
    if node.tagname == "system_message":
        node = self.parent[-2]
    node.line = line
    return result

def body_doctest(self, _match, _context, next_state):
    line = self.document.current_line + 1
    data = "\\n".join(self.state_machine.get_text_block())
    n = nodes.doctest_block(data, data)
    n.line = line
    self.parent += n
    return [], next_state, []

# patched before the first parse: docutils' cached states keep their methods
Text.indent = text_indent
Body.doctest = body_doctest
doc = publish_doctree(sys.stdin.read(), settings_overrides={
    "_disable_config": True, "report_level": 5})
print(json.dumps({"lines": [(n.tagname, n.line) for n in doc.findall(nodes.Element)],
                  "doctests": [n.astext() for n in doc.findall(nodes.doctest_block)],
                  "tree": doc.pformat()}))
"""

_PATCHED_INPUT = """\
Some text.

>>> 1 + 1
2
>>> more

Some text and then a definition list.

abc
    x

def
    something

* item

  >>> nested
  doctest

  term
     definition
"""


def _run(mode: str, script: str, text: str = "") -> Any:
    proc = subprocess.run([sys.executable, "-c", _PRELUDE + script, mode], input=text,
                          capture_output=True, text=True, check=False,
                          env={"PYTHONPATH": str(ROOT / "python")})
    assert proc.returncode == 0, proc.stderr
    return json.loads(proc.stdout)


def _real_docutils_available() -> bool:
    proc = subprocess.run([sys.executable, "-c", "import docutils; print(docutils.__file__)"],
                          capture_output=True, text=True, check=False)
    return proc.returncode == 0 and "/shim/" not in proc.stdout


def test_patched_transition_methods_run_on_native_constructs() -> None:
    shim = _run("shim", _TRANSITION_PATCHES, _PATCHED_INPUT)
    patched = ("doctest_block", "definition_list")
    assert [[t, n] for t, n in shim["lines"] if t in patched] == [
        ["doctest_block", 4], ["definition_list", 10], ["doctest_block", 18],
        ["definition_list", 21]]
    assert shim["doctests"] == [">>> 1 + 1\n2\n>>> more", ">>> nested\ndoctest"]
    if _real_docutils_available():
        assert shim == _run("real", _TRANSITION_PATCHES, _PATCHED_INPUT)


_TYPEHINTS_BUILD = """\
import os, tempfile, textwrap
from sphinx.application import Sphinx
src = tempfile.mkdtemp()
with open(os.path.join(src, "mod.py"), "w") as f:
    f.write(textwrap.dedent('''
        def has_doctest() -> None:
            \"\"\"Doctest follows.

            >>> fake
            a
            \"\"\"

        def has_deflist() -> int:
            \"\"\"Definition list follows.

            term
                definition
            \"\"\"
            return 1
    '''))
with open(os.path.join(src, "conf.py"), "w") as f:
    f.write("import sys; sys.path.insert(0, %r)\\n" % src)
    f.write("extensions = ['sphinx.ext.autodoc', 'sphinx_autodoc_typehints']\\n")
with open(os.path.join(src, "index.rst"), "w") as f:
    f.write(".. autofunction:: mod.has_doctest\\n\\n.. autofunction:: mod.has_deflist\\n")
out = os.path.join(src, "_build")
app = Sphinx(src, src, out, os.path.join(out, ".doctrees"), "text", status=None,
             warning=None, freshenv=True)
app.build()
with open(os.path.join(out, "index.txt")) as f:
    print(json.dumps(f.read()))
"""


def test_sphinx_autodoc_typehints_places_return_type() -> None:
    """The return type goes before a docstring's doctest or definition list."""
    pytest.importorskip("sphinx_autodoc_typehints")
    text = _run("shim", _TYPEHINTS_BUILD)
    assert text.index("Return type") < text.index(">>> fake")
    assert text.index("Return type:\n      \"int\"") < text.index("term")
    if _real_docutils_available():
        assert text == _run("real", _TYPEHINTS_BUILD)
