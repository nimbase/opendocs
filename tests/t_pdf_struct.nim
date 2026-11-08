## P5 tests: tagged-PDF structure tree.

import std/strutils
import unittest
import ../src/opendocs/pdf
import ./pdf_support

const Struct = "tests/data/pdf/struct_tree.pdf"

proc tree(): PdfStructElem =
  var d = openDoc(readFile(Struct))
  d.structTree()

test "root carries the single top element":
  check tree().kids.len == 1

test "rolemap translates the section type":
  let s = tree().kids[0]
  check s.structType == "Sect"
  check s.kids.len == 3

test "paragraph keeps alt text and page":
  let s = tree().kids[0].kids[0]
  check s.structType == "P"
  check s.alt == "para alt"
  check s.pageIndex == 0

test "mcr leaf carries mcid and page":
  let s = tree().kids[0].kids[1]
  check s.structType == ""
  check s.mcid == 1
  check s.pageIndex == 0
  check s.kids.len == 0

test "span keeps actual text and attributes":
  let s = tree().kids[0].kids[2]
  check s.structType == "Span"
  check s.actualText == "ligature"
  check ("O", "Layout") in s.attrs

test "missing tree reads as empty root":
  var d = openDoc(buildSimplePdf(@[(w: 10.0, h: 10.0)]))
  let t = d.structTree()
  check t.kids.len == 0
  check t.structType == ""
