## Rich-text fixture generator (run manually, not a test).
##
## Writes minimal synthetic workbooks under tests/fixtures/xlsx/ for the
## rich-text reader. Fixtures are checked in so tests stay hermetic;
## rerun after any reader change:
##   clue run tests/gen_xlsx_richtext.nim   (or build + exec)
##
## Origin: synthetic, generated locally by this script. No licensing
## concerns.

import std/os
import std/strutils
import ../src/opendocs/zip

const OutDir = "tests/fixtures/xlsx"

const ContentTypes = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>THEME_CT<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/></Types>"""

const Rels = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>"""

const WbRels = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/>THEME_REL</Relationships>"""

const Workbook = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>"""

const Styles = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts><fills count="1"><fill><patternFill patternType="none"/></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs></styleSheet>"""

const Theme = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Office Theme"><a:themeElements><a:clrScheme name="Office"><a:lt1><a:sysClr windowText="windowText" val="windowText" lastClr="FFFFFF"/></a:lt1><a:dk1><a:sysClr window="window" val="window" lastClr="000000"/></a:dk1><a:lt2><a:srgbClr val="E7E6E6"/></a:lt2><a:dk2><a:srgbClr val="44546A"/></a:dk2><a:accent1><a:srgbClr val="4472C4"/></a:accent1><a:accent2><a:srgbClr val="ED7D31"/></a:accent2><a:accent3><a:srgbClr val="A5A5A5"/></a:accent3><a:accent4><a:srgbClr val="FFC000"/></a:accent4><a:accent5><a:srgbClr val="5B9D5B"/></a:accent5><a:accent6><a:srgbClr val="70AD47"/></a:accent6><a:hlink><a:srgbClr val="0563C1"/></a:hlink><a:folHlink><a:srgbClr val="954F72"/></a:folHlink></a:clrScheme><a:fmtScheme name="Office"><a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:fillStyleLst></a:fmtScheme></a:themeElements></a:theme>"""

proc writeBook(path, sheet, sst: string, withTheme: bool) =
  var w = newZipWriter()
  var ct = ContentTypes
  var rels = WbRels
  if withTheme:
    ct = ct.replace("THEME_CT",
      """<Override PartName="/xl/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>""")
    rels = rels.replace("THEME_REL",
      """<Relationship Id="rId4" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="theme/theme1.xml"/>""")
  else:
    ct = ct.replace("THEME_CT", "")
    rels = rels.replace("THEME_REL", "")
  w.addFile("[Content_Types].xml", ct)
  w.addFile("_rels/.rels", Rels)
  w.addFile("xl/workbook.xml", Workbook)
  w.addFile("xl/_rels/workbook.xml.rels", rels)
  w.addFile("xl/worksheets/sheet1.xml", sheet)
  w.addFile("xl/sharedStrings.xml", sst)
  w.addFile("xl/styles.xml", Styles)
  if withTheme:
    w.addFile("xl/theme/theme1.xml", Theme)
  w.writeZip(OutDir / path)
  echo "wrote ", OutDir / path

proc sheetWrap(rows, extra = ""): string =
  """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><dimension ref="A1:B6"/><sheetData>""" &
    rows & "</sheetData>" & extra & "</worksheet>"

proc sstWrap(items: string): string =
  """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="6" uniqueCount="6">""" &
    items & "</sst>"

proc basic() =
  let sst = sstWrap(
    """<si><r><t>plain</t></r><r><rPr><b/><sz val="14"/><color rgb="FFFF0000"/><rFont val="Calibri"/></rPr><t>Bold</t></r><r><rPr><i/><vertAlign val="superscript"/></rPr><t>super</t></r></si>""" &
    """<si><t>Just text</t></si>""" &
    """<si><r><t></t></r><r><rPr><strike val="0"/></rPr><t>x</t></r></si>""" &
    """<si><r><rPr><u/><charset val="134"/><family val="2"/><scheme val="minor"/><outline/><shadow/><condense/><extend/></rPr><t>Full</t></r></si>""" &
    """<si><r><rPr><u val="double"/><vertAlign val="subscript"/><sz val="9"/></rPr><t>sub</t></r></si>""" &
    """<si><t xml:space="preserve"> spaced </t></si>""")
  let sheet = sheetWrap(
    """<row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>0</v></c></row>""" &
    """<row r="2"><c r="A2" t="s"><v>1</v></c></row>""" &
    """<row r="3"><c r="A3" t="s"><v>2</v></c></row>""" &
    """<row r="4"><c r="A4" t="s"><v>3</v></c></row>""" &
    """<row r="5"><c r="A5" t="s"><v>4</v></c><c r="B5" t="inlineStr"><is><r><rPr><b/><sz val="12"/></rPr><t>Inline bold</t></r><r><t> tail</t></r></is></c></row>""" &
    """<row r="6"><c r="A6" t="n"><v>42</v></c><c r="B6" t="s"><v>5</v></c></row>""",
    """<mergeCells count="1"><mergeCell ref="B1:B2"/></mergeCells>""")
  writeBook("richtext_basic.xlsx", sheet, sst, true)

proc inlines() =
  let sst = sstWrap("""<si><t>unused</t></si>""")
  let sheet = sheetWrap(
    """<row r="1"><c r="A1" t="inlineStr"><is><r><rPr><color rgb="FF00FF00"/><rFont val="Arial"/></rPr><t xml:space="preserve">Green </t></r><r><t>plain</t></r></is></c></row>""" &
    """<row r="2"><c r="A2" t="inlineStr"><is><t>Whole</t></is></c></row>""" &
    """<row r="3"><c r="A3"><v>7</v></c></row>""")
  writeBook("richtext_inline.xlsx", sheet, sst, true)

proc colors() =
  let sst = sstWrap(
    """<si><r><rPr><color theme="4" tint="0.5"/></rPr><t>Accent light</t></r></si>""" &
    """<si><r><rPr><color theme="1"/></rPr><t>Dark</t></r></si>""" &
    """<si><r><rPr><color indexed="10"/></rPr><t>Indexed red</t></r></si>""" &
    """<si><r><rPr><color auto="1"/></rPr><t>Automatic</t></r></si>""" &
    """<si><r><rPr><color rgb="FF00FF00"/></rPr><t>Alpha green</t></r></si>""" &
    """<si><r><rPr><color rgb="80112233"/></rPr><t>Half custom</t></r></si>""")
  let sheet = sheetWrap(
    """<row r="1"><c r="A1" t="s"><v>0</v></c></row>""" &
    """<row r="2"><c r="A2" t="s"><v>1</v></c></row>""" &
    """<row r="3"><c r="A3" t="s"><v>2</v></c></row>""" &
    """<row r="4"><c r="A4" t="s"><v>3</v></c></row>""" &
    """<row r="5"><c r="A5" t="s"><v>4</v></c></row>""" &
    """<row r="6"><c r="A6" t="s"><v>5</v></c></row>""")
  writeBook("richtext_colortheme.xlsx", sheet, sst, true)

proc edge() =
  # No theme part: all colors resolve invalid. rPh ignored. Bad index.
  let sst = sstWrap(
    """<si><r><rPr><color theme="4" tint="0.5"/></rPr><t>No theme here</t></r></si>""" &
    """<si><t>Plain</t><rPh sb="0" eb="1"><t>hint</t></rPh></si>""" &
    """<si><r><rPr><b val="false"/><i val="0"/></rPr><t>Off flags</t></r></si>""" &
    """<si><t></t></si>""" &
    """<si><t>x</t></si>""" &
    """<si><t>y</t></si>""")
  let sheet = sheetWrap(
    """<row r="1"><c r="A1" t="s"><v>0</v></c></row>""" &
    """<row r="2"><c r="A2" t="s"><v>1</v></c></row>""" &
    """<row r="3"><c r="A3" t="s"><v>2</v></c></row>""" &
    """<row r="4"><c r="A4" t="s"><v>3</v></c></row>""" &
    """<row r="9"><c r="A9" t="s"><v>99</v></c></row>""")
  writeBook("richtext_edge.xlsx", sheet, sst, false)

basic()
inlines()
colors()
edge()
