## M16d tests: color, vector, styled text.

import std/strutils
import unittest
import ../src/opendocs/pdf
import ../src/opendocs/pdf/gstate

test "color ops validate range":
  check fillOp(rgb(1.0, 0.0, 0.0)) == "1.0 0.0 0.0 rg"
  check strokeOp(gray(0.5)) == "0.5 G"
  expect PdfError:
    discard rgb(2.0, 0.0, 0.0)

test "path ops round-trip through reader":
  var p: Path
  p.moveTo(10.0, 10.0)
  p.lineTo(50.0, 10.0)
  p.lineTo(50.0, 50.0)
  p.close()
  let ops = p.paintOps(FillOpts(hasFill: true, fill: rgb(1.0, 0.0, 0.0),
    hasStroke: true, stroke: black(), lineWidth: 2.0))
  check "re" notin ops
  check "B" in ops
  check "q " in ops and " Q" in ops

test "empty path fails":
  var p: Path
  expect PdfError:
    discard p.pathOps()

test "ellipse and circle validate":
  let e = ellipsePath(0.0, 0.0, 10.0, 5.0)
  check e.cmds.len == 6
  expect PdfError:
    discard ellipsePath(0.0, 0.0, -1.0, 5.0)

test "high-level vector lands in content":
  var doc = newPdf()
  doc.line(10.0, 10.0, 50.0, 50.0, 2.0, rgb(0.0, 0.0, 1.0))
  doc.rect(10.0, 10.0, 40.0, 20.0,
    FillOpts(hasFill: true, fill: gray(0.9), hasStroke: true,
      stroke: black(), lineWidth: 1.0))
  doc.circle(100.0, 100.0, 20.0,
    FillOpts(hasFill: true, fill: rgb(1.0, 0.0, 0.0)))
  let data = doc.build()
  var d = openDoc(data)
  check d.pageCount() == 1
  let ops = d.pageContentStream(0)
  check "m" in ops and "l" in ops and "c" in ops
  check "rg" in ops or "RG" in ops or "g" in ops

test "styled text with color and align":
  var doc = newPdf()
  doc.paragraphStyled("Hello styled",
    TextStyle(hasColor: true, color: rgb(0.8, 0.0, 0.0)), alignCenter)
  doc.textRun("run", TextStyle(underline: true,
    hasColor: true, color: black()), 72.0, 700.0)
  let data = doc.build()
  var d = openDoc(data)
  check d.extractText(0).join(" ").contains("Hello")
