## Style fixture generator (run manually, not a test).
##
## Writes a minimal synthetic workbook under tests/fixtures/xlsx/ for the
## style-record reader. Fixtures are checked in so tests stay hermetic;
## rerun after any reader change:
##   clue build tests/gen_xlsx_style.nim --out:/tmp/genstyle && /tmp/genstyle
##
## Origin: synthetic, generated locally by this script. Expected style
## values were verified cell-by-cell against excelize (`GetStyle`) before
## being frozen into `tests/t_xlsx_style.nim`.

import std/os
import ../src/opendocs/zip

const OutDir = "tests/fixtures/xlsx"
const NsMain = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"

const Styles = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="""" & NsMain & """"><numFmts count="1"><numFmt numFmtId="164" formatCode="0.00"/></numFmts><fonts count="4"><font><b/><sz val="14"/><color rgb="FFFF0000"/><name val="Calibri"/></font><font><i/><u val="single"/><sz val="11"/><color theme="4" tint="-0.5"/><name val="Arial"/></font><font><color indexed="12"/><name val="Calibri"/></font><font><sz val="10"/><color rgb="FF00FF00"/><name val="Calibri"/><family val="2"/><charset val="1"/><scheme val="minor"/><vertAlign val="superscript"/></font></fonts><fills count="4"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FFFFFF00"/><bgColor indexed="64"/></patternFill></fill><fill><patternFill patternType="gray125"><fgColor theme="5"/><bgColor rgb="FF0000FF"/></patternFill></fill><fill><gradientFill degree="90"><stop position="0"><color rgb="FFFF0000"/></stop><stop position="1"><color rgb="FF0000FF"/></stop></gradientFill></fill></fills><borders count="3"><border><left/><right/><top/><bottom/><diagonal/></border><border><left style="thin"><color rgb="FF0000FF"/></left><right style="medium"><color theme="4"/></right><top style="dashed"><color indexed="10"/></top><bottom style="thin"><color rgb="FF00FF00"/></bottom><diagonal/></border><border diagonalUp="1" diagonalDown="1"><left/><right/><top/><bottom/><diagonal style="thin"><color rgb="FFFF0000"/></diagonal></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="5"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="164" fontId="0" fillId="1" borderId="1" xfId="0" applyNumberFormat="1" applyFont="1" applyFill="1" applyBorder="1"><alignment horizontal="center" vertical="center" wrapText="1"/><protection locked="1" hidden="0"/></xf><xf numFmtId="0" fontId="1" fillId="3" borderId="0" xfId="0"><alignment horizontal="right" indent="2" shrinkToFit="1" textRotation="45"/></xf><xf numFmtId="0" fontId="2" fillId="2" borderId="2" xfId="0" applyFont="0"><alignment vertical="top"/></xf><xf numFmtId="0" fontId="3" fillId="0" borderId="0" xfId="0" applyFill="0" applyBorder="0"/></cellXfs><colors><indexedColors><rgbColor rgb="FF000000"/><rgbColor rgb="FFFFFFFF"/><rgbColor rgb="FFFF0000"/><rgbColor rgb="FF00FF00"/><rgbColor rgb="FF0000FF"/><rgbColor rgb="FFFFFF00"/><rgbColor rgb="FFFF00FF"/><rgbColor rgb="FF00FFFF"/><rgbColor rgb="FF800000"/><rgbColor rgb="FF008000"/><rgbColor rgb="FFABCDEF"/><rgbColor rgb="FF112233"/><rgbColor rgb="FF123456"/></indexedColors></colors></styleSheet>"""

const Theme = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Office Theme"><a:themeElements><a:clrScheme name="Office"><a:lt1><a:sysClr windowText="windowText" val="windowText" lastClr="FFFFFF"/></a:lt1><a:dk1><a:sysClr window="window" val="window" lastClr="000000"/></a:dk1><a:lt2><a:srgbClr val="E7E6E6"/></a:lt2><a:dk2><a:srgbClr val="44546A"/></a:dk2><a:accent1><a:srgbClr val="4472C4"/></a:accent1><a:accent2><a:srgbClr val="ED7D31"/></a:accent2><a:accent3><a:srgbClr val="A5A5A5"/></a:accent3><a:accent4><a:srgbClr val="FFC000"/></a:accent4><a:accent5><a:srgbClr val="5B9D5B"/></a:accent5><a:accent6><a:srgbClr val="70AD47"/></a:accent6><a:hlink><a:srgbClr val="0563C1"/></a:hlink><a:folHlink><a:srgbClr val="954F72"/></a:folHlink></a:clrScheme><a:fmtScheme name="Office"><a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:fillStyleLst></a:fmtScheme></a:themeElements></a:theme>"""

const Sheet = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="""" & NsMain & """"><dimension ref="A1:A5"/><sheetData><row r="1"><c r="A1" s="1"><v>1234.5</v></c></row><row r="2"><c r="A2" s="2"><v>themed</v></c><c r="B2"><v>plain</v></c></row><row r="3"><c r="A3" s="3"><v>42</v></c></row><row r="4"><c r="A4" s="4"><v>styled</v></c></row><row r="5"><c r="A5" s="1"><v>merged</v></c></row></sheetData><mergeCells count="1"><mergeCell ref="A5:B5"/></mergeCells></worksheet>"""

proc main() =
  var w = newZipWriter()
  w.addFile("[Content_Types].xml",
    """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/><Override PartName="/xl/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/></Types>""")
  w.addFile("_rels/.rels",
    """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>""")
  w.addFile("xl/workbook.xml",
    """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="""" & NsMain & """" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Style" sheetId="1" r:id="rId1"/></sheets></workbook>""")
  w.addFile("xl/_rels/workbook.xml.rels",
    """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="theme/theme1.xml"/></Relationships>""")
  w.addFile("xl/worksheets/sheet1.xml", Sheet)
  w.addFile("xl/styles.xml", Styles)
  w.addFile("xl/theme/theme1.xml", Theme)
  w.writeZip(OutDir / "styles_full.xlsx")
  echo "wrote ", OutDir / "styles_full.xlsx"

main()
