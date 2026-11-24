## Document-properties reader tests.
##
## `fixture1.xlsx` (LibreOffice-produced) carries `docProps/core.xml`
## and `docProps/app.xml`. `docprops_custom.xlsx` is `fixture1.xlsx`
## plus an injected `docProps/custom.xml` exercising every flattened
## `vt:*` kind (string, int, bool, float, filetime); the rest of the
## package is byte-identical to the fixture. `cols.xlsx` has no
## `docProps/` parts at all (absent yields empty, never an error).

import std/[unittest, tables, strutils]
import opendocs/xlsx

const DocPropsDir = "tests/fixtures/xlsx/"

suite "docprops":
  test "core props read by local name":
    let f = openXlsx(DocPropsDir & "fixture1.xlsx")
    defer: f.closeXlsx()
    let p = f.getDocProps()
    check p.language == "en-US"
    check p.revision == "0"
    check p.title == ""
    check p.creator == ""
    check p.created == ""

  test "app props are a flat map plus sheet count":
    let f = openXlsx(DocPropsDir & "fixture1.xlsx")
    defer: f.closeXlsx()
    let a = f.getAppProps()
    check "LibreOffice" in a["Application"]
    check a["AppVersion"] == "15.0000"
    check a["SheetCount"] == "2"
    check "TitlesOfParts" notin a

  test "custom props flatten typed values":
    let f = openXlsx(DocPropsDir & "docprops_custom.xlsx")
    defer: f.closeXlsx()
    let c = f.getCustomProps()
    check c["Owner"] == "Alice"
    check c["Pages"] == "42"
    check c["Approved"] == "true"
    check c["Ratio"] == "1.5"
    check c["SignedAt"] == "2026-01-02T03:04:05Z"

  test "missing parts yield empty, never an error":
    let f = openXlsx(DocPropsDir & "cols.xlsx")
    defer: f.closeXlsx()
    check f.getDocProps() == XlsxDocProps()
    check f.getAppProps().len == 0
    check f.getCustomProps().len == 0
