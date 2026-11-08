## P1 tests: document metadata (/Info + XMP).

import std/strutils
import unittest
import ../src/opendocs/pdf
import ./pdf_support

const InfoFull = "tests/data/pdf/info_full.pdf"
const InfoDates = "tests/data/pdf/info_dates.pdf"

test "full info reads every key":
  let doc = readPdfBytes(readFile(InfoFull))
  check doc.info.title == "Full Title"
  check doc.info.author == "Ada Author"
  check doc.info.subject == "A Subject"
  check doc.info.keywords == "kw1, kw2"
  check doc.info.creator == "Tool 1.0"
  check doc.info.producer == "Prod"
  check doc.info.trapped == "False"
  check doc.info.creationDate == "D:20260304050607+02'00'"
  check doc.info.created.ok
  check doc.info.created.year == 2026
  check doc.info.created.month == 3
  check doc.info.created.day == 4
  check doc.info.created.hour == 5
  check doc.info.created.minute == 6
  check doc.info.created.second == 7
  check doc.info.created.tzHour == 2
  check doc.info.created.tzMinute == 0
  check doc.info.modDate == "D:1998"
  check doc.info.modified.ok
  check doc.info.modified.year == 1998
  check doc.info.modified.month == 1
  check doc.info.modified.day == 1

test "xmp packet and convenience fields":
  let doc = readPdfBytes(readFile(InfoFull))
  check "x:xmpmeta" in doc.info.xmp
  check doc.info.xmpTitle == "Full Title & More"
  check doc.info.xmpCreator == "Ada Author"
  check doc.info.xmpCreateDate == "2026-03-04T05:06:07Z"

test "malformed dates keep raw, parse as not-ok":
  let doc = readPdfBytes(readFile(InfoDates))
  check doc.info.creationDate == "not a date"
  check not doc.info.created.ok
  check not doc.info.modified.ok
  check doc.info.title == "T"

test "missing info reads empty":
  let doc = readPdfBytes(buildSimplePdf(@[(w: 10.0, h: 10.0)]))
  check doc.info.title == ""
  check doc.info.author == ""
  check doc.info.xmp == ""
  check doc.info.xmpTitle == ""
  check not doc.info.created.ok

test "date grammar edges":
  check parsePdfDate("D:2026").ok
  check parsePdfDate("2026").ok
  check parsePdfDate("D:20260304050607Z").ok
  check parsePdfDate("D:20260304050607-08'00'").tzHour == -8
  check not parsePdfDate("").ok
  check not parsePdfDate("D:20").ok
  check not parsePdfDate("D:20261301").ok
  check not parsePdfDate("D:20260001").ok
  check not parsePdfDate("D:20260101250000").ok
  check not parsePdfDate("D:2026x").ok
  check parsePdfDate("D:1999").month == 1
