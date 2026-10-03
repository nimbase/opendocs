# PDF parser robustness (plan, 2026-10-02)

Tier 2. Turns "this file is broken" into "this file is broken but here is
what it contains".

## Problem

`openDoc` (`docmodel.nim:77`) calls `parseXRef` and propagates any
`PdfError`. There is no recovery path of any kind:

- `xref.parseStartxref` (`xref.nim:35`) requires the literal `startxref`
  within the last `maxScanBytes` (8192). Files with trailing junk beyond
  that, or with `startxref` inside a comment, fail outright.
- `parseClassicSection` (`xref.nim:46`) requires every subsection header
  and entry to parse. One corrupt line kills the file.
- A broken `/Prev` chain is unrecoverable even if the newest section is
  fine.

Every parser in the package is strict by design, which is correct for
well-formed input. The gap is that real PDFs are frequently not
well-formed, and the failure mode is total loss rather than degradation.

libpdfjs treats leniency as a headline design principle (`CLAUDE.md`:
"super lenient", brute-force fallback parser, 21 malformed fixtures
sourced from the Apache PDFBox regression suite). This plan adopts that
as an explicit, *opt-in-by-default-when-recovery-is-needed* policy.

## Locked decisions

- **Recovery is automatic but visible.** A recovered document sets
  `recovered*: bool` and `recoveryNotes*: seq[string]`. Callers can
  ignore it; nobody is silently lied to about file integrity.
- **Layered fallback, three tiers.**
  1. Normal `/Prev` chain, strict (current behaviour).
  2. Lenient xref: skip unparseable subsections and entries, keep the
     rest, note each skip.
  3. Brute-force scan: sweep the whole file for `N G obj`, build an
     xref from what is found, then extract object streams.
- **Never fabricate objects.** A brute-force scan that cannot find an
  object leaves it missing; the next reader raises a precise error
  naming the object number.
- **Newest wins.** During recovery, the *last* definition of an object
  number in file order wins, matching the incremental-update
  convention the strict path already uses.
- **Recovery is bounded.** The sweep is capped by `maxScanBytes` grown to
  file size (it must see the whole file) and by `maxObjects`. A hostile
  file of `N G obj` noise raises rather than allocating without limit.

## Reference map (libpdfjs -> Nim)

| libpdfjs | Nim target | Notes |
|---|---|---|
| `parser/xref-parser.ts` (618) | `xref.nim` | strict path already equivalent |
| `parser/brute-force-parser.ts` (497) | new `recover.nim` | the core new work |
| `parser/errors.ts` (86) | `types.nim` | add `RecoverableParseError` flavour |
| `parser/document-parser.ts` (913) | `docmodel.nim` | orchestrate the fallback chain |
| `fixtures/malformed/` (21 files) | `tests/data/pdf/malformed/` | vendored corpus |
| `fixtures/xref/hello3.pdf` | regression | hybrid table + stream + ObjStm |

## Module changes

### `types.nim`
```nim
type
  PdfRecovery* = object
    recovered*: bool
    notes*: seq[string]      ## human-readable, one per skipped item

proc note*(r: var PdfRecovery, msg: string)
```
Add `maxScanBytes` semantics note: the strict path uses it as the tail
window; the brute-force path needs the whole file. Document that it is
the tail window, not a total scan cap, and add `maxRecoveryObjects` for
the sweep.

### `xref.nim`
Add a lenient sibling rather than loosening `parseXRef`:

```nim
proc parseXRefLenient*(src: PdfSource, limits: PdfLimits,
    rec: var PdfRecovery): XRef
```

Differences from the strict path:
- `startxref` missing or out of range: scan backwards for the highest
  plausible offset instead of raising.
- Subsection header unparseable: skip to the next plausible
  `first count` pair, note it.
- Entry flag not `n`/`f`: treat as free, note it.
- `trailer` missing after subsections: note it and continue to the next
  section.
- `/Prev` pointing at garbage: note it and stop the chain (do not
  discard what was already collected).

Keep every guard from `xref.nim:64` (implausible subsection size) and
`xref.nim:66` (`checkCount`). Leniency is about malformed input, not
about unbounded allocation.

### `recover.nim` (new)
```nim
proc bruteForceXref*(src: PdfSource, limits: PdfLimits,
    rec: var PdfRecovery): XRef
proc scanObjectStreams*(src: PdfSource, xr: var XRef,
    limits: PdfLimits, rec: var PdfRecovery)
proc findRoot*(src: PdfSource, limits: PdfLimits,
    rec: var PdfRecovery): CosObj
```

`bruteForceXref` sweeps for the token pattern `int int obj` outside of
stream payloads. Two hazards, both handled:
- **False positives inside binary streams.** A `stream ... endstream`
  payload may contain the byte pattern. Mitigation: track stream
  boundaries as we go (an `/Length`-resolved region, or the `endstream`
  keyword) and skip those spans. Where `/Length` is wrong, fall back to
  scanning for `endstream`.
- **Cost.** A byte-level sweep of a 500 MB file is real work, but it is
  linear and bounded, and it only runs when tiers 1 and 2 both failed.

`scanObjectStreams` runs `tier-3` object extraction: for each
`/Type /ObjStm` found, decode it and register its contained objects as
compressed entries. This is what makes recovery work for PDF 1.5+ files,
where most objects live in object streams and the page tree is
unreachable from a broken xref.

`findRoot` locates `/Type /Catalog`, preferring a trailer `/Root`
reference, then any object with `/Type /Catalog`, then an object with
`/Type /Pages` and no `/Parent` (a root that lost its `/Type`).

### `docmodel.nim`
`openDoc` becomes:

```
strict parseXRef
  -> on PdfError: lenient parseXRefLenient
  -> on PdfError: bruteForceXref + scanObjectStreams + findRoot
  -> on failure: re-raise the original strict error, not the recovery
     error, so the message names the real problem
```

`PdfDoc` gains `recovery*: PdfRecovery`. `openDoc` and `openPdf` are
unchanged in signature.

### `document.nim`
`PdfDocument` gains `recovered*: bool` so the snapshot path exposes it
without holding a `PdfDoc`.

## Robustness beyond the xref

While in here, three smaller hardening items that the recovery layer
makes easy to handle:

1. **`startxref` pointing into the middle of an object.** The strict
   parser will fail with a confusing message. The lenient parser should
   retry at the nearest preceding object boundary.
2. **A `/Length` that overruns the file.** `decodeCosStream` currently
   fails. Clamp to the available bytes and note it.
3. **A `/Length` that underruns, leaving `endstream` inside the data.**
   Content stream parsing will hit binary garbage and raise from
   `content.nim:117` ("bad content operator"). Prefer the `endstream`
   keyword when `/Length` disagrees, and note it.

Do **not** add these as silent fixes. Each notes and continues.

## Fixtures

Vendor the malformed corpus from `libpdfjs/fixtures/malformed/` (21
files, Apache PDFBox regression cases: PDFBOX-3068 through PDFBOX-5025,
plus `genko_oc_shiryo1` and `xref-off-by-one.pdf`) into
`tests/data/pdf/malformed/`. Check licences: PDFBox fixtures are
Apache-2.0, and the PDF spec permits them for testing.

Add synthetic cases to `tests/gen_pdf_fixtures.nim` for shapes libpdfjs
does not carry: truncated file, zeroed xref offsets, circular `/Prev`,
`obj` pattern inside a stream payload, `/ObjStm` with no xref entry.

## Testing

New `tests/t_pdf_recover.nim`.

Two rules for this suite:
1. **Every malformed fixture must not crash.** No `IndexDefect`, no
   `Defect`, no infinite loop, no unbounded allocation. Recovery or a
   clean `PdfError`, never a crash.
2. **Every recoverable fixture must recover.** Assert `recovered == true`
   and that page count or object resolution is plausible.

Plus:
- recovery notes are populated and readable
- a file that parses strictly does **not** set `recovered` (recovery must
  not fire on healthy files, or it becomes noise)
- `openDoc` on a non-PDF still raises the header error
- the strict error message survives when recovery also fails

## Risks

- **False positives are the main hazard.** A brute-force scan that
  registers a bogus object can produce a document that opens and then
  yields wrong data, which is worse than a clean failure. Prefer missing
  objects over wrong ones.
- **Cost on large files.** The sweep is linear but not free. It only runs
  after two cheaper tiers fail, which bounds the blast radius.
- **Recovery masks upstream corruption.** A caller who ignores
  `recovered` may act on a lossy parse. Mitigated by making the flag
  visible on both `PdfDoc` and `PdfDocument`, never by raising instead.
- Vendoring third-party fixtures adds an attribution obligation. Record
  provenance in `ATTRIBUTION.md` as plan 02 did for docx fixtures.
