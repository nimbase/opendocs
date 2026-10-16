Spreadsheet fixtures: origin and generation.

`fixture1.xlsx` — two-sheet workbook (`Fruit`, `Second`) with strings,
numbers, a boolean, a date, and a formula cell. Generated from a
hand-written flat ODF source (`/tmp/xlgen/fixture.fods`, not checked in)
via:

  /Applications/LibreOffice.app/Contents/MacOS/soffice --headless \
    --convert-to xlsx --outdir tests/fixtures/xlsx /tmp/xlgen/fixture.fods

LibreOffice normalizes booleans/dates to stored numbers on xlsx export
(`t="n"`); the formula cell keeps its source-cached `#VALUE!` (LO
recomputes to `Err:510` on load). Oracle CSV via
`soffice --convert-to csv` — see the fixture suite in `tests/t_xlsx.nim`.

`phase_b_matrix.xlsx` — 32 builtin number formats (columns B..AG, one
style per column) over 18 numeric values (rows 2..19: integers, date
serials incl. the 59/60/61 leap-quirk zone, fractions, negatives,
rounding halves) plus bool cells A20/A21 under a date style. Written
by excelize itself (`nimbase/references/excelize`) so formatted values
are the reference implementation's verbatim output.
`phase_b_matrix.txt` — the matching `GetCellValue` dump
(`fmtId|rowIdx|value`, rowIdx 0-based over the 18 values), consumed by
the Phase B oracle suite in `tests/t_xlsx.nim`.

`merge_basic.xlsx`, `merge_offaxis.xlsx`, `merge_empty.xlsx`, and
`merge_overlap.xlsx` — minimal synthetic packages with fixed archive
timestamps. They isolate normal, reversed/off-anchor, empty, and
overlapping merge declarations, respectively, and are consumed by
`tests/t_xlsx_merge.nim`.

`cols.xlsx` — minimal synthetic package with fixed archive timestamps. The
`Geometry` sheet covers stored dimensions, row heights and visibility,
overlapping column ranges, and sheet format defaults; `Bare` covers absent
geometry. Consumed by `tests/t_xlsx_geometry.nim`.

`defined_names.xlsx` — minimal synthetic package with fixed archive
timestamps. Covers workbook and sheet-local scopes, a scope collision,
built-in print names, and workbook-order `localSheetId` mapping. Consumed
by `tests/t_xlsx_defined_names.nim`.

`hyperlinks.xlsx` — minimal synthetic package with fixed archive
timestamps. Covers an external relationship, an internal location, a
dangling relationship, and a contrasting `HYPERLINK()` formula. Consumed
by `tests/t_xlsx_hyperlinks.nim`.
