===================
Third-party notices
===================

docodin is released under the MIT license (``LICENSE``).  It contains or is derived from
the following third-party works, whose license texts are in ``LICENSES/``.

Docutils 0.22.4
===============

docodin implements the API of Docutils (https://docutils.sourceforge.io/).  Its docutils
package (``python/docodin/shim/docutils``) includes Docutils' data files: stylesheets,
templates, the LaTeX package ``docutils.sty``, the standard include files and language
data.  The native tools embed the stylesheets, templates, ``docutils.sty`` and standard
include files, and the native modules port Docutils' algorithms, among them smart quotes
(``odin/text``) and the LaTeX math converters (``odin/math``).

Most of Docutils is in the public domain.  The exceptions that docodin includes or ports
are released under the 2-Clause BSD license (``LICENSES/BSD-2-Clause.rst``):

- ``docutils/utils/smartquotes.py``: © 2010-2023 Günter Milde, based on SmartyPants
  © 2003 John Gruber (3-Clause BSD license) and smartypants.py © 2004, 2007 Chad Miller
  (``LICENSES/SmartyPants.rst``);
- ``docutils/utils/math/latex2mathml.py``: © Jens Jørgen Mortensen, Günter Milde;
- ``docutils/utils/math/math2html.py`` and ``docutils/writers/html5_polyglot/math.css``:
  © 2009, 2010 Alex Fernández, 2021 Günter Milde;
- ``docutils/utils/punctuation_chars.py``, ``docutils/writers/html5_polyglot/*.css`` and
  ``docutils/writers/latex2e/docutils.sty``: © Günter Milde.

Docutils' own statement of its terms is ``LICENSES/docutils-COPYING.rst``.

Unicode Character Database
==========================

The character tables of the native engine (``odin/rst/unicode_tables.odin``,
``odin/doctree/unicode_tables.odin``, ``odin/math/unicode_tables.odin`` and
``odin/math/nfc_tables.odin``) are generated from the Unicode 16.0 data of CPython 3.14's
``unicodedata`` module.

Copyright © 1991-2023 Unicode, Inc.  Distributed under the Unicode License v3
(``LICENSES/Unicode-3.0.txt``).
