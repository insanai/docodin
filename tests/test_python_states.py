"""The shim's pure-Python reStructuredText state machine.

Extensions that change the grammar in Python (custom state classes, subclassed
or monkeypatched states, their own state machines) make the shim parse with
its Python states instead of the native engine.  Each test runs a script in a
subprocess with the shim (natively by default, and with ``DOCODIN_NATIVE=0``)
and compares the result with real docutils when it is installed.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent

_PRELUDE = """\
import json, sys
if sys.argv[1] == "shim":
    import docodin.shim
    docodin.shim.install_shim(force=True)
from docutils import nodes
from docutils.core import publish_doctree
from docutils.parsers.rst import Parser, states

SETTINGS = {"_disable_config": True, "report_level": 5}

def dump(doc):
    lines = [(n.tagname, n.line) for n in doc.findall(nodes.Element)]
    print(json.dumps({"tree": doc.pformat(), "lines": lines}))
"""

_INPUT = """\
Title
=====

!! A shout at the start.

- first item
- second item

  !! nested shout

  * inner item

Section
-------

term
   definition

!! another shout
"""

# A ``Body`` subclass with a new construct: "!! text" becomes a paragraph
# with the class "shout".
_CUSTOM_BODY = """\
class Body(states.Body):
    patterns = {**states.Body.patterns, "shout": r"!!( +|$)"}
    initial_transitions = ("shout", *states.Body.initial_transitions)

    def shout(self, match, context, next_state):
        text = match.string[match.end():]
        lineno = self.state_machine.abs_line_number()
        textnodes, messages = self.inline_text(text, lineno)
        para = nodes.paragraph(text, "", *textnodes, classes=["shout"])
        para.source, para.line = self.state_machine.get_source_and_line(lineno)
        self.parent += para
        self.parent += messages
        return [], next_state, []

CLASSES = tuple(Body if cls is states.Body else cls for cls in states.state_classes)

class ShoutParser(Parser):
    def __init__(self):
        super().__init__()
        self.state_classes = CLASSES
"""

_SUBCLASSED_BODY = _CUSTOM_BODY + """\
dump(publish_doctree(sys.stdin.read(), parser=ShoutParser(), settings_overrides=SETTINGS))
"""

# ``Body.bullet`` wrapped by an extension: bullet lists get a class.
_PATCHED_BULLET = """\
original_bullet = states.Body.bullet

def bullet(self, match, context, next_state):
    result = original_bullet(self, match, context, next_state)
    self.parent[-1]["classes"].append("patched")
    return result

states.Body.bullet = bullet
dump(publish_doctree(sys.stdin.read(), settings_overrides=SETTINGS))
"""

# An extension wrapping an inline markup method of ``Inliner`` (docutils
# dispatches through the class-level ``dispatch`` table).
_PATCHED_INLINER = """\
original_literal = states.Inliner.literal

def literal(self, match, lineno):
    before, inlines, remaining, messages = original_literal(self, match, lineno)
    for node in inlines:
        node["classes"].append("patched")
    return before, inlines, remaining, messages

states.Inliner.dispatch["``"] = literal
dump(publish_doctree(sys.stdin.read(), settings_overrides=SETTINGS))
"""

# An extension's own state machine with custom state classes.
_OWN_MACHINE = _CUSTOM_BODY + """\
from docutils.frontend import get_default_settings
from docutils.utils import new_document

settings = get_default_settings(Parser)
settings.report_level = 5
document = new_document("<machine>", settings)
machine = states.RSTStateMachine(state_classes=CLASSES, initial_state="Body")
machine.run(sys.stdin.read().splitlines(), document)
dump(document)
"""

_STOCK = """\
dump(publish_doctree(sys.stdin.read(), settings_overrides=SETTINGS))
"""


def _run(mode: str, script: str, text: str, python: bool = False) -> Any:
    env = {"PYTHONPATH": str(ROOT / "python")}
    if python:
        env["DOCODIN_NATIVE"] = "0"
    proc = subprocess.run([sys.executable, "-c", _PRELUDE + script, mode], input=text,
                          capture_output=True, text=True, check=False, env=env)
    assert proc.returncode == 0, proc.stderr
    return json.loads(proc.stdout)


def _real_docutils_available() -> bool:
    proc = subprocess.run([sys.executable, "-c", "import docutils; print(docutils.__file__)"],
                          capture_output=True, text=True, check=False)
    return proc.returncode == 0 and "/shim/" not in proc.stdout


def _check(script: str, text: str = _INPUT) -> dict[str, Any]:
    """The shim's result (native default and forced Python agree); equal to
    real docutils' when it is installed."""
    shim = _run("shim", script, text)
    assert shim == _run("shim", script, text, python=True)
    if _real_docutils_available():
        assert shim == _run("real", script, text)
    return shim


def test_body_subclass_adds_a_construct() -> None:
    result = _check(_SUBCLASSED_BODY)
    assert result["tree"].count('<paragraph classes="shout">') == 2
    # nested parses use the stock state classes (``nested_sm_kwargs``)
    assert "!! nested shout" in result["tree"]


def test_monkeypatched_bullet_transition() -> None:
    result = _check(_PATCHED_BULLET)
    assert result["tree"].count('<bullet_list bullet="-" classes="patched">') == 1
    assert result["tree"].count('<bullet_list bullet="*" classes="patched">') == 1


def test_monkeypatched_inliner_method() -> None:
    result = _check(_PATCHED_INLINER, "Some ``code`` here.\n\n- and ``more``\n")
    assert result["tree"].count('<literal classes="patched">') == 2


def test_custom_state_classes_in_own_state_machine() -> None:
    result = _check(_OWN_MACHINE)
    assert result["tree"].count('<paragraph classes="shout">') == 2


_RICH = """\
==========
 Document
==========

:Author: A. Writer
:Version: 1

.. contents::

Section *one*
=============

Paragraph with **strong**, ``literal``, a reference_, [1]_, [CIT]_ and |sub|.

.. _reference: https://example.org
.. [1] A footnote.
.. [CIT] A citation.
.. |sub| replace:: substitution

.. note:: An admonition with a list:

   - item
   - item

     1. enumerated
     2. list

   (a) parens
   (b) list

+-----+-----+
| a   | b   |
+=====+=====+
| 1   | 2   |
+-----+-----+

=====  =====
x      y
=====  =====
1      2
=====  =====

>>> print("doctest")
doctest

| line block
|    indented line

    A block quote.

    -- Attribution

Section two
===========

term : classifier
   definition

-o, --option  description
--long=VALUE  another

Literal::

    code

Quoted::

> quoted
> literal

----

Title
-----

.. image:: picture.png
   :alt: alternative

.. unknown-directive:: argument

.. _`phrase target`:

__ https://anonymous.example.org

Bad title
--

*unclosed emphasis
"""


def test_forced_python_parser_matches_native() -> None:
    """``DOCODIN_NATIVE=0`` parses a document exactly like the native engine."""
    assert _run("shim", _STOCK, _RICH) == _run("shim", _STOCK, _RICH, python=True)
    if _real_docutils_available():
        assert _run("shim", _STOCK, _RICH, python=True) == _run("real", _STOCK, _RICH)
