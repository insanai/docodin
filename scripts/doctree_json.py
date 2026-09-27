"""Dump the docutils document tree of a reST source to JSON (the doctree interchange).

The native pipeline (``odin/doctree``) loads these dumps with ``doctree.load_json`` so
that transforms and writers can be developed and tested against docutils independently
of the native parser.  The format is described in The docodin Book, chapter "The doctree
interchange" (docs/book/internals/interchange.rst).

The document is taken from real docutils, driven as ``Publisher.publish`` does, at one
of three stages:

``parsed``
    after ``reader.read`` and ``Transformer.populate_from_components``, before any
    transform: the queue holds the reader, parser and writer transforms and the
    ``pending`` transforms of directives.
``transformed``
    after ``Transformer.apply_transforms``, before the writer.
``output``
    ``transformed`` plus the writer's output and its parts (``publish_parts``) as the
    expected result.

Run with the interpreter that the native Unicode tables mirror (see
scripts/gen_doctree_tables.py):

    PY="uv run --no-project --python 3.14 --with docutils==0.22.4 python"
    $PY scripts/doctree_json.py doc.rst --writer html5 --stage output --set report_level=1
"""

from __future__ import annotations

import argparse
import io
import json
import math
import sys
import warnings
from pathlib import Path

import docutils
from docutils import core, nodes, utils
from docutils import io as dio

FORMAT = "docodin-doctree/1"
STAGES = ("parsed", "transformed", "output")

# Instance attributes of node objects that the node records carry elsewhere.
KNOWN_NODE_VARS = {"parent", "children", "attributes", "rawsource", "tagname", "_document",
                   "source", "line", "referenced", "resolved", "transform", "details"}
# Registry lists of ``nodes.document`` (node lists).
NODE_LISTS = ("indirect_targets", "autofootnotes", "autofootnote_refs", "symbol_footnotes",
              "symbol_footnote_refs", "footnotes", "citations", "parse_messages",
              "transform_messages")
# Registry dicts mapping a name to a list of nodes.
NODE_LIST_MAPS = ("refnames", "refids", "footnote_refs", "citation_refs")


class InterchangeError(Exception):
    """A document that the interchange format cannot represent."""


# --- capturing the warning stream ----------------------------------------------------

class _Capture(io.StringIO):
    """The warning stream: records each write."""

    def __init__(self) -> None:
        super().__init__()
        self.chunks: list[str] = []

    def write(self, s: str) -> int:
        self.chunks.append(s)
        return super().write(s)


_WRITTEN: list[tuple[object, int, object, str]] = []  # (reporter, level, message, text)
_ORIGINAL_SYSTEM_MESSAGE = utils.Reporter.system_message


def _recording_system_message(self, level, message, *children, **kwargs):
    stream = getattr(self.stream, "destination", None)
    before = len(stream.chunks) if isinstance(stream, _Capture) else 0
    msg = _ORIGINAL_SYSTEM_MESSAGE(self, level, message, *children, **kwargs)
    if isinstance(stream, _Capture) and len(stream.chunks) > before:
        _WRITTEN.append((self, level, msg, "".join(stream.chunks[before:])))
    return msg


utils.Reporter.system_message = _recording_system_message


# --- values --------------------------------------------------------------------------

def plain_value(value):
    """A JSON value for a Python ``str``/``int``/``bool``/``None``/``float``/list,
    ``KeyError`` for other types (the caller decides)."""
    if value is None or isinstance(value, (str, bool, int)):
        return value
    if isinstance(value, float):
        if not math.isfinite(value):
            raise KeyError(type(value).__name__)
        return {"float": repr(value)}
    if isinstance(value, (list, tuple)):
        return [plain_value(x) for x in value]
    raise KeyError(type(value).__name__)


def attribute_value(node, key, value):
    if isinstance(value, list) and not all(isinstance(x, str) for x in value):
        raise InterchangeError(f"<{node.tagname}> {key}: list items are not all str")
    try:
        return plain_value(value)
    except KeyError as e:
        raise InterchangeError(f"<{node.tagname}> {key}: unsupported type {e}") from None


def settings_dict(settings) -> dict:
    """All attributes of the settings that are JSON-serializable."""
    out = {}
    for key, value in sorted(vars(settings).items()):
        try:
            out[key] = plain_value(value)
        except KeyError:
            continue
    return out


# --- the node table ------------------------------------------------------------------

def is_node_class(node) -> bool:
    """Is ``node`` a ``Text`` or an instance of a class of ``nodes.node_class_names``?"""
    return isinstance(node, nodes.Text) or type(node).__name__ in nodes.node_class_names


def stale_parent(node):
    """The parent of a node outside the document tree.  The plain ``nodes.Element``
    containers of directives (``nested_parse`` targets) are left out: None."""
    parent = node.parent
    return parent if parent is not None and is_node_class(parent) else None


class Dumper:
    """Numbers the nodes (preorder of the document, then detached subtrees in order
    of discovery) and builds the JSON records."""

    def __init__(self, document: nodes.document) -> None:
        self.document = document
        self.index: dict[int, int] = {}
        self.count = 0
        self.kids: dict[int, list] = {}  # the children of each numbered node
        self.detached: list[tuple[object, object]] = []  # (root, stale parent)
        self.number(document, in_tree=True)
        self.tree = self.record(document)

    def number(self, node, in_tree: bool = False) -> None:
        """Number ``node`` and its children.  A node has one parent: the children
        of a detached node that were moved elsewhere (their ``parent`` is another
        node) are left out."""
        self.index[id(node)] = self.count
        self.count += 1
        kids = []
        for child in getattr(node, "children", ()):
            if id(child) not in self.index and child.parent is node:
                kids.append(child)
                self.number(child, in_tree)
            elif in_tree:
                raise InterchangeError(f"<{child.tagname}> is not a proper child of "
                                       f"<{node.tagname}> (shared or stale parent)")
        self.kids[id(node)] = kids

    def ref(self, node):
        """The index of ``node``; a node outside the numbered trees becomes (with
        its subtree) a detached root."""
        if node is None:
            return None
        if id(node) not in self.index:
            parent = stale_parent(node)
            if parent is not None:
                self.ref(parent)
            if id(node) not in self.index:
                self.number(node)
                self.detached.append((node, parent))
        return self.index[id(node)]

    def refs(self, values) -> list:
        return [self.ref(v) for v in values]

    def record(self, node) -> dict:
        if not is_node_class(node):
            raise InterchangeError(f"{type(node).__name__} is not a docutils node class")
        rec: dict = {"tag": "#text" if isinstance(node, nodes.Text) else node.tagname}
        if node.source is not None:
            rec["source"] = node.source
        if node.line is not None:
            rec["line"] = node.line
        if node._document is not None:
            rec["document"] = True
        if isinstance(node, nodes.Text):
            rec["text"] = str(node)
            return rec
        self.element_fields(node, rec)
        if self.kids[id(node)]:
            rec["children"] = [self.record(c) for c in self.kids[id(node)]]
        return rec

    def element_fields(self, node, rec: dict) -> None:
        if node.rawsource:
            rec["rawsource"] = str(node.rawsource)
        attributes = {k: attribute_value(node, k, v) for k, v in node.attributes.items()
                      if not (k in node.list_attributes and v == [])}
        if attributes:
            rec["attributes"] = attributes
        deleted = [k for k in node.list_attributes if k not in node.attributes]
        if deleted:
            rec["deleted"] = deleted
        if getattr(node, "referenced", False):
            rec["referenced"] = True
        if getattr(node, "resolved", False):
            rec["resolved"] = True
        internal = self.internals(node)
        if internal:
            rec["internal"] = internal
        if isinstance(node, nodes.pending):
            transform = node.transform
            rec["pending"] = {"transform": f"{transform.__module__}.{transform.__name__}",
                              "default_priority": transform.default_priority,
                              "details": self.details(node.details)}

    def internals(self, node) -> dict:
        """Python instance state outside ``attributes`` (in a fixed order, which is
        the order of first reference of the nodes it names)."""
        state = {k: v for k, v in vars(node).items() if k not in KNOWN_NODE_VARS}
        if node is self.document:
            return {}
        out: dict = {}
        indent = state.pop("indent", None)
        if isinstance(indent, int) and isinstance(node, nodes.line):
            out["indent"] = indent
        elif indent is not None:
            raise InterchangeError(f"<{node.tagname}>.indent: unsupported value {indent!r}")
        name = state.pop("indirect_reference_name", None)
        if name is not None:
            out["indirect_reference_name"] = str(name)
        for key in ("expect_referenced_by_id", "expect_referenced_by_name"):
            value = state.pop(key, {})
            if value:
                out[key] = [[k, self.ref(v)] for k, v in value.items()]
        if state:
            raise InterchangeError(f"<{node.tagname}>: unsupported internal state {sorted(state)}")
        return out

    def details(self, details: dict) -> dict:
        """Details of a ``pending`` element (or transform kwargs), by sorted key."""
        out = {}
        for key, value in sorted(details.items()):
            if isinstance(value, nodes.Node):
                out[key] = {"node": self.ref(value)}
            elif isinstance(value, list) and value and all(isinstance(v, nodes.Node)
                                                           for v in value):
                out[key] = {"nodes": self.refs(value)}
            elif isinstance(value, list) and not all(isinstance(v, str) for v in value):
                raise InterchangeError(f"pending detail {key}: list items are not all str")
            elif value is None or isinstance(value, (str, bool, int, list)):
                out[key] = value
            else:
                name = type(value).__name__
                raise InterchangeError(f"pending detail {key}: unsupported type {name}")
        return out

    def detached_records(self) -> list:
        out = []
        i = 0
        while i < len(self.detached):  # records may discover further detached nodes
            root, parent = self.detached[i]
            out.append({"parent": self.ref(parent), "node": self.record(root)})
            i += 1
        return out


# --- document state -------------------------------------------------------------------

def registry(d: Dumper) -> dict:
    doc = d.document
    out: dict = {
        "ids": [[k, d.ref(v)] for k, v in doc.ids.items()],
        "nameids": [[k, v] for k, v in doc.nameids.items()],
        "nametypes": [[k, bool(v)] for k, v in doc.nametypes.items()],
        "substitution_defs": [[k, d.ref(v)] for k, v in doc.substitution_defs.items()],
        "substitution_names": [[k, v] for k, v in doc.substitution_names.items()],
        "id_counter": [[k, v] for k, v in doc.id_counter.items()],
        "autofootnote_start": doc.autofootnote_start,
        "symbol_footnote_start": doc.symbol_footnote_start,
        "decoration": d.ref(doc.decoration),
        "current_source": doc.current_source,
        "current_line": doc.current_line,
    }
    for name in NODE_LIST_MAPS:
        out[name] = [[k, d.refs(v)] for k, v in getattr(doc, name).items()]
    for name in NODE_LISTS:
        out[name] = d.refs(getattr(doc, name))
    return out


def transformer(d: Dumper) -> dict:
    t = d.document.transformer
    queue = []
    for priority, cls, pending, kwargs in sorted(t.transforms, key=lambda x: x[0]):
        name = f"{cls.__module__}.{cls.__name__}"
        queue.append([priority, name, d.ref(pending), d.details(kwargs)])
    return {"queue": queue, "serialno": t.serialno}


def observer_name(observer) -> str:
    name = getattr(observer, "__name__", "")
    if getattr(observer, "__self__", None) is not None and name in (
            "note_parse_message", "note_transform_message"):
        return name
    raise InterchangeError(f"unsupported reporter observer {observer!r}")


def source_lines(reporter) -> dict | None:
    """The line map behind ``Reporter.get_source_and_line`` (the state machine's
    ``input_lines`` as runs of consecutive offsets)."""
    hook = getattr(reporter, "get_source_and_line", None)
    sm = getattr(hook, "__self__", None)
    if hook is None:
        return None
    if sm is None or getattr(sm, "input_lines", None) is None:
        raise InterchangeError(f"unsupported get_source_and_line hook {hook!r}")
    runs: list[list] = []
    for src, offset in sm.input_lines.items:
        last = runs[-1] if runs else None
        if last and last[0] == src and last[1] + last[2] == offset:
            last[2] += 1
        else:
            runs.append([src, offset, 1])
    return {"input_offset": sm.input_offset, "line_offset": sm.line_offset, "runs": runs}


def reporter_state(d: Dumper) -> dict:
    r = d.document.reporter
    written = [{"level": level, "node": d.ref(msg), "text": text}
               for rep, level, msg, text in _WRITTEN if rep is r]
    return {"source": str(r.source), "report_level": r.report_level,
            "halt_level": r.halt_level, "debug": bool(r.debug_flag),
            "max_level": r.max_level, "observers": [observer_name(o) for o in r.observers],
            "source_lines": source_lines(r), "written": written}


def snapshot(document: nodes.document, stage: str, run_input: dict) -> dict:
    """The JSON object of ``document`` now (everything is converted immediately:
    later transforms mutate the document)."""
    d = Dumper(document)
    out = {"format": FORMAT, "stage": stage, "input": run_input, "tree": d.tree,
           "registry": registry(d), "transformer": transformer(d),
           "reporter": reporter_state(d), "settings": settings_dict(document.settings),
           "expected": {"pformat": document.pformat()}}
    out["detached"] = d.detached_records()
    return out


# --- driving docutils -------------------------------------------------------------------

def publish_stages(text: str, source_path: str, writer: str, overrides: dict,
                   stages=STAGES) -> dict[str, dict]:
    """Run docutils as ``Publisher.publish`` does and snapshot the requested stages.
    Python warnings about settings (deprecations, future defaults) are silenced."""
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", DeprecationWarning)
        warnings.simplefilter("ignore", FutureWarning)
        return _publish_stages(text, source_path, writer, overrides, stages)


def _publish_stages(text, source_path, writer, overrides, stages) -> dict[str, dict]:
    _WRITTEN.clear()
    settings_overrides = {"_disable_config": True, **overrides, "warning_stream": _Capture()}
    pub = core.Publisher("standalone", "restructuredtext", writer,
                         source_class=dio.StringInput, destination_class=dio.StringOutput)
    pub.process_programmatic_settings(None, settings_overrides, None)
    pub.set_source(text, source_path)
    pub.set_destination(None, None)
    pub.set_io()
    run_input = {"source_path": source_path, "writer": writer, "overrides": overrides}
    document = pub.reader.read(pub.source, pub.parser, pub.settings)
    pub.document = document
    document.transformer.populate_from_components(
        (pub.source, pub.reader, pub.reader.parser, pub.writer, pub.destination))
    out = {}
    if "parsed" in stages:
        out["parsed"] = snapshot(document, "parsed", run_input)
    document.transformer.apply_transforms()
    for stage in ("transformed", "output"):
        if stage in stages:
            out[stage] = snapshot(document, stage, run_input)
    if "output" in stages:
        output = pub.writer.write(document, pub.destination)
        pub.writer.assemble_parts()
        if isinstance(output, bytes):
            output = output.decode(pub.settings.output_encoding)
        parts = {k: v for k, v in pub.writer.parts.items() if isinstance(v, str)}
        out["output"]["expected"].update(output=output, parts=parts)
    return out


def dumps(data: dict) -> str:
    """The canonical text of a dump (``doctree.dump_json`` writes the same)."""
    return json.dumps(data, sort_keys=True, indent=1, ensure_ascii=False) + "\n"


DOCUTILS_DIR = str(Path(docutils.__file__).resolve().parent)


def portable(text: str) -> str:
    """``text`` with the docutils installation directory (in the sources of the
    standard includes and in ``stylesheet_dirs``) replaced by ``<docutils>``."""
    return text.replace(DOCUTILS_DIR, "<docutils>")


def parse_setting(item: str) -> tuple[str, object]:
    key, sep, value = item.partition("=")
    if not sep:
        raise argparse.ArgumentTypeError(f"--set expects KEY=VALUE, got {item!r}")
    try:
        return key, json.loads(value)
    except json.JSONDecodeError:
        return key, value


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("file", nargs="?", default="-", help="reST source ('-': stdin)")
    ap.add_argument("--stage", choices=STAGES, default="transformed")
    ap.add_argument("--writer", default="pseudoxml", help="docutils writer name")
    ap.add_argument("--set", dest="settings", action="append", default=[],
                    type=parse_setting, metavar="KEY=VALUE",
                    help="settings override (VALUE as JSON, else a string)")
    ap.add_argument("--source-path", help="source path recorded in the document")
    ap.add_argument("--portable", action="store_true",
                    help="write the docutils installation directory as <docutils>")
    ap.add_argument("-o", "--output", help="output file (default: stdout)")
    args = ap.parse_args(argv)
    if args.file == "-":
        text, path = sys.stdin.read(), args.source_path or "<stdin>"
    else:
        text, path = Path(args.file).read_text(encoding="utf-8"), args.source_path or args.file
    data = publish_stages(text, path, args.writer, dict(args.settings), (args.stage,))
    out = dumps(data[args.stage])
    if args.portable:
        out = portable(out)
    if args.output:
        Path(args.output).write_text(out, encoding="utf-8")
    else:
        sys.stdout.write(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
