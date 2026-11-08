## M13 tests: parser recovery (lenient chain + brute-force sweep).
##
## Strict files parse exactly as before (recovered=false). Corruption
## that used to be total loss now degrades: bad entries skipped, broken
## older sections stop the /Prev chain with a note, and xref-less files
## rebuild from an object sweep plus the last parseable trailer.

import std/strutils
import std/tables
import unittest
import ../src/opendocs/pdf
import ../src/opendocs/pdf/docmodel
import ../src/opendocs/pdf/filters
import ../src/opendocs/pdf/gstate
import ../src/opendocs/pdf/cmap
import ./pdf_support

test "strict files are not marked recovered":
  let doc = readPdfBytes(buildSimplePdf(@[(w: 100.0, h: 100.0)]))
  check not doc.recovered
  check doc.recoveryNotes.len == 0
  var d = openDoc(buildSimplePdf(@[(w: 100.0, h: 100.0)]))
  check not d.recovered()

test "bad entry skipped when unreferenced":
  var data = assemblePdf(@["<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    pageObj(2, 10.0, 10.0),
    "<< /Unused true >>"])
  # Mangle object 4's entry flag: strict fails, lenient skips it.
  let xpos = data.find("xref")
  check xpos >= 0
  var npos = -1
  var seen = 0
  var i = xpos
  while true:
    i = data.find(" 00000 n \n", i)
    if i < 0: break
    inc seen
    if seen == 4:
      npos = i
      break
    inc i
  check npos >= 0
  data[npos + 7] = 'x' # entry flag 'n' -> 'x'
  var strictFailed = false
  try:
    discard parseXRefStrict(fromString(data), defaultPdfLimits())
  except PdfError:
    strictFailed = true
  check strictFailed
  let doc = readPdfBytes(data)
  check doc.recovered
  check doc.pageCount == 1
  check doc.pages[0].width == 10.0

test "broken prev stops the chain with a note":
  var data = buildSimplePdf(@[(w: 100.0, h: 100.0)])
  let xpos = data.find("xref")
  # Append a newer self-contained revision with a garbage /Prev.
  let base = data.len
  var appendix = "%PDF-1.7\n"
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
  appendix.add("trailer\n<< /Size 4 /Root 1 0 R /Prev 99999999 >>\n" &
    "startxref\n" & $xrefPos & "\n%%EOF\n")
  data.add(appendix)
  check xpos >= 0
  var strictFailed = false
  try:
    discard parseXRefStrict(fromString(data), defaultPdfLimits())
  except PdfError:
    strictFailed = true
  check strictFailed
  let doc = readPdfBytes(data)
  check doc.recovered
  check doc.pageCount == 1
  check doc.pages[0].width == 200.0
  var noted = false
  for n in doc.recoveryNotes:
    if "Prev" in n: noted = true
  check noted

test "trailing junk past the tail scan still opens":
  var data = buildSimplePdf(@[(w: 50.0, h: 60.0)])
  data.add("\n% trailing junk " & repeat('x', 9000))
  let doc = readPdfBytes(data)
  check doc.pageCount == 1
  check doc.pages[0].width == 50.0

test "xref-less file rebuilds from sweep plus trailer":
  var data = "%PDF-1.7\n%\xE2\xE3\xCF\xD3\n"
  var offsets: seq[int] = @[]
  let objs = @["<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 33 44] >>"]
  for i, body in objs:
    offsets.add(data.len)
    data.add($(i + 1) & " 0 obj\n" & body & "\nendobj\n")
  data.add("trailer\n<< /Size 4 /Root 1 0 R >>\n%%EOF\n")
  check offsets.len == 3
  let doc = readPdfBytes(data)
  check doc.recovered
  check doc.pageCount == 1
  check doc.pages[0].width == 33.0
  check doc.recoveryNotes.len > 0

test "garbage without objects or trailer still fails":
  expect PdfError:
    discard readPdfBytes("%PDF-1.7\n1 2 hello\n%%EOF\n")

test "page tree cycle fails loudly":
  let data = assemblePdf(@["<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [2 0 R] /Count 1 >>"])
  expect PdfError:
    discard readPdfBytes(data)

test "stray q is ignored":
  var gs = initGState()
  gs.applyOp(ContentOp(name: "Q", operands: @[]))
  gs.applyOp(ContentOp(name: "q", operands: @[]))
  gs.applyOp(ContentOp(name: "Q", operands: @[]))

test "cmap bad hex skips the token, keeps the map":
  let cmapData = """/CIDInit /ProcSet findresource begin
12 dict begin
begincmap
1 begincodespacerange
<00> <FF>
endcodespacerange
3 beginbfchar
<41> <0041>
<ZZ> <0042>
<43> <0043>
endbfchar
endcmap
"""
  let m = parseCMap(cmapData)
  check m.entries.getOrDefault(0x41, "") == "A"
  check m.entries.getOrDefault(0x43, "") == "C"
