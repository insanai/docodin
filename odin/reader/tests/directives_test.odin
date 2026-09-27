package reader_tests

import "core:testing"

import dt "../../doctree"
import reader ".."

// The directives ported last (images, tables, meta) and ``include`` parsed
// in the state machine of the directive, against docutils 0.22.4 output.

@(private = "file")
Case :: struct {
	name, text, want: string,
}

@(private = "file")
CASES := [?]Case {
	{
		"image_figure",
		".. image:: a.png\n" +
		"   :width: 50 %\n" +
		"   :target: `ref`_\n" +
		"\n" +
		".. figure:: f.png\n" +
		"   :figwidth: 3em\n" +
		"\n" +
		"   Caption.\n" +
		"\n" +
		"   Legend.\n",
		"<document source=\"test data\">\n" +
		"    <reference name=\"ref\" refname=\"ref\">\n" +
		"        <image uri=\"a.png\" width=\"50%\">\n" +
		"    <figure width=\"3em\">\n" +
		"        <image uri=\"f.png\">\n" +
		"        <caption>\n" +
		"            Caption.\n" +
		"        <legend>\n" +
		"            <paragraph>\n" +
		"                Legend.\n",
	},
	{
		"csv_table",
		".. csv-table:: T\n" +
		"   :header: \"A\", \"B\"\n" +
		"\n" +
		"   1, \"two, three\"\n" +
		"   4\n",
		"<document source=\"test data\">\n" +
		"    <table>\n" +
		"        <title>\n" +
		"            T\n" +
		"        <tgroup cols=\"2\">\n" +
		"            <colspec colwidth=\"50\">\n" +
		"            <colspec colwidth=\"50\">\n" +
		"            <thead>\n" +
		"                <row>\n" +
		"                    <entry>\n" +
		"                        <paragraph>\n" +
		"                            A\n" +
		"                    <entry>\n" +
		"                        <paragraph>\n" +
		"                            B\n" +
		"            <tbody>\n" +
		"                <row>\n" +
		"                    <entry>\n" +
		"                        <paragraph>\n" +
		"                            1\n" +
		"                    <entry>\n" +
		"                        <paragraph>\n" +
		"                            two, three\n" +
		"                <row>\n" +
		"                    <entry>\n" +
		"                        <paragraph>\n" +
		"                            4\n" +
		"                    <entry>\n",
	},
	{
		"list_table",
		".. list-table::\n" +
		"   :header-rows: 1\n" +
		"   :widths: 1 2\n" +
		"\n" +
		"   * - H1\n" +
		"     - H2\n" +
		"   * - a\n" +
		"     - b\n",
		"<document source=\"test data\">\n" +
		"    <table classes=\"colwidths-given\">\n" +
		"        <tgroup cols=\"2\">\n" +
		"            <colspec colwidth=\"1\">\n" +
		"            <colspec colwidth=\"2\">\n" +
		"            <thead>\n" +
		"                <row>\n" +
		"                    <entry>\n" +
		"                        <paragraph>\n" +
		"                            H1\n" +
		"                    <entry>\n" +
		"                        <paragraph>\n" +
		"                            H2\n" +
		"            <tbody>\n" +
		"                <row>\n" +
		"                    <entry>\n" +
		"                        <paragraph>\n" +
		"                            a\n" +
		"                    <entry>\n" +
		"                        <paragraph>\n" +
		"                            b\n",
	},
	{
		"meta",
		"Title\n" +
		"=====\n" +
		"\n" +
		".. meta::\n" +
		"   :keywords: a, b\n" +
		"   :description lang=en: D\n",
		"<document source=\"test data\">\n" +
		"    <meta content=\"a, b\" name=\"keywords\">\n" +
		"    <meta content=\"D\" lang=\"en\" name=\"description\">\n" +
		"    <section ids=\"title\" names=\"title\">\n" +
		"        <title>\n" +
		"            Title\n",
	},
	{
		"include_block_quote",
		" .. include:: <isonum.txt>\n" +
		"   :end-before: |copy|\n" +
		".. _tgt:\n",
		"<document source=\"test data\">\n" +
		"    <block_quote>\n" +
		"        <comment xml:space=\"preserve\">\n" +
		"            This data file has been placed in the public domain.\n" +
		"        <comment xml:space=\"preserve\">\n" +
		"            Derived from the Unicode character mappings available from\n" +
		"            <http://www.w3.org/2003/entities/xml/>.\n" +
		"            Processed by unicode2rstsubs.py, part of Docutils:\n" +
		"            <https://docutils.sourceforge.io>.\n" +
		"        <substitution_definition names=\"amp\">\n" +
		"            &\n" +
		"        <substitution_definition names=\"apos\">\n" +
		"            '\n" +
		"        <substitution_definition names=\"ast\">\n" +
		"            *\n" +
		"        <substitution_definition names=\"brvbar\">\n" +
		"            ¦\n" +
		"        <substitution_definition names=\"bsol\">\n" +
		"            \\\n" +
		"        <substitution_definition names=\"cent\">\n" +
		"            ¢\n" +
		"        <substitution_definition names=\"colon\">\n" +
		"            :\n" +
		"        <substitution_definition names=\"comma\">\n" +
		"            ,\n" +
		"        <substitution_definition names=\"commat\">\n" +
		"            @\n" +
		"        <comment xml:space=\"preserve\">\n" +
		"    <system_message level=\"2\" line=\"3\" source=\"test data\" type=\"WARNING\">\n" +
		"        <paragraph>\n" +
		"            Block quote ends without a blank line; unexpected unindent.\n" +
		"    <target ids=\"tgt\" names=\"tgt\">\n",
	},
}

@(test)
test_directives_against_docutils :: proc(t: ^testing.T) {
	for c in CASES {
		s := dt.default_settings()
		s.report_level = 5
		s.warning_stream = .Collect
		doc := reader.parse(c.text, s, "test data")
		got := dt.pformat(doc, doc.root, allocator = context.temp_allocator)
		testing.expectf(t, got == c.want, "%s:\n%s", c.name, got)
		dt.destroy(doc)
	}
	free_all(context.temp_allocator)
}
