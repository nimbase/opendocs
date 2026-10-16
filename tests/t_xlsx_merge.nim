## Merged-cell reader tests.
##
## Fixtures are minimal synthetic packages rather than producer output: each
## isolates one merge shape (normal, reversed/off-anchor, empty, and
## overlapping declarations). They are checked in under
## `tests/fixtures/xlsx/merge_*.xlsx`.

import std/[unittest]
import opendocs/xlsx
import opendocs/zip

const MergeDir = "tests/fixtures/xlsx/"

suite "merged cells":
  test "covered cells read the stored anchor value and type":
    let f = openXlsx(MergeDir & "merge_basic.xlsx")
    defer: f.closeXlsx()
    let merges = f.getMergeCells("Basic")
    check merges.len == 2
    check merges[0].`ref` == "A1:B2"
    check (merges[0].firstCol, merges[0].firstRow,
      merges[0].lastCol, merges[0].lastRow) == (1, 1, 2, 2)
    check (merges[0].anchorCol, merges[0].anchorRow) == (1, 1)
    check merges[0].value == "7"
    check merges[1].value == "7"
    check f.getCellValue("Basic", "B1") == "7"
    check f.getCellValue("Basic", "A2") == "7"
    check f.getCellValue("Basic", "B2") == "7"
    check f.getCellType("Basic", "B2") == ctyUnset
    check f.isMerged("Basic", "B2")
    check not f.isMerged("Basic", "C1")
    check f.getCellFormula("Basic", "D2") == "SUM(A1:A1)"

  test "reversed ranges normalize and use the stored anchor":
    let f = openXlsx(MergeDir & "merge_offaxis.xlsx")
    defer: f.closeXlsx()
    let merges = f.getMergeCells("OffAxis")
    check merges.len == 1
    check merges[0].`ref` == "B2:A1"
    check (merges[0].firstCol, merges[0].firstRow,
      merges[0].lastCol, merges[0].lastRow) == (1, 1, 2, 2)
    check (merges[0].anchorCol, merges[0].anchorRow) == (2, 2)
    check merges[0].value == "9"
    check f.getCellValue("OffAxis", "A1") == "9"
    check f.getCellValue("OffAxis", "B1") == "9"
    check f.getCellValue("OffAxis", "A2") == "9"

  test "empty merges report the range without inventing values":
    let f = openXlsx(MergeDir & "merge_empty.xlsx")
    defer: f.closeXlsx()
    let merges = f.getMergeCells("Empty")
    check merges.len == 1
    check (merges[0].anchorCol, merges[0].anchorRow) == (0, 0)
    check merges[0].value == ""
    check f.getCellValue("Empty", "B2") == ""
    check f.getCellType("Empty", "B2") == ctyUnset
    check f.isMerged("Empty", "B2")

  test "first-listed range wins an overlap":
    let f = openXlsx(MergeDir & "merge_overlap.xlsx")
    defer: f.closeXlsx()
    let merges = f.getMergeCells("Overlap")
    check merges.len == 2
    check merges[0].`ref` == "A1:B2"
    check merges[1].`ref` == "B2:C3"
    check merges[0].value == "first"
    check merges[1].value == "second"
    check f.getCellValue("Overlap", "B2") == "first"
    check f.getCellValue("Overlap", "C2") == "second"
    check f.getCellValue("Overlap", "C3") == "second"

  test "the value grid stays storage-shaped":
    let f = openXlsx(MergeDir & "merge_basic.xlsx")
    defer: f.closeXlsx()
    check f.getRows("Basic") == @[@["7", "", "", "7"]]

suite "malformed merges":
  const
    BadNsMain = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    BadNsRel =
      "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    BadNsPkg =
      "http://schemas.openxmlformats.org/package/2006/relationships"

  proc mergePkg(mergeXml: string): seq[byte] =
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
<worksheet xmlns="""" & BadNsMain & """"><sheetData/>""" & mergeXml &
        """</worksheet>"""),
    ]:
      w.addFile(name, content)
    w.toBytes()

  test "merge declarations without refs raise":
    let f = openXlsxBytes(mergePkg(
      """<mergeCells count="1"><mergeCell/></mergeCells>"""))
    defer: f.closeXlsx()
    expect XlsxError:
      discard f.getMergeCells("Bad")

  test "malformed ranges raise":
    let f = openXlsxBytes(mergePkg(
      """<mergeCells count="1"><mergeCell ref="A1:"/></mergeCells>"""))
    defer: f.closeXlsx()
    expect XlsxError:
      discard f.getMergeCells("Bad")
