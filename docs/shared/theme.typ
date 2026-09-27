// Typography adapted from the sibling Insan.ai discussion design system.
#let primary-color = rgb("182e3b")
#let accent-color = rgb("166777")
#let muted-color = rgb("526773")
#let border-color = rgb("d5dfe2")
#let bg-light = rgb("f1f5f5")

#let typography(body) = {
  set text(font: "New Computer Modern", size: 10.5pt, fill: primary-color,
    lang: "en", hyphenate: true, costs: (orphan: 100%, widow: 100%))
  set smartquote(enabled: false)
  set par(justify: true, leading: 0.68em, spacing: 0.75em)
  set heading(numbering: "1.1")
  show heading: set text(font: "New Computer Modern Sans", weight: "bold", hyphenate: false)
  show heading: set par(justify: false)
  show heading.where(level: 1): set text(size: 17pt, fill: primary-color)
  show heading.where(level: 2): set text(size: 12.5pt, fill: accent-color)
  show heading.where(level: 3): set text(size: 11pt, fill: accent-color)
  set raw(tab-size: 4)
  show raw: set text(font: "New Computer Modern Mono", size: 8.4pt, hyphenate: false)
  show raw.where(block: true): it => block(width: 100%, breakable: false,
    inset: 10pt, fill: bg-light, stroke: (left: 1.5pt + border-color), it)
  show link: set text(fill: accent-color)
  set table(stroke: (left: none, right: none, top: none, bottom: 0.45pt + border-color),
    inset: (x: 7pt, y: 7pt), fill: (_, y) => if y == 0 { bg-light } else { none })
  set table.cell(breakable: false)
  show table: set par(justify: false, leading: 0.5em)
  show table: set text(font: "New Computer Modern Sans", size: 9pt, hyphenate: false)
  body
}
