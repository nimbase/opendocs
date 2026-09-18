## M3a tests: content-stream parsing, graphics state, fixtures.
##
## Unit vectors are inline strings; integration uses the generated
## fixtures under tests/data/pdf (see tests/gen_pdf_fixtures.nim for
## origin: synthetic, Flate via the real encoder, classic xref).

import std/math
import std/strutils
import unittest
import ../src/opendocs/pdf
import ../src/opendocs/pdf/cos
import ../src/opendocs/pdf/docmodel
import ../src/opendocs/pdf/content
import ../src/opendocs/pdf/gstate

const
  Basic = "tests/data/pdf/m3a_basic.pdf"
  Update = "tests/data/pdf/m3a_update.pdf"

proc showOps(ops: seq[ContentOp], name: string): seq[CosObj] =
  for op in ops:
    if op.name == name:
      return op.operands
  @[]

proc close(a, b: Matrix): bool =
  for i in 0 ..< 6:
    if abs(a[i] - b[i]) > 1e-9:
      return false
  true

test "text showing ops tokenize":
  let ops = parseContentStream("BT /F1 12 Tf 72 720 Td (Hi) Tj ET")
  check ops.len == 5
  check ops[0].name == "BT" and ops[0].operands.len == 0
  check ops[1].name == "Tf"
  check ops[1].operands[0].asName() == "F1"
  check ops[1].operands[1].asInt() == 12
  check ops[3].operands[0].sval == "Hi"

test "arrays hex strings and floats as operands":
  # All operands accumulate onto the following operator.
  let ops = parseContentStream("[1 (a) <BB> 2.5] 1 0 0 1 10 20 cm")
  check ops.len == 1
  check ops[0].name == "cm" and ops[0].operands.len == 7
  check ops[0].operands[0].items[2].sval == "\xBB"

test "quote operators are operators":
  let ops = parseContentStream("(a) ' (b) \"")
  check ops.len == 2
  check ops[0].name == "'" and ops[1].name == "\""

test "inline image raw scan":
  let ops = parseContentStream(
    "BI /W 2 /H 1 /CS /G /BPC 8 ID \x01\x02\x03 EI Q")
  check ops.len == 2
  check ops[0].name == "BI"
  check ops[0].operands[0].dictGet("W").asInt() == 2
  check ops[0].operands[0].dictGet("CS").asName() == "G"
  check ops[0].operands[1].sval == "\x01\x02\x03"
  check ops[1].name == "Q"

test "inline image ends at first EI match":
  # Heuristic documented in content.nim: a payload holding
  # whitespace + EI + delimiter truncates early.
  let ops = parseContentStream("BI /W 1 ID AB EI CD EI")
  check ops[0].operands[1].sval == "AB"

test "dangling operands raise":
  expect(PdfError):
    discard parseContentStream("12 34")

test "unterminated inline image raises":
  expect(PdfError):
    discard parseContentStream("BI /W 1 ID abc")

test "missing whitespace after ID raises":
  expect(PdfError):
    discard parseContentStream("BI /W 1 ID")

test "operator limit enforced":
  var lim = defaultPdfLimits()
  lim.maxContentOps = 3
  expect(PdfError):
    discard parseContentStream("Q Q Q Q", lim)

test "cm concatenates onto ctm":
  var gs = walkOps(parseContentStream("2 0 0 3 10 20 cm"))
  check close(gs.ctm, [2.0, 0.0, 0.0, 3.0, 10.0, 20.0])
  gs = walkOps(parseContentStream("1 0 0 1 5 5 cm 2 0 0 2 0 0 cm"))
  # CTM = S(2) x T(5,5): scale applies first in user space.
  check close(gs.ctm, [2.0, 0.0, 0.0, 2.0, 5.0, 5.0])

test "q restores ctm":
  let gs = walkOps(parseContentStream(
    "5 0 0 5 0 0 cm q 2 0 0 2 0 0 cm Q"))
  check close(gs.ctm, [5.0, 0.0, 0.0, 5.0, 0.0, 0.0])

test "unbalanced Q raises":
  expect(PdfError):
    discard walkOps(parseContentStream("Q"))

test "text matrices thread through Td and Tstar":
  let gs = walkOps(parseContentStream(
    "BT 1 0 0 1 10 20 Tm 5 5 Td T* ET"))
  check close(gs.textLine, [1.0, 0.0, 0.0, 1.0, 15.0, 25.0])
  check close(gs.textMatrix, gs.textLine)
  check not gs.inText

test "TD sets leading":
  let gs = walkOps(parseContentStream("BT 0 -14 TD ET"))
  check abs(gs.text.leading - 14.0) < 1e-9

test "Tf and text state":
  let gs = walkOps(parseContentStream(
    "BT /F1 12 Tf 100 Tc 50 Tw 80 Tz 14 TL 1 Tr 2 Ts ET"))
  check gs.text.fontName == "F1"
  check abs(gs.text.fontSize - 12.0) < 1e-9
  check abs(gs.text.charSpace - 100.0) < 1e-9
  check abs(gs.text.wordSpace - 50.0) < 1e-9
  check abs(gs.text.scale - 80.0) < 1e-9
  check abs(gs.text.leading - 14.0) < 1e-9
  check gs.text.renderMode == 1
  check abs(gs.text.rise - 2.0) < 1e-9

test "bad cm arity raises":
  expect(PdfError):
    discard walkOps(parseContentStream("1 2 cm"))

test "transformPoint":
  check transformPoint(identityMatrix(), 3.0, 4.0) == (3.0, 4.0)
  let m: Matrix = [2.0, 0.0, 0.0, 2.0, 10.0, 20.0]
  check transformPoint(m, 1.0, 1.0) == (12.0, 22.0)

test "basic fixture text and inline image":
  var d = openDoc(readFile(Basic))
  let ops = d.walkPageOps(0)
  check showOps(ops, "Tj")[0].sval == "Hello page one"
  # page 0 ops: BT Tf Td Tj ET q cm BI Q
  let bi = ops[7]
  check bi.name == "BI"
  check bi.operands[0].dictGet("W").asInt() == 2
  check bi.operands[1].sval == "\xAA\xBB"
  var res = d.pageResources(0)
  var f1 = res.dictGet("Font").dictGet("F1")
  if f1.kind == coRef:
    f1 = d.resolve(f1)
  check f1.dictGet("BaseFont").asName() == "Helvetica"

test "contents array concatenates mixed filters":
  var d = openDoc(readFile(Basic))
  let ops = d.walkPageOps(1)
  check showOps(ops, "Tj")[0].sval == "Second"
  check showOps(ops, "Tm").len == 6
  var sawCm = false
  for op in ops:
    if op.name == "cm":
      sawCm = true
  check sawCm

test "incremental fixture resolves newest contents":
  var d = openDoc(readFile(Update))
  check d.walkPageOps(0)[1].operands[0].sval == "Second"

test "page index out of range raises":
  var d = openDoc(readFile(Basic))
  expect(PdfError):
    discard d.walkPageOps(9)
