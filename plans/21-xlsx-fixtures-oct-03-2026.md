# XLSX fixtures and oracles (plan, 2026-10-03)

Tier 1 support, but sequenced **first**. Every other plan in this
roadmap depends on it, and plan 16's locale data is worthless without it.

This is not a feature plan. It is the thing that makes the other plans
checkable.

## Locked decisions

- **Check in the generated fixtures and the oracle dumps, and check in
  the generator.** A test that depends on Go being installed cannot run in
  CI, and a test that depends on a frozen dump cannot be refreshed.
  Both: dumps are committed, generators are committed, CI uses the dumps.
- **Pin the oracle version.** Record the excelize commit that produced
  each dump. The existing `phase_b_matrix.txt` was produced at
  `0434413`; new dumps record the same or note a move.
- **One workbook per feature area**, not one per function. A workbook
  with 3,000 cells compares better than 3,000 workbooks.
- **Malformed fixtures are hand-built** and live in a separate directory.
- **Attribute every borrowed fixture.** `ATTRIBUTION.md` already exists
  for `tests/fixtures/xlsx/`; extend it.

## The existing precedent

This pattern is already proven in this package, which is the main reason
to extend it rather than invent something:

- `tests/fixtures/xlsx/phase_b_matrix.xlsx` (8.8K) is a workbook with
  32 builtin formats by 18 values.
- `tests/fixtures/xlsx/phase_b_matrix.txt` (8.2K) is the matching
  `GetCellValue` dump.
- `t_xlsx.nim:285-301` reads the dump and compares all 576 cells,
  asserting the expected count at line 294 so a truncated fixture cannot
  silently shrink the suite.

That is exactly right, and it scales to plan 20's 458 functions as one
workbook.

## Generators

Three languages, three roles. Keep them separate.

### `tools/gen_xlsx_fixtures.nim` (Nim, in-repo)

For packages the reference cannot write. Uses the existing `newZipWriter`
path from `tests/t_xlsx.nim:309`.

- Hand-shaped malformed inputs (plan 18's corpus).
- Synthetic edge cases: a merge with the value off-anchor, overlapping
  merges, a range that is exactly `XFD1048576`, shared formulas with
  absolute anchors, a `<cols>` entry with `min == max`.
- Fixtures that need a specific byte shape, such as deep XML nesting.
- Deterministic output. No timestamps, no random ids. A fixture that
  changes on regeneration cannot be diffed.

### `tools/gen_xlsx_oracle.go` (Go, requires excelize)

Produces the dumps. Not run in CI; run when a fixture set changes, then
commit the output.

```go
// Reads a workbook, writes one line per cell:
// <sheet>\t<cell>\tGetCellValue\t<CalcCellValue>\tGetCellType
// CalcCellValue lines are omitted when it errors, with the error recorded
// on a separate line so "unsupported" is distinguishable from "wrong".
```

Two functions matter and they are different oracles:

| excelize API | oracle for |
|---|---|
| `GetCellValue` | plans 15, 16, 17: values, formats, styles |
| `CalcCellValue` | plan 20: formula results |
| `GetCellType`, `GetStyle`, `GetMergeCells`, `GetComments`, `GetPictures`, `GetDocProps`, `GetDefinedName`, `GetPageLayout`, `GetHeaderFooter` | the rest of plans 15-17 |

**Record errors, do not skip them.** A dump that silently omits a cell
whose evaluation failed looks identical to a dump for a workbook where the
cell does not exist. Every failure gets a line with the error text. This
is the same trap as plan 18's "assert which error, not that something
failed".

### LibreOffice (`soffice --convert-to`)

Plan 05 line 74 nominates LibreOffice as a value oracle. It is useful for
two things and not a third:

- **Generating workbooks that excelize cannot write.** excelize has no
  writer for comments, custom properties, or threaded comments, so plan
  17's fixtures need LibreOffice.
- **Cross-checking values** on files it produced.

It is **not** a value oracle for formatting: `soffice --convert-to csv`
emits formatted values using its own interpretation, which differs from
Excel's for custom formats and locales. Using it as the numfmt oracle would
validate against the wrong implementation. The current suite already
declines to use it at runtime (`t_xlsx.nim:241` records the CSV result as
a comment).

## Fixture inventory

Grouped by the plan that needs them. Names describe the **feature**, not
the phase, matching the lesson from the PDF fixtures where `m3a_*` through
`m8_*` names outlived their meaning.

### For plan 15: merges, geometry, names, hyperlinks

| Fixture | Shape |
|---|---|
| `merge_basic.xlsx` | 2x2 and 1x3 merges, values at anchors |
| `merge_offaxis.xlsx` | merge whose stored value is not top-left |
| `merge_ref.xlsx` | `mergeCellRef` form |
| `merge_empty.xlsx` | merge with no value in the span |
| `merge_overlap.xlsx` | overlapping ranges, invalid but occurs |
| `merge_corner.xlsx` | single-cell and whole-column merges |
| `defined_names.xlsx` | workbook scope, sheet-local, name collision, `Print_Area`, `Print_Titles`, `localSheetId` != `sheetId` |
| `hyperlinks.xlsx` | external rel, internal `location`, display, tooltip, plus a `HYPERLINK()` formula for contrast |
| `cols.xlsx` | ranged and overlapping `<cols>`, `bestFit`, `outlineLevel`, absent `defaultColWidth` |
| `shared_formula.xlsx` | shared formula spanning rows and columns, cross-sheet ref in the anchor |

`references/excelize/test/MergeCell.xlsx` (6.2K) is usable as a
cross-check.

### For plan 16: formats, styles, locales

| Fixture | Shape |
|---|---|
| `fmt_custom.xlsx` | one sheet per code family |
| `fmt_sections.xlsx` | 1-4 sections, empty section, `General` fallback |
| `fmt_scaling.xlsx` | trailing-comma **scaling** versus **grouping** |
| `fmt_exponent.xlsx` | `0.00E+00` versus `E+0`, 15+ significant digits |
| `fmt_fraction.xlsx` | `# ?/?`, `# ??/??`, edge denominators |
| `fmt_conditionals.xlsx` | `[<0]`, `[>=5]`, colour conditions |
| `fmt_escapes.xlsx` | `\"`, `\\`, `\_`, `*`, `;` inside quotes |
| `fmt_locale_all.xlsx` | **416 cells, one per LCID**, `[$-NNNN]` date format |
| `fmt_locale_odd.xlsx` | `fa-IR,301`, `az-Cyrl`, `x-sysdate`, unsupported |
| `styles_full.xlsx` | fonts, fills, borders, alignment, indexed and theme colours, tint |
| `styles_missing.xlsx` | no `styles.xml`; out-of-range `s` |

`fmt_locale_all.xlsx` is the one that matters most. 416 cells, one per
locale, each formatted with its own `[$-NNNN]` date code, dumped from
excelize. It is the entire verification story for 128 KB of locale data
and it is generated by a script, not typed.

`fmt_scaling.xlsx` deserves emphasis: `#,##0` and `#,##0,` differ by a
factor of a thousand and look nearly identical. Every locale-parity test
can pass while both are wrong.

### For plan 17: read-side

| Fixture | Shape |
|---|---|
| `props_full.xlsx` | full core, app, custom with all four `vt` types |
| `props_sparse.xlsx` | partial core; absent parts |
| `props_weirdns.xlsx` | default namespace, no `dc:` prefixes |
| `page_setup.xlsx` | portrait/landscape, `paperSize`, scale vs fit, odd/even/first, row and column breaks |
| `comments_basic.xlsx` | three comments, two authors, multi-run text, `xml:space="preserve"` |
| `comments_badauthor.xlsx` | `authorId` past the end |
| `pictures.xlsx` | `twoCellAnchor`, `oneCellAnchor`, PNG, JPEG, a chart drawing to skip, `extLst` |
| `pictures_cellimages.xlsx` | Excel 365 `cellimages.xml` |
| `richtext.xlsx` | bold, italic, theme colour, size, superscript, `<rPh>`, run without `rPr` |
| `richtext_whitespace.xlsx` | runs whose text is only spaces |
| `sheet_props.xlsx` | tab colour, hidden gridlines, code name, protection, custom widths |

### For plan 18: malformed

Under `tests/fixtures/xlsx/malformed/`, hand-built. Missing required
parts, zero-length parts, truncation at four positions, deep nesting,
huge attribute, path-traversal rels, external-target rels, rel cycles,
`A0`, `XFE1`, row 0, `t="z"`, non-numeric `<v>`, out-of-range SST index,
negative SST index, style index out of range, zip central-directory
disagreement, duplicate part paths.

### For plan 19: OLE and encryption

| Fixture | Source |
|---|---|
| `ole/vbaProject.bin` | copy from `references/excelize/test/` (16K, real CFB) |
| `macro.xlsm`, `macro.xltm`, `macro.xlam` | carry it |
| `macro_bad_magic.xlsm` | the 7-byte fake already at `t_xlsx.nim:431`, kept as negative |
| `ole/cyclic_fat.bin`, `ole/v3_and_v4.bin`, `ole/ministream.bin` | hand-built |
| `encrypted/aes.xlsx`, `sha1.xlsx`, `sha512.xlsx` | from the reference |

### For plan 20: calc

| Fixture | Shape |
|---|---|
| `calc_arith.xlsx` | precedence, `2^3^2`, unary minus, percent, error propagation |
| `calc_refs.xlsx` | absolute/relative, cross-sheet, 3D, whole-column clamping |
| `calc_criteria.xlsx` | every `SUMIF`/`COUNTIF` criteria form |
| `calc_dates.xlsx` | 1900 and 1904, leap-bug boundary, `YEARFRAC` all bases |
| `calc_errors.xlsx` | all error types, nesting, unknown function |
| `calc_cycles.xlsx` | circular refs, iteration on and off |
| `calc_volatile.xlsx` | `NOW`/`RAND` across calls |
| `calc_all_functions.xlsx` | **one cell per function**, the differential corpus |

`calc_all_functions.xlsx` is the plan's whole verification strategy in one
file. It should exist before P3 so each remaining function lands against a
known answer.

## Test harness

```nim
proc assertAgainstOracle*(suite: string, book, dump, oracle: string,
                          names: openArray[string])
```

A shared helper, because eight plans will otherwise each write their own
ad-hoc dump parser. It should:

- read the dump line by line into a `Table[(sheet, cell), seq[string]]`;
- assert the dump's expected cell count matches the workbook, as
  `t_xlsx.nim:294` does;
- compare each named cell against each oracle column;
- **fail on a dump entry with no corresponding cell**, and on a cell with
  no dump entry. Both directions, because either one means the fixture
  and the dump drifted apart;
- record which excelize commit produced the dump in a header comment and
  surface it in failure output.

`phase_b_matrix.txt` should be migrated onto this helper as proof it works
before the other plans rely on it.

## Phases

1. **P1 the harness**, plus migrating the existing Phase B matrix.
2. **P2 the Go oracle generator**, covering `GetCellValue` and
   `CalcCellValue` at minimum.
3. **P3 `fmt_locale_all.xlsx` and its 416-cell dump.** Before plan 16 P5,
   since that data is otherwise unverifiable.
4. **P4 variant fixtures** for `.xlsm`/`.xltx`/`.xltm`/`.xlam`, shared
   with plan 18 P5.
5. **P5 `calc_all_functions.xlsx`**, incrementally as functions land, but
   the skeleton before plan 20 P3.
6. **P6 malformed corpus**, with plan 18.
7. **P7 attribution** for everything checked in.

## Testing

The harness is itself tested, which is unusual and necessary:

- A dump with a missing line must fail, not pass quietly.
- A dump with an extra line must fail.
- A truncated dump must fail the count assertion, proving the existing
  check at `t_xlsx.nim:294` works through the new harness.
- An empty oracle column set must raise rather than vacuously passing.
- Malformed fixtures: assert the specific `XlsxError`, not merely failure.

## Risks

- **Checked-in binary fixtures accumulate.** Every plan adds files. Keep
  them small and purpose-built; the existing fixtures are 6-9 KB each and
  that is the right order. A single multi-megabyte fixture is a signal the
  test should be synthetic.
- **Oracle drift.** The dumps are frozen at an excelize commit. When
  excelize is bumped, every oracle comparison is stale and nobody will
  notice until a real regression. Record the commit in each dump header
  and add a script that reports which dumps are older than the pinned
  version.
- **LibreOffice version differences** affect generated fixtures for plan
  17. Record the version in `ATTRIBUTION.md` alongside each fixture, and
  prefer hand-built fixtures when the shape is simple enough.
- **Go and excelize availability** blocks regeneration. Committing both
  the dumps and the generators means CI is fine and only a deliberate
  refresh needs Go.
- **A 416-locale fixture is one cell wide and enormous** in diffs when it
  changes. Keep the dump line-oriented and sorted so a mismatch localises.
- **Fixture names drift from meaning**, as `m3a_*` did in the PDF corpus.
  Name by feature. If a milestone name feels natural, resist.
- **`calc_all_functions.xlsx` will be huge** and will grow with the
  engine. Split by category (nine workbooks) rather than one, so a
  financial-function failure does not require re-running statistical ones,
  and so each file stays diffable.