## Shared-formula fixture generator (run manually, not a test).
##
## Writes a minimal synthetic workbook under tests/fixtures/xlsx/ for
## shared-formula expansion. Fixtures are checked in so tests stay
## hermetic; rerun after any reader change:
##   clue build tests/gen_xlsx_shared_formula.nim --out:/tmp/genform && /tmp/genform
##
## Origin: synthetic, generated locally by this script. Expected formulas
## were verified cell-by-cell against excelize (`GetCellFormula`) before
## being frozen into `tests/t_xlsx_formula.nim`.

import std/os
import ../src/opendocs/zip

const OutDir = "tests/fixtures/xlsx"
const NsMain = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
const NsPkg = "http://schemas.openxmlformats.org/package/2006/relationships"
const NsRel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

const Sheet = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="""" & NsMain & """"><sheetData><row r="1"><c r="A1"><v>1</v></c><c r="C1"><f t="shared" ref="C1:C3" si="1">SUM('My Sheet'!A1:A10)</f><v>3</v></c></row><row r="2"><c r="A2"><v>10</v></c><c r="B2"><f t="shared" ref="B2:D2" si="0">A1*B2</f><v>2</v></c><c r="D2"><f t="shared" si="0"/><v>20</v></c><c r="C2"><f t="shared" si="1"/><v>30</v></c></row><row r="3"><c r="C3"><f t="shared" si="1"/><v>300</v></c></row><row r="5"><c r="D5"><f t="shared" ref="D5:D6" si="3">$A$1+A1+A$1+$A1</f><v>1</v></c></row><row r="6"><c r="D6"><f t="shared" si="3"/><v>2</v></c></row><row r="7"><c r="E7"><f t="shared" ref="E7:E8" si="4">A:A</f><v>1</v></c></row><row r="8"><c r="E8"><f t="shared" si="4"/><v>2</v></c></row><row r="9"><c r="F9"><f t="shared" si="99"/><v>0</v></c><c r="G9"><f>SUM(A1:A2)</f><v>3</v></c></row></sheetData></worksheet>"""

proc main() =
  var w = newZipWriter()
  w.addFile("[Content_Types].xml",
    """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>""")
  w.addFile("_rels/.rels",
    """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="""" & NsPkg & """"><Relationship Id="rId1" Type="""" &
      NsRel & """/officeDocument" Target="xl/workbook.xml"/></Relationships>""")
  w.addFile("xl/workbook.xml",
    """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="""" & NsMain & """" xmlns:r="""" & NsRel & """"><sheets><sheet name="Shared" sheetId="1" r:id="rId1"/></sheets></workbook>""")
  w.addFile("xl/_rels/workbook.xml.rels",
    """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="""" & NsPkg & """"><Relationship Id="rId1" Type="""" &
      NsRel & """/worksheet" Target="worksheets/sheet1.xml"/></Relationships>""")
  w.addFile("xl/worksheets/sheet1.xml", Sheet)
  w.writeZip(OutDir / "shared_formula.xlsx")
  echo "wrote ", OutDir / "shared_formula.xlsx"

main()
