"""Generate the data tables of the native doctree package (``odin/doctree``).

Two tables are generated, each to standard output:

``unicode``
    Unicode data from CPython's ``unicodedata`` and ``str`` methods that
    ``docutils.nodes`` relies on: ``str.lower()`` (with the final-sigma rule),
    ``str.isspace()``, ``str.isprintable()`` (for ``repr()``) and the ASCII
    part of the NFKD decomposition (for ``make_id()``).

``nodes``
    The docutils node classes: tag names, element categories, the
    ``child_text_separator``, list and valid attributes and content models,
    introspected from ``docutils.nodes``.

Run with the interpreter (and docutils version) that docodin mirrors; all
native Unicode tables (see scripts/gen_unicode_tables.py) must come from the
same Unicode version (currently CPython 3.14, Unicode 16):

    PY="uv run --no-project --python 3.14 --with docutils==0.22.4 python"
    $PY scripts/gen_doctree_tables.py unicode > odin/doctree/unicode_tables.odin
    $PY scripts/gen_doctree_tables.py nodes > odin/doctree/node_classes.odin
    $PY scripts/doctree_fixtures.py
"""

from __future__ import annotations

import sys
import unicodedata

from docutils import nodes

MAX_COLS = 96


def all_chars():
    for cp in range(sys.maxunicode + 1):
        if not 0xD800 <= cp <= 0xDFFF:
            yield cp, chr(cp)


def ranges(pred) -> list[tuple[int, int]]:
    out: list[tuple[int, int]] = []
    start = None
    for cp in range(sys.maxunicode + 1):
        ok = not 0xD800 <= cp <= 0xDFFF and pred(chr(cp))
        if ok and start is None:
            start = cp
        elif not ok and start is not None:
            out.append((start, cp - 1))
            start = None
    if start is not None:
        out.append((start, sys.maxunicode))
    return out


def emit_items(decl: str, items: list[str]) -> None:
    print(f"@(rodata)\n{decl}{{")
    line = "\t"
    for item in items:
        if len(line) + len(item) + 1 > MAX_COLS - 4:
            print(line.rstrip())
            line = "\t"
        line += item + " "
    if line.strip():
        print(line.rstrip())
    print("}\n")


def emit_ranges(name: str, rs: list[tuple[int, int]]) -> None:
    emit_items(f"{name} := [?][2]rune", [f"{{0x{lo:X}, 0x{hi:X}}}," for lo, hi in rs])


def odin_str(s: str) -> str:
    out = []
    for c in s:
        if c in '"\\':
            out.append("\\" + c)
        elif " " <= c < "\x7f":
            out.append(c)
        else:
            out.append(f"\\u{ord(c):04X}" if ord(c) < 0x10000 else f"\\U{ord(c):08X}")
    return '"' + "".join(out) + '"'


# --- str.lower() ------------------------------------------------------------

def lower_runs() -> tuple[list[tuple[int, int, int, int]], list[tuple[int, str]]]:
    """Runs (lo, hi, stride, delta) of 1:1 lowercase mappings plus the 1:n ones."""
    single: dict[int, int] = {}
    multi: list[tuple[int, str]] = []
    for cp, c in all_chars():
        low = c.lower()
        if low == c:
            continue
        if len(low) == 1:
            single[cp] = ord(low) - cp
        else:
            multi.append((cp, low))
    runs: list[tuple[int, int, int, int]] = []
    cps = sorted(single)
    i = 0
    while i < len(cps):
        lo = cps[i]
        delta = single[lo]
        stride = 1 if single.get(lo + 1) == delta else 2
        hi = lo
        while True:
            nxt = hi + stride
            gap_free = stride == 1 or (hi + 1) not in single
            if single.get(nxt) == delta and gap_free:
                hi = nxt
            else:
                break
        if hi == lo:
            stride = 1
        runs.append((lo, hi, stride, delta))
        i = cps.index(hi) + 1
    return runs, multi


def final_sigma_classes() -> tuple[list[tuple[int, int]], list[tuple[int, int]]]:
    """Derive CPython's ``_PyUnicode_IsCased``/``IsCaseIgnorable`` from ``lower()``.

    cased' = lower(c + 'Σ') ends with 'ς'  (cased and not case-ignorable)
    either = lower('A' + c + 'Σ') ends with 'ς'  (case-ignorable or cased)
    ignorable = either and not cased'
    """
    cased: set[int] = set()
    ignorable: set[int] = set()
    for cp, c in all_chars():
        x = (c + "Σ").lower().endswith("ς")
        y = ("A" + c + "Σ").lower().endswith("ς")
        if x:
            cased.add(cp)
        if y and not x:
            ignorable.add(cp)
    return (ranges(lambda c: ord(c) in cased), ranges(lambda c: ord(c) in ignorable))


# --- NFKD, ASCII part ---------------------------------------------------------

def nfkd_ascii() -> tuple[list[tuple[int, int, int, int]], list[tuple[int, str]]]:
    """Runs (lo, hi, first, step) of single ASCII characters and the longer ones."""
    single: dict[int, int] = {}
    multi: list[tuple[int, str]] = []
    for cp, c in all_chars():
        if cp < 0x80:
            continue
        a = unicodedata.normalize("NFKD", c).encode("ascii", "ignore").decode("ascii")
        if len(a) == 1:
            single[cp] = ord(a)
        elif a:
            multi.append((cp, a))
    runs: list[tuple[int, int, int, int]] = []
    cps = sorted(single)
    i = 0
    while i < len(cps):
        lo = cps[i]
        first = single[lo]
        step = 1 if single.get(lo + 1) == first + 1 else 0
        hi = lo
        while single.get(hi + 1) == first + step * (hi + 1 - lo):
            hi += 1
        runs.append((lo, hi, first, step if hi > lo else 0))
        i += hi - lo + 1
    return runs, multi


def main_unicode() -> None:
    print("// Code generated by scripts/gen_doctree_tables.py unicode; DO NOT EDIT.")
    print(f"// Unicode {unicodedata.unidata_version}, CPython {sys.version.split()[0]}.")
    print("package doctree\n")
    emit_ranges("SPACE_RANGES", ranges(str.isspace))
    emit_ranges("NONPRINTABLE_RANGES", ranges(lambda c: not c.isprintable()))
    cased, ignorable = final_sigma_classes()
    emit_ranges("CASED_RANGES", cased)
    emit_ranges("CASE_IGNORABLE_RANGES", ignorable)
    runs, multi = lower_runs()
    emit_items("LOWER_RUNS := [?]Lower_Run",
               [f"{{0x{lo:X}, 0x{hi:X}, {s}, {d}}}," for lo, hi, s, d in runs])
    emit_items("LOWER_MULTI := [?]Rune_String",
               [f"{{0x{cp:X}, {odin_str(s)}}}," for cp, s in multi])
    runs, multi = nfkd_ascii()
    emit_items("NFKD_ASCII_RUNS := [?]Ascii_Run",
               [f"{{0x{lo:X}, 0x{hi:X}, {f}, {s}}}," for lo, hi, f, s in runs])
    emit_items("NFKD_ASCII_MULTI := [?]Rune_String",
               [f"{{0x{cp:X}, {odin_str(s)}}}," for cp, s in multi])


# --- node classes -------------------------------------------------------------

CATEGORIES = [
    "Element", "TextElement", "FixedTextElement", "PureTextElement", "Root", "Structural",
    "SubStructural", "Body", "General", "Sequential", "Admonition", "Special", "Invisible",
    "Part", "Inline", "Titular", "PreBibliographic", "Bibliographic", "Decorative",
    "Labeled", "Resolvable", "Referential", "Targetable", "BackLinkable",
]
BASIC_LISTS = ["ids", "classes", "names", "dupnames", "backrefs"]


def node_classes() -> list[type]:
    # The generic ``nodes.Element`` comes last: directives use it as a dummy
    # container (``class``, ``replace``).
    return [getattr(nodes, name) for name in nodes.node_class_names] + [nodes.Element]


def class_ref(cls: type) -> tuple[str, str]:
    """('tag'|'cat', name) for a class named in a content model."""
    if cls.__name__ in nodes.node_class_names:
        return "tag", cls.__name__
    assert cls.__name__ in CATEGORIES, cls
    return "cat", cls.__name__


def model_item(category, quantifier: str) -> str:
    classes = category if isinstance(category, tuple) else (category,)
    name = "> or <".join(c.__name__ for c in classes)
    tags = [f".{n}" for k, n in map(class_ref, classes) if k == "tag"]
    cats = [f".{n}" for k, n in map(class_ref, classes) if k == "cat"]
    return (f"{{{{{', '.join(tags)}}}, {{{', '.join(cats)}}}, "
            f"{odin_str(name)}, '{quantifier}'}},")


def check_concrete_classes(classes: list[type]) -> None:
    # isinstance() against a concrete class must be a tag test: no concrete
    # node class may derive from another one.
    concrete = [c for c in classes if c is not nodes.Element]
    for a in concrete:
        for b in concrete:
            assert a is b or not issubclass(a, b), (a, b)


def emit_wrapped(head: str, items: list[str], tail: str) -> None:
    """Print ``head item, item, ... tail``, continuing long lines with two tabs."""
    line = head
    for i, item in enumerate(items):
        text = item + (", " if i + 1 < len(items) else "")
        if len(line.expandtabs(4)) + len(text.rstrip()) + len(tail) > MAX_COLS:
            print(line.rstrip())
            line = "\t\t"
        line += text
    print(line + tail)


def emit_enum(decl: str, names: list[str]) -> None:
    print(f"{decl} {{")
    for n in names:
        print(f"\t{n},")
    print("}\n")


def emit_attribute_tables(classes: list[type]) -> None:
    flat: list[str] = []
    spans: dict[str, tuple[int, int]] = {}
    for cls in classes[1:]:
        key = " ".join(cls.valid_attributes)
        if key not in spans:
            spans[key] = (len(flat), len(cls.valid_attributes))
            flat.extend(cls.valid_attributes)
    emit_items("VALID_ATTR_NAMES := [?]string", [f"{odin_str(a)}," for a in flat])
    print("@(rodata)\nTAG_VALID_ATTRS := [Tag][2]u8{")
    print("\t.Text = {0, 0},")
    for cls in classes[1:]:
        off, n = spans[" ".join(cls.valid_attributes)]
        print(f"\t.{cls.__name__} = {{{off}, {n}}},")
    print("}\n")
    print("@(rodata)\nTAG_LIST_ATTRS := [Tag]Basic_Lists{")
    print("\t.Text = {},")
    for cls in classes[1:]:
        assert set(cls.list_attributes) <= set(BASIC_LISTS), cls
        items = ", ".join(f".{a}" for a in cls.list_attributes)
        print(f"\t.{cls.__name__} = {{{items}}},")
    print("}\n")


def emit_content_models(classes: list[type]) -> None:
    flat: list[str] = []
    spans: dict[str, tuple[int, int]] = {}
    per_class: dict[str, tuple[int, int]] = {}
    for cls in classes[1:]:
        items = [model_item(c, q) for c, q in cls.content_model]
        key = "\n".join(items)
        if key not in spans:
            spans[key] = (len(flat), len(items))
            flat.extend(items)
        per_class[cls.__name__] = spans[key]
    print("@(rodata)\nMODEL_ITEMS := [?]Model_Item{")
    for item in flat:
        if len(item) + 4 > MAX_COLS:  # put the class names on a line of their own
            head, _, tail = item.partition(', "')
            item = f'{head},\n\t\t"{tail}'
        print(f"\t{item}")
    print("}\n")
    print("@(rodata)\nTAG_MODEL := [Tag][2]u8{")
    print("\t.Text = {0, 0},")
    for name, (off, n) in per_class.items():
        print(f"\t.{name} = {{{off}, {n}}},")
    print("}\n")


def main_nodes() -> None:
    import docutils
    classes = node_classes()
    assert classes[0] is nodes.Text
    check_concrete_classes(classes)
    names = [c.__name__ for c in classes]
    print("// Code generated by scripts/gen_doctree_tables.py nodes; DO NOT EDIT.")
    print(f"// docutils {docutils.__version__} (docutils.nodes.node_class_names).")
    print("package doctree\n")
    print("// A docutils node class: ``Text`` plus the element classes.")
    emit_enum("Tag :: enum u8", names)
    print("// A docutils element category (abstract base or mix-in class).")
    emit_enum("Category :: enum u8", CATEGORIES)
    print("@(rodata)\nTAG_NAMES := [Tag]string{")
    for c in classes:
        print(f'\t.{c.__name__} = "{c.tagname if c is nodes.Text else c.__name__}",')
    print("}\n")
    print("@(rodata)\nTAG_CATEGORIES := [Tag]Categories{")
    for c in classes:
        cats = [f".{k}" for k in CATEGORIES if issubclass(c, getattr(nodes, k))]
        emit_wrapped(f"\t.{c.__name__} = {{", cats, "},")
    print("}\n")
    print("@(rodata)\nCATEGORY_TAGS := [Category]Tag_Set{")
    for k in CATEGORIES:
        tags = [f".{c.__name__}" for c in classes if issubclass(c, getattr(nodes, k))]
        emit_wrapped(f"\t.{k} = {{", tags, "},")
    print("}\n")
    print("@(rodata)\nTAG_TEXT_SEPARATOR := [Tag]string{")
    print('\t.Text = "",')
    for c in classes[1:]:
        sep = c.child_text_separator.encode("unicode_escape").decode("ascii")
        print(f'\t.{c.__name__} = "{sep}",')
    print("}\n")
    emit_attribute_tables(classes)
    emit_content_models(classes)


if __name__ == "__main__":
    {"unicode": main_unicode, "nodes": main_nodes}[sys.argv[1]]()
