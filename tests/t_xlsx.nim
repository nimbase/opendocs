## Phase A spreadsheet reader tests: synthetic packages covering every
## Phase A cell kind, grid edge cases, A1 utils, and failure modes.

import std/[unittest, tables, os, strutils]
import opendocs/xlsx
import opendocs/zip

const
  NsMain = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
  NsRel =
    "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
  NsPkg = "http://schemas.openxmlformats.org/package/2006/relationships"

proc packXlsx(files: openArray[(string, string)]): seq[byte] =
  var w = newZipWriter()
  for (name, content) in files: w.addFile(name, content)
  w.toBytes()

proc packXlsxBin(files: openArray[(string, seq[byte])]): seq[byte] =
  var w = newZipWriter()
  for (name, content) in files: w.addFile(name, content)
  w.toBytes()

proc samplePkg(workbookExtra = "", sheet2Rows = ""): seq[byte] =
  packXlsx([
    ("_rels/.rels", """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="""" & NsPkg & """"><Relationship Id="rId1" Type="""" &
      NsRel & """/officeDocument" Target="xl/workbook.xml"/></Relationships>"""),
    ("xl/workbook.xml",
      """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="""" & NsMain & """" xmlns:r="""" & NsRel & """">""" &
      workbookExtra &
      """<sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/><sheet name="Data" sheetId="2" r:id="rId2"/></sheets></workbook>"""),
    ("xl/_rels/workbook.xml.rels",
      """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="""" & NsPkg & """"><Relationship Id="rId1" Type="""" &
      NsRel & """/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="""" &
      NsRel & """/worksheet" Target="worksheets/sheet2.xml"/></Relationships>"""),
    ("xl/worksheets/sheet1.xml",
      """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="""" & NsMain & """"><dimension ref="A1:H4"/><sheetData>
<row r="1"><c r="A1"><v>42</v></c><c r="B1" t="s"><v>0</v></c><c r="C1" t="inlineStr"><is><t>hi</t></is></c><c r="D1" t="b"><v>1</v></c><c r="E1"><f>SUM(A1:A2)</f><v>10</v></c><c r="F1" t="str"><v>calc</v></c><c r="G1" t="e"><v>#DIV/0!</v></c><c r="H1" t="d"><v>44927</v></c></row>
<row r="2"><c r="A2"><v>7</v></c><c r="C2" t="s"><v>1</v></c></row>
<row r="4"><c r="A4"><v>gap</v></c></row>
</sheetData></worksheet>"""),
    ("xl/worksheets/sheet2.xml",
      """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="""" & NsMain & """"><sheetData>""" & sheet2Rows &
      """</sheetData></worksheet>"""),
    ("xl/sharedStrings.xml",
      """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<sst xmlns="""" & NsMain & """" count="2" uniqueCount="2"><si><t>hello</t></si><si><r><t>foo</t></r><r><t>bar</t></r></si></sst>"""),
  ])

suite "workbook mapping":
  test "sheet list and map in workbook order":
    let f = openXlsxBytes(samplePkg())
    defer: f.closeXlsx()
    check f.getSheetList() == @["Sheet1", "Data"]
    check f.getSheetMap() == {1: "Sheet1", 2: "Data"}.toTable
    check f.date1904 == false

  test "date1904 flag from workbookPr":
    let f = openXlsxBytes(samplePkg(
      """<workbookPr date1904="1"/>"""))
    defer: f.closeXlsx()
    check f.date1904 == true

  test "sheet lookup is case-insensitive":
    let f = openXlsxBytes(samplePkg())
    defer: f.closeXlsx()
    check f.getCellValue("sheet1", "A1") == "42"
    check f.getCellValue("SHEET1", "A1") == "42"

  test "unknown sheet raises":
    let f = openXlsxBytes(samplePkg())
    defer: f.closeXlsx()
    expect XlsxError:
      discard f.getRows("Nope")

suite "raw cell values":
  test "every Phase A cell kind resolves":
    let f = openXlsxBytes(samplePkg())
    defer: f.closeXlsx()
    check f.getCellValue("Sheet1", "A1") == "42" # plain number
    check f.getCellValue("Sheet1", "B1") == "hello" # shared string
    check f.getCellValue("Sheet1", "C1") == "hi" # inline string
    check f.getCellValue("Sheet1", "D1") == "1" # bool raw
    check f.getCellValue("Sheet1", "E1") == "10" # formula cached
    check f.getCellValue("Sheet1", "F1") == "calc" # t=str
    check f.getCellValue("Sheet1", "G1") == "#DIV/0!" # error
    check f.getCellValue("Sheet1", "H1") == "44927" # date raw
    check f.getCellValue("Sheet1", "C2") == "foobar" # rich SST concat

  test "missing cell reads empty":
    let f = openXlsxBytes(samplePkg())
    defer: f.closeXlsx()
    check f.getCellValue("Sheet1", "B2") == ""
    check f.getCellValue("Sheet1", "Z99") == ""

  test "cell types":
    let f = openXlsxBytes(samplePkg())
    defer: f.closeXlsx()
    check f.getCellType("Sheet1", "A1") == ctyUnset
    check f.getCellType("Sheet1", "B1") == ctySharedString
    check f.getCellType("Sheet1", "C1") == ctyInlineString
    check f.getCellType("Sheet1", "D1") == ctyBool
    check f.getCellType("Sheet1", "E1") == ctyUnset # formula, no t
    check f.getCellType("Sheet1", "F1") == ctyFormula
    check f.getCellType("Sheet1", "G1") == ctyError
    check f.getCellType("Sheet1", "H1") == ctyDate
    check f.getCellType("Sheet1", "Z99") == ctyUnset

  test "formula text":
    let f = openXlsxBytes(samplePkg())
    defer: f.closeXlsx()
    check f.getCellFormula("Sheet1", "E1") == "SUM(A1:A2)"
    check f.getCellFormula("Sheet1", "A1") == ""
    check f.getCellFormula("Sheet1", "Z99") == ""

suite "grid shape":
  test "interior blanks pad, trailing blanks trim, row gaps surface":
    let f = openXlsxBytes(samplePkg())
    defer: f.closeXlsx()
    let rows = f.getRows("Sheet1")
    check rows.len == 4
    check rows[0] ==
      @["42", "hello", "hi", "1", "10", "calc", "#DIV/0!", "44927"]
    check rows[1] == @["7", "", "foobar"]
    check rows[2] == newSeq[string]()
    check rows[3] == @["gap"]

  test "columns transpose with trailing trim":
    let f = openXlsxBytes(samplePkg())
    defer: f.closeXlsx()
    let cols = f.getCols("Sheet1")
    check cols.len == 8
    check cols[0] == @["42", "7", "", "gap"]
    check cols[1] == @["hello"]
    check cols[2] == @["hi", "foobar"]
    check cols[7] == @["44927"]

  test "empty sheet reads empty":
    let f = openXlsxBytes(samplePkg())
    defer: f.closeXlsx()
    check f.getRows("Data") == newSeq[seq[string]]()
    check f.getCols("Data") == newSeq[seq[string]]()

  test "dimension is stored":
    let f = openXlsxBytes(samplePkg())
    defer: f.closeXlsx()
    check f.getSheet("Sheet1").dimension == "A1:H4"

suite "A1 references":
  test "split and join round-trip":
    check splitCellRef("A1") == (1, 1)
    check splitCellRef("XFD1048576") == (16384, 1048576)
    check splitCellRef("$B$12") == (2, 12)
    check joinCellName(1, 1) == "A1"
    check joinCellName(16384, 1048576) == "XFD1048576"

  test "column conversions":
    check columnNameToNumber("A") == 1
    check columnNameToNumber("Z") == 26
    check columnNameToNumber("AA") == 27
    check columnNameToNumber("XFD") == 16384
    check columnNumberToName(1) == "A"
    check columnNumberToName(27) == "AA"
    check columnNumberToName(16384) == "XFD"

  test "malformed refs raise":
    for bad in ["", "A", "1", "A0", "A1B2", "a1", "XFE1", "A1048577"]:
      expect XlsxError:
        discard splitCellRef(bad)
    expect XlsxError:
      discard columnNumberToName(0)
    expect XlsxError:
      discard joinCellName(1, 0)

suite "failure modes":
  test "not a zip raises":
    expect XlsxError:
      discard openXlsxBytes(@[byte('n'), byte('o'), byte('t')])

  test "OLE magic is rejected, not misread":
    var data = @[0xD0'u8, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
    expect XlsxError:
      discard openXlsxBytes(data)

  test "missing workbook raises":
    let pkg = packXlsx([("_rels/.rels",
      """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="""" & NsPkg & """"/>""")])
    expect XlsxError:
      discard openXlsxBytes(pkg)

  test "bad sheet XML raises":
    var files = @[
      ("_rels/.rels", """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="""" & NsPkg & """"><Relationship Id="rId1" Type="""" &
        NsRel & """/officeDocument" Target="xl/workbook.xml"/></Relationships>"""),
      ("xl/workbook.xml", """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="""" & NsMain & """" xmlns:r="""" & NsRel & """"><sheets><sheet name="S" sheetId="1" r:id="rId1"/></sheets></workbook>"""),
      ("xl/_rels/workbook.xml.rels", """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="""" & NsPkg & """"><Relationship Id="rId1" Type="""" &
        NsRel & """/worksheet" Target="worksheets/sheet1.xml"/></Relationships>"""),
      ("xl/worksheets/sheet1.xml", "<worksheet><sheetData>"),
    ]
    let f = openXlsxBytes(packXlsx(files))
    defer: f.closeXlsx()
    expect XlsxError:
      discard f.getRows("S")

  test "shared-string index out of range raises":
    let f = openXlsxBytes(samplePkg(
      sheet2Rows = """<row r="1"><c r="A1" t="s"><v>99</v></c></row>"""))
    defer: f.closeXlsx()
    expect XlsxError:
      discard f.getCellValue("Data", "A1")

  test "dangling sheet rel lists but raises on access":
    var files = @[
      ("_rels/.rels", """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="""" & NsPkg & """"><Relationship Id="rId1" Type="""" &
        NsRel & """/officeDocument" Target="xl/workbook.xml"/></Relationships>"""),
      ("xl/workbook.xml", """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="""" & NsMain & """" xmlns:r="""" & NsRel & """"><sheets><sheet name="Ghost" sheetId="1" r:id="rId9"/></sheets></workbook>"""),
      ("xl/_rels/workbook.xml.rels", """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="""" & NsPkg & """"><Relationship Id="rId9" Type="""" &
        NsRel & """/worksheet" Target="worksheets/ghost.xml"/></Relationships>"""),
    ]
    let f = openXlsxBytes(packXlsx(files))
    defer: f.closeXlsx()
    check f.getSheetList() == @["Ghost"]
    expect XlsxError:
      discard f.getRows("Ghost")

suite "libreoffice fixture":
  # tests/fixtures/xlsx/fixture1.xlsx: two-sheet workbook written by
  # LibreOffice (from a flat-ODF source). Oracle: soffice --convert-to csv
  # name,qty,price,ok / apple,3,1.5,1 / pear,7,2.25,45366 / total,Err:510
  # NOTE: LO normalizes bools/dates to numbers on xlsx export, and the
  # formula cell carries a stale #VALUE! cache (LO recomputes on load).
  # Raw readers surface stored values; recalc is a later phase.
  test "fixture1 sheets and raw grid":
    let f = openXlsx("tests/fixtures/xlsx/fixture1.xlsx")
    defer: f.closeXlsx()
    check f.getSheetList() == @["Fruit", "Second"]
    check f.getRows("Fruit") == @[
      @["name", "qty", "price", "ok"],
      @["apple", "3", "1.5", "1"],
      @["pear", "7", "2.25", "45366"],
      @["total", "#VALUE!"],
    ]
    check f.getRows("Second") ==
      @[@["second-sheet"], newSeq[string](), @["", "", "99"]]
    check f.getCellFormula("Fruit", "B4") == "of:=SUM(B2:B3)"
    check f.getCellType("Fruit", "B4") == ctyError
    check f.getCellType("Fruit", "D2") == ctyNumber # bool normalized
    check f.getCellType("Fruit", "D3") == ctyNumber # date serialized

suite "phase B oracle matrix":
  const matrixFmts = [0, 1, 2, 3, 4, 9, 10, 11, 12, 13, 14, 15, 16, 17,
    18, 19, 20, 21, 22, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49]

  proc unquoteGo(s: string): string =
    ## Minimal Go %q unquote (dump contains no exotic escapes).
    result = ""
    var i = 0
    assert s[0] == '"' and s[^1] == '"'
    let b = s[1 .. ^2]
    while i < b.len:
      if b[i] == '\\' and i + 1 < b.len:
        case b[i + 1]
        of '"': result &= '"'
        of '\\': result &= '\\'
        of 'n': result &= '\n'
        of 't': result &= '\t'
        else: result &= b[i + 1]
        i += 2
      else:
        result &= b[i]
        i += 1

  test "excelize-produced matrix matches the GetCellValue dump":
    var expected = initTable[(int, int), string]()
    for line in readFile(
        "tests/fixtures/xlsx/phase_b_matrix.txt").splitLines():
      if line.strip() == "" or line.startsWith("bool"): continue
      let a = line.find('|')
      let b = line.find('|', a + 1)
      expected[(parseInt(line[0 ..< a]), parseInt(line[a + 1 ..< b]))] =
        unquoteGo(line[b + 1 .. ^1])
    check expected.len == 32 * 18
    let f = openXlsx("tests/fixtures/xlsx/phase_b_matrix.xlsx")
    defer: f.closeXlsx()
    for j, id in matrixFmts:
      let col = columnNumberToName(j + 2)
      for i in 0 ..< 18:
        check f.getCellValue("Sheet1", col & $(i + 2)) ==
          expected[(id, i)]

  test "bools under a date style stay boolean":
    let f = openXlsx("tests/fixtures/xlsx/phase_b_matrix.xlsx")
    defer: f.closeXlsx()
    check f.getCellValue("Sheet1", "A20") == "TRUE"
    check f.getCellValue("Sheet1", "A21") == "FALSE"

proc styledPkg(cells, stylesXml: string,
    workbookExtra = ""): seq[byte] =
  ## One-sheet package with an explicit stylesheet.
  packXlsx([
    ("_rels/.rels", """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="""" & NsPkg & """"><Relationship Id="rId1" Type="""" &
      NsRel & """/officeDocument" Target="xl/workbook.xml"/></Relationships>"""),
    ("xl/workbook.xml",
      """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="""" & NsMain & """" xmlns:r="""" & NsRel & """">""" &
      workbookExtra &
      """<sheets><sheet name="S" sheetId="1" r:id="rId1"/></sheets></workbook>"""),
    ("xl/_rels/workbook.xml.rels",
      """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="""" & NsPkg & """"><Relationship Id="rId1" Type="""" &
      NsRel & """/worksheet" Target="worksheets/sheet1.xml"/></Relationships>"""),
    ("xl/worksheets/sheet1.xml",
      """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="""" & NsMain & """"><sheetData>""" & cells &
      """</sheetData></worksheet>"""),
    ("xl/styles.xml", stylesXml),
  ])

const builtinStyles = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="""" & NsMain & """"><numFmts count="1"><numFmt numFmtId="164" formatCode="0.000"/></numFmts><cellXfs count="4"><xf numFmtId="0"/><xf numFmtId="2"/><xf numFmtId="14"/><xf numFmtId="164"/></cellXfs></styleSheet>"""

suite "phase B formatting":
  test "bool and ISO dates format, errors and strings pass through":
    let pkg = styledPkg(
      """<row r="1"><c r="A1" s="1" t="b"><v>1</v></c><c r="B1" s="1" t="b"><v>0</v></c><c r="C1" s="2" t="d"><v>20240315T000000</v></c><c r="D1" s="2" t="d"><v>2024-03-15T00:00:00Z</v></c><c r="E1" s="2" t="d"><v>2024-03-15 06:00:00</v></c><c r="F1" s="2" t="d"><v>not-a-date</v></c><c r="G1" s="1" t="e"><v>#DIV/0!</v></c><c r="H1" s="1" t="str"><v>calc</v></c></row>""",
      builtinStyles)
    let f = openXlsxBytes(pkg)
    defer: f.closeXlsx()
    check f.getCellValue("S", "A1") == "TRUE"
    check f.getCellValue("S", "B1") == "FALSE"
    check f.getCellValue("S", "C1") == "03-15-24"
    check f.getCellValue("S", "D1") == "03-15-24"
    check f.getCellValue("S", "E1") == "03-15-24"
    check f.getCellValue("S", "F1") == "not-a-date"
    check f.getCellValue("S", "G1") == "#DIV/0!"
    check f.getCellValue("S", "H1") == "calc"

  test "custom codes fall back to raw until Phase C":
    let pkg = styledPkg(
      """<row r="1"><c r="A1" s="3"><v>1.5</v></c></row>""",
      builtinStyles)
    let f = openXlsxBytes(pkg)
    defer: f.closeXlsx()
    check f.getCellValue("S", "A1") == "1.5"

  test "missing styles and out-of-range S read raw without error":
    let noStyles = packXlsx([
      ("_rels/.rels", """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="""" & NsPkg & """"><Relationship Id="rId1" Type="""" &
        NsRel & """/officeDocument" Target="xl/workbook.xml"/></Relationships>"""),
      ("xl/workbook.xml", """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="""" & NsMain & """" xmlns:r="""" & NsRel & """"><sheets><sheet name="S" sheetId="1" r:id="rId1"/></sheets></workbook>"""),
      ("xl/_rels/workbook.xml.rels", """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="""" & NsPkg & """"><Relationship Id="rId1" Type="""" &
        NsRel & """/worksheet" Target="worksheets/sheet1.xml"/></Relationships>"""),
      ("xl/worksheets/sheet1.xml", """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="""" & NsMain & """"><sheetData><row r="1"><c r="A1" s="5"><v>1.5</v></c></row></sheetData></worksheet>"""),
    ])
    let f = openXlsxBytes(noStyles)
    defer: f.closeXlsx()
    check f.getCellValue("S", "A1") == "1.5"
    let g = openXlsxBytes(styledPkg(
      """<row r="1"><c r="A1" s="99"><v>1.5</v></c></row>""",
      builtinStyles))
    defer: g.closeXlsx()
    check g.getCellValue("S", "A1") == "1.5"

  test "rawCellValue opt returns stored values":
    let pkg = styledPkg(
      """<row r="1"><c r="A1" s="1"><v>44927.5</v></c><c r="B1" s="1" t="b"><v>1</v></c></row>""",
      builtinStyles)
    let f = openXlsxBytes(pkg, XlsxReadOpts(rawCellValue: true))
    defer: f.closeXlsx()
    check f.getCellValue("S", "A1") == "44927.5"
    check f.getCellValue("S", "B1") == "1"
    let g = openXlsxBytes(pkg)
    defer: g.closeXlsx()
    check g.getCellValue("S", "A1") == "44927.50"
    check g.getCellValue("S", "B1") == "TRUE"

  test "1904 date system renders its quirk table":
    let pkg = styledPkg(
      """<row r="1"><c r="A1" s="2"><v>0</v></c><c r="B1" s="2"><v>1</v></c><c r="C1" s="2"><v>61</v></c></row>""",
      builtinStyles, """<workbookPr date1904="1"/>""")
    let f = openXlsxBytes(pkg)
    defer: f.closeXlsx()
    check f.date1904 == true
    check f.getCellValue("S", "A1") == "01-00-00"
    check f.getCellValue("S", "B1") == "01-03-00"
    check f.getCellValue("S", "C1") == "03-02-04"

  test "explicit General trims like the reference":
    let pkg = styledPkg(
      """<row r="1"><c r="A1" s="0"><v>2.675</v></c></row>""",
      """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="""" & NsMain & """"><cellXfs count="1"><xf numFmtId="0" applyNumberFormat="1"/></cellXfs></styleSheet>""")
    let f = openXlsxBytes(pkg)
    defer: f.closeXlsx()
    check f.getCellValue("S", "A1") == "2.675"

suite "package variants and spill":
  test "macro-style package with vbaProject.bin opens":
    # Binary macro parts ride along untouched (Phase D parses the OLE).
    var w = newZipWriter()
    for (name, content) in [
        ("_rels/.rels", """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="""" & NsPkg & """"><Relationship Id="rId1" Type="""" &
          NsRel & """/officeDocument" Target="xl/workbook.xml"/></Relationships>"""),
        ("xl/workbook.xml", """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="""" & NsMain & """" xmlns:r="""" & NsRel & """"><sheets><sheet name="M" sheetId="1" r:id="rId1"/></sheets></workbook>"""),
        ("xl/_rels/workbook.xml.rels", """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="""" & NsPkg & """"><Relationship Id="rId1" Type="""" &
          NsRel & """/worksheet" Target="worksheets/sheet1.xml"/></Relationships>"""),
        ("xl/worksheets/sheet1.xml", """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="""" & NsMain & """"><sheetData><row r="1"><c r="A1"><v>9</v></c></row></sheetData></worksheet>"""),
      ]:
      w.addFile(name, content)
    w.addFile("xl/vbaProject.bin",
      @[0xD0'u8, 0xCF, 0x11, 0xE0, 0xAA, 0xBB, 0xCC])
    let f = openXlsxBytes(w.toBytes())
    defer: f.closeXlsx()
    check f.getSheetList() == @["M"]
    check f.getCellValue("M", "A1") == "9"

  test "forced spill reads identical, close removes the dir":
    let f = openXlsxBytes(samplePkg(),
      XlsxReadOpts(spillThresholdBytes: 0))
    check f.spillDir != ""
    check dirExists(f.spillDir)
    let spilled = f.spillDir
    check f.getRows("Sheet1")[0][1] == "hello"
    check f.getCellValue("Sheet1", "C2") == "foobar"
    f.closeXlsx()
    check not dirExists(spilled)
