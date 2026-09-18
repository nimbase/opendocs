## Sheet extraction: pages of classified rows.
import std/os
import std/strutils
import unittest
import ../src/opendocs/pdf
import ../src/opendocs/pdf/cos
import ../src/opendocs/pdf/write
import ../src/opendocs/pdf/sheet

const bigPdf = "tests" / "data" / "pdf" / "file-example_PDF_500_kB.pdf"

proc sheetResources(): CosObj =
  let f1 = CosObj(kind: coDict, keys: @["Type", "Subtype", "BaseFont"],
    vals: @[CosObj(kind: coName, name: "Font"),
      CosObj(kind: coName, name: "Type1"),
      CosObj(kind: coName, name: "Helvetica")])
  CosObj(kind: coDict, keys: @["Font"],
    vals: @[CosObj(kind: coDict, keys: @["F1"], vals: @[f1])])

proc sheetDoc(): PdfDoc =
  var b = newPdfBuilder()
  let res = sheetResources()
  let parts = @[
    "BT /F1 24 Tf 72 720 Td (Report Title) Tj ET",
    "BT /F1 12 Tf 72 680 Td (First body line) Tj " &
      "0 -14 Td (Second body line) Tj ET",
    "BT /F1 12 Tf 72 640 Td (- item one) Tj " &
      "0 -14 Td (- item two) Tj ET",
    "BT /F1 9 Tf 72 600 Td (Figure 1: demo chart) Tj ET",
    "BT /F1 12 Tf 72 560 Td (1. ordered step) Tj ET",
    "BT /F1 7 Tf 72 540 Td (tiny footer note) Tj ET",
  ]
  var content = ""
  for p in parts:
    content.add(p & " ")
  discard b.addPage(612.0, 792.0, b.addContentStream(content,
    flate = false), res)
  openDoc(b.buildPdf())

test "body size is the mode":
  var d = sheetDoc()
  check bodySize(d.pageText(0).lines) == 12.0
  check bodySize(@[]) == 0.0

test "rows classify in content order":
  var d = sheetDoc()
  let page = d.sheetPage(0)
  check page.width == 612.0
  check page.rows.len == 6
  let kinds: seq[BlockKind] = @[bkHeading, bkParagraph, bkListItem,
    bkCaption, bkListItem, bkOther]
  for i, row in page.rows:
    check row.kind == kinds[i]
  check page.rows[0].text == "Report Title"
  check page.rows[0].size == 24.0
  check page.rows[1].text == "First body line\nSecond body line"
  check page.rows[2].text == "- item one\n- item two"
  check page.rows[5].text == "tiny footer note"

test "empty page has no rows":
  var b = newPdfBuilder()
  discard b.addPage(100.0, 200.0,
    b.addContentStream("", flate = false),
    CosObj(kind: coDict, keys: @[], vals: @[]))
  var d = openDoc(b.buildPdf())
  check d.sheetPage(0).rows.len == 0

proc gridDoc(): PdfDoc =
  var b = newPdfBuilder()
  let res = sheetResources()
  let cells = @[
    (72.0, 700.0, 14.0, "Name"), (200.0, 700.0, 14.0, "Qty"),
    (330.0, 700.0, 14.0, "Price"),
    (72.0, 680.0, 10.0, "Apples"), (200.0, 680.0, 10.0, "12"),
    (330.0, 680.0, 10.0, "1.20"),
    (72.0, 664.0, 10.0, "Pears"), (200.0, 664.0, 10.0, "7"),
    (72.0, 652.0, 10.0, "fresh"),
    (72.0, 632.0, 10.0, "Figs"), (200.0, 632.0, 10.0, "3"),
    (330.0, 632.0, 10.0, "2.50"),
  ]
  var content = ""
  for (x, y, size, t) in cells:
    content.add("BT /F1 " & $size & " Tf " & $x & " " & $y &
      " Td (" & t & ") Tj ET ")
  discard b.addPage(612.0, 792.0, b.addContentStream(content,
    flate = false), res)
  openDoc(b.buildPdf())

test "grid detects headers rows wraps and empty cells":
  var d = gridDoc()
  let page = d.sheetPage(0)
  check page.tables.len == 1
  check page.rows.len == 0
  let t = page.tables[0]
  check t.headers == @["Name", "Qty", "Price"]
  check t.rows == @[
    @["Apples", "12", "1.20"],
    @["Pears\nfresh", "7", ""],
    @["Figs", "3", "2.50"],
  ]
  check t.x == 72.0
  check t.w > 250.0

test "plain page has no tables":
  var d = sheetDoc()
  check d.sheetPage(0).tables.len == 0

test "real-world sheet":
  var d = openMappedDoc(bigPdf)
  let sheet = d.extractSheet("1.4")
  check sheet.version == "1.4"
  check sheet.pageCount == 5
  var rows = 0
  var kinds: seq[BlockKind] = @[]
  for p in sheet.pages:
    check p.width > 0.0
    rows += p.rows.len
    for r in p.rows:
      check r.text.len > 0
      if r.kind notin kinds:
        kinds.add(r.kind)
  check rows > 0
  check bkParagraph in kinds
  d.close()

test "real-world table groups into grid":
  var d = openMappedDoc(bigPdf)
  let sheet = d.extractSheet("1.4")
  let p1 = sheet.pages[1]
  check p1.tables.len == 1
  let t = p1.tables[0]
  check t.headers.len == 0
  check t.rows == @[
    @["1", "In eleifend velit vitae libero sollicitudin euismod.",
      "Lorem"],
    @["2", "Cras fringilla ipsum magna, in fringilla dui commodo\na.",
      "Ipsum"],
    @["3", "Aliquam erat volutpat.", "Lorem"],
    @["4", "Fusce vitae vestibulum velit.", "Lorem"],
    @["5", "Etiam vehicula luctus fermentum.", "Ipsum"],
  ]
  check abs(t.x - 59.6) < 0.01
  for r in p1.rows:
    check (r.text in @["a.", "Ipsum", "Lorem"]) == false
    check ("2 Cras fringilla" in r.text) == false
  check sheet.pages[0].tables.len == 0
  check sheet.pages[2].tables.len == 0
  d.close()
