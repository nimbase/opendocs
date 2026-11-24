## M17 tests: redaction mark/apply/verify.

import std/strutils
import unittest
import ../src/opendocs/pdf
import ../src/opendocs/pdf/cos
import ../src/opendocs/pdf/docmodel
import ../src/opendocs/pdf/gstate
import ../src/opendocs/pdf/write
import ./pdf_support

proc redactPdf(): string =
  ## Two text lines plus a text annot; content stream is one Flate
  ## stream so surgery paths stay covered without multi-stream setup.
  var b = newPdfBuilder()
  let r = CosObj(kind: coDict, keys: @[], vals: @[])
  let c = b.addContentStream(
    "BT /F1 12 Tf 50 700 Td (Alpha public) Tj ET\n" &
    "BT /F1 12 Tf 50 650 Td (Beta secret) Tj ET\n")
  let fdict = CosObj(kind: coDict,
    keys: @["Type", "Subtype", "BaseFont"],
    vals: @[CosObj(kind: coName, name: "Font"),
      CosObj(kind: coName, name: "Type1"),
      CosObj(kind: coName, name: "Helvetica")])
  let fnum = b.addValue(fdict)
  let res = CosObj(kind: coDict, keys: @["Font"],
    vals: @[CosObj(kind: coDict, keys: @["F1"],
      vals: @[CosObj(kind: coRef, refNum: fnum, refGen: 0)])])
  discard b.addPage(300.0, 800.0, c, res)
  discard r
  b.buildPdf()

test "mark adds redact annots":
  let data = markRedactions(redactPdf(),
    @[(page: 0, rect: [40.0, 640.0, 200.0, 665.0])])
  var d = openDoc(data)
  let a = d.pageAnnots(0)
  check a.len == 1
  check a[0].subtype == "Redact"

test "mark rejects empty and bad rects":
  expect PdfError:
    discard markRedactions(redactPdf(), @[])
  expect PdfError:
    discard markRedactions(redactPdf(),
      @[(page: 3, rect: [0.0, 0.0, 10.0, 10.0])])
  expect PdfError:
    discard markRedactions(redactPdf(),
      @[(page: 0, rect: [5.0, 5.0, 5.0, 5.0])])

test "apply removes the covered line and verifies":
  let rects = @[(page: 0, rect: [40.0, 640.0, 200.0, 665.0])]
  let data = applyRedactions(redactPdf(), rects)
  var d = openDoc(data)
  let txt = d.extractText(0).join(" ")
  check txt.contains("Alpha")
  check not txt.contains("Beta")
  verifyNoFauxRedaction(data, rects)

test "apply drops marks and paints over":
  let rects = @[(page: 0, rect: [40.0, 640.0, 200.0, 665.0])]
  let marked = markRedactions(redactPdf(), rects)
  let data = applyRedactions(marked, rects)
  var d = openDoc(data)
  for a in d.pageAnnots(0):
    check a.subtype != "Redact"
  check not d.extractText(0).join(" ").contains("Beta")

test "verify fails on unapplied content":
  let rects = @[(page: 0, rect: [40.0, 640.0, 200.0, 665.0])]
  expect PdfError:
    verifyNoFauxRedaction(redactPdf(), rects)

test "rect over blank area still paints and verifies":
  let rects = @[(page: 0, rect: [10.0, 10.0, 60.0, 30.0])]
  let data = applyRedactions(redactPdf(), rects)
  verifyNoFauxRedaction(data, rects)
  var d = openDoc(data)
  check d.extractText(0).join(" ").contains("Alpha")
