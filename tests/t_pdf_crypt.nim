## M4 tests: Standard-filter encryption (V1/V2 RC4, V4 AESV2, V5 R6).
##
## Fixtures under tests/data/pdf (see tests/gen_pdf_fixtures.nim):
## m4_rc4.pdf V2/R3 user "user123" owner "owner123";
## m4_aes.pdf V4/R4 AESV2 same passwords; m4_r6.pdf V5/R6
## user "user456" owner "owner456".

import std/strutils
import unittest
import ../src/opendocs/pdf
import ../src/opendocs/pdf/cos
import ../src/opendocs/pdf/docmodel
import ../src/opendocs/pdf/gstate

const
  Basic = "tests/data/pdf/m3a_basic.pdf"
  Rc4 = "tests/data/pdf/m4_rc4.pdf"
  Aes = "tests/data/pdf/m4_aes.pdf"
  R6 = "tests/data/pdf/m4_r6.pdf"

proc tjText(d: var PdfDoc, page: int): string =
  for op in d.walkPageOps(page):
    if op.name == "Tj":
      return op.operands[0].sval
  ""

proc contentsDict(d: var PdfDoc): CosObj =
  let page = d.pageDicts()[0]
  var c = page.dictGet("Contents")
  if c.kind == coRef:
    c = d.resolve(c)
  c

test "openPdfPassword flags encrypted files":
  check openPdfPassword(readFile(Rc4))
  check openPdfPassword(readFile(Aes))
  check openPdfPassword(readFile(R6))
  check not openPdfPassword(readFile(Basic))

test "rc4 user password reads content":
  let doc = readPdfBytes(readFile(Rc4), defaultPdfLimits(), "user123")
  check doc.hasEncrypt
  check doc.pages.len == 1
  var d = openDoc(readFile(Rc4), defaultPdfLimits(), "user123")
  check tjText(d, 0) == "Secret RC4"
  check contentsDict(d).dictGet("MyKey").sval == "hidden"

test "rc4 owner password works":
  var d = openDoc(readFile(Rc4), defaultPdfLimits(), "owner123")
  check tjText(d, 0) == "Secret RC4"

test "rc4 empty password asks for one":
  try:
    discard openDoc(readFile(Rc4))
    fail()
  except PdfError as e:
    check "password required" in e.msg

test "rc4 wrong password fails":
  expect(PdfError):
    discard openDoc(readFile(Rc4), defaultPdfLimits(), "nope")

test "encrypt dict itself stays plaintext":
  var d = openDoc(readFile(Rc4), defaultPdfLimits(), "user123")
  var enc = d.xref.encrypt
  if enc.kind == coRef:
    enc = d.resolve(enc)
  check enc.dictGet("O").sval.len == 32
  check enc.dictGet("U").sval.len == 32

test "aesv2 user password reads flate content":
  var d = openDoc(readFile(Aes), defaultPdfLimits(), "user123")
  check tjText(d, 0) == "Secret AES"
  check contentsDict(d).dictGet("MyKey").sval == "hidden2"

test "aesv2 owner password works":
  var d = openDoc(readFile(Aes), defaultPdfLimits(), "owner123")
  check tjText(d, 0) == "Secret AES"

test "aesv2 wrong password fails":
  expect(PdfError):
    discard openDoc(readFile(Aes), defaultPdfLimits(), "nope")

test "r6 user password reads content":
  var d = openDoc(readFile(R6), defaultPdfLimits(), "user456")
  check tjText(d, 0) == "Secret R6"

test "r6 owner password works":
  var d = openDoc(readFile(R6), defaultPdfLimits(), "owner456")
  check tjText(d, 0) == "Secret R6"

test "r6 wrong password fails":
  expect(PdfError):
    discard openDoc(readFile(R6), defaultPdfLimits(), "nope")

test "r6 empty password asks for one":
  try:
    discard openDoc(readFile(R6))
    fail()
  except PdfError as e:
    check "password required" in e.msg
