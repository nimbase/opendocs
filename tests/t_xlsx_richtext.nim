## Rich-text reader tests.
##
## Fixtures are minimal synthetic workbooks from
## `tests/gen_xlsx_richtext.nim` (checked in, rerun the generator after
## any reader change):
## - `richtext_basic.xlsx`: shared runs (plain/bold/superscript), a
##   plain-`<t>` string, empty runs, full `rPr` extras, an inline cell,
##   a merge over the rich anchor, and a number cell.
## - `richtext_inline.xlsx`: inline-only shapes with preserved spaces.
## - `richtext_colortheme.xlsx`: theme, indexed, auto, and ARGB colors.
## - `richtext_edge.xlsx`: no theme part, phonetic hints, off flags.

import std/[unittest]
import openparser/colors
import opendocs/xlsx

const RichDir = "tests/fixtures/xlsx/"

func rgb(c: Color): tuple[r, g, b: int] =
  let t = c.toRgb()
  (t.r, t.g, t.b)

suite "rich runs, shared strings":
  test "runs keep order, fonts attach per run":
    let f = openXlsx(RichDir & "richtext_basic.xlsx")
    defer: f.closeXlsx()
    let runs = f.getCellRichText("Sheet1", "A1")
    check runs.len == 3
    check runs[0].text == "plain"
    check not runs[0].hasFont
    check runs[1].text == "Bold"
    check runs[1].hasFont
    check runs[1].font.bold
    check not runs[1].font.italic
    check runs[1].font.size == 14.0
    check runs[1].font.name == "Calibri"
    check rgb(runs[1].font.color) == (255, 0, 0)
    check runs[2].text == "super"
    check runs[2].font.italic
    check runs[2].font.vertAlign == "superscript"

  test "plain t-only string is one unformatted run":
    let f = openXlsx(RichDir & "richtext_basic.xlsx")
    defer: f.closeXlsx()
    let runs = f.getCellRichText("Sheet1", "A2")
    check runs.len == 1
    check runs[0].text == "Just text"
    check not runs[0].hasFont

  test "empty runs and off flags":
    let f = openXlsx(RichDir & "richtext_basic.xlsx")
    defer: f.closeXlsx()
    let runs = f.getCellRichText("Sheet1", "A3")
    check runs.len == 2
    check runs[0].text == ""
    check not runs[0].hasFont
    check runs[1].text == "x"
    check not runs[1].font.strike

  test "full rPr extras round-trip":
    let f = openXlsx(RichDir & "richtext_basic.xlsx")
    defer: f.closeXlsx()
    let runs = f.getCellRichText("Sheet1", "A4")
    check runs.len == 1
    let ft = runs[0].font
    check runs[0].hasFont
    check ft.underline == "single" # bare <u/> means single
    check ft.charset == 134
    check ft.hasCharset
    check ft.family == 2
    check ft.hasFamily
    check ft.scheme == "minor"
    check ft.outline
    check ft.shadow
    check ft.condense
    check ft.extend

  test "explicit underline and subscript":
    let f = openXlsx(RichDir & "richtext_basic.xlsx")
    defer: f.closeXlsx()
    let runs = f.getCellRichText("Sheet1", "A5")
    check runs.len == 1
    check runs[0].font.underline == "double"
    check runs[0].font.vertAlign == "subscript"
    check runs[0].font.size == 9.0

  test "spaced text survives":
    let f = openXlsx(RichDir & "richtext_basic.xlsx")
    defer: f.closeXlsx()
    check f.getCellValue("Sheet1", "B6") == " spaced "
    let runs = f.getCellRichText("Sheet1", "B6")
    check runs.len == 1
    check runs[0].text == " spaced "

  test "getCellValue still concatenates":
    let f = openXlsx(RichDir & "richtext_basic.xlsx")
    defer: f.closeXlsx()
    check f.getCellValue("Sheet1", "A1") == "plainBoldsuper"

suite "rich runs, inline strings":
  test "inline runs mirror shared shapes":
    let f = openXlsx(RichDir & "richtext_basic.xlsx")
    defer: f.closeXlsx()
    let runs = f.getCellRichText("Sheet1", "B5")
    check runs.len == 2
    check runs[0].text == "Inline bold"
    check runs[0].font.bold # bare <b/> is true (OOXML, not excelize)
    check runs[0].font.size == 12.0
    check runs[1].text == " tail"
    check not runs[1].hasFont
    check f.getCellValue("Sheet1", "B5") == "Inline bold tail"

  test "inline-only file with preserved spaces":
    let f = openXlsx(RichDir & "richtext_inline.xlsx")
    defer: f.closeXlsx()
    let runs = f.getCellRichText("Sheet1", "A1")
    check runs.len == 2
    check runs[0].text == "Green "
    check rgb(runs[0].font.color) == (0, 255, 0)
    check runs[0].font.name == "Arial"
    check runs[1].text == "plain"
    check not runs[1].hasFont

  test "whole inline string is one unformatted run":
    let f = openXlsx(RichDir & "richtext_inline.xlsx")
    defer: f.closeXlsx()
    let runs = f.getCellRichText("Sheet1", "A2")
    check runs.len == 1
    check runs[0].text == "Whole"
    check not runs[0].hasFont

suite "rich colors":
  test "theme, indexed, auto, and ARGB resolve":
    let f = openXlsx(RichDir & "richtext_colortheme.xlsx")
    defer: f.closeXlsx()
    # accent1 4472C4 at tint 0.5 (matches excelize ThemeColor).
    check rgb(f.getCellRichText("Sheet1", "A1")[0].font.color) ==
      (0xA2, 0xB8, 0xE2)
    # dk1, no tint.
    check rgb(f.getCellRichText("Sheet1", "A2")[0].font.color) == (0, 0, 0)
    # Indexed palette entry 10 is red.
    check rgb(f.getCellRichText("Sheet1", "A3")[0].font.color) ==
      (255, 0, 0)
    # Automatic resolves like excelize (indexed 0: black).
    check rgb(f.getCellRichText("Sheet1", "A4")[0].font.color) == (0, 0, 0)
    # 8-digit rgb honors alpha (diverges from excelize's first-six read).
    let g = f.getCellRichText("Sheet1", "A5")[0].font.color
    check rgb(g) == (0, 255, 0)
    check g.a == 1.0
    let h = f.getCellRichText("Sheet1", "A6")[0].font.color
    check rgb(h) == (0x11, 0x22, 0x33)
    check abs(h.a - 128.0 / 255.0) < 1e-9

  test "missing theme part invalidates colors":
    let f = openXlsx(RichDir & "richtext_edge.xlsx")
    defer: f.closeXlsx()
    let runs = f.getCellRichText("Sheet1", "A1")
    check runs.len == 1
    check not runs[0].font.color.valid

suite "rich edge cases":
  test "phonetic hints are not runs":
    let f = openXlsx(RichDir & "richtext_edge.xlsx")
    defer: f.closeXlsx()
    let runs = f.getCellRichText("Sheet1", "A2")
    check runs.len == 1
    check runs[0].text == "Plain"
    check not runs[0].hasFont

  test "explicit off flags stay off":
    let f = openXlsx(RichDir & "richtext_edge.xlsx")
    defer: f.closeXlsx()
    let runs = f.getCellRichText("Sheet1", "A3")
    check runs.len == 1
    check not runs[0].font.bold
    check not runs[0].font.italic

  test "non-string cells and absent cells have no runs":
    let f = openXlsx(RichDir & "richtext_basic.xlsx")
    defer: f.closeXlsx()
    check f.getCellRichText("Sheet1", "A6").len == 0 # number cell
    check f.getCellRichText("Sheet1", "Z9").len == 0 # absent cell

  test "merge-covered cells report the anchor's runs":
    let f = openXlsx(RichDir & "richtext_basic.xlsx")
    defer: f.closeXlsx()
    check f.isMerged("Sheet1", "B2")
    let runs = f.getCellRichText("Sheet1", "B2")
    check runs.len == 3
    check runs[1].text == "Bold"

  test "dangling shared-string index raises":
    let f = openXlsx(RichDir & "richtext_edge.xlsx")
    defer: f.closeXlsx()
    expect(XlsxError):
      discard f.getCellRichText("Sheet1", "A9")
