// DocOdin SDS template following SDS 1 specification.
#import "theme.typ": *

#let state-fill(state) = (
  prediscussion: rgb("fef3c7"), discussion: rgb("dcfce7"),
  published: rgb("dbeafe"), committed: rgb("ede9fe"), abandoned: rgb("e5e7eb"),
).at(state, default: rgb("f1f5f9"))

#let state-chip(state) = box(inset: (x: 6pt, y: 3pt), radius: 3pt,
  fill: state-fill(state))[
  #text(font: "New Computer Modern Sans", size: 8pt, weight: "bold")[#upper(state)]
]
#let meta-label(body) = text(font: "New Computer Modern Sans", size: 8pt,
  weight: "bold", tracking: 0.04em, fill: muted-color, body)

#let sds-pages(number, body) = {
  set page(paper: "a4", margin: (x: 22mm, top: 22mm, bottom: 22mm),
    header: [
      #set text(font: "New Computer Modern Sans", size: 8pt, fill: muted-color)
      #grid(columns: (1fr, auto), [DocOdin Discussions (SDS)], [SDS #number])
      #v(-2pt)
      #line(length: 100%, stroke: 0.5pt + border-color)
    ],
    footer: context [
      #set text(font: "New Computer Modern Sans", size: 8pt, fill: muted-color)
      #line(length: 100%, stroke: 0.4pt + rgb("e2e8f0"))
      #v(1pt)
      #grid(columns: (1fr, auto), [DOCODIN / COMPILER & ARCHITECTURE RECORD], counter(page).display())
    ])
  typography(body)
}

#let sds-document(number, title, body, state: "prediscussion", created: "",
  updated: "", category: "Engineering Discussion", authors: ("DocOdin contributors",),
  discussion: "Repository discussion; review link not yet assigned.", status: "Draft",
  labels: ()) = {
  set document(title: "SDS " + number + ": " + title, author: authors)
  sds-pages(number, [
    #counter(heading).update(0)
    #metadata("sds-record-start")
    #block(width: 100%, breakable: false, inset: (x: 1.15em, y: 1.05em),
      radius: 4pt, stroke: 0.75pt + rgb("cbd5e1"), fill: luma(99.2%))[
      #set par(justify: false)
      #grid(columns: (1fr, auto), column-gutter: 1.4em, align: (left, top),
        [#text(12.4pt, weight: "bold")[DocOdin Project] \
         #text(9pt, fill: muted-color)[Software Design Specification]],
        [#align(right)[#text(13.5pt, weight: "bold", fill: accent-color)[SDS #number] \
         #text(9pt, fill: muted-color)[#category]]])
      #v(0.8em)
      #text(21pt, weight: "bold")[#title]
      #v(0.5em)
      #line(length: 100%, stroke: 0.7pt + rgb("e2e8f0"))
      #v(0.6em)
      #grid(columns: (1fr, 1.25fr), column-gutter: 1.8em, row-gutter: 0.4em,
        align: (left, top),
        [#meta-label[STATE]], [#meta-label[INTENDED STATUS]],
        [#state-chip(state)], [#text(9.8pt)[#status]],
        [#meta-label[CREATED]], [#meta-label[AUTHORS]],
        [#text(9.8pt)[#created]], [#text(9.8pt)[#authors.join(", ")]],
        [#meta-label[LAST UPDATED]], [#meta-label[DISCUSSION]],
        [#text(9.8pt)[#updated]], [#text(9.8pt)[#discussion]],
      )
      #if labels.len() > 0 [
        #v(0.65em)
        #meta-label[TOPICS]
        #linebreak()
        #for topic in labels [
          #box(inset: (x: 5pt, y: 2.5pt), radius: 3pt, fill: rgb("f1f5f9"),
            stroke: 0.4pt + rgb("cbd5e1"))[
            #text(font: "New Computer Modern Sans", size: 8pt)[#topic]
          ]#h(3pt)
        ]
      ]
    ]
    #v(0.8em)
    #block(width: 100%, breakable: false, inset: 0.9em, radius: 4pt,
      stroke: 0.7pt + rgb("94a3b8"), fill: luma(98%))[
      #text(font: "New Computer Modern Sans", weight: "bold", size: 9.5pt)[Status of This Memo]
      #v(3pt)
      #text(size: 9.2pt)[
        #if state == "discussion" [
          This proposal is open for discussion. It records a design and its rationale;
          it does not establish acceptance or claim an implemented system.
        ] else if state == "published" [
          This is an accepted DocOdin design record. It may be clarified through reviewed revisions;
          publication does not imply that its implementation is complete.
        ] else if state == "committed" [
          This record describes an implemented design. Its implementation section identifies
          the applicable scope and evidence; operational qualification remains separately stated.
        ] else if state == "abandoned" [
          This proposal has been withdrawn or superseded. See its discussion history for the reason.
        ] else [
          This is a preliminary DocOdin discussion draft. Its scope and proposed direction may change.
        ]
      ]
    ]
    #v(0.6em)
    #body
    #metadata("sds-record-end")
  ])
}

#let sds-contents() = {
  pagebreak()
  context {
    let start = query(metadata.where(value: "sds-record-start").before(here())).last()
    let end = query(metadata.where(value: "sds-record-end").after(here())).first()
    outline(title: [Contents], indent: 1.4em, depth: 2,
      target: selector(heading).after(start.location()).before(end.location()))
  }
  pagebreak()
}

#let diagram-card(caption: none, body) = block(width: 100%, breakable: false,
  inset: 12pt, radius: 4pt, fill: luma(99.5%), stroke: 0.65pt + rgb("cbd5e1"), below: 1.4em)[
  #align(center)[#body]
  #if caption != none [
    #v(6pt)
    #line(length: 100%, stroke: 0.4pt + rgb("e2e8f0"))
    #v(4pt)
    #text(font: "New Computer Modern Sans", size: 8.5pt, style: "italic", fill: muted-color)[#caption]
  ]
]

#let sds-index-page(records) = {
  set document(title: "DocOdin Discussions", author: "DocOdin contributors")
  sds-pages("INDEX", [
    #block(width: 100%, inset: 14pt, radius: 4pt, stroke: 0.7pt + border-color, fill: rgb("f8fafc"))[
      #meta-label[DOCODIN PROJECT]
      #v(3pt)
      #text(font: "New Computer Modern Sans", size: 24pt, weight: "bold")[DocOdin Discussions]
      #v(5pt)
      Design proposals, mathematical foundations, and implementation records for DocOdin.
      The lifecycle follows SDS 1: discussion, published design, then committed implementation.
    ]
    #v(1em)
    #for record in records [
      #block(width: 100%, breakable: false, inset: 11pt, radius: 3pt,
        stroke: 0.6pt + border-color, below: 4mm)[
        #grid(columns: (1fr, auto), gutter: 12pt,
          [#text(font: "New Computer Modern Sans", size: 12.5pt, weight: "bold")[
            #link(record.pdf)[SDS #record.number: #record.title]
          ]], [#state-chip(record.state)])
        #v(4pt)
        #record.summary
        #v(5pt)
        #text(size: 8.5pt, fill: muted-color)[#record.category / Updated #record.at("last-updated")]
      ]
    ]
  ])
}

