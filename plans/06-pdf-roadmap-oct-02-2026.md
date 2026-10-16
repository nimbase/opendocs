# PDF roadmap (index, 2026-10-02)

Reference: `nimbase/references/libpdfjs` (TypeScript, `@libpdf/core` 0.4.2).
Existing plan numbering continues from `05-xlsx-readers.md`.

## Why this document exists

PDF is the largest and most complete subsystem in the package (10,617
lines across 29 files under `src/opendocs/pdf/`, plus the 588-line
`pdf.nim` facade; 240 tests in 17 files) yet it never had a plan file.
Its scope lives only as `M1`-`M12` markers scattered across roughly twenty
module doc comments. This document promotes that to a tracked roadmap
and adds per-area plans for the work that remains.

## Locked decisions

- **Milestone numbering continues.** `M1`-`M12` are shipped, including
  `M7` (Form XObjects). New work beyond `M12` gets `M13`+ rather than
  reusing a retired number.
- **Tier order is fixed** (see below). Read-side correctness first,
  because the existing extractors are *silently* incomplete: text and
  images inside Form XObjects are invisible today, with no error and no
  diagnostic.
- **Per-area plans are separate documents**, numbered 07 onward. This
  file is the index and the status matrix; it stays short.
- **No unified document DOM.** Per `00-collection-overview.md`, each
  format keeps its own API. PDF exposes flat, purpose-built entry points
  (`extractText`, `pageImages`, `formFields`, `docSignatures`), not one
  universal tree.
- **Fail loudly, never guess.** Existing modules raise `PdfError` rather
  than silently degrading. Every new feature follows that rule; where a
  heuristic is unavoidable (`sheet.nim`, `doctext.nim`) it is documented
  in the module header.
- **README is deferred.** Its over-claims are corrected when the code
  lands, not before.

## Status matrix

Legend: `done` shipped and tested, `partial` shipped with a documented
narrow scope, `gap` absent entirely.

| Area | Module | State | Notes |
|---|---|---|---|
| COS model | `cos.nim` | done | full value model, streams, indirect `/Length` |
| Byte source | `source.nim` | done | mmap zero-copy, Defect on use-after-close |
| Lexer / xref | `lexer.nim`, `xref.nim` | done | classic + stream tables, mixed `/Prev` chains |
| Object streams | `docmodel.nim` | done | `/ObjStm`, compressed page dicts |
| Filters | `filters.nim` | partial | Flate/LZW/A85/AHx/RL + predictors pass; image codecs passthrough, no preset dictionary, bpc != 8 rejected |
| Encryption read | `crypt.nim` | done | R2/R3/R4/R6, crypt filters, `/Perms` |
| Encryption write | `crypt.nim` | gap | no `computeO`/`computeU` forward path, no `/Encrypt` builder; `write.nim:411,463` reject encrypted input |
| Content parsing | `content.nim` | partial | full operator tokenizing; inline-image `EI` scan is first-match heuristic |
| Graphics state | `gstate.nim` | partial | CTM + text state only; no path, color, or `gs` state |
| **Form XObjects** | `gstate.nim` | done | `walkNested`, resource stack, `maxNestedXObject`; M7 plan removed |
| Text extraction | `text.nim` | partial | deep encoding fallback chain, CJK vertical; nested forms handled by `walkNested` |
| Doc text / search | `doctext.nim` | partial | lines, blocks, exact search; ASCII-only case folding |
| Sheet / tables | `sheet.nim` | partial | whitespace-grid heuristics only, read-only |
| Images | `images.nim`, `vipsimg.nim` | partial | 7 colorspaces; Lab raises, CCITT/JBIG2/JPX passthrough; XObject and inline images collected |
| Metadata read | `document.nim` | gap | `PdfDocument` exposes only `version`, `pages`, `hasEncrypt`; no `/Info`, no XMP |
| Outlines | none | gap | no `/Outlines` reader |
| Annotation read | `forms.nim` (incidental) | gap | `/Annots` touched only for widget plumbing and page transplant |
| Tagged PDF | none | gap | no `/StructTreeRoot`, `/MarkInfo`, `/RoleMap` |
| Optional content | none | gap | no `/OCProperties` |
| Page labels | none | gap | no `/PageLabels` |
| COS serializer | `write.nim` | done | `writeCos`, `rewritePdf`, `reflate` |
| Builder | `write.nim` | done | catalog/pages/content, `adoptPage`, images, `/Info` |
| Incremental update | `write.nim` | done | `/Prev` chain, run-subset xref subsections |
| Font embedding | `fontembed.nim` | done | HarfBuzz shape + subset, WinAnsi and Identity-H CID, CFF and TrueType |
| Vector graphics write | none | gap | no path construction, painting, clipping, shading, patterns |
| Color write | none | gap | no `rg`/`RG`/`k`/`g`/`sc`/`scn`, no `gs` ExtGState |
| Annotation write | `forms.nim` (widgets only) | gap | no link, text, square, ink, or stamp write |
| Outline write | none | gap | no `/Outlines` builder |
| Tables write | none | gap | `sheet.nim` is read-only |
| Metadata write | `write.nim` | partial | `/Title` + `/Author` only; no dates, Producer, XMP |
| Forms | `forms.nim` | partial | extract/fill/flatten solid; signature and pushbutton fields never filled, XFA and JS actions absent |
| Signatures | `sign.nim` | partial | PAdES **P4a** only; P4b deferred, plan 10 |
| Parser robustness | `xref.nim`, `docmodel.nim` | gap | no recovery scan, no malformed corpus, plan 08 |
| Page renderer | none | gap | no rasterizer at all, plan 09 |

## Tier order

| Tier | Theme | Plan | Rationale |
|---|---|---|---|
| 0 | Test hermeticity | this file, bottom | 10 tests silently `echo`-skip without a sibling `harfbuzz` checkout that is not a declared dependency; CI never runs them |
| 1 | Read-side completeness | 08 (M7 done; plan removed) | Fix silent blind spots in shipped extractors. Highest value per line written. |
| 2 | Parser robustness | 08 | Leniency as a design principle; malformed corpus is the safety net for tier 1 |
| 3 | Page renderer | 09 | New capability, large, but a thin libvips path exists so the cost is lower than it looks |
| 4 | Signature completion (P4b) | 10 | Largest single block; needs a hand-rolled DER layer |
| 5 | Encryption writer | 11 | Symmetric to a complete decrypt side; unlocks rewrite and incremental update on encrypted files |
| 6 | Writer capability | 12 | Vector graphics, color, tables, annotations, outlines. Broadest surface, least correctness risk |

Tier 5 sits below tier 4 deliberately: the decrypt side is already
complete, so encryption writing is additive, whereas P4b is blocked on
infrastructure (ASN.1/DER) that does not exist yet.

Tier 6 is last because the shipped writer is correct for what it does
(flowing text plus JPEG/RGB images). Extending it is a product decision
rather than a correctness fix.

## Tier 0: test hermeticity (do first, it is small)

10 tests across `t_pdf_docwrite.nim` and `t_pdf_fontembed.nim` `echo` a
skip message and continue when `../harfbuzz/tests/data/DejaVuSans.ttf`
is absent. The path resolves on this machine (the sibling checkout
exists) but never in CI, which installs HarfBuzz from a release tarball
with `-Dtests=disabled`. So CI reports green while exercising a
meaningfully smaller surface than local.

Actions:
1. Vendor a permissively licensed subset font into
   `tests/data/fonts/` (DejaVu is Bitstream Vera licensed; Noto is OFL).
   The existing `cjk-cff-micro.otf` and `emoji-cbdt-micro.ttf` are the
   precedent for small purpose-built fonts.
2. Point the constants at the vendored file; keep the sibling path as a
   fallback for regenerating fixtures.
3. Convert the `echo` guards to `unittest.skip` so a missing fixture is
   visible in output rather than silently absent.

## Per-area plans

| Plan | Area | Tier |
|---|---|---|
| `08-pdf-read-side-oct-02-2026.md` | metadata, outlines, annotation read, tagged PDF, inline images | 1 |
| `09-pdf-parser-robustness-oct-02-2026.md` | brute-force recovery, lenient xref, malformed corpus | 2 |
| `10-pdf-render-oct-02-2026.md` | page rasterization | 3 |
| `11-pdf-sign-p4b-oct-02-2026.md` | CMS/PKCS#7, timestamps, DSS/VRI | 4 |
| `12-pdf-encrypt-write-oct-02-2026.md` | encryption writer | 5 |
| `13-pdf-writer-capabilities-oct-02-2026.md` | vector graphics, color, tables, annotations, outlines | 6 |

## Cross-cutting notes

**`walkPageOps` is the seam for tier 1.** `gstate.nim:210` returns a flat
`seq[ContentOp]` with no resource context. Every read-side consumer
(`extractText` at `text.nim:463`, `pageRawImages` at `images.nim:248`,
`extractSheet`, `flattenFields`) iterates it. Recursive descent into
Form XObjects belongs there, once, not in four consumers.

**libpdfjs is a scope reference, not a port target.** It is 128,928 lines
across 417 files and explicitly declares rasterization a non-goal. Its
value to this roadmap is its gap inventory (`.agents/STATUS.md`), its
malformed fixture corpus, and its API shape for the drawing and
annotation layers. Two of its docs are stale and should not be trusted:
`ARCHITECTURE.md` claims CCITT is passthrough when G4/G3-1D decode is in
fact implemented, and `CODE_STYLE.md` still names Biome where the repo
uses oxlint.

**Determinism is a tested property.** `t_pdf_docwrite.nim` and
`t_pdf_fontembed.nim` both assert byte-identical output across runs.
Every writer-side plan keeps that assertion; subsetting order and object
numbering must stay stable.

**Limits are load-bearing.** `PdfLimits` (`types.nim:9`) caps pages,
objects, walk depth, content ops, and image pixels. Recursive
content-stream descent in tier 1 introduces a new unbounded dimension
(Form XObject nesting) and must add a cap rather than relying on
`maxWalkDepth`.

## Risks

- Recursive content descent can be quadratic or worse on adversarial
  nesting. The new cap is not optional; without it this is a DoS vector.
- libvips `pdfload` (poppler) as the tier 3 shortcut silently inherits
  poppler's rendering, not ours. Acceptable as a documented escape hatch,
  misleading if presented as our own renderer.
- P4b without an ASN.1 dependency means hand-rolling DER. It is a
  well-bounded TLV format, but certificate *parsing* is where the real
  complexity lives, and a subtle bug there is a silent security defect.
- Tier 6 breadth invites API churn. Lock the writer API shape before
  starting, not during.
