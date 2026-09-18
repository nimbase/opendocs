## PDF font embedding for the writer, backed by HarfBuzz.
##
## The M6 builder assembles pages from caller-supplied dictionaries,
## which left every caller hand-rolling font objects. This module
## closes the loop: measure text with shaped advances, draw text
## lines, wrap paragraphs, and embed (optionally subset) TrueType
## programs with matching /Widths and /ToUnicode, so our own reader
## round-trips the text.
##
## HarfBuzz supplies the font intelligence (shaping for measurement,
## subsetting for size); every COS object is ours. Typical flow:
##
##   var use = FontUse(fontBytes: dejavu, baseName: "DejaVuSans")
##   let words = wrapText(sf, "Hello writer", 24.0, 468.0)
##   var content: string
##   for i, line in words:
##     use.noteUse(line)
##     content.add(drawTextLine(72.0, 720.0 - float64(i) * 28.0,
##       "F2", 24.0, line))
##   var b = newPdfBuilder()
##   let fonts = b.finalizeFonts({"F2": use}.toTable)
##   let cnum = b.addContentStream(content)
##   discard b.addPage(612.0, 792.0, cnum, fontResources(fonts))
##
## Encoding boundary: the `FontUse` path above is WinAnsi only and
## fails loudly outside it. The `CidFontUse` path below covers full
## Unicode: lines are shaped with HarfBuzz, shown as 2-byte CIDs under
## /Identity-H in a Type0 font, and mapped back to Unicode with a
## /ToUnicode CMap, so our own reader round-trips the text. Color
## glyphs pass through whatever HarfBuzz subsets (COLR, CBDT, sbix);
## SVG-in-OpenType color has no subset support upstream and fails
## loudly. System fonts are out of scope: the caller supplies the
## program bytes (for example from the harfbuzz checkout's test data).

import std/algorithm
import std/strutils
import std/tables
import std/unicode
import harfbuzz
import ./cos
import ./write
import ./shape
import ./cmap

type
  FontUse* = object
    ## One font program plus the byte codes used with it. Collect
    ## while drawing, then hand to `finalizeFonts` once, just before
    ## `buildPdf`: the subset is only known after all text is drawn,
    ## but the builder assigns object numbers eagerly.
    fontBytes*: string ## full program; the table keeps it alive
    baseName*: string  ## PostScript name, e.g. "DejaVuSans"
    codes*: Table[int, uint32] ## WinAnsi byte code to Unicode scalar

proc winAnsiByte*(r: Rune): int =
  ## WinAnsi byte for a rune, or -1 when not encodable.
  let u = int(r)
  if u < 0 or u > 0xFFFF:
    return -1
  for b in 0 .. 255:
    if winAnsiTable[b] == u:
      return b
  -1

proc noteUse*(u: var FontUse, text: string) =
  ## Record every rune of `text` in the used-code table. Fails loudly
  ## on runes outside WinAnsi.
  for r in text.runes:
    let b = winAnsiByte(r)
    if b < 0:
      pdfFail("text U+" & toHex(int(r), 4) &
        " is outside WinAnsi; CID-keyed fonts are future work")
    u.codes[b] = uint32(r)

proc subsetFont*(fontBytes: string,
    unicodes: openArray[uint32]): string =
  ## Subset a TrueType/OpenType program to `unicodes` via HarfBuzz,
  ## keeping hinting and `.notdef`. Fails loudly on empty input or a
  ## failed subset operation.
  if fontBytes.len == 0:
    pdfFail("cannot subset an empty font program")
  var sf = openShapedFont(fontBytes)
  defer: close(sf)
  let input = hb_subset_input_create_or_fail()
  if input == nil:
    pdfFail("HarfBuzz refused the subset input")
  defer: hb_subset_input_destroy(input)
  let uset = hb_subset_input_unicode_set(input)
  for u in unicodes:
    hb_set_add(uset, hb_codepoint_t(u))
  let sub = hb_subset_or_fail(sf.face, input)
  if sub == nil:
    pdfFail("HarfBuzz failed to subset the font program")
  defer: hb_face_destroy(sub)
  let bb = hb_face_reference_blob(sub)
  if bb == nil:
    pdfFail("subset produced no font blob")
  defer: hb_blob_destroy(bb)
  var n: cuint = 0
  let p = hb_blob_get_data(bb, addr n)
  if p == nil or n == 0:
    pdfFail("subset produced no font bytes")
  result = newString(int(n))
  copyMem(addr result[0], p, int(n))

proc measureText*(sf: ShapedFont, text: string,
    size: float64): float64 =
  ## Text-space width of `text` at `size`: total shaped advance over
  ## 1000 upm times the size. Includes kerning, ligatures and GPOS.
  sf.shapedWidth(text) / 1000.0 * size

# ---------------------------------------------------------------------------
# Builtin base-14 Helvetica: unembedded measurement for the default font
# ---------------------------------------------------------------------------
#
# Advances below are the Adobe Helvetica AFM widths (1000 upm, indexed
# by WinAnsi byte). Spot-verified against the licensed Apple Helvetica
# cut (A 722, a 556, m 833, i 222, space 278, Scaron 667, perthousand
# 1000, endash 556) and Ghostscript output for the ASCII range
# (quoteright 222); modern Helvetica cuts drift on quotes and Euro, so
# the Adobe values win as the documented PDF base-14 standard. Zeros
# mean no Adobe glyph: C0 controls, DEL, the WinAnsi-undefined C1
# slots, and Euro U+20AC (Adobe Helvetica predates it). Those fail
# loudly in `builtinMeasure` instead of wrapping on a wrong width.

const helveticaWidths*: array[256, int] = [
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, # 0-15
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, # 16-31
  278, 278, 355, 556, 556, 889, 667, 222, # 32-39 space ! " # $ % & '
  333, 333, 389, 584, 278, 333, 278, 278, # 40-47 ( ) * + , - . /
  556, 556, 556, 556, 556, 556, 556, 556, # 48-55 0-7
  556, 556, 278, 278, 584, 584, 584, 556, # 56-63 8 9 : ; < = > ?
  1015, 722, 722, 722, 722, 667, 611, 778, # 64-71 @ A-G
  722, 278, 500, 667, 556, 833, 722, 778, # 72-79 H-O
  667, 778, 722, 667, 611, 722, 667, 944, # 80-87 P-W
  667, 667, 611, 278, 278, 278, 469, 556, # 88-95 X Y Z [ \ ] ^ _
  222, 556, 556, 500, 556, 556, 278, 556, # 96-103 ` a-g
  556, 222, 222, 500, 222, 833, 556, 556, # 104-111 h-o
  556, 556, 333, 500, 278, 556, 500, 722, # 112-119 p-w
  500, 500, 500, 334, 260, 334, 584, 0, # 120-127 x y z { | } ~ DEL
  0, 0, 222, 556, 222, 1000, 556, 556, # 128-135 Euro - , f , ... t d
  469, 1000, 667, 333, 1000, 0, 611, 0, # 136-143 ^ %o S < OE - Z -
  0, 222, 222, 222, 222, 556, 556, 1000, # 144-151 - ' " " . - - --
  222, 822, 500, 333, 1000, 0, 611, 667, # 152-159 ~ TM s > oe - z Ydier
  278, 333, 556, 556, 556, 556, 260, 556, # 160-167 nbsp i c £ o ¥ | §
  333, 737, 370, 556, 584, 333, 737, 333, # 168-175 ¨ © a « ¬ ­ ® ¯
  400, 584, 333, 333, 222, 556, 537, 278, # 176-183 ° ± ² ³ ´ µ ¶ ·
  333, 333, 370, 556, 834, 834, 834, 611, # 184-191 ¸ ¹ º » ¼ ½ ¾ ¿
  722, 722, 722, 722, 722, 722, 1000, 722, # 192-199 À-Æ Ç
  667, 667, 667, 667, 278, 278, 278, 278, # 200-207 È-Ï
  722, 722, 778, 778, 778, 778, 778, 584, # 208-215 Ð Ñ Ò-Ö ×
  778, 722, 722, 722, 722, 667, 667, 611, # 216-223 Ø Ù-Ü Ý Þ ß
  556, 556, 556, 556, 556, 556, 889, 500, # 224-231 à-å æ ç
  556, 556, 556, 556, 222, 222, 222, 222, # 232-239 è-ï
  500, 556, 556, 556, 556, 556, 556, 584, # 240-247 ð ñ ò-ö ÷
  556, 556, 556, 556, 556, 500, 556, 500] # 248-255 ø ù-ü ý þ ÿ

proc builtinMeasure*(text: string, size: float64): float64 =
  ## Text-space width of WinAnsi `text` at `size` from the Helvetica
  ## AFM table. No kerning or ligatures (base-14 has neither in the
  ## writer). Fails loudly outside WinAnsi and on codes with no Adobe
  ## advance (controls, DEL, undefined C1 slots, Euro): those need a
  ## loaded font instead.
  var total = 0
  for r in text.runes:
    let b = winAnsiByte(r)
    if b < 0:
      pdfFail("text U+" & toHex(int(r), 4) &
        " is outside WinAnsi; load a font for full Unicode")
    let w = helveticaWidths[b]
    if w == 0:
      pdfFail("U+" & toHex(int(r), 4) &
        " has no advance in builtin Helvetica; load a font for it")
    total += w
  float64(total) / 1000.0 * size

proc builtinWrapText*(text: string, size,
    maxWidth: float64): seq[string] =
  ## `wrapText` over AFM widths: same greedy rules, `\n` breaks, space
  ## runs collapse, overlong words overflow on their own line.
  result = @[]
  for para in text.split('\n'):
    var line = ""
    var lineW = 0.0
    let spW = builtinMeasure(" ", size)
    for word in para.split(' '):
      if word.len == 0:
        continue
      let w = builtinMeasure(word, size)
      if line.len == 0:
        line = word
        lineW = w
      elif lineW + spW + w <= maxWidth + 1e-6:
        line.add(' ')
        line.add(word)
        lineW += spW + w
      else:
        result.add(line)
        line = word
        lineW = w
    result.add(line)

proc builtinFontDict*(): CosObj =
  ## Unembedded base-14 Helvetica font dictionary. The viewer
  ## substitutes its own Helvetica; nothing is measured from or
  ## embedded into the file.
  CosObj(kind: coDict, keys: @["Type", "Subtype", "BaseFont"],
    vals: @[CosObj(kind: coName, name: "Font"),
      CosObj(kind: coName, name: "Type1"),
      CosObj(kind: coName, name: "Helvetica")])

proc drawTextLine*(x, y: float64, resName: string, size: float64,
    text: string): string =
  ## One `BT...ET` content line drawing `text` (WinAnsi, already
  ## recorded via `noteUse`) with font resource `resName`.
  "BT /" & resName & " " & $size & " Tf " & $x & " " & $y & " Td " &
    writeStr(text) & " Tj ET"

proc wrapText*(sf: ShapedFont, text: string, size,
    maxWidth: float64): seq[string] =
  ## Greedy word wrap on shaped widths. `\n` forces a break, runs of
  ## spaces collapse, and a word wider than `maxWidth` takes its own
  ## line (overflowing, never hyphenated). A 1e-6 epsilon keeps float
  ## dust from breaking lines that measure exactly at the width.
  result = @[]
  for para in text.split('\n'):
    var line = ""
    var lineW = 0.0
    let spW = measureText(sf, " ", size)
    for word in para.split(' '):
      if word.len == 0:
        continue
      let w = measureText(sf, word, size)
      if line.len == 0:
        line = word
        lineW = w
      elif lineW + spW + w <= maxWidth + 1e-6:
        line.add(' ')
        line.add(word)
        lineW += spW + w
      else:
        result.add(line)
        line = word
        lineW = w
    result.add(line)

proc uniHex(u: uint32): string =
  if u <= 0xFFFF:
    toHex(int(u), 4).toUpperAscii()
  else:
    let v = u - 0x10000
    toHex(int(0xD800 + (v shr 10)), 4).toUpperAscii() &
      toHex(int(0xDC00 + (v and 0x3FF)), 4).toUpperAscii()

proc toUnicodeCMap(codes: Table[int, uint32]): string =
  var keys: seq[int] = @[]
  for c in codes.keys:
    keys.add(c)
  keys.sort()
  result = "/CIDInit /ProcSet findresource begin\n" &
    "12 dict begin\nbegincmap\n" &
    "/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) " &
    "/Supplement 0 >> def\n" &
    "/CMapName /Adobe-Identity-UCS def\n/CMapType 2 def\n" &
    "1 begincodespacerange\n<00> <FF>\nendcodespacerange\n" &
    $keys.len & " beginbfchar\n"
  for c in keys:
    result.add("<" & toHex(c, 2).toUpperAscii() & "> <" &
      uniHex(codes[c]) & ">\n")
  result.add("endbfchar\nendcmap\nCMapName currentdict /CMap " &
    "defineresource pop\nend\nend\n")

proc fontResources*(fonts: Table[string, int]): CosObj =
  ## A /Resources dict with a /Font subdict from resource name to
  ## font-dict object number (as built by `finalizeFonts`).
  var names: seq[string] = @[]
  for k in fonts.keys:
    names.add(k)
  names.sort()
  var items: seq[CosObj] = @[]
  for n in names:
    items.add(CosObj(kind: coRef, refNum: fonts[n], refGen: 0))
  CosObj(kind: coDict, keys: @["Font"],
    vals: @[CosObj(kind: coDict, keys: names, vals: items)])

proc embedFont*(b: var PdfBuilder, baseName: string, fontBytes: string,
    codes: Table[int, uint32], subset = true): int =
  ## Embed a TrueType program with matching /Widths and /ToUnicode.
  ## Returns the font-dict object number. With `subset` (default) only
  ## the used unicodes are embedded; otherwise the full program ships.
  ## Widths and descriptor metrics come from the embedded bytes, so
  ## laid-out breaks match the real font.
  if codes.len == 0:
    pdfFail("embedFont needs at least one used code")
  var prog = fontBytes
  if subset:
    var uni: seq[uint32] = @[]
    for u in codes.values:
      uni.add(u)
    prog = subsetFont(fontBytes, uni)
  var sf = openShapedFont(prog)
  defer: close(sf)
  var first = 256
  var last = -1
  for c in codes.keys:
    first = min(first, c)
    last = max(last, c)
  var widths: seq[CosObj] = @[]
  for c in first .. last:
    if codes.hasKey(c):
      let g = sf.nominalGlyph(codes[c])
      widths.add(CosObj(kind: coInt,
        ival: int(sf.glyphAdvance1000(g) + 0.5)))
    else:
      widths.add(CosObj(kind: coInt, ival: 0))
  let bbox = sf.headBBox()
  let ext = sf.hExtents1000()
  var capH = ext.ascender
  let hGlyph = sf.nominalGlyph(0x48)
  if hGlyph != 0:
    var e: hb_glyph_extents_t
    if hb_font_get_glyph_extents(sf.font, hb_codepoint_t(hGlyph),
        addr e) != 0:
      capH = int(e.height)
  let fileNum = b.addStream(CosObj(kind: coDict,
    keys: @["Length1"],
    vals: @[CosObj(kind: coInt, ival: prog.len)]), prog)
  let descNum = b.addValue(CosObj(kind: coDict,
    keys: @["Type", "FontName", "Flags", "FontBBox", "ItalicAngle",
      "Ascent", "Descent", "CapHeight", "StemV", "FontFile2"],
    vals: @[CosObj(kind: coName, name: "FontDescriptor"),
      CosObj(kind: coName, name: baseName),
      CosObj(kind: coInt, ival: 32),
      CosObj(kind: coArray, items: @[
        CosObj(kind: coInt, ival: bbox.xMin),
        CosObj(kind: coInt, ival: bbox.yMin),
        CosObj(kind: coInt, ival: bbox.xMax),
        CosObj(kind: coInt, ival: bbox.yMax)]),
      CosObj(kind: coInt, ival: 0),
      CosObj(kind: coInt, ival: ext.ascender),
      CosObj(kind: coInt, ival: ext.descender),
      CosObj(kind: coInt, ival: capH),
      CosObj(kind: coInt, ival: 80),
      CosObj(kind: coRef, refNum: fileNum, refGen: 0)]))
  let tuNum = b.addStream(CosObj(kind: coDict, keys: @[], vals: @[]),
    toUnicodeCMap(codes))
  result = b.addValue(CosObj(kind: coDict,
    keys: @["Type", "Subtype", "BaseFont", "FirstChar", "LastChar",
      "Widths", "Encoding", "FontDescriptor", "ToUnicode"],
    vals: @[CosObj(kind: coName, name: "Font"),
      CosObj(kind: coName, name: "TrueType"),
      CosObj(kind: coName, name: baseName),
      CosObj(kind: coInt, ival: first),
      CosObj(kind: coInt, ival: last),
      CosObj(kind: coArray, items: widths),
      CosObj(kind: coName, name: "WinAnsiEncoding"),
      CosObj(kind: coRef, refNum: descNum, refGen: 0),
      CosObj(kind: coRef, refNum: tuNum, refGen: 0)]))

proc finalizeFonts*(b: var PdfBuilder,
    uses: Table[string, FontUse], subset = true): Table[string, int] =
  ## Embed every collected `FontUse` (resource name to use) and return
  ## resource name to font-dict object number, for `fontResources`.
  ## Names embed in sorted order for deterministic output.
  result = initTable[string, int]()
  var names: seq[string] = @[]
  for k in uses.keys:
    names.add(k)
  names.sort()
  for n in names:
    let u = uses[n]
    result[n] = b.embedFont(u.baseName, u.fontBytes, u.codes, subset)

# ---------------------------------------------------------------------------
# CID-keyed Type0 fonts: full Unicode via HarfBuzz shaping
# ---------------------------------------------------------------------------
#
# A `FontUse` fixes byte codes up front, which cannot survive subset
# GID renumbering or shaped glyph runs (ligatures have no single
# code). The CID path therefore assigns CIDs eagerly in first-use
# order at note/draw time and resolves them to subset GIDs only at
# `embedCidFont`, through a /CIDToGIDMap stream. Deliberately not an
# explicit old-to-new subset mapping: those must be monotonic or OTS
# rejects the font, and first-use order is arbitrary.

type
  CidFontUse* = object
    ## One font program plus the shaped glyphs used with it. Collect
    ## while drawing, then hand to `finalizeFonts` once, just before
    ## `buildPdf`, like `FontUse`. CIDs start at 1 in first-use order
    ## of the full-font GIDs; 0 stays .notdef.
    fontBytes*: string ## full program; the table keeps it alive
    baseName*: string  ## PostScript name, e.g. "DejaVuSans"
    cids*: Table[uint32, int] ## full-font GID to CID
    texts*: Table[int, string] ## CID to UTF-8 destination text

  CidSeg = object ## one cluster group in visual order
    cids: seq[int]
    text: string
    shaped: float64 ## summed shaped x advance, 1000 upm
    nominal: float64 ## summed hmtx advance, 1000 upm

proc runeSlices(text: string): seq[tuple[r: Rune, off, len: int]] =
  ## Runes of `text` with their UTF-8 byte offsets.
  var i = 0
  while i < text.len:
    let off = i
    var r: Rune
    fastRuneAt(text, i, r, true)
    result.add((r, off, i - off))

proc groupShaped(sf: ShapedFont, text: string,
    u: var CidFontUse): seq[CidSeg] =
  ## Shape `text` and group the glyphs by contiguous equal clusters,
  ## assigning CIDs in first-use order. Each group's text is the rune
  ## slice from its cluster to the next higher cluster in the whole
  ## line (logical byte order, so RTL lines map correctly); glyphs
  ## sharing one cluster (Indic splits) repeat the slice on every
  ## glyph, matching what mainstream writers emit.
  var run = ShapedRun(glyphs: @[], text: text)
  shapeInto(sf, text, run)
  if run.glyphs.len == 0:
    return @[]
  let slices = runeSlices(text)
  var bounds: seq[int] = @[] ## sorted distinct cluster values
  for g in run.glyphs:
    if bounds.len == 0 or bounds[^1] != g.cluster:
      if g.cluster notin bounds:
        bounds.add(g.cluster)
  bounds.sort()
  result = @[]
  var i = 0
  while i < run.glyphs.len:
    var j = i
    while j + 1 < run.glyphs.len and
        run.glyphs[j + 1].cluster == run.glyphs[i].cluster:
      inc j
    let c = run.glyphs[i].cluster
    var edge = text.len
    for b in bounds:
      if b > c:
        edge = b
        break
    var t = ""
    for s in slices:
      if s.off >= c and s.off < edge:
        t.add($s.r)
    var seg = CidSeg(cids: @[], text: t, shaped: 0.0, nominal: 0.0)
    for k in i .. j:
      let gid = uint32(run.glyphs[k].glyphId)
      if gid == 0:
        pdfFail("no glyph for run starting at byte " & $c &
          " in font " & u.baseName & "; CID fonts need full coverage")
      if not u.cids.hasKey(gid):
        u.cids[gid] = u.cids.len + 1
        u.texts[u.cids[gid]] = t
      seg.cids.add(u.cids[gid])
      seg.shaped += run.glyphs[k].xAdvance
      seg.nominal += sf.glyphAdvance1000(gid)
    result.add(seg)
    i = j + 1

proc hasTable(face: ptr hb_face_t, a, b, c, d: char): bool =
  ## HarfBuzz returns an empty blob (not nil) for missing tables, so
  ## presence means nonzero length.
  let tb = hb_face_reference_table(face, HB_TAG(a, b, c, d))
  if tb == nil:
    return false
  var n: cuint = 0
  discard hb_blob_get_data(tb, addr n)
  hb_blob_destroy(tb)
  n > 0

proc svgOnly(sf: ShapedFont, gid: uint32, r: Rune): bool =
  ## Heuristic for SVG-in-OpenType color glyphs, which HarfBuzz
  ## cannot subset (dropped silently upstream): an SVG table exists
  ## and the glyph has no outline extents despite a nonzero advance.
  ## Whitespace and zero-advance marks are exempt.
  if not hasTable(sf.face, 'S', 'V', 'G', ' '):
    return false
  if r == Rune(0x20) or r == Rune(0x09) or r == Rune(0x0A) or
      r == Rune(0x0D) or r == Rune(0x00A0):
    return false
  if sf.glyphAdvance1000(gid) == 0.0:
    return false
  var e: hb_glyph_extents_t
  if hb_font_get_glyph_extents(sf.font, hb_codepoint_t(gid),
      addr e) == 0:
    return true
  e.width == 0 and e.height == 0

proc noteCidUse*(u: var CidFontUse, sf: ShapedFont, text: string) =
  ## Record every shaped glyph of `text` in the CID table. Needs the
  ## open `ShapedFont` because CIDs key on shaped (not nominal)
  ## glyph ids. Fails loudly on uncovered runes and SVG-only color.
  for seg in groupShaped(sf, text, u):
    discard seg
  if hasTable(sf.face, 'S', 'V', 'G', ' '):
    for gid, cid in u.cids.pairs:
      for r in u.texts[cid].runes:
        if svgOnly(sf, gid, r):
          pdfFail("text U+" & toHex(int(r), 4) &
            " is SVG-only color, which HarfBuzz cannot subset")

proc drawCidLine*(u: var CidFontUse, sf: ShapedFont, x, y: float64,
    resName: string, size: float64, text: string): string =
  ## One `BT...ET` content line drawing the shaped `text` with font
  ## resource `resName`. Glyphs show as 2-byte hex CIDs; adjacent
  ## cluster groups merge into one hex string, splitting only where a
  ## `TJ` number must correct kerning (shaped advance drifting from
  ## the nominal /W advance), so laid-out breaks match measured
  ## widths and kerned output stays compact.
  let segs = groupShaped(sf, text, u)
  var parts: seq[string] = @[]
  var adjs: seq[int] = @[] ## adjustment before each part but the first
  var cur = ""
  for i, seg in segs:
    if i > 0:
      let prev = segs[i - 1]
      let adj = int(prev.nominal - prev.shaped + 0.5)
      if adj != 0:
        parts.add(cur)
        adjs.add(adj)
        cur = ""
    for cid in seg.cids:
      cur.add(toHex(cid, 4).toUpperAscii())
  parts.add(cur)
  var show: string
  if parts.len == 1:
    show = "<" & parts[0] & "> Tj"
  else:
    show = "["
    for i, p in parts:
      if i > 0:
        show.add(" " & $adjs[i - 1])
      show.add("<" & p & ">")
    show.add("] TJ")
  "BT /" & resName & " " & $size & " Tf " & $x & " " & $y & " Td " &
    show & " ET"

proc utf16Hex(text: string): string =
  ## UTF-8 text to uppercase UTF-16BE hex for ToUnicode destinations.
  for r in text.runes:
    let v = int(r)
    if v <= 0xFFFF:
      result.add(toHex(v, 4).toUpperAscii())
    else:
      let w = v - 0x10000
      result.add(toHex(0xD800 + (w shr 10), 4).toUpperAscii())
      result.add(toHex(0xDC00 + (w and 0x3FF), 4).toUpperAscii())

proc cidUnicodeCMap(texts: Table[int, string]): string =
  ## /ToUnicode CMap over 2-byte CIDs, bfchar blocks chunked at 100
  ## entries per the spec limit.
  var cids: seq[int] = @[]
  for c in texts.keys:
    cids.add(c)
  cids.sort()
  result = "/CIDInit /ProcSet findresource begin\n" &
    "12 dict begin\nbegincmap\n" &
    "/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) " &
    "/Supplement 0 >> def\n" &
    "/CMapName /Adobe-Identity-UCS def\n/CMapType 2 def\n" &
    "1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n"
  var i = 0
  while i < cids.len:
    let n = min(100, cids.len - i)
    result.add($n & " beginbfchar\n")
    for c in cids[i ..< i + n]:
      result.add("<" & toHex(c, 4).toUpperAscii() & "> <" &
        utf16Hex(texts[c]) & ">\n")
    result.add("endbfchar\n")
    i += n
  result.add("endcmap\nCMapName currentdict /CMap " &
    "defineresource pop\nend\nend\n")

proc oldToNewGids(fontBytes: string,
    unicodes: openArray[uint32]): tuple[prog: string,
      mapping: Table[uint32, uint32]] =
  ## Subset by `unicodes` and return the program plus the full-font
  ## GID to subset GID map, via a subset plan (same input executes
  ## the plan, so the mapping describes the bytes we embed).
  if fontBytes.len == 0:
    pdfFail("cannot subset an empty font program")
  var sf = openShapedFont(fontBytes)
  defer: close(sf)
  let input = hb_subset_input_create_or_fail()
  if input == nil:
    pdfFail("HarfBuzz refused the subset input")
  defer: hb_subset_input_destroy(input)
  let uset = hb_subset_input_unicode_set(input)
  for u in unicodes:
    hb_set_add(uset, hb_codepoint_t(u))
  discard hb_subset_input_pin_all_axes_to_default(input, sf.face)
  hb_subset_input_set_flags(input, cuint(HB_SUBSET_FLAGS_DOWNGRADE_CFF2))
  let plan = hb_subset_plan_create_or_fail(sf.face, input)
  if plan == nil:
    pdfFail("HarfBuzz refused the subset plan")
  defer: hb_subset_plan_destroy(plan)
  let sub = hb_subset_plan_execute_or_fail(plan)
  if sub == nil:
    pdfFail("HarfBuzz failed to subset the font program")
  defer: hb_face_destroy(sub)
  let bb = hb_face_reference_blob(sub)
  if bb == nil:
    pdfFail("subset produced no font blob")
  defer: hb_blob_destroy(bb)
  var n: cuint = 0
  let p = hb_blob_get_data(bb, addr n)
  if p == nil or n == 0:
    pdfFail("subset produced no font bytes")
  var prog = newString(int(n))
  copyMem(addr prog[0], p, int(n))
  let m = hb_subset_plan_old_to_new_glyph_mapping(plan)
  if m == nil:
    pdfFail("subset plan has no glyph mapping")
  var mapping = initTable[uint32, uint32]()
  var idx: cint = -1
  var k, v: hb_codepoint_t
  while hb_map_next(m, addr idx, addr k, addr v) != 0:
    mapping[uint32(k)] = uint32(v)
  (prog, mapping)

proc embedCidFont*(b: var PdfBuilder, baseName: string,
    fontBytes: string, cids: Table[uint32, int],
    texts: Table[int, string], subset = true): int =
  ## Embed a program as Identity-H Type0 with /CIDToGIDMap, compact
  ## /W and /ToUnicode, covering TrueType (CIDFontType2/FontFile2)
  ## and CFF (CIDFontType0/FontFile3). Returns the Type0 dict number.
  ## With `subset` (default) only used unicodes ship; the subsetter
  ## renumbers glyphs, hence the map stream. Widths and descriptor
  ## metrics come from the embedded bytes.
  if cids.len == 0:
    pdfFail("embedCidFont needs at least one used glyph")
  var runes: seq[uint32] = @[]
  for t in texts.values:
    for r in t.runes:
      runes.add(uint32(r))
  var prog = fontBytes
  var mapping = initTable[uint32, uint32]()
  if subset:
    let (p, m) = oldToNewGids(fontBytes, runes)
    prog = p
    mapping = m
  else:
    for g in cids.keys:
      mapping[g] = g
  var sf = openShapedFont(prog)
  defer: close(sf)
  let cff = hasTable(sf.face, 'C', 'F', 'F', ' ') or
    hasTable(sf.face, 'C', 'F', 'F', '2')
  var maxCid = 0
  for c in cids.values:
    maxCid = max(maxCid, c)
  var newOfCid = initTable[int, uint32]()
  for g, c in cids.pairs:
    if not mapping.hasKey(g):
      pdfFail("subset dropped drawn glyph " & $g & " from " & baseName)
    newOfCid[c] = mapping[g]
  var gidBytes = newString((maxCid + 1) * 2)
  for c in 0 .. maxCid:
    let g = if newOfCid.hasKey(c): newOfCid[c] else: 0'u32
    gidBytes[c * 2] = char(int(g shr 8) and 0xFF)
    gidBytes[c * 2 + 1] = char(int(g) and 0xFF)
  var ncids: seq[int] = @[]
  for c in cids.values:
    ncids.add(c)
  ncids.sort()
  var witems: seq[CosObj] = @[]
  var i = 0
  while i < ncids.len:
    var j = i
    while j + 1 < ncids.len and ncids[j + 1] == ncids[j] + 1:
      inc j
    witems.add(CosObj(kind: coInt, ival: ncids[i]))
    var ws: seq[CosObj] = @[]
    for c in ncids[i .. j]:
      ws.add(CosObj(kind: coInt,
        ival: int(sf.glyphAdvance1000(newOfCid[c]) + 0.5)))
    witems.add(CosObj(kind: coArray, items: ws))
    i = j + 1
  var bbox = (xMin: 0, yMin: 0, xMax: 0, yMax: 0)
  if hasTable(sf.face, 'h', 'e', 'a', 'd'):
    bbox = sf.headBBox()
  else: ## bare CFF: union the used glyph extents instead
    for c in ncids:
      var e: hb_glyph_extents_t
      if hb_font_get_glyph_extents(sf.font,
          hb_codepoint_t(newOfCid[c]), addr e) != 0:
        bbox.xMin = min(bbox.xMin, int(e.x_bearing))
        bbox.yMin = min(bbox.yMin, int(e.y_bearing + e.height))
        bbox.xMax = max(bbox.xMax, int(e.x_bearing + e.width))
        bbox.yMax = max(bbox.yMax, int(e.y_bearing))
  let ext = sf.hExtents1000()
  var capH = ext.ascender
  let hGlyph = sf.nominalGlyph(0x48)
  if hGlyph != 0:
    var e: hb_glyph_extents_t
    if hb_font_get_glyph_extents(sf.font, hb_codepoint_t(hGlyph),
        addr e) != 0:
      capH = int(e.height)
  var fileDict = CosObj(kind: coDict, keys: @[], vals: @[])
  var fileKey = "FontFile2"
  if cff:
    ## hb-subset always outputs sfnt-wrapped programs, which the PDF
    ## spec (and poppler's sniffer) wants as /OpenType. Bare CFF data
    ## only arrives via subset=false with a hand-supplied .cff, named
    ## /Type1C; CID-keyed bare CFF wants /CIDFontType0C instead, so
    ## subset CID-keyed inputs rather than embedding them raw.
    var sub = "OpenType"
    if not (prog.len >= 4 and prog[0 .. 3] == "OTTO"):
      sub = "Type1C"
    fileDict = CosObj(kind: coDict, keys: @["Subtype"],
      vals: @[CosObj(kind: coName, name: sub)])
    fileKey = "FontFile3"
  else:
    fileDict = CosObj(kind: coDict, keys: @["Length1"],
      vals: @[CosObj(kind: coInt, ival: prog.len)])
  let fileNum = b.addStream(fileDict, prog)
  let descNum = b.addValue(CosObj(kind: coDict,
    keys: @["Type", "FontName", "Flags", "FontBBox", "ItalicAngle",
      "Ascent", "Descent", "CapHeight", "StemV", fileKey],
    vals: @[CosObj(kind: coName, name: "FontDescriptor"),
      CosObj(kind: coName, name: baseName),
      CosObj(kind: coInt, ival: 32),
      CosObj(kind: coArray, items: @[
        CosObj(kind: coInt, ival: bbox.xMin),
        CosObj(kind: coInt, ival: bbox.yMin),
        CosObj(kind: coInt, ival: bbox.xMax),
        CosObj(kind: coInt, ival: bbox.yMax)]),
      CosObj(kind: coInt, ival: 0),
      CosObj(kind: coInt, ival: ext.ascender),
      CosObj(kind: coInt, ival: ext.descender),
      CosObj(kind: coInt, ival: capH),
      CosObj(kind: coInt, ival: 80),
      CosObj(kind: coRef, refNum: fileNum, refGen: 0)]))
  let mapNum = b.addStream(CosObj(kind: coDict, keys: @[], vals: @[]),
    gidBytes)
  let cidNum = b.addValue(CosObj(kind: coDict,
    keys: @["Type", "Subtype", "BaseFont", "CIDSystemInfo", "DW", "W",
      "FontDescriptor", "CIDToGIDMap"],
    vals: @[CosObj(kind: coName, name: "Font"),
      CosObj(kind: coName,
        name: if cff: "CIDFontType0" else: "CIDFontType2"),
      CosObj(kind: coName, name: baseName),
      CosObj(kind: coDict,
        keys: @["Registry", "Ordering", "Supplement"],
        vals: @[CosObj(kind: coStr, sval: "Adobe"),
          CosObj(kind: coStr, sval: "Identity"),
          CosObj(kind: coInt, ival: 0)]),
      CosObj(kind: coInt,
        ival: int(sf.glyphAdvance1000(0) + 0.5)),
      CosObj(kind: coArray, items: witems),
      CosObj(kind: coRef, refNum: descNum, refGen: 0),
      CosObj(kind: coRef, refNum: mapNum, refGen: 0)]))
  let tuNum = b.addStream(CosObj(kind: coDict, keys: @[], vals: @[]),
    cidUnicodeCMap(texts))
  result = b.addValue(CosObj(kind: coDict,
    keys: @["Type", "Subtype", "BaseFont", "Encoding",
      "DescendantFonts", "ToUnicode"],
    vals: @[CosObj(kind: coName, name: "Font"),
      CosObj(kind: coName, name: "Type0"),
      CosObj(kind: coName, name: baseName),
      CosObj(kind: coName, name: "Identity-H"),
      CosObj(kind: coArray, items: @[
        CosObj(kind: coRef, refNum: cidNum, refGen: 0)]),
      CosObj(kind: coRef, refNum: tuNum, refGen: 0)]))

proc finalizeFonts*(b: var PdfBuilder,
    uses: Table[string, CidFontUse],
    subset = true): Table[string, int] =
  ## Embed every collected `CidFontUse` (resource name to use) and
  ## return resource name to Type0-dict object number, for
  ## `fontResources`. Names embed in sorted order like `FontUse`.
  result = initTable[string, int]()
  var names: seq[string] = @[]
  for k in uses.keys:
    names.add(k)
  names.sort()
  for n in names:
    let u = uses[n]
    result[n] = b.embedCidFont(u.baseName, u.fontBytes, u.cids,
      u.texts, subset)
