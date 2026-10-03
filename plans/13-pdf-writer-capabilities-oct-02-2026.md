# PDF writer capability (plan, 2026-10-02)

Tier 6. Broadens what the package can *produce*. Last, because what ships
today is correct for what it does, and breadth here is a product decision
rather than a bug fix.

## Where the writer stands

Two layers exist and both work:

- **Low level** (`write.nim`): `PdfBuilder` with `addObject`,
  `addValue`, `addStream`, `addContentStream`, `addPage`, `adoptPage`,
  `addJpegImage`, `addRgbImage`, `setInfo`, `buildPdf`. Callers assemble
  content streams by hand.
- **High level** (`pdf.nim`, 588 lines): `newPdf`, `setPageSize`,
  `setMargin`, `setFont`, `newPage`, `paragraph`, `heading`, `textAt`,
  `imageFromFile`, `save`.

The high-level writer emits flowing text and JPEG/RGB images. Nothing
else. `pdf.nim:359` states the boundary honestly: "No hyphenation or
justification in v1."

Missing entirely: vector graphics, colour, tables, links, outlines, text
rendering modes, transparency, text style (weight, italic, underline,
colour, spacing), lists, headers and footers, page numbers, text
alignment.

## Locked decisions

- **Draw content in operators, not in a retained scene graph.** Emit
  content-stream bytes directly. A scene graph would need its own
  serialiser, invalidation model, and hit-testing, none of which the
  package needs. This matches `write.nim`'s existing philosophy.
- **Both layers get the same capabilities.** Adding colour only to the
  low-level builder means every high-level user hand-rolls operators.
  Where feasible, the high-level writer delegates to the low-level one.
- **The API shape is locked before implementation.** This is the phase
  most likely to churn, and churn is expensive once examples depend on
  it. Write the signatures, get them reviewed, then implement.
- **No justification engine.** Justification needs inter-word space
  measurement and a Knuth-Plass-style algorithm to avoid rivers. Out of
  scope; `pdf.nim:359` already says so.
- **Table output is a table *writer*, not the read-side heuristics.**
  `sheet.nim`'s `detectTables` is a reader that guesses. The writer takes
  explicit column widths and row heights and emits ruling lines. They
  share nothing.

## Reference map (libpdfjs -> Nim)

| libpdfjs | Nim target | Notes |
|---|---|---|
| `helpers/operators.ts` (814), 67 factories | new `ops.nim` | direct model, well-scoped |
| `drawing/path-builder.ts` (427) | `path.nim` | moveTo/lineTo/curveTo/close |
| `drawing/operations.ts` (488) | `gpath.nim` | paint ops, transforms |
| `drawing/types.ts` (500) | `types` for the above | |
| `drawing/text-layout.ts` (229) | wrap only; no justification | |
| `drawing/resources/` (6 files, 944) | shadings, patterns, extgstate | |
| `drawing/serialize.ts` (32) | fold into `ops.nim` | |
| `svg/path-parser.ts` (541), `arc-to-bezier.ts` (265) | `svg.nim` | optional, phase 4 |
| `annotations/` (22 files) | reuse plan 08's `PdfAnnot` shape | |
| `content/parsing/operators.ts` `KNOWN_OPERATORS` | arity validation | round-trips our own output |
| `api/pdf-page-tree.ts` (316) | `addPage`/`removePage` balancing | mostly exists |

`helpers/operators.ts` is the single most reusable file in libpdfjs for
this phase: 67 small operator factories with no dependencies.

## Phase 1: colour and text style

The cheapest large win, since almost every document needs it.

```nim
type
  PdfColor* = object
    ## Either RGB (0..1 floats) or grayscale (single value) or CMYK.

type
  TextStyle* = object
    font*: string
    size*: float64
    color*: PdfColor
    bold*, italic*, underline*, strikeout*: bool
    charSpacing*, wordSpacing*: float64
    rise*: float64
    renderMode*: int        ## Tr
    horizontalScale*: float64 ## Tz

proc setFillColor*(doc: var Pdf, c: PdfColor)
proc setStrokeColor*(doc: var Pdf, c: PdfColor)
proc textRun*(doc: var Pdf, text: string, style: TextStyle,
    x, y: float64)
proc paragraphStyled*(doc: var Pdf, text: string, style: TextStyle,
    align = alignLeft)
```

Emits `rg`/`RG`/`g`/`G`/`k`/`K`, `Tf` with a font slot per
(style, weight) pair, `Tc`/`Tw`/`Ts`/`Tz`/`Tr`, and `re f`/`re S` for
underline and strikeout. Alignment needs line-width measurement, which
`fontembed.nim` already provides via `measureText`.

Font slots: the writer keeps a slot table keyed by
`(baseName, bold, italic)` so a bold variant reuses the same TTF with a
synthetic bold or the caller's second font file. Synthetic emboldening is
what most producers do and is acceptable.

## Phase 2: vector graphics

```nim
type
  Path* = object
    cmds: seq[PathCmd]       ## MoveTo, LineTo, CurveTo, Close
    cur: Point
    start: Point

proc moveTo*(p: var Path, x, y: float64): Path
proc lineTo*(p: var Path, x, y: float64): Path
proc curveTo*(p: var Path, x1, y1, x2, y2, x3, y3: float64): Path
proc close*(p: var Path): Path
proc addRect*(p: var Path, x, y, w, h: float64): Path

proc stroke*(doc: var Pdf, p: Path, width = 1.0, c: PdfColor)
proc fill*(doc: var Pdf, p: Path, c: PdfColor)
proc fillEvenOdd*(doc: var Pdf, p: Path, c: PdfColor)
proc clip*(doc: var Pdf, p: Path)
proc line*(doc: var Pdf, x1, y1, x2, y2: float64, width = 1.0, c: PdfColor)
proc rect*(doc: var Pdf, x, y, w, h: float64, opts: RectOpts)
proc circle*(doc: var Pdf, cx, cy, r: float64, opts: FillOpts)
proc ellipse*(doc: var Pdf, cx, cy, rx, ry: float64, opts: FillOpts)

type
  FillOpts* = object
    fillColor*: PdfColor
    strokeColor*: PdfColor
    lineWidth*: float64
    evenOdd*: bool
    clipAfter*: bool
```

Circles and ellipses are four Bezier arcs; the kappa constant is
0.5522847498. `q`/`Q` around groups, `cm` for placement. Line caps,
joins, and dash patterns via `/ExtGState`.

Validate the output by running our own reader over it: plan 07 and 08
give us a parser that can confirm the operators and geometry round-trip.
That is a real test asset the package currently lacks.

## Phase 3: tables

```nim
type
  Column* = object
    width*: float64
    align*: Alignment
  Row* = object
    cells*: seq[string]
    style*: TextStyle
    height*: float64
  TableStyle* = object
    columns*: seq[Column]
    borders*: BorderSet        ## per edge: none/single/double, width, color
    headerRows*: int
    cellPadding*: float64

proc table*(doc: var Pdf, rows: seq[Row], style: TableStyle)
```

Cell layout: measure, wrap within column width using the existing
`wrapText`, emit each cell as its own text block plus optional ruling
lines. Row heights grow to fit wrapped content; a row that overflows the
page starts a new page and repeats the header.

This is a real layout engine. Timebox it: no cell spanning, no nested
tables, no vertical text. Say so in the module header.

## Phase 4: links, annotations, outlines

Link annotations reuse plan 08's `PdfAnnot`:

```nim
proc addLink*(b: var PdfBuilder, page, rect: array[4, float64],
    uri: string)
proc addInternalLink*(b: var PdfBuilder, page, rect: array[4, float64],
    targetPage: int, top: float64 = 0.0)
proc addText*(doc: var Pdf, x, y: float64, w, h: float64,
    contents: string, opts: TextAnnotOpts)
proc addRectAnnot*(doc: var Pdf, rect: array[4, float64],
    opts: SquareAnnotOpts)
```

Outlines:
```nim
proc addOutline*(b: var PdfBuilder, title: string,
    targetPage: int, top: float64 = 0.0,
    parent = -1): int
```
Builds `/Outlines` with `/First`/`/Next`/`/Count`, plus `/Dest` name
trees if needed. The read side (plan 08) is the test oracle.

Also: transparency (`/Group`, `ExtGState /ca` `/CA`) and simple
shadings (`sh` with axial and radial), which are the two most requested
items after colour.

Optional: SVG path import (`svg.nim`), reusing libpdfjs's parser and arc
conversion. Nice, self-contained, and a good showcase. Keep it out of the
critical path.

## Phase 5: document furniture

Lower value per line, but what makes output usable as a document rather
than a page dump.

- **Headers and footers**: content on every page, requires generating
  content after pagination is known. The builder writes content per page
  as it goes, so this needs a second pass over pages, which means
  `PdfBuilder` must support editing a page's content stream after
  `addPage`. Confirm that works before committing.
- **Page numbers**: a special case of headers and footers, but with a
  deferred evaluation problem. The total page count is not known until
  the document is laid out. Solution: lay out, count, then rewrite the
  placeholder. Implement page numbers first as the forcing function for
  the two-pass mechanism, then generalise.
- **Lists**: numbered and bulleted paragraphs with indentation. Real
  numbering needs the `/Numbering` structure tree; a simpler correct
  approach is explicit numbering in the content stream with fixed
  indents. Take the simple approach and document it.
- **Hyphenation**: needs a language-specific hyphenation dictionary
  (Liang's patterns, large). Skip.
- **Text alignment** (left/centre/right/justify-when-last-line-left):
  easy once `measureText` is wired, so it ships in phase 1.

## Phases

| Phase | Content | Note |
|---|---|---|
| Lock | Write the API signatures, review, then implement | do this before phase 1 |
| 1 | Colour, text style, alignment | biggest value per line |
| 2 | Vector graphics | plus `/ExtGState` basics |
| 3 | Tables | timeboxed, no spanning cells |
| 4 | Links, annotations, outlines, transparency, shadings | reuses plan 08 types |
| 5 | Headers, footers, page numbers, lists | needs the two-pass mechanism |
| 6 | SVG path import | optional |

## API-shape sketch

```nim
type
  Pdf* = object          ## existing, extended
    # private: pages, fonts, styles, graphics state

proc setFont*(doc: var Pdf, name: string)
proc setFontStyle*(doc: var Pdf, base = "", bold = false,
    italic = false)
proc setTextColor*(doc: var Pdf, c: PdfColor)
proc setFillColor*(doc: var Pdf, c: PdfColor)
proc setStrokeColor*(doc: var Pdf, c: PdfColor)
proc setLineWidth*(doc: var Pdf, w: float64)

proc paragraph*(doc: var Pdf, text: string)          ## existing
proc paragraph*(doc: var Pdf, text: string,
    style: TextStyle)                               ## new overload
proc heading*(doc: var Pdf, text: string, size = 18.0)  ## existing
proc textAt*(doc: var Pdf, text: string, x, y: float64,
    size = -1.0)                                    ## existing

proc line*(doc: var Pdf, x1, y1, x2, y2: float64,
    width = 1.0, c: PdfColor = black)
proc rect*(doc: var Pdf, x, y, w, h: float64,
    opts: FillOpts = FillOpts())
proc circle*(doc: var Pdf, cx, cy, r: float64,
    opts: FillOpts = FillOpts())

proc table*(doc: var Pdf, rows: seq[Row], style: TableStyle)
proc pageNumber*(doc: var Pdf, fmt = "", pos = footerRight)
```

Prefer overloads and defaulted parameters over a growing `Pdf` object.
A `graphicsState` object with explicit `push`/`pop` would eventually be
cleaner than implicit state, but it is a breaking change to every
existing call, so it is not proposed here.

## Testing

- **Self-consistency is the main oracle.** Write with the new API, read
  back with the existing reader, assert geometry: paths produce the
  expected operators and coordinates; colours round-trip; a table's text
  extracts with the right cell contents and approximate positions.
- **Visual oracle for phase 3 onwards.** Render with plan 10's poppler
  path and compare against expected layout, or check ink bounding boxes
  numerically (`extractText` positions, image placement).
- **Determinism**, continuing the existing property: byte-identical
  output for identical input across runs.
- **Round-trip through `rewritePdf`**: write, rewrite, re-extract, compare
  text and page count.
- **Compatibility gate**: any fixture produced must open in a real
  viewer. Plan 02 established this gate for docx via LibreOffice; the PDF
  equivalent is `qpdf --check` plus a poppler render, both of which should
  go into the test workflow.

## Risks

- **API churn is the main risk, and it is why the lock phase exists.**
  Every phase makes the previous one's signatures more likely to change.
  Get them right up front or accept rewrites.
- **Table layout** is the phase most likely to produce a layout engine
  that is subtly wrong (widow cells, header repetition, page splits).
  Timebox it.
- **Two-pass page numbering** changes `PdfBuilder`'s shape. Doing it in
  phase 5 means phases 1-4 ship with a builder that cannot edit page
  content; verify that assumption before building four phases on it.
- **Implicit graphics state** (`setFillColor` then `fill`) is convenient
  and will surprise anyone who forgets. The `q`/`Q` discipline in the
  generated content must be provably balanced; add a test that asserts
  it, because an unbalanced `q` corrupts everything after it.
