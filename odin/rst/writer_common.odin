package rst

import "base:runtime"
import "core:strings"

// What the native HTML and LaTeX emitters (writer_html.odin,
// writer_latex.odin) share: hyperlink resolution, directive blocks and plain
// text.  These emitters are interim: exact ports of the docutils writers
// replace them (docs/NATIVE_PIPELINE.md).

// Where a reference points.
Link :: struct {
	kind:     enum u8 {External, Internal, Indirect},
	value:    string, // URI, anchor id, or the normalized name of the next target
	implicit: bool,   // a section title's name (explicit targets override it)
}

Directive_Option :: struct {
	name, value: string,
}

// A directive's argument, options and content, split like
// ``Body.parse_directive_block``.
Directive_Block :: struct {
	arguments: []string, // the argument lines
	options:   []Directive_Option,
	content:   []string,
	body:      Node, // the content parsed as reStructuredText, or NO_NODE
}

// How a directive is split and rendered.
Directive_Kind :: enum u8 {
	Code,               // code, code-block, sourcecode: [language], literal content
	Image,              // image: URI argument, no content
	Figure,             // figure: URI argument, caption and legend
	Admonition,         // note, warning, ...: no argument
	Generic_Admonition, // admonition: title argument
	Raw,                // raw: format argument, literal content
	Other,              // anything else: arguments dropped, content parsed
}

// State shared by both emitters, prepared by ``render_context_make``.
Render_Context :: struct {
	p:              ^Parser,
	t:              ^Tree,
	a:              runtime.Allocator,
	links:          map[string]Link, // by fully normalized name
	anonymous:      [dynamic]Link,   // anonymous targets in document order
	next_anonymous: int,             // anonymous references resolved so far
	blocks:         map[Node]Directive_Block,
}

ADMONITION_LABELS := [?][2]string {
	{"attention", "Attention"},
	{"caution", "Caution"},
	{"danger", "Danger"},
	{"error", "Error"},
	{"hint", "Hint"},
	{"important", "Important"},
	{"note", "Note"},
	{"tip", "Tip"},
	{"warning", "Warning"},
}

// The English title of a named admonition (``ok`` false for others).
admonition_label :: proc "contextless" (name: string) -> (label: string, ok: bool) {
	for l in ADMONITION_LABELS do if l[0] == name do return l[1], true
	return "", false
}

directive_kind :: proc "contextless" (name: string) -> Directive_Kind {
	switch name {
	case "code", "code-block", "sourcecode": return .Code
	case "image":                            return .Image
	case "figure":                           return .Figure
	case "admonition":                       return .Generic_Admonition
	case "raw":                              return .Raw
	}
	if _, ok := admonition_label(name); ok do return .Admonition
	return .Other
}

// Resolve the document's hyperlinks and parse its directive blocks.
render_context_make :: proc(p: ^Parser, doc: Node) -> (ctx: Render_Context) {
	ctx.p = p
	ctx.t = &p.tree
	ctx.a = p.allocator
	ctx.links = make(map[string]Link, 16, p.allocator)
	ctx.anonymous = make([dynamic]Link, 0, 4, p.allocator)
	ctx.blocks = make(map[Node]Directive_Block, 8, p.allocator)
	collect_links(&ctx, doc)
	return
}

// --- names and plain text ------------------------------------------------------------

// docutils ``fully_normalize_name``: lowercase, whitespace collapsed.
fully_normalize_name :: proc(name: string, a: runtime.Allocator) -> string {
	return strings.to_lower(whitespace_normalize(name, a), a)
}

// The anchor of the target named ``name`` (normalized): [a-z0-9-] only.
anchor_id :: proc(name: string, a: runtime.Allocator) -> string {
	if slug := slugify(name, a); slug != "" do return slug
	// no ASCII letters or digits: a stable id from the name's bytes (FNV-1a)
	h: u32 = 2166136261
	for i in 0 ..< len(name) do h = (h ~ u32(name[i])) * 16777619
	buf: [16]byte
	digits := "0123456789abcdef"
	for i in 0 ..< 8 do buf[i] = digits[(h >> uint(28 - 4 * i)) & 0xF]
	return concat("id-", string(buf[:8]), allocator = a)
}

slugify :: proc(s: string, allocator: runtime.Allocator) -> string {
	b := strings.builder_make(allocator)
	in_dash := false
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') {
			strings.write_byte(&b, c)
			in_dash = false
		} else if c >= 'A' && c <= 'Z' {
			strings.write_byte(&b, c + 32)
			in_dash = false
		} else if !in_dash && (c == ' ' || c == '-' || c == '_' || c == '.') {
			strings.write_byte(&b, '-')
			in_dash = true
		}
	}
	res := strings.to_string(b)
	return strings.trim(res, "-")
}

// The text of an inline tree, without markup (docutils ``astext()``).
node_astext :: proc(ctx: ^Render_Context, n: Node) -> string {
	b := strings.builder_make(ctx.a)
	write_astext(ctx, &b, n)
	return strings.to_string(b)
}

@(private = "file")
write_astext :: proc(ctx: ^Render_Context, b: ^strings.Builder, n: Node) {
	t := ctx.t
	#partial switch t.nodes[n].kind {
	case .Text, .Emphasis, .Strong, .Interpreted, .Inline_Target, .Substitution_Reference:
		strings.write_string(b, unescape(t.nodes[n].text, ctx.a))
		return
	case .Literal, .Footnote_Reference, .Citation_Reference, .Problematic:
		strings.write_string(b, t.nodes[n].text)
		return
	case .Reference:
		strings.write_string(b, reference_text(ctx, n))
		return
	}
	it := children(t, n)
	for c in iterate(&it) do write_astext(ctx, b, c)
}

// The text a ``Reference`` displays.
reference_text :: proc(ctx: ^Render_Context, n: Node) -> string {
	text := unescape(ctx.t.nodes[n].text, ctx.a)
	if text == "" {
		if info, ok := phrase_info(ctx.t, n); ok do return info.alias
	}
	return text
}

// --- hyperlinks ----------------------------------------------------------------------

// The link of reference ``n`` (``External`` or ``Internal``).  Anonymous
// references take the anonymous targets in order, so references must be
// resolved in document order.
resolve_reference :: proc(ctx: ^Render_Context, n: Node) -> Link {
	d := node_data(ctx.t, n)
	switch Ref_Kind(d.num[0]) {
	case .Uri: return {kind = .External, value = d.name}
	case .Pep: return {kind = .External, value = pep_url(d.name, ctx.a)}
	case .Rfc:
		url := concat("https://datatracker.ietf.org/doc/html/rfc", d.name, allocator = ctx.a)
		return {kind = .External, value = url}
	case .Simple, .Phrase:
	}
	if is_anonymous_reference(ctx.t, n) {
		if ctx.next_anonymous >= len(ctx.anonymous) do return {kind = .Internal}
		link := ctx.anonymous[ctx.next_anonymous]
		ctx.next_anonymous += 1
		return lookup_link(ctx, link.value) if link.kind == .Indirect else link
	}
	info, has_alias := phrase_info(ctx.t, n)
	if has_alias && info.alias_type == .Uri do return {kind = .External, value = info.alias}
	name := info.alias if has_alias else unescape(d.text, ctx.a)
	return lookup_link(ctx, fully_normalize_name(name, ctx.a))
}

// https://peps.python.org/pep-NNNN/ (at least four digits).
@(private = "file")
pep_url :: proc(number: string, a: runtime.Allocator) -> string {
	zeros := "0000"
	pad := zeros[:max(4 - len(number), 0)]
	return concat("https://peps.python.org/pep-", pad, number, "/", allocator = a)
}

is_anonymous_reference :: proc(t: ^Tree, n: Node) -> bool {
	#partial switch Ref_Kind(t.nodes[n].num[0]) {
	case .Simple: return t.nodes[n].num[1] != 0
	case .Phrase: return strings.has_suffix(t.nodes[n].raw, "__")
	}
	return false
}

// The final link of the (normalized) name, following indirect targets.
// Unknown names link to their own anchor.
lookup_link :: proc(ctx: ^Render_Context, name: string) -> Link {
	current := name
	for _ in 0 ..< 32 {
		link, ok := ctx.links[current]
		if !ok do break
		if link.kind != .Indirect do return link
		current = link.value
	}
	return {kind = .Internal, value = anchor_id(name, ctx.a)}
}

@(private = "file")
add_link :: proc(ctx: ^Render_Context, name: string, link: Link) {
	if old, ok := ctx.links[name]; ok && !(old.implicit && !link.implicit) do return
	ctx.links[name] = link
}

// Register the targets of the tree below ``n``, in document order.
@(private = "file")
collect_links :: proc(ctx: ^Render_Context, n: Node) {
	t := ctx.t
	#partial switch t.nodes[n].kind {
	case .Target:
		collect_target(ctx, n)
	case .Section_Title:
		if title := t.nodes[n].first; title != NO_NODE {
			name := fully_normalize_name(node_astext(ctx, title), ctx.a)
			link := Link {
				kind     = .Internal,
				value    = anchor_id(name, ctx.a),
				implicit = true,
			}
			add_link(ctx, name, link)
		}
	case .Inline_Target:
		name := fully_normalize_name(unescape(t.nodes[n].text, ctx.a), ctx.a)
		add_link(ctx, name, {kind = .Internal, value = anchor_id(name, ctx.a)})
	case .Reference:
		collect_embedded_target(ctx, n)
	case .Directive:
		block := directive_block(ctx, n)
		ctx.blocks[n] = block
		if block.body != NO_NODE do collect_links(ctx, block.body)
	}
	it := children(t, n)
	for c in iterate(&it) do collect_links(ctx, c)
}

// ``.. _name: URI``, ``.. _name: other_``, ``.. _name:`` and ``__ URI``.
@(private = "file")
collect_target :: proc(ctx: ^Render_Context, n: Node) {
	d := node_data(ctx.t, n)
	link := Link {
		kind  = .External,
		value = d.text,
	}
	if Target_Type(d.num[0]) == .Refname {
		link = {kind = .Indirect, value = fully_normalize_name(d.text, ctx.a)}
	}
	if d.num[1] != 0 {
		append(&ctx.anonymous, link)
		return
	}
	name := fully_normalize_name(unescape(d.name, ctx.a), ctx.a)
	if link.kind == .External && link.value == "" {
		link = {kind = .Internal, value = anchor_id(name, ctx.a)}
	}
	add_link(ctx, name, link)
}

// A named phrase reference with an embedded URI or alias also defines a
// target (```text <URI>`_``).
@(private = "file")
collect_embedded_target :: proc(ctx: ^Render_Context, n: Node) {
	info, ok := phrase_info(ctx.t, n)
	if !ok || is_anonymous_reference(ctx.t, n) do return
	name := fully_normalize_name(unescape(ctx.t.nodes[n].text, ctx.a), ctx.a)
	if name == "" do return
	link := Link {
		kind  = .External,
		value = info.alias,
	}
	if info.alias_type == .Name {
		link = {kind = .Indirect, value = fully_normalize_name(info.alias, ctx.a)}
	}
	if _, known := ctx.links[name]; !known do ctx.links[name] = link
}

// --- directive blocks ----------------------------------------------------------------

// Split the block of directive ``n`` and parse its content where the
// emitters render it as reStructuredText.
directive_block :: proc(ctx: ^Render_Context, n: Node) -> (b: Directive_Block) {
	info, _ := directive_info(ctx.t, n)
	kind := directive_kind(strings.to_lower(ctx.t.nodes[n].name, ctx.a))
	content_offset: int
	b, content_offset = split_directive_block(info, kind != .Admonition, ctx.a)
	#partial switch kind {
	case .Code, .Image, .Raw:
		return
	}
	if len(b.content) > 0 {
		b.body = new_node(ctx.t, .Block_Quote, 0) // anonymous container
		sm := make_state_machine(ctx.p, nil, 0, b.body)
		nested_parse(&sm, b.content, content_offset, b.body)
	}
	return
}

// ``Body.parse_directive_block``: the argument lines, the option field list
// (up to the first blank line) and the content.
split_directive_block :: proc(
	info: Directive_Info,
	takes_arguments: bool,
	a: runtime.Allocator,
) -> (
	b: Directive_Block,
	content_offset: int,
) {
	lines, offset := info.lines, info.line_offset
	if len(lines) > 0 && strip(lines[0]) == "" {
		lines = lines[1:]
		offset += 1
	}
	for len(lines) > 0 && strip(lines[len(lines) - 1]) == "" do lines = lines[:len(lines) - 1]
	i := 0
	for i < len(lines) && strip(lines[i]) != "" do i += 1
	arg_block := lines[:i]
	b.content, content_offset = lines[min(i + 1, len(lines)):], offset + i + 1
	opt := 0
	for opt < len(arg_block) {
		if _, _, is_field := match_field_marker(arg_block[opt]); is_field do break
		opt += 1
	}
	b.options = parse_directive_options(arg_block[opt:], a)
	arg_block = arg_block[:opt]
	if len(arg_block) > 0 && !takes_arguments {
		joined := make([]string, len(arg_block) + len(lines) - i, a)
		copy(joined, arg_block)
		copy(joined[len(arg_block):], lines[i:])
		b.content, content_offset = joined, offset
		arg_block = nil
	}
	for len(b.content) > 0 && strip(b.content[0]) == "" {
		b.content = b.content[1:]
		content_offset += 1
	}
	b.arguments = arg_block
	return
}

// A field list of options (``:name: value`` with continuation lines).
@(private = "file")
parse_directive_options :: proc(lines: []string, a: runtime.Allocator) -> []Directive_Option {
	options := make([dynamic]Directive_Option, 0, len(lines), a)
	for line in lines {
		if name, end, is_field := match_field_marker(line); is_field {
			append(&options, Directive_Option{name, strip(line[end:])})
		} else if len(options) > 0 {
			last := &options[len(options) - 1]
			last.value = strip(concat(last.value, " ", strip(line), allocator = a))
		}
	}
	return options[:]
}

directive_option :: proc "contextless" (b: Directive_Block, name: string) -> (string, bool) {
	for o in b.options do if o.name == name do return o.value, true
	return "", false
}

// The arguments joined with spaces (a title, a language or a format).
directive_argument :: proc(b: Directive_Block, a: runtime.Allocator) -> string {
	parts := make([]string, len(b.arguments), a)
	for line, i in b.arguments do parts[i] = strip(line)
	return strings.join(parts, " ", a)
}

// A URI argument: its lines joined without whitespace (docutils ``image``).
directive_uri :: proc(b: Directive_Block, a: runtime.Allocator) -> string {
	parts := make([]string, len(b.arguments), a)
	for line, i in b.arguments do parts[i] = strip(line)
	return strings.concatenate(parts, a)
}

// A code language reduced to characters safe in a class name.
code_language :: proc(b: Directive_Block, a: runtime.Allocator) -> string {
	words := split_whitespace(directive_argument(b, a), a)
	if len(words) == 0 do return ""
	out := strings.builder_make(a)
	for i in 0 ..< len(words[0]) {
		switch c := words[0][i]; c {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '-', '_', '+', '.', '#':
			strings.write_byte(&out, c)
		}
	}
	return strings.to_string(out)
}

// --- document structure ----------------------------------------------------------------

// A section title adornment: underline (and overline) characters.
Title_Style :: struct {
	chars: [2]u8,
	n:     int, // 1: underline only, 2: overline and underline
}

// The level (1-based) of a section title adorned with ``style``; new styles
// are appended to ``styles`` in order of appearance.
section_level :: proc(styles: ^[dynamic]Title_Style, style: string) -> int {
	s := Title_Style {
		n = len(style),
	}
	for i in 0 ..< min(len(style), 2) do s.chars[i] = style[i]
	for known, i in styles do if known == s do return i + 1
	append(styles, s)
	return len(styles)
}

// The first top-level section title (``NO_NODE`` when there is none).
first_section_title :: proc(t: ^Tree, doc: Node) -> Node {
	it := children(t, doc)
	for n in iterate(&it) {
		if t.nodes[n].kind == .Section_Title && t.nodes[n].first != NO_NODE do return n
	}
	return NO_NODE
}

// ``configured``, else the text of the first section title.
document_title :: proc(ctx: ^Render_Context, doc: Node, configured: string) -> string {
	if configured != "" do return configured
	if n := first_section_title(ctx.t, doc); n != NO_NODE {
		if title := node_astext(ctx, ctx.t.nodes[n].first); title != "" do return title
	}
	return "Document"
}

// The anchor of footnote or citation ``label`` (``prefix``: "footnote" or
// "citation").
note_id :: proc(a: runtime.Allocator, prefix, label: string) -> string {
	return concat(prefix, "-", anchor_id(fully_normalize_name(label, a), a), allocator = a)
}

// The anchor a ``Target`` places (internal, named targets only).
target_anchor :: proc(ctx: ^Render_Context, d: Node_Data) -> (id: string, ok: bool) {
	if d.kind != .Target || d.num[1] != 0 do return
	if Target_Type(d.num[0]) != .Refuri || d.text != "" do return
	return anchor_id(fully_normalize_name(unescape(d.name, ctx.a), ctx.a), ctx.a), true
}
