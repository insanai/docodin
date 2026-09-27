"""Docutils states drop-in implementation for docodin."""

from __future__ import annotations

from typing import Any

from docodin.shim import nodes
from docodin.shim.statemachine import StateMachineWS, StateWS, StringList


class MarkupError(Exception):
    pass


class Struct:
    """Namespace object storing arbitrary keyword arguments."""

    def __init__(self, **values: Any) -> None:
        self.__dict__.update(values)


class Inliner:
    """Inline markup recognizer."""

    def __init__(self) -> None:
        self.implicit_dispatch: list[Any] = []

    def init_customizations(self, settings: Any) -> None:
        pass

    def parse(self, text: str, lineno: int, memo: Any, parent: nodes.Element) -> tuple[list[nodes.Node], list[nodes.system_message]]:
        from docodin.builder import parse_string_inline

        return parse_string_inline(text, lineno, memo, parent)


class RSTState(StateWS):
    @property
    def parent(self) -> Any:
        return getattr(getattr(self, "state_machine", None), "node", None)

    @parent.setter
    def parent(self, value: Any) -> None:
        if hasattr(self, "state_machine") and self.state_machine is not None:
            self.state_machine.node = value

    def nested_parse(
        self,
        block: StringList,
        input_offset: int,
        node: nodes.Element,
        match_titles: bool = False,
        state_machine_class: Any = None,
        state_machine_kwargs: Any = None,
    ) -> int:
        from docodin.builder import parse_string_list

        inliner = getattr(getattr(self, "memo", None), "inliner", None)
        parse_string_list(block, node.document, inliner=inliner, input_offset=input_offset, match_titles=match_titles, current_node=node)
        return len(block)

    def nested_list_parse(
        self,
        block: StringList,
        input_offset: int,
        node: nodes.Element,
        initial_state: str = "Body",
        blank_finish: bool = True,
        extra_settings: Any = None,
        match_titles: bool = False,
        state_machine_class: Any = None,
        state_machine_kwargs: Any = None,
    ) -> tuple[int, bool]:
        self.nested_parse(block, input_offset, node, match_titles=match_titles)
        return len(block), blank_finish

    def inline_text(self, text: str, lineno: int) -> tuple[list[nodes.Node], list[nodes.system_message]]:
        inliner = getattr(self, "inliner", None) or getattr(getattr(self, "memo", None), "inliner", None)
        if inliner is None:
            inliner = Inliner()
        return inliner.parse(text, lineno, getattr(self, "memo", None), getattr(self, "parent", None))

    def check_subsection(self, source: str, style: tuple[str, ...], lineno: int) -> bool:
        title_styles = getattr(self.memo, "title_styles", None)
        if title_styles is None:
            title_styles = self.memo.title_styles = []
        parent_sections = self.parent.section_hierarchy()
        oldlevel = len(parent_sections) + getattr(getattr(self, "state_machine", None), "section_level_offset", 0)
        try:
            newlevel = title_styles.index(style) + 1
        except ValueError:
            newlevel = len(title_styles) + 1
        if newlevel > oldlevel + 1:
            styles = " ".join("/".join(s) for s in title_styles)
            if hasattr(self, "reporter") and self.reporter:
                self.parent += self.reporter.error(
                    f"Inconsistent title style: skip from level {oldlevel} to {newlevel}.",
                    nodes.literal_block("", source),
                    nodes.paragraph("", f"Established title styles: {styles}"),
                    line=lineno,
                )
            return False
        if newlevel <= oldlevel:
            try:
                new_parent = parent_sections[newlevel - oldlevel - 1].parent
            except IndexError:
                return False
            self.parent = new_parent
            self.memo.section_level = newlevel - 1
        if newlevel > len(title_styles):
            title_styles.append(style)
        return True

    def new_subsection(self, title: str, lineno: int, messages: list[Any]) -> None:
        section_node = nodes.section()
        self.parent += section_node
        textnodes, title_messages = self.inline_text(title, lineno)
        titlenode = nodes.title(title, "", *textnodes)
        name = nodes.fully_normalize_name(titlenode.astext())
        section_node["names"].append(name)
        section_node += titlenode
        section_node += messages
        section_node += title_messages
        if hasattr(self, "document") and self.document:
            self.document.note_implicit_target(section_node, section_node)
        self.parent = section_node
        if hasattr(self.memo, "section_level"):
            self.memo.section_level += 1


class Body(RSTState):
    patterns: dict[str, str] = {
        "field_marker": r":(?![: ])([^:\\]|\\.|:(?!([ `]|$)))*(?<! ):( +|$)",
    }

    def disallowed_inside_substitution_definitions(self, node: Any) -> str:
        if isinstance(node, nodes.reference) and node.get("anonymous"):
            return "Anonymous references"
        if isinstance(node, nodes.footnote_reference) and node.get("auto"):
            return "References to auto-numbered and auto-symbol footnotes"
        if node.get("names") or node.get("ids"):
            return "Targets (names and identifiers)"
        return ""

    def parse_extension_options(self, option_spec: dict[str, Any], datalines: list[str]) -> tuple[int, Any]:
        from docodin.shim import utils

        node = nodes.field_list()
        newline_offset, blank_finish = self.nested_list_parse(
            datalines, 0, node, initial_state="ExtensionOptions", blank_finish=True
        )
        if newline_offset != len(datalines):
            return 0, "invalid option block"
        try:
            options = utils.extract_extension_options(node, option_spec)
        except KeyError as detail:
            return 0, f'unknown option: "{detail.args[0]}"'
        except (ValueError, TypeError) as detail:
            return 0, f'invalid option value: {" ".join(detail.args)}'
        except utils.ExtensionOptionError as detail:
            return 0, f'invalid option data: {" ".join(detail.args)}'
        if blank_finish:
            return 1, options
        return 0, "option data incompletely parsed"


class SubstitutionDef(Body):
    pass


class RSTStateMachine(StateMachineWS):
    def run(
        self,
        input_lines: Any,
        document: Any,
        input_offset: int = 0,
        match_titles: bool = True,
        inliner: Any = None,
    ) -> None:
        from docodin.builder import parse_string_list

        if not isinstance(input_lines, StringList):
            input_lines = StringList(list(input_lines), document.get("source", ""))
        rfc2822 = getattr(self, "initial_state", "Body") == "RFC2822Body"
        parse_string_list(input_lines, document, inliner, input_offset, match_titles, rfc2822=rfc2822)
        self.node = None
        self.memo = None


class NestedStateMachine(StateMachineWS):
    pass


state_classes: tuple[type, ...] = (Body,)
