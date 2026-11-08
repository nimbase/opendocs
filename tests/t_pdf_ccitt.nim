## M14 tests: CCITTFaxDecode (T.4 1D + T.6 2D).
##
## Vectors are independent of the decoder: a 172x12 pattern exercising
## short/makeup/extended runs in both colors, all-white, all-black,
## alternating and text-like rows. `tests/data/pdf/ccitt/plain.tif` is an
## uncompressed 1-bit TIFF (0 = white) written by a throwaway script;
## `g4.raw` / `g31d.raw` are its strips after `tiffcp -c g4` / `-c g3:1d`
## (libtiff 4.7.1, MacPorts). `expected_pdf.raw` repacks the pixels to PDF
## image convention (1 = white); `expected.raw` keeps TIFF convention for
## the /BlackIs1 test. `g32d.raw` (`-c g3:2d`) is kept for the future K>0
## work; K > 0 still fails loudly. The decoder must agree with libtiff,
## not with itself.

import std/strutils
import unittest
import ../src/opendocs/pdf
import ../src/opendocs/pdf/docmodel
import ../src/opendocs/pdf/filters
import ../src/opendocs/pdf/images
import ./pdf_support

const CcDir = "tests/data/pdf/ccitt/"
const W = 172
const H = 12
const Stride = 22 # (172+7) div 8

proc bitsOf(s: string): string =
  ## '0'/'1' per pixel bit, MSB first, for readable diffs.
  for ch in s:
    for b in [0x80, 0x40, 0x20, 0x10, 0x08, 0x04, 0x02, 0x01]:
      result.add(if (int(byte(ch)) and b) != 0: '1' else: '0')

test "g4 group4 matches libtiff pixels":
  let enc = readFile(CcDir & "g4.raw")
  let want = readFile(CcDir & "expected_pdf.raw")
  check enc.len == 209 # frozen: guards against silent fixture swap
  let got = ccittFaxDecode(enc, W, H, -1, false, false, false, 0)
  check got.len == want.len
  check got == want

test "g3 1d matches libtiff pixels":
  let enc = readFile(CcDir & "g31d.raw")
  let want = readFile(CcDir & "expected_pdf.raw")
  check enc.len == 157
  let got = ccittFaxDecode(enc, W, H, 0, false, false, false, 0)
  check got == want

test "rows=0 decodes until data ends":
  for (name, k) in [("g4.raw", -1), ("g31d.raw", 0)]:
    let got = ccittFaxDecode(readFile(CcDir & name), W, 0, k,
      false, false, false, 0)
    check got == readFile(CcDir & "expected_pdf.raw")

test "rows pad short data with white":
  let enc = readFile(CcDir & "g4.raw")
  let got = ccittFaxDecode(enc, W, H + 2, -1, false, false, false, 0)
  check got.len == (H + 2) * Stride
  check got[0 ..< H * Stride] == readFile(CcDir & "expected_pdf.raw")
  var tail = newString(2 * Stride)
  for i in 0 ..< tail.len: tail[i] = '\xFF'
  check got[H * Stride .. ^1] == tail

test "blackis1 inverts to tiff convention":
  let enc = readFile(CcDir & "g4.raw")
  let got = ccittFaxDecode(enc, W, H, -1, true, false, false, 0)
  check got == readFile(CcDir & "expected.raw")

test "k>0 fails loudly":
  expect PdfError:
    discard ccittFaxDecode(readFile(CcDir & "g32d.raw"), W, H, 1,
      false, false, false, 0)

test "absurd columns fail before allocating":
  expect PdfError:
    discard ccittFaxDecode("\x00", 1 shl 21, 1, -1,
      false, false, false, 0)

test "empty input fails, not empty image":
  expect PdfError:
    discard ccittFaxDecode("", W, H, -1, false, false, false, 0)

test "corrupt row fails without budget, white-substitutes with budget":
  # Hand-packed 8px rows: white, 12 bad bits (no white code matches any
  # prefix), white-0 then black-8; then RTC. Damage resyncs at next EOL.
  let enc = "\x00\x19\x80\x0c\x80\x00\x09\xa8\xa0\x02\x00\x20\x02\x00\x20\x02\x00\x20"
  expect PdfError:
    discard ccittFaxDecode(enc, 8, 3, 0, false, false, false, 0)
  let got = ccittFaxDecode(enc, 8, 3, 0, false, false, false, 1)
  check got == "\xFF\xFF\x00"

test "truncated data fails, pads white with budget":
  # Cutting 20 of 157 bytes starves rows 8..11 (frozen: first diff row
  # is 8 for this fixture). Budget covers the damage; the tail is white.
  let enc = readFile(CcDir & "g31d.raw")
  let cut = enc[0 ..< enc.len - 20]
  expect PdfError:
    discard ccittFaxDecode(cut, W, H, 0, false, false, false, 0)
  let got = ccittFaxDecode(cut, W, H, 0, false, false, false, 4)
  let want = readFile(CcDir & "expected_pdf.raw")
  check got.len == H * Stride
  check got[0 ..< 8 * Stride] == want[0 ..< 8 * Stride]
  var tail = newString(4 * Stride)
  for i in 0 ..< tail.len: tail[i] = '\xFF'
  check got[8 * Stride .. ^1] == tail

test "ccitt image xobject end to end":
  let enc = readFile(CcDir & "g4.raw")
  let imgDict = "/Type /XObject /Subtype /Image /Width " & $W &
    " /Height " & $H & " /BitsPerComponent 1 /ColorSpace /DeviceGray" &
    " /Filter /CCITTFaxDecode /DecodeParms << /K -1 >>"
  let content = "q " & $W & " 0 0 " & $H & " 0 0 cm /Im0 Do Q"
  let pdf = assemblePdf(@[
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] " &
      "/Resources << /XObject << /Im0 4 0 R >> >> /Contents 5 0 R >>",
    streamObj(imgDict, enc),
    streamObj("", content),
  ])
  var d = openDoc(pdf)
  let raws = d.pageRawImages(0)
  check raws.len == 1
  check raws[0].name == "Im0"
  check raws[0].raw.width == W and raws[0].raw.height == H
  check not raws[0].raw.coded
  check raws[0].raw.samples == readFile(CcDir & "expected_pdf.raw")

test "ccitt with default columns/rows uses width and height":
  # Columns/Rows absent: image context supplies both (K still declared).
  let enc = readFile(CcDir & "g4.raw")
  let imgDict = "/Type /XObject /Subtype /Image /Width " & $W &
    " /Height " & $H & " /BitsPerComponent 1 /ColorSpace /DeviceGray" &
    " /Filter /CCITTFaxDecode /DecodeParms << /K -1 >>"
  let content = "q /Im0 Do Q"
  let pdf = assemblePdf(@[
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] " &
      "/Resources << /XObject << /Im0 4 0 R >> >> /Contents 5 0 R >>",
    streamObj(imgDict, enc),
    streamObj("", content),
  ])
  var d = openDoc(pdf)
  check d.pageRawImages(0)[0].raw.samples ==
    readFile(CcDir & "expected_pdf.raw")

test "table spot checks":
  # Hand-packed: EOL, white run 8 (10011), EOL = all-white 8px row.
  # Bits: 000000000001 10011 000000000001 -> bytes 00 19 80 08.
  let s = "\x00\x19\x80\x08"
  let got = ccittFaxDecode(s, 8, 1, 0, false, false, false, 0)
  check got == "\xFF"
  check bitsOf(got) == "11111111"
