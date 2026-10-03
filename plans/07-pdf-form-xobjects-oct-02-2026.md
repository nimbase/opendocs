# M7 Form XObjects and nested content (plan, 2026-10-02)

Tier 1. Closes the last unreached milestone and removes a silent blind
spot in the shipped extractors.

## Problem

`/Subtype /Form` XObjects are common in real PDFs: page templates,
letterheads, table cell backgrounds, watermarks, and anything a producer
factorized. Today they are skipped outright:

```
src/opendocs/pdf/images.nim:251
  ## Form XObjects are skipped (nested content is an M7 concern).
```

The consequence is not an error, it is *missing data*. `extractText`
returns runs for visible top-level text only; `pageImages` returns only
page-level `/Resources /XObject` images. Both look like a successful
call. A reader cannot tell a genuinely blank region from content the
library chose not to read.

Forms are common in producer-generated PDFs: page templates, letterheads,
table cell backgrounds, watermarks, and anything a producer factorized.

**Correction (verified during implementation):** neither checked-in
real-world fixture uses forms. Walking every live object, including those
inside object streams, finds zero `/Subtype /Form` in
`file-example_PDF_500_kB.pdf` (55 objects) and `525J-001.pdf` (411
objects). An earlier draft of this plan assumed both were affected; they
are not. That makes them useful as *negative* fixtures: the new descent
must be a measurable no-op on them, which is what
`tests/t_pdf_formrealdoc.nim` asserts. The feature itself is covered by
the synthetic `m7_*` fixtures.

## Locked decisions

- **Descend, do not flatten.** A Form XObject is parsed and its
  operators are executed in the caller's graphics state with the form's
  `/Matrix` and `/Resources` applied. Flattening to a synthetic op list
  loses the resource namespace, which is the whole difficulty.
- **Resource lookup is a stack, not a dict.** A form's `/Resources`
  shadows the page's for the duration of the `Do`. Names resolve from the
  innermost dict that defines them.
- **BBox clips, it does not transform.** `/BBox` restricts the form's
  coordinate space. Text extraction filters runs whose device-space origin
  falls outside the transformed box. Path painting needs real clipping,
  which lands in tier 6; tier 1 clips text and image placement only.
- **New depth cap.** `PdfLimits` gains `maxNestedXObject` (default 12).
  `maxWalkDepth` governs the page tree, not content, and is not reused.
- **Recursion is per-`Do`-execution, not per-object.** The same form
  XObject drawn 40 times on a page is walked 40 times. Deduplicating by
  object number would be wrong, because the CTM differs each time.

## Reference map (libpdfjs -> Nim)

| libpdfjs | Nim target | Notes |
|---|---|---|
| `content/parsing/content-stream-parser.ts` | extend `content.nim` | already equivalent |
| `drawing/resources/form-xobject.ts` (132) | new in `gstate.nim` | `/Matrix`, `/BBox`, `/Resources` |
| `api/pdf-page.ts` `getResources()` | `pageResources` (`gstate.nim:172`) | extend for nesting |
| `document/object-copier.ts` remap | reuse `merge.nim` `cloneDirect` | for writing nested forms later |
| `integration/scenarios/` indirect XObject | fixture | already covered |

libpdfjs does not treat Form XObjects as a special feature; they fall
out of its resource-stack design. That is the right model and the reason
the gap is cheap to close here.

## Module changes

### `types.nim`
Add `maxNestedXObject*: int` to `PdfLimits`; default 12 in
`defaultPdfLimits`.

### `content.nim`
`parseContentStream` stays as-is: it is a pure tokenizer over one
stream's bytes and knows nothing about resources. Descent belongs above
it.

### `gstate.nim`
New resource stack and nested-walk driver.

```nim
type
  ResourceFrame* = object
    resources*: CosObj   ## resolved /Resources dict
    depth*: int

proc pushResources*(d: var PdfDoc, frame: var seq[ResourceFrame],
    parent: CosObj, sub: CosObj)
proc lookupResource*(d: var PdfDoc, stack: seq[ResourceFrame],
    category, name: string): CosObj
```

`walkPageOps` currently returns `seq[ContentOp]`. It cannot express
nesting, because a nested stream has a different `/Resources` than the
enclosing one. Two options:

| Option | Shape | Cost |
|---|---|---|
| A | `seq[ContentOp]` plus a parallel `seq[CosObj]` of the resource frame in effect at each op | Small diff. Consumers index both. Awkward to consume. |
| B | New `WalkedOp = object op*: ContentOp, resources*: CosObj` and `walkPageOps` returns `seq[WalkedOp]` | Breaking change to `walkPageOps` and its four consumers, but the resource context travels with the op and cannot be forgotten. |

**Take option B.** The four consumers are all in-repo (`text.nim`,
`images.nim`, `sheet.nim`, `forms.nim`), the breaking change is
mechanical, and option A invites exactly the bug this plan exists to fix
(an op consumed with the wrong resource frame). Text extraction already
takes `res` as a parameter (`text.nim:446` `decoderFor`), so the fix is
mostly mechanical there.

New recursion driver:

```nim
proc walkNested*(d: var PdfDoc, index: int): seq[WalkedOp]
```

Algorithm:
1. Frame 0 = page `/Resources`, depth 0.
2. Iterate ops. For a non-`Do` op, emit `WalkedOp(op, frame.resources)`.
3. For `Do` with a name: resolve through the frame stack. If
   `/Subtype /Form`, decode the content stream, parse it, apply
   `/Matrix` to the CTM, push a frame from the form's `/Resources`
   (falling back to the parent frame when absent, per spec), recurse at
   depth + 1, pop, and restore the CTM.
4. If `/Subtype /Image`, emit nothing here; image collection handles it
   (it needs the transform, which `WalkedOp` carries).
5. Depth past `maxNestedXObject` raises `PdfError`.

Also handle `BDC`/`BMC`/`EMC` marked content: they only affect structure,
not rendering, so emit them as ops and ignore.

### `text.nim`
`extractText` (`text.nim:463`) switches to per-op resources:
`decoderFor(op.resources, ...)` instead of the page-level `res`. The
font decoder cache key must become `(frameIndex, fontName)`, not
`fontName`, because `/F1` in a form and `/F1` on the page can be
different fonts. This is a real correctness point, not bookkeeping.

Text matrix and CTM state must be saved and restored around the
recursion boundary, which `GState` already models via `q`/`Q`.

### `images.nim`
`pageRawImages` (`images.nim:248`) currently reads ops, collects the
distinct `Do` names, then looks them up in the page `/Resources`. With
nesting, collect `Do` ops with `/Subtype /Image` from the walked list and
resolve each through its own frame. Record the CTM at the `Do` so
callers can place the image; add `ctm*: array[6, float64]` to
`PdfRawImage`.

### `vipsimg.nim`
`pageImages` inherits the placement fix for free. Add the unit square to
`/Matrix` for output so callers get device-space bounds.

### `doctext.nim`, `sheet.nim`, `forms.nim`
No signature change. They consume `extractText` / `extractDocumentText`,
which become correct once nested runs appear. `sheet.nim`'s row
classification will now see text it previously missed, so its real-world
fixture assertions may need updating (expect new rows, not failures).

### `forms.nim`
`flattenFields` bakes field appearances into page content. Appearance
streams are themselves Form XObjects, and it already handles them
specially. Verify that nested descent does not double-flatten or
double-count a widget's appearance. **Likely the one place this plan can
regress existing behaviour**, so it gets its own test first.

## Phases

1. **P1 seam.** `WalkedOp`, `ResourceFrame`, depth cap, `walkNested`.
   Mechanical consumer migration. Green before any semantics change.
2. **P2 text.** Per-frame decoder cache key, CTM save/restore, BBox
   clip. New fixture: a page with a form XObject carrying text.
3. **P3 images.** Per-frame lookup, CTM at `Do`. New fixture: an image
   inside a form.
4. **P4 nesting.** Form inside form, `/Matrix` scaling, `/BBox`
   clipping, resource shadowing, depth cap firing. Plus the
   `flattenFields` regression guard from P1.
5. **P5 real-world.** `tests/t_pdf_formrealdoc.nim` pins that both
   checked-in real documents contain no forms (so the premise is
   explicit), that `walkNested` returns exactly the flat op count on
   them, and that image collection is unchanged. A fixture swap to one
   that does use forms will fail these loudly, which is the intended
   signal.

## Implementation notes

Three findings from the implementation worth recording:

- **The synthesised `q`/`cm`/`Q` must be emitted into the output, not
  just applied to the walker's local state.** Otherwise a consumer that
  folds operators linearly computes a different CTM than the one
  recorded on each `WalkedOp`, and form text lands at the wrong place
  and then fails its own BBox clip. This was the one real bug found by
  the M7 tests. `tests/t_pdf_formxobject.nim` asserts the invariant
  directly: replaying `walkNested` output must reproduce every recorded
  CTM.
- **The synthesised `Q` belongs to the caller's resource frame**, not the
  form's, since it restores the caller's graphics state.
- **Inline images need their abbreviations expanded** (`/W`, `/H`,
  `/BPC`, `/CS`, `/D`, `/DP`, `/F`, `/IM`, `/I`, `/L` to their long
  forms) before the shared image parser runs, and a `/Subtype /Image`
  supplied, since the dictionary reader does not canonicalise either.
  This is also the natural home for the inline-image support that plan 08
  had listed as a separate work item; it is done.
- **Inline image payloads cannot contain whitespace.** `content.nim`'s
  `EI` scan takes the first whitespace + `EI` + delimiter match, so a
  payload byte of `0x20` truncates it. That limitation is pre-existing
  and documented in `content.nim`; only the fixture had to avoid it.

## Fixtures

Extend `tests/gen_pdf_fixtures.nim` (527 lines, stdlib-only assembler in
`tests/pdf_support.nim`):
- `m7_form_text.pdf`: page draws `/Fm1` containing `BT /F1 12 Tf ... Tj`.
- `m7_form_image.pdf`: form containing an image `Do`.
- `m7_form_nested.pdf`: form inside form, with a `/Matrix` scale and a
  `/BBox` that clips text on one line.
- `m7_form_loop.pdf`: a form whose content invokes itself; must raise at
  the cap.
- `m7_form_inline.pdf`: an inline image at page level and one inside a
  form.
- `m7_form_nores.pdf`: a form with no `/Resources`, which must inherit
  the page's frame rather than fail.

Fixture authoring note: `streamObj` only takes a payload, so a form
must be built with `streamObj` directly (not the `streamFlate` wrapper)
or its `/Subtype /Form` is silently dropped and every `Do` becomes a
pass-through. Object numbering must also account for the font object
sitting between the page and its content stream. Both mistakes were
made and caught by `sanityNested` in the generator.

## Testing

New `tests/t_pdf_formxobject.nim`. Assertions:
- nested text extracted, positions in device space
- `/Matrix` scaling reflected in run positions
- `/BBox` clipping drops out-of-box runs, keeps in-box ones
- resource shadowing yields two distinct `/F1` decoders
- image inside a form is collected with its CTM
- depth cap raises `PdfError` on a self-referential form
- `flattenFields` output unchanged versus pre-plan fixture bytes
- no crash on a form with a missing `/Resources` (falls back to parent)
- `525J-001.pdf` nested-run count is greater than the recorded baseline

## Risks

- Option B is a breaking change to `walkPageOps`. It is contained, but
  it must land in one commit with all four consumers migrated.
- The decoder cache key change is the easiest thing to get subtly wrong.
  Without it, two fonts both named `/F1` collide and text extracts as
  garbage with no error.
- `flattenFields` interacts with nested content and is the most likely
  regression site. Test it before touching descent.
- Forms that reference resources they do not define are legal (fall back
  to the page). Getting this wrong turns valid files into errors.
