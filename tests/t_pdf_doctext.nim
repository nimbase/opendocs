## Document text: lines, blocks, plain text, exact search.
import std/os
import std/strutils
import unittest
import ../src/opendocs/pdf
import ../src/opendocs/pdf/cos
import ../src/opendocs/pdf/write
import ../src/opendocs/pdf/doctext

const bigPdf = "tests" / "data" / "pdf" / "file-example_PDF_500_kB.pdf"

proc textResources(): CosObj =
  let f1 = CosObj(kind: coDict, keys: @["Type", "Subtype", "BaseFont"],
    vals: @[CosObj(kind: coName, name: "Font"),
      CosObj(kind: coName, name: "Type1"),
      CosObj(kind: coName, name: "Helvetica")])
  CosObj(kind: coDict, keys: @["Font"],
    vals: @[CosObj(kind: coDict, keys: @["F1"], vals: @[f1])])

proc twoPageDoc(): PdfDoc =
  var b = newPdfBuilder()
  let c0 = b.addContentStream("BT /F1 12 Tf 72 720 Td (Alpha) Tj " &
    "0 -14 Td (Beta) Tj 0 -60 Td (Gamma ha ha) Tj ET", flate = false)
  discard b.addPage(612.0, 792.0, c0, textResources())
  let c1 = b.addContentStream(
    "BT /F1 12 Tf 72 720 Td [(Ke) -80 (rn)] TJ ET", flate = false)
  discard b.addPage(612.0, 792.0, c1, textResources())
  openDoc(b.buildPdf())

test "model shape":
  var d = twoPageDoc()
  let doc = d.extractDocumentText("1.7")
  check doc.version == "1.7"
  check doc.pageCount == 2
  let p0 = doc.pages[0]
  check p0.width == 612.0
  check p0.height == 792.0
  check p0.runs.len == 3
  check p0.lines.len == 3
  check p0.blocks.len == 2

test "lines join and blocks split":
  var d = twoPageDoc()
  let p0 = d.pageText(0)
  check p0.lines[0].text == "Alpha"
  check p0.lines[1].text == "Beta"
  check p0.blocks[0].text == "Alpha\nBeta"
  check p0.blocks[1].text == "Gamma ha ha"
  check p0.text == "Alpha\nBeta\n\nGamma ha ha"
  check p0.blocks[0].x == 72.0
  check p0.blocks[0].h == 14.0

test "kerned TJ joins without a space":
  var d = twoPageDoc()
  let p1 = d.pageText(1)
  check p1.runs.len == 2
  check p1.lines.len == 1
  check p1.lines[0].text == "Kern"

test "vertical runs group into column lines":
  var d = openDoc(readFile("tests" / "data" / "pdf" / "m8_cjk.pdf"))
  let p = d.pageText(1)
  check p.runs.len == 2
  check p.lines.len == 2
  check p.lines[0].text == "日"
  check p.lines[1].text == "あ"
  check p.blocks.len == 1
  check p.blocks[0].text == "日\nあ"

test "empty page is empty":
  var b = newPdfBuilder()
  discard b.addPage(100.0, 200.0,
    b.addContentStream("", flate = false),
    CosObj(kind: coDict, keys: @[], vals: @[]))
  var d = openDoc(b.buildPdf())
  let p = d.pageText(0)
  check p.runs.len == 0
  check p.lines.len == 0
  check p.blocks.len == 0
  check p.text == ""

test "document text joins pages with form feed":
  var d = twoPageDoc()
  let t = d.extractDocumentText().text()
  check t == "Alpha\nBeta\n\nGamma ha ha\fKern"

test "tracked glyphs collapse, word gaps survive":
  var b = newPdfBuilder()
  let res = textResources()
  let tracked = "BT /F1 12 Tf 72 720 Td (T) Tj (r) Tj (a) Tj (c) Tj " &
    "(k) Tj (e) Tj (d) Tj ET"
  let spaced = "BT /F1 12 Tf 72 700 Td [(wo) -250 (rd)] TJ ET"
  let c = b.addContentStream(tracked & " " & spaced, flate = false)
  discard b.addPage(612.0, 792.0, c, res)
  var d = openDoc(b.buildPdf())
  let p = d.pageText(0)
  check p.lines.len == 2
  check p.lines[0].text == "Tracked"
  check p.lines[1].text == "wo rd"
  check p.runs[0].w > 0.0
  check p.lines[1].starts == @[0, 3]

test "exact search hits":
  var d = twoPageDoc()
  let doc = d.extractDocumentText()
  let hits = doc.searchText("Beta")
  check hits.len == 1
  check hits[0].page == 0
  check hits[0].line == 1
  check hits[0].col == 0
  check hits[0].x == 72.0
  check hits[0].fontName == "F1"
  check hits[0].excerpt == "Beta"

test "search case policy and empty query":
  var d = twoPageDoc()
  let doc = d.extractDocumentText()
  check doc.searchText("alpha").len == 1
  check doc.searchText("alpha", caseSensitive = true).len == 0
  check doc.searchText("").len == 0
  check doc.searchText("zzz").len == 0

test "search reports every occurrence":
  var d = twoPageDoc()
  let hits = d.extractDocumentText().searchText("ha")
  check hits.len == 3
  check hits[0].col == 3 # "Alp[ha]"
  check hits[1].col == 6
  check hits[2].col == 9

test "excerpt is capped rune-safe":
  var b = newPdfBuilder()
  let long = "w".repeat(200)
  let c = b.addContentStream("BT /F1 12 Tf 72 720 Td (" & long &
    ") Tj ET", flate = false)
  discard b.addPage(612.0, 792.0, c, textResources())
  var d = openDoc(b.buildPdf())
  let hits = d.extractDocumentText().searchText("w")
  check hits.len == 200
  check hits[0].excerpt.endsWith("…")

test "real-world 500kB document":
  # The file carries stale /Count 7 and /Count 4 objects, but its one
  # trailer roots a 5-leaf page tree, which is what a reader must see.
  var d = openMappedDoc(bigPdf)
  let doc = d.extractDocumentText("1.4")
  check doc.pageCount == 5
  var runs = 0
  for p in doc.pages:
    check p.width > 0.0
    check p.height > 0.0
    runs += p.runs.len
  check runs > 100
  check doc.text().len > 1000
  # Self-seeking: the first long word must find itself.
  var probe = ""
  for r in doc.pages[0].runs:
    for w in r.text.split({' ', '\x0A', '\x0D', '\x09'}):
      if w.len > 4:
        probe = w
        break
    if probe.len > 0:
      break
  check probe.len > 4
  let hits = doc.searchText(probe)
  check hits.len > 0
  check hits[0].page == 0
  d.close()
