## Format-code tokenizer tests.
##
## P1 covers parsing only: stable codes must round-trip, pinned reference
## quirks are asserted explicitly, and invalid separator counts fail loudly.
## No formatted values change here; the Phase B matrix guards behavior.

import std/[unittest]
import opendocs/xlsx

const StableCodes = [
  "0",
  "0.00",
  "#,##0",
  "#,##0.00",
  "0%",
  "0.00%",
  "0.00E+00",
  "# ?/?",
  "# ??/??",
  "mm-dd-yy",
  "h:mm:ss AM/PM",
  "[h]:mm:ss",
  "[$-409]m/d/yy",
  "[DBNum1]0",
  "[Red]0.00",
  "[<=5]0",
  "General",
  "@",
  "0;-0;\"zero\";@",
  "_(* #,##0_)",
  "*-0",
  "\\-0",
  "_(0",
  "B1",
  "B2",
  "0.00E-00",
  "0;;0",
  "0;",
  ";;;",
  "0;@",
  "\"abc\"",
  "\"high\";\"low\"",
]

func sectionKinds(ast: NumFmtAst): seq[string] =
  for sec in ast.sections: result.add sec.kind

func tokenShapes(ast: NumFmtAst, section: int): seq[(string, string)] =
  for item in ast.sections[section].items:
    result.add (item.kind, item.text)

suite "tokenizer round-trip":
  test "stable codes parse and reconstruct exactly":
    for code in StableCodes:
      let ast = parseNumFmt(code)
      check ast.ok
      check renderNumFmt(ast) == code

  test "empty and skipped sections survive":
    check renderNumFmt(parseNumFmt("0;;0")) == "0;;0"
    check sectionKinds(parseNumFmt("0;;0")) == @["Positive", "Negative",
      "Zero"]
    check renderNumFmt(parseNumFmt(";;;")) == ";;;"

  test "at marks the current section as text":
    let ast = parseNumFmt("0;@")
    check ast.ok
    check sectionKinds(ast) == @["Positive", "Text"]
    check tokenShapes(ast, 1) == @[("TextPlaceHolder", "@")]

suite "token shapes":
  test "scientific codes distinguish E+ from E-":
    let plus = parseNumFmt("0.00E+00")
    check plus.ok
    check ("Exponential", "E+") in tokenShapes(plus, 0)
    let minus = parseNumFmt("0.00E-00")
    check minus.ok
    check ("Exponential", "E+") notin tokenShapes(minus, 0)
    check ("DateTimes", "E") in tokenShapes(minus, 0)
    check ("Literal", "-") in tokenShapes(minus, 0)

  test "brackets carry conditions, locales, colors, and switches":
    let cond = parseNumFmt("[<=5]0")
    check cond.ok
    check cond.sections[0].items[0].kind == "Condition"
    check cond.sections[0].items[0].text == "<=5"
    check cond.sections[0].items[0].parts ==
      @[NumFmtPart(kind: "Operator", value: "<="),
        NumFmtPart(kind: "Operand", value: "5")]
    let locale = parseNumFmt("[$-409]m/d/yy")
    check locale.ok
    check locale.sections[0].items[0].kind == "CurrencyLanguage"
    check locale.sections[0].items[0].text == "$-409"
    check locale.sections[0].items[0].parts ==
      @[NumFmtPart(kind: "LanguageInfo", value: "409")]
    let color = parseNumFmt("[Red]0.00")
    check (color.sections[0].items[0].kind,
      color.sections[0].items[0].text) == ("Color", "Red")
    let sw = parseNumFmt("[DBNum1]0")
    check (sw.sections[0].items[0].kind,
      sw.sections[0].items[0].text) == ("SwitchArgument", "DBNum1")
    let elapsed = parseNumFmt("[h]:mm:ss")
    check (elapsed.sections[0].items[0].kind,
      elapsed.sections[0].items[0].text) == ("ElapsedDateTimes", "h")

  test "B1 and B2 stay together, other B prefixes do not":
    check tokenShapes(parseNumFmt("B1"), 0) == @[("DateTimes", "B1")]
    check tokenShapes(parseNumFmt("B2"), 0) == @[("DateTimes", "B2")]
    check tokenShapes(parseNumFmt("B3"), 0) == @[("Literal", "B3")]

suite "reference quirks":
  test "quoted digits split like the pinned parser":
    let ast = parseNumFmt("\"a1\"")
    check ast.ok
    check tokenShapes(ast, 0) == @[("Literal", "a"), ("Literal", "1")]
    check renderNumFmt(ast) == "\"a\"\"1\""

  test "quoted semicolons split sections like the pinned parser":
    let ast = parseNumFmt("\"a;b\"0")
    check ast.ok
    check sectionKinds(ast) == @["Positive", "Negative"]
    check tokenShapes(ast, 0) == @[("Literal", "a")]
    check tokenShapes(ast, 1) == @[("Literal", "b"),
      ("ZeroPlaceHolder", "0")]

  test "more than four sections is invalid":
    let ast = parseNumFmt("0;0;0;0;0")
    check not ast.ok
    check ast.sections.len == 0
