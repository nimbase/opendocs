## Custom number-format fixture generator (run manually, not a test).
##
## Writes a minimal synthetic workbook under tests/fixtures/xlsx/ for
## the custom format renderer. Fixtures are checked in so tests stay
## hermetic; rerun after any renderer change:
##   clue build tests/gen_xlsx_numfmt.nim --out:/tmp/genfmt && /tmp/genfmt
##
## Origin: synthetic, generated locally by this script. Expected values
## were verified cell-by-cell against excelize (`GetCellValue`) before
## being frozen into `tests/t_xlsx_numfmt_custom.nim`.

import std/os
import std/strutils
import ../src/opendocs/zip

const OutDir = "tests/fixtures/xlsx"

const Codes = [
  "0.00", "#,##0", "0%", "# ?/?", "0.00E+00", "0,,", "[Red]0.00",
  "m/d/yy", "h:mm:ss", "[mm]:ss", "mm:ss.000", "[$-409]m/d/yy",
  "General", "@", "0;-0;\"zero\"", "\"a\"", "0\"k\"",
]

proc stylesXml(): string =
  result = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><numFmts count="""" &
    $Codes.len & """">"""
  for i, c in Codes:
    result &= "<numFmt numFmtId=\"" & $(164 + i) &
      "\" formatCode=\"" & c.replace("\"", "&quot;") & "\"/>"
  result &= "</numFmts><cellXfs count=\"" & $(Codes.len + 1) &
    "\"><xf numFmtId=\"0\"/>"
  for i in 0 ..< Codes.len:
    result &= "<xf numFmtId=\"" & $(164 + i) & "\"/>"
  result &= "</cellXfs></styleSheet>"

const Values = [
  "1.5", "1234567", "0.25", "2.75", "1234.5", "2500000", "-1.5",
  "44927", "0.5", "0.075", "0.000789", "44927", "1.5", "hi", "0",
  "5", "1500",
]

proc main() =
  var rows = ""
  for i in 0 ..< Codes.len:
    let cell = "A" & $(i + 1)
    let t = if i == 13: " t=\"s\"" else: ""
    let v = if i == 13: "0" else: Values[i]
    rows &= "<row r=\"" & $(i + 1) & "\"><c r=\"" & cell &
      "\" s=\"" & $(i + 1) & "\"" & t & "><v>" & v &
      "</v></c></row>"
  let sheet = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>""" &
    rows & """</sheetData></worksheet>"""
  let sst = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="1" uniqueCount="1"><si><t>hi</t></si></sst>"""
  var w = newZipWriter()
  w.addFile("[Content_Types].xml",
    """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>""")
  w.addFile("_rels/.rels",
    """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>""")
  w.addFile("xl/workbook.xml",
    """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Fmt" sheetId="1" r:id="rId1"/></sheets></workbook>""")
  w.addFile("xl/_rels/workbook.xml.rels",
    """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/></Relationships>""")
  w.addFile("xl/worksheets/sheet1.xml", sheet)
  w.addFile("xl/sharedStrings.xml", sst)
  w.addFile("xl/styles.xml", stylesXml())
  w.writeZip(OutDir / "fmt_custom.xlsx")
  echo "wrote ", OutDir / "fmt_custom.xlsx"

main()
