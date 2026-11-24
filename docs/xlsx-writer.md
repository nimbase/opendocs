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
  part, including stale sheet `.rels` under `xl/worksheets/_rels/`);
  `_rels/.rels` and `[Content_Types].xml` always regenerate.
  `ZipError` surfaces as `XlsxError`.

## Sheet extras (W2)

- `addMerge(doc, sheet, ref)` — merged range (`A1:B2`, absolutes and
  reversed corners accepted). Invalid refs and overlaps with an earlier
  merge fail loudly (the reader tolerates overlaps file-order-first;
  the builder refuses to author ambiguity). Merges grow the emitted
  `dimension` even when their cells are empty.
- `setColWidth(doc, sheet, min, max, width)` / `setColHidden(...)` —
  column ranges appended in call order (overlaps read back last-wins,
  reader parity). Non-positive widths fail (hide instead).
- `setRowHeight(doc, sheet, row, height)` / `setRowHidden(...)` —
  per-row geometry; rows with props but no cells still emit an empty
  `<row>`. Non-positive heights fail.
- `addHyperlink(doc, sheet, ref, target, location, display, tooltip)` —
  cell or range ref. External targets serialize through the sheet's
  `.rels` (`TargetMode="External"`, `rIdH1...` minting); internal
  `location`-only jumps inline. Both-empty fails; dangling `r:id`s are
  never authored (reader tolerates, builder refuses).
- `addDefinedName(doc, name, refersTo, scope, hidden, comment)` —
  workbook names. Blank/overlong/cell-ref-like names and unknown scopes
  fail; one leading `=` on `refersTo` is stripped (reader normalization).
  Workbook scope emits no `localSheetId`; sheet scope emits the 0-based
  workbook-order index.

See `tests/t_xlsx_write.nim` (20/20: W1 cells plus merges, geometry,
hyperlinks incl. rels part, defined names with scopes).

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

## Styles (W3)

- `XlsxCellStyle(numFmtCode, hasFont/font, hasFill/fill, hasBorder/border,
  hasAlignment/alignment, hasProtection/protection)` — component types
  reuse the reader model (`XlsxFont`, `XlsxFill`, `XlsxBorder`,
  `XlsxAlignment`, `XlsxProtection`) so `getCellStyle` round-trips
  compare equal. Only pattern fills supported (gradients fail loudly
  in `addStyle`).
- `addStyle(doc, style): int` — intern, return the `cellXfs` index.
  Index 0 stays reserved for unstyled cells, so even an empty style
  yields a nonzero index (this is what flips bools to `TRUE`/`FALSE`).
  Components dedupe structurally (including against the seeded blank
  defaults); `cellXfs` records dedupe among appended entries only.
  Custom number formats allocate ids from 164 up, deduped by code;
  builtin codes (e.g. `mm-dd-yy` -> 14) map to their builtin ids.
- `setCellStyle(doc, sheet, ref, idx)` / `setRangeStyle(doc, sheet,
  fromRef, toRef, idx)` — assign to existing cells only; absent cells
  and out-of-range indices fail loudly (no phantom cells).
- Every save ships a minimal `xl/theme/theme1.xml` (Office palette,
  docx-writer shape): the reader resolves all style colors through the
  theme, so conditional emission would silently drop colors.
- `setCellDate` + a date `numFmtCode` renders serials as dates
  (`formatApplied` true); any nonzero style index renders bools as
  `TRUE`/`FALSE`. Style-free cells keep the exact W1 shape.

- `openXlsxForEditBytes(data, opts) / openXlsxForEdit(path, opts)` (W4)
  — hydrate an existing package into the builder for modify-and-resave:
  cells (numbers verbatim, strings resolved to plain text, `t="d"` ISO
  dates normalized to serials per excelize `getCellDate`, bools coerced
  on `1`, errors carried, shared formulas flattened to plain formulas
  with per-cell cached values, array/dataTable formulas refused loudly),
  style tables verbatim (indices stay aligned), merges/cols/row
  geometry/hyperlinks/defined names/docProps carried, source theme
  carried byte-exact. `xl/calcChain.xml` always dropped (stale caches
  must not survive an edit); chartsheets fail loudly (unrepresentable,
  and silent sheet loss is worse); sheet `state` is unmodeled (the
  reader does not parse it; sheets always emit visible).

See `tests/t_xlsx_write.nim` (32/32: W1 cells, W2 extras, W3 styles,
W4 built-file edits, LibreOffice round-trip with byte-exact theme,
error/shared-formula fidelity, calcChain drop, chartsheet refusal).
