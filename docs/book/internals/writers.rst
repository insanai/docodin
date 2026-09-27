.. _writers:

===============
Native writers
===============

``odin/writers`` ports five docutils 0.22 writers: pseudo-XML, Docutils XML, HTML5
(``html5_polyglot``), LaTeX (``latex2e``) and XeLaTeX (``xetex``).  ``write`` translates a
transformed document into the writer's output and its ``publish_parts`` parts, byte for
byte as docutils does.

.. code-block:: text

   Writer_Name :: enum u8 { Pseudoxml, Xml, Html5, Latex, Xetex }

   write :: proc(doc: ^dt.Doc, writer: Writer_Name, settings: Settings,
                 allocator := context.allocator) -> (output: string, parts: Parts, err: string)

How a writer works
==================

Traversal
   Each translator walks the document with ``walkabout`` and dispatches on the node's
   tag through tables indexed by ``doctree.Tag`` of visit and depart procedures, the
   equivalent of docutils' ``visit_<node>`` and ``depart_<node>`` methods.  Unknown
   nodes behave as in docutils (``strict_visitor``).

Output collectors
   docutils' translators collect output in Python lists of strings, and some of their
   methods work on the list items: ``body[-1] == "<code>"``, ``del body[start:]``,
   ``out.pop()``, ``out[0]``.  ``Out`` keeps the text in one growing byte buffer and
   records where each item ("chunk") starts, so these operations keep their list
   semantics without a string per item.  There is one ``Out`` per document part.

Parts
   ``Parts`` holds the ``publish_parts`` parts in docutils' insertion order: ``whole``,
   ``body``, ``title``, ``head``, ``stylesheet`` and the rest, as each writer defines
   them.

Settings
   ``settings_for`` reads the writer settings from the document's settings, or from the
   dumped docutils settings of an interchange document (:doc:`interchange`).

Data files
   The stylesheets and templates of docutils' writers (``minimal.css``, ``plain.css``,
   ``math.css``, ``responsive.css``, ``tuftig.css``, the templates ``template.txt``,
   ``default.tex``, ``xelatex.tex``, ``titlepage.tex`` and ``titlingpage.tex``, and
   ``docutils.sty``) are embedded with ``#load`` from docodin's docutils package
   (``files.odin``).  With ``embed_stylesheet`` they are embedded in the output; otherwise
   they are linked by their path in the docutils package directory, as docutils links
   them.

Python formatting
   Where docutils formats numbers or strings with Python (``%``-formatting, ``repr``,
   float formatting for column widths), ``pyfmt.odin`` reproduces Python's results.

Errors
   Where docutils raises, ``err`` names the Python exception and its message, and the
   publisher reports it as docutils would.

The writers
===========

Pseudo-XML (``pseudoxml``)
   ``document.pformat()``, with ``detailed`` for the detailed form.

Docutils XML (``xml``)
   The XML of ``docutils_xml``, with ``newlines``, ``indents``, the XML declaration and
   the DOCTYPE as docutils writes them.

HTML5 (``html5``)
   ``html5_polyglot``: ``html_body.odin``, ``html_inline.odin``, ``html_tables.odin``,
   ``html_media.odin``, ``html_docinfo.odin``, ``html_math.odin`` and ``html_parts.odin``.
   It includes docutils' math output formats (MathML through the native
   ``latex2mathml``, HTML through the native ``math2html``, MathJax, LaTeX), table
   styles, footnote reference styles, image loading (``embed``, ``link``, ``lazy``), and
   embedded SVG images: ``svg.odin`` parses SVG code as
   ``xml.etree.ElementTree.fromstring`` does, sets the image attributes, and serialises
   it as ``ElementTree.tostring`` does.

LaTeX (``latex``) and XeLaTeX (``xetex``)
   ``latex2e`` and ``xetex``: ``latex_document.odin`` (the preamble, packages, template
   and parts), ``latex_body.odin``, ``latex_inline.odin``, ``latex_tables.odin`` (the
   ``longtable``, ``tabular`` and ``booktabs`` styles and column widths),
   ``latex_encode.odin`` (the escaping of special characters and Unicode) and
   ``latex_babel.odin`` (the Babel languages).  The XeLaTeX writer differs in the
   template, the preamble (fonts through ``fontspec``) and the encoding handling.

What is not ported
==================

The manual page, ODT, S5, PEP and HTML4 writers remain Python-only in docodin's docutils
package.  Asking the native pipeline for them is a Python need: the hosts publish the
document with docutils.

Verification
============

``tests/native_writers_differential.py`` compares the writers' output and parts byte for
byte: on docutils' functional tests with their settings (also against
``test/functional/expected``), on the functional inputs and ``docs/**/*.rst`` with several
settings variants per writer, and on generated documents.  ``odin test
odin/writers/tests`` checks the ``output`` fixtures of the interchange, and with
``WRITERS_DUMP_DIR`` a whole corpus of dumps.
