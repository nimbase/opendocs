# XLSX roadmap (index, 2026-10-03)

Reference: `nimbase/references/excelize` (Go, `github.com/xuri/excelize/v2`,
HEAD `0434413`, 89,359 lines across 54 non-test Go files).
Continues the numbering from `13-pdf-writer-capabilities-oct-02-2026.md`.

Supersedes the phase ledger in `05-xlsx-readers.md`, which stays as the
original design record. This document is the current status of record.

## Why this document exists

`05-xlsx-readers.md` describes the intent accurately but its phase ledger
is now misleading in three specific ways, all documented below. It records
Phase C as "not started" when roughly a tenth of it is shipped, and it
records Phase E as "timebox to common functions first" when the decision
has changed: the calc engine is now a committed tier with full parity as
the target.

## Locked decisions

- **Readers only.** Carried forward from plan 05 and reconfirmed. Writer
  work stays out of scope; this roadmap never adds a `set*` proc.
- **Phase E is committed, not optional.** Plan 05 flagged the calc engine
  as "2-4x the other phases combined" and optional. That is superseded.
  Full excelize parity (458 functions) is the target. Tier order is
  unchanged in consequence: calc still lands last.
- **The VM is ours, not vancode's.** `packages/vancode` was evaluated and
  rejected. See "Rejected dependencies" below; the licensing reason alone
  is sufficient.
- **Custom number formats get full excelize parity, locales included.**
  This is the single largest mechanical block in the roadmap and is
  called out again in tier 2 because it is mostly data entry, not design.
- **OLE stays Phase D** as plan 05 locked it, scoped to stream listing and
  bytes for `vbaProject.bin`. VBA macro semantics stay out of scope.
- **Expose, do not interpret.** Every reader returns what the file says.
  Where excelize normalizes or repairs, that is a writer or calc concern.
- **Fail loudly, never silently degrade.** Three shipped paths currently
  degrade silently (custom formats, missing style parts, unparsed rich
  text formatting). Tier 1 makes each either correct or documented.

## Status matrix

Legend: `done` shipped and tested, `partial` shipped with a documented
narrow scope, `gap` absent entirely.

| Area | Module | State | Notes |
|---|---|---|---|
| Package open / spill | `xlsx/reader.nim`, `xlsx/base.nim` | done | zip, spill thresholds, caps, `=destroy` cleanup |
| OLE magic rejection | `xlsx/reader.nim:22` | done | encrypted/legacy packages raise `XlsxError` |
| Workbook / sheet map | `xlsx/workbook.nim` | partial | sheet map, `date1904`; **no `calcPr`, no defined names** |
| Lazy shared strings | `xlsx/sharedstrings.nim` | done | full load on first access, guarded by `sstLoaded` |
| Cell types | `xlsx/cell.nim` | done | all 7 `T` values plus `ctyUnset` default |
| A1 references | `xlsx/cell.nim` | done | split/join, column conversions, raises on malformed |
| Raw grid | `xlsx/sheet.nim` | done | rows, cols, interior padding, trailing trim |
| Number formats (builtin) | `xlsx/numfmt.nim` | done | 893 lines, dates + fractions + scientific |
| Number formats (custom) | `xlsx/numfmt.nim:891` | **gap** | short-circuits to raw; silent degradation |
| Number formats (locales) | none | **gap** | `[$-NNN]` not interpreted at all |
| Styles: numFmts/cellXfs | `xlsx/styles.nim` | done | enough for formatting |
| Styles: fonts/fills/borders | none | **gap** | deferred to plan 16 |
| Rich text | `xlsx/sharedstrings.nim:10` | partial | runs concatenate; `<rPr>` formatting discarded |
| Sheet dimension | `xlsx/sheet.nim:54` | partial | parsed, stored, **no getter** |
| Row height / hidden | `xlsx/sheet.nim:66` | partial | parsed into `XlsxRow`, **no getter** |
| Column width / hidden | none | **gap** | `<cols>` never read; no `XlsxCol` type |
| **Merged cells** | none | **gap** | not read at all; plan 05 line 57 required it |
| Hyperlinks | none | **gap** | `<hyperlinks>` never read |
| Defined names | none | **gap** | `definedName` grep: 0 hits |
| `calcPr` / `calcChain` | none | **gap** | both absent; tolerant skip is the plan |
| docProps | none | **gap** | no `docprops.nim`; docx has the precedent |
| Header/footer, page setup | none | **gap** | no `pageSetup`, `headerFooter`, `pageMargins` |
| Comments (notes) | none | **gap** | no `comments.xml`, no VML, no `<legacyDrawing>` |
| Pictures | none | **gap** | no drawing rel resolution, no `xl/media` |
| Formula text / cached value | `xlsx/sheet.nim:27` | done | `<f>` and `<v>` verbatim |
| **Formula evaluation** | none | **gap** | plan 20 |
| OLE / CFB | none | **gap** | no `ole2.nim`; plan 19 |
| XML depth enforcement | `xlsx/base.nim:14` | **gap** | constant declared, never referenced |

## Corrections to plan 05's phase ledger

Plan 05's ledger reads "C not started / D not started / E not started".
Verified state:

| Phase | Plan says | Actually |
|---|---|---|
| **A** package + raw grid | DONE | DONE, confirmed |
| **B** formatting core | DONE | DONE, confirmed; 576-cell oracle green |
| **C** sheet extras | not started | **~10%**: 6 of 9 items absent, 3 partial |
| **D** OLE subset | not started | 0%: magic rejection only, no `ole2.nim` |
| **E** calc engine | not started, optional | 0%, and now **committed**, not optional |

Four things plan 05 does not record, each of which changes what the next
contributor does first:

1. **Merged cells are the largest parity gap.** Plan 05 line 57 explicitly
   requires "merged-range reads duplicate the value (excelize parity)".
   It is unimplemented and, unlike the other gaps, was a stated
   requirement rather than a deferred item. Plan 15.
2. **`MaxXlsxXmlDepth = 64` is declared and never used.**
   `base.nim:14` comments it as a "nesting cap against hostile documents"
   but nothing references it. A reviewer would reasonably believe XML
   depth is bounded. It is not. Plan 18.
3. **Custom formats degrade silently.** `numfmt.nim:891` returns the raw
   value for any `numFmtId` present in `styles.numFmts`. One test asserts
   this as intended (`t_xlsx.nim:351`), so it is a decision, but it is
   invisible at the call site. Plan 16.
4. **`getSheetMap` inverts excelize.** `sheet.nim:99` returns
   `Table[int, string]` (sheetId to name); excelize's `GetSheetMap`
   returns name to index. Deliberate or not, it is undocumented and will
   surprise anyone porting excelize code. Documented in plan 15.

## Tier order

| Tier | Theme | Plan | Rationale |
|---|---|---|---|
| 0 | Correct the ledger | this file | Plan 05's phase list is the first thing a contributor reads |
| 1 | Read-side completeness | 15, 16, 17 | Fix silent blind spots. Highest value per line |
| 2 | Parser robustness | 18 | Depth cap is currently a lie; malformed corpus is the net |
| 3 | OLE / VBA | 19 | Self-contained, no dependency on the rest |
| 4 | Calc engine | 20 | Largest block; needs tier 1 and 2 to be correct first |

Tier 1 before tier 2 because the blind spots and the missing depth cap
are both correctness issues in shipped code, and tier 2's malformed
corpus is what keeps tiers 1 and 4 from regressing.

Tier 4 last, and this is unchanged from plan 05's instinct. The reason is
sharper now that calc is committed rather than optional: a formula
resolver that ignores merged-cell anchors, defined names, and
whole-column clamping will need its resolver rebuilt once tiers 1 and 3
land. Building the engine first means building it twice.

## Tier 0: correcting the ledger

Plan 05 lines 59-68 mark C, D, and E as unstarted. That is wrong for C
and right for D and E. Either update plan 05's ledger in place or add a
pointer to this document at the top of it; leaving both in place means
the next reader gets two contradictory status lists.

Recommendation: add a two-line pointer at the head of `05-xlsx-readers.md`
naming this document as the status of record, and leave the original
phases intact as the design record. That preserves the reasoning behind
the locked decisions rather than overwriting history.

## Rejected dependencies

**`packages/vancode` for the calc engine.** Evaluated in detail, since it
looked like a strong fit: 10,010 lines with an AST (`nkInfix`, `nkCall`,
and friends), a bytecode VM, a dynasm JIT, and a worked calculator
example. Rejected on two independent grounds.

- **Licensing.** vancode is `LGPL-3.0-or-later`; opendocs is `MIT`.
  Linking it into an MIT package imposes LGPL obligations on the combined
  work. This alone is sufficient to reject it.
- **Technical fit.** `detectRecursiveAndCompile` specializes procs with
  recursive arithmetic patterns and installs a `{.global.}` VM singleton
  via `installJit`. Spreadsheet evaluation needs lazy reference
  resolution against a cell grid, not trace-JIT'd recursive numeric
  kernels. The dynasm dependency and process-global VM would also be a
  heavy addition to a package whose current native surface is harfbuzz
  and libvips.

Plan 20 therefore specifies a tokenizer, evaluator, and bytecode VM
inside `src/opendocs/xlsx/calc/`.

**excelize's external tokenizer deps** (`xuri/efp`, `xuri/nfp`). Plan 20
specifies an in-repo formula tokenizer and format-code tokenizer. Nim
tokenizers for both grammars are small; the alternative is two more
package dependencies for what is a bounded grammar each.

## Cross-cutting notes

**`sheet.nim` is the seam for tier 1.** Every read-side gap is an element
`parseSheet` (`sheet.nim:42`) does not visit: it reads `dimension` and
`sheetData` and nothing else. Merges, `<cols>`, hyperlinks, `<legacyDrawing>`
all live on the same element and belong in one pass, not four.

**The oracle-dump pattern already works.** Phase B's `phase_b_matrix.txt`
is a `GetCellValue` dump from excelize, checked in, and asserted at
`t_xlsx.nim:294`. Plans 16, 17 and 20 all extend it. The pattern is
already proven; the fixture strategy is in plan 21.

**Locale data is the long pole in wall-clock terms, not design terms.**
`numfmt.go` lines 729-1213 are 416 LCID entries in 76 KB of pure data;
lines 5753-7498 are 1,746 lines of month-name functions in 52 KB. No
design work is needed, and no amount of cleverness shortens it. Plan 16
sequences it last within its own tier and plan 21 supplies the per-locale
oracle dump that makes the data entry verifiable.

**Limits are already load-bearing.** `XlsxMaxRows`/`XlsxMaxCols` (1,048,576
and 16,384) and the two spill constants exist and are honored. `XlsxReadOpts`
gives the caller byte-level control over spill. Add caps in the same style:
named, defaulted, overridable, documented as a guard.

**Read-side fidelity over excelize where they disagree.** excelize repairs
some inputs silently (auto-fixing missing SST `count`/`uniqueCount` at
`rows.go:525`). Prefer raising `XlsxError`, matching the existing
`reader.nim:22` OLE behavior. Where excelize's behavior is a genuine
interop requirement rather than a convenience, note it in the plan.

## Risks

- **Locale parity is unverifiable without generated oracles.** 416 locales
  of month and weekday names cannot be eyeballed. Without a per-locale
  excelize dump this becomes 76 KB of untrusted data. Plan 21 exists
  specifically to make it verifiable, and should land first.
- **Enforcing `MaxXlsxXmlDepth` is a behavior change.** Some file that
  parses today will raise once the constant is wired up. Excel's own
  limit is 64, so conformant files should be unaffected, but this has not
  been measured against the fixture corpus. Plan 18 measures before
  enforcing.
- **Calc is a research project wearing a feature flag.** 458 functions,
  3D references, implicit intersection, iterative calculation, and a
  criteria evaluator is a lot of surface where a subtle bug returns a
  plausible wrong number rather than an error. The mitigation is that
  cached values remain the default and evaluation is opt-in, so a wrong
  answer requires a caller to ask for one.
- **Shared formulas are unaddressed.** `<f t="shared" si="n" ref="...">`
  means the first cell carries the text and the rest carry only `si`.
  `getCellFormula` returns empty for those. This affects tier 1 (correct
  read-side) and tier 4 (calc) and should not be left to plan 20 alone.
- **Writer deferral leaves round-trip untestable.** Every fixture is
  read-only, so a parse/re-serialize byte comparison is impossible. Plan
  21 records this as the reason the excelize dumps are the only available
  oracle.