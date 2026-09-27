"""
A parser for CommonMark Markdown text using `recommonmark`__.

__ https://pypi.org/project/recommonmark/

.. important:: This module is deprecated.

   * The "recommonmark" package is unmaintained and deprecated.
     This wrapper module will be removed in Docutils 1.0.

   * The API is not settled and may change with any minor Docutils version.
"""

from __future__ import annotations

from docutils import Component, nodes

__docformat__ = "reStructuredText"

try:
    # If possible, import Sphinx's 'addnodes'
    from sphinx import addnodes
except ImportError:
    # stub to prevent errors if Sphinx isn't installed
    import sys
    import types

    class pending_xref(nodes.Inline, nodes.Element):  # noqa: N801 - Sphinx name
        ...

    sys.modules["sphinx"] = sphinx = types.ModuleType("sphinx")
    sphinx.addnodes = addnodes = types.SimpleNamespace()
    addnodes.pending_xref = pending_xref
try:
    import recommonmark
    from recommonmark.parser import CommonMarkParser
except ImportError as err:
    raise ImportError(
        'Parsing "recommonmark" Markdown flavour requires the\n'
        "  package https://pypi.org/project/recommonmark."
    ) from err
else:
    if recommonmark.__version__ < "0.6.0":
        raise ImportError('The installed version of "recommonmark" is too old.'
                          ' Update with "pip install -U recommonmark".')


# auxiliary function for `document.findall()`
def is_literal(node: nodes.Node) -> bool:
    return isinstance(node, (nodes.literal, nodes.literal_block))


def _merge_text_nodes(document: nodes.document) -> None:
    """Merge adjoining Text nodes and remove empty ones."""
    for node in document.findall(nodes.TextElement):
        children = node.children
        i = 0
        while i+1 < len(children):
            if (isinstance(children[i], nodes.Text)
                    and isinstance(children[i+1], nodes.Text)):
                children[i] = nodes.Text(children[i]+children.pop(i+1))
                children[i].parent = node
            else:
                i += 1
    for node in document.findall(nodes.Text):
        if not len(node):
            node.parent.remove(node)


def _normalize_literals(document: nodes.document) -> None:
    """Add "code" class to literals and move "language" to classes."""
    for node in document.findall(is_literal):
        if "code" not in node["classes"]:
            node["classes"].append("code")
    for node in document.findall(nodes.literal_block):
        if "language" in node.attributes:
            node["classes"].append(node["language"])
            del node["language"]


def _replace_raw_nodes(document: nodes.document) -> None:
    """Replace raw nodes with warnings (for use if raw is not allowed)."""
    for node in document.findall(nodes.raw):
        message = document.reporter.warning("Raw content disabled.")
        if isinstance(node.parent, nodes.TextElement):
            msgid = document.set_id(message)
            problematic = nodes.problematic("", node.astext(), refid=msgid)
            node.parent.replace(node, problematic)
            prbid = document.set_id(problematic)
            message.add_backref(prbid)
            document.append(message)
        else:
            node.parent.replace(node, message)


def _drop_pending_xrefs(document: nodes.document) -> None:
    """Drop pending_xref (Sphinx cross reference extension)."""
    for node in document.findall(addnodes.pending_xref):
        reference = node.children[0]
        if "name" not in reference:
            reference["name"] = nodes.fully_normalize_name(reference.astext())
        node.parent.replace(node, reference)


class Parser(CommonMarkParser):
    """MarkDown parser based on recommonmark.

    This parser is provisional:
    the API is not settled and may change with any minor Docutils version.
    """
    supported = ("recommonmark", "commonmark", "markdown", "md")
    """Formats this parser supports."""

    config_section = "recommonmark parser"
    config_section_dependencies = ("parsers",)

    def get_transforms(self):
        return Component.get_transforms(self)  # + [AutoStructify]

    def parse(self, inputstring: str, document: nodes.document) -> None:
        """Wrapper of upstream method.

        Ensure "line-length-limt". Report errors with `document.reporter`.
        """
        # check for exorbitantly long lines
        for i, line in enumerate(inputstring.split("\n")):
            if len(line) > document.settings.line_length_limit:
                error = document.reporter.error(
                    "Line %d exceeds the line-length-limit." % (i+1))
                document.append(error)
                return

        # pass to upstream parser
        try:
            CommonMarkParser.parse(self, inputstring, document)
        except Exception as err:
            if document.settings.traceback:
                raise
            error = document.reporter.error('Parsing with "recommonmark" '
                                            "returned the error:\n%s" % err)
            document.append(error)

    # Post-Processing
    # ---------------

    def finish_parse(self) -> None:
        """Finalize parse details.  Call at end of `self.parse()`."""
        document = self.document
        _merge_text_nodes(document)
        _normalize_literals(document)
        if not document.settings.raw_enabled:
            _replace_raw_nodes(document)
        _drop_pending_xrefs(document)
        # now we are ready to call the upstream function:
        super().finish_parse()

    def visit_document(self, node: nodes.document) -> None:
        """Dummy function to prevent spurious warnings.

        cf. https://github.com/readthedocs/recommonmark/issues/177
        """

    # Overwrite parent method with version that
    # doesn't pass deprecated `rawsource` argument to nodes.Text:
    def visit_text(self, mdnode) -> None:
        self.current_node.append(nodes.Text(mdnode.literal))
