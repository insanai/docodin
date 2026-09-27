"""Directives for figures and simple images."""

from __future__ import annotations

from typing import Any
from urllib.request import url2pathname

from docutils import nodes
from docutils.nodes import fully_normalize_name, whitespace_normalize_name
from docutils.parsers.rst import Directive, directives, states
from docutils.parsers.rst.roles import normalize_options

try:  # check for the Python Imaging Library
    import PIL.Image
except ImportError:
    PIL = None

__docformat__ = "reStructuredText"


class Image(Directive):
    align_h_values = ("left", "center", "right")
    align_v_values = ("top", "middle", "bottom")
    align_values = align_v_values + align_h_values
    loading_values = ("embed", "link", "lazy")

    def align(argument: str) -> str:  # noqa: N805 - option converter
        # This is not callable as `self.align()`.  We cannot make it a
        # staticmethod because we're saving an unbound method in option_spec below.
        return directives.choice(argument, Image.align_values)

    def loading(argument: str) -> str:  # noqa: N805 - option converter
        return directives.choice(argument, Image.loading_values)

    required_arguments = 1
    optional_arguments = 0
    final_argument_whitespace = True
    option_spec = {
        "alt": directives.unchanged,
        "height": directives.length_or_unitless,
        "width": directives.length_or_percentage_or_unitless,
        "scale": directives.percentage,
        "align": align,
        "target": directives.unchanged_required,
        "loading": loading,
        "class": directives.class_option,
        "name": directives.unchanged,
    }

    def run(self) -> list[nodes.Node]:
        self._check_align()
        messages: list[nodes.Node] = []
        self.options["uri"] = directives.uri(self.arguments[0])
        reference_node = None
        if "target" in self.options:
            reference_node = self._target_reference(messages)
            del self.options["target"]
        options = normalize_options(self.options)
        image_node = nodes.image(self.block_text, **options)
        image_node.source, image_node.line = self.state_machine.get_source_and_line(self.lineno)
        self.add_name(image_node)
        if reference_node:
            reference_node += image_node
            return [*messages, reference_node]
        return [*messages, image_node]

    def _check_align(self) -> None:
        if "align" not in self.options:
            return
        align = self.options["align"]
        if isinstance(self.state, states.SubstitutionDef):
            # Check for align_v_values.
            if align not in self.align_v_values:
                raise self.error(
                    'Error in "%s" directive: "%s" is not a valid value for the "align" option '
                    'within a substitution definition.  Valid values for "align" are: "%s".'
                    % (self.name, align, '", "'.join(self.align_v_values)))
        elif align not in self.align_h_values:
            raise self.error(
                'Error in "%s" directive: "%s" is not a valid value for the "align" option.  '
                'Valid values for "align" are: "%s".'
                % (self.name, align, '", "'.join(self.align_h_values)))

    def _target_reference(self, messages: list[nodes.Node]) -> Any:
        block = states.escape2null(self.options["target"]).splitlines()
        target_type, data = self.state.parse_target(list(block), self.block_text, self.lineno)
        if target_type == "refuri":
            return nodes.reference(refuri=data)
        if target_type == "refname":
            reference_node = nodes.reference(refname=fully_normalize_name(data),
                                             name=whitespace_normalize_name(data))
            reference_node.indirect_reference_name = data
            self.state.document.note_refname(reference_node)
            return reference_node
        messages.append(data)  # data is a system message
        return None


class Figure(Image):
    def align(argument: str) -> str:  # noqa: N805 - option converter
        return directives.choice(argument, Figure.align_h_values)

    def figwidth_value(argument: str) -> str:  # noqa: N805 - option converter
        if argument.lower() == "image":
            return "image"
        return directives.length_or_percentage_or_unitless(argument, "px")

    option_spec = Image.option_spec.copy()
    option_spec["figwidth"] = figwidth_value
    option_spec["figclass"] = directives.class_option
    option_spec["figname"] = directives.unchanged
    option_spec["align"] = align
    has_content = True

    def run(self) -> list[nodes.Node]:
        figwidth = self.options.pop("figwidth", None)
        figclasses = self.options.pop("figclass", None)
        figname = self.options.pop("figname", None)
        align = self.options.pop("align", None)
        (image_node,) = Image.run(self)
        if isinstance(image_node, nodes.system_message):
            return [image_node]
        figure_node = nodes.figure("", image_node)
        figure_node.source, figure_node.line = self.state_machine.get_source_and_line(
            self.lineno)
        self._set_width(figure_node, image_node, figwidth)
        if figclasses:
            figure_node["classes"] += figclasses
        if figname:
            figure_node["names"].append(nodes.fully_normalize_name(figname))
            self.state.document.note_explicit_target(figure_node, figure_node)
        if align:
            figure_node["align"] = align
        if self.content:
            error = self._caption_and_legend(figure_node)
            if error is not None:
                return [figure_node, error]
        return [figure_node]

    def _set_width(self, figure_node: nodes.figure, image_node: nodes.Element,
                   figwidth: str | None) -> None:
        if figwidth is None:
            return
        if figwidth != "image":
            figure_node["width"] = figwidth
            return
        if PIL and self.state.document.settings.file_insertion_enabled:
            imagepath = url2pathname(image_node["uri"])
            try:
                with PIL.Image.open(imagepath) as img:
                    figure_node["width"] = "%dpx" % img.size[0]
            except (OSError, UnicodeEncodeError):
                pass  # TODO: warn/info?
            else:
                self.state.document.settings.record_dependencies.add(
                    imagepath.replace("\\", "/"))

    def _caption_and_legend(self, figure_node: nodes.figure) -> nodes.system_message | None:
        """Optional caption (single paragraph or empty comment) + optional legend."""
        node = nodes.Element()  # anonymous container for parsing
        self.state.nested_parse(self.content, self.content_offset, node)
        index = 0  # of the caption (or the last node before the legend)
        for child in node:
            # skip temporary nodes that will be removed by transforms
            if isinstance(child, (nodes.target, nodes.pending)):
                figure_node += child
                index += 1
                continue
            if isinstance(child, nodes.paragraph):
                caption = nodes.caption(child.rawsource, "", *child.children)
                caption.source = child.source
                caption.line = child.line
                figure_node += caption
                break
            if isinstance(child, nodes.comment) and len(child) == 0:
                break
            return self.reporter.error("Figure caption must be a paragraph or empty comment.",
                                       nodes.literal_block(self.block_text, self.block_text),
                                       line=self.lineno)
        if len(node) > index + 1:
            figure_node += nodes.legend("", *node[index + 1:])
        return None
