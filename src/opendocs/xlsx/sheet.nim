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

proc parseMergeBounds(refStr, part: string): tuple[firstCol, firstRow,
    lastCol, lastRow: int] =
  ## Normalize `A1:B2`, `$A$1:$B$2`, reversed ranges, and single cells.
  ## Bounds stay inside the SpreadsheetML grid; invalid ranges raise.
  let ends = refStr.split(':')
  if ends.len < 1 or ends.len > 2:
    raise newException(XlsxError, "bad merge range in " & part & ": " &
      refStr)
  let last = if ends.len == 2: ends[1] else: ends[0]
  let (startCol, startRow) =
    try: splitCellRef(ends[0])
    except XlsxError as e:
      raise newException(XlsxError, "bad merge range in " & part & ": " &
        refStr & " (" & e.msg & ")")
  let (endCol, endRow) =
    try: splitCellRef(last)
    except XlsxError as e:
      raise newException(XlsxError, "bad merge range in " & part & ": " &
        refStr & " (" & e.msg & ")")
  (min(startCol, endCol), min(startRow, endRow),
    max(startCol, endCol), max(startRow, endRow))

proc mergeAnchor(s: XlsxSheet, m: XlsxMerge,
    prior: seq[XlsxMerge] = @[]): tuple[found: bool, cell: Cell] =
  ## Stored cell supplying a merged range's value. Excel keeps the value in
  ## the top-left cell, but malformed files may store it elsewhere, so scan
  ## the range in row-major order rather than assuming the first corner.
  ## Cells already claimed by an earlier overlapping merge are skipped, so
  ## file order decides overlaps.
  for r in s.rows:
    if r.r < m.firstRow or r.r > m.lastRow: continue
    for c in r.cells:
      if c.col < m.firstCol or c.col > m.lastCol: continue
      var claimed = false
      for p in prior:
        if c.col >= p.firstCol and c.col <= p.lastCol and
            r.r >= p.firstRow and r.r <= p.lastRow:
          claimed = true
          break
      if claimed: continue
      if c.raw != "" or c.inlineText != "" or c.hasFormula:
        return (true, c)
  (false, Cell())

proc reqIntAttr(node: XmlNode, name, part, what: string): int =
  ## Required integer attribute. Unlike `intAttr`, malformed values raise
  ## instead of falling back to a default.
  let raw = optAttr(node, name)
  if raw == "":
    raise newException(XlsxError, "missing " & what & " in " & part)
  try: parseInt(raw)
  except ValueError:
    raise newException(XlsxError, "bad " & what & " in " & part & ": " & raw)

proc optFloatAttr(node: XmlNode, name: string): tuple[present: bool,
    value: float] =
  ## Optional floating-point attribute. Malformed values raise; absent
  ## values are reported rather than defaulted.
  let raw = optAttr(node, name)
  if raw == "": return (false, 0.0)
  try: (true, parseFloat(raw))
  except ValueError:
    raise newException(ValueError, "bad " & name & " attribute: " & raw)

proc optIntAttr(node: XmlNode, name: string): tuple[present: bool,
    value: int] =
  ## Optional integer attribute with the same malformed-value behavior.
  let raw = optAttr(node, name)
  if raw == "": return (false, 0)
  try: (true, parseInt(raw))
  except ValueError:
    raise newException(ValueError, "bad " & name & " attribute: " & raw)

proc parseCol(colNode: XmlNode, part: string): XlsxCol =
  ## One `<col>` range. Overlapping file entries are preserved; getters
  ## apply last-wins semantics.
  let min = reqIntAttr(colNode, "min", part, "column min")
  let max = reqIntAttr(colNode, "max", part, "column max")
  if min < 1 or max < 1 or min > XlsxMaxCols or max > XlsxMaxCols:
    raise newException(XlsxError, "column range out of range in " & part &
      ": " & $min & "-" & $max)
  if min > max:
    raise newException(XlsxError, "bad column range in " & part & ": " &
      $min & "-" & $max)
  let (hasWidth, width) =
    try: optFloatAttr(colNode, "width")
    except ValueError as e:
      raise newException(XlsxError, e.msg & " in " & part)
  let (hasOutline, outline) =
    try: optIntAttr(colNode, "outlineLevel")
    except ValueError as e:
      raise newException(XlsxError, e.msg & " in " & part)
  if hasOutline and (outline < 0 or outline > 7):
    raise newException(XlsxError, "bad outlineLevel in " & part & ": " &
      $outline)
  XlsxCol(min: min, max: max, width: width, hasWidth: hasWidth,
    hidden: boolAttr(colNode, "hidden"),
    bestFit: boolAttr(colNode, "bestFit"),
    customWidth: boolAttr(colNode, "customWidth"),
    outlineLevel: if hasOutline: outline else: 0,
    collapsed: boolAttr(colNode, "collapsed"))

proc parseSheetFormatPr(formatNode: XmlNode, part: string): tuple[
    hasDefaultWidth: bool, defaultWidth: float, hasBaseWidth: bool,
    baseWidth: int] =
  ## Sheet defaults used only when no explicit column width matches.
  if formatNode == nil: return (false, 0.0, false, 0)
  let (hasDefault, defaultWidth) =
    try: optFloatAttr(formatNode, "defaultColWidth")
    except ValueError as e:
      raise newException(XlsxError, e.msg & " in " & part)
  let (hasBase, baseWidth) =
    try: optIntAttr(formatNode, "baseColWidth")
    except ValueError as e:
      raise newException(XlsxError, e.msg & " in " & part)
  (hasDefault, defaultWidth, hasBase, baseWidth)

proc sheetRelsPath(part: string): string =
  ## `xl/worksheets/sheet1.xml` -> `xl/worksheets/_rels/sheet1.xml.rels`.
  let slash = part.rfind('/')
  if slash < 0: "_rels/" & part & ".rels"
  else: part[0 .. slash] & "_rels/" & part[slash + 1 .. ^1] & ".rels"

proc hyperlinkTarget(f: XlsxFile, part, rid: string): string =
  ## External hyperlink target resolved through the sheet's relationships.
  ## The target is returned verbatim: package-path resolution is for package
  ## parts, not absolute URLs. Missing rels or an unresolvable ID yields an
  ## empty target because a dangling link is not fatal to the workbook.
  let relsNode = readXmlPart(f, sheetRelsPath(part))
  if relsNode == nil: return ""
  for r in readRels(relsNode):
    if r.id == rid:
      if r.relType.endsWith("/hyperlink"): return r.target
      return ""
  ""

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
  if data != nil:
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
  let formatNode = firstChildL(root, "sheetFormatPr")
  let (hasDefaultWidth, defaultWidth, hasBaseWidth, baseWidth) =
    parseSheetFormatPr(formatNode, part)
  result.hasDefaultColWidth = hasDefaultWidth
  result.defaultColWidth = defaultWidth
  result.hasBaseColWidth = hasBaseWidth
  result.baseColWidth = baseWidth
  let colsNode = firstChildL(root, "cols")
  if colsNode != nil:
    for colNode in childElemsL(colsNode, "col"):
      result.cols.add parseCol(colNode, part)
  let mcNode = firstChildL(root, "mergeCells")
  if mcNode != nil:
    for kid in childElemsL(mcNode, "mergeCell"):
      let refStr = optAttr(kid, "ref")
      if refStr == "":
        raise newException(XlsxError, "merge cell without ref in " & part)
      let (firstCol, firstRow, lastCol, lastRow) =
        parseMergeBounds(refStr, part)
      result.merges.add XlsxMerge(`ref`: refStr, firstRow: firstRow,
        lastRow: lastRow, firstCol: firstCol, lastCol: lastCol)
    for i in 0 ..< result.merges.len:
      let (hasAnchor, anchor) = mergeAnchor(result, result.merges[i],
        result.merges[0 ..< i])
      if hasAnchor:
        result.merges[i].anchorRow = anchor.row
        result.merges[i].anchorCol = anchor.col
  let linksNode = firstChildL(root, "hyperlinks")
  if linksNode != nil:
    for linkNode in childElemsL(linksNode, "hyperlink"):
      let refStr = optAttr(linkNode, "ref")
      if refStr == "":
        raise newException(XlsxError, "hyperlink without ref in " & part)
      discard parseMergeBounds(refStr, part)
      let rid = optAttr(linkNode, "r:id")
      var target = ""
      if rid != "": target = hyperlinkTarget(f, part, rid)
      result.hyperlinks.add XlsxHyperlink(cell: refStr, target: target,
        location: optAttr(linkNode, "location"),
        display: optAttr(linkNode, "display"),
        tooltip: optAttr(linkNode, "tooltip"))

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

proc mergeAt(s: XlsxSheet, col, row: int): tuple[found: bool, merge: XlsxMerge] =
  ## First-listed merge covering a coordinate. Overlapping declarations are
  ## malformed but occur; listing order decides instead of a crash.
  for m in s.merges:
    if col >= m.firstCol and col <= m.lastCol and
        row >= m.firstRow and row <= m.lastRow:
      return (true, m)
  (false, XlsxMerge())

proc mergedCell(s: XlsxSheet, col, row: int): tuple[
    covered: bool, cell: Cell] =
  ## Anchor cell for a merge-covered coordinate. Covered cells redirect to
  ## the recorded anchor even when they physically store another value: a
  ## stored non-anchor value is malformed, while the merge declaration is
  ## the authoritative layout.
  let (found, m) = mergeAt(s, col, row)
  if not found: return (false, Cell())
  if m.anchorCol <= 0 or m.anchorRow <= 0: return (true, Cell())
  let (hasAnchor, anchor) = findCell(s, m.anchorCol, m.anchorRow)
  if hasAnchor: (true, anchor) else: (true, Cell())

proc findSheetRow(s: XlsxSheet, row: int): tuple[found: bool, sheetRow: XlsxRow] =
  ## Exact row record. Absent rows are valid and use default geometry.
  for r in s.rows:
    if r.r == row: return (true, r)
  (false, XlsxRow())

proc findSheetCol(cols: seq[XlsxCol], col: int): tuple[found: bool,
    sheetCol: XlsxCol] =
  ## Last file-ordered `<col>` range containing the column.
  var hit = false
  var hitCol = XlsxCol()
  for c in cols:
    if col >= c.min and col <= c.max:
      hit = true
      hitCol = c
  (hit, hitCol)

proc hyperlinkCovers(link: XlsxHyperlink, col, row: int,
    part: string): bool =
  ## Stored hyperlink refs may be ranges. Covered cells report the stored
  ## reference rather than an expanded span.
  let (firstCol, firstRow, lastCol, lastRow) =
    parseMergeBounds(link.cell, part)
  col >= firstCol and col <= lastCol and row >= firstRow and row <= lastRow

# ------------------------------------------------------------------ getters

func getSheetList*(f: XlsxFile): seq[string] =
  ## All sheet names in workbook order (incl. chart/dialog sheets).
  f.sheetOrder

func getSheetMap*(f: XlsxFile): Table[int, string] =
  ## sheetId -> name for the whole workbook.
  for n in f.sheetOrder:
    result[f.sheetIds.getOrDefault(n)] = n

proc getSheetDimension*(f: XlsxFile, sheet: string): string =
  ## Stored used-range reference, `""` when absent. Malformed values raise
  ## instead of returning a partial range.
  let s = getSheet(f, sheet)
  if s.dimension == "": return ""
  discard parseMergeBounds(s.dimension, s.part)
  s.dimension

proc getRowHeight*(f: XlsxFile, sheet: string, row: int): float =
  ## Explicit row height, or `-1` when the row or height is absent. Excelize
  ## substitutes its default row height; this reader preserves absence so
  ## callers can distinguish an explicit height from a default.
  if row < 1:
    raise newException(XlsxError, "row out of range: " & $row)
  let (found, sheetRow) = findSheetRow(getSheet(f, sheet), row)
  if found: sheetRow.height else: -1.0

proc getRowVisible*(f: XlsxFile, sheet: string, row: int): bool =
  ## Whether a row is visible. Absent rows are visible; only an explicit
  ## hidden row record reports false.
  if row < 1:
    raise newException(XlsxError, "row out of range: " & $row)
  let (found, sheetRow) = findSheetRow(getSheet(f, sheet), row)
  if found: not sheetRow.hidden else: true

proc getColWidth*(f: XlsxFile, sheet: string, col: int): float =
  ## Explicit column width in one-based column index form, or `-1` when no
  ## width is set. Unlike excelize's name-based getter, this port does not
  ## substitute Excel's 8.43 default for absent widths.
  if col < 1 or col > XlsxMaxCols:
    raise newException(XlsxError, "column out of range: " & $col)
  let s = getSheet(f, sheet)
  let (found, sheetCol) = findSheetCol(s.cols, col)
  if found and sheetCol.hasWidth: return sheetCol.width
  if s.hasDefaultColWidth: return s.defaultColWidth
  if s.hasBaseColWidth: return s.baseColWidth.float
  -1.0

proc getColVisible*(f: XlsxFile, sheet: string, col: int): bool =
  ## Whether a column is visible. Absent columns are visible; overlapping
  ## `<col>` ranges use the last matching entry.
  if col < 1 or col > XlsxMaxCols:
    raise newException(XlsxError, "column out of range: " & $col)
  let (found, sheetCol) = findSheetCol(getSheet(f, sheet).cols, col)
  if found: not sheetCol.hidden else: true

proc getHyperlinks*(f: XlsxFile, sheet: string): seq[XlsxHyperlink] =
  ## Hyperlinks in file order, with external targets resolved verbatim.
  getSheet(f, sheet).hyperlinks

proc getCellHyperlink*(f: XlsxFile, sheet, cellRef: string): tuple[
    found: bool, link: XlsxHyperlink] =
  ## Hyperlink covering a cell. Range-valued links match covered cells but
  ## return the stored reference, not the span.
  let (col, row) = splitCellRef(cellRef)
  let s = getSheet(f, sheet)
  for link in s.hyperlinks:
    if hyperlinkCovers(link, col, row, s.part): return (true, link)
  (false, XlsxHyperlink())

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

proc getMergeCells*(f: XlsxFile, sheet: string): seq[XlsxMerge] =
  ## Merged ranges in file order. `value` is resolved from the anchor cell
  ## when a stored anchor exists. `getRows` intentionally stays
  ## storage-shaped and does not duplicate these values.
  let s = getSheet(f, sheet)
  for m in s.merges:
    var item = m
    if m.anchorCol > 0 and m.anchorRow > 0:
      let (hasAnchor, anchor) = findCell(s, m.anchorCol, m.anchorRow)
      if hasAnchor:
        item.value = cellDisplayValue(f, anchor)
    result.add item

proc isMerged*(f: XlsxFile, sheet, cellRef: string): bool =
  ## Whether a cell lies inside any declared merged range.
  let (col, row) = splitCellRef(cellRef)
  let (found, _) = mergeAt(getSheet(f, sheet), col, row)
  found

proc getCellValue*(f: XlsxFile, sheet, cellRef: string): string =
  ## Cell value with number formatting applied ("", when the cell is
  ## absent). Shared strings are resolved; `rawCellValue` opt returns
  ## stored values verbatim. Merge-covered cells return their anchor value.
  let (col, row) = splitCellRef(cellRef)
  let s = getSheet(f, sheet)
  let (covered, anchor) = mergedCell(s, col, row)
  if covered: return cellDisplayValue(f, anchor)
  let (found, c) = findCell(s, col, row)
  if not found: return ""
  cellDisplayValue(f, c)

proc getCellType*(f: XlsxFile, sheet, cellRef: string): CellType =
  ## Cell data type; `ctyUnset` when the cell is absent or untyped.
  ## Merge-covered cells return their anchor type.
  let (col, row) = splitCellRef(cellRef)
  let s = getSheet(f, sheet)
  let (covered, anchor) = mergedCell(s, col, row)
  if covered: return anchor.cellType
  let (found, c) = findCell(s, col, row)
  if not found: ctyUnset else: c.cellType

proc getCellFormula*(f: XlsxFile, sheet, cellRef: string): string =
  ## Formula text ("", when the cell has none). Merge-covered cells return
  ## their anchor formula.
  let (col, row) = splitCellRef(cellRef)
  let s = getSheet(f, sheet)
  let (covered, anchor) = mergedCell(s, col, row)
  if covered:
    return if anchor.hasFormula: anchor.formula.content else: ""
  let (found, c) = findCell(s, col, row)
  if not found or not c.hasFormula: "" else: c.formula.content
