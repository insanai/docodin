package site

import gv "../graphviz"
import rd "../reader"

GRAPHVIZ := gv.GRAPHVIZ
GRAPH := gv.GRAPH
DIGRAPH := gv.DIGRAPH

@(init)
init_graphviz :: proc "contextless" () {
	GRAPHVIZ.run = run_graphviz
	GRAPH.run = run_graphviz
	DIGRAPH.run = run_graphviz
}

@(private = "file")
run_graphviz :: proc(c: ^rd.Context, d: ^rd.Directive) -> (rd.Nodes, rd.Failure) {
	b := build_of(c)
	format := "svg" if b.format == .Html else "pdf"
	return gv.run(c, d, {directory = b.graphviz_directory, format = format, themed = true})
}
