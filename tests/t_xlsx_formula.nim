## Formula tokenizer tests (Plan 20 P1 + Plan 15 P5).
##
## `parseFormulaToks` is an exact port of xuri/efp `getTokens`
## (pinned commit 2ddeb826f9a9): every formula below was dumped
## from efp itself, so token shapes and renders are oracle, not
## hand expectations. `shared_formula.xlsx` (built by
## `tests/gen_xlsx_shared_formula.nim`) covers shared-formula
## expansion end to end against excelize `GetCellValue`.
##
## Deliberate efp quirks, all fixture-tested:
## - the first raw token is always dropped (zero-value cursor);
##   `=A1` and `A1` tokenize identically, `==A1` keeps one `=`.
## - quoted sheet names lose quotes on render; text literals lose
##   `"..."` doubling; `{1,2;3,4}` renders `ARRAY`-ese.
## - whitespace is only ASCII space; only single spaces can form
##   intersection operators.

import std/[strutils, unittest]
import opendocs/xlsx

const RenderOracle = [
  ("SUM(A1:A2)", "SUM(A1:A2)"),
  ("A1", "A1"),
  ("$A$1", "$A$1"),
  ("$A1", "$A1"),
  ("A$1", "A$1"),
  ("Sheet1!A1", "Sheet1!A1"),
  ("'My Sheet'!A1", "My Sheet!A1"),
  ("Sheet1:Sheet3!A1", "Sheet1:Sheet3!A1"),
  ("'S 1:S 3'!A1", "S 1:S 3!A1"),
  ("[1]Sheet1!A1", "[1]Sheet1!A1"),
  ("A:A", "A:A"),
  ("1:1", "1:1"),
  ("$A:B", "$A:B"),
  ("A$1:B$2", "A$1:B$2"),
  ("Sheet1!$A$1:$B$2", "Sheet1!$A$1:$B$2"),
  ("-A1", "-A1"),
  ("+A1", "A1"),
  ("--A1", "--A1"),
  ("A1+-B2", "A1+-B2"),
  ("A1%", "A1%"),
  ("20%", "20%"),
  ("\"a\"\"b\"", "\"a\"b\""),
  ("\"x\"", "\"x\""),
  ("IF(A1>0,\"y\",\"n\")", "IF(A1>0,\"y\",\"n\")"),
  ("SUM(A1,B2:C3)", "SUM(A1,B2:C3)"),
  ("A1 B2", "A1 B2"),
  ("A1,B2", "A1,B2"),
  ("#DIV/0!", "#DIV/0!"),
  ("#N/A", "#N/A"),
  ("#NAME?", "#NAME?"),
  ("#REF!", "#REF!"),
  ("#VALUE!", "#VALUE!"),
  ("#NUM!", "#NUM!"),
  ("#NULL!", "#NULL!"),
  ("#SPILL!", "#SPILL!"),
  ("#CALC!", "#CALC!"),
  ("#GETTING_DATA", "#GETTING_DATA"),
  ("{1,2;3,4}", "ARRAY(ARRAYROW(1,2),ARRAYROW(3,4))"),
  ("1E+10", "1E+10"),
  ("1.5E-3", "1.5E-3"),
  ("2^3^2", "2^3^2"),
  ("A1&B2", "A1&B2"),
  ("A1=B2", "A1=B2"),
  ("A1<>B2", "A1<>B2"),
  ("A1<=B2", "A1<=B2"),
  ("A1>=B2", "A1>=B2"),
  ("@SUM(A1:A2)", "SUM(A1:A2)"),
  ("TRUE", "TRUE"),
  ("FALSE", "FALSE"),
  ("123", "123"),
  ("12.5", "12.5"),
  (".5", ".5"),
  ("SUM (A1)", "SUM (A1)"),
  ("A1 + B2", "A1+B2"),
  ("  A1", "A1"),
  ("A1  ", "A1"),
  ("- 5", "-5"),
  ("(A1)", "(A1)"),
  ("((A1))", "((A1))"),
  ("SUM()", "SUM()"),
  ("=A1", "A1"),
  ("==A1", "=A1"),
  ("5*-3", "5*-3"),
  ("OFFSET(A1,1,1)", "OFFSET(A1,1,1)"),
  ("$A$1:$B$2", "$A$1:$B$2"),
  ("C1:C10", "C1:C10"),
  ("SUM(A1:A2)+SUM(B1:B2)", "SUM(A1:A2)+SUM(B1:B2)"),
  ("IF(SUM(A1:A10)>5,MAX(B1:B5),MIN(C1:C5))", "IF(SUM(A1:A10)>5,MAX(B1:B5),MIN(C1:C5))"),
  ("R1C1", "R1C1"),
  ("R[41]C[2]", "R[41]C[2]"),
  ("RC", "RC"),
  ("A1:R2C2", "A1:R2C2"),
]

func tokShapes(formula: string): seq[(string, string, string)] =
  for t in parseFormulaToks(formula):
    result.add ($t.kind, $t.sub, t.text)

suite "tokenizer oracle":
  test "every corpus formula renders exactly":
    for (formula, want) in RenderOracle:
      check renderFormulaToks(parseFormulaToks(formula)) == want

  test "renders are fixpoint-stable outside lossy classes":
    for (formula, rendered) in RenderOracle:
      let lossy = ("'" in formula) or ('"' in formula) or
        ('{' in formula) or rendered.startsWith("=")
      if lossy: continue
      check renderFormulaToks(parseFormulaToks(rendered)) == rendered

  test "leading equals is dropped like efp":
    check tokShapes("=A1") == tokShapes("A1")
    check tokShapes("=A1") == @[("ftkOperand", "ftsRange", "A1")]
    check tokShapes("==A1") ==
      @[("ftkOpInfix", "ftsLogical", "="), ("ftkOperand", "ftsRange", "A1")]

  test "unary operators and percent":
    check tokShapes("-A1") == @[("ftkOpPrefix", "ftsNone", "-"),
      ("ftkOperand", "ftsRange", "A1")]
    check tokShapes("A1+-B2") == @[("ftkOperand", "ftsRange", "A1"),
      ("ftkOpInfix", "ftsMath", "+"), ("ftkOpPrefix", "ftsNone", "-"),
      ("ftkOperand", "ftsRange", "B2")]
    check tokShapes("A1%") == @[("ftkOperand", "ftsRange", "A1"),
      ("ftkOpPostfix", "ftsNone", "%")]

  test "intersection needs operand neighbors":
    check tokShapes("A1 B2") == @[("ftkOperand", "ftsRange", "A1"),
      ("ftkOpInfix", "ftsIntersect", ""), ("ftkOperand", "ftsRange", "B2")]
    check renderFormulaToks(parseFormulaToks("SUM(A1 B2)")) ==
      "SUM(A1 B2)"

  test "comma is union outside functions, argument inside":
    check tokShapes("A1,B2") == @[("ftkOperand", "ftsRange", "A1"),
      ("ftkOpInfix", "ftsUnion", ","), ("ftkOperand", "ftsRange", "B2")]
    check tokShapes("SUM(A1,B2)") == @[
      ("ftkFunction", "ftsStart", "SUM"),
      ("ftkOperand", "ftsRange", "A1"),
      ("ftkArgument", "ftsNone", ","),
      ("ftkOperand", "ftsRange", "B2"),
      ("ftkFunction", "ftsStop", "")]

  test "operands classify like Go ParseFloat":
    check tokShapes("1E+10") ==
      @[("ftkOperand", "ftsNumber", "1E+10")]
    check tokShapes("TRUE") ==
      @[("ftkOperand", "ftsLogical", "TRUE")]
    check tokShapes("#DIV/0!") ==
      @[("ftkOperand", "ftsError", "#DIV/0!")]

  test "quoted strings and sheet names":
    check tokShapes("\"a\"\"b\"") ==
      @[("ftkOperand", "ftsText", "a\"b")]
    check renderFormulaToks(parseFormulaToks("\"a\"\"b\"")) == "\"a\"b\""
    check tokShapes("'My Sheet'!A1") ==
      @[("ftkOperand", "ftsRange", "My Sheet!A1")]

  test "arrays expand to ARRAY/ARRAYROW calls":
    check renderFormulaToks(parseFormulaToks("{1,2;3,4}")) ==
      "ARRAY(ARRAYROW(1,2),ARRAYROW(3,4))"

  test "three-dimensional and bracketed refs stay whole":
    check tokShapes("Sheet1:Sheet3!A1") ==
      @[("ftkOperand", "ftsRange", "Sheet1:Sheet3!A1")]
    check tokShapes("[1]Sheet1!A1") ==
      @[("ftkOperand", "ftsRange", "[1]Sheet1!A1")]

suite "shared reference shifting":
  test "absolute markers pin their axis":
    check shiftSharedToken("$A$1", 5, 5) == "$A$1"
    check shiftSharedToken("$A1", 2, 3) == "$A4"
    check shiftSharedToken("A$1", 2, 3) == "C$1"
    check shiftSharedToken("A1", 2, 3) == "C4"

  test "ranges shift endpoint-wise":
    check shiftSharedToken("A1:B2", 1, 1) == "B2:C3"
    check shiftSharedToken("$A$1:$B$2", 1, 1) == "$A$1:$B$2"
    check shiftSharedToken("A:A", 1, 9) == "B:B"
    check shiftSharedToken("1:1", 9, 1) == "2:2"
    check shiftSharedToken("$A:B", 1, 0) == "$A:C"
    check shiftSharedToken("Sheet1!A1", 1, 1) == "Sheet1!A1"

  test "overflow blanks the part":
    check shiftSharedToken("A1", -1, 0) == ""
    # Both endpoints blank but the join survives (excelize parity).
    check shiftSharedToken("A:A", -1, 0) == ":"

  test "anchor expansion matches excelize":
    check expandSharedFormula("A1+B1", 3, 1, 3, 2) == "A2+B2"
    check expandSharedFormula("SUM('My Sheet'!A1:A10)", 3, 1, 3, 3) ==
      "SUM(My Sheet!A1:A12)"
    check expandSharedFormula("$A$1+A1+A$1+$A1", 4, 5, 4, 6) ==
      "$A$1+A2+A$1+$A2"

suite "shared formula cells":
  const SharedDir = "tests/fixtures/xlsx/"
  test "anchor and members expand":
    let f = openXlsx(SharedDir & "shared_formula.xlsx")
    defer: f.closeXlsx()
    check f.getCellFormula("Shared", "C1") == "SUM(My Sheet!A1:A10)"
    check f.getCellFormula("Shared", "C2") == "SUM(My Sheet!A1:A11)"
    check f.getCellFormula("Shared", "C3") == "SUM(My Sheet!A1:A12)"
    check f.getCellFormula("Shared", "D5") == "$A$1+A1+A$1+$A1"
    check f.getCellFormula("Shared", "D6") == "$A$1+A2+A$1+$A2"
    check f.getCellFormula("Shared", "E7") == "A:A"
    check f.getCellFormula("Shared", "E8") == "A:A"
    check f.getCellFormula("Shared", "B2") == "A1*B2"
    check f.getCellFormula("Shared", "D2") == "C1*D2"

  test "dangling and plain cells":
    let f = openXlsx(SharedDir & "shared_formula.xlsx")
    defer: f.closeXlsx()
    check f.getCellFormula("Shared", "F9") == ""
    check f.getCellFormula("Shared", "G9") == "SUM(A1:A2)"
    check f.getCellFormula("Shared", "Z9") == ""
