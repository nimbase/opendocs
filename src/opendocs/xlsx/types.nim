## Copyright (c) 2026 nimbase (MIT, see LICENSE at repo root).
## Portions derived from excelize (https://github.com/qax-os/excelize,
## commit 0434413, 2026-09-18): Copyright (c) 2016-2026 The excelize
## Authors, Copyright (c) 2011-2017 Geoffrey J. Teale, BSD-3-Clause.
## SPDX-License-Identifier: MIT AND BSD-3-Clause
##
## Spreadsheet `.xlsx`/`.xlsm`/`.xltx`/`.xltm`/`.xlam` (OOXML
## SpreadsheetML) reader model.
##
## Lazy like excelize: the package stays in `archive` (or spilled files) and
## sheets / shared strings parse on first access, then cache in `sheets`.

type
  XlsxError* = object of CatchableError

  CellType* = enum
    ## `t` attribute of a cell. `ctyUnset` mirrors excelize (`CellTypeUnset`):
    ## an absent `t` still resolves as a number.
    ctyUnset
    ctyBool
    ctyDate
    ctyError
    ctyFormula ## `t="str"` (formula-string cached value)
    ctyInlineString
    ctyNumber
    ctySharedString

  CellFormula* = object
    content*: string
    ftype*: string ## normal/array/shared/dataTable, "" = plain
    si*: int ## shared-formula index, -1 = absent
    `ref`*: string ## shared-formula range, "" = absent

  Cell* = object
    col*: int ## 1-based column (positional fallback resolved at parse)
    row*: int ## 1-based row (positional fallback resolved at parse)
    styleIdx*: int
    cellType*: CellType
    raw*: string ## `v` content, unformatted
    hasFormula*: bool
    formula*: CellFormula
    inlineText*: string ## resolved `is` text (rich runs concatenated)
    isNode*: XmlNode ## inline `is` element for lazy rich runs, nil otherwise

  XlsxRow* = object
    r*: int ## 1-based row number (positional fallback resolved at parse)
    cells*: seq[Cell]
    hidden*: bool
    height*: float ## -1 = absent

  XlsxMerge* = object
    `ref`*: string ## range as written (`A1:B2` or `A1`)
    firstRow*, lastRow*: int ## normalized 1-based row bounds
    firstCol*, lastCol*: int ## normalized 1-based column bounds
    anchorRow*, anchorCol*: int ## first stored cell in the range, 0 = none
    value*: string ## populated by `getMergeCells`, not during parsing

  XlsxDefinedName* = object
    name*: string
    refersTo*: string ## raw target with one leading `=` removed
    scope*: string ## `Workbook` or the owning sheet name
    hidden*: bool
    comment*: string

  XlsxHyperlink* = object
    cell*: string ## stored reference, which may be a range
    target*: string ## external URL, `""` for internal jumps
    location*: string ## internal destination, `""` for external links
    display*: string
    tooltip*: string


  XlsxCol* = object
    min*, max*: int ## 1-based inclusive column range
    width*: float ## explicit width; valid only when hasWidth is true
    hasWidth*: bool
    hidden*: bool
    bestFit*: bool
    customWidth*: bool
    outlineLevel*: int
    collapsed*: bool

  XlsxFont* = object
    ## Run font, excelize `Font` parity (`xmlStyles.go:342`) plus the
    ## `rPr`-only extras excelize drops (`scheme`, integer `family`).
    ## excelize quirk preserved: the typeface travels in `name` (its
    ## `Font.Family` carries the `rFont` value, not the integer family).
    ## Used for both rich-text runs and stylesheet fonts (the two parse
    ## sites differ only in `name` vs `rFont`).
    name*: string ## typeface (`rFont`/`name`), "" when absent
    size*: float64 ## 0.0 when absent
    bold*, italic*, strike*, outline*, shadow*, condense*,
      extend*: bool
    underline*: string ## "" absent; bare `<u/>` reads `"single"`
    vertAlign*: string ## "", "baseline", "superscript", "subscript"
    scheme*: string ## `rPr` scheme, "" when absent
    charset*: int
    hasCharset*: bool
    family*: int ## `rPr` integer family, valid only when hasFamily
    hasFamily*: bool
    color*: Color ## resolved run color (rgb/theme/indexed); invalid
      ## when no `color` element or when unresolvable (e.g. no theme
      ## part, like excelize's empty-string result)

  XlsxFill* = object
    ## Cell fill, excelize `Fill` parity (`xmlStyles.go`) with resolved
    ## colors instead of hex strings. `kind` is `"pattern"`, `"gradient"`,
    ## or `""` when the fill record is absent.
    kind*: string
    pattern*: string ## `patternType`, e.g. `"solid"`; "" when absent
    fgColor*, bgColor*: Color ## invalid when absent or `auto`
    gradientColors*: seq[Color] ## gradient stops in file order
    gradientType*: string ## e.g. `"path"`; "" when absent
    gradientDegree*: float64 ## 0.0 when absent
    shading*: int ## gradient variant index (`styleFillVariants`
      ## order), -1 when not a gradient or unmatched

  XlsxBorderSide* = object
    ## One border edge. `style` is the raw name (`"thin"`, ...), "" when
    ## the edge carries no style; `color` is invalid when unresolvable.
    style*: string
    color*: Color

  XlsxBorder* = object
    ## Cell border edges plus diagonal/outline flags. Sides default to
    ## empty (no style, invalid color) when the record omits them.
    left*, right*, top*, bottom*, diagonal*, vertical*,
      horizontal*: XlsxBorderSide
    diagonalUp*, diagonalDown*, outline*: bool

  XlsxAlignment* = object
    ## Cell alignment, excelize `Alignment` parity (`xmlStyles.go`).
    horizontal*, vertical*: string
    wrapText*, shrinkToFit*, justifyLastLine*: bool
    indent*, relativeIndent*: int
    readingOrder*: int
    textRotation*: int

  XlsxProtection* = object
    ## Cell protection flags. Both default false when the record or the
    ## attribute is absent (excelize `extractProtection` parity).
    hidden*, locked*: bool

  XlsxXf* = object
    ## One `cellXfs/xf` formatting record. Ids are -1 when the attribute
    ## is absent; `apply*` pairs follow the `has*` convention (absent
    ## counts as apply, matching excelize's nil-means-apply checks).
    numFmtId*: int
    fontId*, fillId*, borderId*, xfId*: int
    applyNumberFormat*, applyFont*, applyFill*, applyBorder*,
      applyAlignment*, applyProtection*: bool
    hasApplyNumberFormat*, hasApplyFont*, hasApplyFill*,
      hasApplyBorder*, hasApplyAlignment*, hasApplyProtection*: bool
    alignment*: XlsxAlignment
    hasAlignment*: bool
    protection*: XlsxProtection
    hasProtection*: bool

  XlsxStyle* = object
    ## Resolved cell style (excelize `GetStyle` shape, Nim-ified): the
    ## `xf` record's number format plus resolved font/fill/border/
    ## alignment/protection. `has*` is false when the part is absent,
    ## the apply flag forbids it, or the id is out of range.
    numFmtId*: int
    fontId*, fillId*, borderId*: int ## -1 when the xf omits the id
    hasFont*: bool
    font*: XlsxFont
    hasFill*: bool
    fill*: XlsxFill
    hasBorder*: bool
    border*: XlsxBorder
    hasAlignment*: bool
    alignment*: XlsxAlignment
    hasProtection*: bool
    protection*: XlsxProtection

  XlsxLocale* = object
    ## One locale's date-format data (excelize `languageInfo` parity):
    ## month and weekday names plus the AM/PM format. Generated from the
    ## pinned excelize commit; see `xlsx/locale_data.nim`.
    tags*: seq[string]
    monthsFull*, monthsAbbrev*, monthsNarrow*: array[12, string]
    weekdaysFull*: array[7, string]
    weekdaysAbbrev*: array[7, string]
    apFmt*: string ## e.g. `"AM/PM"`, `"午前/午後"`
    useGannen*: bool ## first-year `元` rendering (zh-TW only)

  XlsxRichRun* = object
    ## One rich-text run: text plus its direct formatting. Runs without
    ## `rPr` report `hasFont == false` (excelize nil-`Font` parity).
    text*: string
    hasFont*: bool
    font*: XlsxFont

  XlsxSheet* = object
    name*: string
    sheetId*: int
    state*: string ## visible/hidden/veryHidden, "" = visible
    part*: string ## package path of the sheet XML
    parsed*: bool
    dimension*: string ## used-range ref, "" = absent
    rows*: seq[XlsxRow]
    merges*: seq[XlsxMerge] ## in file order; first listed wins overlaps
    hyperlinks*: seq[XlsxHyperlink] ## in file order
    cols*: seq[XlsxCol] ## in file order; last matching range wins
    defaultColWidth*: float
    hasDefaultColWidth*: bool
    baseColWidth*: int
    hasBaseColWidth*: bool

  XlsxStylesheet* = object
    ## `xl/styles.xml` contents: custom format codes, the full `cellXfs`
    ## record table, font/fill/border tables, and the legacy indexed-
    ## color palette consulted by color resolution.
    numFmts*: Table[int, string] ## custom numFmtId -> format code
    cellXfs*: seq[XlsxXf] ## `cellXfs/xf` records in file order
    fonts*: seq[XlsxFont] ## `fonts/font` records in file order
    fills*: seq[XlsxFill] ## `fills/fill` records in file order
    borders*: seq[XlsxBorder] ## `borders/border` records in file order
    indexedColors*: seq[string] ## custom palette entries (raw `rgb`)

  XlsxFormatInfo* = object
    ## What `formattedCellValue` decided (P7): whether a number format
    ## applied, which one, and the rendered text when it did.
    applied*: bool
    numFmtId*: int
    code*: string ## builtin code or custom format code
    builtin*: bool
    text*: string ## rendered value when applied, raw value otherwise

const
  XlsxMaxRows* = 1048576 ## SpreadsheetML row limit
  XlsxMaxCols* = 16384 ## SpreadsheetML column limit (XFD)
  DefaultXlsxSpillThresholdBytes* = 64 * 1024 * 1024
    ## Spill parts to temp files when total inflated size exceeds this.
  DefaultXlsxSpillCapBytes* = 512 * 1024 * 1024
    ## Hard cap on total bytes spilled to disk (zip-bomb guard).

type
  XlsxReadOpts* = object
    spillThresholdBytes*: int = DefaultXlsxSpillThresholdBytes
      ## >0: spill when total inflated size exceeds it; 0: always spill;
      ## <0: never spill (pure in-memory).
    spillCapBytes*: int = DefaultXlsxSpillCapBytes
      ## Total spilled bytes allowed (<=0 selects the default cap).
    spillDir*: string = ""
      ## Parent for the spill dir ("" = system temp dir).
    rawCellValue*: bool = false
      ## Return raw values without number-format application (Phase B
      ## formatting honors this; Phase A readers are always raw).

type
  XlsxFileObj* = object
    ## Package handle contents (see `XlsxFile`). Split out so a
    ## `=destroy` hook can clean up the spill dir.
    archive*: ZipArchive
    spillDir*: string ## "" = memory mode
    opts*: XlsxReadOpts
    sheetOrder*: seq[string] ## all sheets in workbook order
    sheetParts*: Table[string, string] ## canonical name -> sheet part path
    sheetIds*: Table[string, int] ## canonical name -> sheetId
    definedNames*: seq[XlsxDefinedName] ## workbook order
    sheets*: Table[string, XlsxSheet] ## parsed-sheet cache
    sstLoaded*: bool
    sharedStrings*: seq[string]
    sstNodes*: seq[XmlNode] ## `si` elements, filled with sharedStrings
    themeLoaded*: bool
    themeColors*: array[10, string] ## lt1/dk1/lt2/dk2/accent1-6/hlink/folHlink
    date1904*: bool ## workbook date system (Phase B formatting)
    styles*: XlsxStylesheet ## eager stylesheet (missing part -> empty)

  XlsxFile* = ref XlsxFileObj
    ## Owns the package for its lifetime: `archive` in memory mode, or the
    ## spill dir on disk. Close with `closeXlsx` (also runs on destroy).
