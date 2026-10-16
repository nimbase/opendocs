## Hyperlink reader tests.
##
## `hyperlinks.xlsx` is a minimal synthetic package with fixed archive
## timestamps. It covers an external relationship, an internal location, a
## dangling relationship ID, and a `HYPERLINK()` formula that must not be
## mistaken for a `<hyperlinks>` entry.

import std/[unittest]
import opendocs/xlsx
import opendocs/zip

const HyperlinksDir = "tests/fixtures/xlsx/"

suite "hyperlinks":
  test "external targets resolve verbatim":
    let f = openXlsx(HyperlinksDir & "hyperlinks.xlsx")
    defer: f.closeXlsx()
    let (found, link) = f.getCellHyperlink("Links", "A1")
    check found
    check link.cell == "A1"
    check link.target == "https://example.com/report?a=1&b=2"
    check link.location == ""
    check link.display == "Example report"
    check link.tooltip == "Open the example"

  test "range links cover cells but report the stored reference":
    let f = openXlsx(HyperlinksDir & "hyperlinks.xlsx")
    defer: f.closeXlsx()
    let (found, link) = f.getCellHyperlink("Links", "C3")
    check found
    check link.cell == "B2:C3"
    check link.target == ""
    check link.location == "Other!A1"
    check link.display == "Jump inside"

  test "dangling relationships report empty targets":
    let f = openXlsx(HyperlinksDir & "hyperlinks.xlsx")
    defer: f.closeXlsx()
    let (found, link) = f.getCellHyperlink("Links", "D4")
    check found
    check link.target == ""
    check link.display == "Dangling"

  test "hyperlink formulas are not hyperlink entries":
    let f = openXlsx(HyperlinksDir & "hyperlinks.xlsx")
    defer: f.closeXlsx()
    let (found, _) = f.getCellHyperlink("Links", "E5")
    check not found
    check f.getCellFormula("Links", "E5") ==
      """HYPERLINK("https://example.com/formula","label")"""

  test "all links are listed in file order":
    let f = openXlsx(HyperlinksDir & "hyperlinks.xlsx")
    defer: f.closeXlsx()
    let links = f.getHyperlinks("Links")
    check links.len == 3
    check links[0].cell == "A1"
    check links[1].cell == "B2:C3"
    check links[2].cell == "D4"

suite "malformed hyperlinks":
  const
    BadNsMain = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    BadNsRel =
      "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    BadNsPkg =
      "http://schemas.openxmlformats.org/package/2006/relationships"

  proc linksPkg(linksXml: string): seq[byte] =
    var w = newZipWriter()
    for (name, content) in [
      ("_rels/.rels", """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="""" & BadNsPkg & """"><Relationship Id="rId1" Type="""" &
        BadNsRel & """/officeDocument" Target="xl/workbook.xml"/></Relationships>"""),
      ("xl/workbook.xml", """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="""" & BadNsMain & """" xmlns:r="""" & BadNsRel & """"><sheets><sheet name="Bad" sheetId="1" r:id="rId1"/></sheets></workbook>"""),
      ("xl/_rels/workbook.xml.rels", """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="""" & BadNsPkg & """"><Relationship Id="rId1" Type="""" &
        BadNsRel & """/worksheet" Target="worksheets/sheet1.xml"/></Relationships>"""),
      ("xl/worksheets/sheet1.xml", """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="""" & BadNsMain & """"><sheetData/>""" & linksXml &
        """</worksheet>"""),
    ]:
      w.addFile(name, content)
    w.toBytes()

  test "links without refs raise":
    let f = openXlsxBytes(linksPkg(
      """<hyperlinks><hyperlink r:id="rIdH1"/></hyperlinks>"""))
    defer: f.closeXlsx()
    expect XlsxError:
      discard f.getHyperlinks("Bad")

  test "malformed link ranges raise":
    let f = openXlsxBytes(linksPkg(
      """<hyperlinks><hyperlink ref="A1:"/></hyperlinks>"""))
    defer: f.closeXlsx()
    expect XlsxError:
      discard f.getHyperlinks("Bad")

  test "malformed cell lookups raise":
    let f = openXlsx(HyperlinksDir & "hyperlinks.xlsx")
    defer: f.closeXlsx()
    expect XlsxError:
      discard f.getCellHyperlink("Links", "A0")
