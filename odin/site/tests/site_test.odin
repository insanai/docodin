package site_tests

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import site ".."
import dt "../../doctree"

// Unit tests of the native Sphinx-project builder: conf.py, names and
// globs, the toctree graph and numbering, cross references and the search
// index.  tests/test_book.py builds whole projects through the CLI.

// --- conf.py -----------------------------------------------------------------------------

@(test)
conf_simple_assignments :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	c := site.parse_conf(`# comment
import datetime
project = "Demo"  # trailing comment
author = 'Ada'
version = release = "1.2"
html_title = project + " docs"
exclude_patterns = [
    "_build",   # a comment in a list
    "drafts/*",
]
numfig = True
docodin_part_labels = False
docodin_tagline = ("A tagline "
                   "on two lines")
latex_elements = {"papersize": "a4paper", "preamble": r"\usepackage{x}"}
setup = print("ignored")
def f():
    return 1
language = None
`)
	testing.expect_value(t, c.project, "Demo")
	testing.expect_value(t, c.author, "Ada")
	testing.expect_value(t, c.version, "1.2")
	testing.expect_value(t, c.release, "1.2")
	testing.expect_value(t, c.html_title, "Demo docs")
	testing.expect_value(t, len(c.exclude_patterns), 2)
	testing.expect_value(t, c.exclude_patterns[1], "drafts/*")
	testing.expect(t, c.numfig)
	testing.expect(t, !c.part_labels)
	testing.expect_value(t, c.tagline, "A tagline on two lines")
	testing.expect_value(t, c.root_doc, "index")
	_, has_setup := c.values["setup"]
	testing.expect(t, !has_setup)
	d, is_dict := c.values["latex_elements"].(site.Dict)
	testing.expect(t, is_dict && len(d.keys) == 2 && d.values[1].(string) == `\usepackage{x}`)
}

@(test)
conf_fstring_year :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	c := site.parse_conf(
		"author = \"Ada\"\ncopyright = f\"2025-{datetime.date.today().year}, {author}\"\n")
	testing.expect(t, strings.has_prefix(c.copyright, "2025-20"))
	testing.expect(t, strings.has_suffix(c.copyright, ", Ada"))
}

// --- names -------------------------------------------------------------------------------

@(test)
names_and_urls :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	testing.expect_value(t, site.docname_join("guide/intro", "usage"), "guide/usage")
	testing.expect_value(t, site.docname_join("guide/intro", "../index"), "index")
	testing.expect_value(t, site.docname_join("guide/intro", "/reference/api"), "reference/api")
	testing.expect_value(t, site.relative_url("guide/intro", "reference/api"),
		"../reference/api.html")
	testing.expect_value(t, site.relative_url("index", "guide/intro"), "guide/intro.html")
	testing.expect(t, site.glob_match("drafts/*", "drafts/a.rst"))
	testing.expect(t, !site.glob_match("drafts/*", "drafts2/a.rst"))
	testing.expect(t, site.glob_match("_build", "_build/html/x.rst"))
	testing.expect(t, site.glob_match("**/.ipynb_checkpoints", ".ipynb_checkpoints"))
	testing.expect(t, site.glob_match("[0-9]*", "0001-x"))
	testing.expect(t, !site.glob_match("*.rst", "a/b.rst"))
	testing.expect_value(t, site.roman(14), "XIV")
}

@(test)
explicit_titles :: proc(t: ^testing.T) {
	title, target, explicit := site.split_explicit_title("The guide <guide/intro>")
	testing.expect(t, explicit)
	testing.expect_value(t, title, "The guide")
	testing.expect_value(t, target, "guide/intro")
	_, target, explicit = site.split_explicit_title("guide/intro")
	testing.expect(t, !explicit)
	testing.expect_value(t, target, "guide/intro")
}

@(test)
only_expressions :: proc(t: ^testing.T) {
	testing.expect(t, site.eval_tags("html", .Html))
	testing.expect(t, !site.eval_tags("latex", .Html))
	testing.expect(t, site.eval_tags("not html", .Latex))
	testing.expect(t, site.eval_tags("(latex or html) and not epub", .Latex))
}

// --- a project ----------------------------------------------------------------------------

// A project in a fresh temporary directory.
@(private = "file")
make_project :: proc(t: ^testing.T, files: []string) -> string {
	tmp := os.get_env("TMPDIR", context.temp_allocator)
	if tmp == "" do tmp = "/tmp"
	// one directory per test (the tests run in parallel)
	dir, _ := filepath.join({tmp, fmt.tprintf("docodin-site-test-%d-%p", os.get_pid(), t)},
		context.temp_allocator)
	os.remove_all(dir)
	for i := 0; i + 1 < len(files); i += 2 {
		path, _ := filepath.join({dir, files[i]}, context.temp_allocator)
		os.make_directory_all(filepath.dir(path))
		// "@" stands for the backquote, which raw strings cannot hold
		text, _ := strings.replace_all(files[i + 1], "@", "`", context.temp_allocator)
		_ = os.write_entire_file(path, text)
	}
	return dir
}

@(private = "file")
PROJECT := []string {
	"conf.py", "project = 'P'\nnumfig = True\nexclude_patterns = ['_build']\n",
	"index.rst", `Root
====

Part A
------

.. toctree::
   :numbered:

   a/one
   a/two

See :ref:@two-label@, :doc:@a/one@, :term:@widget@, :numref:@fig-x@ and :ref:@nowhere@.
`,
	"a/one.rst", `One
===

Sub one
-------

.. glossary::

   widget
      A thing.
`,
	"a/two.rst", `.. _two-label:

Two
===

.. _fig-x:

.. figure:: missing.png

   A caption.

Deeper
------

.. toctree::

   three
`,
	"a/three.rst", "Three\n=====\n\nText.\n",
	"lonely.rst", "Lonely\n======\n",
}

@(private = "file")
doc_of :: proc(s: ^site.Site, name: string) -> site.Doc_Id {
	return s.by_name[name]
}

@(test)
toctree_graph_and_numbers :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := make_project(t, PROJECT)
	defer os.remove_all(dir)
	s, err := site.open_site(dir, "")
	testing.expect_value(t, err, "")
	defer site.destroy_site(s)
	b := site.build_make(s, .Html)
	defer site.build_destroy(b)
	one, two, three := doc_of(s, "a/one"), doc_of(s, "a/two"), doc_of(s, "a/three")
	testing.expect_value(t, b.pages[two].parent, s.root)
	testing.expect_value(t, b.pages[three].parent, two)
	testing.expect_value(t, b.pages[one].prev, s.root)
	testing.expect_value(t, b.pages[one].next, two)
	testing.expect_value(t, b.pages[three].prev, two)
	number := func_number(b, three)
	testing.expect_value(t, site.number_text(number), "2.1.1")
	testing.expect_value(t, site.number_text(func_number(b, one)), "1")
	testing.expect_value(t, site.numbered_title(b, two), "2. Two")
	fig := b.fignums[site.Fig_Key{two, "fig-x"}]
	testing.expect_value(t, site.number_text(fig), "2.1")
	// the lonely page is in no toctree
	testing.expect(t, strings.contains(warning_texts(s), "document isn't included in any toctree"))
}

@(private = "file")
func_number :: proc(b: ^site.Build, id: site.Doc_Id) -> []int {
	return b.toc[b.pages[id].toc].number
}

@(private = "file")
warning_texts :: proc(s: ^site.Site) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for w in s.warnings {
		strings.write_string(&sb, w.text)
		strings.write_byte(&sb, '\n')
	}
	return strings.to_string(sb)
}

@(test)
cross_references :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := make_project(t, PROJECT)
	defer os.remove_all(dir)
	s, _ := site.open_site(dir, "")
	defer site.destroy_site(s)
	b := site.build_make(s, .Html)
	defer site.build_destroy(b)
	site.prepare_html_page(b, s.root)
	doc := b.pages[s.root].doc
	uris := make([dynamic]string, context.temp_allocator)
	texts := make([dynamic]string, context.temp_allocator)
	for n in dt.traverse(doc, doc.root, dt.Tag_Set{.reference}) {
		append(&uris, dt.get_string(doc, n, dt.K_REFURI))
		append(&texts, dt.astext(doc, n))
	}
	joined := strings.join(uris[:], " ", context.temp_allocator)
	titles := strings.join(texts[:], "|", context.temp_allocator)
	testing.expect(t, strings.contains(joined, "a/two.html#two"), joined)
	testing.expect(t, strings.contains(joined, "a/one.html#term-widget"), joined)
	testing.expect(t, strings.contains(joined, "a/two.html#fig-x"), joined)
	testing.expect(t, strings.contains(titles, "Fig. 2.1"), titles)
	testing.expect(t, strings.contains(titles, "|Two|"), titles)
	testing.expect(t, strings.contains(titles, "1. One"), titles) // the rendered toctree
	testing.expect(t, strings.contains(warning_texts(s), "undefined label: 'nowhere'"))
}

@(test)
search_index_json :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := make_project(t, PROJECT)
	defer os.remove_all(dir)
	s, _ := site.open_site(dir, "")
	defer site.destroy_site(s)
	b := site.build_make(s, .Html)
	defer site.build_destroy(b)
	context.allocator = b.allocator
	ix := site.search_index_make(b)
	for i in 1 ..< len(s.docs) {
		id := site.Doc_Id(i)
		site.prepare_html_page(b, id)
		site.search_index_add(&ix, b, id)
	}
	json := site.search_index_json(&ix)
	testing.expect(t, strings.has_prefix(json, `{"docs":[{"n":"a/one","t":"One"`), json[:60])
	testing.expect(t, strings.contains(json, `"widget":[[0,`))
	testing.expect(t, strings.contains(json, `[0,"Sub one","sub-one"]`))
	words := site.search_words("The Quick-brown fox, a b", context.temp_allocator)
	testing.expect_value(t, len(words), 3)
	testing.expect_value(t, words[1], "brown")
}

@(test)
missing_documents_are_reported :: proc(t: ^testing.T) {
	files := []string {
		"conf.py", "project = 'P'\n",
		"index.rst", "Root\n====\n\n.. toctree::\n\n   nothere\n\n.. frobnicate::\n",
	}
	context.allocator = context.temp_allocator
	dir := make_project(t, files)
	defer os.remove_all(dir)
	s, _ := site.open_site(dir, "")
	defer site.destroy_site(s)
	b := site.build_make(s, .Html)
	defer site.build_destroy(b)
	texts := warning_texts(s)
	missing := "toctree contains reference to nonexisting document 'nothere'"
	testing.expect(t, strings.contains(texts, missing), texts)
	testing.expect(t, strings.contains(texts, `Unknown directive type "frobnicate".`), texts)
	testing.expect_value(t, site.max_level(s), 3)
}
