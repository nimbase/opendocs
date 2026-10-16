# XLSX merges, hyperlinks, defined names (plan, 2026-10-03)

Tier 1, workstream 1 of 3. The first tier-1 document because merged cells
are the one gap that plan 05 stated as a *requirement* rather than a
deferred item, so leaving it unbuilt contradicts a locked decision.

## Locked decisions

- **Merged-value duplication matches excelize.** `GetMergeCells` and the
  cell read path both propagate the anchor value across the span, so
  `getCellValue(sheet, "B2")` on a merge anchored at `A1` returns `A1`'s
  value. This is what plan 05 line 57 required.
- **Expose merges as their own type.** `getMergeCells` returns ranges;
  duplication is applied on read. Do not synthesize phantom cells into
  `XlsxSheet.rows`, which would corrupt `getRows` for callers that care
  about stored layout.
- **Merges are read-only here.** `mergeCells` needs no writing.
- **Hyperlinks report, not fetch.** Target and tooltip are returned;
  nothing dereferences the URL.
- **Defined names carry their scope.** Workbook-scoped and sheet-local
  names are distinguished, since the same name can exist in both.

## Work items

### 1. Merged cells (highest value; unmet requirement)

`parseSheet` (`sheet.nim:42`) reads `dimension` and `sheetData` and stops.
`mergeCells` sits between them in the schema and is never visited. Grep
for `merge` across `xlsx.nim` and `xlsx/` returns nothing.

Add:

```nim
type
  XlsxMerge* = object
    ref*: string          ## "A1:B2", as written
    first*: int           ## row, 1-based
    last*: int            ## row
    firstCol*, lastCol*: int  ## 1-based
  value*: string        ## resolved from the anchor cell

proc getMergeCells*(f: XlsxFile, sheet: string): seq[XlsxMerge]
proc isMerged*(f: XlsxFile, sheet: string, cell: string): bool
```

- `<mergeCells count="n">` holds `<mergeCell ref="A1:B2"/>`.
  `CT_MergeCells` contains only `mergeCell` children, so there is no separate
  `mergeCellRef` form to support.
- Anchors need not be top-left. Excel writes the anchor in the first cell
  and empties the rest, but a file may store the value in any covered
  cell. Resolve by scanning the span for the first non-empty stored value
  rather than assuming `first`/`firstCol`.
- **`getCellValue` and `getCellType` must consult the merge map.** A read
  of a covered cell returns the anchor's value and type. Cache the map
  per sheet alongside the parsed sheet; this is a `Table[string, string]`
  keyed by cell, built once on first merged read.
- `getRows` must **not** replicate. It returns stored rows today and its
  interior padding (`sheet.nim:153`) is a layout property callers depend
  on. Document the split explicitly: `getRows` is storage-shaped,
  `getCellValue` is value-shaped.
- `XlsxSheet` gains `merges*: seq[XlsxMerge]`.

excelize parity note: `GetMergeCells` takes a `withoutValues ...bool`
variadic, defaulting to *with* values. We expose both, unconditionally
populated, since there is no cheap way to fill values later without a
second parse.

### 2. Defined names

Absent entirely; `definedName` has zero hits in the subsystem. Needed by
calc (plan 20) for name resolution and by anything that wants to follow
`Print_Area` or `Print_Titles`.

```nim
type
  XlsxDefinedName* = object
    name*: string
    refersTo*: string      ## raw "Sheet1!$A$1:$B$2"
    scope*: string         ## "Workbook" or the sheet name
    hidden*: bool
    comment*: string
proc getDefinedNames*(f: XlsxFile): seq[XlsxDefinedName]
```

- Read `<definedNames>` from `workbook.xml`. Local names carry
  `localSheetId`, an **index into workbook order**, not a sheetId. Map it
  through `sheetOrder`; the two differ whenever sheets have been deleted
  and re-added.
- Built-ins to recognise and keep addressable by name:
  `_xlnm.Print_Area`, `_xlnm.Print_Titles`, `_xlnm._FilterDatabase`,
  `_xlnm.Criteria`. Do not hide them; they are the only way to recover a
  print range, which plan 17's header/footer work wants.
- Scope resolution: worksheet scope wins over workbook scope, matching
  excelize's `getDefinedNameRefTo` (`lib.go:370`). Expose the raw list and
  document that callers must do the precedence themselves; doing it in
  the getter hides information a writer will need.
- `refertsTo` often carries a leading `=` in some producers and not
  others. Strip a single leading `=` on read, and document that.

### 3. Hyperlinks

`<hyperlinks>` is a sibling of `sheetData`, after `mergeCells`. Each
`<hyperlink ref="A1" r:id="rId1" display="..." tooltip="..."/>` carries
either an `r:id` (external, resolved through the sheet's `.rels`) or an
inline `location` (internal jump, no rel).

```nim
type
  XlsxHyperlink* = object
    cell*: string
    target*: string        ## external URL, "" for internal
    location*: string      ## internal target, "" for external
    display*, tooltip*: string
proc getHyperlinks*(f: XlsxFile, sheet: string): seq[XlsxHyperlink]
proc getCellHyperlink*(f: XlsxFile, sheet: string, cell: string): (bool, XlsxHyperlink)
```

- Relationship type `.../hyperlink`, `TargetMode="External"`. The rels
  reader (`workbook.nim:14`) is reusable but is currently private to the
  workbook module; widen it rather than duplicating.
- `HYPERLINK("url", "text")` **formulas** are a separate thing from
  `<hyperlinks>` elements. Excel writes one or the other. Plan 20 parses
  the formula; do not special-case it here.
- Cells may be inside a merge. Report the stored ref, not the span.

### 4. Sheet dimension, row and column geometry (retrieval only)

Three fields are already parsed and unreachable. This is retrieval work,
not new parsing, and it is cheap:

```nim
proc getSheetDimension*(f: XlsxFile, sheet: string): string
proc getRowHeight*(f: XlsxFile, sheet: string, row: int): float
proc getRowVisible*(f: XlsxFile, sheet: string, row: int): bool
proc getColWidth*(f: XlsxFile, sheet: string, col: int): float
proc getColVisible*(f: XlsxFile, sheet: string, col: int): bool
```

- `dimension` is at `sheet.nim:54`, `row/@hidden` and `row/@ht` at
  `sheet.nim:66`. All three are stored; only the getters are missing.
- `<cols>` is genuinely absent and needs parsing. `XlsxCol` gains `min`,
  `max`, `width`, `hidden`, `bestFit`, `customWidth`, `outlineLevel`,
  `collapsed`. Note that `<cols>` entries span ranges (`min="2" max="4"`),
  so a column can appear in several entries; last-wins per Excel, and the
  getter should walk entries rather than assume uniqueness.
- Default width comes from `<sheetFormatPr defaultColWidth baseColWidth>`.
  Return `-1` for "absent" like `height` does, rather than inventing the
  Excel default of 8.43, which varies with the base font.
- `getColWidth` takes a **1-based column index**, not an A1 ref. Adding
  `columnNameToNumber` from `cell.nim:24` makes both spellings trivial;
  pick one and document it.

### 5. Shared formulas

`<f t="shared" si="7" ref="C1:C10">SUM(A1:A2)</f>` on the anchor, and
`<f t="shared" si="7"/>` on the rest. `getCellFormula` returns `""` for
every cell except the anchor. LibreOffice produces this shape and Excel
does it under pressure, so it is not rare.

- Resolve by translating the anchor formula's relative references by the
  row/column delta from anchor to target. That is a token-level rewrite,
  not a string operation.
- This is the natural home for it, since plan 20's tokenizer is needed to
  do it correctly, and plan 20 lands later. Sequence the tokenizer first
  within plan 20 and land shared-formula expansion as its first
  milestone. Do not implement it twice.

## Reference map (excelize -> Nim)

| excelize | Nim target | Notes |
|---|---|---|
| `merge.go:146` `GetMergeCells` | `getMergeCells` | excelize's `withoutValues` variadic dropped |
| `sheet.go:1876` `GetDefinedName` | `getDefinedNames` | we expose scope explicitly |
| `lib.go:366` `getDefinedNameRefTo` | scope precedence, documented not applied | |
| `templates.go:857` `builtInDefinedNames` | recognised, not hidden | |
| `cell.go:1022` `GetCellHyperLink` | `getCellHyperlink` | excelize returns `(bool, string)`; we return the record |
| `cell.go:1053` `GetHyperLinkCells` | scan variant, optional | |
| `rows.go:487` `GetRowHeight` | `getRowHeight` | |
| `col.go:716` `GetColWidth` | `getColWidth` | ours takes an index |
| `col.go:245` `GetColVisible` | `getColVisible` | |
| `sheet.go:2170` `GetSheetDimension` | `getSheetDimension` | already parsed |

## Phases

1. **P1 merges: done.** `XlsxMerge`, `getMergeCells`, `isMerged`,
   merge-aware `getCellValue`/`getCellType`. Unblocks the plan 05
   requirement.
2. **P2 geometry getters: done.** They close three parsed-but-unreachable
   fields. `<cols>` parsing included.
3. **P3 defined names: done.** Needed by calc.
4. **P4 hyperlinks: done.** Independent of the rest.
5. **P5 shared formulas.** After plan 20's tokenizer; listed here so the
   dependency is not lost.

## Fixtures

- `merge_basic.xlsx`: 2x2 and 1x3 merges, values at anchors.
- `merge_offaxis.xlsx`: merge whose value sits in a non-anchor cell.
- `merge_empty.xlsx`: merge with no value anywhere in the span.
- `merge_overlap.xlsx`: overlapping ranges, which is invalid but occurs.
- `defined_names.xlsx`: workbook-scoped, two sheet-local with a name
  colliding with the workbook scope, plus `Print_Area` and
  `Print_Titles`; sheet-local names on a sheet whose index differs from
  its sheetId.
- `hyperlinks.xlsx`: external rel, internal `location`, display and
  tooltip, and a `HYPERLINK()` formula cell for contrast.
- `cols.xlsx`: ranged `<cols>` entries with overlaps, `bestFit`,
  `outlineLevel`, explicit defaults on one sheet and absent geometry on
  another.
- `shared_formula.xlsx`: shared formula spanning rows and columns, with a
  cross-sheet reference in the anchor.

Generate with excelize where it can produce the shape, LibreOffice
otherwise, and hand-write the malformed ones. `test/MergeCell.xlsx`
(6.2K) already exists in the reference and is usable as a cross-check.

## Testing

Extend `tests/t_xlsx.nim`, or split into `t_xlsx_merge.nim` and
`t_xlsx_names.nim` since the file is already 447 lines and this plan adds
roughly as much again.

Assert the negative cases, which is where this plan's real risk lives:

- a read of a covered cell returns the anchor's value **and** its type,
  not `""` and not `ctyUnset`;
- `getRows` does **not** replicate, and this is asserted explicitly so a
  future "fix" to unify the two does not silently change layout;
- a merge with no stored value returns `""` rather than raising;
- overlapping merges do not crash; first-wins is documented;
- `localSheetId` maps through workbook order, not sheetId;
- a defined name with and without a leading `=` yields the same
  `refersTo`;
- an unresolvable hyperlink rel yields an empty `target` rather than
  raising, since a dangling rel is not fatal to the workbook.

## Risks

- **Duplication is a visible behaviour change.** `getCellValue` on a
  covered cell returns a value where it returned `""` before. That is the
  intended parity fix, but it can break callers that use empty-string
  probing to find real cells. Call it out in the release notes.
- **Anchor-not-top-left is real but rare.** Resolving by scanning the span
  makes this correct, at O(span) per merge. Bound it by the sheet
  dimension so a malformed huge range does not scan a million rows.
- **Reference translation for shared formulas is easy to get subtly
  wrong**, particularly with absolute anchors, ranges whose endpoints
  shift differently, and cross-sheet refs. This is why it waits for a
  real tokenizer instead of a regex.
- **`getColWidth` semantics differ from excelize** (index versus ref,
  and ours returns -1 for absent where excelize returns a default). The
  `-1` sentinel is consistent with `XlsxRow.height`, which is the
  in-repo precedent, but it is a divergence worth stating in the header.