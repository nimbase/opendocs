## Copyright (c) 2026 nimbase (MIT, see LICENSE at repo root).
## Portions derived from excelize (https://github.com/qax-os/excelize,
## commit 0434413, 2026-09-18): Copyright (c) 2016-2026 The excelize
## Authors, Copyright (c) 2011-2017 Geoffrey J. Teale, BSD-3-Clause.
## SPDX-License-Identifier: MIT AND BSD-3-Clause
##
## Spreadsheet writer: owned builder model plus full package assembly.
##
## Behavioral oracle: excelize `cell.go` setters, `sheet.go` `NewFile` /
## `NewSheet`, `merge.go`, `col.go`, hyperlink rels, `templates.go`
## blank-part shapes. Clean-room: edge handling and oracle shapes
## observed, all bytes authored here.
##
## Coverage: W1 fresh build (all five cell types) plus W2 sheet extras
## (merges, column ranges, row geometry, hyperlinks with sheet `.rels`,
## defined names). Styles (W3) and open-edit (W4) remain future work:
## all cells still write style `0`, and `rawParts` carry-through is
## injection-tested only.
##
## Model mirrors `docx/writer`: `XlsxDoc` owns every modeled value,
## `buildPackage` regenerates modeled parts, `rawParts` re-emit
## byte-exact except where superseded (same name, or a per-part `.rels`
## for a regenerated part). Fresh builds carry no raw parts; open-edit
## (W4) populates them. A test-only injection path (`rawParts` is a
## public field) proves the carry-through without waiting for open-edit.
##
## Divergences from excelize, all documented and tested:
## - Duplicate sheet names fail loudly (`XlsxError`). excelize
##   `NewSheet` returns the existing index; a builder silently aliasing
##   two sheets would corrupt the cell map, so this is a deliberate
##   strictness.
## - `sst/count` is the total string-cell reference count (spec-correct).
##   excelize sets `count == uniqueCount` (both unique). The reader
##   ignores both attributes, so either opens everywhere.
## - Dates before the epoch (`serial <= 0`) fail loudly. excelize stores
##   them as RFC3339 strings; silent type-switching in a writer hides
##   caller bugs, so this fails instead (documented in `setCellDate`).
## - NaN/Inf floats store as shared strings ("NaN", "Inf", "-Inf"),
##   matching excelize `SetCellFloat` (which delegates to `SetCellStr`).
## - No theme part in W1. excelize ships a full `theme1.xml`; the reader
##   treats a missing theme as "no color" and every consumer opens
##   theme-less workbooks, so the part is omitted until styles (W3) need
##   real theme slots. Content types and rels are consistent with the
##   omission.
## - Zip entry timestamps come from `opendocs/zip` (`now().utc()`), so
##   two saves of the same model differ byte-wise. Round-trip tests
##   compare through the reader, never byte-wise (same as the docx
##   writer).
##
## Heuristics:
## - String cells truncate at 32767 UTF-16 code units (astral plane
##   counts 2), excelize `TotalCellChars` parity. Counting is by UTF-16
##   units, cutting only at rune boundaries.
## - `<t xml:space="preserve">` emits exactly when the value has
##   leading/trailing tab/LF/CR/space (excelize `trimCellValue` parity).
## - Spill is per part: parts larger than
##   `XlsxWriteOpts.spillThresholdBytes` stage through a temp file and
##   are mmap-read (`std/memfiles` + `buffalo/memView`) one at a time at
##   pack time, so peak memory is one large part, not all parts. Small
##   builds never touch disk.

type
  XlsxCellKind* = enum
    ## Stored cell kinds for the W1 builder (all five user-facing types).
    wckString
    wckNumber
    wckBool
    wckDate
    wckFormula

  XlsxWCell* = object
    ## One builder cell. `styleIdx` is reserved for W3 styles; W1 always
    ## writes 0 (the single default xf).
    case kind*: XlsxCellKind
    of wckString: strVal*: string
    of wckNumber: numRaw*: string ## preformatted (`$int` exact, floats 15-digit)
    of wckBool: boolVal*: bool
    of wckDate: dateSerial*: float
    of wckFormula:
      formula*: string
      cachedVal*: string ## "" = no `<v>` (recalc on load)
      cachedIsStr*: bool ## true -> `t="str"`, false -> numeric/no `t`

  XlsxWSheet* = object
    ## Builder sheet: name plus sparse cell map. Key packs a coordinate
    ## as `(row - 1) * XlsxMaxCols + (col - 1)` (fits int64, unique,
    ## sortable). W2 extras (merges, column ranges, row geometry,
    ## hyperlinks) reuse the reader model types so round-trips compare
    ## equal through the reader.
    name*: string
    sheetId*: int
    cells*: Table[int, XlsxWCell]
    merges*: seq[XlsxMerge]
    cols*: seq[XlsxCol]
    rowHeights*: Table[int, float] ## explicit height by 1-based row
    rowHidden*: Table[int, bool] ## explicit hidden rows
    hyperlinks*: seq[XlsxHyperlink]

  XlsxWriteOpts* = object
    ## Spill policy for large saves (mirrors `XlsxReadOpts` caps style).
    spillThresholdBytes*: int
    spillCapBytes*: int
    spillDir*: string ## parent for the spill dir ("" = system temp dir)

  XlsxDoc* = object
    ## Owned workbook model (DOCX `DocxDocument` analogue).
    sheets*: seq[XlsxWSheet]
    sheetIdx*: Table[string, int] ## lowercased name -> sheets index
    sst*: seq[string]
    sstIndex*: Table[string, int]
    sstTotal*: int ## total string-cell references (spec `count`)
    date1904*: bool
    coreProps*: XlsxDocProps
    appCompany*: string
    customProps*: Table[string, string]
    definedNames*: seq[XlsxDefinedName]
    rawParts*: Table[string, seq[byte]] ## unmodeled carry-through (W4)

const
  DefaultXlsxWriteSpillThresholdBytes* = 64 * 1024 * 1024
  DefaultXlsxWriteSpillCapBytes* = 512 * 1024 * 1024
  MaxSheetNameLen* = 31 ## UTF-16 code units, excelize parity
  MaxCellChars* = 32767 ## UTF-16 code units, excelize `TotalCellChars`

func defaultXlsxWriteOpts*(): XlsxWriteOpts =
  XlsxWriteOpts(spillThresholdBytes: DefaultXlsxWriteSpillThresholdBytes,
    spillCapBytes: DefaultXlsxWriteSpillCapBytes, spillDir: "")

# ------------------------------------------------------------ validation

func utf16Units(s: string): int =
  ## UTF-16 code-unit count (astral runes count 2). Invalid bytes count
  ## as single units rather than raising: the writer escapes, never
  ## rejects, cell text (refs and names are validated separately).
  var i = 0
  while i < s.len:
    let c = s[i].uint8
    var runeLen = 1
    var cp = c.int
    if (c and 0x80) == 0:
      runeLen = 1
    elif (c and 0xE0) == 0xC0:
      runeLen = 2
      cp = c.int and 0x1F
    elif (c and 0xF0) == 0xE0:
      runeLen = 3
      cp = c.int and 0x0F
    elif (c and 0xF8) == 0xF0:
      runeLen = 4
      cp = c.int and 0x07
    else:
      inc i
      inc result
      continue
    if i + runeLen > s.len:
      inc result
      break
    if runeLen > 1:
      for j in 1 ..< runeLen:
        cp = (cp shl 6) or (s[i + j].uint8.int and 0x3F)
    inc result, if cp > 0xFFFF: 2 else: 1
    i += runeLen

func truncateUtf16(s: string, maxUnits: int): string =
  ## Cut at a rune boundary so UTF-16 units stay within `maxUnits`.
  var units = 0
  var i = 0
  while i < s.len:
    let c = s[i].uint8
    var runeLen = 1
    var cp = c.int
    if (c and 0x80) == 0:
      runeLen = 1
    elif (c and 0xE0) == 0xC0:
      runeLen = 2
      cp = c.int and 0x1F
    elif (c and 0xF0) == 0xE0:
      runeLen = 3
      cp = c.int and 0x0F
    elif (c and 0xF8) == 0xF0:
      runeLen = 4
      cp = c.int and 0x07
    else:
      if units + 1 > maxUnits: break
      inc units
      inc i
      continue
    if i + runeLen > s.len: break
    if runeLen > 1:
      for j in 1 ..< runeLen:
        cp = (cp shl 6) or (s[i + j].uint8.int and 0x3F)
    let w = if cp > 0xFFFF: 2 else: 1
    if units + w > maxUnits: break
    units += w
    i += runeLen
  s[0 ..< i]

proc checkSheetName*(name: string) =
  ## excelize `checkSheetName` parity, minus the dup-exists path (dups
  ## fail in `addSheet`, documented above).
  if name == "":
    raise newException(XlsxError, "sheet name is blank")
  if utf16Units(name) > MaxSheetNameLen:
    raise newException(XlsxError,
      "sheet name exceeds 31 characters: " & name)
  if name.startsWith("'") or name.endsWith("'"):
    raise newException(XlsxError,
      "sheet name may not start or end with a single quote: " & name)
  for ch in [':', '\\', '/', '?', '*', '[', ']']:
    if ch in name:
      raise newException(XlsxError,
        "sheet name contains forbidden character '" & $ch & "': " & name)

func cellKey(col, row: int): int =
  (row - 1) * XlsxMaxCols + (col - 1)

func keyColRow(key: int): tuple[col, row: int] =
  ((key mod XlsxMaxCols) + 1, key div XlsxMaxCols + 1)

func excelFloatStr(v: float): string =
  ## Port of excelize `formatCellFloat(v, -1, 64)`: shortest `f` form,
  ## then 15-significant-digit truncation (zero-fill past the limit).
  if v.classify in {fcInf, fcNegInf, fcNan}: return $v
  var str = goFminus1(v)
  const maxPrec = 15
  let decimal = str.find('.')
  var significant = 0
  for idx in 0 ..< str.len:
    let ch = str[idx]
    if ch < '0' or ch > '9' or (significant == 0 and ch == '0'):
      continue
    inc significant
    if significant <= maxPrec: continue
    if decimal >= 0 and idx > decimal:
      result = str[0 ..< idx]
      if result.endsWith("."): result.setLen(result.len - 1)
      return
    var dec = decimal
    if dec < 0: dec = str.len
    var truncd = str[0 ..< dec]
    for _ in idx ..< truncd.len: truncd.add '0'
    return truncd
  str

func civilToSerial(y, mo, d, h, mi, s: int, fracSec: float,
    date1904: bool): float =
  ## Inverse of the reader's serial mapping (excelize `timeToExcelTime`
  ## parity): days since the epoch plus day fraction, with the Lotus
  ## 1900-02-29 quirk on the 1900 system only.
  let days = if date1904:
    (daysFromCivil(y, mo, d) - daysFromCivil(1904, 1, 1)).float
  else:
    (daysFromCivil(y, mo, d) - daysFromCivil(1899, 12, 31)).float
  result = days + (h.float * 3600.0 + mi.float * 60.0 + s.float) /
    86400.0 + fracSec / 86400.0
  if not date1904 and (y > 1900 or (y == 1900 and (mo > 2 or
      (mo == 2 and d > 28)))):
    result += 1.0

# ---------------------------------------------------------------- builder

proc newXlsxDoc*(date1904 = false): XlsxDoc =
  ## Fresh workbook with one sheet (`Sheet1`), empty SST, empty props.
  ## Deterministic: no timestamps are emitted unless the caller sets
  ## `coreProps.created/modified`.
  result = XlsxDoc(date1904: date1904,
    sheetIdx: initTable[string, int](),
    sstIndex: initTable[string, int](),
    customProps: initTable[string, string](),
    rawParts: initTable[string, seq[byte]]())
  result.sheets.add XlsxWSheet(name: "Sheet1", sheetId: 1,
    cells: initTable[int, XlsxWCell](),
    rowHeights: initTable[int, float](),
    rowHidden: initTable[int, bool]())
  result.sheetIdx["sheet1"] = 0

proc sheetIndex(doc: XlsxDoc, sheet: string): int =
  let key = sheet.toLowerAscii()
  if not doc.sheetIdx.hasKey(key):
    raise newException(XlsxError, "unknown sheet: " & sheet)
  doc.sheetIdx[key]

proc addSheet*(doc: var XlsxDoc, name: string) =
  ## Append a sheet. Blank/forbidden/overlong names and case-insensitive
  ## duplicates fail loudly with `XlsxError`.
  checkSheetName(name)
  if doc.sheetIdx.hasKey(name.toLowerAscii()):
    raise newException(XlsxError, "duplicate sheet name: " & name)
  var maxId = 0
  for s in doc.sheets:
    if s.sheetId > maxId: maxId = s.sheetId
  doc.sheets.add XlsxWSheet(name: name, sheetId: maxId + 1,
    cells: initTable[int, XlsxWCell](),
    rowHeights: initTable[int, float](),
    rowHidden: initTable[int, bool]())
  doc.sheetIdx[name.toLowerAscii()] = doc.sheets.high

proc internString(doc: var XlsxDoc, value: string): int =
  ## SST dedupe with `TotalCellChars` truncation. Returns the index.
  let v = truncateUtf16(value, MaxCellChars)
  if doc.sstIndex.hasKey(v): return doc.sstIndex[v]
  result = doc.sst.len
  doc.sst.add v
  doc.sstIndex[v] = result

proc putCell(doc: var XlsxDoc, sheet, cellRef: string, cell: XlsxWCell) =
  let idx = doc.sheetIndex(sheet)
  let (col, row) = splitCellRef(cellRef)
  doc.sheets[idx].cells[cellKey(col, row)] = cell

proc setCellStr*(doc: var XlsxDoc, sheet, cellRef, value: string) =
  ## Shared-string cell (SST-deduped, truncated at 32767 UTF-16 units).
  let t = truncateUtf16(value, MaxCellChars)
  discard doc.internString(t)
  inc doc.sstTotal
  doc.putCell(sheet, cellRef, XlsxWCell(kind: wckString, strVal: t))

proc setCellNum*(doc: var XlsxDoc, sheet, cellRef: string, value: float) =
  ## Numeric cell (15-significant-digit `formatCellFloat` form).
  ## Non-finite values store as shared strings in Go `fmt.Sprint` form
  ## ("Inf", "-Inf", "NaN"), excelize `SetCellFloat` parity (which
  ## delegates to `SetCellStr`; Nim `$` would render "inf"/"nan").
  if value.classify == fcInf:
    doc.setCellStr(sheet, cellRef, "Inf")
    return
  if value.classify == fcNegInf:
    doc.setCellStr(sheet, cellRef, "-Inf")
    return
  if value.classify == fcNan:
    doc.setCellStr(sheet, cellRef, "NaN")
    return
  doc.putCell(sheet, cellRef,
    XlsxWCell(kind: wckNumber, numRaw: excelFloatStr(value)))

proc setCellInt*(doc: var XlsxDoc, sheet, cellRef: string, value: int64) =
  ## Integer cell: exact decimal (excelize `SetCellInt` parity, no
  ## 15-digit truncation on the integer path).
  doc.putCell(sheet, cellRef,
    XlsxWCell(kind: wckNumber, numRaw: $value))

proc setCellBool*(doc: var XlsxDoc, sheet, cellRef: string, value: bool) =
  ## Boolean cell (`t="b"`, `1`/`0`).
  doc.putCell(sheet, cellRef, XlsxWCell(kind: wckBool, boolVal: value))

proc setCellDate*(doc: var XlsxDoc, sheet, cellRef: string,
    dt: DateTime) =
  ## Date cell: serial number in the workbook date system. Dates on or
  ## before the epoch (`serial <= 0`) fail loudly instead of silently
  ## degrading to strings (divergence from excelize, documented above).
  let frac = dt.nanosecond.float / 1e9
  let serial = civilToSerial(dt.year, dt.month.ord, dt.monthday,
    dt.hour, dt.minute, dt.second, frac, doc.date1904)
  if serial <= 0.0:
    raise newException(XlsxError,
      "date precedes the workbook epoch: " & $dt)
  doc.putCell(sheet, cellRef, XlsxWCell(kind: wckDate,
    dateSerial: serial))

proc setCellFormula*(doc: var XlsxDoc, sheet, cellRef, formula: string) =
  ## Formula cell without a cached value (recalc on load). Empty
  ## formulas fail loudly; the leading `=` is never stored (callers
  ## pass `SUM(A1:A2)`, not `=SUM(A1:A2)`).
  if formula == "":
    raise newException(XlsxError, "formula is empty")
  if formula.startsWith("="):
    raise newException(XlsxError,
      "formula must not start with '=': " & formula)
  doc.putCell(sheet, cellRef, XlsxWCell(kind: wckFormula,
    formula: formula, cachedVal: "", cachedIsStr: false))

proc setCellFormulaValue*(doc: var XlsxDoc, sheet, cellRef,
    formula: string, cached: float) =
  ## Formula with a numeric cached value (`<v>`, no `t`).
  if formula == "":
    raise newException(XlsxError, "formula is empty")
  if formula.startsWith("="):
    raise newException(XlsxError,
      "formula must not start with '=': " & formula)
  if cached.classify in {fcNan, fcInf, fcNegInf}:
    raise newException(XlsxError, "formula cached value is non-finite")
  doc.putCell(sheet, cellRef, XlsxWCell(kind: wckFormula,
    formula: formula, cachedVal: excelFloatStr(cached),
    cachedIsStr: false))

proc setCellFormulaStr*(doc: var XlsxDoc, sheet, cellRef, formula,
    cached: string) =
  ## Formula with a string cached value (`t="str"`).
  if formula == "":
    raise newException(XlsxError, "formula is empty")
  if formula.startsWith("="):
    raise newException(XlsxError,
      "formula must not start with '=': " & formula)
  doc.putCell(sheet, cellRef, XlsxWCell(kind: wckFormula,
    formula: formula,
    cachedVal: truncateUtf16(cached, MaxCellChars), cachedIsStr: true))

# ------------------------------------------------------- W2: sheet extras

proc addMerge*(doc: var XlsxDoc, sheet, mergeRef: string) =
  ## Declare a merged range (`A1:B2`, absolutes and reversed corners
  ## accepted, same normalization as the reader). Invalid refs and
  ## ranges overlapping an earlier merge fail loudly with `XlsxError`
  ## (the reader tolerates overlaps file-order-first; the builder
  ## refuses to author ambiguity).
  let (firstCol, firstRow, lastCol, lastRow) =
    parseMergeBounds(mergeRef, "addMerge")
  let idx = doc.sheetIndex(sheet)
  for m in doc.sheets[idx].merges:
    if firstCol <= m.lastCol and lastCol >= m.firstCol and
        firstRow <= m.lastRow and lastRow >= m.firstRow:
      raise newException(XlsxError,
        "overlapping merge range: " & mergeRef)
  doc.sheets[idx].merges.add XlsxMerge(`ref`: mergeRef,
    firstRow: firstRow, lastRow: lastRow, firstCol: firstCol,
    lastCol: lastCol)

proc setColWidth*(doc: var XlsxDoc, sheet: string, minCol, maxCol: int,
    width: float) =
  ## Explicit column width over an inclusive range. Appended in call
  ## order; overlapping ranges read back last-wins (reader parity).
  ## Non-positive widths fail loudly (hide via `setColHidden`).
  if minCol < 1 or maxCol < 1 or minCol > XlsxMaxCols or
      maxCol > XlsxMaxCols or minCol > maxCol:
    raise newException(XlsxError,
      "column range out of range: " & $minCol & "-" & $maxCol)
  if width <= 0.0:
    raise newException(XlsxError,
      "column width must be positive: " & $width)
  let idx = doc.sheetIndex(sheet)
  doc.sheets[idx].cols.add XlsxCol(min: minCol, max: maxCol,
    width: width, hasWidth: true)

proc setColHidden*(doc: var XlsxDoc, sheet: string, minCol, maxCol: int,
    hidden = true) =
  ## Hidden flag over an inclusive column range (appended, last-wins).
  if minCol < 1 or maxCol < 1 or minCol > XlsxMaxCols or
      maxCol > XlsxMaxCols or minCol > maxCol:
    raise newException(XlsxError,
      "column range out of range: " & $minCol & "-" & $maxCol)
  let idx = doc.sheetIndex(sheet)
  doc.sheets[idx].cols.add XlsxCol(min: minCol, max: maxCol, hidden: hidden)

proc setRowHeight*(doc: var XlsxDoc, sheet: string, row: int,
    height: float) =
  ## Explicit row height. Non-positive heights fail loudly.
  if row < 1 or row > XlsxMaxRows:
    raise newException(XlsxError, "row out of range: " & $row)
  if height <= 0.0:
    raise newException(XlsxError,
      "row height must be positive: " & $height)
  let idx = doc.sheetIndex(sheet)
  doc.sheets[idx].rowHeights[row] = height

proc setRowHidden*(doc: var XlsxDoc, sheet: string, row: int,
    hidden = true) =
  ## Hidden flag for one row.
  if row < 1 or row > XlsxMaxRows:
    raise newException(XlsxError, "row out of range: " & $row)
  let idx = doc.sheetIndex(sheet)
  doc.sheets[idx].rowHidden[row] = hidden

proc addHyperlink*(doc: var XlsxDoc, sheet, cellRef, target: string,
    location = "", display = "", tooltip = "") =
  ## Hyperlink over a cell or range (`parseMergeBounds` validation, so
  ## ranges accepted). External links (`target`) serialize through the
  ## sheet's `.rels` (`TargetMode="External"`, `rIdH1...` minting);
  ## internal jumps (`location`, no `target`) inline the destination.
  ## Both empty fails loudly; unknown sheets fail loudly. A dangling
  ## `r:id` is never authored (the reader tolerates them, the builder
  ## refuses to).
  discard parseMergeBounds(cellRef, "addHyperlink")
  if target == "" and location == "":
    raise newException(XlsxError,
      "hyperlink needs a target or location: " & cellRef)
  let idx = doc.sheetIndex(sheet)
  doc.sheets[idx].hyperlinks.add XlsxHyperlink(cell: cellRef,
    target: target, location: location, display: display,
    tooltip: tooltip)

proc addDefinedName*(doc: var XlsxDoc, name, refersTo: string,
    scope = "Workbook", hidden = false, comment = "") =
  ## Workbook defined name. Empty/overlong names, names that parse as a
  ## cell reference, and unknown scopes fail loudly. One leading `=` on
  ## `refersTo` is stripped (the same normalization the reader applies);
  ## an empty remainder fails loudly.
  if name == "":
    raise newException(XlsxError, "defined name is blank")
  if utf16Units(name) > 255:
    raise newException(XlsxError,
      "defined name exceeds 255 characters: " & name)
  var isCellRef = true
  try:
    discard splitCellRef(name)
  except XlsxError:
    isCellRef = false
  if isCellRef:
    raise newException(XlsxError,
      "defined name must not be a cell reference: " & name)
  var canonScope = scope
  if scope != "Workbook":
    # Canonical sheet name (case-insensitive, reader parity).
    var found = ""
    for s in doc.sheets:
      if s.name.cmpIgnoreCase(scope) == 0:
        found = s.name
        break
    if found == "":
      raise newException(XlsxError, "unknown sheet: " & scope)
    canonScope = found
  var target = refersTo
  if target.startsWith("="): target = target[1 .. ^1]
  if target == "":
    raise newException(XlsxError, "defined name target is empty")
  doc.definedNames.add XlsxDefinedName(name: name, refersTo: target,
    scope: canonScope, hidden: hidden, comment: comment)

# ------------------------------------------------------------- serialization

proc sheetBounds(s: XlsxWSheet): tuple[found: bool, minCol, minRow,
    maxCol, maxRow: int] =
  var first = true
  for key in s.cells.keys:
    let (col, row) = keyColRow(key)
    if first:
      result = (true, col, row, col, row)
      first = false
    else:
      result.minCol = min(result.minCol, col)
      result.minRow = min(result.minRow, row)
      result.maxCol = max(result.maxCol, col)
      result.maxRow = max(result.maxRow, row)
  for m in s.merges: # a merge range counts as used even when empty
    for (col, row) in [(m.firstCol, m.firstRow), (m.lastCol, m.lastRow)]:
      if first:
        result = (true, col, row, col, row)
        first = false
      else:
        result.minCol = min(result.minCol, col)
        result.minRow = min(result.minRow, row)
        result.maxCol = max(result.maxCol, col)
        result.maxRow = max(result.maxRow, row)

proc writeCell(e: var XlsxEmit, doc: var XlsxDoc, col, row: int,
    cell: XlsxWCell) =
  let r = joinCellName(col, row)
  case cell.kind
  of wckString:
    let idx = doc.internString(cell.strVal)
    e.openTag("c", xlsxAttr("r", r) & xlsxAttr("t", "s"))
    e.elemNode("v", $idx)
    e.closeTag("c")
  of wckNumber:
    e.openTag("c", xlsxAttr("r", r))
    e.elemNode("v", cell.numRaw)
    e.closeTag("c")
  of wckBool:
    e.openTag("c", xlsxAttr("r", r) & xlsxAttr("t", "b"))
    e.elemNode("v", if cell.boolVal: "1" else: "0")
    e.closeTag("c")
  of wckDate:
    e.openTag("c", xlsxAttr("r", r))
    e.elemNode("v", excelFloatStr(cell.dateSerial))
    e.closeTag("c")
  of wckFormula:
    if cell.cachedIsStr:
      e.openTag("c", xlsxAttr("r", r) & xlsxAttr("t", "str"))
    else:
      e.openTag("c", xlsxAttr("r", r))
    e.elemNode("f", cell.formula)
    if cell.cachedVal != "" or cell.cachedIsStr:
      e.elemNode("v", cell.cachedVal)
    e.closeTag("c")

proc writeSheetXml(e: var XlsxEmit, doc: var XlsxDoc, si: int) =
  let s = doc.sheets[si]
  e.decl()
  e.openTag("worksheet",
    xlsxAttr("xmlns",
      "http://schemas.openxmlformats.org/spreadsheetml/2006/main") &
    xlsxAttr("xmlns:r",
      "http://schemas.openxmlformats.org/officeDocument/2006/relationships"))
  let b = sheetBounds(s)
  if b.found:
    e.emptyTag("dimension", xlsxAttr("ref",
      joinCellName(b.minCol, b.minRow) & ":" &
      joinCellName(b.maxCol, b.maxRow)))
  else:
    e.emptyTag("dimension", xlsxAttr("ref", "A1"))
  e.openTag("sheetViews")
  e.emptyTag("sheetView",
    xlsxAttr("tabSelected", if si == 0: "1" else: "0") &
    xlsxAttr("workbookViewId", "0"))
  e.closeTag("sheetViews")
  e.emptyTag("sheetFormatPr", xlsxAttr("defaultRowHeight", "15"))
  if s.cols.len > 0:
    e.openTag("cols")
    for c in s.cols:
      var attrs = xlsxAttr("min", $c.min) & xlsxAttr("max", $c.max)
      if c.hasWidth: attrs.add xlsxAttr("width", $c.width)
      if c.hidden: attrs.add xlsxAttr("hidden", "1")
      if c.bestFit: attrs.add xlsxAttr("bestFit", "1")
      if c.customWidth: attrs.add xlsxAttr("customWidth", "1")
      e.emptyTag("col", attrs)
    e.closeTag("cols")
  e.openTag("sheetData")
  var rowSet = initTable[int, bool]()
  for k in s.cells.keys:
    rowSet[keyColRow(k)[1]] = true
  for r in s.rowHeights.keys: rowSet[r] = true
  for r in s.rowHidden.keys: rowSet[r] = true
  var rows: seq[int] = @[]
  for r in rowSet.keys: rows.add r
  rows.sort()
  for row in rows:
    var attrs = xlsxAttr("r", $row)
    if s.rowHidden.getOrDefault(row, false):
      attrs.add xlsxAttr("hidden", "1")
    if s.rowHeights.hasKey(row):
      attrs.add xlsxAttr("ht", $s.rowHeights[row])
    e.openTag("row", attrs)
    var cellKeys: seq[int] = @[]
    for k in s.cells.keys:
      if keyColRow(k)[1] == row: cellKeys.add k
    cellKeys.sort()
    for key in cellKeys:
      let (col, _) = keyColRow(key)
      e.writeCell(doc, col, row, s.cells[key])
    e.closeTag("row")
  e.closeTag("sheetData")
  if s.merges.len > 0:
    e.openTag("mergeCells", xlsxAttr("count", $s.merges.len))
    for m in s.merges:
      e.emptyTag("mergeCell", xlsxAttr("ref", m.`ref`))
    e.closeTag("mergeCells")
  if s.hyperlinks.len > 0:
    # External links mint `rIdH1...` in first-seen order (same order
    # as the sheet `.rels` writer below, so ids agree).
    var hid = 0
    e.openTag("hyperlinks")
    for h in s.hyperlinks:
      var attrs = xlsxAttr("ref", h.cell)
      if h.display != "": attrs.add xlsxAttr("display", h.display)
      if h.tooltip != "": attrs.add xlsxAttr("tooltip", h.tooltip)
      if h.target != "":
        inc hid
        attrs.add xlsxAttr("r:id", "rIdH" & $hid)
      if h.location != "": attrs.add xlsxAttr("location", h.location)
      e.emptyTag("hyperlink", attrs)
    e.closeTag("hyperlinks")
  e.closeTag("worksheet")

proc writeSheetRelsXml(e: var XlsxEmit, s: XlsxWSheet): bool =
  ## Sheet `.rels` for external hyperlinks. Returns false (no part)
  ## when the sheet carries none.
  var ext: seq[XlsxHyperlink] = @[]
  for h in s.hyperlinks:
    if h.target != "": ext.add h
  if ext.len == 0: return false
  e.decl()
  e.openTag("Relationships",
    xlsxAttr("xmlns",
      "http://schemas.openxmlformats.org/package/2006/relationships"))
  const relNs =
    "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
  for i, h in ext:
    e.emptyTag("Relationship",
      xlsxAttr("Id", "rIdH" & $(i + 1)) &
      xlsxAttr("Type", relNs & "/hyperlink") &
      xlsxAttr("Target", h.target) &
      xlsxAttr("TargetMode", "External"))
  e.closeTag("Relationships")
  true

proc writeSharedStringsXml(e: var XlsxEmit, doc: XlsxDoc) =
  e.decl()
  e.openTag("sst",
    xlsxAttr("xmlns",
      "http://schemas.openxmlformats.org/spreadsheetml/2006/main") &
    xlsxAttr("count", $doc.sstTotal) &
    xlsxAttr("uniqueCount", $doc.sst.len))
  for s in doc.sst:
    e.openTag("si")
    if needsPreserve(s):
      e.openTag("t", xlsxAttr("xml:space", "preserve"))
    else:
      e.openTag("t")
    e.textNode(s)
    e.closeTag("t")
    e.closeTag("si")
  e.closeTag("sst")

proc writeStylesXml(e: var XlsxEmit) =
  ## Minimal stylesheet: one font/fill/border/xf (the W1 default). Own
  ## attribute order, same semantics as the excelize blank template.
  e.decl()
  e.openTag("styleSheet",
    xlsxAttr("xmlns",
      "http://schemas.openxmlformats.org/spreadsheetml/2006/main"))
  e.openTag("fonts", xlsxAttr("count", "1"))
  e.openTag("font")
  e.emptyTag("sz", xlsxAttr("val", "11"))
  e.emptyTag("color", xlsxAttr("theme", "1"))
  e.emptyTag("name", xlsxAttr("val", "Calibri"))
  e.emptyTag("family", xlsxAttr("val", "2"))
  e.closeTag("font")
  e.closeTag("fonts")
  e.openTag("fills", xlsxAttr("count", "2"))
  e.openTag("fill")
  e.emptyTag("patternFill", xlsxAttr("patternType", "none"))
  e.closeTag("fill")
  e.openTag("fill")
  e.emptyTag("patternFill", xlsxAttr("patternType", "gray125"))
  e.closeTag("fill")
  e.closeTag("fills")
  e.openTag("borders", xlsxAttr("count", "1"))
  e.openTag("border")
  e.emptyTag("left")
  e.emptyTag("right")
  e.emptyTag("top")
  e.emptyTag("bottom")
  e.emptyTag("diagonal")
  e.closeTag("border")
  e.closeTag("borders")
  e.openTag("cellStyleXfs", xlsxAttr("count", "1"))
  e.emptyTag("xf",
    xlsxAttr("numFmtId", "0") & xlsxAttr("fontId", "0") &
    xlsxAttr("fillId", "0") & xlsxAttr("borderId", "0"))
  e.closeTag("cellStyleXfs")
  e.openTag("cellXfs", xlsxAttr("count", "1"))
  e.emptyTag("xf",
    xlsxAttr("numFmtId", "0") & xlsxAttr("fontId", "0") &
    xlsxAttr("fillId", "0") & xlsxAttr("borderId", "0") &
    xlsxAttr("xfId", "0"))
  e.closeTag("cellXfs")
  e.openTag("cellStyles", xlsxAttr("count", "1"))
  e.emptyTag("cellStyle",
    xlsxAttr("name", "Normal") & xlsxAttr("xfId", "0") &
    xlsxAttr("builtinId", "0"))
  e.closeTag("cellStyles")
  e.closeTag("styleSheet")

proc writeWorkbookXml(e: var XlsxEmit, doc: XlsxDoc) =
  e.decl()
  e.openTag("workbook",
    xlsxAttr("xmlns",
      "http://schemas.openxmlformats.org/spreadsheetml/2006/main") &
    xlsxAttr("xmlns:r",
      "http://schemas.openxmlformats.org/officeDocument/2006/relationships"))
  e.emptyTag("fileVersion",
    xlsxAttr("appName", "xl") & xlsxAttr("lastEdited", "6") &
    xlsxAttr("lowestEdited", "6") & xlsxAttr("rupBuild", "14420"))
  if doc.date1904:
    e.emptyTag("workbookPr", xlsxAttr("date1904", "1"))
  else:
    e.emptyTag("workbookPr")
  e.openTag("bookViews")
  e.emptyTag("workbookView",
    xlsxAttr("xWindow", "0") & xlsxAttr("yWindow", "0") &
    xlsxAttr("windowWidth", "14805") & xlsxAttr("windowHeight", "8010"))
  e.closeTag("bookViews")
  e.openTag("sheets")
  for i, s in doc.sheets:
    e.emptyTag("sheet",
      xlsxAttr("name", s.name) & xlsxAttr("sheetId", $s.sheetId) &
      xlsxAttr("r:id", "rId" & $(i + 1)))
  e.closeTag("sheets")
  if doc.definedNames.len > 0:
    e.openTag("definedNames")
    for dn in doc.definedNames:
      var attrs = xlsxAttr("name", dn.name)
      if dn.scope != "Workbook":
        # 0-based index into workbook order (reader parity).
        var localId = -1
        for i, s in doc.sheets:
          if s.name == dn.scope:
            localId = i
            break
        attrs.add xlsxAttr("localSheetId", $localId)
      if dn.hidden: attrs.add xlsxAttr("hidden", "1")
      if dn.comment != "": attrs.add xlsxAttr("comment", dn.comment)
      e.elemNode("definedName", dn.refersTo, attrs)
    e.closeTag("definedNames")
  e.emptyTag("calcPr", xlsxAttr("calcId", "122211"))
  e.closeTag("workbook")

proc writeWorkbookRels(e: var XlsxEmit, doc: XlsxDoc) =
  e.decl()
  e.openTag("Relationships",
    xlsxAttr("xmlns",
      "http://schemas.openxmlformats.org/package/2006/relationships"))
  const relNs =
    "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
  for i, s in doc.sheets:
    e.emptyTag("Relationship",
      xlsxAttr("Id", "rId" & $(i + 1)) &
      xlsxAttr("Type", relNs & "/worksheet") &
      xlsxAttr("Target", "worksheets/sheet" & $s.sheetId & ".xml"))
  let styleId = doc.sheets.len + 1
  e.emptyTag("Relationship",
    xlsxAttr("Id", "rId" & $styleId) &
    xlsxAttr("Type", relNs & "/styles") &
    xlsxAttr("Target", "styles.xml"))
  if doc.sst.len > 0:
    e.emptyTag("Relationship",
      xlsxAttr("Id", "rId" & $(styleId + 1)) &
      xlsxAttr("Type", relNs & "/sharedStrings") &
      xlsxAttr("Target", "sharedStrings.xml"))
  e.closeTag("Relationships")

proc writeRootRels(e: var XlsxEmit) =
  e.decl()
  e.openTag("Relationships",
    xlsxAttr("xmlns",
      "http://schemas.openxmlformats.org/package/2006/relationships"))
  const pkgNs =
    "http://schemas.openxmlformats.org/package/2006/relationships"
  const docNs =
    "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
  e.emptyTag("Relationship",
    xlsxAttr("Id", "rId1") &
    xlsxAttr("Type", docNs & "/officeDocument") &
    xlsxAttr("Target", "xl/workbook.xml"))
  e.emptyTag("Relationship",
    xlsxAttr("Id", "rId2") &
    xlsxAttr("Type", pkgNs & "/metadata/core-properties") &
    xlsxAttr("Target", "docProps/core.xml"))
  e.emptyTag("Relationship",
    xlsxAttr("Id", "rId3") &
    xlsxAttr("Type", docNs & "/extended-properties") &
    xlsxAttr("Target", "docProps/app.xml"))
  e.closeTag("Relationships")

proc writeContentTypes(e: var XlsxEmit, doc: XlsxDoc) =
  e.decl()
  e.openTag("Types",
    xlsxAttr("xmlns",
      "http://schemas.openxmlformats.org/package/2006/content-types"))
  e.emptyTag("Default",
    xlsxAttr("Extension", "rels") &
    xlsxAttr("ContentType",
      "http://schemas.openxmlformats.org/package/2006/relationships"))
  e.emptyTag("Default",
    xlsxAttr("Extension", "xml") &
    xlsxAttr("ContentType", "application/xml"))
  e.emptyTag("Override",
    xlsxAttr("PartName", "/xl/workbook.xml") &
    xlsxAttr("ContentType",
      "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"))
  for s in doc.sheets:
    e.emptyTag("Override",
      xlsxAttr("PartName", "/xl/worksheets/sheet" & $s.sheetId & ".xml") &
      xlsxAttr("ContentType",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"))
  e.emptyTag("Override",
    xlsxAttr("PartName", "/xl/styles.xml") &
    xlsxAttr("ContentType",
      "application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"))
  if doc.sst.len > 0:
    e.emptyTag("Override",
      xlsxAttr("PartName", "/xl/sharedStrings.xml") &
      xlsxAttr("ContentType",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"))
  e.emptyTag("Override",
    xlsxAttr("PartName", "/docProps/core.xml") &
    xlsxAttr("ContentType",
      "application/vnd.openxmlformats-package.core-properties+xml"))
  e.emptyTag("Override",
    xlsxAttr("PartName", "/docProps/app.xml") &
    xlsxAttr("ContentType",
      "application/vnd.openxmlformats-officedocument.extended-properties+xml"))
  if doc.customProps.len > 0:
    e.emptyTag("Override",
      xlsxAttr("PartName", "/docProps/custom.xml") &
      xlsxAttr("ContentType",
        "application/vnd.openxmlformats-officedocument.custom-properties+xml"))
  for name in doc.rawParts.keys:
    if name == "[Content_Types].xml" or name == "_rels/.rels": continue
    if name.endsWith(".rels"): continue
    if name == "xl/workbook.xml" or name == "xl/styles.xml" or
        name == "xl/sharedStrings.xml" or name == "docProps/core.xml" or
        name == "docProps/app.xml" or name == "docProps/custom.xml":
      continue
    if name.startsWith("xl/worksheets/sheet"):
      var modeled = false
      for s in doc.sheets:
        if name == "xl/worksheets/sheet" & $s.sheetId & ".xml":
          modeled = true
          break
      if modeled: continue
    let dot = name.rfind('.')
    let ext = if dot >= 0: name[dot + 1 .. ^1].toLowerAscii() else: ""
    if ext == "xml":
      e.emptyTag("Override",
        xlsxAttr("PartName", "/" & name) &
        xlsxAttr("ContentType", "application/xml"))
    else:
      e.emptyTag("Override",
        xlsxAttr("PartName", "/" & name) &
        xlsxAttr("ContentType", "application/octet-stream"))
  e.closeTag("Types")

proc writeCoreXml(e: var XlsxEmit, doc: XlsxDoc) =
  e.decl()
  e.openTag("cp:coreProperties",
    xlsxAttr("xmlns:cp",
      "http://schemas.openxmlformats.org/package/2006/metadata/core-properties") &
    xlsxAttr("xmlns:dc", "http://purl.org/dc/elements/1.1/") &
    xlsxAttr("xmlns:dcterms", "http://purl.org/dc/terms/") &
    xlsxAttr("xmlns:xsi",
      "http://www.w3.org/2001/XMLSchema-instance"))
  let p = doc.coreProps
  if p.creator != "": e.elemNode("dc:creator", p.creator)
  if p.title != "": e.elemNode("dc:title", p.title)
  if p.subject != "": e.elemNode("dc:subject", p.subject)
  if p.keywords != "": e.elemNode("cp:keywords", p.keywords)
  if p.description != "": e.elemNode("dc:description", p.description)
  if p.category != "": e.elemNode("cp:category", p.category)
  if p.contentStatus != "": e.elemNode("cp:contentStatus", p.contentStatus)
  if p.lastModifiedBy != "":
    e.elemNode("cp:lastModifiedBy", p.lastModifiedBy)
  if p.identifier != "": e.elemNode("dc:identifier", p.identifier)
  if p.language != "": e.elemNode("dc:language", p.language)
  if p.version != "": e.elemNode("cp:version", p.version)
  if p.revision != "": e.elemNode("cp:revision", p.revision)
  if p.created != "":
    e.elemNode("dcterms:created", p.created,
      xlsxAttr("xsi:type", "dcterms:W3CDTF"))
  if p.modified != "":
    e.elemNode("dcterms:modified", p.modified,
      xlsxAttr("xsi:type", "dcterms:W3CDTF"))
  e.closeTag("cp:coreProperties")

proc writeAppXml(e: var XlsxEmit, doc: XlsxDoc) =
  e.decl()
  e.openTag("Properties",
    xlsxAttr("xmlns",
      "http://schemas.openxmlformats.org/officeDocument/2006/extended-properties") &
    xlsxAttr("xmlns:vt",
      "http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"))
  e.elemNode("Application", "opendocs")
  if doc.appCompany != "": e.elemNode("Company", doc.appCompany)
  e.closeTag("Properties")

proc writeCustomXml(e: var XlsxEmit, doc: XlsxDoc) =
  e.decl()
  e.openTag("Properties",
    xlsxAttr("xmlns",
      "http://schemas.openxmlformats.org/officeDocument/2006/custom-properties") &
    xlsxAttr("xmlns:vt",
      "http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"))
  var pid = 2
  var names: seq[string] = @[]
  for k in doc.customProps.keys: names.add k
  names.sort()
  for name in names:
    e.openTag("property",
      xlsxAttr("fmtid", "{D5CDD505-2E9C-101B-9397-08002B2CF9AE}") &
      xlsxAttr("pid", $pid) & xlsxAttr("name", name))
    e.elemNode("vt:lpwstr", doc.customProps[name])
    e.closeTag("property")
    inc pid
  e.closeTag("Properties")

# ------------------------------------------------------------- packaging

proc buildParts(doc: var XlsxDoc, e: var XlsxEmit):
    seq[tuple[name: string, data: seq[byte]]] =
  ## Render every modeled part through the shared buffalo emitter
  ## (`clear` per part, backing reused). Caller packs or spills.
  e.writeContentTypes(doc)
  result.add ("[Content_Types].xml", e.toBytes())
  e.clear()
  e.writeRootRels()
  result.add ("_rels/.rels", e.toBytes())
  e.clear()
  e.writeWorkbookXml(doc)
  result.add ("xl/workbook.xml", e.toBytes())
  e.clear()
  e.writeWorkbookRels(doc)
  result.add ("xl/_rels/workbook.xml.rels", e.toBytes())
  e.clear()
  e.writeStylesXml()
  result.add ("xl/styles.xml", e.toBytes())
  e.clear()
  if doc.sst.len > 0:
    e.writeSharedStringsXml(doc)
    result.add ("xl/sharedStrings.xml", e.toBytes())
    e.clear()
  for si in 0 ..< doc.sheets.len:
    e.writeSheetXml(doc, si)
    result.add ("xl/worksheets/sheet" & $doc.sheets[si].sheetId & ".xml",
      e.toBytes())
    e.clear()
    if e.writeSheetRelsXml(doc.sheets[si]):
      result.add (sheetRelsPath(
        "xl/worksheets/sheet" & $doc.sheets[si].sheetId & ".xml"),
        e.toBytes())
      e.clear()
  e.writeCoreXml(doc)
  result.add ("docProps/core.xml", e.toBytes())
  e.clear()
  e.writeAppXml(doc)
  result.add ("docProps/app.xml", e.toBytes())
  e.clear()
  if doc.customProps.len > 0:
    e.writeCustomXml(doc)
    result.add ("docProps/custom.xml", e.toBytes())
    e.clear()

proc saveXlsxBytes*(doc: var XlsxDoc,
    opts = defaultXlsxWriteOpts()): seq[byte] =
  ## Serialize the workbook to a complete `.xlsx` package in memory.
  ## Parts larger than the spill threshold stage through a temp dir and
  ## are mmap-read (`std/memfiles` + `buffalo/memView`) one at a time at
  ## pack time, so peak memory is one large part, not all parts.
  var e = initXlsxEmit()
  let parts = buildParts(doc, e)
  var spillDir = ""
  var spilled: seq[tuple[name: string, path: string]] = @[]
  var live: seq[tuple[name: string, data: seq[byte]]] = @[]
  var spilledBytes = 0
  try:
    for (name, data) in parts:
      if opts.spillThresholdBytes > 0 and
          data.len > opts.spillThresholdBytes:
        if spillDir == "":
          let base = if opts.spillDir == "": getTempDir()
            else: opts.spillDir
          try:
            spillDir = createTempDir("opendocs_", "_xlsxwrite", base)
          except OSError as err:
            raise newException(XlsxError,
              "cannot create spill dir: " & err.msg)
        let cap = if opts.spillCapBytes > 0: opts.spillCapBytes
          else: DefaultXlsxWriteSpillCapBytes
        if spilledBytes + data.len > cap:
          raise newException(XlsxError,
            "write spill cap exceeded by: " & name)
        let path = spillDir / name.replace("/", "__") & ".part"
        try:
          var sf: File
          if not open(sf, path, fmWrite):
            raise newException(XlsxError, "cannot spill " & name)
          try:
            if data.len > 0 and writeBytes(sf, data, 0, data.len) != data.len:
              raise newException(XlsxError, "short spill write: " & name)
          finally:
            close(sf)
        except IOError as err:
          raise newException(XlsxError,
            "cannot spill " & name & ": " & err.msg)
        spilled.add (name, path)
        spilledBytes += data.len
      else:
        live.add (name, data)
    # Pack: live parts straight in; spilled parts mmap-read one at a
    # time (zero-copy view -> single owned copy for the zip input).
    var w = newZipWriter()
    var emitted: seq[string] = @[]
    for (name, data) in live:
      w.addFile(name, data)
      emitted.add name
    for (name, path) in spilled:
      var mf: MemFile
      try:
        mf = memfiles.open(path, fmRead)
      except OSError as err:
        raise newException(XlsxError,
          "cannot map spilled part " & name & ": " & err.msg)
      try:
        if mf.size == 0:
          w.addFile(name, newSeq[byte](0))
        else:
          # Zero-copy view over the mapping; the single copy below
          # feeds the zip input (flate takes `openArray`, the store
          # keeps the owned seq).
          var data = newSeq[byte](mf.size)
          copyMem(addr data[0], unsafeAddr memView(mf)[0], mf.size)
          w.addFile(name, data)
      finally:
        memfiles.close(mf)
      emitted.add name
    for name, data in doc.rawParts:
      if name in emitted: continue
      if name == "_rels/.rels": continue
      if name == "[Content_Types].xml": continue
      var superseded = false
      for ename in emitted:
        if name == ename & ".rels":
          superseded = true
          break
      if superseded: continue
      if name.endsWith(".rels"):
        let base = name[0 ..< name.len - 5]
        if base in emitted: continue
        # Sheet `.rels` live under `_rels/` next to the sheet, not at
        # `sheet.xml.rels`: drop stale ones for regenerated sheets so a
        # carried hyperlink map can never dangle.
        if name.startsWith("xl/worksheets/_rels/") and
            name.endsWith(".xml.rels"):
          let leaf = name["xl/worksheets/_rels/".len ..< name.len - 5]
          if "xl/worksheets/" & leaf in emitted: continue
      w.addFile(name, data)
    try:
      result = w.toBytes()
    except ZipError as err:
      raise newException(XlsxError, "cannot pack xlsx: " & err.msg)
  finally:
    if spillDir != "":
      try: removeDir(spillDir)
      except OSError: discard

proc saveXlsx*(doc: var XlsxDoc, path: string,
    opts = defaultXlsxWriteOpts()) =
  ## Serialize the workbook to a `.xlsx` file on disk.
  let img = saveXlsxBytes(doc, opts)
  var f: File
  if not open(f, path, fmWrite):
    raise newException(XlsxError, "cannot write file: " & path)
  defer: close(f)
  if img.len > 0 and writeBytes(f, img, 0, img.len) != img.len:
    raise newException(XlsxError, "short write: " & path)
