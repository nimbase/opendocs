# PDF page renderer (plan, 2026-10-02)

Tier 3. First genuinely new capability rather than closing a gap.

## Position: two options, pick one deliberately

There is no rasterizer today. `vipsimg.nim` decodes embedded *image
XObjects*; `exports.nim` re-encodes those pixels. Nothing composites page
content. Two routes, and they are not equivalent:

| | A: libvips `pdfload` | B: own compositor |
|---|---|---|
| Mechanism | `vips_pdfload_buffer` (poppler) on the file bytes | Execute content operators onto a raster surface |
| New code | ~150 lines | 4,000+ lines |
| Fidelity | poppler's, mature | ours, incomplete for months |
| Dependencies | none (libvips already required) | font rasterizer (FreeType via harfbuzz, already present), rasterizer, blend modes, transparency groups |
| Encrypted input | poppler handles passwords | we already decrypt |
| Our modifications | none; it re-reads the file | naturally reflects them |

**Recommendation: ship A first, as `renderPageVia*`, honestly named.** It
unblocks thumbnails, previews, and image export from real pages in a day
of work, and it is genuinely useful. Do **not** call it our renderer.

Then decide whether B is wanted. B is a large project with a long tail
(soft masks, blend modes, shadings, patterns, Type 3 fonts, tiling
patterns, transparency groups, overprint). libpdfjs explicitly declares
rasterization a non-goal; pdf.js and mupdf are the projects to study for
B, not libpdfjs.

The rest of this plan covers **B**, and the phased structure is
deliberate: each phase is independently useful, and if B is abandoned
midway the shipped phases still stand.

## Phase 0: the libvips escape hatch

`libvips/src/libvips/bindings/foreign.nim:270-272` already binds
`vips_pdfload_buffer`. The `api/` wrapper does not expose it, and the
bindings are `varargs`, so options (`page`, `dpi`, `scale`, `n`,
`password`) need explicit plumbing.

Add to the libvips package (`clients/libvips`), not to opendocs:
```nim
proc loadPdfBuffer*(buf: seq[uint8], page = 0, dpi = 150.0,
    password = ""): Image
```
Then in opendocs:
```nim
proc renderPagePreview*(path: string, page = 0, dpi = 150.0,
    password = ""): ExportPixels   ## reuses exports.nim
```
Document precisely what it is: **poppler renders this, not opendocs.**

Constraints to verify before promising it:
- poppler presence is a build-time property of libvips. CI installs
  `libvips-dev` on Linux and `vips` via brew on macOS; poppler may be
  absent. Gate the proc behind a runtime capability probe
  (`vips_type_find("VipsOperation", "pdfload_buffer") != 0`) and raise
  `PdfError` with a clear message when missing.
- It takes a *file path or buffer*, so `PdfSource` mmap-backed documents
  and in-memory strings both work via the buffer variant.

## Phase 1 (B): device model and the raster surface

The core abstraction. A page renders into a scanline buffer.

```nim
type
  Raster* = object
    w, h*: int
    stride*: int
    px*: seq[uint8]        ## RGBA8, premultiplied

  BlendMode* = enum
    bmNormal, bmMultiply, bmScreen, bmOverlay, bmDarken, bmLighten,
    bmColorDodge, bmColorBurn, bmHardLight, bmSoftLight,
    bmDifference, bmExclusion, bmHue, bmSaturation, bmColor, bmLuminosity

  ColorSpaceKind* = enum
    csDeviceGray, csDeviceRGB, csDeviceCMYK, csCalGray, csCalRGB,
    csLab, csICCBased, csIndexed, csSeparation, csDeviceN,
    csPattern, csCIEBased

  Rgb* = object
    r, g, b: float32       ## 0..1

proc fillRect*(r: var Raster, x, y, w, h: int, c: Rgb, alpha: float32)
proc blendPixel*(r: var Raster, x, y: int, c: Rgb, alpha: float32,
    mode: BlendMode)
```

- Resolution scale as an explicit parameter (`scale`, default 72 dpi =
  1.0). All device coordinates are floats, rounded at sample time.
- Anti-aliasing: supersample paths by default (`aaSamples`, default 4),
  configurable to 1. Supersampling is simpler than analytic coverage and
  good enough for a first version.
- Clip to a device-space rect; every painting op is intersected with the
  current clip before sampling.

The CTM maps user space to device space. `gstate.nim` already has
`concatMatrix` and the `[a b c d e f]` convention; reuse both, and use
`transformPoint` from `content.nim` for point mapping.

## Phase 2: paths

Full path construction (`m l c v y h re`) plus painting
(`S s f F f* B B* b b* n`) and clipping (`W W*`).

The hard part is curve flattening. Bezier flattening with an adaptive
subdivision count derived from the transformed control polygon is
standard; fixed subdivision looks wrong at large scales. libpdfjs's
`svg/arc-to-bezier.ts` (265 lines) is a useful reference for the arc
conversion that `SVG` path input will need later, though PDF paths have
no arcs natively.

Non-zero and even-odd winding both needed (`f` vs `f*`). Implement as two
scanline fill rules sharing the edge list.

`flattenFields` in `forms.nim` already bakes appearance streams into page
content, so a rendered flattened form needs no special handling. That is a
real reuse win: form flattening becomes visible for the first time.

## Phase 3: colors

Full colorspace support, which is broader than the reader's current state:
`images.nim:132` still raises on Lab.

- DeviceGray/RGB/CMYK with the standard transfer functions.
- ICCBased: libvips can apply a profile (`vips_icc_import` /
  `vips_icc_transform`). Use it rather than writing an ICC engine.
- Indexed: expand to RGB (the reader already does this for images).
- Separation and DeviceN: use `/Alternate` (what `vipsimg.nim` already
  does) unless `/TintTransform` says otherwise. Note as a deliberate
  limitation.
- Lab: convert via the D50 white point, matching the spec's requirement
  that Lab be relative to D50 after adaptation.
- Pattern colorspaces are deferred to phase 6.

## Phase 4: text and fonts

This is where the existing text work pays off.

- Glyph outlines: FreeType through HarfBuzz, already a dependency
  (`shape.nim` uses it). `hb_font_get_glyph_extents` gives metrics;
  outline extraction needs `hb_ft_font` or a direct FreeType face load.
- Embedded font programs must be written to a temporary file or an
  in-memory FreeType face for FT_New_Memory_Face. There is no public
  FreeType import in this package; check whether harfbuzz's binding
  re-exports it before assuming a new dependency.
- Standard 14 fonts: the AFM widths are already embedded
  (`pdf.nim` ships Helvetica metrics). The *outlines* are not. Options:
  vendor base-14 Type 1 programs (metrically compatible, freely
  redistributable), or rasterize with a metric substitute and document
  the substitution. Vendoring is the honest answer.
- Type 3 fonts: run the glyph content stream as a mini page with the glyph
  space as device space. Straightforward once paths work, and worth doing
  since Type 3 is common in older LaTeX and form output.
- Text rendering mode `Tr` (fill, stroke, clip, invisible): phase 5
  brings clipping, so honour `Tr` 0/3 now and 1/2/4-7 with phase 5.

## Phase 5: graphics state, clipping, transparency, blend modes

- `/ExtGState`: `/ca` and `/CA` constant alpha, `/BM` blend mode,
  `/SMask` soft mask, `/LW` line width, `/LC` and `/LJ` line caps and
  joins, `/D` dash pattern.
- Clipping becomes a real device-space region. Intersect on `W`, restore
  on `Q`. Bounding-box acceleration is not needed at first; scanline
  intersection is.
- Transparency groups (`/Group` with `/S /Transparency`) require
  offscreen buffers plus correct compositing order. This is the single
  largest item in the phase.
- Blend modes: the 16 separable modes in closed form, plus the four
  non-separable (hue, saturation, color, luminosity) which need the
  non-separable algorithm.

## Phase 6: images, shadings, patterns

- XObjects: reuse `pageRawImages` and `vipsimg.nim` wholesale, compositing
  the decoded bitmap through the CTM. Images inside Form XObjects come
  free from plan 07.
- `sh` operator: axial (`t` type 2) and radial (`t` type 3) shadings,
  Gouraud (`t` type 1) and stitching (`t` type 4-7) are rarer. Start with
  2 and 3.
- Pattern colorspaces: tiling patterns render into a cell and repeat;
  shading patterns are a shim between the two.

## Phase 7: annotations and optional content

- Annotation `/AP` normal appearance streams rendered in place.
- `flattenFields` output renders as ordinary page content, no special
  handling.
- Optional content: apply `/OCProperties` default config, then honour
  `/OCMD` visibility expressions for the non-JavaScript subset that
  plan 08 already parses. This finally makes `flattenLayers` (a tier 6
  item) meaningful.
- Annotation borders and line-ends.

## API shape

Lock this before starting; the tier 6 breadth warning in the index
applies with more force here.

```nim
type
  RenderOptions* = object
    dpi*: float64            ## 72 = 72 dpi, 1 user unit = 1 px
    page*: int               ## 0-based
    aaSamples*: int          ## 1 = none, default 4
    background*: Rgb         ## white by default
    maxPixels*: int          ## guard, default 50_000_000

proc renderPage*(d: var PdfDoc, opts = RenderOptions()): Raster
proc renderToPng*(r: Raster): seq[uint8]   ## via exports.nim
proc renderToFile*(r: Raster, path: string)
```

`renderPage` returns the raster, not encoded bytes. Encoding is
`exports.nim`'s job already. Keep it that way; a `renderPageToJpeg`
convenience overload is fine.

## Testing

Rendering needs a visual oracle, which is the hard part.

- Golden-image comparison against poppler's `pdftoppm` output at fixed
  dpi, with a per-pixel tolerance. Poppler is the reference because it is
  what phase 0 already exposes, and it is a de facto standard.
- Threshold on mean absolute difference per channel. Exact equality is
  unreachable across independent rasterizers.
- Fixture set: the existing `m3a_basic.pdf`, `m5_images.pdf`,
  `m8_cjk.pdf`, plus new renderer-specific fixtures per phase (paths,
  gradients, clipping, transparency, blend modes, Type 3, all text
  render modes).
- Property tests that need no oracle: rendering never reads out of
  bounds (checked with a bounds-instrumented raster), alpha stays in
  0..1, `maxPixels` raises rather than allocating, and a clipped region
  contains exactly the pixels the clip rect allows.
- Determinism: identical output across runs, matching the property the
  writer tests already assert.

## Risks

- **Scope.** Phases 3 through 7 are individually weeks. This plan is
  honest about that; phase 0 exists so the plan can deliver value
  immediately and be abandoned at any phase boundary without waste.
- **Font rasterization is the hidden cost**, not paths or colors. Type 1
  CFF, TrueType, CID-keyed CFF, Type 3, and base-14 are five different
  code paths. Phase 4 is the phase most likely to overrun.
- **Transparency groups** are where renderers usually get subtly wrong
  and where visual tests are weakest. Consider deferring to phase 8
  explicitly rather than half-implementing.
- **Naming matters for trust.** Calling a poppler-backed function
  `renderPage` would misrepresent what the package does. Phase 0 is named
  for what it is.
