## HarfBuzz text shaping (M3b).
##
## shapeText runs the Unicode text of one run through HarfBuzz at
## 1000 units per em, returning glyph ids plus advances for width
## measurement and the M6 writer's subsetting. Fonts come from embedded
## FontFile streams (TrueType/OpenType); base-14 fonts have no program
## and Adobe Type 1 is not supported by HarfBuzz, both reported as
## clear errors rather than silent zeros.

import harfbuzz
import ./types
import ./lexer
import ./cos
import ./docmodel
import ./filters

type
  ShapedGlyph* = object
    glyphId*: int
    xAdvance*: float64 ## font units at 1000 upm
    yAdvance*: float64
    cluster*: int ## byte index into the input text

  ShapedRun* = object
    glyphs*: seq[ShapedGlyph]
    text*: string

  ShapedFont* = object
    ## A cached HarfBuzz shaping context for one font program: one
    ## blob, face and font shared by every shape call. The font scale
    ## is fixed at 1000 upm, so all advances read out in PDF glyph
    ## units. `bytes` keeps the program alive because the blob does
    ## not copy; keep the `ShapedFont` (not just the bytes) reachable
    ## while shaping. Call `close` when done.
    bytes*: string
    blob*: ptr hb_blob_t
    face*: ptr hb_face_t
    font*: ptr hb_font_t
    upem*: int

proc close*(sf: var ShapedFont) =
  ## Destroy the HarfBuzz objects. Idempotent; safe on a zero value.
  if sf.font != nil:
    hb_font_destroy(sf.font)
    sf.font = nil
  if sf.face != nil:
    hb_face_destroy(sf.face)
    sf.face = nil
  if sf.blob != nil:
    hb_blob_destroy(sf.blob)
    sf.blob = nil

proc openShapedFont*(fontBytes: string): ShapedFont =
  ## Build a shaping context over `fontBytes` (TrueType/OpenType).
  ## Fails loudly on empty input, refused programs, and glyph-less
  ## faces (Adobe Type 1 is not supported by HarfBuzz).
  if fontBytes.len == 0:
    pdfFail("cannot shape text with empty font program")
  result.bytes = fontBytes
  result.blob = hb_blob_create(cstring(result.bytes),
    cuint(result.bytes.len), HB_MEMORY_MODE_READONLY, nil, nil)
  if result.blob == nil:
    pdfFail("HarfBuzz refused the font program")
  result.face = hb_face_create(result.blob, 0)
  result.font = hb_font_create(result.face)
  hb_ot_font_set_funcs(result.font)
  hb_font_set_scale(result.font, 1000, 1000)
  result.upem = int(hb_face_get_upem(result.face))
  if hb_face_get_glyph_count(result.face) == 0:
    close(result)
    pdfFail("font program has no glyphs (Adobe Type 1 programs are " &
      "not supported by HarfBuzz; embed TrueType or OpenType)")

proc shapeInto*(sf: ShapedFont, text: string, run: var ShapedRun) =
  let buf = hb_buffer_create()
  hb_buffer_add_utf8(buf, cstring(text), cint(text.len), 0,
    cint(text.len))
  hb_buffer_guess_segment_properties(buf)
  hb_shape(sf.font, buf, nil, 0)
  var nInfo: cuint = 0
  var nPos: cuint = 0
  let infos = cast[ptr UncheckedArray[hb_glyph_info_t]](
    hb_buffer_get_glyph_infos(buf, addr nInfo))
  let poss = cast[ptr UncheckedArray[hb_glyph_position_t]](
    hb_buffer_get_glyph_positions(buf, addr nPos))
  let n = min(int(nInfo), int(nPos))
  for i in 0 ..< n:
    run.glyphs.add(ShapedGlyph(glyphId: int(infos[i].codepoint),
      xAdvance: float64(poss[i].x_advance),
      yAdvance: float64(poss[i].y_advance),
      cluster: int(infos[i].cluster)))
  hb_buffer_destroy(buf)

proc shapedWidth*(sf: ShapedFont, text: string): float64 =
  ## Total horizontal advance of `text` in font units at 1000 upm,
  ## including kerning, ligatures and GPOS adjustments. Empty text
  ## measures zero.
  if text.len == 0:
    return 0.0
  var run = ShapedRun(glyphs: @[], text: text)
  shapeInto(sf, text, run)
  for g in run.glyphs:
    result += g.xAdvance

proc nominalGlyph*(sf: ShapedFont, unicode: uint32): uint32 =
  ## Glyph id for a Unicode scalar via the font's cmap, or 0 (.notdef)
  ## when the font has no glyph for it.
  var g: hb_codepoint_t = 0
  if hb_font_get_nominal_glyph(sf.font, hb_codepoint_t(unicode),
      addr g) == 0:
    return 0
  uint32(g)

proc glyphAdvance1000*(sf: ShapedFont, glyph: uint32): float64 =
  ## Horizontal advance of one glyph id in font units at 1000 upm.
  float64(hb_font_get_glyph_h_advance(sf.font,
    hb_codepoint_t(glyph)))

proc headBBox*(sf: ShapedFont): tuple[xMin, yMin, xMax, yMax: int] =
  ## The sfnt `head` bounding box, scaled to 1000 upm for
  ## /FontDescriptor /FontBBox.
  let tag = HB_TAG('h', 'e', 'a', 'd')
  let tb = hb_face_reference_table(sf.face, tag)
  if tb == nil:
    pdfFail("font program has no head table")
  var n: cuint = 0
  let p = cast[ptr UncheckedArray[uint8]](hb_blob_get_data(tb,
    addr n))
  if n < 54:
    hb_blob_destroy(tb)
    pdfFail("truncated head table in font program")
  template s16(at: int): int =
    let v = int(p[at]) shl 8 or int(p[at + 1])
    if v >= 0x8000: v - 0x10000 else: v
  let k = 1000.0 / float64(max(sf.upem, 1))
  result = (xMin: int(float64(s16(36)) * k),
    yMin: int(float64(s16(38)) * k),
    xMax: int(float64(s16(40)) * k),
    yMax: int(float64(s16(42)) * k))
  hb_blob_destroy(tb)

proc hExtents1000*(sf: ShapedFont): tuple[ascender, descender: int] =
  ## Horizontal ascender/descender in font units at 1000 upm for
  ## /FontDescriptor /Ascent and /Descent.
  var e: hb_font_extents_t
  if hb_font_get_h_extents(sf.font, addr e) == 0:
    pdfFail("font program has no horizontal extents")
  (ascender: int(e.ascender), descender: int(e.descender))

proc loadFontBytes*(fontDict: CosObj, d: var PdfDoc): string =
  ## Decode the embedded program from /FontDescriptor (/FontFile2 or
  ## /FontFile3 preferred, /FontFile last). Fails when the font is not
  ## embedded.
  var desc = fontDict.dictGet("FontDescriptor")
  if desc.kind == coRef:
    desc = d.resolve(desc)
  if desc.kind != coDict:
    pdfFail("no /FontDescriptor: font is not embedded, " &
      "shaping needs an embedded program")
  for key in ["FontFile2", "FontFile3", "FontFile"]:
    var s = desc.dictGet(key)
    if s.kind == coRef:
      s = d.resolve(s)
    if s.kind == coStream:
      let raw = decodeCosStream(s)
      if raw.len == 0:
        pdfFail("empty embedded font program in /" & key)
      return raw
  pdfFail("no embedded font program (/FontFile, /FontFile2 or " &
    "/FontFile3) in /FontDescriptor")

proc shapeText*(fontBytes, text: string): ShapedRun =
  ## Shape UTF-8 text with HarfBuzz. Advances are horizontal font
  ## units at 1000 upm; divide by 1000 and scale by the font size for
  ## text-space advances.
  result = ShapedRun(glyphs: @[], text: text)
  if text.len == 0:
    return
  var sf = openShapedFont(fontBytes)
  defer: close(sf)
  shapeInto(sf, text, result)
