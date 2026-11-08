## Custom number-format rendering tests.
##
## P2 covers the previously raw custom path: section selection,
## number/date/fraction/scientific/text rendering, scaling commas,
## dropped colors/conditions/locales, and alignment padding. Every
## `(code, value)` pair below was verified against excelize
## (`GetCellValue`) before freezing; `fmt_custom.xlsx` (built by
## `tests/gen_xlsx_numfmt.nim`) covers the same ground end to end.
##
## Divergences from excelize, all documented in `xlsx/numfmt.nim`:
## bare booleans read true, 8-digit rgb honors alpha, theme colors
## resolve on runs, border styles and fill patterns surface as raw OOXML
## names (not enum indexes), and there is no `CultureInfo` option (so
## `ko-KR +2333` and the gannen code-info table are unreachable).
## Locale coverage lives in `t_xlsx_numfmt_locale.nim`.

import std/[unittest, tables]
import opendocs/xlsx

const CustomOracle = [
  ("0", "0", "0"), ("0", "5", "5"), ("0", "-5", "-5"), ("0", "1.5", "2"),
  ("0.00", "0", "0.00"), ("0.00", "1.5", "1.50"),
  ("0.00", "-1.5", "-1.50"), ("0.00", "123.456", "123.46"),
  ("#,##0", "0", "0"), ("#,##0", "1234", "1,234"),
  ("#,##0", "-1234", "-1,234"), ("#,##0", "1234567", "1,234,567"),
  ("#,##0.00", "1234.567", "1,234.57"),
  ("#,##0.00", "-1234.567", "-1,234.57"),
  ("#,##0.00", "0.1", "0.10"),
  ("0%", "0", "0%"), ("0%", "0.5", "50%"), ("0%", "1", "100%"),
  ("0%", "-0.25", "-25%"),
  ("0.00%", "0.1234", "12.34%"), ("0.00%", "-0.1234", "-12.34%"),
  ("# ?/?", "1.5", "1 1/2"), ("# ?/?", "0.25", "0 1/4"),
  ("# ?/?", "2.75", "2 3/4"), ("# ?/?", "-1.5", "-1 1/2"),
  ("# ??/??", "1.5", "1  1/2 "), ("# ??/??", "0.25", "0  1/4 "),
  ("# ??/??", "3.14159", "3  1/7 "),
  ("0.00E+00", "1234.5", "1.23E+03"),
  ("0.00E+00", "0.0001234", "1.23E-04"),
  ("0.00E+00", "-98765", "-9.88E+04"),
  ("0.00E+00", "0", "0.00E+00"),
  ("0.0E+0", "123.4", "123.4"),
  ("##0.0E+0", "123456", "123456"),
  ("\"$\"#,##0.00", "1234.5", "$1,234.50"),
  ("\"$\"#,##0.00", "-1234.5", "-$1,234.50"),
  ("_(* #,##0_);_(* (#,##0);_(* \"-\"_);_(@_)", "1234", " 1,234 "),
  ("_(* #,##0_);_(* (#,##0);_(* \"-\"_);_(@_)", "-1234", " (1,234)"),
  ("_(* #,##0_);_(* (#,##0);_(* \"-\"_);_(@_)", "0", " 0 "),
  ("[Red]0.00", "1.5", "1.50"), ("[Red]0.00", "-1.5", "-1.50"),
  ("0.00;[Red]-0.00", "1.5", "1.50"),
  ("0.00;[Red]-0.00", "-1.5", "-1.50"),
  ("#,##0_);(#,##0)", "1234", "1,234 "),
  ("#,##0_);(#,##0)", "-1234", "(1,234)"),
  ("\"a\"@\"b\"", "0", "0"),
  ("\\-0", "5", "-5"),
  ("0.0", "1.56", "1.6"), ("0.0", "1.54", "1.5"), ("0.0", "2", "2.0"),
  ("00.00", "1.5", "01.50"), ("00.00", "0.5", "00.50"),
  ("?.??", "1.5", " 2"),
  ("?.?", "1.56", "2"),
  ("#.##", "1.5", "1.5"), ("#.##", "1", "1"), ("#.##", "0", "0"),
  ("?.00", "1.5", "1.50"),
  ("0,", "1234567", "1235"), ("0,", "1234", "1"),
  ("0.0,", "1234567", "1234.6"),
  ("0.00,,", "1234567", "1.23"),
  ("0\"k\"", "1500", "1500k"),
  ("0;[Red]-0", "5", "5"), ("0;[Red]-0", "-5", "-5"),
  ("General", "1.5", "1.5"),
  ("General", "123456789012345", "1.23456789E+14"),
  ("@", "5", "5"),
  ("\"a\"", "5", "a"),
  ("0.000", "1.5", "1.500"),
  ("m/d/yy", "44927.5", "1/1/23"),
  ("m/d/yy", "1", "1/1/00"),
  ("m/d/yy", "0.5", "1/0/00"),
  ("[$-409]m/d/yy", "44927.5", "1/1/23"),
  ("[$-404]m/d/yy", "44927.5", "1/1/23"),
  ("h:mm:ss", "0.5", "12:00:00"),
  ("h:mm:ss", "44927.75", "18:00:00"),
  ("[h]:mm", "1.5", "36:00"),
  ("[h]:mm", "0.75", "18:00"),
  ("[mm]:ss", "0.075", "108:00"),
  ("mm:ss.000", "0.000789", "01:08.169"),
  ("yyyy-mm-dd", "44927", "2023-01-01"),
  ("ddd, mmm d", "44927", "Sun, Jan 1"),
  ("0;-0;\"zero\"", "5", "5"),
  ("0;-0;\"zero\"", "-5", "-5"),
  ("0;-0;\"zero\"", "0", "0"),
  ("0;;;0", "5", "5"),
  ("0;;;0", "-5", ""),
  ("[>100]\"high\";\"low\"", "50", "high"),
  ("[>100]\"high\";\"low\"", "150", "high"),
  ("[<100]\"low\";\"high\"", "50", "low"),
  ("[<100]\"low\";\"high\"", "150", "low"),
]

proc renderWith(code, value: string): tuple[applied: bool, text: string] =
  var st = XlsxStylesheet(
    numFmts: {164: code}.toTable, cellXfs: @[XlsxXf(fontId: -1,
      fillId: -1, borderId: -1, xfId: -1),
      XlsxXf(numFmtId: 164, fontId: -1, fillId: -1, borderId: -1,
        xfId: -1)])
  let f = XlsxFile(styles: st)
  let info = f.formatInfo(value, ctyNumber, 1)
  (info.applied, info.text)

suite "custom renderer oracle":
  test "every oracle pair renders exactly":
    for (code, val, want) in CustomOracle:
      let (applied, got) = renderWith(code, val)
      check got == want
      # applied tracks transformation, not section selection: plain
      # General and text-selected codes legitimately report false.

  test "applied tracks transformation, not selection":
    check renderWith("0.00", "1.5").applied
    check renderWith("General", "123456789012345").applied
    check not renderWith("General", "1.5").applied
    check not renderWith("@", "5").applied
    check renderWith("m/d/yy", "44927").applied
    check not renderWith("[$-XYZ]m/d/yy", "44927").applied

  test "text and zero-section selection":
    # Text values take the text section; zero falls back to Positive
    # (excelize parity: the zero section never matches).
    check renderWith("\"a\";\"b\"", "xyz").text == "xyz"
    check renderWith("0;-0;\"zero\"", "0").text == "0"
    check renderWith("@", "xyz").text == "xyz"

  test "unsupported locale tags in date sections stay raw":
    check renderWith("[$-XYZ]m/d/yy", "44927.5") == (false, "44927.5")

  test "malformed codes stay raw":
    check renderWith("0;;;;0", "5") == (false, "5")

suite "custom fixture end to end":
  const FmtDir = "tests/fixtures/xlsx/"
  test "fixture cells render":
    let f = openXlsx(FmtDir & "fmt_custom.xlsx")
    defer: f.closeXlsx()
    check f.getCellValue("Fmt", "A1") == "1.50"
    check f.getCellValue("Fmt", "A2") == "1,234,567"
    check f.getCellValue("Fmt", "A3") == "25%"
    check f.getCellValue("Fmt", "A4") == "2 3/4"
    check f.getCellValue("Fmt", "A5") == "1.23E+03"
    check f.getCellValue("Fmt", "A6") == "3"
    check f.getCellValue("Fmt", "A7") == "-1.50"
    check f.getCellValue("Fmt", "A8") == "1/1/23"
    check f.getCellValue("Fmt", "A9") == "12:00:00"
    check f.getCellValue("Fmt", "A10") == "108:00"
    check f.getCellValue("Fmt", "A11") == "01:08.169"
    check f.getCellValue("Fmt", "A12") == "1/1/23"
    check f.getCellValue("Fmt", "A13") == "1.5"
    check f.getCellValue("Fmt", "A14") == "hi"
    check f.getCellValue("Fmt", "A15") == "0"
    check f.getCellValue("Fmt", "A16") == "a"
    check f.getCellValue("Fmt", "A17") == "1500k"

  test "formatApplied tracks the fixture":
    let f = openXlsx(FmtDir & "fmt_custom.xlsx")
    defer: f.closeXlsx()
    check f.formatApplied("Fmt", "A1")
    check f.formatApplied("Fmt", "A8")
    check not f.formatApplied("Fmt", "Z9")
