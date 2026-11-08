## M15 fixture generator (run manually, not a test).
##
## Writes synthetic PDFs under tests/data/pdf/ for metadata, outlines,
## page labels, annotations and structure-tree readers. Fixtures are
## checked in so tests stay hermetic; rerun after any reader change:
##   clue build tests/gen_pdf_readmeta.nim --out:/tmp/genreadmeta && /tmp/genreadmeta
##
## Origin: synthetic, generated locally by this script. Expected values
## were verified against pdfcraft behavior notes (name-tree last-wins,
## outline openness, label styles) and frozen into tests/t_pdf_meta.nim,
## tests/t_pdf_outline.nim, tests/t_pdf_labels.nim,
## tests/t_pdf_annot.nim and tests/t_pdf_struct.nim.

import std/os
import ./pdf_support
import ../src/opendocs/pdf

const OutDir = "tests/data/pdf"

const XmpPacket = """<?xpacket begin="\uFEFF" id="W5M0MpCehiHzreSzNTczkc9d"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/">
 <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
  <rdf:Description rdf:about=""
    xmlns:dc="http://purl.org/dc/elements/1.1/"
    xmlns:xmp="http://ns.adobe.com/xap/1.0/">
   <dc:title><rdf:Alt>
    <rdf:li xml:lang="x-default">Full Title &amp; More</rdf:li>
    <rdf:li xml:lang="de">Voller Titel</rdf:li>
   </rdf:Alt></dc:title>
   <dc:creator><rdf:Seq>
    <rdf:li>Ada Author</rdf:li>
    <rdf:li>Co Author</rdf:li>
   </rdf:Seq></dc:creator>
   <xmp:CreateDate>2026-03-04T05:06:07Z</xmp:CreateDate>
  </rdf:Description>
 </rdf:RDF>
</x:xmpmeta>
<?xpacket end="w"?>"""

proc writeInfoFull() =
  let objs = @[
    "<< /Type /Catalog /Pages 2 0 R /Metadata 6 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
    streamObj("", ""),
    "<< /Title (Full Title) /Author (Ada Author) /Subject (A Subject) " &
      "/Keywords (kw1, kw2) /Creator (Tool 1.0) /Producer (Prod) " &
      "/CreationDate (D:20260304050607+02'00') /ModDate (D:1998) " &
      "/Trapped /False >>",
    streamObj("", XmpPacket),
  ]
  writeFile(OutDir / "info_full.pdf",
    assemblePdf(objs, extraTrailer = "/Info 5 0 R"))
  let doc = readPdfBytes(readFile(OutDir / "info_full.pdf"))
  doAssert doc.info.title == "Full Title"
  doAssert doc.info.xmpTitle == "Full Title & More"
  doAssert doc.info.xmpCreator == "Ada Author"

proc writeInfoDates() =
  let objs = @[
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
    streamObj("", ""),
    "<< /Title (T) /CreationDate (not a date) " &
      "/ModDate (D:2026-13-40) >>",
  ]
  writeFile(OutDir / "info_dates.pdf",
    assemblePdf(objs, extraTrailer = "/Info 5 0 R"))
  let doc = readPdfBytes(readFile(OutDir / "info_dates.pdf"))
  doAssert not doc.info.created.ok
  doAssert not doc.info.modified.ok
  doAssert doc.info.creationDate == "not a date"

proc writeOutlines() =
  let objs = @[
    # 1 catalog, 2 pages, 3-5 pages, 6-8 (unused content), 9 outlines root,
    # 10 names, 11 old dests, 12-16 top items, 17 name tree, 18-19 kids, 20 F
    "<< /Type /Catalog /Pages 2 0 R /Outlines 9 0 R " &
      "/Names 10 0 R /Dests 11 0 R >>",
    "<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
    streamObj("", ""),
    streamObj("", ""),
    streamObj("", ""),
    "<< /First 12 0 R /Last 20 0 R /Count 6 >>",
    "<< /Dests 17 0 R >>",
    "<< /oldsec [5 0 R /FitH 700] >>",
    "<< /Title (Chapter 1) /Parent 9 0 R /Next 13 0 R " &
      "/Dest [3 0 R /Fit] /C [0 0 1] >>",
    "<< /Title (Chapter 2) /Parent 9 0 R /Prev 12 0 R /Next 14 0 R " &
      "/First 18 0 R /Last 19 0 R /Count -2 >>",
    "<< /Title (Remote) /Parent 9 0 R /Prev 13 0 R /Next 15 0 R " &
      "/A << /S /GoToR /F (oldspec.pdf) >> >>",
    "<< /Title (Broken) /Parent 9 0 R /Prev 14 0 R /Next 16 0 R " &
      "/Dest (missing) >>",
    "<< /Title (Plain) /Parent 9 0 R /Prev 15 0 R /Next 20 0 R >>",
    "<< /Names [(sec21) [4 0 R /XYZ 10 20 2]] >>",
    "<< /Title (Section 2.1) /Parent 13 0 R /Next 19 0 R " &
      "/Dest (sec21) >>",
    "<< /Title (Web) /Parent 13 0 R /Prev 18 0 R " &
      "/A << /S /URI /URI (https://example.com/x?q=1) >> >>",
    "<< /Title (Old) /Parent 9 0 R /Prev 16 0 R /Dest /oldsec >>",
  ]
  writeFile(OutDir / "outlines.pdf", assemblePdf(objs))
  var d = openDoc(readFile(OutDir / "outlines.pdf"))
  doAssert d.docOutlines().len == 6
  doAssert d.docOutlines()[1].children.len == 2

proc writePageLabels() =
  var kids = ""
  for i in 3 ..< 11:
    if kids.len > 0: kids.add(" ")
    kids.add($i & " 0 R")
  let objs = @[
    "<< /Type /Catalog /Pages 2 0 R /PageLabels 13 0 R >>",
    "<< /Type /Pages /Kids [" & kids & "] /Count 8 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
    "<< /Nums [0 << /S /r >> 3 << /S /R /St 4 >>] >>",
    "<< /Nums [5 << /S /A /St 27 >> 6 << /S /a >> 7 << /P (End-) >>] >>",
    "<< /Kids [11 0 R 12 0 R] >>",
  ]
  writeFile(OutDir / "page_labels.pdf", assemblePdf(objs))
  var d = openDoc(readFile(OutDir / "page_labels.pdf"))
  doAssert d.pageLabels().len == 5
  doAssert labelForPage(d.pageLabels(), 3) == "IV"

proc writeAnnots() =
  let objs = @[
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] " &
      "/Annots [5 0 R 6 0 R 7 0 R 8 0 R 9 0 R 10 0 R 11 0 R] >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
    "<< /Type /Annot /Subtype /Link /Rect [0 0 100 20] " &
      "/Border [0 0 1] /A << /S /URI /URI (https://example.com/x) >> >>",
    "<< /Type /Annot /Subtype /Link /Rect [0 0 100 20] " &
      "/Dest [4 0 R /Fit] >>",
    "<< /Type /Annot /Subtype /Text /Rect [10 10 30 30] " &
      "/Contents (Fix this) /T (Anne) /Subj (Review) /C [1 0 0] " &
      "/F 4 /M (D:20260101) >>",
    "<< /Type /Annot /Subtype /Square /Rect [50 50 0 0] /C [0 1 0] >>",
    "<< /Type /Annot /Subtype /Highlight /Rect [0 0 60 10] " &
      "/QuadPoints [0 10 60 10 0 0 60 0] /C [1 1 0] >>",
    "<< /Type /Annot /Subtype /Ink /Rect [0 0 70 70] " &
      "/InkList [[0 0 10 10 20 0] [5 5 5 15]] >>",
    "<< /Type /Annot /Subtype /Widget /Rect [0 0 80 20] /T (field1) " &
      "/FT /Tx /V (hi) >>",
  ]
  writeFile(OutDir / "annots.pdf", assemblePdf(objs))
  var d = openDoc(readFile(OutDir / "annots.pdf"))
  doAssert d.pageAnnots(0).len == 7
  doAssert d.pageAnnots(1).len == 0

proc writeStructTree() =
  let objs = @[
    "<< /Type /Catalog /Pages 2 0 R /StructTreeRoot 4 0 R " &
      "/MarkInfo << /Marked true >> >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
    "<< /K [5 0 R] /RoleMap << /Chapter /Sect >> >>",
    "<< /S /Chapter /K [6 0 R 7 0 R 8 0 R] >>",
    "<< /S /P /Pg 3 0 R /K 0 /Alt (para alt) >>",
    "<< /Type /MCR /Pg 3 0 R /MCID 1 >>",
    "<< /S /Span /ActualText (ligature) /A << /O /Layout >> >>",
  ]
  writeFile(OutDir / "struct_tree.pdf", assemblePdf(objs))
  var d = openDoc(readFile(OutDir / "struct_tree.pdf"))
  let t = d.structTree()
  doAssert t.kids.len == 1
  doAssert t.kids[0].structType == "Sect"

writeInfoFull()
writeInfoDates()
writeOutlines()
writePageLabels()
writeAnnots()
writeStructTree()
echo "wrote M15 fixtures"
