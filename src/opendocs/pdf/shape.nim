## Text shaping (M3b), backed by the pure-Nim harfnim engine.
##
## shapeText runs the Unicode text of one run through harfnim at
## 1000 units per em, returning glyph ids plus advances for width
## measurement and the M6 writer's subsetting. Fonts come from embedded
## FontFile streams (TrueType/OpenType); base-14 fonts have no program
## and Adobe Type 1 is not supported by harfnim, both reported as
## clear errors rather than silent zeros.

import std/options
import harfnim/buffer as hbuf
import harfnim/feature as hfeat
import harfnim/font as hfont
import harfnim/scale as hscale
import harfnim/sfnt as hsfnt
import harfnim/shape as hshape
import harfnim/tag as htag
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
    ## A cached shaping context for one font program: the parsed sfnt
    ## plus a harfnim shaper scaled to 1000 upm, shared by every shape
    ## call. `bytes` keeps the program alive. Call `close` when done
    ## (idempotent; safe on a zero value).
    bytes*: string
    parsed*: hsfnt.SfntFont
    shaper*: hfont.ShaperFont
    upem*: int

proc close*(sf: var ShapedFont) =
  ## Release the shaping context. Idempotent; safe on a zero value.
  sf.parsed = nil
  sf.shaper = nil
  sf.upem = 0

proc defaultFeatures(): seq[hfeat.Feature] =
  ## HarfBuzz-compatible default: this set is on unless the caller mentions the tag;
  ## harfnim applies only requested features, so request them (mirrors
  ## harfnim's own hr-shape default list).
  const names = ["abvm", "blwm", "calt", "ccmp", "clig", "curs",
    "dist", "kern", "liga", "locl", "mark", "mkmk", "rlig", "rclt"]
  result = newSeq[hfeat.Feature](names.len)
  for i, n in names:
    result[i] = hfeat.globalFeature(htag.tagFromStr(n), 1)

proc openShapedFont*(fontBytes: string): ShapedFont =
  ## Build a shaping context over `fontBytes` (TrueType/OpenType).
  ## Fails loudly on empty input, refused programs, and glyph-less
  ## faces (Adobe Type 1 is not supported by harfnim).
  if fontBytes.len == 0:
    pdfFail("cannot shape text with empty font program")
  result.bytes = fontBytes
  try:
    result.parsed = hsfnt.parseFontString(fontBytes)
  except hsfnt.FontError as e:
    pdfFail("harfnim refused the font program (" & e.msg &
      "; Adobe Type 1 programs are not supported, embed TrueType or OpenType)")
  result.shaper = hfont.newShaperFont(result.parsed)
  result.shaper.setScale(1000)
  result.upem = int(result.parsed.unitsPerEm)
  if result.parsed.numGlyphs == 0:
    close(result)
    pdfFail("font program has no glyphs (Adobe Type 1 programs are " &
      "not supported by harfnim; embed TrueType or OpenType)")

proc shapeInto*(sf: ShapedFont, text: string, run: var ShapedRun) =
  var buf = hbuf.newBuffer()
  buf.pushStr(text)
  hshape.shape(sf.shaper, buf, defaultFeatures())
  for i in 0 ..< buf.len:
    run.glyphs.add(ShapedGlyph(glyphId: int(buf.info[i].glyphId),
      xAdvance: float64(buf.pos[i].xAdvance),
      yAdvance: float64(buf.pos[i].yAdvance),
      cluster: int(buf.info[i].cluster)))

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
  let g = sf.shaper.nominalGlyph(unicode)
  if g.isNone:
    return 0
  g.get.value

proc glyphAdvance1000*(sf: ShapedFont, glyph: uint32): float64 =
  ## Horizontal advance of one glyph id in font units at 1000 upm.
  float64(sf.shaper.hAdvance(hbuf.newGlyphId(glyph)))

proc headBBox*(sf: ShapedFont): tuple[xMin, yMin, xMax, yMax: int] =
  ## The sfnt `head` bounding box, scaled to 1000 upm for
  ## /FontDescriptor /FontBBox.
  let t = sf.parsed.tableData(htag.tagFromStr("head").toU32())
  if not t.ok:
    pdfFail("font program has no head table")
  let b = sf.parsed.bytes
  if t.offset + 54 > b.len:
    pdfFail("truncated head table in font program")
  template s16(at: int): int =
    let v = int(b[at]) shl 8 or int(b[at + 1])
    if v >= 0x8000: v - 0x10000 else: v
  let k = 1000.0 / float64(max(sf.upem, 1))
  result = (xMin: int(float64(s16(t.offset + 36)) * k),
    yMin: int(float64(s16(t.offset + 38)) * k),
    xMax: int(float64(s16(t.offset + 40)) * k),
    yMax: int(float64(s16(t.offset + 42)) * k))

proc hExtents1000*(sf: ShapedFont): tuple[ascender, descender: int] =
  ## Horizontal ascender/descender in font units at 1000 upm for
  ## /FontDescriptor /Ascent and /Descent.
  let t = sf.parsed.tableData(htag.tagFromStr("hhea").toU32())
  if not t.ok:
    pdfFail("font program has no horizontal metrics")
  let b = sf.parsed.bytes
  if t.offset + 8 > b.len:
    pdfFail("truncated hhea table in font program")
  template s16(at: int): int32 =
    let v = int(b[at]) shl 8 or int(b[at + 1])
    int32(if v >= 0x8000: v - 0x10000 else: v)
  # Scale like the shaper (HarfBuzz-identical fixed-point rounding).
  let asc = sf.shaper.scale.scaleY(s16(t.offset + 4))
  let desc = sf.shaper.scale.scaleY(s16(t.offset + 6))
  (ascender: int(asc), descender: int(desc))

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
      let raw = decodeCosStream(s, d.limits)
      if raw.len == 0:
        pdfFail("empty embedded font program in /" & key)
      return raw
  pdfFail("no embedded font program (/FontFile, /FontFile2 or " &
    "/FontFile3) in /FontDescriptor")

proc shapeText*(fontBytes, text: string): ShapedRun =
  ## Shape UTF-8 text with harfnim. Advances are horizontal font
  ## units at 1000 upm; divide by 1000 and scale by the font size for
  ## text-space advances.
  result = ShapedRun(glyphs: @[], text: text)
  if text.len == 0:
    return
  var sf = openShapedFont(fontBytes)
  defer: close(sf)
  shapeInto(sf, text, result)

proc tablePresent*(sf: ShapedFont, a, b, c, d: char): bool =
  ## True when the font program carries the named sfnt table.
  var name = newString(4)
  name[0] = a
  name[1] = b
  name[2] = c
  name[3] = d
  sf.parsed.hasTable(htag.tagFromStr(name).toU32())

proc glyphExtents1000*(sf: ShapedFont,
    glyph: uint32): tuple[ok: bool, xBearing, yBearing, width,
    height: int] =
  ## Scaled glyph extents (1000 upm), or ok=false when the glyph has
  ## no usable outline.
  let e = sf.shaper.glyphExtents(hbuf.newGlyphId(glyph))
  if e.isNone:
    return (false, 0, 0, 0, 0)
  let v = e.get
  (true, int(v.xBearing), int(v.yBearing), int(v.width), int(v.height))
