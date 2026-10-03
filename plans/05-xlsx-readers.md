# xlsx / xlsm / xltx / xltm / xlam readers (plan)

Reference: `nimbase/references/excelize` (Go). Template: `src/opendocs/docx/`
(docx reader/writer split, `zip.nim` reuse, `openparser/xml` DOM `xpStrict`).

## Locked decisions
- **Lazy getters**, excelize-style: sheet XML retained, parsed on access.
- **Formulas**: cached value + formula text in readers; `calc.go` engine port
  is a separate later phase (Phase E, largest chunk).
- **Number formatting staged**: raw values + types first (A), builtin + dates (B),
  custom formats (C/later).
- **vbaProject at OLE level only**: read-only CFB walk exposing stream bytes (D);
  VBA macro semantics out of scope.
- Readers only in this workstream; writers deferred. Unknown parts go to
  `rawParts` byte-exact so future writers round-trip.

## Reference map (excelize -> Nim)
| excelize | Nim | Notes |
|---|---|---|
| `excelize.go` File, `file.go` open flow | `xlsx.nim` + `xlsx/types.nim` | lazy fields, caches |
| `lib.go` ReadZipReader, `templates.go` paths | reuse `zip.nim` | case-insensitive `[Content_Types]`, `\\->/` |
| `xmlWorkbook.go`, `workbook.go` sheetMap | `xlsx/workbook.nim` | eager sheet name->sheetN.xml via rels |
| `xmlWorksheet.go`, `rows.go`, `cell.go`, `col.go`, A1 utils | `xlsx/sheet.nim` + `xlsx/cell.nim` | lazy per-sheet parse |
| `xmlSharedStrings.go`, lazy SST | `xlsx/sharedstrings.nim` | lazy + spill past size limit |
| `xmlStyles.go`, `numfmt.go`, `date.go` | `xlsx/styles.nim` | eager styles (Phase B+) |
| content types `templates.go:822` | `xlsx/contenttypes.nim` | ext->type matrix, no read branching |
| `calcchain.go`, CalcPr | tolerant skip | missing file is not an error |
| `docProps.go` | `xlsx/docprops.nim` | same shape as docx props |
| `crypt.go` magic check | detect + `XlsxError` | encrypted files error, never garbage |
| `vbaProject.bin` (OLE CFB) | `ole2.nim` read-only subset | brought forward from `.doc` phase |

## Module layout (`src/opendocs/`)
```
xlsx.nim               # facade: openXlsx/openXlsxBytes, getters, XlsxError
xlsx/types.nim         # XlsxFile (Pkg, sheetMap, lazy caches, XlsxReadOpts), CellType, Cell
xlsx/workbook.nim      # workbook.xml + rels -> sheet map, CalcPr, defined names
xlsx/sharedstrings.nim # lazy SST
xlsx/sheet.nim         # lazy sheet parse, rows, dimension, merges
xlsx/cell.nim          # getValueFrom port (b/d/e/n/s/str/inlineStr)
xlsx/styles.nim        # Phase B+
xlsx/docprops.nim      # Phase C
ole2.nim               # Phase D, read-only CFB
```

## Variant matrix (generic zip+rels flow; matrix is validation/passthrough only)
| Ext | workbook type | extras |
|---|---|---|
| `.xlsx` | SheetML | baseline |
| `.xlsm` | Macro | `xl/vbaProject.bin` |
| `.xltx` | Template | template content types |
| `.xltm` | TemplateMacro | template types + `vbaProject.bin` |
| `.xlam` | AddinMacro | add-in types + `vbaProject.bin` |

## Cell resolution (port of `cell.go:645 getValueFrom`)
`R` (A1) -> row/col; `T` -> CellType (`b/d/n/e/s/str/inlineStr`, default
numeric); `S` style idx (B); `F` formula text + cached `V`; `V` raw;
`IS` inline rich text. Merged-range reads duplicate the value (excelize parity).

## Phases
1. **A — package + raw grid**: DONE.
2. **B — formatting core**: DONE (576-cell excelize oracle matrix +
   bool/ISO/custom/missing-styles/1904 suites green).
3. **C — sheet extras**: rich text, hyperlinks, merges, dimensions, row/col
   sizes + visibility, docProps, header/footer + page layout, comment/picture refs.
4. **D — OLE subset**: `ole2.nim` read-only (header/FAT/directory),
   `vbaProject.bin` stream listing + bytes.
5. **E — calc engine (flagged, huge)**: formula evaluation; timebox to common
   functions first.

## Testing
`tests/t_xlsx.nim` (synthetic `newZipWriter` packages + checked-in fixtures per
ext generated via local LibreOffice), `unzip -t` gate, LO `--convert-to csv` as
value oracle. Malformed inputs (bad ZIP, missing workbook, corrupt SST index)
must raise, never panic.

## Risks
- DOM memory on huge sheets -> lazy per-sheet + spill; SAX fallback if needed.
- `xpStrict` vs Excel quirks -> keep quirks list per fixture failure.
- Phase E is 2-4x the other phases combined; keep last and optional.
