package texmath

// TeX to HTML: a port of ``docutils.utils.math.math2html`` (eLyXer's formula
// converter).  A formula is translated in three passes, as in docutils:
//
// 1. Parse (`parse_formula`): a cursor over the source with a stack of endings
//    (`m2h_position.odin`) feeds the bit kinds (`m2h_parse.odin`) and the command
//    kinds (`m2h_commands.odin`, `m2h_arrays.odin`, `m2h_hybrid.odin`), which build a
//    tree of `Node`s.
// 2. Process (`process_formula`, `m2h_process.odin`): scripts become limits and
//    stacks, ``\left``/``\right`` brackets are resized, letters set in italics.
// 3. Output (`render`): each node writes its HTML into one builder.
//
// Problems in the input are reported as docutils reports them on standard error
// (``Trace.error``): the `trace` of the result holds those lines.  Where docutils
// raises an exception, the conversion stops at the same point with an `Exception`.

import "core:mem/virtual"
import "core:strings"

// The Python class of a node: its behaviour while parsing and processing.
Bit_Kind :: enum u8 {
	Formula_Constant,
	Whole_Formula,
	Raw_Text,
	Formula_Symbol,
	Formula_Number,
	Comment,
	White_Space,
	Bracket,
	Square_Bracket,
	Tagged_Bit,
	Formula_Command, // an unknown command
	Alpha_Command,
	Empty_Command,
	One_Param_Function,
	Font_Function,
	Text_Function,
	Spaced_Command,
	Begin_Command,
	Overset_Function,
	Underset_Function,
	Combining_Function,
	Limit_Command,
	Bracket_Command,
	Hybrid_Function,
	Symbol_Function,
	Formula_Cell,
	Formula_Row,
	Formula_Equation,
	Formula_Array,
	Formula_Matrix,
	Formula_Cases,
	Equation_Environment,
}

// The Python class names, for messages and ``ContainerConfig.extracttext``.
@(rodata)
CLASS_NAMES := [Bit_Kind]string {
	.Formula_Constant     = "FormulaConstant",
	.Whole_Formula        = "WholeFormula",
	.Raw_Text             = "RawText",
	.Formula_Symbol       = "FormulaSymbol",
	.Formula_Number       = "FormulaNumber",
	.Comment              = "Comment",
	.White_Space          = "WhiteSpace",
	.Bracket              = "Bracket",
	.Square_Bracket       = "SquareBracket",
	.Tagged_Bit           = "TaggedBit",
	.Formula_Command      = "FormulaCommand",
	.Alpha_Command        = "AlphaCommand",
	.Empty_Command        = "EmptyCommand",
	.One_Param_Function   = "OneParamFunction",
	.Font_Function        = "FontFunction",
	.Text_Function        = "TextFunction",
	.Spaced_Command       = "SpacedCommand",
	.Begin_Command        = "BeginCommand",
	.Overset_Function     = "OversetFunction",
	.Underset_Function    = "UndersetFunction",
	.Combining_Function   = "CombiningFunction",
	.Limit_Command        = "LimitCommand",
	.Bracket_Command      = "BracketCommand",
	.Hybrid_Function      = "HybridFunction",
	.Symbol_Function      = "SymbolFunction",
	.Formula_Cell         = "FormulaCell",
	.Formula_Row          = "FormulaRow",
	.Formula_Equation     = "FormulaEquation",
	.Formula_Array        = "FormulaArray",
	.Formula_Matrix       = "FormulaMatrix",
	.Formula_Cases        = "FormulaCases",
	.Equation_Environment = "EquationEnvironment",
}

// The command tables of ``FormulaFactory.commandtypes``, in order of precedence.
Command_Kind :: enum u8 {
	Alpha,
	Empty,
	One_Param,
	Font,
	Text,
	Spaced,
	Begin,
	Overset,
	Underset,
	Combining,
	Limit,
	Bracket,
	Hybrid,
}

@(rodata)
COMMAND_BITS := [Command_Kind]Bit_Kind {
	.Alpha     = .Alpha_Command,
	.Empty     = .Empty_Command,
	.One_Param = .One_Param_Function,
	.Font      = .Font_Function,
	.Text      = .Text_Function,
	.Spaced    = .Spaced_Command,
	.Begin     = .Begin_Command,
	.Overset   = .Overset_Function,
	.Underset  = .Underset_Function,
	.Combining = .Combining_Function,
	.Limit     = .Limit_Command,
	.Bracket   = .Bracket_Command,
	.Hybrid    = .Hybrid_Function,
}

Command_Entry :: struct {
	name:  string,
	kind:  Command_Kind,
	value: string, // the translation ("" for hybrid functions)
}

// A key with a list of strings (``bigbrackets``, ``environments``).
Pieces_Entry :: struct {
	key:    string,
	pieces: []string,
}

// How a node renders (``ContainerOutput``).
Output_Kind :: enum u8 {
	Contents, // the contents' output
	Tagged, // the contents wrapped in `tag`
	Fixed, // `text` replaces the contents
	Empty, // nothing
	String, // `text` (a constant)
}

Node :: struct {
	kind:        Bit_Kind,
	output:      Output_Kind,
	breaklines:  bool, // tags on their own lines
	self_closing: bool, // ``<tag/>``
	size:        int, // rows spanned, for brackets
	type:        string, // "alpha", "number", "font" or ""
	tag:         string,
	text:        string, // a constant's string; fixed output
	original:    string, // the source read
	command:     string,
	translated:  string,
	literal:     string, // brackets read literally
	piece:       string, // environments
	alignments:  []string, // multi-row formulas and rows
	contents:    [dynamic]^Node,
}

// The state of one conversion.
M2h :: struct {
	text:     string, // the formula
	pos:      int, // byte offset in `text` (may pass the end)
	endings:  [dynamic]Ending,
	display:  bool, // ``DocumentParameters.displaymode``
	simple:   bool, // ``Options.simplemath``
	trace:    strings.Builder,
	err:      Error,
	depth:    int, // of nested parses, up to `MAX_DEPTH`
}

Math2html_Options :: struct {
	display:    bool, // display (block) math: limits above and below big operators
	simplemath: bool, // no stacked limits and scripts, no resized brackets
}

Math2html_Result :: struct {
	html:  string,
	trace: string, // what docutils writes to standard error: "* message" lines
	err:   Error, // the exception docutils raises, if any (then `html` is empty)
}

// ``math2html.math2html(formula)`` with ``DocumentParameters.displaymode = display``.
math2html :: proc(
	formula: string,
	display := false,
	allocator := context.allocator,
) -> (
	html: string,
	err: Error,
) {
	result := convert_math2html(formula, {display = display}, allocator)
	return result.html, result.err
}

// `math2html` with all options, returning the trace messages as well.
convert_math2html :: proc(
	formula: string,
	options: Math2html_Options,
	allocator := context.allocator,
) -> (
	result: Math2html_Result,
) {
	scratch: Scratch
	if !scratch_begin(&scratch) {
		return
	}
	defer scratch_end(&scratch)
	context.allocator = virtual.arena_allocator(&scratch.arena)
	m := M2h {
		text    = formula,
		display = options.display,
		simple  = options.simplemath,
	}
	strings.builder_init(&m.trace)
	whole := parse_formula(&m)
	if m.err == nil {
		process_formula(&m, whole)
	}
	out := strings.builder_make()
	if m.err == nil {
		render(&m, &out, whole)
	}
	if m.err == nil {
		result.html = strings.clone(strings.to_string(out), allocator)
	}
	result.trace = strings.clone(strings.to_string(m.trace), allocator)
	result.err = clone_error(m.err, allocator)
	return
}

// ``Trace.error``: a message line on standard error (none after an exception).
trace_error :: proc(m: ^M2h, parts: ..string) {
	if m.err != nil {
		return
	}
	strings.write_string(&m.trace, "* ")
	for part in parts {
		strings.write_string(&m.trace, part)
	}
	strings.write_byte(&m.trace, '\n')
}

// Raise an exception (only the first counts: the conversion stops there).
raise :: proc(m: ^M2h, exception: Exception) {
	if m.err == nil {
		m.err = exception
	}
}

// Nodes
// -----

new_node :: proc(kind: Bit_Kind) -> ^Node {
	node := new(Node)
	node.kind = kind
	node.size = 1
	return node
}

// ``FormulaConstant(string)``.
new_constant :: proc(text: string) -> ^Node {
	node := new_node(.Formula_Constant)
	node.output = .String
	node.text = text
	node.original = text
	return node
}

// ``FormulaBit.add``: append a parsed bit, and its source to ours.
add :: proc(bit: ^Node, child: ^Node) {
	append(&bit.contents, child)
	bit.original = concat(bit.original, child.original)
}

concat :: proc(a, b: string) -> string {
	if len(b) == 0 {
		return a
	}
	if len(a) == 0 {
		return b
	}
	return strings.concatenate({a, b})
}

set_tag :: proc(node: ^Node, tag: string, breaklines := false, self_closing := false) {
	node.output = .Tagged
	node.tag = tag
	node.breaklines = breaklines
	node.self_closing = self_closing
}

// ``TaggedBit().constant(text, tag)``.
tagged_constant :: proc(text: string, tag: string) -> ^Node {
	node := new_node(.Tagged_Bit)
	set_tag(node, tag)
	add(node, new_constant(text))
	return node
}

// ``TaggedBit().complete(contents, tag, breaklines)``.
tagged_complete :: proc(contents: []^Node, tag: string, breaklines := false) -> ^Node {
	node := new_node(.Tagged_Bit)
	append(&node.contents, ..contents)
	set_tag(node, tag, breaklines)
	return node
}

// ``str(bit)`` of a formula bit.
describe :: proc(node: ^Node) -> string {
	return strings.concatenate({CLASS_NAMES[node.kind], " read in ", node.original})
}

// ``FormulaBit.computesize``: the largest size of the contents (1 when empty).
compute_size :: proc(node: ^Node) -> int {
	if node.kind == .Formula_Constant {
		return node.size
	}
	if len(node.contents) == 0 {
		return 1
	}
	size := node.contents[0].size
	for child in node.contents[1:] {
		size = max(size, child.size)
	}
	node.size = size
	return size
}

// Output
// ------

render :: proc(m: ^M2h, out: ^strings.Builder, node: ^Node) {
	switch node.output {
	case .Contents:
		for child in node.contents {
			render(m, out, child)
		}
	case .Tagged:
		render_tagged(m, out, node)
	case .Fixed, .String:
		strings.write_string(out, node.text)
	case .Empty:
	}
}

// ``TaggedOutput.gethtml``: an empty tag is reported (on opening and closing).
@(private = "file")
render_tagged :: proc(m: ^M2h, out: ^strings.Builder, node: ^Node) {
	if len(node.tag) == 0 {
		trace_error(m, "No tag in ", describe(node))
	} else {
		strings.write_byte(out, '<')
		strings.write_string(out, node.tag)
		strings.write_string(out, node.self_closing ? "/>" : ">")
		if node.breaklines {
			strings.write_byte(out, '\n')
		}
	}
	if node.self_closing {
		return
	}
	for child in node.contents {
		render(m, out, child)
	}
	if len(node.tag) == 0 {
		trace_error(m, "No tag in ", describe(node))
		return
	}
	name := node.tag
	if space := strings.index_byte(name, ' '); space >= 0 {
		name = name[:space]
	}
	if node.breaklines {
		strings.write_byte(out, '\n')
	}
	strings.write_string(out, "</")
	strings.write_string(out, name)
	strings.write_byte(out, '>')
	if node.breaklines {
		strings.write_byte(out, '\n')
	}
}
