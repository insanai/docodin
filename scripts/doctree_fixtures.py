"""Generate the differential fixtures of the native doctree (``odin/doctree/tests``).

The fixtures come from real docutils (the one installed in ``.venv``):

``unicode.json``
    ``make_id``, ``fully_normalize_name``, ``whitespace_normalize_name``,
    ``repr`` and ``splitlines`` of every code point (in blocks) and of random
    strings.

``trees.json``
    Scenarios: lists of operations on the ``docutils.nodes`` API (element
    creation, tree mutation, attributes, registration with the ``document``,
    system messages, traversal, validation) executed here while they are
    generated.  Operations that observe state (``pformat``, ``registry``,
    ``written``, ``findall`` ...) carry the value docutils produced; the Odin
    tests replay the operations through the ``doctree`` API and compare.

Run from the repository root:

    uv run python scripts/doctree_fixtures.py
"""

from __future__ import annotations

import importlib
import io
import json
import random
import sys
import unicodedata
import warnings
from pathlib import Path

from docutils import frontend, nodes, utils

OUT = Path(__file__).resolve().parent.parent / "odin" / "doctree" / "tests" / "fixtures"

# --- strings -------------------------------------------------------------------

POOLS = [
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789",
    " \t\n\r\x0b\x0c\x1c\x1d\x1e\x1f\x85\xa0     　",
    "-_.:;,!?'\"`~@#$%^&*()[]{}<>/\\|+=",
    "".join(chr(c) for c in range(0x80, 0x250)),
    "ΑΒΓΣσςΩαβγωΆΈΉͅ­̧̀́'.:·",
    "АБВГДЁЖабвгдёж",
    "İıẞßæÆœŒǸǹȸȹøØđĐħĦłŁ",
    "".join(chr(c) for c in range(0xFF01, 0xFF5F)),
    "".join(chr(c) for c in range(0x1D400, 0x1D4FF)),
    "ﬀﬁﬂﬃﬄﬅﬆ①②③⑴⑵⒈Ⓐⓐ¹²³⁴ⁿ₀₁ⅠⅡⅢⅰⅱ㎏㎡㍱",
    "中文日本語한국어あア",
    "​‌‍‎‏﻿⁠͸\U0010fffd\U0001f600",
    "\x00\x01\x07\x7f",
]


def random_string(rng: random.Random) -> str:
    parts = []
    for _ in range(rng.randint(1, 5)):
        pool = rng.choice(POOLS)
        parts.append("".join(rng.choice(pool) for _ in range(rng.randint(1, 6))))
    return "".join(parts)


def fnv1a64(s: str) -> str:
    h = 0xCBF29CE484222325
    for b in s.encode("utf-8", "surrogatepass"):
        h = ((h ^ b) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return f"{h:016x}"


def string_case(s: str) -> list:
    return [s, nodes.make_id(s), nodes.fully_normalize_name(s),
            nodes.whitespace_normalize_name(s), repr(s), s.splitlines(True), s.lower()]


def block(lo: int, hi: int) -> str:
    """The code points ``lo`` to ``hi`` (exclusive) without surrogates."""
    return "".join(chr(c) for c in range(lo, hi) if not 0xD800 <= c <= 0xDFFF)


def block_case(lo: int, hi: int) -> list:
    """Expected values of a block; long outputs as FNV-1a hashes (the Odin test
    builds the same block)."""
    s = block(lo, hi)
    return [lo, hi, nodes.make_id(s), fnv1a64(nodes.fully_normalize_name(s)),
            fnv1a64(nodes.whitespace_normalize_name(s)), fnv1a64(repr(s)),
            fnv1a64("\x00".join(s.splitlines(True)))]


def unicode_fixture(rng: random.Random) -> dict:
    blocks = [block_case(lo, lo + 128) for lo in range(0, 0x30000, 128)]
    blocks += [block_case(0xE0000, 0xE0200), block_case(0xF0000, 0xF0100),
               block_case(0x10FF00, 0x110000)]
    randoms = [string_case(random_string(rng)) for _ in range(3000)]
    sigma = [string_case(s) for s in (
        "ΣΑΣ", "Σ", "αΣ", "αΣβ", "Α'Σ", "Α\u0345Σ", "Α.Σ.", "ΑΣ\u00adΑ", "ΣΣ", "a Σ b",
        "ΑΣ'",
    )]
    return {"unicode": unicodedata.unidata_version, "python": sys.version.split()[0],
            "blocks": blocks, "strings": randoms + sigma}


# --- scenarios -----------------------------------------------------------------

def desc(node) -> str:
    if node is None:
        return "None"
    if isinstance(node, nodes.Text):
        return "#text:" + str(node)
    return node.starttag()


def dump_registry(doc: nodes.document) -> str:
    out: list[str] = []

    def section(title, mapping, fmt):
        out.append(title + ":")
        out.extend(f"  {k} -> {fmt(v)}" for k, v in mapping.items())

    def node_list(values):
        return "[" + ", ".join(desc(v) for v in values) + "]"

    section("ids", doc.ids, desc)
    section("nameids", doc.nameids, str)
    section("nametypes", doc.nametypes, str)
    section("refnames", doc.refnames, node_list)
    section("refids", doc.refids, node_list)
    section("substitution_defs", doc.substitution_defs, desc)
    section("substitution_names", doc.substitution_names, str)
    section("footnote_refs", doc.footnote_refs, node_list)
    section("citation_refs", doc.citation_refs, node_list)
    section("id_counter", doc.id_counter, str)
    for name in ("indirect_targets", "autofootnotes", "autofootnote_refs", "symbol_footnotes",
                 "symbol_footnote_refs", "footnotes", "citations", "parse_messages",
                 "transform_messages"):
        out.append(f"{name}: {node_list(getattr(doc, name))}")
    queue = [f"{p} {t.__module__}.{t.__name__} {desc(n)}"
             for p, t, n, _ in doc.transformer.transforms]
    out.append("pending: [" + ", ".join(queue) + "]")
    out.append(f"current: {doc.current_source} {doc.current_line}")
    return "\n".join(out) + "\n"


def resolve_transform(qualname: str):
    module, _, name = qualname.rpartition(".")
    return getattr(importlib.import_module(module), name)


class Runner:
    """Executes scenario operations on docutils, recording them."""

    def __init__(self) -> None:
        self.vars: dict[str, object] = {}
        self.ops: list[list] = []
        self.stream = io.StringIO()
        self.doc: nodes.document | None = None
        self.halted = False

    def run(self, *op) -> object:
        op = list(op)
        result = getattr(self, "op_" + op[0])(*op[1:])
        self.ops.append(op)
        return result

    def expect(self, kind: str, *args) -> None:
        try:
            value = getattr(self, "get_" + kind)(*args)
        except (TypeError, AttributeError):  # e.g. astext() with a non-str "alt"
            return
        self.ops.append([kind, *args, value])

    def v(self, name):
        return None if name is None else self.vars[name]

    # construction
    def op_doc(self, source, opts) -> None:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            settings = frontend.get_default_settings()
        settings.warning_stream = self.stream
        for k, val in opts.items():
            setattr(settings, k, val)
        self.doc = utils.new_document(source, settings)
        self.vars["doc"] = self.doc

    def op_elem(self, var, tag, rawsource, text) -> None:
        cls = getattr(nodes, tag)
        if issubclass(cls, nodes.TextElement):
            self.vars[var] = cls(rawsource, text)
        else:
            self.vars[var] = cls(rawsource)

    def op_text(self, var, data) -> None:
        self.vars[var] = nodes.Text(data)

    def op_pending(self, var, qualname, _priority, details) -> None:
        det = {k: self.vars[v["node"]] if isinstance(v, dict) else v for k, v in details.items()}
        self.vars[var] = nodes.pending(resolve_transform(qualname), det)

    def op_msg(self, var, level, text, opts) -> None:
        kw = {k: self.v(val) if k == "base_node" else val for k, val in opts.items()}
        try:
            self.vars[var] = self.doc.reporter.system_message(level, text, **kw)
        except utils.SystemMessage:
            self.halted = True
            self.vars[var] = None

    # tree
    def op_append(self, p, c) -> None:
        self.v(p).append(self.v(c))

    def op_insert(self, p, i, c) -> None:
        self.v(p).insert(i, self.v(c))

    def op_remove(self, p, c) -> None:
        self.v(p).remove(self.v(c))

    def op_replace(self, p, old, new) -> None:
        self.v(p).replace(self.v(old), self.v(new))

    def op_replace_self(self, n, news) -> None:
        self.v(n).replace_self([self.v(x) for x in news])

    def op_pop(self, p, i) -> None:
        self.v(p).pop(i)

    def op_copy(self, var, n) -> None:
        self.vars[var] = self.v(n).copy()

    def op_deepcopy(self, var, n) -> None:
        self.vars[var] = self.v(n).deepcopy()

    # attributes
    def op_set(self, n, key, value) -> None:
        self.v(n)[key] = list(value) if isinstance(value, list) else value

    def op_listappend(self, n, key, value) -> None:
        self.v(n)[key].append(value)

    def op_del(self, n, key) -> None:
        self.v(n).delattr(key)

    def op_update_basic(self, n, other) -> None:
        self.v(n).update_basic_atts(self.v(other))

    # registry
    def op_setid(self, n, msgnode, suggested) -> None:
        self.doc.set_id(self.v(n), self.v(msgnode), suggested)

    def op_target(self, n, msgnode, explicit) -> None:
        if explicit:
            self.doc.note_explicit_target(self.v(n), self.v(msgnode))
        else:
            self.doc.note_implicit_target(self.v(n), self.v(msgnode))

    def op_note(self, kind, n) -> None:
        getattr(self.doc, "note_" + kind)(self.v(n))

    def op_subdef(self, n, name, msgnode) -> None:
        self.doc.note_substitution_def(self.v(n), name, self.v(msgnode))

    def op_subref(self, n, refname) -> None:
        self.doc.note_substitution_ref(self.v(n), refname)

    def op_note_pending(self, n, priority) -> None:
        self.doc.note_pending(self.v(n), priority)

    def op_note_source(self, source, offset) -> None:
        self.doc.note_source(source, offset)

    def op_decoration(self, var) -> None:
        self.vars[var] = self.doc.get_decoration()

    def op_findall_mutate(self, start, tags, action, _expected=None) -> None:
        cond = condition(tags or None)
        seen = []
        for node in self.v(start).findall(cond):
            seen.append(desc(node))
            if len(seen) >= 200:
                break
            mutate(node, action)
        self.ops.append(["findall_mutate", start, tags, action, seen])
        self.ops.append(["pformat", "doc", self.doc.pformat()])

    # observations
    def get_pformat(self, n) -> str:
        return self.v(n).pformat()

    def get_astext(self, n) -> str:
        return self.v(n).astext()

    def get_registry(self) -> str:
        return dump_registry(self.doc)

    def get_written(self) -> str:
        return self.stream.getvalue()

    def get_halted(self) -> bool:
        return self.halted

    def get_desc(self, n) -> str:
        return desc(self.v(n))

    def get_findall(self, n, tags, include_self, descend, siblings, ascend) -> list[str]:
        cond = condition(tags)
        found = []
        try:  # a removed node's stale parent makes docutils raise; the Odin iterator ends
            for x in self.v(n).findall(cond, include_self, descend, siblings, ascend):
                found.append(desc(x))
        except ValueError:
            pass
        return found

    def get_index(self, p, c) -> int:
        try:
            return self.v(p).index(self.v(c))
        except ValueError:
            return -1

    def get_first_matching(self, p, tags, start) -> int:
        cls = tuple(getattr(nodes, t) for t in tags)
        found = self.v(p).first_child_matching_class(cls, start)
        return -1 if found is None else found

    def get_first_not_matching(self, p, tags, start) -> int:
        cls = tuple(getattr(nodes, t) for t in tags)
        found = self.v(p).first_child_not_matching_class(cls, start)
        return -1 if found is None else found

    def get_section_hierarchy(self, n) -> list[str]:
        return [desc(s) for s in self.v(n).section_hierarchy()]

    def get_validate(self, n, recursive) -> list:
        try:
            self.v(n).validate(recursive)
        except nodes.ValidationError as e:
            return [False, str(e), desc(e.problematic_element)]
        return [True, "", "None"]

    def get_source_line(self, n) -> list:
        return list(utils.get_source_line(self.v(n)))


def condition(tags):
    if tags is None:
        return None
    classes = tuple(getattr(nodes, t) for t in tags)
    return lambda node: isinstance(node, classes)


def mutate(node, action: str) -> None:
    parent = node.parent
    if action == "remove" and parent is not None and node in parent.children:
        parent.remove(node)
    elif action == "replace2" and isinstance(node, nodes.Element) and parent is not None \
            and node in parent.children and not isinstance(node, nodes.strong):
        node.replace_self([nodes.strong("", "a"), nodes.strong("", "b")])
    elif action == "grow" and isinstance(node, nodes.Element) \
            and not isinstance(node, (nodes.inline, nodes.document)):
        node.append(nodes.inline("", "x"))
    elif action == "before" and parent is not None and node in parent.children \
            and not isinstance(node, nodes.emphasis):
        parent.insert(parent.index(node), nodes.emphasis("", "e"))


# --- scenario builders -----------------------------------------------------------

CONTAINERS = ["section", "block_quote", "paragraph", "footnote", "citation", "bullet_list",
              "list_item", "field_body", "sidebar", "topic", "admonition", "table"]
LEAVES = ["target", "paragraph", "title", "subtitle", "footnote", "footnote_reference",
          "citation_reference", "reference", "substitution_definition", "literal_block",
          "image", "option_argument", "option_string", "transition", "comment", "emphasis",
          "inline", "raw", "math", "label", "rubric", "field_name", "meta", "system_message"]
NAMES = ["intro", "Intro", "a  b", "a b", "1st", "2", "x", "émigré", "Straße", "ΑΣ", "日本",
         "hello world", "@", "-", "_", "id1", "section-1", "ⅰ ⅱ", "ﬁle", "İstanbul"]
KEYS = ["refuri", "refname", "refid", "anonymous", "auto", "title", "width", "alt",
        "delimiter", "level", "format", "dupnames", "classes", "bogus", "internal:x", "xml:space"]
VALUES = ["", "x", "http://x", "Foo", "a  b", "50 %", "007px", "1.50em", "-1", "1.2.3", "*",
          0, 1, 7, True, False, None, ["a", "b c"], ["Foo"], []]
TRANSFORMS = ["docutils.transforms.parts.Contents", "docutils.transforms.references.Footnotes",
              "docutils.transforms.misc.ClassAttribute", "docutils.transforms.universal.Messages"]


class Builder:
    def __init__(self, rng: random.Random, r: Runner) -> None:
        self.rng, self.r = rng, r
        self.count = 0
        self.elements: list[str] = []
        self.containers: list[str] = ["doc"]

    def fresh(self) -> str:
        self.count += 1
        return f"n{self.count}"

    def new_element(self, tag: str) -> str:
        var = self.fresh()
        if tag == "system_message":  # below the halt level
            level = self.rng.randint(0, min(self.r.doc.reporter.halt_level - 1, 4))
            self.r.run("msg", var, level, self.rng.choice(["", "boom", "a\nb"]),
                       {"backrefs": ["id1"]} if self.rng.random() < 0.3 else {})
            self.elements.append(var)
            return var
        text = self.rng.choice(["", "some text", "a\\ b", "x\x00 y\x00z", "line1\nline2"])
        self.r.run("elem", var, tag, self.rng.choice(["", "raw"]), text)
        self.elements.append(var)
        if tag in CONTAINERS or tag == "document":
            self.containers.append(var)
        return var

    def attach(self, var: str) -> None:
        rng = self.rng
        parent = rng.choice(self.containers)
        if parent == var or self.is_ancestor(var, parent):
            return
        if rng.random() < 0.8 or not len(self.r.vars[parent]):
            self.r.run("append", parent, var)
        else:
            self.r.run("insert", parent, rng.randint(-2, len(self.r.vars[parent]) + 1), var)

    def is_ancestor(self, a: str, b: str) -> bool:
        node = self.r.vars[b]
        target = self.r.vars[a]
        while node is not None:
            if node is target:
                return True
            node = node.parent
        return False

    def names(self, var: str) -> None:
        for _ in range(self.rng.randint(0, 2)):
            self.r.run("listappend", var, "names",
                       nodes.fully_normalize_name(self.rng.choice(NAMES)))

    def register(self, var: str) -> None:
        rng, r = self.rng, self.r
        msgnode = rng.choice([None, None, "doc"] + self.containers[-3:])
        kind = rng.random()
        node = r.vars[var]
        if isinstance(node, nodes.Text):
            return
        if kind < 0.45:
            if rng.random() < 0.2:  # unique: a duplicate would make docutils crash later
                r.run("listappend", var, "ids", f"pre-{var}")
            r.run("target", var, msgnode, rng.random() < 0.5)
        elif kind < 0.6:
            if rng.random() < 0.5:
                r.run("listappend", var, "ids", rng.choice(["id1", "intro", "x", "dup"]))
            r.run("setid", var, msgnode, rng.choice(["", "", "fn"]))
        elif kind < 0.8:
            self.note(var, node)
        else:
            name = rng.choice(NAMES)  # the rST parser adds the name first
            r.run("listappend", var, "names", nodes.whitespace_normalize_name(name))
            r.run("subdef", var, name, msgnode)

    def note(self, var: str, node) -> None:
        kinds = ["anonymous_target", "autofootnote", "autofootnote_ref", "symbol_footnote",
                 "symbol_footnote_ref", "footnote", "citation", "parse_message",
                 "transform_message"]
        if isinstance(node.get("refname"), str):
            kinds += ["refname", "footnote_ref", "citation_ref", "indirect_target"]
        if isinstance(node.get("refid"), str):
            kinds.append("refid")
        self.r.run("note", self.rng.choice(kinds), var)

    def set_attrs(self, var: str) -> None:
        for _ in range(self.rng.randint(0, 2)):
            key = self.rng.choice(KEYS)
            value = self.rng.choice(VALUES)
            if key in ("dupnames", "classes"):
                value = self.rng.choice([["a"], ["Foo", "b  c"], []])
            self.r.run("set", var, key, value)


def build_random(rng: random.Random, index: int) -> dict:
    r = Runner()
    opts = {"id_prefix": rng.choice(["", "", "p-", "X"]),
            "auto_id_prefix": rng.choice(["%", "%", "id", "auto-"]),
            "report_level": rng.randint(0, 5), "halt_level": rng.choice([4, 5])}
    if rng.random() < 0.3:
        opts["detailed"] = True
    r.run("doc", rng.choice(["test.rst", "<string>"]), opts)
    b = Builder(rng, r)
    for _ in range(rng.randint(5, 30)):
        step(b)
    base = rng.choice(b.elements) if b.elements else None
    r.run("msg", b.fresh(), rng.randint(0, 4), "final", {"base_node": base, "line": 7}
          if rng.random() < 0.3 else {"base_node": base})
    finish(b)
    return {"name": f"random-{index}", "ops": r.ops}


def step(b: Builder) -> None:
    rng, r = b.rng, b.r
    choice = rng.random()
    if choice < 0.1:
        r.run("note_source", rng.choice(["test.rst", "other.rst", None]),
              rng.choice([None, 0, 4, 10]))
    elif choice < 0.15:
        var = b.fresh()
        r.run("text", var, rng.choice(["plain", "esc\x00 aped", "multi\nline\r\nend\x85x"]))
        b.elements.append(var)
        b.attach(var)
        return
    elif choice < 0.2 and b.elements:
        mutate_step(b)
        return
    tag = rng.choice(CONTAINERS + LEAVES)
    var = b.new_element(tag)
    b.set_attrs(var)
    b.names(var)
    if rng.random() < 0.85:
        b.attach(var)
    if rng.random() < 0.6 and tag != "system_message":
        b.register(var)


def mutate_step(b: Builder) -> None:
    rng, r = b.rng, b.r
    var = rng.choice(b.elements)
    node = r.vars[var]
    parent = node.parent
    kind = rng.random()
    if parent is None or node not in parent.children:
        return
    pvar = next((k for k, x in r.vars.items() if x is parent), None)
    if pvar is None:
        return
    if kind < 0.3:
        r.run("remove", pvar, var)
    elif kind < 0.6 and isinstance(node, nodes.Element):
        new = b.new_element(rng.choice(["paragraph", "strong", "section"]))
        r.run("replace_self", var, [new])
    elif kind < 0.8:
        new = b.new_element("emphasis")
        r.run("replace", pvar, var, new)
    else:
        r.run("pop", pvar, rng.choice([-1, 0]))


def finish(b: Builder) -> None:
    rng, r = b.rng, b.r
    r.expect("registry")
    r.expect("written")
    r.expect("halted")
    sample = rng.sample(b.elements, min(len(b.elements), 6))
    for var in sample:
        r.expect("astext", var)
        r.expect("desc", var)
        if isinstance(r.vars[var], nodes.Element):
            r.expect("section_hierarchy", var)
        r.expect("source_line", var)
        tags = rng.choice([None, ["Text"], ["paragraph", "target"], ["section"], ["Body"]])
        r.expect("findall", var, tags, rng.random() < 0.5, rng.random() < 0.7,
                 rng.random() < 0.5, rng.random() < 0.5)
    for var in rng.sample(b.containers, min(len(b.containers), 3)):
        r.expect("first_matching", var, ["paragraph", "Text", "title"], rng.randint(0, 2))
        r.expect("first_not_matching", var, ["title", "subtitle"], 0)
        r.expect("validate", var, False)
        if b.elements:
            r.expect("index", var, rng.choice(b.elements))
    r.expect("validate", "doc", True)
    r.expect("pformat", "doc")


def build_mutation(rng: random.Random, index: int) -> dict:
    r = Runner()
    r.run("doc", "m.rst", {})
    b = Builder(rng, r)
    for _ in range(rng.randint(5, 25)):
        tag = rng.choice(CONTAINERS + LEAVES[:-1])
        b.attach(b.new_element(tag))
    r.expect("pformat", "doc")
    start = rng.choice(["doc"] + b.containers)
    tags = rng.choice([[], ["paragraph"], ["Text"], ["section", "paragraph", "target"]])
    r.op_findall_mutate(start, tags, rng.choice(["remove", "replace2", "grow", "before"]))
    return {"name": f"mutation-{index}", "ops": r.ops}


def build_copies(rng: random.Random, index: int) -> dict:
    r = Runner()
    r.run("doc", "c.rst", {"detailed": rng.random() < 0.5})
    b = Builder(rng, r)
    for _ in range(12):
        var = b.new_element(rng.choice(CONTAINERS + LEAVES[:-1]))
        b.set_attrs(var)
        b.names(var)
        b.attach(var)
    for var in rng.sample(b.elements, 4):
        cp = b.fresh()
        r.run(rng.choice(["copy", "deepcopy"]), cp, var)
        r.expect("pformat", cp)
        r.run("append", "doc", cp)
        other = rng.choice(b.elements)
        if other != var:
            r.run("update_basic", cp, other)
    pend = b.fresh()
    qual = rng.choice(TRANSFORMS)
    det = {"a": "x'y", "b": 3, "c": None, "d": [], "e": ["p", "q"], "f": True,
           "node": {"node": b.elements[0]}}
    r.run("pending", pend, qual, resolve_transform(qual).default_priority, det)
    r.run("append", "doc", pend)
    r.run("note_pending", pend, rng.choice([None, 10]))
    deco = b.fresh()
    r.run("decoration", deco)
    r.expect("pformat", "doc")
    r.expect("registry")
    return {"name": f"copies-{index}", "ops": r.ops}


def build_targets(rng: random.Random, index: int) -> dict:
    """Name registration: implicit/explicit duplicates, external targets, msgnodes."""
    r = Runner()
    r.run("doc", "t.rst", {"id_prefix": rng.choice(["", "p-"]),
                           "auto_id_prefix": rng.choice(["%", "id"]), "report_level": 1})
    b = Builder(rng, r)
    holders = [b.new_element(rng.choice(["section", "paragraph", "block_quote"]))
               for _ in range(3)]
    for h in holders:
        r.run("append", "doc", h)
    for _ in range(rng.randint(4, 14)):
        tag = rng.choice(["target", "target", "section", "footnote", "citation"])
        var = b.new_element(tag)
        r.run("listappend", var, "names", rng.choice(["a", "b", "c d"]))
        if tag == "target" and rng.random() < 0.7:
            key = rng.choice(["refuri", "refname"])
            r.run("set", var, key, rng.choice(["", "http://a", "x", "http://a"]))
        r.run("append", rng.choice(holders), var)
        r.run("target", var, rng.choice([None, "doc"] + holders), rng.random() < 0.6)
    r.expect("pformat", "doc")
    r.expect("registry")
    r.expect("written")
    return {"name": f"targets-{index}", "ops": r.ops}


def main() -> None:
    rng = random.Random(20260927)
    OUT.mkdir(parents=True, exist_ok=True)
    data = unicode_fixture(rng)
    (OUT / "unicode.json").write_text(json.dumps(data, ensure_ascii=False, indent=0) + "\n")
    scenarios = [build_random(rng, i) for i in range(160)]
    scenarios += [build_mutation(rng, i) for i in range(80)]
    scenarios += [build_copies(rng, i) for i in range(30)]
    scenarios += [build_targets(rng, i) for i in range(40)]
    text = json.dumps({"scenarios": scenarios}, ensure_ascii=False, indent=0)
    (OUT / "trees.json").write_text(text + "\n")
    print(f"{len(data['blocks'])} blocks, {len(data['strings'])} strings, "
          f"{len(scenarios)} scenarios")


if __name__ == "__main__":
    main()
