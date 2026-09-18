## Shared image export through libvips for document formats.
##
## One format enum plus options shared by every module: PDF images
## (`PdfImage`), and later DOCX extracted images and other doc formats,
## convert to ExportPixels and encode or save. JPEG, PNG and WebP encode
## to memory; every format saves to a path, dispatched by file extension.
## Alpha flattens over white for JPEG (the only listed format without
## alpha); vips errors surface as ExportError.

import std/strutils
import libvips/api
import libvips/bindings/vips
import ./pdf/vipsimg

type
  ExportError* = object of CatchableError

  ImageFormat* = enum
    fmtJpeg, fmtPng, fmtWebP, fmtTiff, fmtGif, fmtHeif, fmtAvif, fmtJxl

  ExportOptions* = object
    jpegQuality*: range[0..100] = 90
    pngCompression*: range[0..9] = 6
    webpQuality*: range[0..100] = 90

  ExportPixels* = object
    width*: int
    height*: int
    bands*: int ## 1 gray, 3 rgb, 4 rgb+alpha (8-bit)
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
  else: exportFail("unsupported image extension '." & ext &
      "' (want jpg, png, webp, tif, gif, heif, avif or jxl)")

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
  let comps = px.bands - 1
  result = ExportPixels(width: px.width, height: px.height,
    bands: comps, data: newString(px.width * px.height * comps))
  for i in 0 ..< px.width * px.height:
    let a = int(byte(px.data[i * px.bands + comps]))
    for c in 0 ..< comps:
      let v = int(byte(px.data[i * px.bands + c]))
      result.data[i * comps + c] = char(v * a div 255 +
        255 * (255 - a) div 255)

proc toBytes(s: string): seq[uint8] =
  result = newSeq[uint8](s.len)
  if s.len > 0:
    copyMem(addr result[0], unsafeAddr s[0], s.len)

proc toVips(px: ExportPixels): Image =
  if px.width <= 0 or px.height <= 0 or
      px.data.len != px.width * px.height * px.bands:
    exportFail("export pixel size mismatch")
  var data = toBytes(px.data)
  fromMemory(data, px.width, px.height, px.bands, VIPS_FORMAT_UCHAR)

proc encodeImage*(px: ExportPixels, format: ImageFormat,
    opts = ExportOptions()): string =
  ## Encode to JPEG, PNG or WebP bytes. Other formats need a path
  ## (use saveImage); conversions without a memory encoder fail loudly.
  ensureVips()
  try:
    let bytes =
      case format
      of fmtJpeg: flattenWhite(px).toVips().saveJPEG(opts.jpegQuality)
      of fmtPng: px.toVips().savePNG(opts.pngCompression)
      of fmtWebP: px.toVips().saveWebP(opts.webpQuality)
      else: exportFail("format " & $format &
          " has no memory encoder (use saveImage with a path)")
    result = newString(bytes.len)
    if bytes.len > 0:
      copyMem(addr result[0], unsafeAddr bytes[0], bytes.len)
  except VipsError as e:
    exportFail("libvips encode failed (" & e.msg & ")")

proc encodeImage*(img: PdfImage, format: ImageFormat,
    opts = ExportOptions()): string =
  encodeImage(img.toExportPixels(), format, opts)

proc saveImage*(px: ExportPixels, path: string,
    opts = ExportOptions()) =
  ## Save to path, dispatching on the file extension. JPEG honors
  ## jpegQuality, PNG honors pngCompression, WebP honors webpQuality;
  ## the rest use the binding defaults.
  ensureVips()
  try:
    case formatForPath(path)
    of fmtJpeg:
      flattenWhite(px).toVips().saveJPEG(path, opts.jpegQuality)
    of fmtPng:
      px.toVips().savePNG(path, opts.pngCompression)
    of fmtWebP:
      px.toVips().saveWebP(path, opts.webpQuality)
    of fmtTiff:
      px.toVips().saveTIFF(path)
    of fmtGif:
      px.toVips().saveGIF(path)
    of fmtHeif:
      px.toVips().saveHEIF(path)
    of fmtAvif:
      px.toVips().saveAVIF(path)
    of fmtJxl:
      px.toVips().saveJXL(path)
  except VipsError as e:
    exportFail("libvips save to '" & path & "' failed (" & e.msg & ")")

proc saveImage*(img: PdfImage, path: string,
    opts = ExportOptions()) =
  saveImage(img.toExportPixels(), path, opts)
