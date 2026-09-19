## Copyright (c) 2026 nimbase (MIT, see LICENSE at repo root).
## Portions derived from excelize (https://github.com/qax-os/excelize,
## commit 0434413, 2026-09-18): Copyright (c) 2016-2026 The excelize
## Authors, Copyright (c) 2011-2017 Geoffrey J. Teale, BSD-3-Clause.
## SPDX-License-Identifier: MIT AND BSD-3-Clause
##
## Worksheet part: lazy per-sheet parse plus the Phase A getters.
## Ports of excelize `workSheetReader`, `GetSheetList`, `GetSheetMap`,
## `GetRows`, `GetCols`, `GetCellValue` (raw), `GetCellType`,
## `GetCellFormula`, and `xlsxC.getValueFrom` (raw branch).

proc parseCell(cNode: XmlNode, posCol, posRow: int): Cell =
  ## One `c` element. Positional fallbacks (`posCol/posRow`) apply when
  ## `r` is absent; both are validated against the SpreadsheetML limits.
  var (col, row) = (posCol, posRow)
  let r = optAttr(cNode, "r")
  if r != "":
    (col, row) = splitCellRef(r)
  if col < 1 or col > XlsxMaxCols:
    raise newException(XlsxError, "column out of range in sheet")
  if row < 1 or row > XlsxMaxRows:
    raise newException(XlsxError, "row out of range in sheet")
  result = Cell(col: col, row: row,
    styleIdx: intAttr(cNode, "s", 0),
    cellType: cellTypeOf(optAttr(cNode, "t")))
  for kid in childElemsL(cNode, "v"): result.raw.add childText(kid)
  let fNode = firstChildL(cNode, "f")
  if fNode != nil:
    result.hasFormula = true
    var si = -1
    let siRaw = optAttr(fNode, "si")
    if siRaw != "":
      try: si = parseInt(siRaw)
      except ValueError:
        raise newException(XlsxError,
          "bad shared-formula index: " & siRaw)
    result.formula = CellFormula(content: childText(fNode),
      ftype: optAttr(fNode, "t"), si: si, `ref`: optAttr(fNode, "ref"))
  let isNode = firstChildL(cNode, "is")
  if isNode != nil: result.inlineText = siText(isNode)

proc parseSheet(f: XlsxFile, name: string): XlsxSheet =
  ## Parse and cache one sheet. Chartsheets (non-`worksheet` roots) fail
  ## loudly; chartsheet support is a later phase.
  let part = sheetPart(f, name)
  let root = readXmlPart(f, part)
  if root == nil:
    raise newException(XlsxError, "sheet part missing: " & part)
  if localName(root.tag) != "worksheet":
    raise newException(XlsxError,
      part & " root is <" & root.tag & ">, want <worksheet>")
  result = XlsxSheet(name: name, sheetId: f.sheetIds.getOrDefault(name),
    part: part, parsed: true)
  let dim = firstChildL(root, "dimension")
  if dim != nil: result.dimension = optAttr(dim, "ref")
  let data = firstChildL(root, "sheetData")
  if data == nil: return
  var posRow = 0
  for rNode in childElemsL(data, "row"):
    var rn = intAttr(rNode, "r", 0)
    if rn <= 0:
      rn = posRow + 1 # absent r: positional (excelize parity)
    if rn < 1 or rn > XlsxMaxRows:
      raise newException(XlsxError, "row out of range in sheet")
    posRow = rn
    var row = XlsxRow(r: rn, hidden: boolAttr(rNode, "hidden"),
      height: floatAttr(rNode, "ht", -1.0))
    var posCol = 0
    for cNode in childElemsL(rNode, "c"):
      posCol += 1
      let c = parseCell(cNode, posCol, rn)
      posCol = c.col # explicit r jumps the running position
      row.cells.add c
    result.rows.add row

proc getSheet*(f: XlsxFile, name: string): XlsxSheet =
  ## Parsed sheet by (any-case) name, cached after first parse.
  let real = resolveSheetName(f, name)
  if f.sheets.hasKey(real): return f.sheets[real]
  let s = parseSheet(f, real)
  f.sheets[real] = s
  s

proc findCell*(s: XlsxSheet, col, row: int): tuple[found: bool, cell: Cell] =
  ## Linear scan (row-major). Fine for Phase A; index later if profiling
  ## demands it.
  for r in s.rows:
    if r.r != row: continue
    for c in r.cells:
      if c.col == col: return (true, c)
  (false, Cell())

# ------------------------------------------------------------------ getters

func getSheetList*(f: XlsxFile): seq[string] =
  ## All sheet names in workbook order (incl. chart/dialog sheets).
  f.sheetOrder

func getSheetMap*(f: XlsxFile): Table[int, string] =
  ## sheetId -> name for the whole workbook.
  for n in f.sheetOrder:
    result[f.sheetIds.getOrDefault(n)] = n

proc resolveRaw*(f: XlsxFile, c: Cell): string =
  ## Phase A value resolution (excelize `getValueFrom`, raw branch):
  ## shared strings via the SST, inline strings verbatim, everything
  ## else (`b/d/e/n/str`, unset) as the stored `v`. Style formatting
  ## (Phase B) does not apply here.
  case c.cellType
  of ctySharedString:
    if c.raw == "": return ""
    let idx =
      try: parseInt(c.raw)
      except ValueError:
        raise newException(XlsxError,
          "bad shared string index: " & c.raw)
    sharedString(f, idx)
  of ctyInlineString: c.inlineText
  else: c.raw

proc cellDisplayValue*(f: XlsxFile, c: Cell): string =
  ## Formatted cell text (excelize `getValueFrom` + `formattedValue`).
  ## Raw mode (`rawCellValue` opt) or unstyled cells return `resolveRaw`
  ## verbatim; otherwise bools render TRUE/FALSE, ISO dates become
  ## serials, and numbers/dates render under the cell's builtin format
  ## (custom codes fall back to raw until Phase C).
  if f.opts.rawCellValue or c.styleIdx <= 0:
    return resolveRaw(f, c)
  case c.cellType
  of ctySharedString, ctyInlineString:
    resolveRaw(f, c) # text never formats under builtin ids
  of ctyBool:
    if c.raw == "1": "TRUE"
    elif c.raw == "0": "FALSE"
    else: formattedCellValue(f, c.raw, ctyBool, c.styleIdx)
  of ctyDate:
    let (ok, serial) = isoToSerial(c.raw)
    if ok: formattedCellValue(f, serial, ctyDate, c.styleIdx)
    else: c.raw
  of ctyError, ctyFormula:
    c.raw # error text and formula strings pass through unformatted
  of ctyUnset, ctyNumber:
    formattedCellValue(f, generalTrim(c.raw), ctyNumber, c.styleIdx)

proc placeRow(f: XlsxFile, row: XlsxRow): seq[string] =
  ## Row values indexed by column (0-based). Interior gaps pad with "";
  ## trailing blanks never materialize; empty non-formula cells occupy
  ## no slot (excelize `rowXMLHandler` parity, formatted values).
  for c in row.cells:
    let idx = c.col - 1
    let v = cellDisplayValue(f, c)
    if v == "" and not c.hasFormula: continue
    while result.len < idx: result.add ""
    if result.len == idx: result.add v
    else: result[idx] = v # overlapping refs: last wins (malformed input)

proc getRows*(f: XlsxFile, sheet: string): seq[seq[string]] =
  ## All rows as string grids. Row-number gaps surface as empty rows;
  ## rows past the last non-empty row are dropped (excelize parity).
  let s = getSheet(f, sheet)
  var cur = 0
  var maxSet = 0
  for r in s.rows:
    cur = r.r
    let placed = placeRow(f, r)
    if placed.len > 0:
      for _ in maxSet + 1 ..< cur: result.add @[]
      result.add placed
      maxSet = cur

proc getCols*(f: XlsxFile, sheet: string): seq[seq[string]] =
  ## Column-major transpose of `getRows`, trailing blanks trimmed.
  let rows = getRows(f, sheet)
  var width = 0
  for r in rows: width = max(width, r.len)
  result = newSeq[seq[string]](width)
  for r in rows:
    for j in 0 ..< width:
      result[j].add if j < r.len: r[j] else: ""
  for j in 0 ..< result.len:
    while result[j].len > 0 and result[j][^1] == "":
      discard result[j].pop()

proc getCellValue*(f: XlsxFile, sheet, cellRef: string): string =
  ## Cell value with number formatting applied ("", when the cell is
  ## absent). Shared strings are resolved; `rawCellValue` opt returns
  ## stored values verbatim.
  let (col, row) = splitCellRef(cellRef)
  let s = getSheet(f, sheet)
  let (found, c) = findCell(s, col, row)
  if not found: return ""
  cellDisplayValue(f, c)

proc getCellType*(f: XlsxFile, sheet, cellRef: string): CellType =
  ## Cell data type; `ctyUnset` when the cell is absent or untyped.
  let (col, row) = splitCellRef(cellRef)
  let (found, c) = findCell(getSheet(f, sheet), col, row)
  if not found: ctyUnset else: c.cellType

proc getCellFormula*(f: XlsxFile, sheet, cellRef: string): string =
  ## Formula text ("", when the cell has none).
  let (col, row) = splitCellRef(cellRef)
  let (found, c) = findCell(getSheet(f, sheet), col, row)
  if not found or not c.hasFormula: "" else: c.formula.content
