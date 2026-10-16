# XLSX read-side completeness (plan, 2026-10-03)

Tier 1, workstream 3 of 3. Everything the reader cannot currently see,
aside from merges/geometry/names (plan 15) and formats/styles (plan 16).

## Locked decisions

- **Read-only.** No writers here.
- **Properties are flat string maps**, matching excelize's `docProps.go`.
  The alternative is typed core-properties, which is nicer but is not
  what the reference does and invites scope creep.
- **Comments expose text and author, not VML geometry.** excelize's
  `vml.go` is 1,245 lines because it must *write* comment shapes. The
  read half is far smaller.
- **Pictures return bytes plus their anchor cell**, not decoded images.
  Decoding belongs to a caller who wants pixels; `xl/media` holds whatever
  the file embedded, including EMF and WMF, which have no decoder in this
  package.
- **Page layout is reported raw, not rendered.** No paper simulation.
- **Protect flags are reported, never enforced.** This is a reader.

## Work items

### 1. docProps

Absent. There is no `xlsx/docprops.nim`, and `docProps` has zero hits in
the subsystem. The docx reader already does this at
`docx/reader.nim:924-952` and `:1313-1331`, so the shape and the
namespace handling can be copied rather than invented.

Three parts:

| Part | Root element | Notes |
|---|---|---|
| `docProps/core.xml` | `cp:coreProperties` | Dublin Core; dates are ISO 8601 |
| `docProps/app.xml` | `Properties` | application, sheet titles, company |
| `docProps/custom.xml` | `Properties` | arbitrary named properties |

```nim
proc getDocProps*(f: XlsxFile): XlsxDocProps
proc getAppProps*(f: XlsxFile): XlsxAppProps
proc getCustomProps*(f: XlsxFile): Table[string, string]
type XlsxDocProps* = object
  title*, subject*, creator*, keywords*, description*, category*,
    contentStatus*, lastModifiedBy*, identifier*, language*, version*,
    created*, modified*, lastPrinted*: string
```

- **Namespaces must be handled by local name, not prefix.** `dc:creator`
  and `creator` are the same thing and producers vary. `localName`
  (`base.nim:20`) already strips prefixes; reuse it.
- Core props are optional. A missing part yields empty strings, never an
  error, matching how `loadStyles` already behaves.
- `app.xml` carries `<TitlesOfParts>` and `<HeadingPairs>` which describe
  sheets rather than the document. Surface sheet count; do not duplicate
  the sheet list into props.
- `custom.xml` property values are typed (`vt:lpwstr`, `vt:i4`,
  `vt:bool`, `vt:filetime`). Flatten to string and document the loss, per
  the flat-map decision.
- `xlsx/contenttypes.nim` from plan 05's module layout is **not** written
  for this. Part lookup is by path, and the parts above have fixed names.
  The content-types matrix remains unwritten; that is a deliberate
  reversal of plan 05's layout list, recorded here so it does not read as
  an oversight.

### 2. Header/footer and page layout

Absent: no `headerFooter`, `oddHeader`, `pageSetup`, `pageMargins`, or
`orientation` anywhere in the subsystem.

```nim
type
  XlsxPageLayout* = object
    orientation*: string        ## "portrait"/"landscape"
    paperSize*: int
    scale*: int
    fitToWidth*, fitToHeight*: int
    firstPageNumber*: int
    orientationChanged*: bool
  XlsxPageMargins* = object
    left*, right*, top*, bottom*, header*, footer*: float
  XlsxHeaderFooter* = object
    oddHeader*, oddFooter*, evenHeader*, evenFooter*,
      firstHeader*, firstFooter*: string
    differentOddEven*, differentFirst*: bool
proc getPageLayout*(f: XlsxFile, sheet: string): XlsxPageLayout
proc getPageMargins*(f: XlsxFile, sheet: string): XlsxPageMargins
proc getHeaderFooter*(f: XlsxFile, sheet: string): XlsxHeaderFooter
```

- These are sheet-level elements after `sheetData` and before `mergeCells`
  in practice; ordering in the file is not guaranteed, so match by local
  name rather than by position.
- `&L`/`&C`/`&R` and `&P`/`&N`/`&D`/`&T`/`&Z`/`&F`/`&A` are **formatting
  codes, not text**. Return the raw string and document it. Splitting into
  sections is cheap and useful, so offer both: the raw string plus
  `left`/`center`/`right` fields.
- `firstHeader`/`firstFooter` exist only when `differentFirst` is set.
- **Print area and print titles are defined names**, not sheet elements
  (`_xlnm.Print_Area`). They come from plan 15's defined-names work; this
  plan consumes them and does not re-read them.
- Row and column page breaks (`rowBreaks`, `colBreaks`) are adjacent and
  cheap. Include them; excelize exposes insertion but not retrieval, so
  this is beyond parity and cheap.

### 3. Comments (notes)

Absent. No `comments.xml`, no VML, no `<legacyDrawing>` relationship.

```nim
type
  XlsxComment* = object
    cell*: string
    author*: string
    text*: string           ## runs concatenated, like rich text
    runs*: seq[XlsxRichRun]
proc getComments*(f: XlsxFile, sheet: string): seq[XlsxComment]
```

- Chain: `<legacyDrawing r:id>` on the sheet points to a VML part; the
  comments part is reached from the sheet's `.rels` by relationship type
  `.../comments`, not from the VML. excelize's `GetComments`
  (`vml.go:50`) does this.
- The comments part holds one `<authors>` list plus one `<commentList>`
  with `<comment ref="B2" authorId="n">`. **Author resolution is by index
  into `authors`**, and the index is frequently out of range in
  producer-generated files; fall back to `""` rather than raising.
- `<text>` contains the same run structure as rich text, so plan 16's run
  type serves both. Reuse `siText`-style concatenation for `text` and
  expose `runs` for callers who want formatting.
- **VML shape geometry is deliberately not parsed.** excelize parses it
  because it writes it. A reader that wants comment boxes needs a drawing
  reader (item 4) anyway.
- Threads: modern threaded comments use `xl/threadedComments/` plus a
  persons part. Out of scope; note it, since a file may contain both and
  the legacy reader will show only the parent comment.

### 4. Pictures and drawings

Absent: no drawing rel resolution, no `xl/media` access.

```nim
type
  XlsxPicture* = object
    cell*: string
    bytes*: string          ## raw media bytes
    ext*: string            ## "png", "jpg", "emf", ...
    anchor*: string         ## "oneCell" / "twoCell" / "absolute"
    fromRow*, fromCol*, toRow*, toCol*: int   ## -1 when not twoCell
proc getPictures*(f: XlsxFile, sheet: string): seq[XlsxPicture]
proc getPictureCells*(f: XlsxFile, sheet: string): seq[string]
```

- Chain: sheet `<drawing r:id>` to `xl/drawings/drawing1.xml`, then its
  `twoCellAnchor`/`oneCellAnchor` elements to `<xdr:pic><xdr:blipFill>`,
  whose `r:embed` resolves through the **drawing's** rels to `xl/media/*`.
  Three rel hops; the drawing has its own rels file, which is the step
  most implementations miss.
- **Excel 365 `cellimages.xml`** is a second, different location for
  in-cell images (`DISPIMG`, WPS variant). excelize handles it in
  `decodeCellImages`. Include it: it is the only way to see images
  produced by some modern tools.
- `ext` comes from the relationship `Target` suffix or the content-type
  override. Do not sniff.
- **EMF and WMF have no decoder here.** Return bytes and say so. Same for
  `WMZ`, `EMZ`, which are zipped variants.
- Charts are *not* in this plan. excelize has no chart read API at all,
  so there is no read-side parity to match, and reading a chart means
  interpreting `c:chart` XML which is a separate body of work. Out of
  scope; noted in the index's "beyond parity".

### 5. Rich text run formatting

`sharedstrings.nim:10` concatenates `<t>` and every `<r><t>`, which is
correct for the plain value and throws away formatting. Add the run type
and a getter:

```nim
type
  XlsxRichRun* = object
    text*: string
    font*: XlsxFont          ## from plan 16
    bold*, italic*, strike*: bool
    underline*: string
    color*: string
    size*: float
    vertAlign*: string       ## superscript/subscript
proc getCellRichText*(f: XlsxFile, sheet: string, cell: string): seq[XlsxRichRun]
```

- `<rPr>` children are in the same namespace as fonts in `styles.xml`
  (`<b/>`, `<i/>`, `<color theme="4"/>`, `<sz val="11"/>`, `<vertAlign val="superscript"/>`, `<rFont/>`, `<charset/>`, `<family/>`, `<scheme/>`, `<u/>`, `<strike/>`).
- **A run without `<rPr>` inherits nothing here**, since rich-text runs
  carry a complete inline style rather than a `styles.xml` index. Do not
  try to merge with the cell's font.
- `<t xml:space="preserve">` matters: without it, leading and trailing
  spaces are lost. Check the attribute explicitly rather than relying on
  the parser's whitespace handling. This is a real correctness item and
  easy to miss.
- **Phonetic runs (`<rPh>`)** are Japanese furigana. excelize parses them
  (`xmlSharedStrings.go:44`) and exposes nothing. Include in the run type
  as an optional field, since the data is already there and dropping it
  silently loses text.

### 6. Sheet-level properties worth reading

Cheap, and all already in `workbook.xml` or `sheetN.xml` root elements:

- `sheetPr`: `codeName` (needed to correlate with `vbaProject.bin` in
  plan 19), `filterMode`, tab colour
- `sheetView`: `showGridLines`, `zoomScale`, `tabSelected`, RTL
- `tabColor` for the tab strip
- `sheetProtection`: read the flags, do not enforce
- `sheetFormatPr`: `defaultRowHeight`, `defaultColWidth`, `baseColWidth`

These are all in the same XML the sheet parse already reads; there is no
new file handling, which is why they are cheap.

## Reference map (excelize -> Nim)

| excelize | Nim target | Notes |
|---|---|---|
| `docProps.go:212` `GetDocProps` | `getDocProps` | flat map, like ours |
| `docProps.go:84` `GetAppProps`, `:315` `GetCustomProps` | same names | |
| `docx/reader.nim:1313-1331` | our precedent | copy the shape |
| `sheet.go:1374` `GetHeaderFooter` | `getHeaderFooter` | |
| `sheet.go:1727` `GetPageLayout`, `sheetpr.go:55` `GetPageMargins` | same | |
| `vml.go:50` `GetComments` | `getComments` | read half only |
| `xmlComments.go:85` | comments schema | authorId indexing |
| `picture.go:540` `GetPictures`, `:574` `GetPictureCells` | same | |
| `picture.go` `decodeCellImages` | Excel 365 in-cell images | include |
| `xmlDecodeDrawing.go` | lenient decode pattern | useful shape |
| `cell.go:1227` `GetCellRichText` | `getCellRichText` | |
| `sheetview.go:89` `GetSheetView`, `sheetpr.go:182` `GetSheetProps` | same | |

## Phases

1. **P1 docProps.** Three parts, flat maps, namespace-agnostic.
2. **P2 sheet properties and sheet view.** Cheapest; all in parsed XML.
3. **P3 rich text runs.** Depends on plan 16's `XlsxFont`.
4. **P4 header/footer, page layout, margins, breaks.** Consumes plan 15's
   defined names for print areas.
5. **P5 comments.**
6. **P6 pictures and drawings.** Last; most rel-hop work.

## Fixtures

- `props_full.xlsx`: core with every field, app with titles and headings,
  custom with all four `vt` value types.
- `props_sparse.xlsx`: core only, with empty and missing elements;
  `docProps` entirely absent.
- `props_weirdns.xlsx`: default namespace rather than `dc:` prefixes, to
  prove local-name matching works.
- `page_setup.xlsx`: portrait and landscape, `paperSize`, `scale` versus
  `fitToWidth`, odd/even/first header/footer all populated, row and column
  breaks, `differentFirst` unset with a `firstHeader` present.
- `comments_basic.xlsx`: three comments, two authors, multi-run text,
  `xml:space="preserve"` runs with leading spaces.
- `comments_badauthor.xlsx`: `authorId` past the end of `authors`.
- `pictures.xlsx`: `twoCellAnchor` and `oneCellAnchor`, PNG and JPEG, a
  chart graphicData drawing that must be skipped, and an `extLst` entry.
- `pictures_cellimages.xlsx`: Excel 365 in-cell image via `cellimages.xml`.
- `richtext.xlsx`: bold, italic, colour via theme index, size,
  superscript, `<rPh>` phonetic run, a run with no `rPr`.
- `richtext_whitespace.xlsx`: runs whose text is only spaces.
- `sheet_props.xlsx`: tab colour, hidden gridlines, code name, protection
  flags, custom default widths.

Generate with LibreOffice where it will emit the shape; hand-write the
malformed ones. excelize cannot write comments or custom props, so those
fixtures are LibreOffice or hand-built.

## Testing

- Namespace-agnostic property lookup gets its own test with the weird
  prefix fixture, because that is the failure mode a normal fixture
  cannot catch.
- Author-index-out-of-range must return `""` and not raise.
- `xml:space="preserve"` gets a fixture whose only content is whitespace,
  since a naive parser returns `""` and a test using normal text passes
  anyway.
- Picture rels: assert the three-hop chain works, and assert a broken
  `r:embed` yields an entry with empty `bytes` rather than raising.
- A drawing that contains only a chart must return zero pictures, not one
  empty one.
- EMF bytes must round-trip byte-identically from the package, which is
  the only assertion possible without a decoder.
- Assert absence is empty and not an error for every part in this plan,
  consistent with `loadStyles`.

## Risks

- **Comments have two on-disk formats and we read one.** Threaded
  comments (`xl/threadedComments/`) mean a modern file may show only
  parent comments. Document it; do not silently merge.
- **VML is a dead format that is nonetheless mandatory for comments.**
  The comment text lives in the comments part, not VML, so skipping VML
  is safe for text but means no box geometry. excelize's 1,245 lines are
  mostly VML geometry for the write path.
- **Picture media can be EMF/WMF and there is no decoder.** Returning
  bytes is honest; a caller expecting pixels will be disappointed, so the
  header must say so.
- **Three rel hops for pictures** is where this usually breaks. One
  fixture with an external-target image relationship would be good, since
  those should be skipped rather than resolved.
- **`app.xml` titles duplicate the sheet list** and can disagree with
  `workbook.xml` after edits. Trust `workbook.xml` for sheet identity;
  `app.xml` is metadata only. Say so, or someone will reconcile them.
- **Rich text has no `<rPr>` inheritance**, so a caller wanting "effective"
  formatting must merge the run font with the cell font themselves. Worth
  an explicit note since it differs from how DOCX works.
- **Charts are excluded**, which leaves a visible hole: a chart renders as
  nothing rather than as its placeholder. excelize is equally blind, so
  this is parity, but it is a limitation a user will hit.