## M16a tests: page organize.

import unittest
import ../src/opendocs/pdf
import ../src/opendocs/pdf/cos
import ../src/opendocs/pdf/docmodel
import ../src/opendocs/pdf/gstate
import ../src/opendocs/pdf/write
import ./pdf_support

test "rotation sets and clears":
  var u = beginUpdate(buildSimplePdf(@[(w: 100.0, h: 100.0)]))
  u.setPageRotation(0, 90)
  let data = u.finishUpdate()
  var d = openDoc(data)
  check d.pageDicts()[0].dictGet("Rotate").ival == 90
  var u2 = beginUpdate(data)
  u2.setPageRotation(0, 0)
  var d2 = openDoc(u2.finishUpdate())
  check d2.pageDicts()[0].dictGet("Rotate").kind == coNull

test "rotation rejects non-multiples":
  var u = beginUpdate(buildSimplePdf(@[(w: 10.0, h: 10.0)]))
  expect PdfError:
    u.setPageRotation(0, 45)

test "rotation rejects bad page":
  var u = beginUpdate(buildSimplePdf(@[(w: 10.0, h: 10.0)]))
  expect PdfError:
    u.setPageRotation(3, 90)

test "page box sets and normalizes":
  var u = beginUpdate(buildSimplePdf(@[(w: 100.0, h: 100.0)]))
  u.setPageBox(0, "CropBox", [50.0, 50.0, 0.0, 0.0])
  var d = openDoc(u.finishUpdate())
  let b = d.pageDicts()[0].dictGet("CropBox")
  check b.items[0].asFloat() == 0.0
  check b.items[2].asFloat() == 50.0

test "page box rejects unknown and degenerate":
  var u = beginUpdate(buildSimplePdf(@[(w: 10.0, h: 10.0)]))
  expect PdfError:
    u.setPageBox(0, "Nope", [0.0, 0.0, 10.0, 10.0])
  expect PdfError:
    u.setPageBox(0, "CropBox", [5.0, 5.0, 5.0, 5.0])

test "delete keeps order":
  var b = newPdfBuilder()
  let r = CosObj(kind: coDict, keys: @[], vals: @[])
  let c1 = b.addContentStream("BT ET", false)
  discard b.addPage(100.0, 100.0, c1, r)
  let c2 = b.addContentStream("BT ET", false)
  discard b.addPage(100.0, 100.0, c2, r)
  let c3 = b.addContentStream("BT ET", false)
  discard b.addPage(100.0, 100.0, c3, r)
  b.deletePages(@[2, 0])
  check b.kids.len == 2
  let data = b.buildPdf()
  var d = openDoc(data)
  check d.pageCount() == 2

test "delete rejects empty and out of range":
  var b = newPdfBuilder()
  let r = CosObj(kind: coDict, keys: @[], vals: @[])
  let c1 = b.addContentStream("BT ET", false)
  discard b.addPage(100.0, 100.0, c1, r)
  expect PdfError:
    b.deletePages(@[])
  expect PdfError:
    b.deletePages(@[5])

test "append transplants pages":
  let src = buildSimplePdf(@[(w: 11.0, h: 12.0), (w: 13.0, h: 14.0)])
  var b = newPdfBuilder()
  b.appendPages(src, @[1])
  check b.kids.len == 1
  var d = openDoc(b.buildPdf())
  check d.pageBoxes()[0].width == 13.0
