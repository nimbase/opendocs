## P2/P3 tests: outlines with destination resolution.

import std/strutils
import unittest
import ../src/opendocs/pdf
import ./pdf_support

const Outlines = "tests/data/pdf/outlines.pdf"

proc outlines(): seq[PdfOutline] =
  var d = openDoc(readFile(Outlines))
  d.docOutlines()

test "top level items and openness":
  let o = outlines()
  check o.len == 6
  check o[0].title == "Chapter 1"
  check o[1].title == "Chapter 2"
  check o[2].title == "Remote"
  check o[3].title == "Broken"
  check o[4].title == "Plain"
  check o[5].title == "Old"
  check not o[0].open
  check not o[1].open # /Count -2 means closed
  check o[1].children.len == 2

test "explicit destination resolves to page":
  let o = outlines()
  check o[0].kind == "dest"
  check o[0].dest == ""
  check o[0].pageIndex == 0

test "named destination resolves via name tree":
  let o = outlines()
  check o[1].children[0].title == "Section 2.1"
  check o[1].children[0].kind == "dest"
  check o[1].children[0].dest == "sec21"
  check o[1].children[0].pageIndex == 1

test "old-style dest dict resolves":
  let o = outlines()
  check o[5].kind == "dest"
  check o[5].dest == "oldsec"
  check o[5].pageIndex == 2

test "uri action surfaces the target":
  let o = outlines()
  check o[1].children[1].kind == "actionURI"
  check o[1].children[1].uri == "https://example.com/x?q=1"
  check o[1].children[1].pageIndex == -1

test "remote goto reports the file":
  let o = outlines()
  check o[2].kind == "actionGoToR"
  check o[2].dest == "oldspec.pdf"
  check o[2].pageIndex == -1

test "unresolvable name keeps the name and -1":
  let o = outlines()
  check o[3].kind == "dest"
  check o[3].dest == "missing"
  check o[3].pageIndex == -1

test "item without dest or action is unknown":
  let o = outlines()
  check o[4].kind == "unknown"
  check o[4].pageIndex == -1

test "no outlines reads empty":
  var d = openDoc(buildSimplePdf(@[(w: 10.0, h: 10.0)]))
  check d.docOutlines().len == 0
