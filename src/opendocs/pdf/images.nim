## Image XObjects, front half (ISO 32000 §8.9): parsing and samples.
##
## Parses image dictionaries, decodes the filter chain with the M2
## filters, and unpacks samples to 8-bit components with /Decode
## applied. Color spaces resolve here (names, Indexed, ICCBased with
## the embedded profile bytes, Separation via /Alternate, CalGray and
## CalRGB approximated as device spaces). Masks stay unresolved
## CosObj values for the vips back half. Coded streams (DCT, JPX,
## CCITT, JBIG2) pass through with their bytes intact; Lab images and
## Pattern color spaces raise clear errors.

import std/tables
import ./types
import ./lexer
import ./cos
import ./docmodel
import ./filters
import ./gstate

type
  ColorKind* = enum
    ckDeviceGray, ckDeviceRGB, ckDeviceCMYK, ckIndexed, ckICCBased,
    ckSeparation

  PdfColorSpace* = ref object
    case kind*: ColorKind
    of ckIndexed:
      base*: PdfColorSpace
      hival*: int
      lookup*: string ## (hival+1) * base-component bytes
    of ckICCBased:
      n*: int ## ICC component count
      profile*: string ## embedded profile bytes
      iccAlt*: PdfColorSpace ## /Alternate, nil when absent
    of ckSeparation:
      sepAlt*: PdfColorSpace ## /Alternate
    else:
      discard

  PdfRawImage* = object
    name*: string
    width*: int
    height*: int
    bpc*: int
    ncomp*: int ## samples per pixel (1 gray/mask, 3 rgb, 4 cmyk)
    cs*: PdfColorSpace ## nil for stencil masks
    samples*: string ## filter-decoded raw bytes
    decode*: seq[tuple[lo, hi: float64]] ## /Decode per component
    coded*: bool ## DCT/JPX/CCITT/JBIG2: samples are coded bytes
    coding*: string ## "dct", "jpx" or "other" when coded
    isMask*: bool ## /ImageMask stencil
    mask*: CosObj ## explicit /Mask (array color-key or stream ref)
    smask*: CosObj ## /SMask stream ref (coNull when absent)

proc ncompOf*(cs: PdfColorSpace): int =
  case cs.kind
  of ckDeviceGray: 1
  of ckDeviceRGB: 3
  of ckDeviceCMYK: 4
  of ckIndexed: ncompOf(cs.base)
  of ckICCBased: cs.n
  of ckSeparation: ncompOf(cs.sepAlt)

proc parseColorSpace*(d: var PdfDoc, cs: CosObj): PdfColorSpace =
  ## Resolve a color space value (name, array or reference).
  var v = cs
  if v.kind == coRef:
    v = d.resolve(v)
  if v.kind == coName:
    case v.name
    of "DeviceGray", "G": return PdfColorSpace(kind: ckDeviceGray)
    of "DeviceRGB", "RGB": return PdfColorSpace(kind: ckDeviceRGB)
    of "DeviceCMYK", "CMYK": return PdfColorSpace(kind: ckDeviceCMYK)
    of "Pattern": pdfFail("Pattern is not an image color space")
    else: pdfFail("unknown image color space /" & v.name)
  if v.kind != coArray or v.items.len == 0:
    pdfFail("bad image /ColorSpace value")
  let head = v.items[0]
  if head.kind != coName:
    pdfFail("bad image /ColorSpace family")
  case head.name
  of "Indexed", "I":
    if v.items.len < 4:
      pdfFail("bad /Indexed color space (want [base hival lookup])")
    var base = v.items[1]
    if base.kind == coRef:
      base = d.resolve(base)
    let cs = parseColorSpace(d, base)
    let hival = v.items[2].asInt()
    if hival < 0 or hival > 255:
      pdfFail("bad /Indexed /Hival " & $hival)
    var lookup = v.items[3]
    if lookup.kind == coRef:
      lookup = d.resolve(lookup)
    if lookup.kind == coStr:
      discard
    elif lookup.kind == coStream:
      lookup = CosObj(kind: coStr, sval: decodeCosStream(lookup))
    else:
      pdfFail("bad /Indexed lookup table")
    let want = (hival + 1) * ncompOf(cs)
    if lookup.sval.len < want:
      pdfFail("short /Indexed lookup table")
    PdfColorSpace(kind: ckIndexed, base: cs, hival: hival,
      lookup: lookup.sval[0 ..< want])
  of "ICCBased":
    if v.items.len < 2:
      pdfFail("bad /ICCBased color space")
    var s = v.items[1]
    if s.kind == coRef:
      s = d.resolve(s)
    if s.kind != coStream:
      pdfFail("/ICCBased profile is not a stream")
    let n = s.dictGet("N").asInt()
    if n != 1 and n != 3 and n != 4:
      pdfFail("bad /ICCBased /N " & $n & " (want 1, 3 or 4)")
    var alt: PdfColorSpace = nil
    let a = s.dictGet("Alternate")
    if a.kind != coNull:
      alt = parseColorSpace(d, a)
    PdfColorSpace(kind: ckICCBased, n: n,
      profile: decodeCosStream(s), iccAlt: alt)
  of "Separation":
    if v.items.len < 4:
      pdfFail("bad /Separation color space")
    PdfColorSpace(kind: ckSeparation,
      sepAlt: parseColorSpace(d, v.items[2]))
  of "CalGray":
    PdfColorSpace(kind: ckDeviceGray)
  of "CalRGB":
    PdfColorSpace(kind: ckDeviceRGB)
  of "Lab":
    pdfFail("Lab image color spaces are not supported (needs M5+)")
  of "Pattern":
    pdfFail("Pattern is not an image color space")
  else:
    pdfFail("unknown image color space /" & head.name)

proc decodeRange*(d: CosObj, ncomp: int): seq[tuple[lo, hi: float64]] =
  ## /Decode array (2 values per component), defaulting to [0 1].
  result = newSeq[tuple[lo, hi: float64]](ncomp)
  for i in 0 ..< ncomp:
    result[i] = (0.0, 1.0)
  if d.kind == coNull:
    return
  if d.kind != coArray or d.items.len != 2 * ncomp:
    pdfFail("bad image /Decode array")
  for i in 0 ..< ncomp:
    result[i] = (d.items[2 * i].asFloat(), d.items[2 * i + 1].asFloat())

proc unpackSamples*(raw: string, width, height, bpc, ncomp: int,
    decode: seq[tuple[lo, hi: float64]]): string =
  ## Unpack rows (byte-padded) to 8-bit components with /Decode
  ## applied. Rows that fall short raise; trailing bytes are ignored.
  if width <= 0 or height <= 0:
    pdfFail("image has non-positive size")
  if bpc notin [1, 2, 4, 8, 16]:
    pdfFail("bad image /BitsPerComponent " & $bpc)
  let rowBits = width * bpc * ncomp
  let stride = (rowBits + 7) div 8
  if raw.len < stride * height:
    pdfFail("short image sample data")
  let scale = float64((1 shl min(bpc, 16)) - 1)
  result = newString(width * height * ncomp)
  var o = 0
  for y in 0 ..< height:
    let row = y * stride
    var bit = 0
    for x in 0 ..< width * ncomp:
      var v: int
      if bpc == 8:
        v = int(byte(raw[row + x]))
      elif bpc == 16:
        v = int(byte(raw[row + 2 * x])) * 256 +
          int(byte(raw[row + 2 * x + 1]))
      else:
        v = 0
        for k in 0 ..< bpc:
          let p = bit + k
          if (int(byte(raw[row + p div 8])) and
              (0x80 shr (p mod 8))) != 0:
            v = v or (1 shl (bpc - 1 - k))
        bit += bpc
      let dr = decode[x mod ncomp]
      let f = dr.lo + (float64(v) / scale) * (dr.hi - dr.lo)
      let clamped = if f < 0.0: 0.0 elif f > 1.0: 1.0 else: f
      result[o] = char(int(clamped * 255.0 + 0.5))
      inc o

proc parseRawImage*(d: var PdfDoc, name: string,
    obj: CosObj): PdfRawImage =
  ## Build the raw image from a resolved XObject dict (streams carry
  ## filter-decoded bytes afterwards in the back half via decodeCosStream).
  if obj.kind != coDict and obj.kind != coStream:
    pdfFail("image XObject /" & name & " is not a dictionary")
  let st = obj.dictGet("Subtype")
  if st.kind != coName or st.name != "Image":
    pdfFail("XObject /" & name & " is not an /Image")
  let w = obj.dictGet("Width").asInt()
  let h = obj.dictGet("Height").asInt()
  var isMask = false
  let im = obj.dictGet("ImageMask")
  if im.kind == coBool and im.bval:
    isMask = true
  var bpc = 1
  let b = obj.dictGet("BitsPerComponent")
  if b.kind == coInt:
    bpc = b.ival
  elif not isMask:
    pdfFail("image /" & name & " missing /BitsPerComponent")
  var cs: PdfColorSpace = nil
  var ncomp = 1
  if not isMask:
    cs = parseColorSpace(d, obj.dictGet("ColorSpace"))
    # Indexed samples are one palette index per pixel; expansion to
    # base components happens after unpacking.
    ncomp = if cs.kind == ckIndexed: 1 else: ncompOf(cs)
  var samples = ""
  var coded = false
  var names: seq[string] = @[]
  if obj.kind == coStream:
    # Filter chain decoded here (DCT/JPX/CCITT/JBIG2 pass through
    # for the vips back half); Flate/LZW/ASCII arrive as samples.
    samples = decodeCosStream(obj)
    let f = obj.dictGet("Filter")
    if f.kind == coName:
      names.add(f.name)
    elif f.kind == coArray:
      for it in f.items:
        names.add(it.asName())
  for n in names:
    if n in ["DCTDecode", "DCT", "JPXDecode", "JPX",
        "CCITTFaxDecode", "CCF", "JBIG2Decode"]:
      coded = true
  var coding = ""
  if coded:
    coding = "other"
    for n in names:
      if n in ["DCTDecode", "DCT"]:
        coding = "dct"
      elif n in ["JPXDecode", "JPX"]:
        coding = "jpx"
  PdfRawImage(name: name, width: w, height: h, bpc: bpc, ncomp: ncomp,
    cs: cs, samples: samples, decode: decodeRange(obj.dictGet("Decode"),
      ncomp), coded: coded, coding: coding, isMask: isMask,
    mask: obj.dictGet("Mask"), smask: obj.dictGet("SMask"))

proc pageRawImages*(d: var PdfDoc, index: int):
    seq[tuple[name: string, raw: PdfRawImage]] =
  ## Top-level /Resources /XObject images referenced by Do on the page.
  ## Form XObjects are skipped (nested content is an M7 concern).
  let ops = d.walkPageOps(index)
  var xobjs = d.pageResources(index).dictGet("XObject")
  if xobjs.kind == coRef:
    xobjs = d.resolve(xobjs)
  if xobjs.kind != coDict:
    return @[]
  result = @[]
  var seen = initTable[string, bool]()
  for op in ops:
    if op.name != "Do" or op.operands.len != 1 or
        op.operands[0].kind != coName:
      continue
    let name = op.operands[0].name
    if seen.hasKey(name):
      continue
    seen[name] = true
    var o = xobjs.dictGet(name)
    if o.kind == coNull:
      pdfFail("XObject /" & name & " missing from /Resources")
    if o.kind == coRef:
      o = d.resolve(o)
    if o.kind != coDict and o.kind != coStream:
      pdfFail("XObject /" & name & " is not a dictionary")
    let st = o.dictGet("Subtype")
    if st.kind == coName and st.name == "Image":
      result.add((name, d.parseRawImage(name, o)))
