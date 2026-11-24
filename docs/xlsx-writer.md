# XLSX Writer

Implementation: `src/opendocs/xlsx/write.nim` (builder + package assembly),
emit helper in `src/opendocs/xlsx/emit.nim`. Entry is `opendocs/xlsx`
(builder API lives alongside the reader; same canonical home).

## Writing

```nim
import opendocs/xlsx

var doc = newXlsxDoc()
doc.setCellStr("Sheet1", "A1", "hello")
doc.setCellNum("Sheet1", "B1", 1.5)
doc.setCellInt("Sheet1", "C1", 42)
doc.setCellBool("Sheet1", "D1", true)
doc.setCellDate("Sheet1", "E1", dateTime(2026, mJan, 2, 12, 0, 0, 0, utc()))
doc.setCellFormulaValue("Sheet1", "F1", "A1+1", 43.5)
let bytes = doc.saveXlsxBytes()
doc.saveXlsx("out.xlsx")
```

- `newXlsxDoc(date1904 = false)` — fresh workbook with one sheet
  (`Sheet1`). Deterministic: no timestamps unless the caller sets
  `coreProps.created/modified`.
- `addSheet(doc, name)` — append a sheet. Blank/forbidden/overlong names
  and case-insensitive duplicates fail loudly (`XlsxError`). Sheet rules
  (31 UTF-16 units, no `: \ / ? * [ ]`, no leading/trailing `'`)
  mirror excelize `checkSheetName`; the duplicate case diverges
  (excelize returns the existing index, this builder fails).
- `setCellStr / setCellNum / setCellInt / setCellBool / setCellDate` —
  the five cell types. Strings SST-dedupe (truncated at 32767 UTF-16
  units); numbers use the 15-significant-digit `formatCellFloat` form
  (ints exact); dates store serials in the workbook date system.
- `setCellFormula(doc, sheet, ref, formula)` (no cached value),
  `setCellFormulaValue(..., cached: float)` (numeric `<v>`),
  `setCellFormulaStr(..., cached: string)` (string `<v>`, `t="str"`).
  Leading `=` is rejected (pass `SUM(A1)`, not `=SUM(A1)`).
- `saveXlsxBytes(doc, opts) / saveXlsx(doc, path, opts)` — full package
  assembly. Modeled parts regenerate; `rawParts` re-emit byte-exact
  except superseded (same name or per-part `.rels` for a regenerated
  part); `_rels/.rels` and `[Content_Types].xml` always regenerate.
  `ZipError` surfaces as `XlsxError`.

## Pre-W3 behavior (deliberate)

- All cells write style `0` (single default xf). Unstyled bools read back
  raw (`"1"`/`"0"`, not `TRUE`/`FALSE`); date serials read back as
  numbers. Formatted views need cell styles (W3).
- No theme part (reader treats a missing theme as "no color").
- `sst/count` is the total string-cell reference count (spec-correct);
  excelize sets `count == uniqueCount`.
- Dates on/before the epoch fail loudly instead of degrading to
  strings (excelize stores RFC3339 in that case).
- Non-finite floats store as `Inf` / `-Inf` / `NaN` shared strings
  (Go `fmt.Sprint` form, excelize `SetCellFloat` parity).
- Zip entry timestamps come from `opendocs/zip` (`now()`), so two saves
  of one model differ byte-wise. Tests round-trip through the reader,
  never byte-compare (same policy as the DOCX writer).

## Zero-copy I/O (`emit.nim`, `std/memfiles` + `buffalo`)

- Emit builds every part in one reusable `PooledBuffer[byte]`
  (`initPool` once per save, `clear` per part). Stack scratch uses
  `StaticBuffer` in a `buffaloScope` at call sites.
- Parts larger than `XlsxWriteOpts.spillThresholdBytes` stage through a
  temp dir and are mmap-read (`memfiles.open(fmRead)` + `buffalo/memView`)
  one at a time at pack time: peak memory is one large part, not all
  parts. `spillCapBytes` bounds the total staged; `spillDir` overrides
  the temp parent (default system temp). Same portable-temp rules as the
  reader (no hardcoded `/tmp`).

See `tests/t_xlsx_write.nim` (12/12: all five types, dedupe, validation,
truncation, spill, carry-through, docProps, file save).
