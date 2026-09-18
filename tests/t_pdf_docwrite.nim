## High-level writer: pages, fonts, text flow, images, metadata.
##
## Core round-trips use the vendored CJK micro font (self-contained);
## the DejaVu sentence case runs when the sibling harfbuzz checkout is
## present. Image fixtures are generated with libvips at test time.
import std/os
import std/strutils
import std/tables
import unittest
import libvips/api
import ../src/opendocs/pdf
import ../src/opendocs/pdf/fontembed

const
  Micro = "tests/data/fonts/cjk-cff-micro.otf"
  DejaVuPath = "../harfbuzz/tests/data/DejaVuSans.ttf"

proc microPdf(): Pdf =
  newPdf(readFile(Micro), "NotoSansJP")

proc runsText(pdf: string): string =
  var d = openDoc(pdf)
  for r in d.extractText(0):
    result.add(r.text)

test "pageDims match ISO and US sizes":
  check pageDims(psA4) == (w: 595.28, h: 841.89)
  check pageDims(psLetter) == (w: 612.0, h: 792.0)
  check pageDims(psA5) == (w: 419.53, h: 595.28)
  check pageDims(psCustom, 100.0, 200.0) == (w: 100.0, h: 200.0)
  expect(PdfError):
    discard pageDims(psCustom, 0.0, 200.0)

test "newPdf defaults to A4":
  var doc = microPdf()
  defer: doc.close()
  check doc.pageCount() == 0
  var d = openDoc(doc.build())
  let boxes = d.pageBoxes()
  check boxes.len == 1
  check boxes[0].width == 595.28
  check boxes[0].height == 841.89

test "paragraph round-trips through our reader":
  # The micro font has no space glyph, so micro-font text is spaceless;
  # spaced sentences run under DejaVu below.
  var doc = microPdf()
  defer: doc.close()
  doc.paragraph("AXAXA")
  check runsText(doc.build()) == "AXAXA"

test "heading and textAt round-trip":
  var doc = microPdf()
  defer: doc.close()
  doc.heading("AX")
  doc.textAt("XA", 72.0, 72.0)
  let t = runsText(doc.build())
  check "AX" in t
  check "XA" in t

test "loadFont and setFont switch typefaces":
  var doc = microPdf()
  defer: doc.close()
  check doc.fontNames() == @["body"]
  doc.loadFont("jp2", Micro)
  check doc.fontNames() == @["body", "jp2"]
  doc.setFont("jp2", 14.0)
  doc.paragraph("AXXA")
  check runsText(doc.build()) == "AXXA"
  doc.loadFont("jp2", Micro)
  check doc.fontNames() == @["body", "jp2"]
  expect(PdfError):
    doc.setFont("nope", 12.0)
  expect(PdfError):
    doc.loadFont("bad name!", Micro)
  expect(PdfError):
    doc.setFont("body", 0.0)

test "long paragraph auto-paginates":
  var doc = microPdf()
  defer: doc.close()
  doc.paragraph(strutils.repeat("AX\n", 400))
  var d = openDoc(doc.build())
  check d.pageCount() > 1
  check d.pageCount() == doc.pageCount()

test "build is deterministic":
  var doc = microPdf()
  defer: doc.close()
  doc.heading("AX")
  doc.paragraph("XAAX")
  check doc.build() == doc.build()

test "title and author land in Info":
  var doc = microPdf()
  defer: doc.close()
  doc.setTitle("My Title")
  doc.setAuthor("Jane Doe")
  doc.paragraph("AX")
  let pdf = doc.build()
  check "/Info" in pdf
  check "(My Title)" in pdf
  check "(Jane Doe)" in pdf

test "builtin default needs no font file":
  var doc = newPdf()
  defer: doc.close()
  check doc.fontNames() == @["body"]
  doc.heading("Hello writer")
  doc.paragraph("It wraps on AFM widths, breaks pages on its own, " &
    "and a writer's apostrophe works too.")
  doc.textAt("absolute", 72.0, 72.0)
  var d = openDoc(doc.build())
  check d.pageCount() == 1
  var t = ""
  for r in d.extractText(0):
    t.add(r.text)
  check "Hello writer" in t
  check "apostrophe works too." in t
  check "absolute" in t

test "builtin default paginates and stays deterministic":
  var doc = newPdf()
  defer: doc.close()
  doc.paragraph(strutils.repeat("Hello\n", 400))
  var d = openDoc(doc.build())
  check d.pageCount() > 1
  check doc.build() == doc.build()

test "AFM widths match Adobe Helvetica":
  check helveticaWidths[32] == 278
  check helveticaWidths[65] == 722
  check helveticaWidths[97] == 556
  check helveticaWidths[109] == 833
  check helveticaWidths[105] == 222
  check helveticaWidths[39] == 222
  check helveticaWidths[138] == 667
  check helveticaWidths[137] == 1000
  check helveticaWidths[150] == 556
  check helveticaWidths[128] == 0
  check builtinMeasure(" ", 12.0) == 278.0 / 1000.0 * 12.0
  check builtinMeasure("A", 12.0) == 722.0 / 1000.0 * 12.0
  check builtinMeasure("ii", 12.0) < builtinMeasure("mm", 12.0)

test "builtin rejects non-WinAnsi loudly":
  var doc = newPdf()
  defer: doc.close()
  expect(PdfError):
    doc.paragraph("日本語")
  expect(PdfError):
    doc.paragraph("Price €5")
  expect(PdfError):
    doc.textAt("€", 72.0, 72.0)

test "loadFont upgrades the default body":
  var doc = newPdf()
  defer: doc.close()
  doc.loadFont("body", Micro)
  check doc.fontNames() == @["body"]
  doc.paragraph("AX")
  check runsText(doc.build()) == "AX"

test "builtin body mixes with an embedded heading":
  if not fileExists(DejaVuPath):
    echo "no sibling harfbuzz checkout; mixed fonts skipped"
  else:
    var doc = newPdf()
    defer: doc.close()
    doc.loadFont("head", DejaVuPath)
    doc.setFont("head", 18.0)
    doc.heading("Hello writer")
    doc.setFont("body", 12.0)
    doc.paragraph("Back to builtin Helvetica.")
    var d = openDoc(doc.build())
    var t = ""
    for p in 0 ..< d.pageCount():
      for r in d.extractText(p):
        t.add(r.text)
    check "Hello writer" in t
    check "Back to builtin Helvetica." in t

test "missing font fails loudly":
  expect(PdfError):
    discard newPdf("/nonexistent/font.ttf")
  expect(PdfError):
    discard newPdf("", "Empty")

test "images embed and round-trip":
  let jpg = getTempDir() / "opengraphics_doc_jpg.jpg"
  let png = getTempDir() / "opengraphics_doc_png.png"
  black(64, 48, 3).saveJPEG(jpg, 85)
  black(64, 48, 3).savePNG(png)
  defer:
    removeFile(jpg)
    removeFile(png)
  var doc = microPdf()
  defer: doc.close()
  doc.paragraph("AX")
  # Small placed widths keep all three images on page 0.
  doc.imageFromFile(jpg, ImageOpts(widthPt: 100.0))
  doc.imageFromFile(png, ImageOpts(widthPt: 100.0))
  doc.imageFromFile(jpg, ImageOpts(compress: true, jpegQuality: 50,
    maxWidthPx: 32, widthPt: 100.0))
  let pdf = doc.build()
  check "DCTDecode" in pdf
  var d = openDoc(pdf)
  let imgs = d.pageImages(0)
  check imgs.len == 3
  check imgs[0].width == 64
  check imgs[1].width == 64
  check imgs[2].width == 32
  var texts: seq[string] = @[]
  for r in d.extractText(0):
    texts.add(r.text)
  check texts.join("") == "AX"

test "save writes a readable file":
  var doc = microPdf()
  defer: doc.close()
  doc.setTitle("t")
  doc.heading("AX")
  doc.newPage()
  doc.paragraph("XA")
  let path = getTempDir() / "opengraphics_doc.pdf"
  defer: removeFile(path)
  doc.save(path)
  check openPdf(path).pageCount == 2

test "dejaVu sentence round-trips":
  if not fileExists(DejaVuPath):
    echo "no sibling harfbuzz checkout; dejavu sentence skipped"
  else:
    var doc = newPdf(DejaVuPath)
    defer: doc.close()
    doc.heading("Hello writer")
    doc.paragraph("The quick brown fox jumps over the lazy dog.")
    doc.textAt("absolute", 72.0, 72.0)
    var d = openDoc(doc.build())
    var t = ""
    for p in 0 ..< d.pageCount():
      for r in d.extractText(p):
        t.add(r.text)
    check "Hello writer" in t
    check "quick brown fox" in t
    check "absolute" in t
