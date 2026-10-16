# XLSX parser robustness (plan, 2026-10-03)

Tier 2. Malformed-input handling, depth limits, and fixture coverage.
Nothing here adds a user-visible feature.

## Locked decisions

- **Enforce the depth cap before parsing, not after.** See "The depth
  problem" below: a post-parse check does not prevent the stack overflow
  it is meant to prevent.
- **Cap depth by default; make it overridable, not removable.** Match the
  existing `XlsxReadOpts` style. A caller who genuinely needs deeper XML
  can raise it.
- **Fail loudly.** Malformed input raises `XlsxError` naming the part. No
  silent repair, with one documented exception below.
- **Auto-repair is allowed only where Excel itself requires it**, and each
  repair gets a test and a comment. This is a change from excelize, which
  silently fixes more.
- **The malformed corpus is checked in as generated files**, not built
  inline in tests, so the shapes are inspectable.

## The depth problem

`base.nim:14` declares:

```nim
MaxXlsxXmlDepth = 64 ## nesting cap against hostile documents
```

**Nothing references it.** Grep confirms zero uses. The comment asserts a
guarantee the code does not provide, which is worse than no constant: a
reviewer reading it will believe XML depth is bounded.

Enforcing it is not as simple as walking the DOM afterwards, because the
overflow happens before a DOM exists. `openparser/xml.nim:1285` builds the
DOM recursively:

```nim
of xtkTagOpen:
  var child: XmlNode
  p.parseHook(child)          # recurses per element
  elem.children.add(child)
```

There is no depth counter in `parseHook` and no depth option in
`XmlOptions`. A sheet part with hundreds of thousands of nesting levels
overflows the stack during `fromXml`, which is a crash rather than an
`XlsxError`. Note that `openparser/json.nim:49` *does* have a `maxDepth`
option, so this is a gap in the XML parser specifically.

Three options, and this plan takes the first:

1. **Pre-parse depth scan (chosen).** One forward pass over the raw part
   bytes counting element open/close to find the maximum depth, raising
   before `fromXml` is called. Linear, no allocation beyond a counter,
   and it works with the current openparser. It duplicates a trivial scan
   of the byte stream, which is a fair price for not crashing.
2. **Add `maxDepth` to `openparser`'s XML `XmlOptions`.** Cleaner and
   reusable, but it changes a shared dependency used by docx, pdf and
   everything else, so it needs its own change and its own tests there.
   Worth proposing upstream; not a prerequisite.
3. **Post-parse DOM walk.** Does not work. The stack is already gone.

Option 2 is the right long-term answer and option 1 is the right
pragmatic one. Record that in the plan so the duplication has a
justification and an expiry condition.

### Implementation

```nim
proc checkXmlDepth*(data: string, part: string, maxDepth: int)
  ## Raises XlsxError if any element nesting in `data` exceeds `maxDepth`.
  ## Runs before fromXml: the DOM builder recurses per element, so a
  ## post-parse check would arrive after the stack overflow it prevents.

proc maxXmlDepthOpts* = XlsxReadOpts(...)
```

- Scan for `<tag`, `/>`, `</tag`, skipping comments `<!--`, CDATA
  `<![CDATA[`, processing instructions `<?`, and DOCTYPE `<!`.
- Text content cannot open elements, so a raw `<` inside a text node is
  either malformed or part of a CDATA/comment and is skipped with the
  construct it belongs to.
- Namespaced tags (`<x:row>`) count the same.
- Self-closing tags do not increase depth.
- Unbalanced closes are the parser's problem, not this scan's. The scan
  reports a depth *exceeded* error and otherwise defers.
- Depth 64 matches Excel's own limit and the existing constant. Raise the
  ceiling before lowering it; measured against the corpus first.

### Do not lower the cap until measured

Enforcing 64 is a behaviour change: some file that parses today will
raise. Excel's own limit is 64, so conformant files should be unaffected,
but that is an argument, not a measurement.

Before enforcing, measure the maximum depth across every checked-in
fixture plus a set of real workbooks. If the corpus max is, say, 12, then
64 is comfortable. If some legitimate producer nests deeper, raise the
cap rather than rejecting that file, and record why.

## Work items

### 1. Depth cap

As above. Add `maxXmlDepth*: int = MaxXlsxXmlDepth` to `XlsxReadOpts`
alongside the existing spill controls. `<= 0` means unlimited, matching
the `spillThresholdBytes` convention at `types.nim:76`.

Wire into `parsePartXml` (`base.nim:70`), which every XML part read
already funnels through, so one call covers workbook, sheets, styles,
shared strings and everything the tier-1 plans add.

### 2. Integer overflow in cell values

excelize carries a fixture for this (`OverflowNumericCell.xlsx`, cell
value `8595602512225`) because int32 wraps. Check what we do: `Cell.raw`
is a string, so we are safe by construction, but `floatAttr`
(`base.nim:59`) and any future typed numeric field are not.

Add a test asserting that a 13-digit value round-trips exactly, and that
`scientific` and `exponent` notation (`1.23456789012345678E+30`) survives
both `parseFloat` and the numfmt path. A `float64` cannot hold 20
significant digits exactly, so the raw string is the only lossless
representation; confirm `getCellValue` with `rawCellValue` keeps it.

### 3. Silent repairs to reconsider

excelize repairs several things silently. For each, decide explicitly:

| excelize behaviour | Location | Our decision |
|---|---|---|
| Auto-fix missing SST `count`/`uniqueCount` | `rows.go:525` | **Accept.** Excel tolerates it and files exist without it. |
| Add a missing SST relationship/content-type | `rows.go:537` | **Reject.** A reader should not fabricate a package. |
| Trim the `_xHHHH_` escape from shared strings | `lib.go:827` (`bstrUnmarshal`) | **Keep.** Non-standard but widely produced; excelize parity. |
| Whole-column refs clamp to data extent | `calc.go:1905` | **Keep.** Excel behaves this way. |
| Unknown function becomes `#VALUE!` | `calc.go:1983` | **Keep**, see plan 20. |

Anything not in this table that we discover should raise rather than
repair. Record each decision in the code with a one-line rationale.

### 4. Malformed corpus

Currently `t_xlsx.nim:180` has a six-test `failure modes` suite covering
not-a-zip, OLE magic, missing workbook, bad sheet XML, out-of-range SST
index, and a dangling sheet rel. That is a good start and it is inline in
the test file.

Grow it to cover the shapes that actually break readers:

- **Missing parts that are required**: no `xl/workbook.xml`, no
  `[Content_Types].xml`, no `_rels/.rels`, no `xl/_rels/workbook.xml.rels`.
- **Empty and zero-length parts**: a 0-byte `sheet1.xml`, a 0-byte
  `sharedStrings.xml`.
- **Truncated XML** at every stage: mid-tag, mid-attribute, mid-CDATA,
  after the root element.
- **Hostile XML**: 1M nesting levels (must raise, not crash), a
  billion-laughs entity expansion attempt (must not expand; check that
  openparser does not resolve entities, and if it does, that is an
  upstream bug to report), a 100 MB attribute value.
- **Malformed rels**: `Target` pointing outside the package (`../evil.xml`
  or an absolute path), a `TargetMode="External"` sheet rel, a cycle in
  the rel graph.
- **Cell-level**: `r="A0"`, `r="XFE1"` (beyond `XlsxMaxCols`), `r="A"` with
  no row, a row index of 0 or negative, `t="z"` (unknown type), a
  numeric `<v>` that is not a number, an `<is>` cell with no `<t>`.
- **SST**: index past the end (already covered), negative index,
  duplicate entries, an `<si>` with only `<rPh>` and no text.
- **Styles**: `cellXfs` index out of range (already covered), `numFmtId`
  referencing an undefined custom format, a cyclic theme reference.
- **Zip-level**: the existing bad-zip case, plus a zip whose central
  directory disagrees with its local headers, and a part with two
  differing entries at the same path.

Each becomes a checked-in `.xlsx` under `tests/fixtures/xlsx/malformed/`
so the byte shape is inspectable, with the test asserting the specific
error message. Test *which* error, not merely that something failed,
otherwise the suite passes on the wrong failure.

### 5. Fixture coverage for variants

Plan 05 line 71 calls for "checked-in fixtures per ext". Reality: only
`.xlsx` fixtures exist. The `.xlsm` coverage at `t_xlsx.nim:415` is a
synthetic package with a **7-byte** `vbaProject.bin` whose bytes
(`0xD0CF11E0 AABBCC`) are not even a valid CFB header.

Add real fixtures for `.xlsm`, `.xltx`, `.xltm`, `.xlam`. The plan 05
variant matrix at lines 45-52 says the matrix is validation and
passthrough only, since all variants ride the same zip-plus-rels flow, so
the substantive assertion is that each opens and reads identically to its
`.xlsx` equivalent. That is worth asserting explicitly rather than
assuming.

Macro-enabled variants need a real `vbaProject.bin` for plan 19 anyway;
generate once and reuse.

### 6. Spill and zip-bomb boundaries

`DefaultXlsxSpillThresholdBytes` (64 MiB) and `DefaultXlsxSpillCapBytes`
(512 MiB) exist and are honored. Verify the boundaries rather than trusting
them:

- A package that inflates past the threshold spills and reads identically.
  Covered at `t_xlsx.nim:438`, keep it.
- A package that would exceed the **cap** raises `XlsxError` and cleans up
  its spill directory. Assert no temp files are left behind on the failure
  path, since `=destroy` (`base.nim:125`) only runs on GC and an exception
  between `newSpillDir` and the archive open could leak.
- A highly compressed part (a 1 MiB zip bomb of zeros) must hit the cap
  rather than allocate unboundedly. This is the real zip-bomb test and it
  is not the same as the spill test.

## Reference map (excelize -> Nim)

| excelize | Nim target | Notes |
|---|---|---|
| `OverflowNumericCell.xlsx` | our own fixture | excelize's int32 issue; ours is string-based |
| `BadWorkbook.xlsx` (404-byte workbook) | our own | `xl/workbook.xml` missing `Sheets` |
| `test/encryptAES.xlsx`, `encryptSHA1.xlsx`, `encryptSHA512.xlsx` | referenced | encrypted input; must raise, see plan 19 |
| `rows.go:525` SST auto-repair | decide per table | |
| `lib.go:33` `checkFileSize` | our spill cap | different mechanism |
| `json.nim:49` `maxDepth` | precedent for option 2 | XML lacks the equivalent |

## Phases

1. **P1 measure depth across the corpus.** Before changing any behaviour.
2. **P2 pre-parse depth scan** and the `XlsxReadOpts` option.
3. **P3 hostile-XML fixtures**, including the deep-nesting case.
4. **P4 zip-bomb and spill-cap boundaries.**
5. **P5 variant fixtures** for `.xlsm`/`.xltx`/`.xltm`/`.xlam`.
6. **P6 numeric precision fixtures.**
7. **P7 the repair-decision table**, reviewed case by case.

## Testing

Split the malformed corpus into `tests/t_xlsx_malformed.nim` rather than
growing `t_xlsx.nim` past 700 lines. It will be assertion-dense and
motivated differently from the behavioural suites.

Every test asserts a **specific** message. `check:` with the exact
`XlsxError` text, or at minimum the part name, so a test cannot pass
because some unrelated error occurred first.

The deep-nesting test is the one that must not be flaky: build the input
in memory at a depth above the cap, confirm the raise, and **also**
confirm the process survives (no stack overflow). If it segfaults, the
scan is not running before the parse.

Assert that no temp files leak on every failure path, using a spill
directory the test controls and can inspect.

## Risks

- **Enforcing depth 64 could reject real files.** Mitigated by P1
  measuring before P2 changes anything, and by allowing the cap to be
  raised. Do not skip P1.
- **Duplicating a depth scan** is technical debt against `openparser`.
  Record the upstream fix (option 2) as the expiry condition so it is a
  deliberate stopgap rather than an unnoticed fork.
- **Entity expansion is unverified.** If openparser resolves entities, a
  billion-laughs input is a memory bomb. Check before assuming; if it
  does resolve them, that is an upstream security issue and belongs in a
  report, not a workaround here.
- **Explicit error-message assertions are brittle** against upstream
  openparser message changes. Prefer asserting the part name and error
  type over exact prose, and keep one or two exact-message tests for the
  messages this package owns.
- **Variant fixtures are close to busywork** given the shared flow. The
  value is in proving the flow is genuinely shared, so keep them but do
  not gold-plate: one readable file per variant is enough.
- **The repair table will grow.** Every "silently fix it" decision is a
  future compatibility argument. Keep it in the plan, not in a comment
  someone will not find.