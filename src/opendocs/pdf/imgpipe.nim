## Image XObjects, back half: pure-Nim decode and color pipeline.
##
## Coded streams (DCTDecode) decode through the pure-Nim `image`
## package, which also resolves Adobe CMYK JPEGs (converted to RGB
## with the naive 255-min(c+k) rule, same as its TIFF decoder).
## JPXDecode has no pure-Nim decoder and fails loudly, like the
## CCITT/JBIG2 passthrough cases. Raw samples unpack in images.nim
## and convert here without a color engine: DeviceGray stays gray,
## DeviceCMYK inverts naively, Indexed expands in Nim, ICCBased
## applies /Alternate when the profile is empty and otherwise treats
## N = 1/3/4 as gray/RGB/CMYK samples, Separation uses /Alternate.
## SMasks become an alpha band; explicit color-key masks flatten over
## white into alpha as well. All decode failures surface as PdfError
## naming the image.

import image/color
import image/buffer
import image/dynamic
import image/error
import image/format
import image/reader
import image/codecs/jpeg
import image/codecs/png
import image/codecs/gif
import image/codecs/bmp
import image/codecs/tiff
import image/codecs/webp
import image/codecs/pnm
import image/codecs/tga
import image/codecs/ico
import image/codecs/qoi
import image/codecs/heif/heif
import image/codecs/farbfeld
import image/codecs/hdr
import image/codecs/openexr
import ./types
import ./lexer
import ./cos
import ./docmodel
import ./filters
import ./images
import ./gstate

export images
export gstate

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
    ctm*: Matrix ## placement at the `Do`; identity when unset
    depth*: int ## resource-frame nesting depth, 0 on the page

  DecodedPixels* = object
    ## Raw 8-bit pixels from a decoded file: `comps` is 1 gray, 2
    ## gray+alpha, 3 rgb or 4 rgb+alpha.
    pixels*: string
    width*: int
    height*: int
    comps*: int

proc toBytes(s: string): seq[uint8] =
  result = newSeq[uint8](s.len)
  if s.len > 0:
    copyMem(addr result[0], unsafeAddr s[0], s.len)

proc failImg(what, msg: string) {.noreturn.} =
  pdfFail("cannot " & what & " (" & msg & ")")

proc seqToStr[T](s: seq[T]): string =
  ## Packed pixel buffer to bytes (Luma/Rgb/Rgba u8 have no padding).
  result = newString(s.len * sizeof(T))
  if s.len > 0:
    copyMem(addr result[0], unsafeAddr s[0], result.len)

proc dynToPixels*(img: DynamicImage): DecodedPixels =
  ## Every decoder output to interleaved 8-bit bytes, keeping alpha
  ## when present. 16-bit takes the rounded high byte, float clamps
  ## to 0..1 (same rounding as the `image` component conversions).
  let (w, h) = img.dimensions()
  let W = int(w)
  let H = int(h)
  case img.kind
  of dkLuma8:
    DecodedPixels(pixels: seqToStr(img.luma8.pixels), width: W,
      height: H, comps: 1)
  of dkLumaA8:
    DecodedPixels(pixels: seqToStr(img.lumaA8.pixels), width: W,
      height: H, comps: 2)
  of dkRgb8:
    DecodedPixels(pixels: seqToStr(img.rgb8.pixels), width: W,
      height: H, comps: 3)
  of dkRgba8:
    DecodedPixels(pixels: seqToStr(img.rgba8.pixels), width: W,
      height: H, comps: 4)
  of dkLuma16:
    var px = newString(W * H)
    for i, p in img.luma16.pixels:
      px[i] = char(convU16toU8(p.data[0]))
    DecodedPixels(pixels: px, width: W, height: H, comps: 1)
  of dkLumaA16:
    var px = newString(W * H * 2)
    for i, p in img.lumaA16.pixels:
      px[2 * i] = char(convU16toU8(p.data[0]))
      px[2 * i + 1] = char(convU16toU8(p.data[1]))
    DecodedPixels(pixels: px, width: W, height: H, comps: 2)
  of dkRgb16:
    var px = newString(W * H * 3)
    for i, p in img.rgb16.pixels:
      px[3 * i] = char(convU16toU8(p.data[0]))
      px[3 * i + 1] = char(convU16toU8(p.data[1]))
      px[3 * i + 2] = char(convU16toU8(p.data[2]))
    DecodedPixels(pixels: px, width: W, height: H, comps: 3)
  of dkRgba16:
    var px = newString(W * H * 4)
    for i, p in img.rgba16.pixels:
      px[4 * i] = char(convU16toU8(p.data[0]))
      px[4 * i + 1] = char(convU16toU8(p.data[1]))
      px[4 * i + 2] = char(convU16toU8(p.data[2]))
      px[4 * i + 3] = char(convU16toU8(p.data[3]))
    DecodedPixels(pixels: px, width: W, height: H, comps: 4)
  of dkLuma32F, dkLumaA32F, dkRgb32F, dkRgba32F:
    let n = case img.kind
      of dkLuma32F: 1
      of dkLumaA32F: 2
      of dkRgb32F: 3
      else: 4
    proc f2b(v: float32): char =
      let c = if v < 0.0f32: 0.0f32 elif v > 1.0f32: 1.0f32 else: v
      char(int(c * 255.0f32 + 0.5f32))
    var px = newString(W * H * n)
    case img.kind
    of dkLuma32F:
      for i, p in img.luma32f.pixels: px[i] = f2b(p.data[0])
    of dkLumaA32F:
      for i, p in img.lumaA32f.pixels:
        px[2 * i] = f2b(p.data[0])
        px[2 * i + 1] = f2b(p.data[1])
    of dkRgb32F:
      for i, p in img.rgb32f.pixels:
        px[3 * i] = f2b(p.data[0])
        px[3 * i + 1] = f2b(p.data[1])
        px[3 * i + 2] = f2b(p.data[2])
    else:
      for i, p in img.rgba32f.pixels:
        px[4 * i] = f2b(p.data[0])
        px[4 * i + 1] = f2b(p.data[1])
        px[4 * i + 2] = f2b(p.data[2])
        px[4 * i + 3] = f2b(p.data[3])
    DecodedPixels(pixels: px, width: W, height: H, comps: n)

proc grayStr*(px: string, w, h, comps: int): string =
  ## RGB8 to Gray8 with sRGB luma weights; gray passes through.
  if comps == 1:
    if px.len != w * h:
      pdfFail("sample size mismatch converting to gray")
    return px
  if comps != 3:
    pdfFail("cannot convert " & $comps & "-component pixels to gray")
  if px.len != w * h * 3:
    pdfFail("sample size mismatch converting to gray")
  result = newString(w * h)
  for i in 0 ..< w * h:
    result[i] = char(rgbToLumaU8(byte(px[3 * i]), byte(px[3 * i + 1]),
      byte(px[3 * i + 2])))

proc cmykNaive*(u8: string): string =
  ## DeviceCMYK bytes to RGB8: 255-min(255, c+k) per channel, the
  ## same naive rule the `image` JPEG/TIFF decoders apply.
  if u8.len mod 4 != 0:
    pdfFail("CMYK sample size is not a multiple of 4")
  result = newString(u8.len div 4 * 3)
  for i in 0 ..< u8.len div 4:
    let c = int(byte(u8[4 * i]))
    let m = int(byte(u8[4 * i + 1]))
    let y = int(byte(u8[4 * i + 2]))
    let k = int(byte(u8[4 * i + 3]))
    result[3 * i] = char(255 - min(255, c + k))
    result[3 * i + 1] = char(255 - min(255, m + k))
    result[3 * i + 2] = char(255 - min(255, y + k))

proc flattenWhiteStr*(px: string, w, h, comps: int): string =
  ## Drop alpha over a white background (for JPEG output and the
  ## Flate writer path, which carry no alpha).
  if comps != 2 and comps != 4:
    if px.len != w * h * comps:
      pdfFail("sample size mismatch flattening alpha")
    return px
  let cc = comps - 1
  if px.len != w * h * comps:
    pdfFail("sample size mismatch flattening alpha")
  result = newString(w * h * cc)
  for i in 0 ..< w * h:
    let a = int(byte(px[i * comps + cc]))
    for c in 0 ..< cc:
      let v = int(byte(px[i * comps + c]))
      result[i * cc + c] = char(v * a div 255 +
        255 * (255 - a) div 255)

proc downscaleToWidth*(px: string, w, h, comps,
    maxW: int): tuple[px: string, w, h: int] =
  ## Bilinear downscale to `maxW` pixels wide (aspect preserved).
  ## Returns the input untouched when already narrow enough.
  if maxW <= 0 or w <= maxW:
    return (px, w, h)
  if px.len != w * h * comps:
    pdfFail("sample size mismatch resizing image")
  let nw = maxW
  let nh = max(1, h * nw div w)
  var outp = newString(nw * nh * comps)
  for y in 0 ..< nh:
    let sy = float64(y) * float64(h) / float64(nh)
    let y0 = min(int(sy), h - 1)
    let y1 = min(y0 + 1, h - 1)
    let fy = sy - float64(y0)
    for x in 0 ..< nw:
      let sx = float64(x) * float64(w) / float64(nw)
      let x0 = min(int(sx), w - 1)
      let x1 = min(x0 + 1, w - 1)
      let fx = sx - float64(x0)
      for c in 0 ..< comps:
        let a = float64(byte(px[(y0 * w + x0) * comps + c]))
        let b = float64(byte(px[(y0 * w + x1) * comps + c]))
        let cc = float64(byte(px[(y1 * w + x0) * comps + c]))
        let dd = float64(byte(px[(y1 * w + x1) * comps + c]))
        let v = a * (1.0 - fx) * (1.0 - fy) + b * fx * (1.0 - fy) +
          cc * (1.0 - fx) * fy + dd * fx * fy
        outp[(y * nw + x) * comps + c] = char(int(v + 0.5))
  (outp, nw, nh)

proc jpegSofComps*(data: string): int =
  ## Component count from the first JPEG SOF marker, or -1 when the
  ## header cannot be parsed. 4 means CMYK/YCCK (Adobe).
  if data.len < 4 or byte(data[0]) != 0xFF or byte(data[1]) != 0xD8:
    return -1
  var i = 2
  while i + 1 < data.len:
    if byte(data[i]) != 0xFF:
      return -1
    var m = byte(data[i + 1])
    var j = i + 1
    while m == 0xFF and j + 1 < data.len:
      inc j
      m = byte(data[j])
    i = j + 1
    if m == 0xD8 or m == 0xD9 or m == 0x01 or (m >= 0xD0 and m <= 0xD7):
      continue # standalone markers carry no length
    if m == 0xDA:
      return -1 # SOS: headers are over, no SOF found
    if i + 1 >= data.len:
      return -1
    let segLen = int(byte(data[i])) * 256 + int(byte(data[i + 1]))
    if segLen < 2 or i + segLen > data.len:
      return -1
    if (m >= 0xC0 and m <= 0xCF) and m != 0xC4 and m != 0xC8 and
        m != 0xCC:
      # SOF (excluding DHT, JPG, DAC): precision(1) + dims(4) + Nf(1).
      if segLen < 8 or i + 7 >= data.len:
        return -1
      return int(byte(data[i + 7]))
    i += segLen
  -1

proc decodeImageBytes*(data: string, path: string): DynamicImage =
  ## Sniff the file magic and decode with the matching pure-Nim
  ## codec. AVIF has color math only (no AV1 bitstream decoder).
  let buf = toBytes(data)
  let (found, fmt) = guessFormat(buf)
  if not found:
    failImg("decode image '" & path & "'", "unknown image format")
  case fmt
  of fmtJpeg:
    let r = decodeJpeg(buf)
    if not r.ok: failImg("decode image '" & path & "'", r.err.msg)
    r.value
  of fmtPng:
    let r = decodePng(buf)
    if not r.ok: failImg("decode image '" & path & "'", r.err.msg)
    r.value
  of fmtGif:
    let g = decodeGif(buf)
    if not g.ok: failImg("decode image '" & path & "'", g.err.msg)
    let r = gifFrameToRgba(g.value, 0)
    if not r.ok: failImg("decode image '" & path & "'", r.err.msg)
    DynamicImage(kind: dkRgba8, rgba8: r.value)
  of fmtBmp:
    let r = decodeBmp(buf)
    if not r.ok: failImg("decode image '" & path & "'", r.err.msg)
    r.value
  of fmtTiff:
    let r = decodeTiff(buf)
    if not r.ok: failImg("decode image '" & path & "'", r.err.msg)
    r.value
  of fmtWebP:
    let r = decodeWebp(buf)
    if not r.ok: failImg("decode image '" & path & "'", r.err.msg)
    r.value
  of fmtPnm:
    let r = decodePnm(buf)
    if not r.ok: failImg("decode image '" & path & "'", r.err.msg)
    r.value
  of fmtTga:
    let r = decodeTga(buf)
    if not r.ok: failImg("decode image '" & path & "'", r.err.msg)
    r.value
  of fmtIco:
    let r = decodeIco(buf)
    if not r.ok: failImg("decode image '" & path & "'", r.err.msg)
    r.value
  of fmtQoi:
    let r = decodeQoi(buf)
    if not r.ok: failImg("decode image '" & path & "'", r.err.msg)
    DynamicImage(kind: dkRgba8, rgba8: r.value)
  of fmtHeif:
    let r = decodeHeif(buf)
    if not r.ok: failImg("decode image '" & path & "'", r.err.msg)
    r.value
  of fmtFarbfeld:
    let r = decodeFarbfeld(buf)
    if not r.ok: failImg("decode image '" & path & "'", r.err.msg)
    DynamicImage(kind: dkRgba16, rgba16: r.value)
  of fmtHdr:
    let r = decodeHdr(buf)
    if not r.ok: failImg("decode image '" & path & "'", r.err.msg)
    DynamicImage(kind: dkRgb32F, rgb32f: r.value)
  of fmtOpenExr:
    let r = decodeExr(buf)
    if not r.ok: failImg("decode image '" & path & "'", r.err.msg)
    r.value
  of fmtAvif:
    failImg("decode image '" & path & "'",
      "AVIF bitstream is not supported (no pure-Nim AV1 decoder)")

proc encodeJpegStr*(px: string, w, h, comps, quality: int,
    path: string): string =
  ## RGB8/Gray8 pixels to JPEG bytes for the writer compress pass.
  if px.len != w * h * comps:
    pdfFail("sample size mismatch encoding image '" & path & "'")
  let q = max(1, min(quality, 100))
  let img =
    if comps == 1:
      var gray = GrayImage(width: uint32(w), height: uint32(h),
        pixels: newSeq[Luma[uint8]](w * h))
      for i in 0 ..< w * h:
        gray.pixels[i] = Luma[uint8](data: [byte(px[i])])
      DynamicImage(kind: dkLuma8, luma8: gray)
    elif comps == 3:
      var rgb = RgbImage(width: uint32(w), height: uint32(h),
        pixels: newSeq[Rgb[uint8]](w * h))
      for i in 0 ..< w * h:
        rgb.pixels[i] = Rgb[uint8](data: [byte(px[3 * i]),
          byte(px[3 * i + 1]), byte(px[3 * i + 2])])
      DynamicImage(kind: dkRgb8, rgb8: rgb)
    else:
      pdfFail("cannot JPEG-encode " & $comps &
        "-component image '" & path & "'")
  let r = encodeJpeg(img, q)
  if not r.ok:
    pdfFail("cannot encode image '" & path & "' (" & r.err.msg & ")")
  var js = newString(r.value.len)
  if js.len > 0:
    copyMem(addr js[0], unsafeAddr r.value[0], js.len)
  js

proc maskGray(d: var PdfDoc, m: CosObj, w, h: int): string =
  ## SMask or mask stream rendered to Gray8, sized to the base image.
  ## Coded masks (DCT) decode through the JPEG codec; raw samples unpack.
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
  if f.kind == coName and (f.name == "DCTDecode" or f.name == "DCT"):
    coded = true
  elif f.kind == coArray:
    for it in f.items:
      let n = it.asName()
      if n == "DCTDecode" or n == "DCT":
        coded = true
  var gray = ""
  if coded:
    let r = decodeJpeg(toBytes(decodeCosStream(s)))
    if not r.ok:
      pdfFail("cannot decode mask of image (" & r.err.msg & ")")
    let dp = dynToPixels(r.value)
    gray = grayStr(dp.pixels, dp.width, dp.height, dp.comps)
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
  ## DCTDecode through the pure-Nim JPEG decoder (Adobe CMYK/YCCK
  ## resolves to RGB inside the codec), then the mask stage.
  ## Gray stays gray; anything beyond gray/RGB with an explicit mask
  ## fails rather than masking converted samples.
  if raw.width <= 0 or raw.height <= 0:
    pdfFail("image /" & raw.name & " has non-positive size")
  if raw.coding == "jpx":
    pdfFail("JPXDecode streams of image /" & raw.name &
      " are not supported (no pure-Nim JPEG 2000 decoder)")
  if raw.coding == "other":
    pdfFail("CCITTFaxDecode/JBIG2Decode streams of image /" &
      raw.name & " are not supported (passthrough only)")
  let r = decodeJpeg(toBytes(raw.samples))
  if not r.ok:
    pdfFail("cannot decode image /" & raw.name & " (" & r.err.msg & ")")
  let dp = dynToPixels(r.value)
  let gray = dp.comps == 1
  if raw.mask.kind == coArray and not gray and dp.comps != 3:
    pdfFail("explicit /Mask on converted coded samples of image /" &
      raw.name & " is not supported")
  if dp.width != raw.width or dp.height != raw.height:
    pdfFail("coded image size " & $dp.width & "x" & $dp.height &
      " disagrees with dict " & $raw.width & "x" & $raw.height)
  var rgb = dp.pixels
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
    converted = true
    rgb = cmykNaive(u8)
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
    # No ICC engine in the pure-Nim backend: an empty profile falls
    # back to /Alternate as before, otherwise N selects the device
    # interpretation (1 gray, 3 RGB, 4 CMYK-naive).
    if cs.profile.len == 0:
      if cs.iccAlt != nil:
        cs = cs.iccAlt
        if cs.kind == ckDeviceGray:
          gray = true
          rgb = u8
        else:
          pdfFail("ICCBased image /" & raw.name &
            " has an empty profile and a non-gray /Alternate")
      else:
        pdfFail("ICCBased image /" & raw.name &
          " has an empty profile and no /Alternate")
    else:
      converted = true
      case cs.n
      of 1:
        gray = true
        rgb = u8
      of 3:
        rgb = u8
      of 4:
        rgb = cmykNaive(u8)
      else:
        pdfFail("ICCBased image /" & raw.name & " has bad /N " & $cs.n)
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
  ## All images the page draws, including those inside Form XObjects and
  ## inline images, converted to RGB8/Gray8 (plus alpha when masked).
  ## Placement (`ctm`, `depth`) from the raw image is carried through.
  result = @[]
  for item in d.pageRawImages(index):
    var img = d.convertRaw(item.raw)
    img.ctm = item.raw.ctm
    img.depth = item.raw.depth
    result.add(img)
