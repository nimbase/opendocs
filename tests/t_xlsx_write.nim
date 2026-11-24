## XLSX writer tests (W1 fresh build).
##
## Hermetic: build in memory, reopen through the reader, compare values.
## No external tools (no excelize, no LibreOffice in CI). Zip timestamps
## are non-deterministic by design (`opendocs/zip` stamps `now()`), so
## tests round-trip through the reader, never byte-compare.

import std/[unittest, tables, strutils, os, tempfiles, times]
import opendocs/xlsx
import opendocs/zip

suite "xlsx writer fresh build":
  test "all five cell types round-trip":
    var doc = newXlsxDoc()
    doc.setCellStr("Sheet1", "A1", "hello")
    doc.setCellNum("Sheet1", "B1", 1.5)
    doc.setCellInt("Sheet1", "C1", 42)
    doc.setCellBool("Sheet1", "D1", true)
    doc.setCellBool("Sheet1", "D2", false)
    doc.setCellDate("Sheet1", "E1", dateTime(2026, mJan, 2, 12, 0, 0, 0, utc()))
    doc.setCellFormula("Sheet1", "F1", "SUM(A1:B1)")
    doc.setCellFormulaValue("Sheet1", "F2", "A1+1", 43.5)
    doc.setCellFormulaStr("Sheet1", "F3", "CONCAT(A1)", "hello!")
    let img = doc.saveXlsxBytes()
    let f = openXlsxBytes(img)
    defer: f.closeXlsx()
    check f.getCellValue("Sheet1", "A1") == "hello"
    check f.getCellType("Sheet1", "A1") == ctySharedString
    check f.getCellValue("Sheet1", "B1") == "1.5"
    check f.getCellValue("Sheet1", "C1") == "42"
    # Unstyled bools read back raw ("1"/"0"): TRUE/FALSE text is a
    # formatted view that needs a bool number format (W3 styles).
    check f.getCellValue("Sheet1", "D1") == "1"
    check f.getCellValue("Sheet1", "D2") == "0"
    check f.getCellType("Sheet1", "D1") == ctyBool
    let serial = f.getCellValue("Sheet1", "E1")
    check serial.parseFloat() > 40000.0
    check f.getCellFormula("Sheet1", "F1") == "SUM(A1:B1)"
    check f.getCellValue("Sheet1", "F1") == ""
    check f.getCellFormula("Sheet1", "F2") == "A1+1"
    check f.getCellValue("Sheet1", "F2") == "43.5"
    check f.getCellFormula("Sheet1", "F3") == "CONCAT(A1)"
    check f.getCellValue("Sheet1", "F3") == "hello!"

  test "second sheet and strings dedupe":
    var doc = newXlsxDoc()
    doc.addSheet("Second")
    doc.setCellStr("Sheet1", "A1", "dup")
    doc.setCellStr("Second", "A1", "dup")
    doc.setCellStr("Second", "B2", "other")
    let img = doc.saveXlsxBytes()
    let f = openXlsxBytes(img)
    defer: f.closeXlsx()
    check f.getSheetList() == @["Sheet1", "Second"]
    check f.getCellValue("Second", "A1") == "dup"
    check f.getCellValue("Second", "B2") == "other"
    check f.getSheetDimension("Second") == "A1:B2"

  test "sheet name validation fails loudly":
    var doc = newXlsxDoc()
    expect XlsxError:
      doc.addSheet("")
    expect XlsxError:
      doc.addSheet("Sheet1") # case-insensitive duplicate
    expect XlsxError:
      doc.addSheet("sheet1")
    expect XlsxError:
      doc.addSheet("a/b")
    expect XlsxError:
      doc.addSheet("a:b")
    expect XlsxError:
      doc.addSheet("'quoted'")
    expect XlsxError:
      doc.addSheet("12345678901234567890123456789012") # 32 chars

  test "bad cell refs fail loudly":
    var doc = newXlsxDoc()
    expect XlsxError:
      doc.setCellStr("Sheet1", "ZZZ9", "x")
    expect XlsxError:
      doc.setCellStr("Nope", "A1", "x")
    expect XlsxError:
      doc.setCellNum("Sheet1", "A0", 1.0)
    expect XlsxError:
      doc.setCellFormula("Sheet1", "A1", "")
    expect XlsxError:
      doc.setCellFormula("Sheet1", "A1", "=SUM(A1)")

  test "long strings truncate at 32767 UTF-16 units":
    var doc = newXlsxDoc()
    doc.setCellStr("Sheet1", "A1", 'a'.repeat(40000))
    let img = doc.saveXlsxBytes()
    let f = openXlsxBytes(img)
    defer: f.closeXlsx()
    check f.getCellValue("Sheet1", "A1").len == 32767

  test "dates before the epoch fail loudly":
    var doc = newXlsxDoc()
    expect XlsxError:
      doc.setCellDate("Sheet1", "A1",
        dateTime(1890, mJan, 1, 0, 0, 0, 0, utc()))

  test "non-finite floats store as strings":
    var doc = newXlsxDoc()
    doc.setCellNum("Sheet1", "A1", Inf)
    doc.setCellNum("Sheet1", "A2", NegInf)
    doc.setCellNum("Sheet1", "A3", Nan)
    let img = doc.saveXlsxBytes()
    let f = openXlsxBytes(img)
    defer: f.closeXlsx()
    check f.getCellType("Sheet1", "A1") == ctySharedString
    check "Inf" in f.getCellValue("Sheet1", "A1")

  test "spill path round-trips with a tiny threshold":
    var doc = newXlsxDoc()
    for i in 1 .. 200:
      doc.setCellStr("Sheet1", "A" & $i, "row value number " & $i)
      doc.setCellNum("Sheet1", "B" & $i, i.float)
    let opts = XlsxWriteOpts(spillThresholdBytes: 512,
      spillCapBytes: 64 * 1024 * 1024, spillDir: "")
    let img = doc.saveXlsxBytes(opts)
    let f = openXlsxBytes(img)
    defer: f.closeXlsx()
    check f.getCellValue("Sheet1", "A1") == "row value number 1"
    check f.getCellValue("Sheet1", "B200") == "200"
    check f.getCellValue("Sheet1", "A200") == "row value number 200"

  test "spill cap exceeded fails loudly":
    var doc = newXlsxDoc()
    for i in 1 .. 50:
      doc.setCellStr("Sheet1", "A" & $i, "padding value " & $i)
    let opts = XlsxWriteOpts(spillThresholdBytes: 1,
      spillCapBytes: 10, spillDir: "")
    expect XlsxError:
      discard doc.saveXlsxBytes(opts)

  test "raw parts carry through byte-exact":
    var doc = newXlsxDoc()
    doc.setCellStr("Sheet1", "A1", "hi")
    let blob = @[1'u8, 2, 3, 4, 5]
    doc.rawParts["xl/drawings/drawing1.xml"] = blob
    let img = doc.saveXlsxBytes()
    let arch = openZipBytes(img)
    check arch.readEntry("xl/drawings/drawing1.xml") == blob
    # Modeled parts win on collision; rels always regenerate.
    doc.rawParts["xl/workbook.xml"] = @[9'u8]
    doc.rawParts["_rels/.rels"] = @[9'u8]
    let img2 = doc.saveXlsxBytes()
    let arch2 = openZipBytes(img2)
    check arch2.readEntry("xl/workbook.xml") != @[9'u8]

  test "docProps round-trip":
    var doc = newXlsxDoc()
    doc.coreProps = XlsxDocProps(title: "T", creator: "me",
      language: "en-US", revision: "3")
    doc.appCompany = "nimbase"
    doc.customProps["Owner"] = "Alice"
    let img = doc.saveXlsxBytes()
    let f = openXlsxBytes(img)
    defer: f.closeXlsx()
    let p = f.getDocProps()
    check p.title == "T"
    check p.creator == "me"
    check p.revision == "3"
    let a = f.getAppProps()
    check "opendocs" in a["Application"]
    check a["SheetCount"] == "1"
    check f.getCustomProps()["Owner"] == "Alice"

  test "save to file and reopen":
    var doc = newXlsxDoc()
    doc.setCellInt("Sheet1", "A1", 7)
    let path = getTempDir() / "nimbase-xlsx-write-test.xlsx"
    try:
      doc.saveXlsx(path)
      let f = openXlsx(path)
      defer: f.closeXlsx()
      check f.getCellValue("Sheet1", "A1") == "7"
    finally:
      try: removeFile(path)
      except OSError: discard

suite "xlsx writer sheet extras":
  test "merges round-trip with anchor values":
    var doc = newXlsxDoc()
    doc.setCellStr("Sheet1", "A1", "top")
    doc.addMerge("Sheet1", "A1:B2")
    doc.addMerge("Sheet1", "D4:E5")
    let img = doc.saveXlsxBytes()
    let f = openXlsxBytes(img)
    defer: f.closeXlsx()
    check f.isMerged("Sheet1", "B2")
    check not f.isMerged("Sheet1", "C3")
    check f.getCellValue("Sheet1", "B2") == "top" # anchor redirect
    check f.getSheetDimension("Sheet1") == "A1:E5" # merges grow dimension
    let m = f.getMergeCells("Sheet1")
    check m.len == 2
    check m[0].`ref` == "A1:B2"
    check m[1].`ref` == "D4:E5"

  test "overlapping merges fail loudly":
    var doc = newXlsxDoc()
    doc.addMerge("Sheet1", "A1:B2")
    expect XlsxError:
      doc.addMerge("Sheet1", "B2:C3")
    expect XlsxError:
      doc.addMerge("Sheet1", "bogus")

  test "column widths and visibility round-trip":
    var doc = newXlsxDoc()
    doc.setCellStr("Sheet1", "A1", "x")
    doc.setColWidth("Sheet1", 1, 3, 20.0)
    doc.setColHidden("Sheet1", 5, 6)
    let img = doc.saveXlsxBytes()
    let f = openXlsxBytes(img)
    defer: f.closeXlsx()
    check f.getColWidth("Sheet1", 1) == 20.0
    check f.getColWidth("Sheet1", 3) == 20.0
    check f.getColWidth("Sheet1", 4) == -1.0
    check not f.getColVisible("Sheet1", 5)
    check f.getColVisible("Sheet1", 4)

  test "row heights and visibility round-trip":
    var doc = newXlsxDoc()
    doc.setCellStr("Sheet1", "A2", "x")
    doc.setRowHeight("Sheet1", 2, 30.0)
    doc.setRowHidden("Sheet1", 4)
    let img = doc.saveXlsxBytes()
    let f = openXlsxBytes(img)
    defer: f.closeXlsx()
    check f.getRowHeight("Sheet1", 2) == 30.0
    check f.getRowHeight("Sheet1", 1) == -1.0
    check not f.getRowVisible("Sheet1", 4)
    check f.getRowVisible("Sheet1", 2)

  test "geometry validation fails loudly":
    var doc = newXlsxDoc()
    expect XlsxError:
      doc.setColWidth("Sheet1", 3, 2, 10.0)
    expect XlsxError:
      doc.setColWidth("Sheet1", 1, 1, 0.0)
    expect XlsxError:
      doc.setColWidth("Sheet1", 0, 1, 10.0)
    expect XlsxError:
      doc.setRowHeight("Sheet1", 1, -1.0)
    expect XlsxError:
      doc.setRowHidden("Sheet1", 0)

  test "hyperlinks round-trip, external via rels":
    var doc = newXlsxDoc()
    doc.setCellStr("Sheet1", "A1", "ext")
    doc.setCellStr("Sheet1", "B2", "in")
    doc.addHyperlink("Sheet1", "A1", "https://example.com/?a=1&b=2",
      display = "Example", tooltip = "Open it")
    doc.addHyperlink("Sheet1", "B2:C3", "", location = "Other!A1",
      display = "Jump")
    doc.addSheet("Other")
    let img = doc.saveXlsxBytes()
    let f = openXlsxBytes(img)
    defer: f.closeXlsx()
    let (found, link) = f.getCellHyperlink("Sheet1", "A1")
    check found
    check link.target == "https://example.com/?a=1&b=2"
    check link.display == "Example"
    check link.tooltip == "Open it"
    let (found2, link2) = f.getCellHyperlink("Sheet1", "C3")
    check found2
    check link2.cell == "B2:C3" # stored ref, not the covered cell
    check link2.location == "Other!A1"
    check link2.target == ""
    # External rel part is really there (not inlined).
    let arch = openZipBytes(img)
    check arch.findEntry("xl/worksheets/_rels/sheet1.xml.rels") >= 0

  test "hyperlink validation fails loudly":
    var doc = newXlsxDoc()
    expect XlsxError:
      doc.addHyperlink("Sheet1", "A1", "")
    expect XlsxError:
      doc.addHyperlink("Sheet1", "ZZZ9", "https://example.com")
    expect XlsxError:
      doc.addHyperlink("Nope", "A1", "https://example.com")
    # External target plus internal anchor is allowed (link with fragment).
    doc.addHyperlink("Sheet1", "A1", "https://example.com",
      location = "frag", display = "both")
    let img = doc.saveXlsxBytes()
    let f = openXlsxBytes(img)
    defer: f.closeXlsx()
    let (found, link) = f.getCellHyperlink("Sheet1", "A1")
    check found
    check link.target == "https://example.com"
    check link.location == "frag"

  test "defined names round-trip, scopes preserved":
    var doc = newXlsxDoc()
    doc.addSheet("Second")
    doc.addDefinedName("Shared", "Sheet1!$A$1")
    doc.addDefinedName("Local", "=$B$2", scope = "Second", hidden = true,
      comment = "c")
    expect XlsxError:
      doc.addDefinedName("", "Sheet1!$A$1")
    expect XlsxError:
      doc.addDefinedName("A1", "Sheet1!$A$1") # cell-ref lookalike
    expect XlsxError:
      doc.addDefinedName("Nope", "Sheet1!$A$1", scope = "Missing")
    expect XlsxError:
      doc.addDefinedName("Empty", "")
    let img = doc.saveXlsxBytes()
    let f = openXlsxBytes(img)
    defer: f.closeXlsx()
    let names = f.getDefinedNames()
    check names.len == 2
    check names[0].name == "Shared"
    check names[0].refersTo == "Sheet1!$A$1"
    check names[0].scope == "Workbook"
    check names[1].name == "Local"
    check names[1].scope == "Second"
    check names[1].hidden
    check names[1].comment == "c"
