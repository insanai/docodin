"""Table and option list handling of the ODF translator."""

from __future__ import annotations

from docutils import nodes

from ._xml import (
    BUILTIN_DEFAULT_TABLE_STYLE,
    SNSD,
    TABLENAMEDEFAULT,
    TABLESTYLEPREFIX,
    SubElement,
    add_ns,
)

_BORDER = "0.035cm solid #000000"

# (style name args, family, properties tag, properties) of the option list styles
_OPTION_TABLE_STYLES = (
    ("%s", (), "table", "style:table-properties", {
        "style:width": "17.59cm",
        "table:align": "left",
        "style:shadow": "none"}),
    ("%s.%%c", ("A", ), "table-column", "style:table-column-properties", {
        "style:column-width": "4.999cm"}),
    ("%s.%%c", ("B", ), "table-column", "style:table-column-properties", {
        "style:column-width": "12.587cm"}),
    ("%s.%%c%%d", ("A", 1, ), "table-cell", "style:table-cell-properties", {
        "fo:background-color": "transparent",
        "fo:padding": "0.097cm",
        "fo:border-left": _BORDER,
        "fo:border-right": "none",
        "fo:border-top": _BORDER,
        "fo:border-bottom": _BORDER}),
    ("%s.%%c%%d", ("B", 1, ), "table-cell", "style:table-cell-properties", {
        "fo:padding": "0.097cm",
        "fo:border": _BORDER}),
    ("%s.%%c%%d", ("A", 2, ), "table-cell", "style:table-cell-properties", {
        "fo:padding": "0.097cm",
        "fo:border-left": _BORDER,
        "fo:border-right": "none",
        "fo:border-top": "none",
        "fo:border-bottom": _BORDER}),
    ("%s.%%c%%d", ("B", 2, ), "table-cell", "style:table-cell-properties", {
        "fo:padding": "0.097cm",
        "fo:border-left": _BORDER,
        "fo:border-right": _BORDER,
        "fo:border-top": "none",
        "fo:border-bottom": _BORDER}),
)


class _TableMixin:
    """Visitor methods for tables and option lists."""

    #
    # Option lists

    def _generate_option_table_styles(self, table_name) -> None:
        for name, params, family, props_tag, props in _OPTION_TABLE_STYLES:
            el = SubElement(self.automatic_styles, "style:style", attrib={
                "style:name": self.rststyle(name % table_name, params),
                "style:family": family}, nsdict=SNSD)
            el1 = SubElement(el, props_tag, attrib=props, nsdict=SNSD)
            if params == ("A", 1):
                SubElement(el1, "style:background-image", nsdict=SNSD)

    def _option_table_header_cell(self, row, table_name, column, text) -> None:
        cell = SubElement(row, "table:table-cell", attrib={
            "table:style-name": self.rststyle("%s.%%c%%d" % table_name, (column, 1, )),
            "office:value-type": "string"})
        par = SubElement(cell, "text:p", attrib={"text:style-name": "Table_20_Heading"})
        par.text = text

    def visit_option_list(self, node) -> None:
        table_name = "tableoption"
        # Generate automatic styles
        if not self.optiontablestyles_generated:
            self.optiontablestyles_generated = True
            self._generate_option_table_styles(table_name)
        # Generate table data
        el = self.append_child("table:table", attrib={
            "table:name": self.rststyle(table_name),
            "table:style-name": self.rststyle(table_name),
        })
        for column in ("A", "B"):
            SubElement(el, "table:table-column", attrib={
                "table:style-name": self.rststyle("%s.%%c" % table_name, (column, ))})
        el1 = SubElement(el, "table:table-header-rows")
        el2 = SubElement(el1, "table:table-row")
        self._option_table_header_cell(el2, table_name, "A", "Option")
        self._option_table_header_cell(el2, table_name, "B", "Description")
        self.set_current_element(el)

    def depart_option_list(self, node) -> None:
        self.set_to_parent()

    def visit_option_list_item(self, node) -> None:
        el = self.append_child("table:table-row")
        self.set_current_element(el)

    def depart_option_list_item(self, node) -> None:
        self.set_to_parent()

    def visit_option_group(self, node) -> None:
        el = self.append_child("table:table-cell", attrib={
            "table:style-name": "Table%d.A2" % self.table_count,
            "office:value-type": "string",
        })
        self.set_current_element(el)

    def depart_option_group(self, node) -> None:
        self.set_to_parent()

    def visit_option(self, node) -> None:
        el = self.append_child("text:p", attrib={"text:style-name": "Table_20_Contents"})
        el.text = node.astext()

    def depart_option(self, node) -> None:
        pass

    def visit_option_string(self, node) -> None:
        pass

    def depart_option_string(self, node) -> None:
        pass

    def visit_option_argument(self, node) -> None:
        pass

    def depart_option_argument(self, node) -> None:
        pass

    def visit_description(self, node):
        el = self.append_child("table:table-cell", attrib={
            "table:style-name": "Table%d.B2" % self.table_count,
            "office:value-type": "string",
        })
        el1 = SubElement(el, "text:p", attrib={"text:style-name": "Table_20_Contents"})
        el1.text = node.astext()
        raise nodes.SkipChildren

    def depart_description(self, node) -> None:
        pass

    #
    # Tables

    def _default_table_style(self, node, message):
        """Return the default table style; warn with `message` if missing."""
        table_style = self.table_styles.get(TABLENAMEDEFAULT)
        if table_style is None:
            # If we can't find the default table style, issue a warning
            #   and use a built-in default style.
            self.document.reporter.warning(message, base_node=node)
            table_style = BUILTIN_DEFAULT_TABLE_STYLE
        return table_style

    def get_table_style(self, node):
        table_name = None
        str_classes = node.get("classes")
        if str_classes is not None:
            for str_class in str_classes:
                if str_class.startswith(TABLESTYLEPREFIX):
                    table_name = str_class
                    break
        if table_name is None:
            # (sic!) The warning of docutils has no f-string here.
            return self._default_table_style(
                node, 'Can\'t find default table style "{table_name}".  '
                'Using built-in default.')
        table_style = self.table_styles.get(table_name)
        if table_style is None:
            # If we can't find the table style, issue warning
            #   and use the default table style.
            self.document.reporter.warning(
                f'Can\'t find table style "{table_name}".  Using default.',
                base_node=node)
            table_style = self._default_table_style(
                node, f'Can\'t find default table style "{TABLENAMEDEFAULT}".  '
                'Using built-in default.')
        return table_style

    def _add_table_styles(self, table_style, table_name):
        """Add the automatic table and cell styles; return the table style el."""
        el1 = SubElement(self.automatic_styles, "style:style", attrib={
            "style:name": self.rststyle("%s" % table_name, (self.table_count, )),
            "style:family": "table",
        }, nsdict=SNSD)
        if table_style.backgroundcolor is None:
            attrib = {
                "table:align": "left",
                "fo:margin-top": "0in",
                "fo:margin-bottom": "0.10in",
            }
        else:
            attrib = {
                "table:align": "margins",
                "fo:margin-top": "0in",
                "fo:margin-bottom": "0.10in",
                "fo:background-color": table_style.backgroundcolor,
            }
        SubElement(el1, "style:table-properties", attrib=attrib, nsdict=SNSD)
        # We use a single cell style for all cells in this table.
        # That's probably not correct, but seems to work.
        el2 = SubElement(self.automatic_styles, "style:style", attrib={
            "style:name": self.rststyle(
                "%s.%%c%%d" % table_name, (self.table_count, "A", 1, )),
            "style:family": "table-cell",
        }, nsdict=SNSD)
        thickness = self.settings.table_border_thickness
        if thickness is None:
            line_style1 = table_style.border
        else:
            line_style1 = "0.%03dcm solid #000000" % (thickness, )
        SubElement(el2, "style:table-cell-properties", attrib={
            "fo:padding": "0.049cm",
            "fo:border-left": line_style1,
            "fo:border-right": line_style1,
            "fo:border-top": line_style1,
            "fo:border-bottom": line_style1,
        }, nsdict=SNSD)
        return el1

    def visit_table(self, node) -> None:
        self.table_count += 1
        table_style = self.get_table_style(node)
        table_name = "%s%%d" % TABLESTYLEPREFIX
        el1 = self._add_table_styles(table_style, table_name)
        title = None
        for child in node.children:
            if child.tagname == "title":
                title = child.astext()
                break
        if title is not None:
            self.append_p("table-title", title)
        el4 = SubElement(self.current_element, "table:table", attrib={
            "table:name": self.rststyle("%s" % table_name, (self.table_count, )),
            "table:style-name": self.rststyle("%s" % table_name, (self.table_count, )),
        })
        self.set_current_element(el4)
        self.current_table_style = el1
        self.table_width = 0.0

    def depart_table(self, node) -> None:
        attribkey = add_ns("style:width", nsdict=SNSD)
        attribval = "%.4fin" % (self.table_width, )
        el1 = self.current_table_style
        el2 = el1[0]
        el2.attrib[attribkey] = attribval
        self.set_to_parent()

    def visit_tgroup(self, node) -> None:
        self.column_count = ord("A") - 1

    def depart_tgroup(self, node) -> None:
        pass

    def visit_colspec(self, node) -> None:
        self.column_count += 1
        colspec_name = self.rststyle(
            "%s%%d.%%s" % TABLESTYLEPREFIX,
            (self.table_count, chr(self.column_count), )
        )
        colwidth = node.propwidth() / 12.0
        el1 = SubElement(self.automatic_styles, "style:style", attrib={
            "style:name": colspec_name,
            "style:family": "table-column",
        }, nsdict=SNSD)
        SubElement(el1, "style:table-column-properties",
                   attrib={"style:column-width": "%.4fin" % colwidth},
                   nsdict=SNSD)
        self.append_child("table:table-column",
                          attrib={"table:style-name": colspec_name, })
        self.table_width += colwidth

    def depart_colspec(self, node) -> None:
        pass

    def visit_thead(self, node) -> None:
        el = self.append_child("table:table-header-rows")
        self.set_current_element(el)
        self.in_thead = True
        self.paragraph_style_stack.append("Table_20_Heading")

    def depart_thead(self, node) -> None:
        self.set_to_parent()
        self.in_thead = False
        self.paragraph_style_stack.pop()

    def visit_row(self, node) -> None:
        self.column_count = ord("A") - 1
        el = self.append_child("table:table-row")
        self.set_current_element(el)

    def depart_row(self, node) -> None:
        self.set_to_parent()

    def visit_entry(self, node) -> None:
        self.column_count += 1
        cellspec_name = self.rststyle(
            "%s%%d.%%c%%d" % TABLESTYLEPREFIX,
            (self.table_count, "A", 1, )
        )
        attrib = {
            "table:style-name": cellspec_name,
            "office:value-type": "string",
        }
        morecols = node.get("morecols", 0)
        if morecols > 0:
            attrib["table:number-columns-spanned"] = "%d" % (morecols + 1,)
            self.column_count += morecols
        morerows = node.get("morerows", 0)
        if morerows > 0:
            attrib["table:number-rows-spanned"] = "%d" % (morerows + 1,)
        el1 = self.append_child("table:table-cell", attrib=attrib)
        self.set_current_element(el1)

    def depart_entry(self, node) -> None:
        self.set_to_parent()

    def visit_tbody(self, node) -> None:
        pass

    def depart_tbody(self, node) -> None:
        pass
