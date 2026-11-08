## P4 tests: annotation read (links, notes, markup, widgets).

import std/strutils
import unittest
import ../src/opendocs/pdf
import ./pdf_support

const Annots = "tests/data/pdf/annots.pdf"

proc annots(page: int): seq[PdfAnnot] =
  var d = openDoc(readFile(Annots))
  d.pageAnnots(page)

test "page holds seven annotations":
  check annots(0).len == 7
  check annots(1).len == 0

test "uri link surfaces the target":
  let a = annots(0)[0]
  check a.subtype == "Link"
  check a.uri == "https://example.com/x"
  check a.destPage == -1
  check a.rect == [0.0, 0.0, 100.0, 20.0]
  check a.border == @[0.0, 0.0, 1.0]

test "internal link resolves the page":
  let a = annots(0)[1]
  check a.subtype == "Link"
  check a.destPage == 1
  check a.uri == ""

test "text note carries author and subject":
  let a = annots(0)[2]
  check a.subtype == "Text"
  check a.contents == "Fix this"
  check a.author == "Anne"
  check a.subject == "Review"
  check a.color == @[1.0, 0.0, 0.0]
  check a.flags == 4
  check a.modified == "D:20260101"

test "reversed rect normalises":
  let a = annots(0)[3]
  check a.subtype == "Square"
  check a.rect == [0.0, 0.0, 50.0, 50.0]

test "highlight carries quad points":
  let a = annots(0)[4]
  check a.subtype == "Highlight"
  check a.quadPoints.len == 1
  check a.quadPoints[0] == [0.0, 10.0, 60.0, 10.0, 0.0, 0.0, 60.0, 0.0]

test "ink carries strokes":
  let a = annots(0)[5]
  check a.subtype == "Ink"
  check a.inkList.len == 2
  check a.inkList[0] == @[0.0, 0.0, 10.0, 10.0, 20.0, 0.0]
  check a.inkList[1] == @[5.0, 5.0, 5.0, 15.0]

test "widget names the field, not an author":
  let a = annots(0)[6]
  check a.subtype == "Widget"
  check a.name == "field1"
  check a.author == ""

test "document-wide listing tags pages":
  var d = openDoc(readFile(Annots))
  let all = d.docAnnots()
  check all.len == 7
  for (page, _) in all:
    check page == 0

test "malformed rect fails naming the annotation":
  let data = assemblePdf(@["<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] " &
      "/Annots [4 0 R] >>",
    "<< /Type /Annot /Subtype /Text /Rect [0 0] >>"])
  var d = openDoc(data)
  var msg = ""
  try:
    discard d.pageAnnots(0)
  except PdfError as e:
    msg = e.msg
  check "annotation 0 on page 0" in msg

test "non-array annots fails":
  let data = assemblePdf(@["<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] " &
      "/Annots 4 0 R >>",
    "<< /Type /Annot /Subtype /Text /Rect [0 0 10 10] >>"])
  var d = openDoc(data)
  expect PdfError:
    discard d.pageAnnots(0)
