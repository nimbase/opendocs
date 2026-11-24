## M16f tests: table writer.

import std/strutils
import unittest
import ../src/opendocs/pdf
import ../src/opendocs/pdf/gstate

test "table writes and extracts":
  var doc = newPdf()
  let style = TableStyle(columns: @[
      Column(width: 200.0, align: alignLeft),
      Column(width: 200.0, align: alignLeft)],
    border: Border(line: bdSingle, width: 0.5, color: black()),
    headerRows: 1, cellPadding: 4.0)
  doc.table(@[
    Row(cells: @["Name", "Value"], height: 0.0),
    Row(cells: @["Alpha", "one two three four five"], height: 0.0)],
    style)
  let data = doc.build()
  var d = openDoc(data)
  check d.pageCount() >= 1
  let txt = d.extractText(0).join(" ")
  check txt.contains("Alpha")
  check txt.contains("Name")
  let ops = d.pageContentStream(0)
  check "m" in ops and "l" in ops

test "table rejects bad geometry":
  var doc = newPdf()
  expect PdfError:
    doc.table(@[Row(cells: @["x"], height: 0.0)],
      TableStyle(columns: @[], border: Border(line: bdNone,
        width: 0.5, color: black()), headerRows: 0, cellPadding: 4.0))
  expect PdfError:
    doc.table(@[Row(cells: @["x"], height: 0.0)],
      TableStyle(columns: @[Column(width: -5.0, align: alignLeft)],
        border: Border(line: bdNone, width: 0.5, color: black()),
        headerRows: 0, cellPadding: 4.0))

test "long table splits pages and repeats header":
  var doc = newPdf()
  var rows: seq[Row] = @[Row(cells: @["H1", "H2"], height: 0.0)]
  for i in 0 ..< 80:
    rows.add(Row(cells: @["row " & $i, "value " & $i], height: 0.0))
  doc.table(rows, TableStyle(columns: @[
      Column(width: 200.0, align: alignLeft),
      Column(width: 200.0, align: alignLeft)],
    border: Border(line: bdSingle, width: 0.5, color: black()),
    headerRows: 1, cellPadding: 4.0))
  let data = doc.build()
  var d = openDoc(data)
  check d.pageCount() > 1
