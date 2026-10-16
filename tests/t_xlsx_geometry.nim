## Sheet geometry reader tests.
##
## `cols.xlsx` is a minimal synthetic package with fixed archive timestamps.
## The `Geometry` sheet exercises stored dimensions, explicit and absent row
## heights, hidden rows, overlapping column ranges, and format defaults. The
## `Bare` sheet proves that absent geometry stays absent instead of turning
## into an Excel default.

import std/[unittest]
import opendocs/xlsx
import opendocs/zip

const GeometryDir = "tests/fixtures/xlsx/"

suite "sheet dimension":
  test "stored dimensions are returned verbatim":
    let f = openXlsx(GeometryDir & "cols.xlsx")
    defer: f.closeXlsx()
    check f.getSheetDimension("Geometry") == "A1:D5"

  test "absent dimensions stay absent":
    let f = openXlsx(GeometryDir & "cols.xlsx")
    defer: f.closeXlsx()
    check f.getSheetDimension("Bare") == ""

suite "rows":
  test "explicit heights and visibility are exposed":
    let f = openXlsx(GeometryDir & "cols.xlsx")
    defer: f.closeXlsx()
    check f.getRowHeight("Geometry", 1) == 20.0
    check f.getRowVisible("Geometry", 1)
    check f.getRowHeight("Geometry", 2) == -1.0
    check not f.getRowVisible("Geometry", 2)
    check f.getRowHeight("Geometry", 4) == 30.0
    check f.getRowVisible("Geometry", 4)

  test "missing rows use default geometry":
    let f = openXlsx(GeometryDir & "cols.xlsx")
    defer: f.closeXlsx()
    check f.getRowHeight("Geometry", 3) == -1.0
    check f.getRowVisible("Geometry", 3)

suite "columns":
  test "explicit widths and last-wins overlaps are exposed":
    let f = openXlsx(GeometryDir & "cols.xlsx")
    defer: f.closeXlsx()
    check f.getColWidth("Geometry", 1) == 9.0
    check f.getColVisible("Geometry", 1)
    check f.getColWidth("Geometry", 2) == 15.0
    check f.getColWidth("Geometry", 3) == 20.0
    check not f.getColVisible("Geometry", 3)
    check f.getColWidth("Geometry", 4) == 20.0
    check not f.getColVisible("Geometry", 4)

  test "format defaults apply only when no explicit width matches":
    let f = openXlsx(GeometryDir & "cols.xlsx")
    defer: f.closeXlsx()
    check f.getColWidth("Geometry", 5) == 12.5
    check f.getColVisible("Geometry", 5)

  test "absent columns stay absent":
    let f = openXlsx(GeometryDir & "cols.xlsx")
    defer: f.closeXlsx()
    check f.getColWidth("Bare", 1) == -1.0
    check f.getColVisible("Bare", 1)

suite "malformed geometry":
  const
    BadNsMain = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    BadNsRel =
      "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    BadNsPkg =
      "http://schemas.openxmlformats.org/package/2006/relationships"

  proc geometryPkg(sheetXml: string): seq[byte] =
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
<worksheet xmlns="""" & BadNsMain & """">""" & sheetXml &
        """</worksheet>"""),
    ]:
      w.addFile(name, content)
    w.toBytes()

  test "row and column numbers are validated":
    let f = openXlsx(GeometryDir & "cols.xlsx")
    defer: f.closeXlsx()
    expect XlsxError:
      discard f.getRowHeight("Geometry", 0)
    expect XlsxError:
      discard f.getColWidth("Geometry", 0)
    expect XlsxError:
      discard f.getColWidth("Geometry", XlsxMaxCols + 1)

  test "malformed dimensions raise":
    let f = openXlsxBytes(geometryPkg(
      """<dimension ref="A1:"/><sheetData/>"""))
    defer: f.closeXlsx()
    expect XlsxError:
      discard f.getSheetDimension("Bad")

  test "malformed column ranges raise":
    let f = openXlsxBytes(geometryPkg(
      """<sheetData/><cols><col min="0" max="2"/></cols>"""))
    defer: f.closeXlsx()
    expect XlsxError:
      discard f.getColWidth("Bad", 1)
