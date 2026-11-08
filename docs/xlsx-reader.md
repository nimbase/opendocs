# XLSX Reader

Entry: `src/opendocs/xlsx.nim` includes `xlsx/types, base, cell, styles, numfmttok, numfmt, workbook, sharedstrings, sheet, richtext, reader`. Single canonical home `opendocs/xlsx`.

Supported: xlsx, xlsm, xltx, xltm, xlam. Phase A (lazy sheets, shared strings, raw values, A1 utils, open flow) done. Phase B (eager styles, builtin formats, dates, 576-cell excelize oracle parity) done. Phase C (rich text done, hyperlinks/merges/dimensions/docProps partial), Phase D OLE read-only guard, writer not yet.

```nim
import opendocs/xlsx

let f = openXlsx("book.xlsx")
echo getSheetList(f)       # ordered names
echo getSheetMap(f)        # id -> name
echo getRows(f, "Sheet1")  # seq[seq[string]] formatted
echo getCols(f, "Sheet1")
echo getCellValue(f, "Sheet1", "B2")
echo getCellFormula(f, "Sheet1", "B2")
closeXlsx(f)

let g = openXlsxBytes(bytes)
defer: closeXlsx(g)
```

## Open / close (`reader.nim`)

- `openXlsxBytes(data, opts): XlsxFile` — OLE guard (encrypted OLE rejected safely), `openZipBytes`, spill decision, `loadWorkbook + loadStyles`.
- `openXlsx(path, opts): XlsxFile`, `closeXlsx(f)` — nil/double-call safe.
- `XlsxReadOpts(spillThresholdBytes, spillCapBytes, spillDir, rawCellValue)`. Defaults `DefaultXlsxSpillThresholdBytes = 64MB`, `DefaultXlsxSpillCapBytes = 512MB`. `rawCellValue = true` returns raw instead of formatted.
- `XlsxError` (object of `CatchableError`). `XlsxMaxRows = 1048576`, `XlsxMaxCols = 16384`.
- `XlsxFileObj(archive: ZipArchive, spillDir, opts, sheetOrder, sheetParts, sheetIds, definedNames, sheets, sstLoaded, sharedStrings, sstNodes, themeLoaded, themeColors[10], date1904, styles)`, `XlsxFile = ref XlsxFileObj`.

## Cells (`cell.nim`, `types.nim`)

- `CellType(ctyUnset/ctyBool/ctyDate/ctyError/ctyFormula/ctyInlineString/ctyNumber/ctySharedString)`, `Cell(col, row, styleIdx, cellType, raw, hasFormula, formula: CellFormula(content, ftype, si, ref), inlineText, isNode)`.
- `cellTypeOf(t)`, `columnNameToNumber(name)` (`A->1 .. XFD->16384`), `columnNumberToName(num)`, `splitCellRef(ref): (col, row)` (`$`-tolerant), `joinCellName(col, row)`.

## Workbook / sheets (`workbook.nim`, `sheet.nim`, `sharedstrings.nim`)

- `getDefinedNames(f)`, `resolveSheetName(f, name)` (case-insensitive, raises `XlsxError`), `sheetPart(f, name)`.
- `XlsxSheet(name, sheetId, state, part, parsed, dimension, rows, merges, hyperlinks, cols, defaultColWidth, ...)`, `XlsxRow(r, cells, hidden, height)`.
- `getSheet(f, name): XlsxSheet` (cached parse), `findCell(s, col, row)`, `getSheetList(f)`, `getSheetMap(f)`, `getSheetDimension(f, sheet)`, `getRowHeight(f, sheet, row)` (`-1` absent), `getRowVisible`, `getColWidth` (`-1` absent), `getColVisible`.
- `sharedStrings(f): seq[string]` (lazy `xl/sharedStrings.xml`, caches `sstNodes`), `sharedString(f, idx)`.
- `resolveRaw(f, c)` (Phase A raw), `cellDisplayValue(f, c)` (formatted, honors `rawCellValue`), `formattedCellValue(f, rawV, effType, styleIdx)`, `formatInfo`.
- `getRows(f, sheet)`, `getCols(f, sheet)`, `getCellValue(f, sheet, ref)` (merge-aware, formatted), `getCellType`, `formatApplied`, `getCellStyleIdx`, `getCellStyle`, `getCellFormula`.
- Merges: `XlsxMerge(ref, firstRow/lastRow, firstCol/lastCol, anchorRow/Col, value)`, `getMergeCells(f, sheet)` (+ value from anchor), `isMerged(f, sheet, ref)`.
- Hyperlinks: `XlsxHyperlink(cell, target, location, display, tooltip)`, `getHyperlinks(f, sheet)`, `getCellHyperlink(f, sheet, ref)`.
- Defined names: `XlsxDefinedName(name, refersTo, scope, hidden, comment)`.
- Columns: `XlsxCol(min, max, width, hasWidth, hidden, bestFit, customWidth, outlineLevel, collapsed)`.
- Rich text: `XlsxRichRun(text, hasFont, font)`, `getCellRichText(f, sheet, ref)` — SST `si/r` + inline `is/r`, merge-anchor aware.

## Dates / formulas

- All cell kinds: numbers, text, shared strings, bools, errors, dates. Formatted values with builtin number formats + 1900/1904 systems. Formulas as cached values plus formula text. Sheet names, A1 refs, case-insensitive lookup. Large workbooks via spill-to-disk; encrypted files rejected safely.

See `examples/xlsx_read_example.nim`, `tests/t_xlsx.nim`, `t_xlsx_oracle.nim` + `xlsx_oracle.nim`.
