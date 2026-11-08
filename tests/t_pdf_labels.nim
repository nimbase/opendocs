## P3 tests: page labels (number-tree ranges + style formatting).

import std/strutils
import unittest
import ../src/opendocs/pdf
import ./pdf_support

const Labels = "tests/data/pdf/page_labels.pdf"

proc labels(): seq[PdfPageLabel] =
  var d = openDoc(readFile(Labels))
  d.pageLabels()

test "ranges come sorted from the kids tree":
  let ls = labels()
  check ls.len == 5
  check ls[0].start == 0 and ls[0].style == "r"
  check ls[1].start == 3 and ls[1].style == "R" and ls[1].first == 4
  check ls[2].start == 5 and ls[2].style == "A" and ls[2].first == 27
  check ls[3].start == 6 and ls[3].style == "a"
  check ls[4].start == 7 and ls[4].prefix == "End-"

test "labels render per page":
  let ls = labels()
  check labelForPage(ls, 0) == "i"
  check labelForPage(ls, 1) == "ii"
  check labelForPage(ls, 2) == "iii"
  check labelForPage(ls, 3) == "IV"
  check labelForPage(ls, 4) == "V"
  check labelForPage(ls, 5) == "AA"
  check labelForPage(ls, 6) == "a"
  check labelForPage(ls, 7) == "End-"

test "no labels reads empty":
  var d = openDoc(buildSimplePdf(@[(w: 10.0, h: 10.0)]))
  check d.pageLabels().len == 0
  check labelForPage(d.pageLabels(), 0) == ""
