"""Integration tests of the language server (``bin/docodin-lsp``).

Each test starts the server as a subprocess and speaks LSP to it over its
standard input and output.  Diagnostics are compared with the messages
docutils writes for the same document (text, level and line).
"""

from __future__ import annotations

import io
import json
import os
import queue
import random
import re
import subprocess
import sys
import threading
from pathlib import Path

import docutils.core
import pytest

sys.path.insert(0, os.path.dirname(__file__))
from fuzz_differential import gen_document  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
BINARY = ROOT / "bin" / "docodin-lsp"

pytestmark = pytest.mark.skipif(not BINARY.exists(), reason="bin/docodin-lsp not built")

TIMEOUT = 10

TOKEN_TYPES = [
    "namespace", "operator", "string", "comment", "function", "parameter", "property", "macro",
    "variable", "type", "enumMember", "decorator", "emphasis", "strong",
]

LEVELS = {"DEBUG": 0, "INFO": 1, "WARNING": 2, "ERROR": 3, "SEVERE": 4}
MESSAGE = re.compile(r"^(?:[^:\n]*):(\d*): \((DEBUG|INFO|WARNING|ERROR|SEVERE)/\d\) (.*)$")


class Client:
    """A minimal LSP client over the server's standard streams."""

    def __init__(self) -> None:
        self.proc = subprocess.Popen(
            [str(BINARY)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE
        )
        self.messages: queue.Queue = queue.Queue()
        self.pending: list[dict] = []
        self.next_id = 0
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self) -> None:
        stream = self.proc.stdout
        while True:
            headers = b""
            while not headers.endswith(b"\r\n\r\n"):
                byte = stream.read(1)
                if not byte:
                    return
                headers += byte
            length = int(re.search(rb"Content-Length: *(\d+)", headers, re.I).group(1))
            self.messages.put(json.loads(stream.read(length)))

    def send(self, message: dict) -> None:
        body = json.dumps({"jsonrpc": "2.0", **message}).encode()
        self.proc.stdin.write(b"Content-Length: %d\r\n\r\n%s" % (len(body), body))
        self.proc.stdin.flush()

    def notify(self, method: str, params: dict | None = None) -> None:
        self.send({"method": method, "params": params or {}})

    def request(self, method: str, params: dict | None) -> dict:
        self.next_id += 1
        self.send({"id": self.next_id, "method": method, "params": params})
        return self.wait(lambda m: m.get("id") == self.next_id)

    def wait(self, predicate) -> dict:
        for i, m in enumerate(self.pending):
            if predicate(m):
                return self.pending.pop(i)
        while True:
            m = self.messages.get(timeout=TIMEOUT)
            if predicate(m):
                return m
            self.pending.append(m)

    def diagnostics(self, uri: str, version: int | None = None) -> list[dict]:
        def published(m: dict) -> bool:
            if m.get("method") != "textDocument/publishDiagnostics":
                return False
            params = m["params"]
            return params["uri"] == uri and (version is None or params.get("version") == version)

        return self.wait(published)["params"]["diagnostics"]

    def open(self, uri: str, text: str, version: int = 1) -> None:
        document = {"uri": uri, "languageId": "restructuredtext", "version": version, "text": text}
        self.notify("textDocument/didOpen", {"textDocument": document})


@pytest.fixture
def client():
    c = Client()
    init = c.request("initialize", {"processId": None, "rootUri": None, "capabilities": {}})
    c.capabilities = init["result"]["capabilities"]
    c.notify("initialized")
    yield c
    if c.proc.poll() is None:
        assert c.request("shutdown", None)["result"] is None
        c.notify("exit")
        assert c.proc.wait(timeout=TIMEOUT) == 0


def uri_of(path: Path) -> str:
    return path.resolve().as_uri()


def docutils_report(text: str, path: Path, report_level: int = 2) -> list[tuple[int, int, str]]:
    """(line, level, first line of the text) of each message docutils writes."""
    stream = io.StringIO()
    docutils.core.publish_string(
        text, source_path=str(path), writer="pseudoxml",
        settings_overrides={"report_level": report_level, "halt_level": 5,
                            "warning_stream": stream, "_disable_config": True},
    )
    out = []
    for line in stream.getvalue().splitlines():
        m = MESSAGE.match(line)
        if m:
            out.append((int(m.group(1) or 0), LEVELS[m.group(2)], m.group(3)))
    return out


def lsp_report(diagnostics: list[dict]) -> list[tuple[int, int, str]]:
    return [(d["data"]["line"], d["data"]["level"], d["message"].split("\n")[0]) for d in diagnostics]


# --- lifecycle ------------------------------------------------------------------------------


def test_initialize(client):
    caps = client.capabilities
    assert caps["positionEncoding"] == "utf-16"
    assert caps["textDocumentSync"] == {"openClose": True, "change": 2}
    assert caps["semanticTokensProvider"]["legend"]["tokenTypes"] == TOKEN_TYPES
    for provider in ("documentSymbolProvider", "foldingRangeProvider", "definitionProvider",
                     "referencesProvider", "hoverProvider"):
        assert caps[provider] is True
    assert "diagnosticProvider" not in caps  # pushed to a client without pull support


def test_errors_before_initialize_and_exit_status():
    c = Client()
    assert c.request("textDocument/hover", {})["error"]["code"] == -32002
    c.notify("exit")
    assert c.proc.wait(timeout=TIMEOUT) == 1  # exit without shutdown


def test_version_option():
    out = subprocess.run([str(BINARY), "--version"], capture_output=True, text=True, check=True)
    assert out.stdout.startswith("docodin-lsp ")


# --- diagnostics ----------------------------------------------------------------------------

CASES = {
    "inline": "Para *emphasis and ``literal\n",
    "sections": "Title\n=====\n\nLong title here\n----\n\nText\n\n===\nSub\n===\n",
    "lists": "- item\ntext\n\n1. one\n3. three\n",
    "references": (
        "See `missing`_ and\nlater `also missing`_, |nosub|, [1]_ and [#]_ and anon__.\n\n"
        ".. _dup: http://a\n.. _dup: http://b\n"
    ),
    "directives": (
        ".. unknown:: x\n\n.. note::\n\n   *unclosed and :bad:`role`.\n\n"
        ".. image::\n\n.. figure:: x.png\n   :width: nope\n"
    ),
    "unreferenced": ".. _unused: http://x\n\n.. [CIT] citation\n",
}


@pytest.mark.parametrize("name", sorted(CASES))
def test_diagnostics_match_docutils(client, tmp_path, name):
    path = tmp_path / "case.rst"
    text = CASES[name]
    client.open(uri_of(path), text)
    got = lsp_report(client.diagnostics(uri_of(path)))
    assert sorted(got) == sorted(docutils_report(text, path))


def test_diagnostics_of_generated_documents(client, tmp_path):
    rng = random.Random(7)
    for i in range(60):
        path = tmp_path / f"gen{i}.rst"
        text = gen_document(rng)
        if sys.version_info < (3, 14) and not text.isascii():
            continue  # the native Unicode tables (column widths) are CPython 3.14's
        client.open(uri_of(path), text)
        got = lsp_report(client.diagnostics(uri_of(path)))
        assert sorted(got) == sorted(docutils_report(text, path)), text


def test_known_roles_and_directives(tmp_path):
    c = Client()
    options = {"sphinx": True, "knownRoles": ["MyRole"], "knownDirectives": ["mydirective"]}
    c.request("initialize", {"capabilities": {}, "initializationOptions": options})
    c.notify("initialized")
    uri = uri_of(tmp_path / "sphinx.rst")
    text = (".. toctree::\n\n   intro\n\n.. mydirective::\n\n.. other::\n\n"
            ":ref:`x`, :py:func:`f`, :myrole:`y` and :unknown:`z`.\n")
    c.open(uri, text)
    got = [d["message"].split("\n")[0] for d in c.diagnostics(uri)]
    assert got == ['Unknown directive type "other".', 'Unknown interpreted text role "unknown".']
    c.request("shutdown", None)
    c.notify("exit")
    assert c.proc.wait(timeout=TIMEOUT) == 0


def test_diagnostic_details(client, tmp_path):
    uri = uri_of(tmp_path / "d.rst")
    client.open(uri, "Long title\n=====\n\nSome *emphasis.\n")
    underline, emphasis = client.diagnostics(uri)
    assert underline["code"] == "TITLE UNDERLINE TOO SHORT"
    assert underline["severity"] == 2 and underline["source"] == "docutils"
    assert underline["message"].startswith("Title underline too short.\n\nLong title\n=====")
    assert "Hint: Make the underline at least as long as the title text (10 characters)." in (
        underline["message"])
    assert emphasis["range"] == {"start": {"line": 3, "character": 5},
                                 "end": {"line": 3, "character": 6}}
    assert emphasis["data"]["fix"] == "Escape the start-string"


def test_did_change_updates_diagnostics(client, tmp_path):
    uri = uri_of(tmp_path / "c.rst")
    client.open(uri, "Some *emphasis.\n")
    assert len(client.diagnostics(uri, 1)) == 1
    # close the emphasis: insert "*" after "emphasis" (line 0, character 14)
    change = {"range": {"start": {"line": 0, "character": 14}, "end": {"line": 0, "character": 14}},
              "text": "*"}
    client.notify("textDocument/didChange",
                  {"textDocument": {"uri": uri, "version": 2}, "contentChanges": [change]})
    assert client.diagnostics(uri, 2) == []
    full = {"text": "`x`_\n"}
    client.notify("textDocument/didChange",
                  {"textDocument": {"uri": uri, "version": 3}, "contentChanges": [full]})
    (unknown,) = client.diagnostics(uri, 3)
    assert unknown["message"] == 'Unknown target name: "x".'
    client.notify("textDocument/didClose", {"textDocument": {"uri": uri}})
    assert client.diagnostics(uri) == []


def test_code_actions(client, tmp_path):
    uri = uri_of(tmp_path / "a.rst")
    client.open(uri, "=====\nLong title\n===\n\n- item\ntext\n")
    diagnostics = client.diagnostics(uri)
    params = {"textDocument": {"uri": uri},
              "range": {"start": {"line": 0, "character": 0}, "end": {"line": 6, "character": 0}},
              "context": {"diagnostics": diagnostics}}
    actions = client.request("textDocument/codeAction", params)["result"]
    titles = [a["title"] for a in actions]
    assert "Insert a blank line" in titles
    assert all(a["kind"] == "quickfix" for a in actions)
    blank = next(a for a in actions if a["title"] == "Insert a blank line")
    assert blank["edit"]["changes"][uri] == [
        {"range": {"start": {"line": 5, "character": 0}, "end": {"line": 5, "character": 0}},
         "newText": "\n"}]


def test_underline_fix_clears_the_warning(client, tmp_path):
    uri = uri_of(tmp_path / "u.rst")
    client.open(uri, "Long title\n=====\n")
    assert len(client.diagnostics(uri, 1)) == 1
    params = {"textDocument": {"uri": uri},
              "range": {"start": {"line": 1, "character": 0}, "end": {"line": 1, "character": 0}},
              "context": {"diagnostics": []}}
    (action,) = client.request("textDocument/codeAction", params)["result"]
    edits = action["edit"]["changes"][uri]
    client.notify("textDocument/didChange", {"textDocument": {"uri": uri, "version": 2},
                                             "contentChanges": [{**e, "text": e["newText"]}
                                                                for e in edits]})
    assert client.diagnostics(uri, 2) == []


# --- navigation -----------------------------------------------------------------------------

NAV = """\
Title
=====

See `Other Section`_, link_, `alias <link_>`_, anon__, |sub| and [#]_.

.. _link: http://example.com
__ http://anonymous.example
.. |sub| replace:: substituted *text*
.. [#] The footnote.

Other Section
-------------

Back to link_.
"""


def at(text: str, needle: str, offset: int = 1) -> dict:
    for line, content in enumerate(text.splitlines()):
        col = content.find(needle)
        if col >= 0:
            return {"line": line, "character": col + offset}
    raise AssertionError(needle)


@pytest.fixture
def nav(client, tmp_path):
    uri = uri_of(tmp_path / "nav.rst")
    client.open(uri, NAV)
    client.diagnostics(uri)
    return client, uri


def test_definition(nav):
    client, uri = nav

    def definition(needle: str) -> dict:
        params = {"textDocument": {"uri": uri}, "position": at(NAV, needle)}
        return client.request("textDocument/definition", params)["result"]

    assert definition("`Other Section`_")["range"]["start"] == {"line": 10, "character": 0}
    assert definition("link_,")["range"] == {"start": {"line": 5, "character": 4},
                                             "end": {"line": 5, "character": 8}}
    assert definition("`alias")["range"]["start"]["line"] == 5
    assert definition("anon__")["range"]["start"]["line"] == 6
    assert definition("|sub|")["range"]["start"] == {"line": 7, "character": 4}
    assert definition("[#]_")["range"]["start"]["line"] == 8


def test_references(nav):
    client, uri = nav
    params = {"textDocument": {"uri": uri}, "position": at(NAV, "_link:", 2),
              "context": {"includeDeclaration": False}}
    lines = sorted(r["range"]["start"]["line"] for r in
                   client.request("textDocument/references", params)["result"])
    assert lines == [3, 3, 13]


def test_hover(nav):
    client, uri = nav

    def hover(needle: str) -> str:
        params = {"textDocument": {"uri": uri}, "position": at(NAV, needle)}
        return client.request("textDocument/hover", params)["result"]["contents"]["value"]

    assert hover("link_,") == "**Hyperlink target** `link` → <http://example.com>"
    assert hover("`Other Section`_") == "**Section** Other Section"
    assert "replace:: substituted *text*" in hover("|sub|")
    assert hover("[#]_").endswith("The footnote.")


def test_document_symbols(nav):
    client, uri = nav
    (title,) = client.request("textDocument/documentSymbol", {"textDocument": {"uri": uri}})["result"]
    assert title["name"] == "Title" and title["kind"] == 3
    names = [c["name"] for c in title["children"]]
    assert names == ["link", "|sub|", "[#]", "Other Section"]
    assert title["range"]["end"]["line"] == 13


def test_folding_ranges(nav):
    client, uri = nav
    folds = client.request("textDocument/foldingRange", {"textDocument": {"uri": uri}})["result"]
    assert {"startLine": 0, "endLine": 13} in folds
    assert {"startLine": 10, "endLine": 13} in folds


def test_semantic_tokens(nav):
    client, uri = nav
    data = client.request("textDocument/semanticTokens/full",
                          {"textDocument": {"uri": uri}})["result"]["data"]
    tokens, line, char = [], 0, 0
    for i in range(0, len(data), 5):
        dl, dc, length, kind, _ = data[i:i + 5]
        char = dc if dl else char + dc
        line += dl
        tokens.append((line, char, length, TOKEN_TYPES[kind]))
    assert (0, 0, 5, "namespace") in tokens
    assert (1, 0, 5, "operator") in tokens
    assert (3, 4, 16, "type") in tokens  # `Other Section`_
    assert (5, 4, 4, "decorator") in tokens
    assert (7, 3, 5, "variable") in tokens  # |sub|
    assert (7, 9, 7, "function") in tokens  # replace
    assert (8, 3, 3, "enumMember") in tokens


def test_completion(client, tmp_path):
    uri = uri_of(tmp_path / "comp.rst")
    text = ".. no\n\n.. image:: x.png\n   :al\n\nSee `Ta and :su\n\n.. _Target: http://x\n"
    client.open(uri, text)

    def labels(line: int, character: int) -> list[str]:
        params = {"textDocument": {"uri": uri}, "position": {"line": line, "character": character}}
        return [i["label"] for i in client.request("textDocument/completion", params)["result"]["items"]]

    assert "note" in labels(0, 5)
    assert ":alt:" in labels(3, 6)
    assert "Target" in labels(5, 7)
    assert "subscript" in labels(5, 15)


def test_utf16_positions(client, tmp_path):
    uri = uri_of(tmp_path / "u16.rst")
    text = "😀 é `link`_\n\n.. _link: http://x\n"
    client.open(uri, text)
    client.diagnostics(uri)
    # "😀" is two UTF-16 code units: `link`_ starts at character 5
    params = {"textDocument": {"uri": uri}, "position": {"line": 0, "character": 6}}
    result = client.request("textDocument/definition", params)["result"]
    assert result["range"]["start"] == {"line": 2, "character": 4}
    hover = client.request("textDocument/hover", params)["result"]
    assert hover["range"] == {"start": {"line": 0, "character": 5}, "end": {"line": 0, "character": 12}}
