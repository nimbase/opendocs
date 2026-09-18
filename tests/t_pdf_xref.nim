import std/strutils
import unittest
import ../src/opendocs/pdf
import ./pdf_support

test "single section document reads":
  let doc = readPdfBytes(buildSimplePdf(@[(w: 612.0, h: 792.0)]))
  check doc.version == "1.7"
  check doc.pageCount == 1
  check doc.pages[0].width == 612.0
  check doc.pages[0].height == 792.0
  check not doc.hasEncrypt

test "multi-page order and inheritance":
  let data = buildSimplePdf(@[(w: 100.0, h: 100.0), (w: 200.0, h: 50.0)])
  let doc = readPdfBytes(data)
  check doc.pageCount == 2
  check doc.pages[1].width == 200.0
  check doc.pages[1].height == 50.0

test "incremental update: newer section wins":
  # v1: one page 100x100. v2 (appended): catalog+pages replaced with
  # 200x200 page; both sections present, newest first via startxref.
  var data = buildSimplePdf(@[(w: 100.0, h: 100.0)])
  let oldXref = data.find("xref")
  var appendix = "%PDF-1.7\n"
  let base = data.len
  var offsets: seq[int] = @[]
  let objs = @["<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] >>"]
  for i, body in objs:
    offsets.add(base + appendix.len)
    appendix.add($(i + 1) & " 0 obj\n" & body & "\nendobj\n")
  let xrefPos = base + appendix.len
  appendix.add("xref\n0 4\n0000000000 65535 f \n")
  for off in offsets:
    var s = $off
    while s.len < 10:
      s = "0" & s
    appendix.add(s & " 00000 n \n")
  appendix.add("trailer\n<< /Size 4 /Root 1 0 R /Prev " & $oldXref &
    " >>\nstartxref\n" & $xrefPos & "\n%%EOF\n")
  data.add(appendix)
  let doc = readPdfBytes(data)
  check doc.pageCount == 1
  check doc.pages[0].width == 200.0
  check doc.pages[0].height == 200.0

test "non-pdf input rejected":
  expect(PdfError):
    discard readPdfBytes("hello, world")
  expect(PdfError):
    discard readPdfBytes("")

test "dangling encrypt reference fails":
  let data = assemblePdf(@["<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    pageObj(2, 10.0, 10.0)],
    extraTrailer = "/Encrypt 4 0 R") &
    "" # trailer references missing object; resolve names it
  var msg = ""
  try:
    discard readPdfBytes(data)
  except PdfError as e:
    msg = e.msg
  check "dangling reference" in msg

test "malformed xref stream names the missing piece":
  var data = "%PDF-1.7\n"
  let xoff = data.len
  data.add("5 0 obj\n<< /Type /XRef /Size 6 /Root 1 0 R /Length 0 >>\n" &
    "stream\nendstream\nendobj\n")
  data.add("startxref\n" & $xoff & "\n%%EOF\n")
  var msg = ""
  try:
    discard readPdfBytes(data)
  except PdfError as e:
    msg = e.msg
  check "xref stream missing /W" in msg

test "dangling reference rejected":
  let data = assemblePdf(@["<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [9 0 R] /Count 1 >>"])
  expect(PdfError):
    discard readPdfBytes(data)

test "page count limit enforced":
  let data = buildSimplePdf(@[(w: 1.0, h: 1.0), (w: 1.0, h: 1.0)])
  expect(PdfError):
    discard readPdfBytes(data, PdfLimits(maxPages: 1, maxScanBytes: 8192,
      maxObjects: 200000, maxWalkDepth: 32))

test "seq[byte] input works":
  let s = buildSimplePdf(@[(w: 50.0, h: 60.0)])
  var b = newSeq[byte](s.len)
  for i, c in s:
    b[i] = byte(c)
  check readPdfBytes(b).pages[0].width == 50.0
