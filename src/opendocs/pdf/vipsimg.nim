## Image XObjects, back half: libvips decode and color pipeline.
##
## Coded streams (DCTDecode, JPXDecode) decode through vips format
## sniffing, which also resolves Adobe CMYK JPEGs. Raw samples unpack
## in images.nim, enter vips as 8-bit bands, and convert to sRGB:
## DeviceGray stays gray, DeviceCMYK converts, Indexed expands in Nim,
## ICCBased applies the embedded profile, Separation uses /Alternate.
## SMasks become an alpha band; explicit color-key masks flatten over
## white into alpha as well. All vips failures surface as PdfError
## naming the image.

import libvips/api
import libvips/bindings/vips
import ./types
import ./lexer
import ./cos
import ./docmodel
import ./filters
import ./images

export images

type
  ImageEncoding* = enum
    ieRGB, ieGray, ieAlpha

  PdfImage* = object
    name*: string
    width*: int
    height*: int
    encoding*: ImageEncoding
    hasAlpha*: bool
    pixels*: string ## RGB8, Gray8 or Alpha8 (+ alpha band when set)

proc ensureVips*() =
  if vips_init("opengraphics") != 0:
    pdfFail("libvips failed to initialize")

proc toBytes(s: string): seq[uint8] =
  result = newSeq[uint8](s.len)
  if s.len > 0:
    copyMem(addr result[0], unsafeAddr s[0], s.len)

proc toStr(b: seq[uint8]): string =
  result = newString(b.len)
  if b.len > 0:
    copyMem(addr result[0], unsafeAddr b[0], b.len)

proc readback(img: Image): string =
  var n: csize_t = 0
  let p = vips_image_write_to_memory(img.v, addr n)
  if p == nil:
    pdfFail("libvips write_to_memory failed")
  result = newString(n)
  if n > 0:
    copyMem(addr result[0], p, n)
  g_free(p)

proc tagCopy(img: Image, interp: VipsInterpretation): Image =
  ## Copy with an explicit interpretation (new_from_memory defaults
  ## to MULTIBAND, which has no defined conversion).
  var outPtr: ptr VipsImage = nil
  let rc = c_vips_copy(img.v, addr outPtr, "interpretation".cstring,
    cint(ord(interp)), nil)
  if rc != 0 or outPtr == nil:
    pdfFail("libvips failed to tag image interpretation")
  Image(v: outPtr)

proc fromSamples(u8: string, w, h, bands: int,
    interp: VipsInterpretation): Image =
  if u8.len != w * h * bands:
    pdfFail("sample size mismatch entering libvips")
  var data = toBytes(u8)
  tagCopy(fromMemory(data, w, h, bands, VIPS_FORMAT_UCHAR), interp)

proc maskGray(d: var PdfDoc, m: CosObj, w, h: int): string =
  ## SMask or mask stream rendered to Gray8, sized to the base image.
  ## Coded masks (DCT/JPX) decode through vips; raw samples unpack.
  var s = m
  if s.kind == coRef:
    s = d.resolve(s)
  if s.kind != coStream:
    pdfFail("mask is not a stream")
  let mw = s.dictGet("Width").asInt()
  let mh = s.dictGet("Height").asInt()
  var bpc = 8
  if s.dictGet("BitsPerComponent").kind == coInt:
    bpc = s.dictGet("BitsPerComponent").asInt()
  let f = s.dictGet("Filter")
  var coded = false
  if f.kind == coName and (f.name == "DCTDecode" or f.name == "DCT" or
      f.name == "JPXDecode" or f.name == "JPX"):
    coded = true
  elif f.kind == coArray:
    for it in f.items:
      let n = it.asName()
      if n == "DCTDecode" or n == "DCT" or n == "JPXDecode" or
          n == "JPX":
        coded = true
  var gray = ""
  if coded:
    ensureVips()
    var data = toBytes(decodeCosStream(s))
    var img = openBuffer(data)
    if img.bands != 1:
      img = img.toGrayscale()
    gray = readback(img)
  else:
    gray = unpackSamples(decodeCosStream(s), mw, mh, bpc, 1,
      decodeRange(s.dictGet("Decode"), 1))
  if mw != w or mh != h or gray.len != w * h:
    pdfFail("mask size " & $mw & "x" & $mh &
      " does not match image " & $w & "x" & $h)
  gray

proc applyMasks(d: var PdfDoc, raw: PdfRawImage, rgb: var string,
    comps: int) =
  ## SMask becomes an alpha band; explicit color-key masks (valid only
  ## when the samples were not converted: comps == raw.ncomp, checked
  ## by the caller) flatten over white into alpha as well.
  if raw.width <= 0 or raw.height <= 0:
    return
  if raw.smask.kind != coNull:
    let a = maskGray(d, raw.smask, raw.width, raw.height)
    var outp = newString(raw.width * raw.height * (comps + 1))
    for i in 0 ..< raw.width * raw.height:
      for c in 0 ..< comps:
        outp[i * (comps + 1) + c] = rgb[i * comps + c]
      outp[i * (comps + 1) + comps] = a[i]
    rgb = outp
    return
  if raw.mask.kind == coArray:
    let ranges = raw.mask.items
    if ranges.len != 2 * raw.ncomp:
      pdfFail("bad explicit /Mask array on image /" & raw.name)
    var lo = newSeq[int](raw.ncomp)
    var hi = newSeq[int](raw.ncomp)
    for i in 0 ..< raw.ncomp:
      lo[i] = ranges[2 * i].asInt()
      hi[i] = ranges[2 * i + 1].asInt()
    # Samples are 8-bit post-unpack; mask ranges are sample values.
    var outp = newString(raw.width * raw.height * (comps + 1))
    for i in 0 ..< raw.width * raw.height:
      var hidden = true
      for c in 0 ..< comps:
        let v = int(byte(rgb[i * comps + c]))
        if v < lo[c] or v > hi[c]:
          hidden = false
      let a = if hidden: 0 else: 255
      for c in 0 ..< comps:
        let v = int(byte(rgb[i * comps + c]))
        outp[i * (comps + 1) + c] = char(v * a div 255 +
          255 * (255 - a) div 255)
      outp[i * (comps + 1) + comps] = char(a)
    rgb = outp

proc convertCoded(d: var PdfDoc, raw: PdfRawImage): PdfImage =
  ## DCTDecode/JPXDecode through vips sniffing, then the mask stage.
  ## Gray stays gray; anything beyond gray/RGB with an explicit mask
  ## fails rather than masking converted samples.
  ensureVips()
  if raw.width <= 0 or raw.height <= 0:
    pdfFail("image /" & raw.name & " has non-positive size")
  if raw.coding == "other":
    pdfFail("CCITTFaxDecode/JBIG2Decode streams of image /" &
      raw.name & " are not supported (passthrough only)")
  var data = toBytes(raw.samples)
  var img = openBuffer(data)
  let gray = img.bands == 1
  if raw.mask.kind == coArray and not gray and img.bands != 3:
    pdfFail("explicit /Mask on converted coded samples of image /" &
      raw.name & " is not supported")
  if not gray:
    img = img.toSRGB()
  if img.width != raw.width or img.height != raw.height:
    pdfFail("coded image size " & $img.width & "x" & $img.height &
      " disagrees with dict " & $raw.width & "x" & $raw.height)
  var rgb = readback(img)
  var hasAlpha = false
  if raw.smask.kind != coNull or raw.mask.kind == coArray:
    applyMasks(d, raw, rgb, if gray: 1 else: 3)
    hasAlpha = true
  PdfImage(name: raw.name, width: raw.width, height: raw.height,
    encoding: if gray: ieGray else: ieRGB, hasAlpha: hasAlpha,
    pixels: rgb)

proc convertRaw(d: var PdfDoc, raw: PdfRawImage): PdfImage =
  ## Raw samples through unpacking, color, and masks.
  if raw.width <= 0 or raw.height <= 0:
    pdfFail("image /" & raw.name & " has non-positive size")
  if raw.width * raw.height > d.limits.maxImagePixels:
    pdfFail("image /" & raw.name & " exceeds pixel limit " &
      $d.limits.maxImagePixels)
  if raw.isMask:
    let u8 = unpackSamples(raw.samples, raw.width, raw.height,
      raw.bpc, 1, raw.decode)
    return PdfImage(name: raw.name, width: raw.width,
      height: raw.height, encoding: ieAlpha, hasAlpha: true,
      pixels: u8)
  if raw.coded:
    return convertCoded(d, raw)
  if raw.samples.len == 0:
    pdfFail("image /" & raw.name & " has no stream data")
  if raw.cs == nil:
    pdfFail("image /" & raw.name & " missing /ColorSpace")
  var u8 = unpackSamples(raw.samples, raw.width, raw.height, raw.bpc,
    raw.ncomp, raw.decode)
  var cs = raw.cs
  while cs.kind == ckSeparation:
    # Tint functions are PostScript; use /Alternate directly.
    cs = cs.sepAlt
  var gray = false
  var converted = false
  var rgb = ""
  case cs.kind
  of ckDeviceGray:
    gray = true
    rgb = u8
  of ckDeviceRGB:
    rgb = u8
  of ckDeviceCMYK:
    ensureVips()
    converted = true
    var img = fromSamples(u8, raw.width, raw.height, 4,
      VIPS_INTERPRETATION_CMYK)
    rgb = readback(img.toSRGB())
  of ckIndexed:
    let bn = ncompOf(cs.base)
    if raw.mask.kind == coArray:
      pdfFail("explicit /Mask on Indexed image /" & raw.name &
        " is not supported (ranges address palette indices)")
    converted = bn != 1
    var exp = newString(raw.width * raw.height * bn)
    for i in 0 ..< raw.width * raw.height:
      let idx = int(byte(u8[i]))
      if idx > cs.hival:
        pdfFail("indexed sample out of range on image /" & raw.name)
      for c in 0 ..< bn:
        exp[i * bn + c] = cs.lookup[idx * bn + c]
    if bn == 1:
      gray = true
    rgb = exp
  of ckICCBased:
    ensureVips()
    converted = true
    let interp = case cs.n
      of 1: VIPS_INTERPRETATION_B_W
      of 4: VIPS_INTERPRETATION_CMYK
      else: VIPS_INTERPRETATION_sRGB
    var img = fromSamples(u8, raw.width, raw.height, cs.n, interp)
    if cs.profile.len == 0:
      if cs.iccAlt != nil:
        cs = cs.iccAlt
        if cs.kind == ckDeviceGray:
          gray = true
          converted = false
          rgb = u8
        else:
          pdfFail("ICCBased image /" & raw.name &
            " has an empty profile and a non-gray /Alternate")
      else:
        pdfFail("ICCBased image /" & raw.name &
          " has an empty profile and no /Alternate")
    else:
      vips_image_set_blob_copy(img.v, VIPS_META_ICC_NAME,
        unsafeAddr cs.profile[0], cs.profile.len.csize_t)
      rgb = readback(img.iccImport().toSRGB())
  of ckSeparation:
    pdfFail("unreachable separation color space")
  let comps = if gray: 1 else: 3
  if rgb.len != raw.width * raw.height * comps:
    pdfFail("sample size mismatch on image /" & raw.name)
  if raw.mask.kind == coArray and converted:
    pdfFail("explicit /Mask on converted samples of image /" &
      raw.name & " is not supported")
  var hasAlpha = false
  if raw.smask.kind != coNull or raw.mask.kind == coArray:
    applyMasks(d, raw, rgb, comps)
    hasAlpha = true
  PdfImage(name: raw.name, width: raw.width, height: raw.height,
    encoding: if gray: ieGray else: ieRGB, hasAlpha: hasAlpha,
    pixels: rgb)

proc pageImages*(d: var PdfDoc, index: int): seq[PdfImage] =
  ## All top-level images on the page, converted to RGB8/Gray8
  ## (plus alpha when masked). Vips failures name the image.
  result = @[]
  try:
    for item in d.pageRawImages(index):
      result.add(d.convertRaw(item.raw))
  except VipsError as e:
    pdfFail("libvips failed (" & e.msg & ")")
