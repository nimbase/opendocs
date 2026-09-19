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

  XlsxRow* = object
    r*: int ## 1-based row number (positional fallback resolved at parse)
    cells*: seq[Cell]
    hidden*: bool
    height*: float ## -1 = absent

  XlsxSheet* = object
    name*: string
    sheetId*: int
    state*: string ## visible/hidden/veryHidden, "" = visible
    part*: string ## package path of the sheet XML
    parsed*: bool
    dimension*: string ## used-range ref, "" = absent
    rows*: seq[XlsxRow]

  XlsxStylesheet* = object
    ## `xl/styles.xml` subset needed for value formatting: custom format
    ## codes (Phase C data, parsed now) and the per-xf number format ids.
    numFmts*: Table[int, string] ## custom numFmtId -> format code
    cellXfs*: seq[int] ## numFmtId per xf (absent attr -> 0)

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
    sheets*: Table[string, XlsxSheet] ## parsed-sheet cache
    sstLoaded*: bool
    sharedStrings*: seq[string]
    date1904*: bool ## workbook date system (Phase B formatting)
    styles*: XlsxStylesheet ## eager stylesheet (missing part -> empty)

  XlsxFile* = ref XlsxFileObj
    ## Owns the package for its lifetime: `archive` in memory mode, or the
    ## spill dir on disk. Close with `closeXlsx` (also runs on destroy).
