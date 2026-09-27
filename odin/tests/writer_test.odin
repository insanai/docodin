package rst_tests

import "core:strings"
import "core:testing"

import rst "../rst"

// Tests of the native HTML and LaTeX emitters.

@(private = "file")
render_html :: proc(source: string, standalone := false) -> string {
	p := rst.Parser {
		allocator = context.allocator,
		settings  = rst.DEFAULT_SETTINGS,
	}
	doc, _, _ := rst.parse_text(&p, source, 0, true)
	return rst.write_html(doc, &p, rst.Html_Config{standalone = standalone})
}

@(private = "file")
render_latex :: proc(source: string, standalone := false, title := "") -> string {
	p := rst.Parser {
		allocator = context.allocator,
		settings  = rst.DEFAULT_SETTINGS,
	}
	doc, _, _ := rst.parse_text(&p, source, 0, true)
	return rst.write_latex(doc, &p, rst.Latex_Config{standalone = standalone, title = title})
}

@(private = "file")
expect_contains :: proc(t: ^testing.T, output, part: string, loc := #caller_location) {
	ok := strings.contains(output, part)
	testing.expectf(t, ok, "missing %q in:\n%s", part, output, loc = loc)
}

@(private = "file")
expect_absent :: proc(t: ^testing.T, output, part: string, loc := #caller_location) {
	ok := !strings.contains(output, part)
	testing.expectf(t, ok, "unexpected %q in:\n%s", part, output, loc = loc)
}

@(test)
writers_remove_escape_markers :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	source := "Escaped \\*star\\*, a\\ b, *em\\ph* and `ref\\ name`_.\n"
	html := render_html(source)
	expect_contains(t, html, "Escaped *star*, ab, <em>emph</em>")
	expect_absent(t, html, "\x00")
	latex := render_latex(source)
	expect_contains(t, latex, "Escaped *star*, ab, \\emph{emph}")
	expect_absent(t, latex, "\x00")
}

@(test)
html_escapes_attributes :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	source :=
		"`x <http://a/\"onmouseover=\"alert(1)>`_ and `q`_\n\n" +
		".. _q: http://b/'onclick='x\n\n" +
		".. image:: a.png\" onerror=\"alert(2)\n" +
		"   :alt: <b>\"alt\"</b>\n\n" +
		".. code:: python\" onload=\"alert(3)\n\n   print(1)\n\n" +
		".. admonition:: <script>alert(4)</script>\n\n   body\n"
	html := render_html(source)
	expect_contains(t, html, "href=\"http://a/&quot;onmouseover=&quot;alert(1)\"")
	expect_contains(t, html, "href=\"http://b/&#x27;onclick=&#x27;x\"")
	expect_contains(t, html, "src=\"a.png&quot; onerror=&quot;alert(2)\"")
	expect_contains(t, html, "alt=\"&lt;b&gt;&quot;alt&quot;&lt;/b&gt;\"")
	expect_contains(t, html, "<code class=\"language-python\">print(1)</code>")
	expect_contains(t, html, "&lt;script&gt;alert(4)&lt;/script&gt;")
	for bad in ([]string{"\"onmouseover", "'onclick", "\" onerror", "\" onload", "<script>"}) {
		expect_absent(t, html, bad)
	}
}

@(private = "file")
LINKS_SOURCE ::
	"Section One\n===========\n\n" +
	"See target_, `Section Two`_, `other <target_>`_, indirect_, `ext <http://e/>`_, ext_,\n" +
	"local_, missing_, an__ and `another`__.\n\n" +
	".. _target: http://example.com/a#b%c\n" +
	".. _indirect: target_\n" +
	".. _local:\n\n" +
	"__ http://anon1/\n" +
	"__ indirect_\n\n" +
	"Section Two\n===========\n\n" +
	"An _`inline target` and `inline target`_.\n"

@(test)
html_resolves_named_references :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	html := render_html(LINKS_SOURCE)
	to_target := "<a href=\"http://example.com/a#b%c\" class=\"reference\">"
	expect_contains(t, html, strings.concatenate({to_target, "target</a>"}))
	expect_contains(t, html, "<a href=\"#section-two\" class=\"reference\">Section Two</a>")
	expect_contains(t, html, "<h1 id=\"section-two\">Section Two</h1>")
	expect_contains(t, html, strings.concatenate({to_target, "other</a>"}))
	expect_contains(t, html, strings.concatenate({to_target, "indirect</a>"}))
	expect_contains(t, html, "<a href=\"http://e/\" class=\"reference\">ext</a>, " +
		"<a href=\"http://e/\" class=\"reference\">ext</a>")
	expect_contains(t, html, "<a href=\"#local\" class=\"reference\">local</a>")
	expect_contains(t, html, "<span id=\"local\"></span>")
	expect_contains(t, html, "<a href=\"#missing\" class=\"reference\">missing</a>")
	expect_contains(t, html, "<a href=\"http://anon1/\" class=\"reference\">an</a>")
	expect_contains(t, html, strings.concatenate({to_target, "another</a>"}))
	expect_contains(t, html, "<span id=\"inline-target\">inline target</span>")
	expect_contains(t, html, "<a href=\"#inline-target\" class=\"reference\">inline target</a>")
	expect_absent(t, html, "href=\"#\"")
}

@(test)
latex_resolves_and_escapes_references :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	latex := render_latex(LINKS_SOURCE)
	expect_contains(t, latex, "\\href{http://example.com/a\\#b\\%c}{target}")
	expect_contains(t, latex, "\\hyperref[section-two]{Section Two}")
	expect_contains(t, latex, "\\section{Section Two}\n\\label{section-two}")
	expect_contains(t, latex, "\\hyperref[local]{local}")
	expect_contains(t, latex, "\\phantomsection\\label{local}")
	expect_contains(t, latex, "\\href{http://anon1/}{an}")
	expect_contains(t, latex, "\\phantomsection\\label{inline-target}inline target")
	escaped := render_latex(
		"`a_b <http://x/{y}~z\\\\>`_\n\n.. image:: my_{img}%.png\n\n" +
		".. code::\n\n   \\end{alltt} $x$\n",
	)
	expect_contains(t, escaped, "\\href{http://x/\\{y\\}\\textasciitilde{}z\\\\}{a\\_b}")
	expect_contains(t, escaped, "\\includegraphics[max width=\\textwidth]{my_\\{img\\}\\%.png}")
	expect_contains(t, escaped, "\\textbackslash{}end\\{alltt\\} \\$x\\$")
}

@(test)
directive_options_stay_out_of_content :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	source :=
		".. code-block:: python\n   :linenos:\n   :emphasize-lines: 2\n\n   print(1)\n\n" +
		".. image:: pic.png\n   :alt: A picture\n   :width: 10px\n\n" +
		".. figure:: fig.png\n   :scale: 50\n\n   The caption.\n\n" +
		".. note:: First line.\n   :class: special\n\n   Second paragraph.\n\n" +
		".. admonition:: Custom *title*\n   :class: x\n\n   Body.\n\n" +
		".. raw:: html\n   :file: ignored\n\n   <hr>\n\n" +
		".. unknown:: argument\n   :option: value\n\n   Content.\n"
	html := render_html(source)
	expect_contains(t, html, "<code class=\"language-python\">print(1)</code>")
	expect_contains(t, html, "<img src=\"pic.png\" alt=\"A picture\" />")
	expect_contains(t, html, "<img src=\"fig.png\" alt=\"fig.png\" />")
	expect_contains(t, html, "<figcaption>\n<p>The caption.</p>\n</figcaption>")
	expect_contains(t, html, "<p class=\"admonition-title\">Note</p>\n<p>First line.</p>\n" +
		"<p>Second paragraph.</p>")
	expect_contains(t, html,
		"<p class=\"admonition-title\">Custom <em>title</em></p>\n<p>Body.</p>")
	expect_contains(t, html, "<hr>\n")
	expect_contains(t, html, "<p>Content.</p>")
	for leaked in ([]string{":linenos:", "emphasize", ":width:", ":scale:", ":class:", ":file:",
		":option:", "argument"}) {
		expect_absent(t, html, leaked)
	}
	latex := render_latex(source)
	expect_contains(t, latex, "\\textbf{Note:}\\newline\nFirst line.")
	expect_contains(t, latex, "\\textbf{Custom \\emph{title}:}\\newline\nBody.")
	expect_absent(t, latex, ":linenos:")
	expect_absent(t, latex, ":option:")
}

@(test)
standalone_title_is_rendered_once :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	source := "Main *Title*\n============\n\nText.\n\nPart\n----\n\nMore.\n"
	latex := render_latex(source, standalone = true)
	expect_contains(t, latex, "\\title{Main Title}")
	expect_contains(t, latex, "\\maketitle")
	expect_absent(t, latex, "section{Main")
	expect_contains(t, latex, "\\section{Part}")
	testing.expect_value(t, strings.count(latex, "Main"), 1)
	configured := render_latex(source, standalone = true, title = "Other")
	expect_contains(t, configured, "\\section{Main \\emph{Title}}")
	expect_contains(t, configured, "\\subsection{Part}")
	html := render_html(source, standalone = true)
	expect_contains(t, html, "<title>Main Title</title>")
	testing.expect_value(t, strings.count(html, "<h1"), 1)
}
