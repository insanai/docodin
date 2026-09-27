# A small Sphinx project for the native book builder's tests.
import datetime

project = "Fixture Book"
author = "Ada Lovelace"
copyright = f"2025-{datetime.date.today().year}, Ada Lovelace"
version = release = "1.2.3"
language = "en"
root_doc = "index"
exclude_patterns = ["_build", "drafts/*"]
numfig = True
docodin_tagline = "A tiny book to test docodin"
docodin_part_labels = True
docodin_pdf_filename = "fixture-book.pdf"

extensions = []
html_theme = "furo"
html_static_path = ["../../docs/theme", "_static"]
html_css_files = ["docodin.css"]
latex_engine = "lualatex"
latex_toplevel_sectioning = "part"
latex_documents = [
    ("index", "fixture-book.tex", project, author, "manual"),
]
latex_elements = {
    "papersize": "a4paper",
    "preamble": r"""
\usepackage{xcolor}
""",
}
