# PDF read-side completeness (plan, 2026-10-02)

Tier 1. Everything the reader cannot currently see, aside from Form
XObjects (plan 07, which lands first since this plan depends on it).

## Locked decisions

- **Read-only.** Nothing here writes; the writer counterparts land in
  tier 6 (plan 13).
- **Expose, do not interpret.** `/StructTreeRoot` is returned as a typed
  tree of structure elements, not resolved into a reading order. XMP is
  returned as raw bytes plus a parsed `dc:title`-style convenience view,
  not as a general RDF engine.
- **Annotations are one polymorphic type, not 18 classes.** libpdfjs uses
  18 annotation classes totalling roughly 4,400 lines. This package uses a
  `PdfAnnot` with a `subtype` field and a small set of typed optionals.
  Nim enums with payloads get unwieldy, and the callers (a reader, an
  indexer) mostly want a rectangle plus a few fields.
- **Optional content is reported, not applied.** `/OCProperties` layers
  are listed with their visibility expressions as strings. Evaluating
  `/OCMD` and JavaScript predicates is explicitly out of scope.
- **Page labels are read.** One entry point, because they are cheap and
  document consumers need them.

## Work items

### 1. Metadata read (highest value in this plan)

`PdfDocument` (`document.nim:12`) carries only `version`, `pages`,
`hasEncrypt`. Add:

```nim
type
  PdfInfo* = object
    title*, author*, subject*, keywords*, creator*, producer*: string
    creationDate*, modDate*: string   ## raw PDF date strings
    trapped*: string                 ## /True /False /Unknown
    xmp*: string                     ## raw /Metadata stream bytes

proc docInfo*(d: var PdfDoc): PdfInfo
```

- `/Info` comes from the newest trailer. Keys absent are empty strings,
  never guessed.
- XMP comes from the catalog's `/Metadata`. It is an XML stream; return
  raw bytes and add a shallow convenience parse for `dc:title`,
  `dc:creator`, `xmp:CreateDate`. Use `openparser` (already a
  dependency) rather than a new XML path.
- Note the interaction with `crypt.nim`: `docmodel.nim:198` already
  exempts `/Metadata` when `EncryptMetadata` is false. Reuse that path,
  do not re-derive it.
- Dates: parse into a typed `PdfDate* = object year, month, day, hour,
  minute, second, tzHour, tzMinute: int` alongside the raw string. PDF
  date syntax is a small grammar and malformed dates are common.
- `PdfDocument` gains an `info*: PdfInfo` field. This is a breaking
  change for anyone constructing the struct literally, which is nobody
  in-repo.

`setInfo` on the writer side currently writes `/Title` and `/Author`
only (`write.nim:191`). That is a tier 6 item; do not widen it here.

### 2. Outlines / bookmarks

`/Outlines` reader. There is zero outline support today.

```nim
type
  PdfOutline* = object
    title*: string
    dest*: string            ## resolved target, "" when unresolvable
    pageIndex*: int          ## -1 when the target is not a page
    kind*: string            ## dest, actionGoTo, actionURI, actionNamed
    uri*: string             ## for /URI actions
    open*: bool              ## /Count negative means closed
    children*: seq[PdfOutline]

proc docOutlines*(d: var PdfDoc): seq[PdfOutline]
```

- Walk `/First`/`/Next`/`/Count` with the existing `maxWalkDepth` guard
  and a new `maxOutlineItems` bound.
- Resolve `/Dest` against the page tree, handling both the explicit
  `[page /XYZ ...]` array and the named-destination form (which requires
  reading the catalog `/Dests` name tree **and** the older
  `/Names /Dests`). libpdfjs returns `null` for named destinations
  (`annotations/link.ts:336`); we do better, since a name tree reader is
  a small amount of code and named destinations are common in
  producer-generated files.
- `/A` actions: support `/S /GoTo` and `/S /GoToR` (remote, reported by
  target), `/S /URI`, `/S /Named`. Everything else is surfaced as
  `kind` with empty target rather than guessed.

### 3. Annotation read

`/Annots` is currently touched only incidentally, by `forms.nim` for
widgets and `merge.nim` for page transplant.

```nim
type
  PdfAnnot* = object
    subtype*: string          ## /Link /Text /Square /Widget /...
    rect*: array[4, float64]  ## /Rect, resolved and normalised
    contents*: string         ## /Contents (note the plural spelling)
    author*, title*, subject*: string
    modified*: string
    flags*: int               ## /F bitfield
    border*: array[4, float64]
    color*: array[3, float64] ## /C, empty when absent
    uri*: string              ## /Link /A /S /URI
    destPage*: int            ## -1 when absent
    quadPoints*: seq[array[4, float64]]
    inklst*: seq[seq[float64]]
    name*: string             ## /T on widgets
proc pageAnnots*(d: var PdfDoc, index: int): seq[PdfAnnot]
proc docAnnots*(d: var PdfDoc): seq[tuple[page: int, annot: PdfAnnot]]
```

- `/Rect` may be malformed (reversed corners, non-numeric). Normalize
  and raise on genuinely unparseable values rather than propagating
  nonsense.
- Do **not** synthesize `/AP` appearance streams. Reading rendered
  annotation text is a tier 6 concern (it needs a renderer).
- Widget annotations also appear here; `formFields` keeps its own view.
  Document that they overlap rather than deduplicating.

### 4. Tagged PDF

```nim
type
  PdfStructElem* = object
    structType*: string      ## /S
    kids*: seq[PdfStructElem]
    mcid*: int               ## /MCID, -1 when absent
    pageIndex*: int          ## resolved via /Pg, -1 when absent
    alt*, actualText*, title*: string
    attrs*: seq[tuple[key, value: string]]

proc structTree*(d: var PdfDoc): PdfStructElem
```

- `/StructTreeRoot /K`, honouring the `MCR` (marked-content reference)
  form that points at `(page, mcid)` pairs. This is what makes tagged
  PDFs useful for extraction order.
- `/RoleMap` translation applied to `/S`.
- Do not attempt `/ParentTree` traversal beyond what `/K` needs.
- Bound recursion with `maxWalkDepth`.
- Tier 1 value: reading order for multi-column documents, which
  `doctext.nim:9` explicitly does not attempt ("content order is kept
  (no column reordering)").

### 5. Optional content (layers)

```nim
type
  PdfLayer* = object
    name*: string
    on*: bool                ## /ON default
    intent*: string          ## /View /Design /All
    ocgs*: seq[string]       ## OCG object numbers
proc docLayers*(d: var PdfDoc): seq[PdfLayer]
proc layerVisibility*(d: var PdfDoc, layer: string): seq[bool] ## per /OCMD
```

Read `/OCProperties /OCGs` and `/D` (default config). Evaluate `/OCMD`
only for `/VE`-free visibility expressions, which is the common case;
report the expression string otherwise. JavaScript in `/JS` is never
evaluated, here or anywhere.

libpdfjs has `layers/layers.ts` (322 lines) as a reference, including
flattening; flattening needs a renderer and lands in tier 3.

### 6. Page labels

```nim
type
  PdfPageLabel* = object
    style*: string           ## /D /R /r /A a
    prefix*: string
    start*: int
proc pageLabels*(d: var PdfDoc): seq[PdfPageLabel]
```

Read `/PageLabels` number tree, apply `/P` (numeric style) and `/R`
(uppercase) or `/r` (lowercase) with `/St` prefix. Simple, self-contained,
and documents need it.

### 7. Inline images (belongs with plan 07)

`content.nim:49` already parses `BI ... ID ... EI` into a
`ContentOp(name: "BI", operands: [dict, bytes])`, and `t_pdf_content.nim`
tests the scan. But `pageRawImages` only enumerates `/Resources
/XObject`, so inline images are parsed and thrown away.

Fix in `images.nim`: while walking ops, treat a `BI` op as an image whose
dictionary is the inline dict. Feed it through the existing
`parseRawImage` path so colorspace, mask, and decode handling are shared.

Caveat to document, not fix: `content.nim:9` notes the `EI` scan takes
the *first* whitespace+`EI`+delimiter match, so a payload containing that
byte run truncates early. libpdfjs ports pdf.js's `EI` detection
(`content/parsing/inline-image.ts`, 565 lines) to do better. Decide
whether to port that here; the honest answer is that it needs the
operator arity table from PDF 32000 tables 57-61, which we do not have.

## Reference map (libpdfjs -> Nim)

| libpdfjs | Nim target | Notes |
|---|---|---|
| `api/pdf-catalog.ts` | new `catalog.nim` | catalog-level getters |
| `document/name-tree.ts` (329), `buildNameTree` | new `nametree.nim` | shared by outlines, page labels, layers |
| `api/pdf-attachments.ts` (270) | model for `docAnnots` | |
| `annotations/` (22 files, ~4400) | single `PdfAnnot` type | deliberately narrower |
| `document/struct-tree.ts` (245) | `PdfStructElem` | libpdfjs only prunes; we read |
| `layers/layers.ts` (322) | `PdfLayer` | read-only half |
| `helpers/colors.ts`, `helpers/rotations.ts` | shared helpers | |

## Phases

1. **P1 metadata.** `PdfInfo`, `docInfo`, XMP passthrough, date parsing.
   Widest immediate payoff for the least code.
2. **P2 name tree + outlines.** `nametree.nim` first (outlines, page
   labels, and `/Dests` all need it).
3. **P3 page labels.** Small, closes out the name-tree work.
4. **P4 annotations.** `PdfAnnot`, per-page and document-wide.
5. **P5 tagged PDF.** `PdfStructElem`, `/K` and `/MCR`, `/RoleMap`.
6. **P6 layers.**
7. **P7 inline images.** After plan 07 lands, since it reuses the nested
   walk.

## Fixtures

Add to `tests/gen_pdf_fixtures.nim`:
Fixtures are named by feature, not by milestone (the existing `m3a_*`
through `m8_*` names are historical):

- `info_full.pdf`: full `/Info` with all keys plus XMP `/Metadata`.
- `info_dates.pdf`: malformed and partial date strings.
- `outlines.pdf`: nested outlines, named destination, URI action,
  remote GoTo action, unresolvable target.
- `annots.pdf`: link (URI and internal), text, square, highlight with
  quad points, ink list, widget; plus a malformed `/Rect`.
- `struct_tree.pdf`: `MCR`-based structure tree over marked content with
  a `/RoleMap`.
- `page_labels.pdf`: `/PageLabels` with `/P`, `/R /St`, `/r`.
- `layers.pdf`: `/OCProperties` with `/VE` and `/JS` configs.
- `inline_image.pdf`: inline image alongside an XObject image.

## Testing

New `tests/t_pdf_meta.nim` (metadata, dates, XMP), `t_pdf_outline.nim`,
`t_pdf_annot.nim`, `t_pdf_struct.nim`.

Every reader asserts the **negative** case too: absent keys are empty
strings, unresolvable destinations report `-1` rather than guessing,
malformed `/Rect` raises `PdfError` naming the annotation.

The libpdfjs malformed fixture corpus is a good source of shapes to
reproduce; its `fixtures/README.md` documents each file's feature.

## Risks

- Broadening `PdfDocument` is breaking. In-repo callers are few, but
  `pdf.nim` re-exports it, so downstream users are affected.
- One wide `PdfAnnot` type will accumulate fields most callers ignore.
  Acceptable: it is a flat read type, and Nim callers pay nothing for
  unused fields.
- XMP is XML in namespaces; a shallow convenience parse must not become
  an RDF engine. Keep the parse to the three fields named above and
  return the raw bytes for everything else.
- Tagged PDF structure trees in the wild are frequently malformed.
  Recursion bounds are mandatory, not defensive extras.
