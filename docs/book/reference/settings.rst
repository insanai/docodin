.. _settings:

========
Settings
========

docodin uses docutils' settings everywhere: in the docutils package, in the native
pipeline, in ``publish_native`` and in the native ``docodin`` command.  This chapter lists
the settings that the native pipeline knows, with their defaults, and the other places
where docodin is configured: the Sphinx extension, the language server and the
documentation projects.

How settings are given
======================

- **Command line**: the options of :doc:`cli`.
- **Python**: ``settings_overrides`` of ``publish_string``, ``publish_parts`` and
  ``publish_native``, keyed by setting name.  ``publish_native`` accepts the values that
  docutils accepts: Python values, or strings, which are converted as docutils'
  validators convert command-line values (thresholds such as ``"warning"``, booleans,
  encodings with an error handler such as ``"ascii:strict"``, comma-separated lists).
- **Configuration files**: read by docutils and by the Python ``docodin`` command, not
  by the native command (``--config`` runs the document through Python).

Settings of the native pipeline
===============================

The native publisher starts from docutils' defaults for the chosen writer, exactly as
``docutils.frontend.get_default_settings`` computes them with configuration files
disabled, and applies the overrides in order.  The table lists every setting with its
default and the options that set it.  "all" means the pseudoxml, xml, html5, latex and
xetex writers.  The html5 writer's ``stylesheet_dirs`` and ``template`` default to the
docutils package directory's ``writers/html5_polyglot`` files; the native command uses
the copies in docodin's docutils package.

.. list-table::
   :header-rows: 1
   :widths: 30 18 24 28

   * - Setting
     - Writers
     - Default
     - Options

   * - ``attribution``
     - html5, latex, xetex
     - ``"dash"``
     - ``--attribution``

   * - ``auto_id_prefix``
     - all
     - ``"%"``
     - ``--auto-id-prefix``

   * - ``character_level_inline_markup``
     - all
     - False
     - ``--word-level-inline-markup``, ``--character-level-inline-markup``

   * - ``cloak_email_addresses``
     - html5
     - None
     - ``--cloak-email-addresses``

   * - ``compact_field_lists``
     - html5
     - True
     - ``--compact-field-lists``, ``--no-compact-field-lists``

   * - ``compact_lists``
     - html5
     - True
     - ``--compact-lists``, ``--no-compact-lists``

   * - ``compound_enumerators``
     - latex, xetex
     - False
     - ``--compound-enumerators``, ``--no-compound-enumerators``

   * - ``config``
     - all
     - None
     - ``--config``

   * - ``datestamp``
     - all
     - None
     - ``-d``, ``--date``, ``-t``, ``--time``, ``--no-datestamp``

   * - ``debug``
     - all
     - None
     - ``--debug``, ``--no-debug``

   * - ``detailed``
     - pseudoxml
     - None
     - ``--detailed``

   * - ``docinfo_xform``
     - all
     - True
     - ``--no-doc-info``

   * - ``doctitle_xform``
     - all
     - True
     - ``--no-doc-title``

   * - ``doctype_declaration``
     - xml
     - ``1``
     - ``--no-doctype``

   * - ``documentclass``
     - latex, xetex
     - ``"article"``
     - ``--documentclass``

   * - ``documentoptions``
     - latex, xetex
     - ``"a4paper"``
     - ``--documentoptions``

   * - ``docutils_footnotes``
     - latex, xetex
     - True
     - ``--docutils-footnotes``

   * - ``dump_internals``
     - all
     - None
     - ``--dump-internals``

   * - ``dump_pseudo_xml``
     - all
     - None
     - ``--dump-pseudo-xml``

   * - ``dump_settings``
     - all
     - None
     - ``--dump-settings``

   * - ``dump_transforms``
     - all
     - None
     - ``--dump-transforms``

   * - ``embed_images``
     - html5
     - None
     - ``--embed-images``, ``--link-images``

   * - ``embed_stylesheet``
     - html5
     - True
     - ``--embed-stylesheet``, ``--link-stylesheet``

   * - ``embed_stylesheet``
     - latex, xetex
     - False
     - ``--embed-stylesheet``, ``--link-stylesheet``

   * - ``error_encoding``
     - all
     - ``"utf-8"``
     - ``-e``, ``--error-encoding``

   * - ``error_encoding_error_handler``
     - all
     - ``"backslashreplace"``
     - ``--error-encoding-error-handler``

   * - ``exit_status_level``
     - all
     - ``5``
     - ``--exit-status``

   * - ``expose_internals``
     - all
     - None
     - ``--expose-internal-attribute``

   * - ``file_insertion_enabled``
     - all
     - True
     - ``--no-file-insertion``, ``--file-insertion-enabled``

   * - ``font_encoding``
     - latex
     - ``"T1"``
     - ``--font-encoding``

   * - ``fontencoding``
     - xetex
     - ``""``
     - (none)

   * - ``footnote_backlinks``
     - all
     - True
     - ``--footnote-backlinks``, ``--no-footnote-backlinks``

   * - ``footnote_references``
     - html5
     - ``"brackets"``
     - ``--footnote-references``

   * - ``footnote_references``
     - latex, xetex
     - ``"superscript"``
     - ``--footnote-references``

   * - ``generator``
     - all
     - None
     - ``-g``, ``--generator``, ``--no-generator``

   * - ``graphicx_option``
     - latex, xetex
     - ``""``
     - ``--graphicx-option``

   * - ``halt_level``
     - all
     - ``4``
     - ``--halt``, ``--strict``

   * - ``hyperlink_color``
     - latex, xetex
     - ``"blue"``
     - ``--hyperlink-color``

   * - ``hyperref_options``
     - latex, xetex
     - ``""``
     - ``--hyperref-options``

   * - ``id_prefix``
     - all
     - ``""``
     - ``--id-prefix``

   * - ``image_loading``
     - html5
     - None
     - ``--image-loading``

   * - ``indents``
     - xml
     - None
     - ``--indents``

   * - ``initial_header_level``
     - html5
     - ``"2"``
     - ``--initial-header-level``

   * - ``input_encoding``
     - all
     - ``"utf-8"``
     - ``--input-encoding``

   * - ``input_encoding_error_handler``
     - all
     - ``"strict"``
     - ``--input-encoding-error-handler``

   * - ``language_code``
     - all
     - ``"en"``
     - ``-l``, ``--language``

   * - ``latex_preamble``
     - latex
     - docutils' LaTeX preamble
     - ``--latex-preamble``

   * - ``latex_preamble``
     - xetex
     - docutils' XeTeX preamble (Linux Libertine, DejaVu Sans Mono)
     - ``--latex-preamble``

   * - ``legacy_class_functions``
     - latex, xetex
     - False
     - ``--legacy-class-functions``, ``--new-class-functions``

   * - ``legacy_column_widths``
     - latex, xetex
     - None
     - ``--legacy-column-widths``, ``--new-column-widths``

   * - ``line_length_limit``
     - all
     - ``10000``
     - ``--line-length-limit``

   * - ``literal_block_env``
     - latex, xetex
     - ``""``
     - ``--literal-block-env``

   * - ``math_output``
     - html5
     - ``"MathML"``
     - ``--math-output``

   * - ``newlines``
     - xml
     - None
     - ``--newlines``

   * - ``output_encoding``
     - all
     - ``"utf-8"``
     - ``--output-encoding``

   * - ``output_encoding_error_handler``
     - pseudoxml, latex, xetex
     - ``"strict"``
     - ``--output-encoding-error-handler``

   * - ``output_encoding_error_handler``
     - xml, html5
     - ``"xmlcharrefreplace"``
     - ``--output-encoding-error-handler``

   * - ``output_path``
     - all
     - None
     - ``--output-path``, ``--output``, ``-o``

   * - ``pep_base_url``
     - all
     - ``"https://peps.python.org/"``
     - ``--pep-base-url``

   * - ``pep_file_url_template``
     - all
     - ``"pep-%04d"``
     - ``--pep-file-url-template``

   * - ``pep_references``
     - all
     - None
     - ``--pep-references``

   * - ``raw_enabled``
     - all
     - True
     - ``--no-raw``, ``--raw-enabled``

   * - ``reference_label``
     - latex, xetex
     - ``""``
     - ``--reference-label``

   * - ``report_level``
     - all
     - ``2``
     - ``-r``, ``--report``, ``-v``, ``--verbose``, ``-q``, ``--quiet``

   * - ``rfc_base_url``
     - all
     - ``"https://tools.ietf.org/html/"``
     - ``--rfc-base-url``

   * - ``rfc_references``
     - all
     - None
     - ``--rfc-references``

   * - ``root_prefix``
     - all
     - ``""``
     - ``--root-prefix``

   * - ``section_enumerator_separator``
     - latex, xetex
     - ``"-"``
     - ``--section-enumerator-separator``

   * - ``section_prefix_for_enumerators``
     - latex, xetex
     - None
     - ``--section-prefix-for-enumerators``, ``--no-section-prefix-for-enumerators``

   * - ``section_self_link``
     - html5
     - False
     - ``--section-self-link``, ``--no-section-self-link``

   * - ``sectnum_xform``
     - all
     - True
     - ``--section-numbering``, ``--no-section-numbering``

   * - ``sectsubtitle_xform``
     - all
     - False
     - ``--section-subtitles``, ``--no-section-subtitles``

   * - ``smart_quotes``
     - all
     - False
     - ``--smart-quotes``

   * - ``smartquotes_locales``
     - all
     - None
     - ``--smartquotes-locales``

   * - ``source_link``
     - all
     - None
     - ``-s``, ``--source-link``, ``--no-source-link``

   * - ``source_url``
     - all
     - None
     - ``--source-url``

   * - ``strict_visitor``
     - all
     - None
     - ``--strict-visitor``

   * - ``strip_classes``
     - all
     - None
     - ``--strip-class``

   * - ``strip_comments``
     - all
     - None
     - ``--strip-comments``, ``--leave-comments``

   * - ``strip_elements_with_classes``
     - all
     - None
     - ``--strip-elements-with-class``

   * - ``stylesheet``
     - html5
     - None
     - ``--stylesheet``

   * - ``stylesheet``
     - latex, xetex
     - ``""``
     - ``--stylesheet``

   * - ``stylesheet_dirs``
     - latex, xetex
     - ``"."``
     - ``--stylesheet-dirs``

   * - ``stylesheet_path``
     - html5
     - ``"minimal.css,plain.css"``
     - ``--stylesheet-path``

   * - ``stylesheet_path``
     - latex, xetex
     - None
     - ``--stylesheet-path``

   * - ``syntax_highlight``
     - all
     - ``"long"``
     - ``--syntax-highlight``

   * - ``tab_width``
     - all
     - ``8``
     - ``--tab-width``

   * - ``table_style``
     - html5
     - ``""``
     - ``--table-style``

   * - ``table_style``
     - latex, xetex
     - ``"standard"``
     - ``--table-style``

   * - ``template``
     - latex
     - ``"default.tex"``
     - ``--template``

   * - ``template``
     - xetex
     - ``"xelatex.tex"``
     - ``--template``

   * - ``title``
     - all
     - None
     - ``--title``

   * - ``toc_backlinks``
     - all
     - ``"entry"``
     - ``--toc-entry-backlinks``, ``--toc-top-backlinks``, ``--no-toc-backlinks``

   * - ``traceback``
     - all
     - None
     - ``--traceback``, ``--no-traceback``

   * - ``trim_footnote_reference_space``
     - all
     - None
     - ``--trim-footnote-reference-space``, ``--leave-footnote-reference-space``

   * - ``use_bibtex``
     - latex, xetex
     - ``""``
     - ``--use-bibtex``

   * - ``use_latex_abstract``
     - latex, xetex
     - False
     - ``--topic-abstract``, ``--use-latex-abstract``

   * - ``use_latex_citations``
     - latex, xetex
     - None
     - ``--use-latex-citations``, ``--figure-citations``

   * - ``use_latex_docinfo``
     - latex, xetex
     - False
     - ``--use-docutils-docinfo``, ``--use-latex-docinfo``

   * - ``use_latex_toc``
     - latex, xetex
     - True
     - ``--use-latex-toc``, ``--use-docutils-toc``

   * - ``use_part_section``
     - latex, xetex
     - False
     - ``--use-part-section``

   * - ``use_verbatim_when_possible``
     - latex, xetex
     - None
     - ``--use-verbatim-when-possible``

   * - ``validate``
     - all
     - None
     - ``--validate``, ``--no-validation``

   * - ``xml_declaration``
     - xml
     - ``1``
     - ``--no-xml-declaration``, ``--xml-declaration``

   * - ``xml_declaration``
     - html5
     - False
     - ``--no-xml-declaration``, ``--xml-declaration``

Setting names in Python and options differ in a few places: the "no" options set a
boolean to ``False`` (``--no-doc-title`` sets ``doctitle_xform``), ``--report``, ``-v``
and ``-q`` all set ``report_level``, and ``--strict`` sets ``halt_level`` to info.  Levels
are numbers in Python (1 info, 2 warning, 3 error, 4 severe, 5 none).  The front-end
settings ``warning_stream`` (``--warnings``) and ``record_dependencies``
(``--record-dependencies``) are handled by the command and by ``publish_native``
directly.

The Sphinx extension
====================

``docodin_gc_tuning``
   A ``conf.py`` value registered by ``docodin.sphinx``.  Default ``False``; ``True``
   tunes the garbage collector for the build.

The language server
===================

``docodin-lsp`` reads ``reportLevel``, ``debounce``, ``sphinx``, ``knownRoles`` and
``knownDirectives`` from ``initializationOptions`` or the ``docodin`` section of the
workspace configuration (:doc:`../guide/editors`).

Documentation projects
======================

``docodin book build`` reads these module-level assignments from a project's
``conf.py``; everything else in the file is for Sphinx and is ignored.

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Value
     - Meaning
   * - ``project``, ``author``, ``copyright``
     - the title and credits of the site and the PDF
   * - ``version``, ``release``
     - the short and full version
   * - ``html_title``
     - the title of the HTML site (default: ``project``)
   * - ``language``
     - the document language
   * - ``root_doc`` or ``master_doc``
     - the root document (default: ``index``)
   * - ``exclude_patterns``
     - glob patterns of files that are not documents
   * - ``numfig``
     - number figures and tables
   * - ``today_fmt``
     - the date format (``strftime``)
   * - ``docodin_tagline``
     - a subtitle for the site header and the PDF title page
   * - ``docodin_part_labels``
     - label the top-level sections of the root document "Part I", "Part II", ...
   * - ``docodin_pdf_filename``
     - the file name of the PDF
