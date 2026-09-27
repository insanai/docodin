"""Build a docutils document tree from the native parse tree.

The native parser (``odin/rst/``) performs all reStructuredText recognition and
reports every parser warning/error.  This module turns its output into real
``docutils.nodes`` and performs the host-side work of the docutils parser, in
the same order docutils does it:

* registration with the ``document`` (``note_*``/``set_id``: names, ids,
  references, footnotes, citations, substitutions),
* section nesting (``RSTState.check_subsection``/``new_subsection``),
* running directives and interpreted-text roles (Python code registered by
  docutils, Sphinx and extensions) with state/state-machine objects that are
  subclasses of the docutils classes, so directive code behaves identically.
  Their ``nested_parse``/``inline_text`` are routed back to the native parser.
"""

from __future__ import annotations

from types import FunctionType, MethodType
from typing import Any

from docutils import nodes, utils
from docutils.nodes import fully_normalize_name as normalize_name
from docutils.nodes import whitespace_normalize_name
from docutils.parsers.rst import Directive, DirectiveError, directives, roles, states
from docutils.parsers.rst import languages as rst_languages
from docutils.parsers.rst.directives import body as _body_directives
from docutils.parsers.rst.states import Inliner, MarkupError, Struct
from docutils.statemachine import StringList

from docodin import _native
from docodin._machine import (
    OdinBody,
    OdinInliner,
    OdinStateMachine,
    OdinSubstitutionDef,
    _make_state,
    patched_transition,
    replay_transition,
)

# Node kinds, in the order of ``Node_Kind`` in odin/rst/node_kinds.odin.
(K_DOCUMENT, K_SECTION, K_SECTION_TITLE, K_TITLE, K_PARAGRAPH, K_BULLET_LIST,
 K_ENUMERATED_LIST, K_LIST_ITEM, K_DEFINITION_LIST, K_DEFINITION_LIST_ITEM, K_TERM,
 K_CLASSIFIER, K_DEFINITION, K_FIELD_LIST, K_FIELD, K_FIELD_NAME, K_FIELD_BODY,
 K_OPTION_LIST, K_OPTION_LIST_ITEM, K_OPTION_GROUP, K_OPTION, K_OPTION_STRING,
 K_OPTION_ARGUMENT, K_DESCRIPTION, K_LITERAL_BLOCK, K_DOCTEST_BLOCK, K_LINE_BLOCK,
 K_LINE, K_BLOCK_QUOTE, K_ATTRIBUTION, K_TRANSITION, K_TABLE, K_TGROUP, K_COLSPEC,
 K_THEAD, K_TBODY, K_ROW, K_ENTRY, K_FOOTNOTE, K_CITATION, K_LABEL, K_TARGET,
 K_SUBSTITUTION_DEFINITION, K_COMMENT, K_DIRECTIVE, K_INCLUDE_END, K_SYSTEM_MESSAGE,
 K_TEXT, K_EMPHASIS, K_STRONG, K_LITERAL, K_INLINE_TARGET, K_SUBSTITUTION_REFERENCE,
 K_REFERENCE, K_FOOTNOTE_REFERENCE, K_CITATION_REFERENCE, K_INTERPRETED,
 K_PROBLEMATIC) = range(58)
K_COUNT = 128  # >= number of Node_Kind values (odin/rst/node_kinds.odin)

# Ref_Kind (odin/rst/nodes.odin)
REF_SIMPLE, REF_PHRASE, REF_URI, REF_PEP, REF_RFC = range(5)
# Phrase_Info.alias_type
ALIAS_NONE, ALIAS_NAME, ALIAS_URI = range(3)
# Target_Type
TARGET_REFURI, TARGET_REFNAME = range(2)

Text = nodes.Text
# Constructs after which docutils attaches a message it reported before
# parsing the construct's content (see TreeBuilder._early_message).
_EARLY_MESSAGE_KINDS = frozenset((K_PARAGRAPH, K_ENUMERATED_LIST))
_EXPLICIT_UNINDENT = "Explicit markup ends without a blank line; unexpected unindent."


# ---------------------------------------------------------------------------
# fast node construction
#
# ``Element.__init__`` + ``extend()``/``setup_child()`` dominate tree building.
# For a *fresh, unattached* node ``setup_child`` only sets ``child.parent``
# (``document`` is None), so the helpers below build nodes that are
# indistinguishable from constructor-built ones (same attributes, rawsource,
# tagname, parent links).  Nodes are attached to the live tree with docutils'
# own ``append`` so ``document``/``source``/``line`` propagation is unchanged.
# ---------------------------------------------------------------------------

_object_new = object.__new__
_BASE_ATTS = ("ids", "classes", "names", "dupnames")
_BACKLINK_ATTS = _BASE_ATTS + ("backrefs",)
_str_new = str.__new__
_list_atts_cache: dict[type, tuple[str, ...]] = {}


def _text(data: str) -> nodes.Text:
    """``nodes.Text(data)`` (without the bytes/rawsource argument checks)."""
    return _str_new(Text, data)


def _element(cls: type, rawsource: str, children: list) -> Any:
    """``cls(rawsource, *children)`` for classes using ``Element.__init__``."""
    node = _object_new(cls)
    node.rawsource = rawsource
    node.children = children
    for child in children:
        child.parent = node
    atts = _list_atts_cache.get(cls)
    if atts is None:
        atts = _list_atts_cache[cls] = tuple(cls.list_attributes)
    if atts == _BASE_ATTS:
        node.attributes = {"ids": [], "classes": [], "names": [], "dupnames": []}
    elif atts == _BACKLINK_ATTS:
        node.attributes = {"ids": [], "classes": [], "names": [], "dupnames": [], "backrefs": []}
    else:
        node.attributes = {att: [] for att in atts}
    if cls.tagname is None:
        node.tagname = cls.__name__
    return node


def _text_element(cls: type, rawsource: str, text: str) -> Any:
    """``cls(rawsource, text)`` for ``TextElement`` subclasses."""
    return _element(cls, rawsource, [_str_new(Text, text)] if text else [])


def _fixed_text_element(cls: type, rawsource: str, text: str) -> Any:
    """``cls(rawsource, text)`` for ``FixedTextElement`` subclasses."""
    node = _element(cls, rawsource, [_str_new(Text, text)] if text else [])
    node.attributes["xml:space"] = "preserve"
    return node


def _append(parent: nodes.Element, child: nodes.Node) -> None:
    """``parent.append(child)`` (``Node.setup_child`` semantics, inlined)."""
    doc = parent._document
    if doc is not None:
        child.parent = parent
        child._document = doc
        if child.source is None:
            child.source = doc.current_source
        if child.line is None:
            child.line = doc.current_line
        parent.children.append(child)
    elif parent.parent is None:  # detached subtree under construction
        child.parent = parent
        parent.children.append(child)
    else:
        parent.append(child)


def _extend(parent: nodes.Element, children: list) -> None:
    for child in children:
        _append(parent, child)


def _setting_int(settings: Any, name: str, default: int) -> int:
    """An integer setting; tolerant of missing or non-integer values (docutils
    only reads some settings on some code paths, so hosts may pass mocks)."""
    value = getattr(settings, name, default)
    if isinstance(value, bool) or not isinstance(value, int):
        try:
            value = int(value) if isinstance(value, (str, float)) else default
        except (TypeError, ValueError):
            value = default
    return value


def parse_flags(settings: Any, match_titles: bool = True, rfc2822: bool = False) -> int:
    flags = _native.MATCH_TITLES if match_titles else 0
    if getattr(settings, "character_level_inline_markup", False):
        flags |= _native.CHARACTER_LEVEL_INLINE_MARKUP
    if getattr(settings, "pep_references", False):
        flags |= _native.PEP_REFERENCES
    if getattr(settings, "rfc_references", False):
        flags |= _native.RFC_REFERENCES
    try:
        if utils.get_trim_footnote_ref_space(settings):
            flags |= _native.TRIM_FOOTNOTE_REFERENCE_SPACE
    except AttributeError:
        pass
    if rfc2822:
        flags |= _native.RFC2822
    return flags


# ---------------------------------------------------------------------------
# per-document context and tree builder
# ---------------------------------------------------------------------------


class DocumentContext:
    """State shared by all (nested) parses of one document."""

    def __init__(self, document: nodes.document, inliner: Inliner | None = None,
                 rfc2822: bool = False, memo: Any = None) -> None:
        self.document = document
        self.reporter = document.reporter
        settings = self.settings = document.settings
        self.native = _native.native()
        self.language = rst_languages.get_language(
            getattr(settings, "language_code", "en"), document.reporter)
        if inliner is None:
            inliner = OdinInliner()
        inliner.init_customizations(settings)
        if isinstance(inliner, OdinInliner):
            inliner.ctx = self
        inliner.document = document
        inliner.reporter = document.reporter
        inliner.language = self.language
        self.inliner = inliner
        if memo is None:
            memo = Struct(document=document, reporter=document.reporter, language=self.language,
                          title_styles=[], section_level=0, section_bubble_up_kludge=False,
                          inliner=inliner)
        # nested parses started from Python state machines find the context here
        memo.docodin_ctx = self
        self.memo = memo
        self.flags = parse_flags(settings, True, rfc2822)
        self.inline_flags = self.flags & ~(_native.MATCH_TITLES | _native.RFC2822)
        self.tab_width = _setting_int(settings, "tab_width", 8)
        self.source = document.get("source") or getattr(document, "current_source", None) or ""
        self.line_count = 0
        self.top_sm: OdinStateMachine | None = None
        # ``insert_input`` bookkeeping (see TreeBuilder._process_inserted_input):
        # inserted blocks (absolute offset, lines) in removal order, the number
        # of lines removed so far, and nodes whose ``line`` is an absolute line
        # number (id -> (node, lines removed at creation)).
        self.insertions: list[tuple[int, StringList]] = []
        self.last_removal_top = False  # the last insertion was made by the top machine
        self.removed_lines = 0
        self.absolute_lines: dict[int, tuple[nodes.Node, int]] = {}
        self.builder = TreeBuilder(self)

    # -- input lines ---------------------------------------------------------

    def make_input_lines(self, text: str | None) -> StringList:
        """Materialize the top-level ``input_lines`` (docutils ``string2lines``)."""
        return StringList(self.native.split_lines(text or "", self.tab_width), self.source)

    # -- parsing entry points ------------------------------------------------

    def parse_document_string(self, text: str) -> None:
        document = self.document
        sm = OdinStateMachine(self, None, 0, document, True, lazy_text=text)
        self._start(sm)
        children, self.line_count, final_offset, _ = self.native.parse(
            text, flags=self.flags, tab_width=self.tab_width,
            line_length_limit=self._line_length_limit())
        self.builder.build_top(children, sm)
        self._finish(sm, final_offset, self.line_count)

    def parse_document_lines(self, lines: StringList, input_offset: int = 0,
                             match_titles: bool = True, node: nodes.Element | None = None) -> None:
        sm = OdinStateMachine(self, lines, input_offset, node or self.document, match_titles)
        self._start(sm)
        self.parse_lines(sm, lines, match_titles, top=True)

    def _start(self, sm: OdinStateMachine) -> None:
        self.top_sm = sm
        reporter = self.reporter
        if not hasattr(reporter, "get_source_and_line"):
            reporter.get_source_and_line = sm.get_source_and_line
        self.document.current_source = self.source or None

    def _line_length_limit(self) -> int:
        return _setting_int(self.settings, "line_length_limit", 10_000)

    def parse_lines(self, sm: OdinStateMachine, lines, match_titles: bool, top: bool = False) -> None:
        data = lines.data if isinstance(lines, StringList) else list(lines)
        flags = self.flags if match_titles else self.flags & ~_native.MATCH_TITLES
        if not top:
            flags &= ~_native.RFC2822
        root = self.top_sm
        root_line = 0
        if root is not None and root is not sm:
            root_line = root.line_offset + root.input_offset + 1
        children, _count, final_offset, current_line = self.native.parse(
            "\n".join(data), input_offset=sm.input_offset, line_count=len(data), flags=flags,
            tab_width=self.tab_width,
            line_length_limit=0,  # only Parser.parse (string input) checks it
            root_line=max(root_line, 0))
        if top:
            self.line_count = len(data)
        self.builder.build_top(children, sm)
        if top:
            self._finish(sm, final_offset, len(data))
        else:
            sm.line_offset = len(data)
            # where docutils' nested state machines left the document
            self.builder.set_current_line(sm, current_line)

    def _finish(self, sm: OdinStateMachine, final_offset: int, count: int) -> None:
        """Leave the top state machine and ``document.current_*`` where
        docutils' own run leaves them (affects messages from transforms)."""
        if final_offset < 0:  # parse aborted (line-length limit): never ran
            final_offset = -1
        if self.insertions:
            self._restore_insertions(sm)
            if final_offset >= 0:
                final_offset += self.removed_lines
                count += self.removed_lines
                if (final_offset > count and self.last_removal_top
                        and _ends_with_insertion(sm.input_lines)):
                    # the input ended inside a top-level ``include`` directive:
                    # docutils went on through the inserted lines, which end cleanly
                    final_offset = count
        sm.line_offset = final_offset
        document = self.document
        document.current_line = None
        if final_offset == count:
            document.current_source = sm.get_source_and_line(None)[0]
        else:
            document.current_source = None

    def _restore_insertions(self, sm: OdinStateMachine) -> None:
        """Give transforms docutils' view of the input after an ``include``.

        docutils keeps inserted lines in ``input_lines``, so absolute line
        numbers after an insertion grow by its length.  The builder removes
        them after parsing (the native items of the enclosing input carry the
        original numbering), so restore both here: re-insert the blocks
        (latest removal first: each offset was taken with the later-removed
        enclosing blocks present and the earlier-removed ones absent) and
        renumber nodes that only carry an absolute line.
        """
        lines = sm.input_lines
        for offset, block in reversed(self.insertions):
            lines.insert(offset - sm.input_offset, block)
        for node, removed in self.absolute_lines.values():
            if node.line is not None:
                node.line += removed
        self.insertions = []
        self.absolute_lines = {}

    def note_absolute_line(self, node: nodes.Node) -> None:
        """Record a node whose ``line`` is an absolute line number (docutils
        sets it without source lookup), to be renumbered by
        ``_restore_insertions``."""
        if self.removed_lines:
            self.absolute_lines.setdefault(id(node), (node, self.removed_lines))

    def inline(self, text: str, lineno: int, container: nodes.Element):
        """``RSTState.inline_text``: (nodes, system_messages)."""
        items = self.native.parse_inline(text, lineno, self.inline_flags)
        msgs: list = []
        out = self.builder.inline(items, lineno, container, msgs)
        return out, msgs


def _ends_with_insertion(lines: StringList) -> bool:
    """The last input line is the padding ``insert_input()`` puts after an insertion."""
    source = lines.info(len(lines) - 1)[0] if len(lines) else None
    return bool(source) and source.startswith("internal padding after ")


class TreeBuilder:
    """Creates docutils nodes for native parse items."""

    def __init__(self, ctx: DocumentContext) -> None:
        self.ctx = ctx
        self.start_message: nodes.system_message | None = None  # see _early_message
        self.document = ctx.document
        self.reporter = ctx.reporter
        self.inliner = ctx.inliner
        block = [self._unknown] * K_COUNT
        block[K_SECTION_TITLE] = self.b_section_title
        block[K_PARAGRAPH] = self.b_paragraph
        block[K_BULLET_LIST] = self.b_bullet_list
        block[K_ENUMERATED_LIST] = self.b_enumerated_list
        block[K_DEFINITION_LIST] = self.b_definition_list
        block[K_FIELD_LIST] = self.b_field_list
        block[K_OPTION_LIST] = self.b_option_list
        block[K_LITERAL_BLOCK] = self.b_literal_block
        block[K_DOCTEST_BLOCK] = self.b_doctest_block
        block[K_LINE_BLOCK] = self.b_line_block
        block[K_BLOCK_QUOTE] = self.b_block_quote
        block[K_TRANSITION] = self.b_transition
        block[K_TABLE] = self.b_table
        block[K_FOOTNOTE] = self.b_footnote
        block[K_CITATION] = self.b_citation
        block[K_TARGET] = self.b_target
        block[K_SUBSTITUTION_DEFINITION] = self.b_substitution_definition
        block[K_COMMENT] = self.b_comment
        block[K_DIRECTIVE] = self.b_directive
        block[K_INCLUDE_END] = self.b_include_end
        block[K_SYSTEM_MESSAGE] = self.b_system_message
        self.block = block
        inline = [self._unknown_inline] * K_COUNT
        inline[K_EMPHASIS] = self.i_emphasis
        inline[K_STRONG] = self.i_strong
        inline[K_LITERAL] = self.i_literal
        inline[K_INLINE_TARGET] = self.i_target
        inline[K_SUBSTITUTION_REFERENCE] = self.i_substitution_reference
        inline[K_REFERENCE] = self.i_reference
        inline[K_FOOTNOTE_REFERENCE] = self.i_footnote_reference
        inline[K_CITATION_REFERENCE] = self.i_citation_reference
        inline[K_INTERPRETED] = self.i_interpreted
        inline[K_PROBLEMATIC] = self.i_problematic
        self.inline_dispatch = inline

    # -- traversal -----------------------------------------------------------

    def _early_message(self, items: list, index: int,
                       sm: OdinStateMachine) -> nodes.system_message | None:
        """A message docutils reports before the construct at ``items[index]``
        is parsed, but attaches after it (see ``_EARLY_MESSAGE_KINDS``):
        created first, so messages reach the reporter in docutils' order."""
        if index + 1 >= len(items):
            return None
        construct, following = items[index], items[index + 1]
        if following[0] != K_SYSTEM_MESSAGE:
            return None
        if construct[0] == K_PARAGRAPH:
            # ``Text.text``: an indented line right after the paragraph
            if (following[3] != "Unexpected indentation."
                    or following[1] != construct[1] + construct[2].count("\n") + 1):
                return None
        elif not following[3].startswith("Enumerated list start value not ordinal-1"):
            return None  # ``Body.enumerator`` reports the start before the items
        self.set_current_line(sm, following[5])
        message = self.message(following)
        if construct[0] == K_ENUMERATED_LIST:
            self.start_message = message  # attached by b_enumerated_list
        return message

    def _paragraph(self, item, parent, sm, linear, delta):
        """Hot path of ``b_paragraph`` (most frequent block element)."""
        # (K, line, raw, children, cur_line, cur)
        lineno = item[1]
        cur_line = item[4]
        top = self.ctx.top_sm
        if cur_line and top is not None:
            top.line_offset = cur_line - top.input_offset - 1
        cur = item[5]
        if linear and cur > 0:
            self.document.current_line = cur
        else:
            self.set_current_line(sm, cur)
        msgs: list = []
        p = _element(nodes.paragraph, item[2], self.inline(item[3], lineno, parent, msgs))
        if linear:
            p.source = sm._linear_source
            p.line = lineno + delta
        else:
            p.source, p.line = sm.srcline(lineno)
        _append(parent, p)
        if msgs:
            _extend(parent, msgs)

    def build_top(self, items: list, sm: OdinStateMachine) -> None:
        """Items at the top level of a (nested) parse: appended to ``sm.node``,
        which section titles may move."""
        block = self.block
        document = self.document
        skip_unindent = False
        linear = sm._is_linear()
        delta = sm.line_delta
        source = sm._linear_source
        early = None
        for index, item in enumerate(items):
            kind = item[0]
            if skip_unindent:
                skip_unindent = False
                if kind == K_SYSTEM_MESSAGE and item[3] == _EXPLICIT_UNINDENT:
                    continue
            if early is not None:  # created before the construct (and its content)
                if early.parent is None:
                    _append(sm.node, early)
                early = None
                continue
            if linear:
                document.current_source = source
                document.current_line = item[1] + delta
            else:
                document.current_source, document.current_line = sm.srcline(item[1])
            if kind in _EARLY_MESSAGE_KINDS:
                early = self._early_message(items, index, sm)
            if kind == K_PARAGRAPH:
                self._paragraph(item, sm.node, sm, linear, delta)
            elif kind == K_DIRECTIVE:
                skip_unindent = self.b_directive(item, sm.node, sm)
                linear = sm._is_linear()
                if linear:
                    document.current_source = sm._linear_source
            else:
                block[kind](item, sm.node, sm)

    def build(self, items: list, parent: nodes.Element, sm: OdinStateMachine) -> None:
        """Items nested inside ``parent`` (no section titles possible)."""
        block = self.block
        document = self.document
        skip_unindent = False
        linear = sm._is_linear()
        delta = sm.line_delta
        source = sm._linear_source
        early = None
        for index, item in enumerate(items):
            kind = item[0]
            if skip_unindent:
                skip_unindent = False
                if kind == K_SYSTEM_MESSAGE and item[3] == _EXPLICIT_UNINDENT:
                    continue
            if early is not None:  # created before the construct (and its content)
                if early.parent is None:
                    _append(parent, early)
                early = None
                continue
            if linear:
                document.current_source = source
                document.current_line = item[1] + delta
            else:
                document.current_source, document.current_line = sm.srcline(item[1])
            if kind in _EARLY_MESSAGE_KINDS:
                early = self._early_message(items, index, sm)
            if kind == K_PARAGRAPH:
                self._paragraph(item, parent, sm, linear, delta)
            elif kind == K_DIRECTIVE:
                skip_unindent = self.b_directive(item, parent, sm)
                linear = sm._is_linear()
                if linear:
                    document.current_source = sm._linear_source
            else:
                block[kind](item, parent, sm)

    def set_current_line(self, sm: OdinStateMachine, cur: int) -> None:
        """Set ``document.current_source``/``current_line`` from a native
        ``cur`` value (docutils ``note_source`` of the last cursor move)."""
        document = self.document
        if cur > 0:
            if sm._is_linear():
                document.current_source, document.current_line = sm._linear_source, cur
            else:
                document.current_source, document.current_line = sm.srcline(cur - sm.line_delta)
        elif cur == 0:
            document.current_line = None
        else:
            document.current_source = document.current_line = None

    def at_line(self, cur_line: int) -> None:
        """Position the reporter's state machine like docutils' during an
        inline parse (messages without an explicit line use it)."""
        top = self.ctx.top_sm
        if top is not None and cur_line:
            top.line_offset = cur_line - top.input_offset - 1

    def inline(self, items: list, lineno: int, container: nodes.Element, msgs: list) -> list:
        out: list = []
        append = out.append
        dispatch = self.inline_dispatch
        self.inliner.parent = container
        for it in items:
            if it.__class__ is str:
                append(_str_new(Text, it))
            else:
                dispatch[it[0]](it, lineno, container, msgs, out)
        return out

    def _unknown(self, item, parent, sm):  # pragma: no cover - defensive
        raise RuntimeError(f"docodin: unexpected block item kind {item[0]}")

    def _unknown_inline(self, item, lineno, container, msgs, out):  # pragma: no cover
        raise RuntimeError(f"docodin: unexpected inline item kind {item[0]}")

    # -- system messages -------------------------------------------------------

    def message(self, item) -> nodes.system_message:
        # (K, line, level, message, children, cur)
        _, line, level, text, children, _cur = item
        kids = [self._message_child(c) for c in children]
        if line:
            return self.reporter.system_message(level, text, *kids, line=line)
        return self.reporter.system_message(level, text, *kids)

    def _message_child(self, item):
        kind = item[0]
        if kind == K_LITERAL_BLOCK:
            return nodes.literal_block(item[2], item[2])
        if kind == K_PARAGRAPH:
            return nodes.paragraph(item[2], item[2])
        raise RuntimeError(f"docodin: unexpected message child {kind}")

    def b_system_message(self, item, parent, sm):
        self.set_current_line(sm, item[5])
        if item[3].endswith("unexpected unindent."):
            parent += self.unindent_warning(item)
        else:
            parent += self.message(item)

    def unindent_warning(self, item) -> nodes.system_message:
        """``RSTState.unindent_warning`` ("... ends without a blank line")."""
        return self.message(item)

    # -- sections ------------------------------------------------------------------

    def b_section_title(self, item, parent, sm):
        # (K, line, style, source, title_raw, title_children, messages, cur_line)
        _, lineno, style, source, title, title_items, message_items, cur_line = item
        messages = [self.message(m) for m in message_items]
        if len(style) == 2:
            style = (style[0], style[1])
        state = sm.state()
        # docutils checks and creates the section while positioned on the underline
        self.document.current_source, self.document.current_line = sm.srcline(lineno + 1)
        if not state.check_subsection(source, style, lineno):
            return
        section_node = _element(nodes.section, "", [])
        _append(sm.node, section_node)
        title_messages: list = []
        self.at_line(cur_line)
        textnodes = self.inline(title_items, lineno, sm.node, title_messages)
        titlenode = _element(nodes.title, title, textnodes)
        name = normalize_name(titlenode.astext())
        section_node["names"].append(name)
        _append(section_node, titlenode)
        _extend(section_node, messages)
        _extend(section_node, title_messages)
        self.document.note_implicit_target(section_node, section_node)
        sm.node = section_node
        sm.memo.section_level += 1

    # -- body elements -----------------------------------------------------------

    def b_paragraph(self, item, parent, sm):
        # (K, line, raw, children, cur_line, cur)
        lineno = item[1]
        msgs: list = []
        self.at_line(item[4])
        self.set_current_line(sm, item[5])
        p = _element(nodes.paragraph, item[2], self.inline(item[3], lineno, parent, msgs))
        p.source, p.line = sm.srcline(lineno)
        _append(parent, p)
        if msgs:
            _extend(parent, msgs)

    def b_bullet_list(self, item, parent, sm):
        # (K, line, bullet, items)
        ul = _element(nodes.bullet_list, "", [])
        ul.source, ul.line = sm.srcline(item[1])
        _append(parent, ul)
        ul["bullet"] = item[2]
        for li in item[3]:
            _append(ul, self._list_item(li, sm))

    def _list_item(self, item, sm):
        # (K, line, raw, children)
        li = _element(nodes.list_item, item[2], [])
        li.source, li.line = sm.srcline(item[1])
        self.build(item[3], li, sm)
        return li

    def b_enumerated_list(self, item, parent, sm):
        # (K, line, enumtype, prefix, suffix, start_or_None, items)
        el = _element(nodes.enumerated_list, "", [])
        el.source, el.line = sm.srcline(item[1])
        _append(parent, el)
        el["enumtype"] = item[2]
        el["prefix"] = item[3]
        el["suffix"] = item[4]
        if item[5] is not None:
            el["start"] = item[5]
        if self.start_message is not None:
            # ``Body.enumerator`` attaches its message before parsing the items
            _append(parent, self.start_message)
            self.start_message = None
        for li in item[6]:
            _append(el, self._list_item(li, sm))

    def b_definition_list(self, item, parent, sm):
        # (K, line, items)
        dl = _element(nodes.definition_list, "", [])
        dl.source, dl.line = sm.srcline(item[1])
        start = len(parent)
        first = True
        for dli in item[2]:
            _append(dl, self._definition_list_item(dli, sm, parent if first else dl))
            if first:
                _append(parent, dl)
                first = False
        if first:
            _append(parent, dl)
        method = patched_transition(states.Text, "indent")
        if method is not None and item[2]:  # docutils: at the first definition line
            raw = item[2][0][2].split("\n")
            replay_transition(method, states.Text, sm, parent, start, item[2][0][1] + 1,
                              raw[1:], " +", raw[:1])

    def _definition_list_item(self, item, sm, container):
        # (K, line, raw, [Term, Classifier*, Definition])
        dli = _element(nodes.definition_list_item, item[2], [])
        dli.source, dli.line = sm.srcline(item[1])
        msgs: list = []
        definition = None
        for child in item[3]:
            kind = child[0]
            if kind == K_TERM:
                self.at_line(child[4])
                self.set_current_line(sm, child[5])
                term = _element(nodes.term, child[2], self.inline(child[3], child[1], container, msgs))
                term.source, term.line = sm.srcline(child[1])
                _append(dli, term)
            elif kind == K_CLASSIFIER:
                _append(dli, _element(nodes.classifier, child[2],
                                      self.inline(child[3], child[1], container, msgs)))
            else:  # K_DEFINITION
                definition = child
        dd = _element(nodes.definition, "", msgs)
        if definition is not None:
            dd.source, dd.line = sm.srcline(definition[1])
            _append(dli, dd)
            self.build(definition[2], dd, sm)
        return dli

    def b_field_list(self, item, parent, sm):
        # (K, line, class_name, fields)
        fl = _element(nodes.field_list, "", [])
        if item[2]:
            fl["classes"].append(item[2])
        _append(parent, fl)
        container = parent
        for f in item[3]:
            _append(fl, self._field(f, sm, container))
            container = fl  # FieldList state: node is the field_list

    def _field(self, item, sm, container):
        # (K, line, [Field_Name, Field_Body])
        lineno = item[1]
        name_item, body_item = item[2]
        field = _element(nodes.field, "", [])
        field.source, field.line = sm.srcline(lineno)
        msgs: list = []
        self.at_line(name_item[4])
        self.set_current_line(sm, name_item[5])
        _append(field, _element(nodes.field_name, name_item[2],
                                self.inline(name_item[3], lineno, container, msgs)))
        body = _element(nodes.field_body, body_item[2], msgs)
        _append(field, body)
        self.build(body_item[3], body, sm)
        return field

    def b_option_list(self, item, parent, sm):
        # (K, line, items)
        ol = nodes.option_list()
        ol.source, ol.line = sm.srcline(item[1])
        first = True
        for oli in item[2]:
            built = self._option_list_item(oli, sm)
            if first:
                parent += ol
                first = False
            self.set_current_line(sm, oli[3])
            ol += built
        if first:
            parent += ol

    def _option_list_item(self, item, sm):
        # (K, line, [Option_Group, Description], cur)
        group_item, desc_item = item[2]
        options = []
        for opt in group_item[2]:
            # (K, line, raw, [Option_String, Option_Argument?])
            option = nodes.option(opt[2])
            for part in opt[3]:
                if part[0] == K_OPTION_STRING:
                    option += nodes.option_string(part[2], part[2])
                else:
                    option += nodes.option_argument(part[2], part[2], delimiter=part[3])
            options.append(option)
        group = nodes.option_group("", *options)
        description = nodes.description(desc_item[2])
        oli = nodes.option_list_item("", group, description)
        self.build(desc_item[3], description, sm)
        return oli

    def b_literal_block(self, item, parent, sm):
        # (K, line, text)
        text = item[2]
        lb = _fixed_text_element(nodes.literal_block, text, text)
        lb.source, lb.line = sm.srcline(item[1])
        _append(parent, lb)

    def b_doctest_block(self, item, parent, sm):
        text = item[2]
        n = _fixed_text_element(nodes.doctest_block, text, text)
        n.line = self.document.current_line  # docutils: the line where it starts
        _append(parent, n)
        method = patched_transition(states.Body, "doctest")
        if method is not None:
            replay_transition(method, states.Body, sm, parent, len(parent) - 1, item[1],
                              text.split("\n"), states.Body.patterns["doctest"], [])

    def b_line_block(self, item, parent, sm):
        # (K, line, children: Line | Line_Block, cur)
        block = _element(nodes.line_block, "", [])
        block.source, block.line = sm.srcline(item[1])
        _append(parent, block)
        # first line parsed in the enclosing state, later ones in LineBlock (node = block)
        containers = [parent, block]
        self._line_block_children(item[2], block, sm, parent, containers, item[3])

    def _line_block_children(self, items, block, sm, outer, containers, cur=None):
        for child in items:
            if child[0] == K_LINE:
                # (K, line, raw, children, cur_line, cur)
                self.at_line(child[4])
                self.set_current_line(sm, child[5])
                msgs: list = []
                line = _element(nodes.line, child[2], self.inline(child[3], child[1], containers[0], msgs))
                containers[0] = containers[1]
                line.source, line.line = sm.srcline(child[1])
                _append(block, line)
                if msgs:  # each line's messages go to the enclosing element
                    _extend(outer, msgs)
            else:
                # ``nest_line_block_segment`` builds the nested blocks after
                # parsing: the outermost ones are attached at the block's end
                # line, deeper ones inside detached blocks (no source/line)
                sub_block = _element(nodes.line_block, "", [])
                if cur is not None:
                    self.set_current_line(sm, cur)
                    _append(block, sub_block)
                else:
                    sub_block.parent = block
                    block.children.append(sub_block)
                self._line_block_children(child[2], sub_block, sm, outer, containers)

    def b_block_quote(self, item, parent, sm):
        # (K, line, raw, children [..., Attribution], cur)
        bq = _element(nodes.block_quote, item[2], [])
        bq.source, bq.line = sm.srcline(item[1])
        children = item[3]
        msgs: list = []
        attribution = None
        if children and children[-1][0] == K_ATTRIBUTION:
            attribution = children[-1]
            children = children[:-1]
        self.build(children, bq, sm)
        if attribution is not None:
            lineno = attribution[1]
            self.at_line(attribution[4])
            self.set_current_line(sm, attribution[5])
            node = _element(nodes.attribution, attribution[2],
                            self.inline(attribution[3], lineno, sm.node, msgs))
            node.source, node.line = sm.srcline(lineno)
            _append(bq, node)
        _append(parent, bq)
        if msgs:
            self.set_current_line(sm, item[4])
            _extend(parent, msgs)

    def b_transition(self, item, parent, sm):
        tr = _element(nodes.transition, item[2], [])
        tr.source, tr.line = sm.srcline(item[1])
        _append(parent, tr)

    def b_table(self, item, parent, sm):
        # (K, line, [TGroup], cur, cell_delta); TGroup: (K, line, cols, [Colspec*, THead?, TBody])
        table = _element(nodes.table, "", [])
        cell_sm = self._cell_sm(sm, item[4])
        for tg in item[2]:
            tgroup = _element(nodes.tgroup, "", [])
            tgroup.attributes["cols"] = tg[2]
            _append(table, tgroup)
            for part in tg[3]:
                kind = part[0]
                if kind == K_COLSPEC:
                    colspec = _element(nodes.colspec, "", [])
                    colspec.attributes["colwidth"] = part[2]
                    _append(tgroup, colspec)
                else:
                    section = _element(nodes.thead if kind == K_THEAD else nodes.tbody, "", [])
                    _append(tgroup, section)
                    for row_item in part[2]:
                        row = _element(nodes.row, "", [])
                        for entry_item in row_item[2]:
                            # (K, line, morerows, morecols, children)
                            entry = _element(nodes.entry, "", [])
                            if entry_item[2]:
                                entry.attributes["morerows"] = entry_item[2]
                            if entry_item[3]:
                                entry.attributes["morecols"] = entry_item[3]
                            _append(row, entry)
                            self.build(entry_item[4], entry, cell_sm)
                        _append(section, row)
        self.set_current_line(sm, item[3])
        _append(parent, table)

    # -- explicit markup -----------------------------------------------------------

    def b_footnote(self, item, parent, sm):
        # (K, line, label, raw, children, cur)
        label = item[2]
        name = normalize_name(label)
        footnote = _element(nodes.footnote, item[3], [])
        footnote.source, footnote.line = sm.srcline(item[1])
        document = self.document
        children = item[4]
        if children and children[0][0] == K_LABEL:
            _append(footnote, _text_element(nodes.label, "", children[0][2]))
            children = children[1:]
        if name[0] == "#":
            name = name[1:]
            footnote["auto"] = 1
            if name:
                footnote["names"].append(name)
            document.note_autofootnote(footnote)
        elif name == "*":
            name = ""
            footnote["auto"] = "*"
            document.note_symbol_footnote(footnote)
        else:
            footnote["names"].append(name)
            document.note_footnote(footnote)
        if name:
            document.note_explicit_target(footnote, footnote)
        else:
            document.set_id(footnote, footnote)
        self.build(children, footnote, sm)
        _append(parent, footnote)

    def b_citation(self, item, parent, sm):
        label = item[2]
        citation = _element(nodes.citation, item[3], [])
        citation.source, citation.line = sm.srcline(item[1])
        children = item[4]
        if children and children[0][0] == K_LABEL:
            _append(citation, _text_element(nodes.label, "", children[0][2]))
            children = children[1:]
        citation["names"].append(normalize_name(label))
        self.document.note_citation(citation)
        self.document.note_explicit_target(citation, citation)
        self.build(children, citation, sm)
        _append(parent, citation)

    def b_target(self, item, parent, sm):
        # (K, line, raw, name, type, data, cur)
        _, lineno, blocktext, name, target_type, data, cur = item
        self.set_current_line(sm, cur)  # registry messages are attached here
        target = _element(nodes.target, blocktext, [])
        if target_type == TARGET_REFNAME:
            target.attributes["refname"] = normalize_name(data)
            target.indirect_reference_name = data
            self._add_target(name, "", target, lineno, parent)
            self.document.note_indirect_target(target)
        else:
            self._add_target(name, data, target, lineno, parent)
        _append(parent, target)

    def _add_target(self, targetname, refuri, target, lineno, parent):
        target.line = lineno
        self.ctx.note_absolute_line(target)
        if targetname:
            name = normalize_name(nodes.unescape(targetname))
            target["names"].append(name)
            if refuri:
                uri = self.inliner.adjust_uri(refuri)
                if uri:
                    target["refuri"] = uri
            self.document.note_explicit_target(target, parent)
        else:
            if refuri:
                target["refuri"] = refuri
            target["anonymous"] = True
            self.document.note_anonymous_target(target)

    def b_substitution_definition(self, item, parent, sm):
        # (K, line, blocktext, subname, children, line_delta, cur)
        _, lineno, blocktext, subname, children, sub_delta, cur = item
        src, srcline = sm.srcline(lineno)
        node = nodes.substitution_definition(blocktext)
        node.source, node.line = src, srcline
        node["names"].append(nodes.whitespace_normalize_name(subname))
        sub_sm = self._context_sm(sm, node)
        sub_sm.line_delta = sm.line_delta + sub_delta
        state = _make_state(OdinSubstitutionDef, sub_sm)
        sub_sm._state = state
        document = self.document
        # where the SubstitutionDef state stopped (an embedded directive
        # moves on from there while it runs)
        self.set_current_line(sm, cur)
        for child in children:
            # the SubstitutionDef state machine's current line (note_source)
            document.current_source, document.current_line = sub_sm.srcline(child[1])
            if child[0] == K_DIRECTIVE:
                self.b_directive(child, node, sub_sm, state=state, option_presets={"alt": node["names"][0]})
            else:
                self.block[child[0]](child, node, sub_sm)
        # docutils Body.substitution_def post-processing
        i = 0
        for child in node[:]:
            if not (isinstance(child, nodes.Inline) or isinstance(child, nodes.Text)):
                parent += node[i]
                del node[i]
            else:
                i += 1
        for elem in node.findall(nodes.Element, include_self=False):
            if isinstance(elem, nodes.problematic):
                msg = self.reporter.error(
                    "Problematic content in substitution definition",
                    nodes.literal_block("", blocktext), source=src, line=srcline)
                msg.append(nodes.block_quote("", nodes.paragraph("", "", *node.children)))
                parent += msg
                return
            illegal = states.Body.disallowed_inside_substitution_definitions(None, elem)
            if illegal:
                msg = self.reporter.error(
                    f"{illegal} are not supported in a substitution definition.",
                    nodes.literal_block("", blocktext), source=src, line=srcline)
                parent += msg
                return
        if len(node) == 0:
            msg = self.reporter.warning(
                'Substitution definition "%s" empty or invalid.' % subname,
                nodes.literal_block(blocktext, blocktext), source=src, line=srcline)
            parent += msg
            return
        self.document.note_substitution_def(node, subname, parent)
        parent += node

    def b_comment(self, item, parent, sm):
        # (K, line, text, cur)
        text = item[2]
        self.set_current_line(sm, item[3])
        _append(parent, _fixed_text_element(nodes.comment, text, text))

    def b_include_end(self, item, parent, sm):
        log = getattr(self.document, "include_log", None)
        if log:
            log.pop()

    # -- directives ---------------------------------------------------------------

    def b_directive(self, item, parent, sm, state=None, option_presets=None) -> bool:
        """Run a directive; returns True when it inserted input lines."""
        # (K, line, name, block_text, lines, line_offset, end_offset, blank_finish)
        _, lineno, type_name, block_text, lines, line_offset, end_offset, _bf = item
        if parent is not sm.node:
            sm = self._context_sm(sm, parent)
        if state is None:
            state = sm.state()
        document = self.document
        directive_class, messages = directives.directive(type_name, self.ctx.language, document)
        parent += messages
        # docutils consumes the directive block before running (or rejecting)
        # the directive: the document's current line is the block's last line
        document.current_source, document.current_line = sm.srcline(end_offset + 1)
        if not directive_class:
            parent += self.reporter.error(
                'Unknown directive type "%s".' % type_name,
                nodes.literal_block(block_text, block_text), line=lineno)
            return False
        if isinstance(directive_class, (FunctionType, MethodType)):
            from docutils.parsers.rst import convert_directive_function
            directive_class = convert_directive_function(directive_class)
        sm.line_offset = end_offset - sm.input_offset
        before = len(sm._input_lines) if sm._input_lines is not None else self.ctx.line_count
        indented = self._block_lines(sm, lines, line_offset)
        try:
            arguments, options, content, content_offset = state.parse_directive_block(
                indented, line_offset, directive_class, option_presets or {})
        except MarkupError as detail:
            parent += self.reporter.error(
                'Error in "%s" directive:\n%s.' % (type_name, " ".join(detail.args)),
                nodes.literal_block(block_text, block_text), line=lineno)
            return False
        directive_instance = directive_class(
            type_name, arguments, options, content, lineno,
            content_offset, block_text, state, sm)
        result = self._run_directive(directive_instance)
        parent += result
        if self.ctx.removed_lines:
            self._note_directive_lines(result, directive_class, content_offset)
        if sm._input_lines is not None and len(sm._input_lines) != before:
            self._process_inserted_input(sm, before)
            return True
        return False

    def _run_directive(self, directive: Directive) -> list:
        try:
            result = directive.run()
        except DirectiveError as error:
            msg_node = self.reporter.system_message(error.level, error.msg, line=directive.lineno)
            msg_node += nodes.literal_block(directive.block_text, directive.block_text)
            result = [msg_node]
        type_name = directive.name
        assert isinstance(result, list), 'Directive "%s" must return a list of nodes.' % type_name
        for i, node in enumerate(result):
            assert isinstance(node, nodes.Node), (
                'Directive "%s" returned non-Node object (index %s): %r' % (type_name, i, node))
        return result

    def _note_directive_lines(self, result: list, directive_class: type,
                              content_offset: int) -> None:
        """Directive nodes without a source carry an absolute line, and so does
        ``parsed-literal``'s block (``content_offset + 1``)."""
        for node in result:
            for n in node.findall(nodes.Element):
                if n.source is None and n.line is not None:
                    self.ctx.note_absolute_line(n)
        if (issubclass(directive_class, _body_directives.ParsedLiteral) and result
                and result[0].line == content_offset + 1):
            self.ctx.note_absolute_line(result[0])

    def _cell_sm(self, sm: OdinStateMachine, delta: int) -> OdinStateMachine:
        """View of ``sm`` for table cells: docutils nests them with a 1-based
        ``input_offset``, so absolute lines run ahead of the source (by one,
        or more after an ``isolate_grid_table`` back-up; see rst.body_table)."""
        cell = self._context_sm(sm, sm.node)
        cell.line_delta = sm.line_delta + delta
        return cell

    def _context_sm(self, sm: OdinStateMachine, node: nodes.Element) -> OdinStateMachine:
        """State machine for a nested container (docutils creates one per
        nested parse; input lines/offsets are shared with the enclosing parse)."""
        child = OdinStateMachine(self.ctx, sm._input_lines, sm.input_offset, node, False,
                                 parent_sm=sm, lines_owner=sm._lines_owner or sm)
        child._linear_source = sm._linear_source
        child.line_delta = sm.line_delta
        return child

    def _block_lines(self, sm: OdinStateMachine, lines: list, line_offset: int) -> StringList:
        input_lines = sm.input_lines
        # views (table cells, substitution definitions) number their lines
        # ``line_delta`` away from the shared input lines
        start = line_offset + sm.line_delta - sm.input_offset
        end = start + len(lines)
        if 0 <= start and end <= len(input_lines):
            block = input_lines[start:end]
            block.data = list(lines)
            return block
        return StringList(list(lines), self.ctx.source)

    def _process_inserted_input(self, sm: OdinStateMachine, before: int) -> None:
        """Parse lines inserted by ``state_machine.insert_input()`` (``include``)
        right after the directive, then drop them again so that absolute line
        offsets of the remaining (already parsed) input stay valid."""
        input_lines = sm._input_lines
        start = sm.line_offset + 1
        count = len(input_lines) - before
        if count <= 0:
            return
        # A connected slice: nested insertions (includes inside the included
        # text) propagate to the parent lists, as in docutils, so reporter
        # line lookups keep working; they are removed again the same way.
        inserted = input_lines[start:start + count]
        child = OdinStateMachine(self.ctx, inserted, sm.input_offset + start, sm.node,
                                 sm.match_titles, parent_sm=sm.parent_state_machine)
        child.section_level_offset = sm.section_level_offset
        self.ctx.parse_lines(child, inserted, sm.match_titles)
        if sm.match_titles:
            sm.node = child.node
        # recorded in removal order, without the (already removed) nested insertions
        self.ctx.insertions.append(
            (sm.input_offset + start, StringList(list(inserted.data), items=list(inserted.items))))
        self.ctx.last_removal_top = sm is self.ctx.top_sm
        # Remove item by item: ``ViewList.__delitem__`` with a slice deletes
        # twice when the list has a parent (docutils bug), integer deletion
        # propagates correctly.
        for _ in range(count):
            del input_lines[start]
        self.ctx.removed_lines += count

    # -- inline elements -------------------------------------------------------

    def i_emphasis(self, it, lineno, container, msgs, out):
        out.append(_text_element(nodes.emphasis, it[1], it[2]))

    def i_strong(self, it, lineno, container, msgs, out):
        out.append(_text_element(nodes.strong, it[1], it[2]))

    def i_literal(self, it, lineno, container, msgs, out):
        out.append(_text_element(nodes.literal, it[1], it[2]))

    def i_target(self, it, lineno, container, msgs, out):
        target = _text_element(nodes.target, it[1], it[2])
        target["names"].append(normalize_name(target.astext()))
        self.document.note_explicit_target(target, container)
        out.append(target)

    def i_substitution_reference(self, it, lineno, container, msgs, out):
        # (K, raw, text, underscores)
        subref = nodes.substitution_reference(it[1], it[2])
        subref_text = subref.astext()
        self.document.note_substitution_ref(subref, subref_text)
        underscores = it[3]
        if underscores:
            endstring = "|" + "_" * underscores
            reference = nodes.reference("|%s%s" % (subref_text, endstring), "")
            if underscores == 2:
                reference["anonymous"] = True
            else:
                reference["refname"] = normalize_name(subref_text)
                self.document.note_refname(reference)
            reference += subref
            out.append(reference)
        else:
            out.append(subref)

    def i_reference(self, it, lineno, container, msgs, out):
        # (K, ref_kind, raw, text, x, y)
        kind = it[1]
        if kind == REF_SIMPLE:
            text = it[3]
            reference = _text_element(nodes.reference, it[2], text)
            reference["name"] = whitespace_normalize_name(text)
            if it[4]:
                reference["anonymous"] = True
            else:
                reference["refname"] = normalize_name(text)
                self.document.note_refname(reference)
            out.append(reference)
        elif kind == REF_PHRASE:
            self._phrase_reference(it, container, out)
        elif kind == REF_URI:
            reference = _text_element(nodes.reference, it[2], it[3])
            reference["refuri"] = it[4]
            out.append(reference)
        elif kind == REF_PEP:
            settings = self.ctx.settings
            ref = settings.pep_base_url + settings.pep_file_url_template % int(it[4])
            out.append(nodes.reference(it[2], it[3], refuri=ref))
        else:  # REF_RFC
            ref = self.ctx.settings.rfc_base_url + self.inliner.rfc_url % int(it[4])
            out.append(nodes.reference(it[2], it[3], refuri=ref))

    def _phrase_reference(self, it, container, out):
        # (K, REF_PHRASE, rawsource, text, alias_type, (alias, target_raw) | None)
        rawsource, text, alias_type, extra = it[2], it[3], it[4], it[5]
        document = self.document
        target = None
        alias = ""
        if alias_type != ALIAS_NONE:
            raw_alias, target_raw = extra
            target = _element(nodes.target, target_raw, [])
            if alias_type == ALIAS_NAME:
                alias = normalize_name(raw_alias)
                target.attributes["refname"] = alias
                target.indirect_reference_name = whitespace_normalize_name(raw_alias)
            else:
                alias = raw_alias
                target.attributes["refuri"] = alias
                target.referenced = 1
            if not text:
                text = alias
        unescaped = nodes.unescape(text) if "\x00" in text else text
        refname = normalize_name(unescaped)
        reference = _text_element(nodes.reference, rawsource, text)
        reference["name"] = whitespace_normalize_name(unescaped)
        out.append(reference)
        if rawsource[-2:] == "__":
            if target is not None and alias_type == ALIAS_NAME:
                reference["refname"] = alias
                document.note_refname(reference)
            elif target is not None and alias_type == ALIAS_URI:
                reference["refuri"] = alias
            else:
                reference["anonymous"] = True
        else:
            if target is not None:
                target["names"].append(refname)
                if alias_type == ALIAS_NAME:
                    reference["refname"] = alias
                    document.note_indirect_target(target)
                    document.note_refname(reference)
                else:
                    reference["refuri"] = alias
                document.note_implicit_target(target, container)
                out.append(target)
            else:
                reference["refname"] = refname
                document.note_refname(reference)

    def i_footnote_reference(self, it, lineno, container, msgs, out):
        label = it[1]
        refname = normalize_name(label)
        refnode = _element(nodes.footnote_reference, "[%s]_" % label, [])
        document = self.document
        if refname[0] == "#":
            refname = refname[1:]
            refnode["auto"] = 1
            document.note_autofootnote_ref(refnode)
        elif refname == "*":
            refname = ""
            refnode["auto"] = "*"
            document.note_symbol_footnote_ref(refnode)
        else:
            _append(refnode, _str_new(Text, label))
        if refname:
            refnode["refname"] = refname
            document.note_footnote_ref(refnode)
        out.append(refnode)

    def i_citation_reference(self, it, lineno, container, msgs, out):
        label = it[1]
        refnode = _text_element(nodes.citation_reference, "[%s]_" % label, label)
        refnode.attributes["refname"] = normalize_name(label)
        self.document.note_citation_ref(refnode)
        out.append(refnode)

    def i_interpreted(self, it, lineno, container, msgs, out):
        # (K, rawsource, escaped_text, role)
        inliner = self.inliner
        inliner.parent = container
        nodelist, messages = inliner.interpreted(it[1], it[2], it[3], lineno)
        out.extend(nodelist)
        msgs.extend(messages)

    def i_problematic(self, it, lineno, container, msgs, out):
        # (K, text, level, message)
        msg = self.reporter.system_message(it[2], it[3], line=lineno)
        inliner = self.inliner
        inliner.parent = container
        out.append(inliner.problematic(it[1], it[1], msg))
        msgs.append(msg)


# ---------------------------------------------------------------------------
# entry points
# ---------------------------------------------------------------------------


def parse_string(inputstring: str, document: nodes.document, inliner: Inliner | None = None,
                 rfc2822: bool = False) -> DocumentContext:
    """Parse a reST string into ``document`` (``docutils.parsers.rst.Parser.parse``)."""
    ctx = DocumentContext(document, inliner, rfc2822)
    ctx.parse_document_string(inputstring)
    return ctx


def parse_string_list(input_lines: StringList, document: nodes.document,
                      inliner: Inliner | None = None, input_offset: int = 0,
                      match_titles: bool = True, rfc2822: bool = False) -> DocumentContext:
    """Parse a ``StringList`` into ``document`` (``RSTStateMachine.run``)."""
    ctx = DocumentContext(document, inliner, rfc2822)
    ctx.parse_document_lines(input_lines, input_offset, match_titles)
    return ctx


def nested_parse(state: Any, block: Any, input_offset: int, node: nodes.Element | None = None,
                 match_titles: bool = False) -> int:
    """Parse `block` natively into `node` (``RSTState.nested_parse``).

    `state` is any docutils state: a state of the native builder, or one of a Python state
    machine (field lists, directive options, extension states) running inside a document.
    Returns the new input offset.
    """
    sm = state.state_machine
    ctx = getattr(sm, "ctx", None) or getattr(state.memo, "docodin_ctx", None)
    if ctx is None:
        ctx = DocumentContext(state.document, state.memo.inliner, memo=state.memo)
    if node is None:
        node = sm.node
    if node is sm.node and not isinstance(node, (nodes.document, nodes.section)):
        match_titles = False
    if not isinstance(block, StringList):
        block = StringList(list(block), source=ctx.source or "")
    child = OdinStateMachine(ctx, block, input_offset, node, match_titles, parent_sm=sm)
    if match_titles:
        l_node = len(node.section_hierarchy())
        l_start = min(len(sm.node.section_hierarchy()), len(state.memo.title_styles))
        child.section_level_offset = l_start - l_node
    block_length = len(block)
    ctx.parse_lines(child, block, match_titles)
    if match_titles and node is sm.node:
        machine = sm
        while machine is not None:
            machine.node = child.node
            machine = getattr(machine, "parent_state_machine", None)
    new_offset = child.input_offset + len(block)
    if block.parent and (len(block) - block_length) != 0:
        sm.next_line(len(block) - block_length)
    return new_offset


__all__ = [
    "DocumentContext",
    "OdinBody",
    "OdinInliner",
    "OdinStateMachine",
    "OdinSubstitutionDef",
    "TreeBuilder",
    "nested_parse",
    "parse_string",
    "parse_string_list",
]

# Silence "imported but unused" for names kept for API compatibility.
_ = (Directive, roles)
