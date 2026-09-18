## M9 merge/split: page transplant, xref streams, object streams.
import std/os
import std/strutils
import unittest
import ../src/opendocs/pdf
import ../src/opendocs/pdf/cos
import ../src/opendocs/pdf/docmodel
import ../src/opendocs/pdf/write
import pdf_support

proc helvResources(): CosObj =
  let f1 = CosObj(kind: coDict, keys: @["Type", "Subtype", "BaseFont"],
    vals: @[CosObj(kind: coName, name: "Font"),
      CosObj(kind: coName, name: "Type1"),
      CosObj(kind: coName, name: "Helvetica")])
  let fonts = CosObj(kind: coDict, keys: @["F1"], vals: @[f1])
  CosObj(kind: coDict, keys: @["Font"], vals: @[fonts])

proc textPdf(pages: seq[tuple[w, h: float, text: string]]): string =
  var b = newPdfBuilder()
  for p in pages:
    let cnum = b.addContentStream(
      "BT /F1 24 Tf 72 720 Td (" & p.text & ") Tj ET")
    discard b.addPage(p.w, p.h, cnum, helvResources())
  b.buildPdf()

proc runTexts(d: var PdfDoc, page: int): seq[string] =
  for r in d.extractText(page):
    result.add(r.text)

proc beBytes(v, width: int): string =
  result = newString(width)
  for i in 0 ..< width:
    result[width - 1 - i] = chr(v shr (8 * i) and 0xFF)

proc buildCompressedPdf(): string =
  ## Two pages whose dicts (4, 5) plus font (7) live in an /ObjStm
  ## (6); the xref table itself is an xref stream (9). No classic
  ## xref/trailer keywords anywhere.
  let c1 = "BT /F1 24 Tf 72 720 Td (Hello one) Tj ET"
  let c2 = "BT /F1 24 Tf 72 700 Td (Hello two) Tj ET"
  let page1 = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 300] " &
    "/Resources << /Font << /F1 7 0 R >> >> /Contents 3 0 R >>"
  let page2 = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 500] " &
    "/Resources << /Font << /F1 7 0 R >> >> /Contents 8 0 R >>"
  let font = "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
  let pairs = "4 0 5 " & $page1.len & " 7 " & $(page1.len + page2.len) &
    " "
  let stmRaw = pairs & page1 & page2 & font
  var objs = @[
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [4 0 R 5 0 R] /Count 2 >>",
    streamObj("", c1),
    "<< placeholder >>", # 4: replaced by the ObjStm below
    "<< placeholder >>", # 5: replaced by the ObjStm below
    streamObj("/Type /ObjStm /N 3 /First " & $pairs.len, stmRaw),
    "<< placeholder >>", # 7: replaced by the ObjStm below
    streamObj("", c2),
  ]
  result = "%PDF-1.7\n%\xE2\xE3\xCF\xD3\n"
  var offsets: seq[int] = @[]
  for i, body in objs:
    if i in [3, 4, 6]:
      offsets.add(-1) # compressed objects have no file offset
      continue
    offsets.add(result.len)
    result.add($(i + 1) & " 0 obj\n" & body & "\nendobj\n")
  let xrefOff = result.len
  var entries = ""
  entries.add("\x00\x00\x00\x00\x00\xFF\xFF") # 0: free
  for num in [1, 2, 3]:
    entries.add("\x01" & beBytes(offsets[num - 1], 4) & "\x00\x00")
  entries.add("\x02" & beBytes(6, 4) & beBytes(0, 2)) # 4 in ObjStm 6
  entries.add("\x02" & beBytes(6, 4) & beBytes(1, 2)) # 5 in ObjStm 6
  entries.add("\x01" & beBytes(offsets[5], 4) & "\x00\x00") # 6
  entries.add("\x02" & beBytes(6, 4) & beBytes(2, 2)) # 7 in ObjStm 6
  entries.add("\x01" & beBytes(offsets[7], 4) & "\x00\x00") # 8
  let self = "\x01" & beBytes(xrefOff, 4) & "\x00\x00" # 9: self
  let xdict = "<< /Type /XRef /Size 10 /Root 1 0 R /W [1 4 2] " &
    "/Length " & $(entries.len + self.len) & " >>"
  result.add("9 0 obj\n" & xdict & "\nstream\n" & entries & self &
    "\nendstream\nendobj\n")
  result.add("startxref\n" & $xrefOff & "\n%%EOF\n")

test "split keeps box and text":
  let src = textPdf(@[(w: 100.0, h: 200.0, text: "page one"),
    (w: 300.0, h: 400.0, text: "page two")])
  var donor = openDoc(src)
  var d = openDoc(extractPages(donor, @[1]))
  check d.pageCount() == 1
  let boxes = d.pageBoxes()
  check boxes.len == 1
  check boxes[0].width == 300.0
  check boxes[0].height == 400.0
  check runTexts(d, 0) == @["page two"]

test "merge concatenates donors in order":
  var a = openDoc(textPdf(@[(w: 100.0, h: 100.0, text: "Alpha")]))
  var b = openDoc(textPdf(@[(w: 200.0, h: 200.0, text: "Beta")]))
  var docs = @[a, b]
  var d = openDoc(mergePdfs(docs))
  check d.pageCount() == 2
  check runTexts(d, 0) == @["Alpha"]
  check runTexts(d, 1) == @["Beta"]
  let boxes = d.pageBoxes()
  check boxes[1].width == 200.0

test "extract reorders pages":
  let src = textPdf(@[(w: 100.0, h: 100.0, text: "first"),
    (w: 200.0, h: 200.0, text: "second")])
  var donor = openDoc(src)
  var d = openDoc(extractPages(donor, @[1, 0]))
  check d.pageCount() == 2
  check runTexts(d, 0) == @["second"]
  check runTexts(d, 1) == @["first"]

test "extract repeats a page with isolated copies":
  let src = textPdf(@[(w: 100.0, h: 100.0, text: "solo")])
  var donor = openDoc(src)
  var d = openDoc(extractPages(donor, @[0, 0]))
  check d.pageCount() == 2
  check runTexts(d, 0) == @["solo"]
  check runTexts(d, 1) == @["solo"]

test "xref stream with object streams opens":
  var d = openDoc(buildCompressedPdf())
  check d.pageCount() == 2
  let boxes = d.pageBoxes()
  check boxes[0].width == 200.0
  check boxes[0].height == 300.0
  check boxes[1].width == 400.0
  check boxes[1].height == 500.0
  check runTexts(d, 0).join(" ") == "Hello one"
  check runTexts(d, 1).join(" ") == "Hello two"

test "compressed page dicts transplant":
  var donor = openDoc(buildCompressedPdf())
  var d = openDoc(extractPages(donor, @[1]))
  check d.pageCount() == 1
  let boxes = d.pageBoxes()
  check boxes[0].width == 400.0
  check boxes[0].height == 500.0
  check runTexts(d, 0).join(" ") == "Hello two"

test "inherited MediaBox materializes on the copy":
  let pdf = assemblePdf(@[
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 " &
      "/MediaBox [0 0 111 222] >>",
    pageObj(2, 0.0, 0.0, omitBox = true),
  ])
  var donor = openDoc(pdf)
  var d = openDoc(extractPages(donor, @[0]))
  let boxes = d.pageBoxes()
  check boxes.len == 1
  check boxes[0].width == 111.0
  check boxes[0].height == 222.0

test "page index out of range fails loudly":
  let src = textPdf(@[(w: 100.0, h: 100.0, text: "only")])
  var donor = openDoc(src)
  expect PdfError:
    discard extractPages(donor, @[5])
  expect PdfError:
    discard extractPages(donor, @[-1])

test "empty selections fail loudly":
  let src = textPdf(@[(w: 100.0, h: 100.0, text: "only")])
  var donor = openDoc(src)
  expect PdfError:
    discard extractPages(donor, @[])
  var none: seq[PdfDoc] = @[]
  expect PdfError:
    discard mergePdfs(none)

test "encrypted donor rejected":
  var d = openDoc(readFile("tests" / "data" / "pdf" / "m4_rc4.pdf"),
    defaultPdfLimits(), "user123")
  expect PdfError:
    discard extractPages(d, @[0])
