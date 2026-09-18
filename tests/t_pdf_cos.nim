import std/strutils
import std/tables
import unittest
import ../src/opendocs/pdf
import ../src/opendocs/pdf/cos
import ../src/opendocs/pdf/lexer
import ../src/opendocs/pdf/docmodel
import ./pdf_support

proc objAt(data: string, num: int): CosObj =
  var doc = openDoc(data)
  doc.resolve(CosObj(kind: coRef, refNum: num, refGen: 0))

test "scalar values":
  let data = buildSimplePdf(@[(w: 10.0, h: 10.0)])
  var doc = openDoc(data)
  check doc.resolve(CosObj(kind: coRef, refNum: 1,
    refGen: 0)).dictGet("Type").asName() == "Catalog"
  let pages = doc.resolve(CosObj(kind: coRef, refNum: 2, refGen: 0))
  check pages.dictGet("Count").asInt() == 1

test "names, strings, hex, escapes":
  let body = "<< /N /A#20B /L (a\\(b\\)c) /H <4142> /T true /F false /Z null /I 7 /R 4 0 R >>"
  let data = assemblePdf(@["<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [] /Count 0 >>", body])
  let o = objAt(data, 3)
  check o.dictGet("N").asName() == "A B"
  check o.dictGet("L").sval == "a(b)c"
  check o.dictGet("H").sval == "AB"
  check o.dictGet("T").bval
  check not o.dictGet("F").bval
  check o.dictGet("Z").kind == coNull
  check o.dictGet("I").asInt() == 7
  check o.dictGet("I").asFloat() == 7.0
  check o.dictGet("R").kind == coRef

test "floats and negative numbers":
  let data = assemblePdf(@["<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [] /Count 0 >>",
    "<< /A [-1.5 2. .5 +3] >>"])
  let arr = objAt(data, 3).dictGet("A")
  check arr.items[0].asFloat() == -1.5
  check arr.items[1].asFloat() == 2.0
  check arr.items[2].asFloat() == 0.5
  check arr.items[3].asFloat() == 3.0

test "stream object with direct length":
  let payload = "hello stream bytes"
  let data = assemblePdf(@["<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [] /Count 0 >>",
    streamObj("/Type /EmbeddedFile", payload)])
  let o = objAt(data, 3)
  check o.kind == coStream
  check o.raw == payload
  check o.dictGet("Type").asName() == "EmbeddedFile"

test "stream with indirect length resolved via doc":
  let payload = "indirect length body"
  let data = assemblePdf(@["<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [] /Count 0 >>",
    "<< /Length 4 0 R >>\nstream\n" & payload & "\nendstream",
    $payload.len])
  var doc = openDoc(data)
  let o = doc.resolve(CosObj(kind: coRef, refNum: 3, refGen: 0))
  check o.kind == coStream
  check o.raw == payload

test "parseIndirect rejects indirect length without doc":
  let payload = "x"
  let data = assemblePdf(@["<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [] /Count 0 >>",
    "<< /Length 4 0 R >>\nstream\n" & payload & "\nendstream",
    $payload.len])
  var doc = openDoc(data)
  let off = doc.xref.entries[3].offset
  var msg = ""
  try:
    discard parseIndirect(fromString(data), off)
  except PdfError as e:
    msg = e.msg
  check "document context" in msg

test "malformed values raise":
  let bad = "<< /A (unterminated >>"
  let data = assemblePdf(@["<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [] /Count 0 >>", bad])
  expect(PdfError):
    discard objAt(data, 3)
