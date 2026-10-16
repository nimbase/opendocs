## Defined-name reader tests.
##
## `defined_names.xlsx` is a minimal synthetic package with fixed archive
## timestamps. Its two sheets deliberately have sheet IDs that differ from
## workbook order, proving that `localSheetId` is an order index rather than
## a sheet ID.

import std/[unittest]
import opendocs/xlsx
import opendocs/zip

const DefinedNamesDir = "tests/fixtures/xlsx/"

suite "defined names":
  test "workbook and sheet scopes are exposed without precedence filtering":
    let f = openXlsx(DefinedNamesDir & "defined_names.xlsx")
    defer: f.closeXlsx()
    let names = f.getDefinedNames()
    check names.len == 6
    check names[0].name == "Shared"
    check names[0].refersTo == "First!$A$1"
    check names[0].scope == "Workbook"
    check not names[0].hidden
    check names[1].name == "Shared"
    check names[1].refersTo == "Second!$B$2"
    check names[1].scope == "Second"
    check names[1].hidden
    check names[1].comment == "local wins"

  test "leading equals signs and built-ins are preserved":
    let f = openXlsx(DefinedNamesDir & "defined_names.xlsx")
    defer: f.closeXlsx()
    let names = f.getDefinedNames()
    check names[2].refersTo == "First!$C$3"
    check names[3].name == "Secret"
    check names[3].hidden
    check names[3].comment == "hidden global"
    check names[4].name == "_xlnm.Print_Area"
    check names[4].refersTo == "First!$A$1:$B$2"
    check names[4].scope == "First"
    check names[5].name == "_xlnm.Print_Titles"
    check names[5].refersTo == "Second!$1:$1"
    check names[5].scope == "Second"

suite "malformed defined names":
  const
    BadNsMain = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    BadNsRel =
      "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    BadNsPkg =
      "http://schemas.openxmlformats.org/package/2006/relationships"

  proc namesPkg(namesXml: string): seq[byte] =
    var w = newZipWriter()
    for (name, content) in [
      ("_rels/.rels", """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="""" & BadNsPkg & """"><Relationship Id="rId1" Type="""" &
        BadNsRel & """/officeDocument" Target="xl/workbook.xml"/></Relationships>"""),
      ("xl/workbook.xml", """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="""" & BadNsMain & """" xmlns:r="""" & BadNsRel & """"><sheets><sheet name="Bad" sheetId="1" r:id="rId1"/></sheets>""" &
        namesXml & """</workbook>"""),
      ("xl/_rels/workbook.xml.rels", """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="""" & BadNsPkg & """"><Relationship Id="rId1" Type="""" &
        BadNsRel & """/worksheet" Target="worksheets/sheet1.xml"/></Relationships>"""),
      ("xl/worksheets/sheet1.xml", """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="""" & BadNsMain & """"><sheetData/></worksheet>"""),
    ]:
      w.addFile(name, content)
    w.toBytes()

  test "local sheet indexes outside workbook order raise":
    expect XlsxError:
      discard openXlsxBytes(namesPkg(
        """<definedNames><definedName name="Bad" localSheetId="7">Bad!$A$1</definedName></definedNames>"""))

  test "unnamed definitions raise":
    expect XlsxError:
      discard openXlsxBytes(namesPkg(
        """<definedNames><definedName>Bad!$A$1</definedName></definedNames>"""))
