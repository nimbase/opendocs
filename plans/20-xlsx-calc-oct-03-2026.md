# XLSX formula engine (plan, 2026-10-03)

Tier 4. Phase E from plan 05, which flagged it as "2-4x the other phases
combined" and optional. That flag is superseded: the engine is committed,
with full excelize parity (458 functions) as the target.

Evaluation is **opt-in**. Cached values remain the default, so a wrong
answer requires a caller to ask for one.

## Locked decisions

- **Full parity: 458 functions.** Not a subset, not timeboxed. Financial
  and engineering are included.
- **The VM is ours, not `vancode`'s.** Rejected on licensing (LGPL-3.0
  against opendocs' MIT) and on fit; see the index's "Rejected
  dependencies".
- **Evaluation is opt-in and per-call.** `calcCellValue` takes a cell and
  returns a result. Nothing in the read path changes behaviour because the
  engine exists.
- **Cached value first.** When a cell has a cached `<v>` and the caller did
  not ask for evaluation, return the cached value. Excel's own value is
  the best available answer for a cell we cannot evaluate.
- **Unknown function is `#VALUE!`**, matching Excel, not an exception. An
  unsupported function is a normal condition, not an error.
- **Excel semantics over mathematical purity** wherever they differ. The
  1900 leap-year bug is the canonical case: reproduce it exactly.
- **No array formulas, no `LET`/`LAMBDA`.** excelize documents both as
  unsupported (`calc.go:415-418`). Reproducing that boundary is cheaper
  and more honest than half-implementing dynamic arrays.

## Why last

Calc is tier 4 because its resolver depends on tier 1 and tier 3 being
correct first, and rebuilding it is expensive.

A formula references the grid. That grid is currently wrong in ways that
matter:

- **Merges** (plan 15) decide whether a referenced span has one value or
  several. Excel resolves a reference to a merged range to the anchor.
- **Defined names** (plan 15) are the `Sheet1!$A$1` indirection used
  pervasively in real workbooks. A resolver without them fails on almost
  every real file.
- **Whole-column references** (`A:A`) must clamp to the data extent, which
  means knowing the extent, which means correct geometry from plan 15.
- **Row and column insertion** shifts references; `adjust.go` (1,168 lines)
  is entirely about this and is write-side, so we skip it, but the read
  resolver must at least not assume a stable layout.

Building the engine first means building its resolver twice. This is the
same reasoning that put P4b below the encryption writer in the PDF
roadmap: infrastructure before the block that needs it.

## Architecture

Four stages, matching excelize's `calc.go` structure but written against
this package's types.

### 1. Tokenizer

excelize delegates to `xuri/efp` (`calc.go:956`). We write ours.

```nim
type
  TokKind* = enum
    tkNum, tkStr, tkBool, tkErr, tkRef, tkName, tkOp, tkLParen,
    tkRParen, tkComma, tkColon, tkPercent, tkLBrace, tkRBrace,
    tkSheetSep, tkSpaceOp
  Tok* = object
    kind*: TokKind
    s*: string          ## raw text
    num*: float64
    fn*: XlsxFunc       ## resolved for tkName
```

Hard cases, all present in real files:

- **String escaping in literals** (`"a""b"` is one string; a backslash is
  literal, unlike C).
- **`Sheet1!A1` versus `'My Sheet'!A1`** versus the 3D forms
  `Sheet1:Sheet3!A1` and `'S 1:S 3'!A1`. Quoting rules are fiddly: a
  quoted sheet name containing `!` must have doubled quotes.
- **The `%` operator** is postfix in Excel and unlike anything in most
  languages; whitespace is the intersection operator.
- **`#REF!`, `#VALUE!`, `#DIV/0!`, `#N/A`, `#NAME?`, `#NUM!`, `#NULL!`**
  are both literals and results. The error constants live at `calc.go:49`.
- **Union and intersection operators** (`,` and space in reference
  arguments) are listed as unimplemented by excelize (`calc.go:1031`).
  Reproduce that.
- **Array constants** `{1,2;3,4}` with `;` for rows. excelize's
  tokenizer handles them; keep it.

### 2. Parser

Precedence-climbing or shunting-yard. excelize uses shunting-yard with five
stacks (`evalInfixExp`, `calc.go:1032`) and a precedence table at
`calc.go:119`:

| Op | Precedence |
|---|---|
| comparison | 1 |
| `&` | 2 |
| `+` `-` | 3 |
| `*` `/` | 4 |
| `^` | 5 |
| unary `-` | 6 |
| `(` | 0 |

Note `^` is **left**-associative in Excel, unlike most languages where it
is right-associative. This is a real trap: `2^3^2` is 64 in Excel and 512
in mathematics. Assert it.

Produce an AST rather than evaluating during parse. A typed AST is
independently valuable for inspection and for plan 15's shared-formula
reference translation, which needs to rewrite references in a formula.

### 3. Evaluator

```nim
type
  XlsxValueKind* = enum
    xvNumber, xvString, xvBool, xvError, xvList, xvMatrix, xvEmpty
  XlsxValue* = ref object
    case kind: XlsxValueKind
    of xvNumber: num: float64
    of xvString, xvError: str: string
    of xvBool: bval: bool
    of xvList, xvMatrix: items: seq[XlsxValue]
    of xvEmpty: discard
```

Seven kinds, matching excelize's `formulaArg` (`calc.go:286-294`).
Coercion helpers (`Value`/`ToNumber`/`ToBool`/`ToList`, `calc.go:310-397`)
because Excel coerces more often than a type system would allow, and
because the coercion order is observable.

Reference resolution: `parseReference` (`calc.go:1650`), `parse3DReference`
(`calc.go:1696`), `split3DReference` (`calc.go:1721`),
`expand3DSheetRange` (`calc.go:1762`), `cellResolver` (`calc.go:1810`),
`rangeResolver` (`calc.go:1872`). Whole-column and whole-row refs clamp to
actual data extent (`calc.go:1905`), which requires plan 15's geometry.

Cached results keyed by (sheet, cell, formula-text-hash), following
excelize's `sync.Map` caches (`calc.go:1824-1833`). Invalidated on close,
not on mutation, since there are no mutations.

### 4. VM

excelize dispatches by reflection (`callFuncByName`, `calc.go:1973`):
`reflect.MethodByName(name)` per call. In Nim that maps to
`method(calls, name)` or a generated dispatch table.

A dispatch table is better here, and the reason is the function count.
458 entries in a case statement compiles to a jump table; `method()` does
a linear scan with string comparison per call. Since the reference map from
name to function is fixed, generate `registerFuncs` once and index by a
resolved id.

**A bytecode VM is not required and this plan does not build one.** The
rejected-vancode reasoning applies to the whole engine: the hot path is
reference resolution against a cell grid, not arithmetic. A tree-walking
evaluator over a real AST is the right shape, and it is debuggable, which
matters more than speed for a feature whose failure mode is a plausible
wrong number.

Structure:

```
src/opendocs/xlsx/calc/
  token.nim      tokenizer
  ast.nim        node types, precedence table
  parse.nim      parser
  value.nim      XlsxValue, coercion
  resolve.nim    references, 3D ranges, whole-column clamping
  func.nim       registration and dispatch
  math.nim       math and trig
  stat.nim       statistical
  text.nim       text
  datetime.nim   date and time
  lookup.nim     lookup and reference
  logical.nim    logical, conditional, information
  financial.nim  financial
  engineering.nim engineering
  db.nim         database
```

## Function surface

458 functions across nine categories. excelize's section headers in
`calc.go`:

| Category | `calc.go` line | Count | Notes |
|---|---|---|---|
| Engineering | 2066 | 54 | BESSEL, BITAND/SHIFT, COMPLEX, CONVERT, DEC/HEX/OCT, 28 `IM*` complex functions |
| Math and trig | 3871 | 85 | includes MDETERM/MINVERSE/MMULT |
| Statistical | 6418 | 136 | largest category; the distributions |
| Information | 11674 | 19 | includes `ISFORMULA` |
| Logical | 12062 | 10 | |
| Conditional | 15001 | 1 | `IF` alone |
| Date and time | 12332 | 25 | incl. `NETWORKDAYS.INTL`, `WORKDAY.INTL` |
| Text | 13732 | 39 | incl. `TEXTAFTER`/`TEXTBEFORE`, `UNIQUE`; `DBCS` is ASCII-only |
| Lookup and reference | 15061 | 17 | incl. `XLOOKUP`, `ANCHORARRAY` |
| Web | 16191 | 1 | `ENCODEURL` |
| Financial | 16206 | 57 | |
| Database | 19094 | 14 | via a `calcDatabase` struct |

**Excluded**, matching excelize: `FILTER`, `SEQUENCE`, `RANDARRAY`,
`SORT`, `SINGLE`, `XMATCH`, `TEXTSPLIT`, `VSTACK`, `HSTACK`, `TOCOL`,
`WRAPROWS`, `LET`, `LAMBDA`. All need dynamic-array or spill semantics that
excelize does not have either.

**Included despite looking exotic**: `UNIQUE`, `SORTBY`, `XLOOKUP`,
`ANCHORARRAY`, `ARRAYTOTEXT`, `VALUETOTEXT`: excelize has them as
array-consuming functions without full spill support.

`DISPIMG` (WPS embedded image, `calc.go:19440`) is a stub upstream. Omit
rather than stub.

### Criteria evaluation

`SUMIF`, `SUMIFS`, `COUNTIF` and the database family all need criteria
parsing: `">5"`, `"<>x"`, `"*wildcard*"`, `"~*"` escapes, `"?x"`.
`formulaCriteriaParser` (`calc.go:1987`) and `formulaCriteriaEval`
(`calc.go:2036`), with a regexp path.

This is more load-bearing than its line count suggests, because criteria
are where Excel's string-to-value coercion is most surprising and where a
naive implementation silently miscounts.

### Date and time

Excel serials, not `datetime`:

- **1900 system** (default) with the leap-year bug: Excel believes
  1900-02-29 exists, so serials after 1900-03-01 are one day ahead of the
  proleptic Gregorian calendar. excelize compensates at `date.go:53-60`
  and skips the correction entirely under the 1904 system.
- **1904 system** (`workbookPr/@date1904`, already read at
  `workbook.nim:58`). Offsets differ by 1462 days.
- `DATE`, `DATEVALUE`, `TIME`, `TIMEVALUE`, `YEARFRAC` with its basis
  argument (0 US 30/360, 1 actual/actual, 2 actual/360, 3 actual/365,
  4 European 30/360), `WEEKNUM`, `ISOWEEKNUM`, `DAYS360`, `EDATE`,
  `EOMONTH`, `NETWORKDAYS.INTL`, `WORKDAY.INTL` with holiday arrays.

Note `numfmt.nim` already has `serialToCivil` and `civilFromDays` for
rendering. Reuse them rather than writing a second date conversion, and
confirm the 1900/1904 split matches what the renderer does, since a
disagreement between formatter and evaluator is a silent wrong answer in
one direction only.

### Caching and cycles

- `f.calcCache`, `f.calcRawCache`, `f.formulaArgCache` in excelize
  (`calc.go:943`, `:1824`). Ours: one table keyed by cell plus a formula
  text hash.
- **Iterative calculation** for circular references, bounded by
  `maxCalcIterations` (`ctx.iterations`, `calc.go:1824`). Required:
  circular references are legal in Excel when iteration is enabled, and
  some real workbooks rely on it.
- Without iteration enabled, a cycle is `#REF!`, not a hang. The
  in-progress marker must be set **before** recursing.
- **Volatile functions** (`NOW`, `TODAY`, `RAND`, `RANDBETWEEN`,
  `OFFSET`, `INDIRECT`) must not be cached. `calcchain.go:87` reads
  `volatileDependencies.xml` for this; simpler is to mark them volatile
  and skip the cache.

### calcChain.xml

**Never read.** Tolerant skip, per plan 05 line 27. Excel recalculates
without it and it is a cache, not an input. excelize only writes it.

## API

```nim
proc calcCellValue*(f: XlsxFile, sheet, cell: string): string
proc calcCellValue*(f: XlsxFile, sheet, cell: string,
                    opts: XlsxCalcOpts): string
type XlsxCalcOpts* = object
  useCache*: bool = true
  maxIterations*: int = 100
  maxDepth*: int = 64
  maxCellsEvaluated*: int = 1_000_000
```

- Returns a formatted string, consistent with `getCellValue`. Add
  `calcCellRaw` for an unformatted result when formatting fidelity is in
  doubt.
- **`maxCellsEvaluated` is mandatory.** A formula referencing `A:A` on a
  million-row sheet is legal and must not be able to hang the process.
- Errors come back as Excel error strings (`#DIV/0!`), not exceptions.
  This is Excel parity and it means a caller can render a spreadsheet
  faithfully. An exception path is still needed for genuine internal
  faults, distinguished by type.
- Nested depth cap for a dependency chain like `A1=B1+1, B1=C1+1, ...`.

## Phases

1. **P1 tokenizer + AST + parser**, with round-trip properties. Lands
   plan 15's shared-formula reference translation on top of it immediately,
   since that was deferred there.
2. **P2 value model, coercion, reference resolution**, single-cell
   arithmetic, comparison, `&`, ranges, whole-column clamping.
3. **P3 math and trig (85)**, logical (10), conditional (1), information
   (19). 115 functions.
4. **P4 text (39)** and lookup and reference (17). 56 more.
5. **P5 date and time (25)**, sharing `numfmt.nim`'s conversions.
6. **P6 statistical (136)**. Largest single phase; the distributions are
   independent of each other and parallelize well.
7. **P7 financial (57).**
8. **P8 engineering (54), database (14), web (1).**
9. **P9 caching, cycles, volatility, limits.** Should really be earlier;
   it is listed last because retrofitting a cache after 458 functions is
   easier than retrofitting correctness into one. Move it to P2 if the
   first phases show it is load-bearing.

Phases 6-8 are where the calendar should be checked: 207 functions of
distributions and finance, all of which are individually easy and
collectively where a subtle error is most likely, since a wrong `NORMDIST`
returns a plausible number.

## Fixtures and oracles

- `calc_arith.xlsx`: precedence, associativity (including `2^3^2 == 64`),
  unary minus, percent, error propagation.
- `calc_refs.xlsx`: relative and absolute refs, cross-sheet, 3D ranges,
  whole-column and whole-row clamping, ranges with empty interiors.
- `calc_criteria.xlsx`: `SUMIF`/`COUNTIF` with every criteria form
  including wildcards and escapes.
- `calc_dates.xlsx`: 1900 and 1904 systems, the leap bug boundary,
  `YEARFRAC` with all five bases.
- `calc_errors.xlsx`: every error type, propagation through nesting,
  unknown function.
- `calc_cycles.xlsx`: circular refs with iteration on and off.
- `calc_volatile.xlsx`: `NOW`/`RAND` not cached across calls.
- `calc_shared.xlsx`: shared formulas whose expansion changes the value
  when evaluated, proving plan 15's translation is right.

**The oracle is excelize's `CalcCellValue`**, dumped one cell per row,
which gives a 458-function differential corpus in a single workbook. That
is the single most valuable fixture in this plan and it should be built in
P3, not P9, so the remaining 340 functions each land against a known
answer rather than against each other.

Generate with excelize where it can express the function, hand-write the
rest. Record any function where our answer differs from excelize's and
decide which is right; do not silently accept the reference.

## Testing

`tests/t_xlsx_calc.nim`, split by category as it grows.

- **Differential against excelize for all 458 functions.** The corpus is
  the test suite.
- **Excel semantics asserted independently of excelize**, for the cases
  where Excel is the authority and excelize might be wrong: `^`
  associativity, the 1900 leap bug, `ROUND` half-away-from-zero,
  `SUMIF` criteria coercion, text-to-number coercion of `"1e3"`.
- **Every function must return a wrong answer when given the wrong
  argument type**, or raise. A function that ignores a bad argument is
  worse than one that errors.
- `maxCellsEvaluated` must actually trip: a formula over `A:A` on a large
  sheet returns an error promptly rather than hanging.
- Cycles: off gives `#REF!` within the depth cap; on converges or reports
  non-convergence.
- Volatile functions are asserted *not* to return the same value twice.
- A total-evaluated-cell counter in tests catches accidental quadratic
  behaviour in reference resolution, which is a plausible failure given
  excelize's own note that whole-column refs are O(cells) at
  `calc.go:1905`.

## Risks

- **A wrong plausible number is the failure mode.** Unlike a parser
  error, a bad `NORMDIST` is invisible. Mitigation is the differential
  corpus plus asserting against Excel semantics rather than only against
  excelize.
- **458 functions is a lot of surface for a review.** Group by file and
  require the oracle before merge, so each function is verified rather
  than the batch.
- **The 1900 leap bug will be "fixed" by someone.** It is not a bug in
  our code; it is Excel's behaviour and reproducing it is the
  requirement. Comment it with the worked example and test it.
- **`^` left-associativity** is the same class of trap and equally likely
  to be corrected by mistake.
- **Coercion is where Excel is most surprising** and where a "clean" type
  model diverges from observed behaviour. Expect to iterate here more than
  on any other part.
- **Caching plus volatility plus cycles interact.** A cache that is wrong
  for `NOW` or for a converging cycle produces results that depend on call
  order, which is the hardest class of bug to test. Keep the cache optional
  and off in some tests.
- **Scope creep from dynamic arrays.** `UNIQUE` and `XLOOKUP` work without
  spill, which makes it tempting to add `FILTER` and `SORT`. Resist:
  excelize does not have them, and spill detection (`#SPILL!`) is defined
  at `calc.go:49` but never used, so there is no reference for it.
- **Reflective dispatch in excelize is O(n) per call.** Do not copy the
  pattern; a generated table is better and it matters at 458 functions.
- **This plan can run indefinitely.** The oracle corpus is what makes each
  increment verifiable, so build it first even though it is not a
  user-visible feature. Without it, "458 functions" is a number with no
  definition of done.