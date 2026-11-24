## M18 tests: optimizer + space audit.

import std/strutils
import std/tables
import unittest
import ../src/opendocs/pdf
import ../src/opendocs/pdf/cos
import ../src/opendocs/pdf/docmodel
import ../src/opendocs/pdf/gstate
import ../src/opendocs/pdf/write
import ./pdf_support

proc noisePixels(w, h, comps: int): string =
  ## Deterministic incompressible bytes (xorshift32) so Flate input
  ## stays large and shrink assertions are meaningful.
  result = newString(w * h * comps)
  var x = 0x12345678u32
  for i in 0 ..< result.len:
    x = x xor (x shl 13)
    x = x xor (x shr 17)
    x = x xor (x shl 5)
    result[i] = char(x and 0xFF)

proc bigImagePdf(): string =
  var b = newPdfBuilder()
  let img = b.addRgbImage(noisePixels(300, 300, 3), 300, 300, 3)
  let content = b.addContentStream(
    "q 300 0 0 300 0 0 cm /Im0 Do Q", false)
  let res = CosObj(kind: coDict, keys: @["XObject"],
    vals: @[CosObj(kind: coDict, keys: @["Im0"],
      vals: @[CosObj(kind: coRef, refNum: img, refGen: 0)])])
  discard b.addPage(300.0, 300.0, content, res)
  b.buildPdf()

test "audit sees the image bytes":
  var d = openDoc(bigImagePdf())
  let audit = d.spaceAudit()
  var images = 0
  var total = 0
  for (kind, bytes) in audit:
    total += bytes
    if kind == "images":
      images = bytes
  check images > 100000
  check total > images

test "downscale shrinks and keeps pixels":
  let (small, stats) = optimizePdf(bigImagePdf(),
    OptimizeOptions(maxImageWidth: 100, jpegQuality: 0, reflate: true))
  check stats.downsized == 1
  check small.len < bigImagePdf().len
  var d = openDoc(small)
  check d.pageImages(0).len == 1
  check d.pageImages(0)[0].width == 100
  check d.pageImages(0)[0].height == 100

test "jpeg recompress keeps readable pixels":
  let (enc, stats) = optimizePdf(bigImagePdf(),
    OptimizeOptions(maxImageWidth: 0, jpegQuality: 70, reflate: true))
  check stats.recompressed == 1
  var d = openDoc(enc)
  check d.pageImages(0).len == 1
  check d.pageImages(0)[0].width == 300
  var sawDct = false
  for num in d.xref.entries.keys:
    if not d.xref.entries[num].live:
      continue
    let e = d.xref.entries[num]
    let o = d.resolve(CosObj(kind: coRef, refNum: num, refGen: e.gen))
    if o.kind == coStream and o.dictGet("Subtype").kind == coName and
        o.dictGet("Subtype").name == "Image":
      let f = o.dictGet("Filter")
      if f.kind == coName and f.name == "DCTDecode":
        sawDct = true
  check sawDct

test "optimize is deterministic":
  let opts = OptimizeOptions(maxImageWidth: 100, jpegQuality: 70,
    reflate: true)
  check optimizePdf(bigImagePdf(), opts).pdf ==
    optimizePdf(bigImagePdf(), opts).pdf

test "bad options fail":
  expect PdfError:
    discard optimizePdf(bigImagePdf(),
      OptimizeOptions(maxImageWidth: -1, jpegQuality: 0, reflate: true))
  expect PdfError:
    discard optimizePdf(bigImagePdf(),
      OptimizeOptions(maxImageWidth: 0, jpegQuality: 101, reflate: true))

test "masked images are skipped intact":
  let pdf = assemblePdf(@[
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] " &
      "/Resources << /XObject << /Im0 4 0 R >> >> /Contents 6 0 R >>",
    "<< /Type /XObject /Subtype /Image /Width 2 /Height 2 " &
      "/ColorSpace /DeviceGray /BitsPerComponent 8 /SMask 5 0 R " &
      "/Length 4 >>\nstream\nabcd\nendstream",
    "<< /Type /XObject /Subtype /Image /Width 2 /Height 2 " &
      "/ColorSpace /DeviceGray /BitsPerComponent 8 " &
      "/Length 4 >>\nstream\nabcd\nendstream",
    streamObj("", "q 2 0 0 2 0 0 cm /Im0 Do Q"),
  ])
  let (data, stats) = optimizePdf(pdf,
    OptimizeOptions(maxImageWidth: 1, jpegQuality: 70, reflate: true))
  check stats.skipped >= 1
  var d = openDoc(data)
  check d.pageCount() == 1
