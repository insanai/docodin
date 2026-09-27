package transforms_tests

import "core:testing"
import "core:time"

import dt "../../doctree"
import tf ".."

// Unit tests of the transform helpers; the transforms themselves are tested
// against docutils by tests/native_transforms_differential.py.

@(test)
test_normalize_language_tag :: proc(t: ^testing.T) {
	cases := [?]struct {
		tag:  string,
		want: []string,
	} {
		{"de_AT-1901", {"de-at-1901", "de-at", "de-1901", "de"}},
		{"de-CH-x_altquot", {"de-ch-x-altquot", "de-ch", "de-x-altquot", "de"}},
		{"en", {"en"}},
		{"en-GB", {"en-gb", "en"}},
		{"zh-Hans-CN", {"zh-hans-cn", "zh-hans", "zh-cn", "zh"}},
	}
	for c in cases {
		got := tf.normalize_language_tag(c.tag)
		testing.expectf(t, len(got) == len(c.want), "%s: %v", c.tag, got)
		for g, i in got {
			if i < len(c.want) do testing.expectf(t, g == c.want[i], "%s: %v", c.tag, got)
		}
	}
}

@(test)
test_priority_string :: proc(t: ^testing.T) {
	testing.expect_value(t, tf.priority_string(210, 3), "210-003")
	testing.expect_value(t, tf.priority_string(0, 1234), "000-1234")
	// serials past 999 sort as strings, as in docutils
	testing.expect(t, tf.priority_string(850, 1000) < tf.priority_string(850, 999))
}

@(test)
test_rcs_keywords :: proc(t: ^testing.T) {
	doc := dt.new_default_document("test.rst")
	defer dt.destroy(doc)
	cases := [?]struct {
		text, want: string,
		pep:        bool,
	} {
		{"$Date: 2006-05-21 22:44:42 +0200 (Sun, 21 May 2006) $", "2006-05-21", false},
		{"$date: 2006/05/21T22:44 $", "2006-05-21", false},
		{"$RCSfile: frontmatter.py,v $", "frontmatter.py", false},
		{"$Revision: 1.2 $ and $Id: x $", "1.2 $ and $Id: x", false},
		{"$Revision: 1.2 $", "1.2", true},
		{"$Revision: 1.2 $ x", "$Revision: 1.2 $ x", true},
		{"no keyword", "no keyword", false},
	}
	for c in cases {
		para := dt.new_element(doc, .paragraph, "", c.text)
		patterns := tf.PEP_RCS_KEYWORDS if c.pep else tf.DOCINFO_RCS_KEYWORDS
		tf.clean_rcs_keywords(doc, para, patterns)
		testing.expectf(t, dt.astext(doc, para) == c.want, "%q: %q", c.text, dt.astext(doc, para))
	}
}

@(test)
test_relative_path :: proc(t: ^testing.T) {
	testing.expect_value(t, tf.relative_path("/a/b/out.html", "/a/c/src.rst"), "../c/src.rst")
	testing.expect_value(t, tf.relative_path("/a/out.html", "/a/src.rst"), "src.rst")
	testing.expect_value(t, tf.relative_path("/x/out.html", "/y/src.rst"), "/y/src.rst")
}

@(test)
test_strftime :: proc(t: ^testing.T) {
	stamp, _ := time.datetime_to_time(2024, 3, 5, 14, 7, 9)
	got := tf.strftime("%Y-%m-%d %H:%M:%S %j %b %a %%", stamp)
	testing.expect_value(t, got, "2024-03-05 14:07:09 065 Mar Tue %")
}

@(test)
test_populate_from_components :: proc(t: ^testing.T) {
	doc := dt.new_default_document("test.rst")
	defer dt.destroy(doc)
	tf.populate_from_components(doc, .Standalone, .Latex)
	testing.expect_value(t, len(doc.pending_queue), 22)
	first := doc.pending_queue[0].transform
	testing.expect_value(t, first, "docutils.transforms.universal.Decorations")
	last := doc.pending_queue[len(doc.pending_queue) - 1]
	testing.expect_value(t, last.transform, "docutils.transforms.references.CitationReferences")
	testing.expect_value(t, last.serial, 22)
}

@(test)
test_apply_all_empty_document :: proc(t: ^testing.T) {
	doc := dt.new_default_document("test.rst")
	defer dt.destroy(doc)
	doc.reporter.stream = .Collect
	tf.populate_from_components(doc, .Standalone, .Pseudoxml)
	_, err := tf.apply_all(doc)
	testing.expect(t, err == nil)
	testing.expect_value(t, len(doc.pending_queue), 0)
	testing.expect_value(t, len(doc.reporter.observers), 0)
}
