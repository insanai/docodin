"""PEP HTML Writer."""

from __future__ import annotations

import os
import os.path
import random
from typing import Any

from docutils import frontend, nodes, utils
from docutils.writers import html4css1

__docformat__ = "reStructuredText"


class Writer(html4css1.Writer):
    default_stylesheet = "pep.css"

    default_stylesheet_path = utils.relative_path(
        os.path.join(os.getcwd(), "dummy"),
        os.path.join(os.path.dirname(__file__), default_stylesheet))

    default_template = "template.txt"

    default_template_path = utils.relative_path(
        os.path.join(os.getcwd(), "dummy"),
        os.path.join(os.path.dirname(__file__), default_template))

    settings_spec = html4css1.Writer.settings_spec + (
        "PEP/HTML Writer Options",
        "For the PEP/HTML writer, the default value for the --stylesheet-path "
        'option is "%s", and the default value for --template is "%s". '
        "See HTML Writer Options above."
        % (default_stylesheet_path, default_template_path),
        (('Python\'s home URL.  Default is "https://www.python.org".',
          ["--python-home"],
          {"default": "https://www.python.org", "metavar": "<URL>"}),
         ('Home URL prefix for PEPs.  Default is "." (current directory).',
          ["--pep-home"],
          {"default": ".", "metavar": "<URL>"}),
         # For testing.
         (frontend.SUPPRESS_HELP,
          ["--no-random"],
          {"action": "store_true", "validator": frontend.validate_boolean}),))

    settings_default_overrides = {"stylesheet_path": default_stylesheet_path,
                                  "template": default_template_path}
    relative_path_settings = ("template",)
    config_section = "pep_html writer"
    config_section_dependencies = ("writers", "html writers", "html4css1 writer")

    def __init__(self) -> None:
        html4css1.Writer.__init__(self)
        self.translator_class = HTMLTranslator

    def interpolation_dict(self) -> dict[str, Any]:
        subs = html4css1.Writer.interpolation_dict(self)
        settings = self.document.settings
        pyhome = settings.python_home
        subs["pyhome"] = pyhome
        subs["pephome"] = settings.pep_home
        subs["pepindex"] = "." if pyhome == ".." else pyhome + "/dev/peps"
        index = self.document.first_child_matching_class(nodes.field_list)
        header = self.document[index]
        self.pepnum = header[0][1].astext()
        subs["pep"] = self.pepnum
        subs["banner"] = 0 if settings.no_random else random.randrange(64)
        try:
            subs["pepnum"] = "%04i" % int(self.pepnum)
        except ValueError:
            subs["pepnum"] = self.pepnum
        self.title = header[1][1].astext()
        subs["title"] = self.title
        subs["body"] = "".join(self.body_pre_docinfo + self.docinfo + self.body)
        return subs

    def assemble_parts(self) -> None:
        html4css1.Writer.assemble_parts(self)
        self.parts["title"] = [self.title]
        self.parts["pepnum"] = self.pepnum


class HTMLTranslator(html4css1.HTMLTranslator):

    def depart_field_list(self, node: nodes.Element) -> None:
        html4css1.HTMLTranslator.depart_field_list(self, node)
        if "rfc2822" in node["classes"]:
            self.body.append("<hr />\n")
