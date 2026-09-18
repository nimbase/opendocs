## M6 writer: serializer, builder, rewrite, incremental update.
import std/os
import std/strutils
import std/tables
import unittest
import ../src/opendocs/pdf
import ../src/opendocs/pdf/cos
import ../src/opendocs/pdf/lexer
import ../src/opendocs/pdf/docmodel
import ../src/opendocs/pdf/write
import pdf_support

proc parseOne(s: string): CosObj =
  var lx = initLexer(s)
  lx.parseCosValue()

proc helvResources(): CosObj =
  let f1 = CosObj(kind: coDict, keys: @["Type", "Subtype", "BaseFont"],
    vals: @[CosObj(kind: coName, name: "Font"),
      CosObj(kind: coName, name: "Type1"),
      CosObj(kind: coName, name: "Helvetica")])
  let fonts = CosObj(kind: coDict, keys: @["F1"], vals: @[f1])
  CosObj(kind: coDict, keys: @["Font"], vals: @[fonts])

proc helloPdf(text: string): string =
  var b = newPdfBuilder()
  let cnum = b.addContentStream(
    "BT /F1 24 Tf 72 720 Td (" & text & ") Tj ET")
  discard b.addPage(612.0, 792.0, cnum, helvResources())
  b.buildPdf()

proc runTexts(d: var PdfDoc, page: int): seq[string] =
  for r in d.extractText(page):
    result.add(r.text)

test "writeCos scalars round-trip":
  let vals = @[
    CosObj(kind: coNull),
    CosObj(kind: coBool, bval: true),
    CosObj(kind: coBool, bval: false),
    CosObj(kind: coInt, ival: -42),
    CosObj(kind: coFloat, fval: 1.5),
    CosObj(kind: coFloat, fval: 100.0),
    CosObj(kind: coName, name: "A B/C#D"),
    CosObj(kind: coStr, sval: "a(b)c\\d\x0A\x01\xFF"),
    CosObj(kind: coRef, refNum: 3, refGen: 1),
    CosObj(kind: coArray, items: @[CosObj(kind: coInt, ival: 1),
      CosObj(kind: coName, name: "Hi")]),
    CosObj(kind: coDict, keys: @["Type", "N"],
      vals: @[CosObj(kind: coName, name: "Example"),
        CosObj(kind: coInt, ival: 7)]),
  ]
  for v in vals:
    check writeCos(parseOne(writeCos(v))) == writeCos(v)

test "writeCos tiny float stays a plain decimal":
  let w = writeCos(CosObj(kind: coFloat, fval: 0.0000001))
  check 'e' notin w and 'E' notin w
  check parseOne(w).fval == 0.0000001

test "writeCos stream round-trips raw bytes":
  let s = CosObj(kind: coStream,
    streamDict: @["Length", "Filter"],
    streamVals: @[CosObj(kind: coInt, ival: 4),
      CosObj(kind: coName, name: "FlateDecode")],
    raw: "a\x00b\xFF")
  let (_, _, back) = parseIndirect(
    fromString("7 0 obj\n" & writeCos(s) & "\nendobj"), 0)
  check back.kind == coStream
  check back.raw == "a\x00b\xFF"
  check back.dictGet("Filter").name == "FlateDecode"

test "builder blank pages":
  var b = newPdfBuilder()
  let res = CosObj(kind: coDict, keys: @[], vals: @[])
  for (w, h) in [(100.0, 200.0), (300.0, 400.0), (500.0, 600.0)]:
    discard b.addPage(w, h, b.addContentStream("", flate = false), res)
  let path = getTempDir() / "opengraphics_built.pdf"
  writeFile(path, b.buildPdf())
  let doc = openPdf(path)
  check doc.pageCount == 3
  var d = openDoc(readFile(path))
  let boxes = d.pageBoxes()
  check boxes[0].width == 100.0
  check boxes[2].height == 600.0
  removeFile(path)

test "builder text extracts":
  var d = openDoc(helloPdf("Hello writer"))
  check d.pageCount() == 1
  check runTexts(d, 0) == @["Hello writer"]

test "rewrite assembled pdf preserves boxes":
  let pdf = buildSimplePdf(@[(w: 10.0, h: 20.0), (w: 30.0, h: 40.0)])
  var d = openDoc(rewritePdf(pdf))
  let boxes = d.pageBoxes()
  check boxes.len == 2
  check boxes[1].width == 30.0
  check boxes[1].height == 40.0

test "rewrite keeps text and images":
  var t = openDoc(rewritePdf(readFile("tests" / "data" / "pdf" /
      "m3b_text.pdf")))
  var t0 = openDoc(readFile("tests" / "data" / "pdf" / "m3b_text.pdf"))
  check runTexts(t, 0).join(" ") == runTexts(t0, 0).join(" ")
  var a = openMappedDoc("tests" / "data" / "pdf" / "m5_images.pdf")
  var b = openDoc(rewritePdf(readFile("tests" / "data" / "pdf" /
      "m5_images.pdf")))
  var na: seq[string] = @[]
  var nb: seq[string] = @[]
  for im in a.pageImages(0):
    na.add(im.name)
  for im in b.pageImages(0):
    nb.add(im.name)
  check nb == na
  check nb.len == 7
  a.close()

test "rewrite with reflate normalizes filters":
  let pdf = helloPdf("reflate me")
  var d = openDoc(rewritePdf(pdf, reflate = true))
  check runTexts(d, 0) == @["reflate me"]
  let contents = d.resolve(d.resolve(CosObj(kind: coRef, refNum: 2,
    refGen: 0)).dictGet("Kids").items[0]).dictGet("Contents")
  let s = d.resolve(contents)
  check s.kind == coStream
  check s.dictGet("Filter").name == "FlateDecode"

test "incremental update adds a page":
  let base = helloPdf("page one")
  var u = beginUpdate(base)
  let cnum = u.addObject(writeCos(CosObj(kind: coStream,
    streamDict: @["Length"],
    streamVals: @[CosObj(kind: coInt,
      ival: "BT /F1 24 Tf 72 700 Td (page two) Tj ET".len)],
    raw: "BT /F1 24 Tf 72 700 Td (page two) Tj ET")))
  let page = CosObj(kind: coDict,
    keys: @["Type", "Parent", "MediaBox", "Resources", "Contents"],
    vals: @[CosObj(kind: coName, name: "Page"),
      CosObj(kind: coRef, refNum: 2, refGen: 0),
      CosObj(kind: coArray, items: @[CosObj(kind: coInt, ival: 0),
        CosObj(kind: coInt, ival: 0),
        CosObj(kind: coFloat, fval: 612.0),
        CosObj(kind: coFloat, fval: 792.0)]),
      helvResources(),
      CosObj(kind: coRef, refNum: cnum, refGen: 0)])
  let pnum = u.addObject(writeCos(page))
  var bd = openDoc(base)
  let old = bd.resolve(bd.catalog().dictGet("Pages"))
  var keys: seq[string] = @[]
  var vals: seq[CosObj] = @[]
  for i, k in old.keys:
    if k == "Kids":
      keys.add(k)
      vals.add(CosObj(kind: coArray,
        items: old.vals[i].items &
          @[CosObj(kind: coRef, refNum: pnum, refGen: 0)]))
    elif k == "Count":
      keys.add(k)
      vals.add(CosObj(kind: coInt, ival: old.vals[i].ival + 1))
    else:
      keys.add(k)
      vals.add(old.vals[i])
  let gen = u.updateObject(2, writeCos(CosObj(kind: coDict, keys: keys,
    vals: vals)))
  # Revisions keep the base generation so pre-existing references
  # keep resolving in strict readers (newest entry wins via /Prev).
  check gen == 0
  let updated = u.finishUpdate()
  check "Prev" in updated
  var d = openDoc(updated)
  check d.xref.entries[2].gen == 0
  check d.pageCount() == 2
  check runTexts(d, 0) == @["page one"]
  check runTexts(d, 1) == @["page two"]

test "writer rejects encrypted input":
  let locked = readFile("tests" / "data" / "pdf" / "m4_rc4.pdf")
  expect(PdfError):
    discard rewritePdf(locked)
  expect(PdfError):
    discard beginUpdate(locked)

test "empty update fails":
  expect(PdfError):
    discard finishUpdate(beginUpdate(helloPdf("solo")))
