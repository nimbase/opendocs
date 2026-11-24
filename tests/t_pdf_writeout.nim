## M16b/c tests: outline, label and annotation writer drafts.

import unittest
import ../src/opendocs/pdf
import ../src/opendocs/pdf/cos
import ../src/opendocs/pdf/docmodel
import ../src/opendocs/pdf/gstate
import ../src/opendocs/pdf/write
import ./pdf_support

proc twoPage(): PdfBuilder =
  result = newPdfBuilder()
  let r = CosObj(kind: coDict, keys: @[], vals: @[])
  let c1 = result.addContentStream("BT ET", false)
  discard result.addPage(200.0, 200.0, c1, r)
  let c2 = result.addContentStream("BT ET", false)
  discard result.addPage(200.0, 200.0, c2, r)

test "outlines round-trip with nesting":
  var b = twoPage()
  let top = b.addOutline("Ch 1", 0)
  discard b.addOutline("Sec 1.1", 1, parent = top)
  discard b.addOutline("Ch 2", 1)
  var d = openDoc(b.buildPdf())
  let o = d.docOutlines()
  check o.len == 2
  check o[0].title == "Ch 1"
  check o[0].pageIndex == 0
  check o[0].children.len == 1
  check o[0].children[0].title == "Sec 1.1"
  check o[0].children[0].pageIndex == 1
  check o[1].pageIndex == 1

test "outline rejects bad target and parent":
  var b = twoPage()
  expect PdfError:
    discard b.addOutline("X", 5)
  expect PdfError:
    discard b.addOutline("X", 0, parent = 9)
  b.outlineDrafts.add(("Bad", 9, -1))
  expect PdfError:
    discard b.buildPdf()

test "labels round-trip":
  var b = twoPage()
  b.setPageLabels(@[(style: "r", prefix: "", start: 0, first: 1),
    (style: "D", prefix: "", start: 1, first: 4)])
  var d = openDoc(b.buildPdf())
  let ls = d.pageLabels()
  check ls.len == 2
  check labelForPage(ls, 0) == "i"
  check labelForPage(ls, 1) == "4"

test "labels reject duplicates and bad style":
  var b = twoPage()
  expect PdfError:
    b.setPageLabels(@[(style: "X", prefix: "", start: 0, first: 1)])
  b.setPageLabels(@[(style: "D", prefix: "", start: 0, first: 1),
    (style: "D", prefix: "", start: 0, first: 2)])
  expect PdfError:
    discard b.buildPdf()

test "annotations round-trip":
  var b = twoPage()
  b.addLink(0, [0.0, 0.0, 50.0, 10.0], "https://example.com/")
  b.addInternalLink(0, [0.0, 20.0, 50.0, 30.0], 1)
  b.addTextAnnot(1, [30.0, 30.0, 10.0, 10.0], "note")
  var d = openDoc(b.buildPdf())
  let a0 = d.pageAnnots(0)
  check a0.len == 2
  check a0[0].uri == "https://example.com/"
  check a0[1].destPage == 1
  let a1 = d.pageAnnots(1)
  check a1.len == 1
  check a1[0].subtype == "Text"
  check a1[0].contents == "note"
  check a1[0].rect == [10.0, 10.0, 30.0, 30.0]

test "annotations reject bad page and empty":
  var b = twoPage()
  expect PdfError:
    b.addLink(5, [0.0, 0.0, 1.0, 1.0], "https://example.com/")
  expect PdfError:
    b.addLink(0, [0.0, 0.0, 1.0, 1.0], "")
  expect PdfError:
    b.addTextAnnot(0, [0.0, 0.0, 1.0, 1.0], "")
