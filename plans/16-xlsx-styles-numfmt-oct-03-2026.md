# XLSX custom number formats and styles (plan, 2026-10-03)

Tier 1, workstream 2 of 3. The largest mechanical block in the roadmap.
Full excelize parity including locale data is a committed decision.

## Locked decisions

- **Full locale parity is committed.** 416 LCID entries, month and
  weekday names, AM/PM strings. No subsetting.
- **The format-code tokenizer is ours.** excelize delegates to
  `xuri/nfp`; we write a tokenizer for the format-code grammar in-repo.
  The grammar is bounded and adding a package dependency for it is not
  worth the coupling.
- **Unrenderable formats return the raw value, as today.** That is
  excelize's documented behaviour (`numfmt.go:5261`) and it is the right
  fallback. The change is that it becomes *visible*: a caller can ask
  whether a format was applied.
- **Colour sections render as text, not ANSI.** `[Red]` is a display
  attribute with no meaning in a string. Parse and drop it.
- **Enriched flags** (`[$-409]`, `*`) are interpreted for locale
  selection but never emitted.
- **`numfmt.nim` grows; `styles.nim` gains the missing parts.** Formats
  and style records belong to different files and should stay there.

## Work items

### 1. Custom format code tokenizer

`numfmt.nim:891` is the whole of current custom support:

```nim
if f.styles.numFmts.hasKey(id): return rawV # custom: Phase C
```

Every custom code returns the raw stored value. The 893-line file already
has the rendering machinery for builtin codes, so the gap is parsing, not
number printing.

A format code is up to four sections separated by `;`:

```
positive ; negative ; zero ; text
```

Section selection (`getValueSectionType`, excelize `numfmt.go:7898`)
picks by sign, with the negative section rendering the absolute value
unless it carries its own sign. An empty section falls back to
`General`. A two- or three-section code applies its last section to
zeros as well.

Tokens to recognize, following excelize's `supportedTokenTypes`
(`numfmt.go:689`), 21 kinds:

| Group | Tokens |
|---|---|
| Number | `0`, `#`, `?`, `.`, `,`, `%` |
| Date/time | `yyyy`, `yy`, `mmmm`, `mmm`, `mm`, `m`, `dddd`, `ddd`, `dd`, `d`, `hh`, `h`, `ss`, `s`, `AM/PM`, `A/P`, elapsed `[h]`, `e` (era) |
| Fraction | `# ?/?`, `# ??/??`, denominators via `?/?` |
| Scientific | `E+`, `E-`, `0.00E+00` |
| Text | `@`, `\"literal\"`, `\\x`, `_x` (skip-width), `*x` (fill) |
| Conditional | `[<0]`, `[<=5]`, `[>=x]` colour conditions |
| Locale | `[$-409]`, `[$USD]`, `[$€-42D]`, `[DBNum1]` |

The tokenizer returns sections of tokens rather than strings, and it must
be **round-trippable**: `render(tokens) == original` for every code in
the fixture corpus. That property is what makes the locale data verifiable
later, because a tokenizer that loses tokens silently corrupts output.

### 2. Rendering

Reuse what exists. `formatBuiltin` (`numfmt.nim:835`) already handles
fractions via continued fractions (`continuedFraction`, `renderFraction`)
and scientific notation, so custom codes plug into the same helpers rather
than duplicating them.

Additions:

- **Conditionals** (`[>100]"high";"low"`): evaluate per section and select.
- **Thousands separators**, respecting the trailing-comma *scaling* rule:
  a comma after the last digit placeholder divides by 1000 per comma,
  which is different from grouping and is a classic source of off-by-1000.
- **Scientific** requires the exponent placeholder to be exactly two
  digits (`E+00`); excelize returns raw otherwise (`numfmt.go:5590`).
- **Big-value fallback** for more than 15 significant digits.
- **Text section** and `@` placeholder substitution for string cells.
- **Escapes**: `\"`, `\\`, `\_`, `\*`, and `;` inside quotes.

`tokenizeDateCode` (`numfmt.nim:503`) and `renderDateCode` (`numfmt.nim:657`)
already tokenize and render date codes, but for builtin ids only. Generalize
them to accept a token list so custom and builtin paths share one renderer.
That is the single most valuable refactor in this plan: two renderers for
the same grammar is how they drift apart.

### 3. Locale data (the bulk)

This is data entry, not design. From `numfmt.go`:

| Data | Location | Size |
|---|---|---|
| `supportedLanguageInfo` LCID map | lines 729-1213 | 416 entries, 485 lines, 76 KB |
| `localMonthsName*` functions | lines 5753-7498 | 162 funcs, 1,746 lines, 52 KB |
| `weekdayNames*` vars | throughout | ~314 vars |
| `monthNames*` vars | throughout | ~275 vars |
| `apFmt*` vars | throughout | ~71 vars |
| `currencyNumFmt` locale currency | lines 214-686 | 471 entries, ids 164-634 |

Shape:

```nim
type
  XlsxLocale* = object
    tags*: seq[string]
    monthsFull*, monthsAbbrev*, monthsNarrow*: array[12, string]
    weekdaysFull*, weekdaysAbbrev*, weekdaysNarrow*: array[7, string]
    amPm*: tuple[am, pm: string]
```

Storage decision: a `Table[int, XlsxLocale]` keyed by LCID, built once and
immutable, rather than 162 separate procs as excelize does. The procs exist
there to avoid a large static table; in Nim a `const` table is fine and
much easier to generate and to diff.

#### Locale resolution rules

- `[$-409]` inside a code, or `CultureInfo` in options, selects the locale.
- excelize takes the **last four hex characters** of the LCID as the
  sub-language (`3010429` fa-IR,301 becomes `0429`). Reproduce this; it is
  load-bearing for the `fa-IR,301` shape.
- `F800`/`x-sysdate`/`1010000` and `F400`/`x-systime` map to `409`.
- A tag may carry a script subtag (`az-Cyrl`, `29740`). Match on the full
  tag first, then the primary subtag, then default to `en-US`.
- Unsupported locale raises, as excelize does (`ErrUnsupportedNumberFormat`).

#### Calendar caveat

excelize is explicit that non-Gregorian calendars are not supported
(`numfmt.go:5053`): the Japanese era (`g`) and ROC era (`e`) render year
*numbers* using era tables, but the underlying serial stays Gregorian. Port
the rendering and keep the caveat. Do not pretend to a calendar
implementation.

### 4. Style records beyond number formats

`styles.nim` models `numFmts` and `cellXfs` only, and says so at line 14.
Add the rest of `xl/styles.xml`:

```nim
type
  XlsxFont* = object
    name*, family*, scheme*: string
    size*: float
    bold*, italic*, underline*, strike*: bool
    color*: XlsxColor
    vertAlign*: string        ## "superscript"/"subscript"
  XlsxFill* = object
    patternType*: string
    fgColor*, bgColor*: XlsxColor
  XlsxBorder* = object
    left*, right*, top*, bottom*: XlsxBorderSide
  XlsxAlignment* = object
    horizontal*, vertical*: string
    wrapText*, textRotation*: bool
    indent*: int
    shrinkToFit*: bool
  XlsxStyle* = object
    numFmtId*: int
    font*, fill*, border*: int      ## indices, -1 when absent
    alignment*: XlsxAlignment
proc getCellStyle*(f: XlsxFile, sheet: string, cell: string): XlsxStyle
proc getStyle*(f: XlsxFile, idx: int): XlsxStyle
```

- **Theme colours.** `<color theme="4"/>` indexes `xl/theme/theme1.xml`,
  which requires walking `<a:clrScheme>` and applying the tint/shade
  transform excelize puts in `hsl.go`. Excel's default Office theme means
  theme index 4 is `accent1`; getting this wrong recolours every themed
  workbook. Add a theme reader and a test against a known Office theme.
- **Tint** is applied in linear RGB with excelize's formula
  (`styles.go:3814`), not naive interpolation.
- **Indexed colours** (`<color indexed="12"/>`) need the legacy 64-entry
  palette. excelize's `GetBaseColor` (`styles.go:1442`) is the reference.
- **Missing style parts must not raise.** `loadStyles` (`styles.nim:12`)
  already returns empty for an absent part, and `t_xlsx.nim:359` asserts
  it. Preserve that: a workbook without `xl/styles.xml` is valid.
- **Out-of-range `s` indices read as the default style**, which is current
  behaviour and tested. Keep.

### 5. Visibility of the fallback

Add:

```nim
proc formatApplied*(f: XlsxFile, sheet: string, cell: string): bool
type XlsxFormatInfo* = object
    applied*: bool
    numFmtId*: int
    code*: string           ## builtin code or custom code
    builtin*: bool
```

The single most valuable thing in this plan. Today a caller cannot tell
whether `getCellValue` returned `"1234.57"` from a format or `"1234.5678"`
because nothing was applied. That ambiguity is exactly what plan 05's
Phase C deferral cost, and it should not survive into the shipped phase.

## Reference map (excelize -> Nim)

| excelize | Nim target | Notes |
|---|---|---|
| `xuri/nfp` (external) | in-repo tokenizer | plan 16 |
| `numfmt.go:5263` `format` | `formattedCellValue` | extend the existing entry |
| `numfmt.go:7898` `getValueSectionType` | section selection | |
| `numfmt.go:689` `supportedTokenTypes` | token kind enum | 21 kinds |
| `numfmt.go:729-1213` | `XlsxLocale` table | 416 LCIDs, `const` not procs |
| `numfmt.go:5753-7498` | month/weekday data | |
| `numfmt.go:214-686` `currencyNumFmt` | locale currency | 471 entries, ids 164-634 |
| `numfmt.go:5237` `getBuiltInNumFmtCode` | extend existing `builtinFmtCode` (`numfmt.nim:325`) | |
| `numfmt.go:5057` `getSupportedLanguageInfo` | locale resolution | last-4-hex rule |
| `styles.go:1670` `GetStyle`, `:1442` `GetBaseColor` | `getStyle` | |
| `styles.go:3814` `ThemeColor` | tint application | linear RGB |
| `hsl.go` | colour conversion | |
| `xmlTheme.go` | new theme reader | |

## Phases

1. **P1 tokenizer: done**, with round-trip property asserted over a corpus.
2. **P2 renderer generalization.** One renderer shared with builtin ids.
   Delete the duplicate date-code path rather than keeping both.
3. **P3 locale resolution** mechanism plus `en-US` and 3-4 common locales
   (de-DE, ja-JP, zh-CN), with oracle dumps.
4. **P4 en-US-adjacent locale data**, generated rather than hand-typed.
5. **P5 the remaining 400-odd locales.** Data entry, gated on plan 21's
   per-locale dump.
6. **P6 style records** and theme colours.
7. **P7 `formatApplied`** so the fallback stops being invisible.

Locales are last inside the tier on purpose: the mechanism is worthless
without an oracle, and the oracle does not exist until plan 21 lands.

## Fixtures

- `fmt_custom.xlsx`: one sheet per code family (number, date, fraction,
  scientific, text, conditional, locale, escaped literal, fill).
- `fmt_sections.xlsx`: 1-, 2-, 3-, and 4-section codes, with an empty
  section and a fallback-to-General case.
- `fmt_scaling.xlsx`: trailing-comma scaling against grouping, since
  conflating them is the classic 1000x bug.
- `fmt_locale.xlsx`: `[$-409]`, `[$-404]`, `fa-IR,301`, `az-Cyrl`,
  an unsupported LCID, and `x-sysdate`.
- `fmt_thousands.xlsx`: values above 15 significant digits, and the
  `0.00E+00` versus `E+0` exponent-width distinction.
- `styles_full.xlsx`: fonts, fills, borders, alignment, indexed colours,
  theme colours with tint.
- `styles_missing.xlsx`: no `xl/styles.xml`; out-of-range `s`.

The oracle is a `GetCellValue` dump from excelize per code, plus a
`StylesReader`-based dump for the style records. Plan 21 owns generation.

## Testing

- **Round-trip property** on the tokenizer over every code in the corpus.
  This is the cheapest high-value assertion in the plan.
- **Differential against excelize** for every fixture, cell by cell, the
  same shape as the existing `phase_b_matrix.txt` assertion at
  `t_xlsx.nim:294`.
- **Per-locale oracle** for all 416 LCIDs: generate a workbook whose date
  cells render under `[$-NNNN]` for each, dump from excelize, compare.
  Without this the locale table is untrusted data.
- `formatApplied` asserts `false` for a custom code before P2 lands and
  `true` after, so the change is visible in the diff of test results.
- Regression guard: the existing 576-cell Phase B matrix must stay green
  unchanged. If it does not, the builtin path was altered.

## Risks

- **The locale table is 128 KB of unverifiable-looking data.** Mitigation
  is entirely plan 21. If the oracle cannot be generated, ship the
  mechanism and `en-US` only, and say so in the header, rather than
  shipping 416 untested locales.
- **Shared-renderer refactor can regress shipped behavior.** Generalizing
  the two date-code paths touches every builtin date format. The Phase B
  oracle matrix is the guard; run it before and after every step of P2.
- **Theme colour errors are silent and total.** A wrong tint recolours
  every themed workbook while all values stay correct, so no value-level
  test catches it. Needs a dedicated fixture with a known theme and
  hardcoded expected RGB values.
- **Locale resolution has a surprising rule** (last four hex chars). It
  looks like a bug and a future contributor will "fix" it. Comment it with
  a worked example and test `3010429`.
- **Trailing-comma scaling** is the highest-value single correctness item
  here and the easiest to get wrong, because `1,234` and `1,234,` look
  similar and differ by a factor of a thousand.
- **Excelize's calc doc comment is stale** (`calc.go:415` claims implicit
  intersection is unsupported while `implicitIntersect` exists at line
  399). Do not trust excelize's prose comments over its code; that lesson
  from the PDF roadmap applies here too.