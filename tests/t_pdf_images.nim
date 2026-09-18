## M5 tests: image XObjects through the libvips pipeline.
##
## Fixture tests/data/pdf/m5_images.pdf (see tests/gen_pdf_fixtures.nim):
## Im1 2x2 RGB Flate; Im2 2x2 gray Flate with SMask; Im3 2x2 Indexed;
## Im4 4x4 solid-red JPEG; Im5 1x1 DeviceCMYK red; Im6 2x2 stencil
## mask; Im7 2x1 gray with a [200 255] color-key mask.

import std/strutils
import unittest
import ../src/opendocs/pdf
import ./pdf_support

const ImagesPdf = "tests/data/pdf/m5_images.pdf"

proc byName(images: seq[PdfImage], name: string): PdfImage =
  for im in images:
    if im.name == name:
      return im
  raise newException(AssertionDefect, "image /" & name & " missing")

proc close(a, b: int, tol = 12): bool =
  abs(a - b) <= tol

test "page holds seven images":
  var d = openDoc(readFile(ImagesPdf))
  check d.pageImages(0).len == 7

test "flate rgb exact":
  var d = openDoc(readFile(ImagesPdf))
  let im = byName(d.pageImages(0), "Im1")
  check im.width == 2 and im.height == 2
  check im.encoding == ieRGB and not im.hasAlpha
  check im.pixels == "\xFF\x00\x00\x00\xFF\x00\x00\x00\xFF\xFF\xFF\xFF"

test "gray plus smask becomes gray alpha":
  var d = openDoc(readFile(ImagesPdf))
  let im = byName(d.pageImages(0), "Im2")
  check im.encoding == ieGray and im.hasAlpha
  check im.pixels ==
    "\x00\xFF\x55\xFF\xAA\x00\xFF\x00"

test "indexed expands palette":
  var d = openDoc(readFile(ImagesPdf))
  let im = byName(d.pageImages(0), "Im3")
  check im.encoding == ieRGB and not im.hasAlpha
  check im.pixels == "\xFF\x00\x00\x00\xFF\x00\x00\xFF\x00\xFF\x00\x00"

test "jpeg decodes near red":
  var d = openDoc(readFile(ImagesPdf))
  let im = byName(d.pageImages(0), "Im4")
  check im.width == 4 and im.height == 4
  check im.encoding == ieRGB and not im.hasAlpha
  check im.pixels.len == 48
  check close(int(byte(im.pixels[0])), 255)
  check close(int(byte(im.pixels[1])), 0)
  check close(int(byte(im.pixels[2])), 0)

test "cmyk red converts":
  var d = openDoc(readFile(ImagesPdf))
  let im = byName(d.pageImages(0), "Im5")
  check im.encoding == ieRGB and not im.hasAlpha
  check im.pixels.len == 3
  # Colorimetric through the default CMYK profile: clearly red.
  let r = int(byte(im.pixels[0]))
  let g = int(byte(im.pixels[1]))
  let b = int(byte(im.pixels[2]))
  check r > 200 and r > g + 100 and r > b + 100

test "stencil mask becomes alpha":
  var d = openDoc(readFile(ImagesPdf))
  let im = byName(d.pageImages(0), "Im6")
  check im.encoding == ieAlpha and im.hasAlpha
  check im.pixels == "\xFF\x00\x00\xFF"

test "color key flattens over white":
  var d = openDoc(readFile(ImagesPdf))
  let im = byName(d.pageImages(0), "Im7")
  check im.encoding == ieGray and im.hasAlpha
  # GrayA: hidden white pixel, opaque black pixel.
  check im.pixels == "\xFF\x00\x00\xFF"

proc imagePdf(xobj, name: string): string =
  assemblePdf(@[
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] " &
      "/Resources << /XObject << /" & name & " 4 0 R >> >> " &
      "/Contents 5 0 R >>",
    xobj,
    streamObj("", "/" & name & " Do"),
  ])

test "lab image names the gap":
  let data = imagePdf("<< /Type /XObject /Subtype /Image /Width 1 " &
    "/Height 1 /ColorSpace [/Lab << /WhitePoint [0.95 1.0 1.09] " &
    "/Range [-100 100 -100 100] >>] /BitsPerComponent 8 " &
    "/Length 3 >>\nstream\nabc\nendstream", "ImL")
  var d = openDoc(data)
  try:
    discard d.pageImages(0)
    fail()
  except PdfError as e:
    check "Lab" in e.msg

test "ccitt names the gap":
  let data = imagePdf("<< /Type /XObject /Subtype /Image /Width 2 " &
    "/Height 2 /ColorSpace /DeviceGray /BitsPerComponent 1 " &
    "/Filter /CCITTFaxDecode /Length 4 >>\nstream\nxxxx\nendstream",
    "ImC")
  var d = openDoc(data)
  try:
    discard d.pageImages(0)
    fail()
  except PdfError as e:
    check "CCITTFaxDecode" in e.msg

test "missing xobject fails":
  let data = assemblePdf(@[
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] " &
      "/Resources << /XObject << >> >> /Contents 4 0 R >>",
    streamObj("", "/Nope Do"),
  ])
  var d = openDoc(data)
  expect(PdfError):
    discard d.pageImages(0)
