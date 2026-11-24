## M17 tests: XFDF export/import.

import std/strutils
import unittest
import ../src/opendocs/pdf
import ../src/opendocs/pdf/cos
import ../src/opendocs/pdf/docmodel
import ../src/opendocs/pdf/gstate
import ./pdf_support

proc xfdfPdf(): string =
  assemblePdf(@[
    "<< /Type /Catalog /Pages 2 0 R /AcroForm 4 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] " &
      "/Resources << /Font << /Helv 6 0 R >> >> " &
      "/Annots [5 0 R 7 0 R 9 0 R] /Contents 10 0 R >>",
    "<< /Fields [5 0 R 7 0 R 8 0 R] >>",
    "<< /Type /Annot /Subtype /Widget /Rect [50 300 200 320] " &
      "/FT /Tx /T (Name) /V (Ann) /DA (/Helv 12 Tf 0 g) /P 3 0 R >>",
    "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    "<< /Type /Annot /Subtype /Widget /Rect [50 270 62 282] " &
      "/FT /Btn /T (Agree) /V /Off /AS /Off " &
      "/AP << /N << /Yes 11 0 R /Off 12 0 R >> >> /P 3 0 R >>",
    "<< /FT /Ch /T (City) /V (Oslo) /Opt [(Oslo) (Bergen)] " &
      "/DA (/Helv 12 Tf 0 g) >>",
    "<< /Type /Annot /Subtype /Text /Rect [10 10 40 40] " &
      "/Contents (note one) /T (Bob) >>",
    streamObj("", "BT /Helv 12 Tf 50 350 Td (static) Tj ET"),
    streamObj("", ""),
    streamObj("", ""),
  ])

test "export carries fields and annots":
  var d = openDoc(xfdfPdf())
  let x = d.exportXfdf()
  check "<xfdf" in x
  check "name=\"Name\"" in x
  check "Ann" in x
  check "Agree" in x
  check "Oslo" in x
  check "<text" in x
  check "note one" in x

test "import fills fields and appends annots":
  let pkt = """<xfdf xmlns="http://ns.adobe.com/xfdf/"><fields>""" &
    """<field name="Name"><value>Grace</value></field>""" &
    """<field name="Agree"><value>Yes</value></field>""" &
    """<field name="City"><value>Bergen</value></field>""" &
    """</fields><annots>""" &
    """<text page="0" rect="5,5,30,30">added note</text>""" &
    """<link page="0" rect="0,0,40,10" href="https://example.com/"/>""" &
    """</annots></xfdf>"""
  let data = importXfdf(xfdfPdf(), pkt)
  var d = openDoc(data)
  check d.getField("Name").value == "Grace"
  check d.getField("Agree").value == "Yes"
  check d.getField("City").value == "Bergen"
  let a0 = d.pageAnnots(0)
  check a0.len == 5
  var sawNote = false
  var sawLink = false
  for a in a0:
    if a.subtype == "Text" and a.contents == "added note":
      sawNote = true
    if a.subtype == "Link" and a.uri == "https://example.com/":
      sawLink = true
  check sawNote and sawLink

test "import rejects unknown field and bad xml":
  expect PdfError:
    discard importXfdf(xfdfPdf(),
      """<xfdf><fields><field name="Nope"><value>x</value></field>""" &
      """</fields></xfdf>""")
  expect PdfError:
    discard importXfdf(xfdfPdf(), "not xml at all <<<")
  # Base untouched by failed imports is implied: input string is never
  # mutated (import returns new bytes).

test "export then import round-trips values":
  var d = openDoc(xfdfPdf())
  let x = d.exportXfdf()
  let data = importXfdf(xfdfPdf(), x)
  var d2 = openDoc(data)
  check d2.getField("Name").value == "Ann"
  check d2.getField("City").value == "Oslo"
