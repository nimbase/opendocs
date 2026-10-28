## Shared image export through the pure-Nim `image` package.
##
## One format enum plus options shared by every module: PDF images
## (`PdfImage`), and later DOCX extracted images and other doc formats,
## convert to ExportPixels and encode or save. JPEG, PNG, WebP and TIFF
## encode to memory; BMP saves through its encoder; the rest dispatch
## by file extension. Alpha flattens over white for JPEG (the only
## listed format without alpha).

import std/strutils
import image/buffer
import image/color
import image/dynamic
import image/codecs/jpeg
import image/codecs/png
import image/codecs/webp
import image/codecs/tiff
import image/codecs/bmp
import ./pdf/imgpipe

type
  ExportError* = object of CatchableError

  ImageFormat* = enum
    fmtJpeg, fmtPng, fmtWebP, fmtTiff, fmtGif, fmtHeif, fmtAvif, fmtJxl,
    fmtBmp

  ExportOptions* = object
    jpegQuality*: range[0..100] = 90
    pngCompression*: range[0..9] = 6
    webpQuality*: range[0..100] = 90

  ExportPixels* = object
    width*: int
    height*: int
    bands*: int ## 1 gray, 2 gray+alpha, 3 rgb, 4 rgb+alpha (8-bit)
    data*: string

proc exportFail(msg: string) {.noreturn.} =
  raise newException(ExportError, msg)

proc formatForExt*(ext: string): ImageFormat =
  ## Map a file extension (with or without dot, any case) to a format.
  case ext.toLowerAscii().strip(chars = {'.'})
  of "jpg", "jpeg": fmtJpeg
  of "png": fmtPng
  of "webp": fmtWebP
  of "tif", "tiff": fmtTiff
  of "gif": fmtGif
  of "heif", "heic": fmtHeif
  of "avif": fmtAvif
  of "jxl": fmtJxl
  of "bmp": fmtBmp
  else: exportFail("unsupported image extension '." & ext &
      "' (want jpg, png, webp, tif, gif, heif, avif, jxl or bmp)")

proc formatForPath*(path: string): ImageFormat =
  let dot = path.rfind('.')
  if dot < 0:
    exportFail("cannot infer image format from '" & path &
        "' (no extension)")
  formatForExt(path[dot + 1 .. ^1])

proc toExportPixels*(img: PdfImage): ExportPixels =
  if img.width <= 0 or img.height <= 0 or img.pixels.len == 0:
    exportFail("cannot export an empty image")
  let bands = case img.encoding
    of ieRGB: 3
    of ieGray, ieAlpha: 1
  ExportPixels(width: img.width, height: img.height,
    bands: bands + (if img.hasAlpha: 1 else: 0), data: img.pixels)

proc flattenWhite(px: ExportPixels): ExportPixels =
  ## Drop alpha over a white background (for JPEG output).
  if px.bands != 2 and px.bands != 4:
    return px
  ExportPixels(width: px.width, height: px.height,
    bands: px.bands - 1,
    data: flattenWhiteStr(px.data, px.width, px.height, px.bands))

proc toDynamic(px: ExportPixels): DynamicImage =
  if px.width <= 0 or px.height <= 0 or
      px.data.len != px.width * px.height * px.bands:
    exportFail("export pixel size mismatch")
  let W = uint32(px.width)
  let H = uint32(px.height)
  case px.bands
  of 1:
    var g = GrayImage(width: W, height: H,
      pixels: newSeq[Luma[uint8]](px.width * px.height))
    for i in 0 ..< px.width * px.height:
      g.pixels[i] = Luma[uint8](data: [byte(px.data[i])])
    DynamicImage(kind: dkLuma8, luma8: g)
  of 2:
    var g = GrayAlphaImage(width: W, height: H,
      pixels: newSeq[LumaA[uint8]](px.width * px.height))
    for i in 0 ..< px.width * px.height:
      g.pixels[i] = LumaA[uint8](data: [byte(px.data[2 * i]),
        byte(px.data[2 * i + 1])])
    DynamicImage(kind: dkLumaA8, lumaA8: g)
  of 3:
    var rgb = RgbImage(width: W, height: H,
      pixels: newSeq[Rgb[uint8]](px.width * px.height))
    for i in 0 ..< px.width * px.height:
      rgb.pixels[i] = Rgb[uint8](data: [byte(px.data[3 * i]),
        byte(px.data[3 * i + 1]), byte(px.data[3 * i + 2])])
    DynamicImage(kind: dkRgb8, rgb8: rgb)
  of 4:
    var rgba = RgbaImage(width: W, height: H,
      pixels: newSeq[Rgba[uint8]](px.width * px.height))
    for i in 0 ..< px.width * px.height:
      rgba.pixels[i] = Rgba[uint8](data: [byte(px.data[4 * i]),
        byte(px.data[4 * i + 1]), byte(px.data[4 * i + 2]),
        byte(px.data[4 * i + 3])])
    DynamicImage(kind: dkRgba8, rgba8: rgba)
  else:
    exportFail("export needs 1-4 bands, got " & $px.bands)

proc toBytes(b: seq[uint8]): string =
  result = newString(b.len)
  if b.len > 0:
    copyMem(addr result[0], unsafeAddr b[0], b.len)

proc encodeImage*(px: ExportPixels, format: ImageFormat,
    opts = ExportOptions()): string =
  ## Encode to JPEG, PNG, WebP or TIFF bytes. Other formats need a
  ## path (use saveImage); conversions without a memory encoder fail
  ## loudly. `pngCompression`/`webpQuality` are kept for API
  ## compatibility: the pure-Nim encoders are fixed-strategy.
  let q = max(1, opts.jpegQuality)
  let bytes =
    case format
    of fmtJpeg:
      let r = encodeJpeg(px.flattenWhite().toDynamic(), q)
      if not r.ok: exportFail("JPEG encode failed (" & r.err.msg & ")")
      r.value
    of fmtPng:
      let r = encodePng(px.toDynamic())
      if not r.ok: exportFail("PNG encode failed (" & r.err.msg & ")")
      r.value
    of fmtWebP:
      let r = encodeWebp(px.toDynamic())
      if not r.ok: exportFail("WebP encode failed (" & r.err.msg & ")")
      r.value
    of fmtTiff:
      let r = encodeTiff(px.toDynamic())
      if not r.ok: exportFail("TIFF encode failed (" & r.err.msg & ")")
      r.value
    else: exportFail("format " & $format &
        " has no memory encoder (use saveImage with a path)")
  toBytes(bytes)

proc encodeImage*(img: PdfImage, format: ImageFormat,
    opts = ExportOptions()): string =
  encodeImage(img.toExportPixels(), format, opts)

proc saveImage*(px: ExportPixels, path: string,
    opts = ExportOptions()) =
  ## Save to path, dispatching on the file extension. JPEG honors
  ## jpegQuality; the other pure-Nim encoders are fixed-strategy.
  ## GIF, HEIF, AVIF and JXL have no pure-Nim file writer.
  let data =
    case formatForPath(path)
    of fmtJpeg, fmtPng, fmtWebP, fmtTiff:
      px.encodeImage(formatForPath(path), opts)
    of fmtBmp:
      let dyn = px.toDynamic()
      let raw =
        case dyn.kind
        of dkRgb8: encodeBmpRgb8(dyn.rgb8)
        of dkRgba8: encodeBmpRgba8(dyn.rgba8)
        else: exportFail("BMP export needs RGB(A) pixels")
      toBytes(raw)
    of fmtGif:
      exportFail("GIF save is not supported by the pure-Nim backend")
    of fmtHeif:
      exportFail("HEIF save is not supported by the pure-Nim backend")
    of fmtAvif:
      exportFail("AVIF save is not supported by the pure-Nim backend")
    of fmtJxl:
      exportFail("JPEG-XL save is not supported by the pure-Nim backend")
  try:
    writeFile(path, data)
  except IOError as e:
    exportFail("cannot write image to '" & path & "' (" & e.msg & ")")

proc saveImage*(img: PdfImage, path: string,
    opts = ExportOptions()) =
  saveImage(img.toExportPixels(), path, opts)
