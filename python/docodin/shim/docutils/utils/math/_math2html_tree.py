"""Containers and their HTML outputs, the tree that `math2html` builds from TeX.

A `Container` holds a list of `contents` (other containers) and an `output` strategy that
turns the container into a list of HTML strings: its contents unchanged
(`ContentsOutput`), wrapped in a tag (`TaggedOutput`), replaced by fixed text
(`FixedOutput`), dropped (`EmptyOutput`), or a leaf's string (`StringOutput`).
"""

from __future__ import annotations

from collections.abc import Callable
from typing import Any

from docutils.utils.math._math2html_config import ContainerConfig
from docutils.utils.math._math2html_options import Trace

__docformat__ = "reStructuredText"


class ContainerOutput:
    """The HTML output of a container."""

    def gethtml(self, container: Container) -> list[str]:
        """Return the HTML of `container` as a list of strings."""
        raise NotImplementedError

    def isempty(self) -> bool:
        """Decide if the output is empty: by default, not empty."""
        return False


class EmptyOutput(ContainerOutput):
    """No output at all."""

    def gethtml(self, container: Container) -> list[str]:
        return []

    def isempty(self) -> bool:
        return True


class FixedOutput(ContainerOutput):
    """The container's fixed `html` replaces its contents."""

    def gethtml(self, container: Any) -> list[str]:
        return container.html


class ContentsOutput(ContainerOutput):
    """The concatenated output of the contents."""

    def gethtml(self, container: Container) -> list[str]:
        html: list[str] = []
        for element in container.contents or ():
            html += element.gethtml()
        return html


class TaggedOutput(ContentsOutput):
    """The contents wrapped in an HTML tag, like ``span class="fraction"``.

    An empty tag is reported and produces no markup; `breaklines` puts the tags on
    their own lines; `empty` makes a self-closing tag without contents.
    """

    tag: str | None = None
    breaklines = False
    empty = False

    def settag(self, tag: str | None, breaklines: bool = False,
               empty: bool = False) -> TaggedOutput:
        """Set the tag; `breaklines` and `empty` are only ever switched on."""
        self.tag = tag
        if breaklines:
            self.breaklines = breaklines
        if empty:
            self.empty = empty
        return self

    def setbreaklines(self, breaklines: bool) -> TaggedOutput:
        """Set the value for breaklines."""
        self.breaklines = breaklines
        return self

    def gethtml(self, container: Container) -> list[str]:
        if self.empty:
            return [self.selfclosing(container)]
        return [self.open(container), *super().gethtml(container), self.close(container)]

    def open(self, container: Container) -> str:
        """Return the opening tag."""
        if not self.checktag(container):
            return ""
        return f"<{self.tag}>" + ("\n" if self.breaklines else "")

    def close(self, container: Container) -> str:
        """Return the closing tag (the element name without attributes)."""
        if not self.checktag(container):
            return ""
        close = f"</{self.tag.split()[0]}>"
        return f"\n{close}\n" if self.breaklines else close

    def selfclosing(self, container: Container) -> str:
        """Return the self-closing tag."""
        if not self.checktag(container):
            return ""
        return f"<{self.tag}/>" + ("\n" if self.breaklines else "")

    def checktag(self, container: Container) -> bool:
        """Check that there is a tag; report an error if not."""
        if not self.tag:
            Trace.error("No tag in " + str(container))
            return False
        return True


class StringOutput(ContainerOutput):
    """The container's `string`."""

    def gethtml(self, container: Any) -> list[str]:
        return [container.string]


class Container:
    """A node of the formula tree."""

    parent: Container | None = None
    begin: int | None = None
    output: ContainerOutput

    def __init__(self) -> None:
        self.contents: list[Container] = []

    def process(self) -> None:
        """Post-process the container once the whole formula is parsed."""

    def gethtml(self) -> list[str]:
        """Return the HTML for the container as a list of strings."""
        return self.output.gethtml(self)

    def recursivesearch(self, locate: Callable[[Container], bool],
                        recursive: Callable[[Container], bool],
                        process: Callable[[Container], object]) -> None:
        """Walk the tree: descend into containers passing `recursive`, and call
        `process` on those passing `locate`."""
        for container in self.contents:
            if recursive(container):
                container.recursivesearch(locate, recursive, process)
            if locate(container):
                process(container)

    def extracttext(self) -> str:
        """Return the text of the string leaves reachable through textual containers."""
        constants = ContainerExtractor(ContainerConfig.extracttext).extract(self)
        return "".join(constant.string for constant in constants)

    def __str__(self) -> str:
        if not self.begin:
            return self.__class__.__name__
        return self.__class__.__name__ + "@" + str(self.begin)


class ContainerExtractor:
    """Collect the containers of the classes named `allowed` in a tree, looking into
    containers of the classes named `extracted` (and ignoring all others).

    Classes are matched by exact name, so subclasses are not included.
    """

    def __init__(self, config: dict[str, list[str]]) -> None:
        self.allowed = config["allowed"]
        self.extracted = config["extracted"]

    def extract(self, container: Container) -> list[Any]:
        """Extract the allowed containers from `container`."""
        found: list[Container] = []
        container.recursivesearch(lambda c: type(c).__name__ in self.allowed,
                                  lambda c: type(c).__name__ in self.extracted,
                                  found.append)
        return found


class StringContainer(Container):
    """A container for a single string."""

    def __init__(self) -> None:
        super().__init__()
        self.output = StringOutput()
        self.string = ""

    def extracttext(self) -> str:
        return self.string

    def __str__(self) -> str:
        result = "StringContainer"
        if self.begin:
            result += "@" + str(self.begin)
        text = self.string.strip()
        return f"{result} ({text[:15]}{'...' if len(text) > 15 else ''})"


class Constant(StringContainer):
    """A constant string."""

    def __init__(self, text: str) -> None:
        super().__init__()
        self.string = text

    def __str__(self) -> str:
        return "Constant: " + self.string
