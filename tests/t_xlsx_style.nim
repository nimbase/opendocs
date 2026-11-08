## Style-record tests (P6).
##
## `styles_full.xlsx` (built by `tests/gen_xlsx_style.nim`) exercises
## fonts (rgb/theme-tint/indexed/extras), fills (pattern/gradient),
## borders (all edges, theme/indexed colors, diagonal flags), alignment,
## protection, `apply*` opt-outs, custom number formats on styles, and
## merged-cell style lookup. Expected colors were verified against
## excelize (`GetStyle` + `ThemeColor`); border-style and pattern names
## are asserted as raw OOXML strings (excelize exposes enum indexes
## instead — a deliberate, documented divergence).

import std/[unittest, strutils]
import openparser/colors
import opendocs/xlsx
import opendocs/zip

const StyleDir = "tests/fixtures/xlsx/"

func rgb(c: Color): tuple[r, g, b: int] =
  let t = c.toRgb()
  (t.r, t.g, t.b)

suite "style fonts":
  test "rgb font parses fully":
    let f = openXlsx(StyleDir & "styles_full.xlsx")
    defer: f.closeXlsx()
    let st = f.getStyle(1)
    check st.hasFont
    check st.font.name == "Calibri"
    check st.font.size == 14.0
    check st.font.bold
    check not st.font.italic
    check rgb(st.font.color) == (255, 0, 0)

  test "theme color with tint resolves bit-exact":
    let f = openXlsx(StyleDir & "styles_full.xlsx")
    defer: f.closeXlsx()
    let st = f.getStyle(2)
    check st.font.name == "Arial"
    check st.font.italic
    check st.font.underline == "single"
    # accent1 4472C4 at tint -0.5 (matches excelize ThemeColor).
    check rgb(st.font.color) == (0x20, 0x38, 0x64)

  test "applyFont opt-out reports no font":
    let f = openXlsx(StyleDir & "styles_full.xlsx")
    defer: f.closeXlsx()
    check not f.getStyle(3).hasFont

  test "custom indexed palette wins over the default":
    let f = openXlsx(StyleDir & "styles_full.xlsx")
    defer: f.closeXlsx()
    # indexed 12 hits the custom entry, not default palette blue.
    check rgb(f.styles.fonts[2].color) == (0x12, 0x34, 0x56)

  test "font extras parse":
    let f = openXlsx(StyleDir & "styles_full.xlsx")
    defer: f.closeXlsx()
    let ft = f.getStyle(4).font
    check rgb(ft.color) == (0, 255, 0)
    check ft.vertAlign == "superscript"
    check ft.scheme == "minor"
    check ft.hasFamily and ft.family == 2
    check ft.hasCharset and ft.charset == 1

suite "style fills":
  test "pattern fill with indexed bg":
    let f = openXlsx(StyleDir & "styles_full.xlsx")
    defer: f.closeXlsx()
    let fl = f.getStyle(1).fill
    check fl.kind == "pattern"
    check fl.pattern == "solid"
    check rgb(fl.fgColor) == (255, 255, 0)
    # indexed 64 falls back to the default palette (black).
    check rgb(fl.bgColor) == (0, 0, 0)

  test "theme fg resolves in fills":
    let f = openXlsx(StyleDir & "styles_full.xlsx")
    defer: f.closeXlsx()
    let fl = f.styles.fills[2]
    check fl.pattern == "gray125"
    # accent2 ED7D31, no tint.
    check rgb(fl.fgColor) == (0xED, 0x7D, 0x31)
    check rgb(fl.bgColor) == (0, 0, 255)

  test "gradient fill keeps stops and shading":
    let f = openXlsx(StyleDir & "styles_full.xlsx")
    defer: f.closeXlsx()
    let fl = f.getStyle(2).fill
    check fl.kind == "gradient"
    check fl.gradientDegree == 90.0
    check fl.gradientColors.len == 2
    check rgb(fl.gradientColors[0]) == (255, 0, 0)
    check rgb(fl.gradientColors[1]) == (0, 0, 255)
    # First styleFillVariants entry (degree 90, two stops).
    check fl.shading == 0

  test "applyFill opt-out reports no fill":
    let f = openXlsx(StyleDir & "styles_full.xlsx")
    defer: f.closeXlsx()
    check not f.getStyle(4).hasFill

suite "style borders":
  test "edges keep style names and resolved colors":
    let f = openXlsx(StyleDir & "styles_full.xlsx")
    defer: f.closeXlsx()
    let b = f.getStyle(1).border
    check b.left.style == "thin"
    check rgb(b.left.color) == (0, 0, 255)
    check b.right.style == "medium"
    # theme accent1, no tint.
    check rgb(b.right.color) == (0x44, 0x72, 0xC4)
    check b.top.style == "dashed"
    # indexed 10 hits the custom entry, not default dark red.
    check rgb(b.top.color) == (0xAB, 0xCD, 0xEF)
    check b.bottom.style == "thin"
    check rgb(b.bottom.color) == (0, 255, 0)

  test "diagonal flags and edge parse":
    let f = openXlsx(StyleDir & "styles_full.xlsx")
    defer: f.closeXlsx()
    let b = f.getStyle(3).border
    check b.diagonalUp and b.diagonalDown
    check b.diagonal.style == "thin"
    check rgb(b.diagonal.color) == (255, 0, 0)

  test "applyBorder opt-out reports no border":
    let f = openXlsx(StyleDir & "styles_full.xlsx")
    defer: f.closeXlsx()
    check not f.getStyle(4).hasBorder

suite "style alignment and protection":
  test "alignment and protection round-trip":
    let f = openXlsx(StyleDir & "styles_full.xlsx")
    defer: f.closeXlsx()
    let st = f.getStyle(1)
    check st.hasAlignment
    check st.alignment.horizontal == "center"
    check st.alignment.vertical == "center"
    check st.alignment.wrapText
    check st.hasProtection
    check st.protection.locked
    check not st.protection.hidden

  test "partial alignment keeps defaults":
    let f = openXlsx(StyleDir & "styles_full.xlsx")
    defer: f.closeXlsx()
    let a = f.getStyle(2).alignment
    check a.horizontal == "right"
    check a.vertical == ""
    check a.indent == 2
    check a.shrinkToFit
    check a.textRotation == 45

  test "absent alignment and protection report false":
    let f = openXlsx(StyleDir & "styles_full.xlsx")
    defer: f.closeXlsx()
    check not f.getStyle(0).hasAlignment
    check not f.getStyle(0).hasProtection

suite "cell-level style lookup":
  test "cells resolve through their xf":
    let f = openXlsx(StyleDir & "styles_full.xlsx")
    defer: f.closeXlsx()
    check f.getCellStyleIdx("Style", "A1") == 1
    check f.getCellStyle("Style", "A1").numFmtId == 164
    check f.getCellValue("Style", "A1") == "1234.50"
    check f.getCellStyle("Style", "A2").font.name == "Arial"

  test "merged cells report the anchor style":
    let f = openXlsx(StyleDir & "styles_full.xlsx")
    defer: f.closeXlsx()
    check f.isMerged("Style", "B5")
    check f.getCellStyleIdx("Style", "B5") ==
      f.getCellStyleIdx("Style", "A5")
    check f.getCellStyle("Style", "B5").hasFont

  test "unstyled cells resolve to xf 0":
    let f = openXlsx(StyleDir & "styles_full.xlsx")
    defer: f.closeXlsx()
    check f.getCellStyleIdx("Style", "B2") == 0
    check f.getCellStyle("Style", "B2").hasFont

  test "absent cells resolve to xf 0":
    let f = openXlsx(StyleDir & "styles_full.xlsx")
    defer: f.closeXlsx()
    check f.getCellStyleIdx("Style", "Z9") == 0

  test "out-of-range style index reads default":
    let pkg = block:
      var w = newZipWriter()
      const NsMain = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
      const NsPkg = "http://schemas.openxmlformats.org/package/2006/relationships"
      const NsRel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
      w.addFile("_rels/.rels", """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="""" & NsPkg & """"><Relationship Id="rId1" Type="""" & NsRel & """/officeDocument" Target="xl/workbook.xml"/></Relationships>""")
      w.addFile("xl/workbook.xml", """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="""" & NsMain & """" xmlns:r="""" & NsRel & """"><sheets><sheet name="S" sheetId="1" r:id="rId1"/></sheets></workbook>""")
      w.addFile("xl/_rels/workbook.xml.rels", """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="""" & NsPkg & """"><Relationship Id="rId1" Type="""" & NsRel & """/worksheet" Target="worksheets/sheet1.xml"/></Relationships>""")
      w.addFile("xl/worksheets/sheet1.xml", """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="""" & NsMain & """"><sheetData><row r="1"><c r="A1" s="99"><v>7</v></c></row></sheetData></worksheet>""")
      w.addFile("xl/styles.xml", """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="""" & NsMain & """"><cellXfs count="1"><xf numFmtId="0"/></cellXfs></styleSheet>""")
      w.toBytes()
    let f = openXlsxBytes(pkg)
    defer: f.closeXlsx()
    check f.getCellValue("S", "A1") == "7"
    let st = f.getCellStyle("S", "A1")
    check st.numFmtId == 0
    check not st.hasFont and not st.hasFill and not st.hasBorder

  test "getStyle out of range raises":
    let f = openXlsx(StyleDir & "styles_full.xlsx")
    defer: f.closeXlsx()
    expect XlsxError:
      discard f.getStyle(99)
    expect XlsxError:
      discard f.getStyle(-1)

  test "missing styles part reads default":
    let pkg = block:
      var w = newZipWriter()
      const NsMain = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
      const NsPkg = "http://schemas.openxmlformats.org/package/2006/relationships"
      const NsRel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
      w.addFile("_rels/.rels", """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="""" & NsPkg & """"><Relationship Id="rId1" Type="""" & NsRel & """/officeDocument" Target="xl/workbook.xml"/></Relationships>""")
      w.addFile("xl/workbook.xml", """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="""" & NsMain & """" xmlns:r="""" & NsRel & """"><sheets><sheet name="S" sheetId="1" r:id="rId1"/></sheets></workbook>""")
      w.addFile("xl/_rels/workbook.xml.rels", """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="""" & NsPkg & """"><Relationship Id="rId1" Type="""" & NsRel & """/worksheet" Target="worksheets/sheet1.xml"/></Relationships>""")
      w.addFile("xl/worksheets/sheet1.xml", """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="""" & NsMain & """"><sheetData><row r="1"><c r="A1" s="3"><v>7</v></c></row></sheetData></worksheet>""")
      w.toBytes()
    let f = openXlsxBytes(pkg)
    defer: f.closeXlsx()
    let st = f.getCellStyle("S", "A1")
    check st.numFmtId == 0
    check not st.hasFont

suite "stylesheets stay total":
  test "style ids survive, formatting unaffected":
    let f = openXlsx(StyleDir & "styles_full.xlsx")
    defer: f.closeXlsx()
    check f.styles.fonts.len == 4
    check f.styles.fills.len == 4
    check f.styles.borders.len == 3
    check f.styles.cellXfs.len == 5
    check f.styles.cellXfs[1].numFmtId == 164
