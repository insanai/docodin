"""The concrete element classes of the Docutils document tree (except `document`)."""

from __future__ import annotations

from typing import Any

from ._base import (
    Admonition,
    BackLinkable,
    Bibliographic,
    Body,
    Decorative,
    Element,
    FixedTextElement,
    General,
    Inline,
    Invisible,
    Labeled,
    Node,
    Part,
    PreBibliographic,
    PureTextElement,
    Referential,
    Sequential,
    Special,
    Structural,
    SubStructural,
    Targetable,
    TextElement,
    Titular,
    ValidationError,
    validate_colwidth,
)

_VA = Element.valid_attributes

# --- decorative and structural -----------------------------------------------------------


class header(Decorative, Element):  # noqa: N801 - docutils tag names
    pass


class footer(Decorative, Element):  # noqa: N801
    pass


class title(Titular, PreBibliographic, SubStructural, TextElement):  # noqa: N801
    """Title of `document`, `section`, `topic` and generic `admonition`."""

    valid_attributes = _VA + ("auto", "refid")


class subtitle(Titular, PreBibliographic, SubStructural, TextElement):  # noqa: N801
    """Sub-title of `document`, `section` and `sidebar`."""

    def validate_position(self) -> None:
        if self.parent and self.parent.index(self) == 0:
            raise ValidationError(f"Element {self.parent.starttag()} invalid:\n"
                                  "  <subtitle> only allowed after <title>.",
                                  problematic_element=self)


class meta(PreBibliographic, SubStructural, Element):  # noqa: N801
    """Container for "invisible" bibliographic data, or meta-data."""

    valid_attributes = _VA + ("content", "dir", "http-equiv", "lang", "media", "name", "scheme")


class docinfo(SubStructural, Element):  # noqa: N801
    """Container for displayed document meta-data."""

    content_model = ((Bibliographic, "+"),)


class decoration(PreBibliographic, SubStructural, Element):  # noqa: N801
    """Container for `header` and `footer`."""

    content_model = ((header, "?"), (footer, "?"))

    def get_header(self) -> header:
        if not len(self.children) or not isinstance(self.children[0], header):
            self.insert(0, header())
        return self.children[0]

    def get_footer(self) -> footer:
        if not len(self.children) or not isinstance(self.children[-1], footer):
            self.append(footer())
        return self.children[-1]


class transition(SubStructural, Element):  # noqa: N801
    """Break between untitled text parts."""

    def validate_position(self) -> None:
        messages = [f"Element {self.parent.starttag()} invalid:"]
        predecessor = self.previous_sibling()
        if predecessor is None or isinstance(predecessor, (title, subtitle, meta, decoration)):
            messages.append("<transition> may not begin a section or document.")
        if self.parent.index(self) == len(self.parent) - 1:
            messages.append("<transition> may not end a section or document.")
        if isinstance(predecessor, transition):
            messages.append("<transition> may not directly follow another transition.")
        if len(messages) > 1:
            raise ValidationError("\n  ".join(messages), problematic_element=self)


class topic(Structural, Element):  # noqa: N801
    """Non-recursive mini-section."""

    content_model = ((title, "?"), (Body, "+"))


class sidebar(Structural, Element):  # noqa: N801
    """Parallel document providing related material."""

    content_model = ((title, "?"), (subtitle, "?"), ((topic, Body), "+"))


class section(Structural, Element):  # noqa: N801
    """Document section, the main unit of hierarchy."""


section.content_model = (
    (title, "."), (subtitle, "?"), ((Body, topic, sidebar, transition), "*"),
    ((section, transition), "*"),
)

# --- bibliographic ---------------------------------------------------------------------


class author(Bibliographic, TextElement):  # noqa: N801
    pass


class organization(Bibliographic, TextElement):  # noqa: N801
    pass


class address(Bibliographic, FixedTextElement):  # noqa: N801
    pass


class contact(Bibliographic, TextElement):  # noqa: N801
    pass


class version(Bibliographic, TextElement):  # noqa: N801
    pass


class revision(Bibliographic, TextElement):  # noqa: N801
    pass


class status(Bibliographic, TextElement):  # noqa: N801
    pass


class date(Bibliographic, TextElement):  # noqa: N801
    pass


class copyright(Bibliographic, TextElement):  # noqa: N801, A001
    pass


class authors(Bibliographic, Element):  # noqa: N801
    """Author information for documents with multiple authors."""

    content_model = ((author, "+"), (organization, "?"), (address, "?"), (contact, "?"))

    def validate_content(self, model: tuple | None = None, elements: Any = None) -> list:
        relics = super().validate_content()
        while relics:
            relics = super().validate_content(elements=relics)
        return relics


# --- body elements -------------------------------------------------------------------


class paragraph(General, TextElement):  # noqa: N801
    pass


class rubric(Titular, General, TextElement):  # noqa: N801
    pass


class compound(General, Element):  # noqa: N801
    content_model = ((Body, "+"),)


class container(General, Element):  # noqa: N801
    content_model = ((Body, "+"),)


class attribution(Part, TextElement):  # noqa: N801
    """Visible reference to the source of a `block_quote`."""


class block_quote(General, Element):  # noqa: N801
    """An extended quotation, set off from the main text."""

    content_model = ((Body, "+"), (attribution, "?"))


class reference(General, Inline, Referential, TextElement):  # noqa: N801
    valid_attributes = _VA + ("anonymous", "name", "refid", "refname", "refuri")


class list_item(Part, Element):  # noqa: N801
    content_model = ((Body, "*"),)


class bullet_list(Sequential, Element):  # noqa: N801
    valid_attributes = _VA + ("bullet",)
    content_model = ((list_item, "+"),)


class enumerated_list(Sequential, Element):  # noqa: N801
    valid_attributes = _VA + ("enumtype", "prefix", "suffix", "start")
    content_model = ((list_item, "+"),)


class term(Part, TextElement):  # noqa: N801
    pass


class classifier(Part, TextElement):  # noqa: N801
    pass


class definition(Part, Element):  # noqa: N801
    """Definition of a `term` in a `definition_list`."""

    content_model = ((Body, "+"),)


class definition_list_item(Part, Element):  # noqa: N801
    content_model = ((term, "."), ((classifier, term), "*"), (definition, "."))


class definition_list(Sequential, Element):  # noqa: N801
    """List of terms and their definitions."""

    content_model = ((definition_list_item, "+"),)


class field_name(Part, TextElement):  # noqa: N801
    pass


class field_body(Part, Element):  # noqa: N801
    content_model = ((Body, "*"),)


class field(Part, Bibliographic, Element):  # noqa: N801
    content_model = ((field_name, "."), (field_body, "."))


class field_list(Sequential, Element):  # noqa: N801
    """List of label & data pairs."""

    content_model = ((field, "+"),)


class option_string(Part, PureTextElement):  # noqa: N801
    """A literal command-line option."""


class option_argument(Part, PureTextElement):  # noqa: N801
    """Placeholder text for option arguments."""

    valid_attributes = _VA + ("delimiter",)

    def astext(self) -> str:
        return self.get("delimiter", " ") + TextElement.astext(self)


class option(Part, Element):  # noqa: N801
    """Option string with zero or more option argument placeholders."""

    child_text_separator = ""
    content_model = ((option_string, "."), (option_argument, "*"))


class option_group(Part, Element):  # noqa: N801
    """One or more synonymous `option` elements."""

    child_text_separator = ", "
    content_model = ((option, "+"),)


class description(Part, Element):  # noqa: N801
    """Description of a command-line option."""

    content_model = ((Body, "+"),)


class option_list_item(Part, Element):  # noqa: N801
    """Pair of `option_group` and `description` elements."""

    child_text_separator = "  "
    content_model = ((option_group, "."), (description, "."))


class option_list(Sequential, Element):  # noqa: N801
    """Two-column list of command-line options and descriptions."""

    content_model = ((option_list_item, "+"),)


class literal_block(General, FixedTextElement):  # noqa: N801
    pass


class doctest_block(General, FixedTextElement):  # noqa: N801
    pass


class math_block(General, FixedTextElement, PureTextElement):  # noqa: N801
    """Mathematical notation (display formula)."""


class line(Part, TextElement):  # noqa: N801
    """Single line of text in a `line_block`."""

    indent: str | None = None


class line_block(General, Element):  # noqa: N801
    """Sequence of lines and nested line blocks."""


line_block.content_model = (((line, line_block), "+"),)


class attention(Admonition, Element):  # noqa: N801
    pass


class caution(Admonition, Element):  # noqa: N801
    pass


class danger(Admonition, Element):  # noqa: N801
    pass


class error(Admonition, Element):  # noqa: N801
    pass


class important(Admonition, Element):  # noqa: N801
    pass


class note(Admonition, Element):  # noqa: N801
    pass


class tip(Admonition, Element):  # noqa: N801
    pass


class hint(Admonition, Element):  # noqa: N801
    pass


class warning(Admonition, Element):  # noqa: N801
    pass


class admonition(Admonition, Element):  # noqa: N801
    content_model = ((title, "."), (Body, "+"))


class label(Part, PureTextElement):  # noqa: N801
    """Visible identifier for footnotes and citations."""


class footnote(General, BackLinkable, Element, Labeled, Targetable):  # noqa: N801
    """Labelled note providing additional context."""

    valid_attributes = _VA + ("auto", "backrefs")
    content_model = ((label, "?"), (Body, "+"))


class citation(General, BackLinkable, Element, Labeled, Targetable):  # noqa: N801
    content_model = ((label, "."), (Body, "+"))


class image(General, Inline, Element):  # noqa: N801
    """Reference to an image resource (body or inline element)."""

    valid_attributes = _VA + ("uri", "alt", "align", "height", "width", "scale", "loading")

    def astext(self) -> str:
        return self.get("alt", "")


class caption(Part, TextElement):  # noqa: N801
    pass


class legend(Part, Element):  # noqa: N801
    """Text accompanying a `figure` that is not the caption."""

    content_model = ((Body, "+"),)


class figure(General, Element):  # noqa: N801
    """A formal figure, generally an illustration, with a title."""

    valid_attributes = _VA + ("align", "width")
    content_model = (((image, reference), "."), (caption, "?"), (legend, "?"))


class entry(Part, Element):  # noqa: N801
    """A table cell."""

    valid_attributes = _VA + ("align", "char", "charoff", "colname", "colsep", "morecols",
                              "morerows", "namest", "nameend", "rowsep", "valign")
    content_model = ((Body, "*"),)


class row(Part, Element):  # noqa: N801
    valid_attributes = _VA + ("rowsep", "valign")
    content_model = ((entry, "+"),)


class colspec(Part, Element):  # noqa: N801
    """Specifications for a column in a `tgroup`."""

    valid_attributes = _VA + ("align", "char", "charoff", "colname", "colnum", "colsep",
                              "colwidth", "rowsep", "stub")

    def propwidth(self) -> int | float:
        """Numerical value of the "colwidth" attribute (default 1)."""
        return validate_colwidth(self.get("colwidth", ""))


class thead(Part, Element):  # noqa: N801
    valid_attributes = _VA + ("valign",)
    content_model = ((row, "+"),)


class tbody(Part, Element):  # noqa: N801
    valid_attributes = _VA + ("valign",)
    content_model = ((row, "+"),)


class tgroup(Part, Element):  # noqa: N801
    valid_attributes = _VA + ("align", "cols", "colsep", "rowsep")
    content_model = ((colspec, "*"), (thead, "?"), (tbody, "."))


class table(General, Element):  # noqa: N801
    valid_attributes = _VA + ("align", "colsep", "frame", "pgwide", "rowsep", "width")
    content_model = ((title, "?"), (tgroup, "+"))


# --- special and invisible -----------------------------------------------------------


class comment(Invisible, FixedTextElement, PureTextElement):  # noqa: N801
    """Author notes, hidden from the output."""


class substitution_definition(Invisible, TextElement):  # noqa: N801
    valid_attributes = _VA + ("ltrim", "rtrim")


class target(Invisible, Inline, TextElement, Targetable):  # noqa: N801
    valid_attributes = _VA + ("anonymous", "refid", "refname", "refuri")


class system_message(Special, BackLinkable, PreBibliographic, Element):  # noqa: N801
    """System message (create with ``document.reporter`` methods)."""

    valid_attributes = BackLinkable.valid_attributes + ("level", "line", "type")
    content_model = ((Body, "+"),)

    def __init__(self, message: str | None = None, *children: Any, **attributes: Any) -> None:
        rawsource = attributes.pop("rawsource", "")
        if message:
            children = (paragraph("", message), *children)
        Element.__init__(self, rawsource, *children, **attributes)

    def astext(self) -> str:
        line = self.get("line", "")
        return "%s:%s: (%s/%s) %s" % (self["source"], line, self["type"], self["level"],
                                      Element.astext(self))


def _detail_lines(key: str, value: Any) -> list[str]:
    if isinstance(value, Node):
        return ["%7s%s:" % ("", key)] + ["%9s%s" % ("", line)
                                          for line in value.pformat().splitlines()]
    if value and isinstance(value, list) and isinstance(value[0], Node):
        lines = ["%7s%s:" % ("", key)]
        for item in value:
            lines.extend("%9s%s" % ("", line) for line in item.pformat().splitlines())
        return lines
    return ["%7s%s: %r" % ("", key, value)]


class pending(Invisible, Element):  # noqa: N801
    """Placeholder for a pending operation (transform + details)."""

    def __init__(self, transform: Any, details: dict[str, Any] | None = None,
                 rawsource: str = "", *children: Any, **attributes: Any) -> None:
        Element.__init__(self, rawsource, *children, **attributes)
        self.transform = transform
        self.details = details or {}

    def pformat(self, indent: str = "    ", level: int = 0) -> str:
        internals = [".. internal attributes:",
                     "     .transform: %s.%s" % (self.transform.__module__,
                                                 self.transform.__name__),
                     "     .details:"]
        for key, value in sorted(self.details.items()):
            internals.extend(_detail_lines(key, value))
        return Element.pformat(self, indent, level) + "".join(
            "    %s%s\n" % (indent * level, line) for line in internals)

    def copy(self) -> pending:
        obj = self.__class__(self.transform, self.details, self.rawsource, **self.attributes)
        obj._document = self._document
        obj.source = self.source
        obj.line = self.line
        return obj


class raw(Special, Inline, PreBibliographic, FixedTextElement, PureTextElement):  # noqa: N801
    """Raw data passed untouched to the writer."""

    valid_attributes = _VA + ("format", "xml:space")


# --- inline elements -----------------------------------------------------------------


class abbreviation(Inline, TextElement):  # noqa: N801
    pass


class acronym(Inline, TextElement):  # noqa: N801
    pass


class emphasis(Inline, TextElement):  # noqa: N801
    pass


class generated(Inline, TextElement):  # noqa: N801
    pass


class inline(Inline, TextElement):  # noqa: N801
    pass


class literal(Inline, TextElement):  # noqa: N801
    pass


class strong(Inline, TextElement):  # noqa: N801
    pass


class subscript(Inline, TextElement):  # noqa: N801
    pass


class superscript(Inline, TextElement):  # noqa: N801
    pass


class title_reference(Inline, TextElement):  # noqa: N801
    pass


class footnote_reference(Inline, Referential, PureTextElement):  # noqa: N801
    valid_attributes = _VA + ("auto", "refid", "refname")


class citation_reference(Inline, Referential, PureTextElement):  # noqa: N801
    valid_attributes = _VA + ("refid", "refname")


class substitution_reference(Inline, TextElement):  # noqa: N801
    valid_attributes = _VA + ("refname",)


class math(Inline, PureTextElement):  # noqa: N801
    """Mathematical notation in running text."""


class problematic(Inline, TextElement):  # noqa: N801
    valid_attributes = _VA + ("refid", "refname", "refuri")
