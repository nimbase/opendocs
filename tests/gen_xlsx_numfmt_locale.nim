## Locale format fixture generator (run manually, not a test).
##
## Writes a minimal synthetic workbook under tests/fixtures/xlsx/ for the
## locale-aware custom date renderer. Fixtures are checked in so tests stay
## hermetic; rerun after any renderer change:
##   clue build tests/gen_xlsx_numfmt_locale.nim --out:/tmp/genloc && /tmp/genloc
##
## Origin: synthetic, generated locally by this script. Expected values
## were verified cell-by-cell against excelize (`GetCellValue`) before
## being frozen into `tests/t_xlsx_numfmt_locale.nim`.

import std/[os, strutils]
import ../src/opendocs/zip

const OutDir = "tests/fixtures/xlsx"

const Codes = [
  "[$-407]mmm d, yyyy",
  "[$-40C]mmmm d",
  "[$-411]dddd",
  "[$-411]h:mm AM/PM",
  "[$-404]e/m/d",
  "[$-419]mmmm",
  "[$-3010429]mmmm",
  "[$\u20AC-42D]mmmm",
  "[$-9999]m/d/yy",
  "[$-411]ggge",
  "[$-404]ggge",
  "[$-407]d-mmm-yy",
]

const Values = [
  "44927", "44927", "44927", "44927.75", "44927", "44927",
  "44927", "44927", "44927", "4384", "4384", "32",
]

proc stylesXml(): string =
  result = "<styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><numFmts count=\"" &
    $Codes.len & "\">"
  for i, c in Codes:
    result &= "<numFmt numFmtId=\"" & $(164 + i) &
      "\" formatCode=\"" & c.replace("\"", "&quot;") & "\"/>"
  result &= "</numFmts><cellXfs count=\"" & $(Codes.len + 1) &
    "\"><xf numFmtId=\"0\"/>"
  for i in 0 ..< Codes.len:
    result &= "<xf numFmtId=\"" & $(164 + i) & "\"/>"
  result &= "</cellXfs></styleSheet>"

proc main() =
  var rows = ""
  for i in 0 ..< Codes.len:
    rows &= "<row r=\"" & $(i + 1) & "\"><c r=\"A" & $(i + 1) &
      "\" s=\"" & $(i + 1) & "\"><v>" & Values[i] & "</v></c></row>"
  let sheet = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>""" &
    rows & """</sheetData></worksheet>"""
  var w = newZipWriter()
  w.addFile("[Content_Types].xml",
    """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>""")
  w.addFile("_rels/.rels",
    """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>""")
  w.addFile("xl/workbook.xml",
    """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Loc" sheetId="1" r:id="rId1"/></sheets></workbook>""")
  w.addFile("xl/_rels/workbook.xml.rels",
    """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>""")
  w.addFile("xl/worksheets/sheet1.xml", sheet)
  w.addFile("xl/styles.xml", stylesXml())
  w.writeZip(OutDir / "fmt_locale.xlsx")
  echo "wrote ", OutDir / "fmt_locale.xlsx"

main()
