## Synthetic PDF builder for tests (stdlib only).
##
## Assembles valid PDFs from object bodies with tracked offsets,
## classic xref tables, optional /Prev chains, trailer, startxref,
## %%EOF. Object 1 is always the catalog.

import std/strutils

proc assemblePdf*(objs: seq[string], prevChain: seq[int] = @[],
    extraTrailer = ""): string =
  ## prevChain lists byte offsets of older xref sections, oldest last;
  ## the newest trailer gets /Prev pointing at prevChain[0], each older
  ## section would need its own trailer (only newest carries /Prev here,
  ## which is enough for merge-precedence tests via manual assembly).
  result = "%PDF-1.7\n%\xE2\xE3\xCF\xD3\n"
  var offsets: seq[int] = @[]
  for i, body in objs:
    offsets.add(result.len)
    result.add($(i + 1) & " 0 obj\n")
    result.add(body)
    result.add("\nendobj\n")
  let xrefPos = result.len
  result.add("xref\n0 " & $(objs.len + 1) & "\n")
  result.add("0000000000 65535 f \n")
  for off in offsets:
    var s = $off
    while s.len < 10:
      s = "0" & s
    result.add(s & " 00000 n \n")
  var trailer = "<< /Size " & $(objs.len + 1) & " /Root 1 0 R"
  if prevChain.len > 0:
    trailer.add(" /Prev " & $prevChain[0])
  if extraTrailer.len > 0:
    trailer.add(" " & extraTrailer)
  trailer.add(" >>")
  result.add("trailer\n" & trailer & "\n")
  result.add("startxref\n" & $xrefPos & "\n%%EOF\n")

proc pageObj*(parent: int, w, h: float, omitBox = false): string =
  result = "<< /Type /Page /Parent " & $parent & " 0 R"
  if not omitBox:
    result.add(" /MediaBox [0 0 " & $w & " " & $h & "]")
  result.add(" >>")

proc buildSimplePdf*(boxes: seq[tuple[w, h: float]],
    pagesExtra = ""): string =
  var kids = ""
  for i in 0 ..< boxes.len:
    if kids.len > 0:
      kids.add(" ")
    kids.add($(i + 3) & " 0 R")
  var objs = @["<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [" & kids & "] /Count " & $boxes.len &
    pagesExtra & " >>"]
  for b in boxes:
    objs.add(pageObj(2, b.w, b.h))
  assemblePdf(objs)

proc streamObj*(dict, payload: string): string =
  "<< " & dict & " /Length " & $payload.len & " >>\nstream\n" &
    payload & "\nendstream"
