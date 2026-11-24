## P1 tests: DER writer vectors + reader rejects.

import std/os
import std/osproc
import std/strutils
import std/times
import unittest
import ../src/opendocs/pdf/der
import ../src/opendocs/pdf
import ./pdf_support

proc hexOf(s: string): string =
  const digits = "0123456789ABCDEF"
  for c in s:
    result.add(digits[(ord(c) shr 4) and 0xF])
    result.add(digits[ord(c) and 0xF])

test "integer vectors":
  check hexOf(derInt(0)) == "020100"
  check hexOf(derInt(5)) == "020105"
  check hexOf(derInt(127)) == "02017F"
  check hexOf(derInt(128)) == "02020080"
  check hexOf(derInt(-1)) == "0201FF"
  check hexOf(derInt(-128)) == "020180"
  check hexOf(derInt(-129)) == "0202FF7F"

test "oid vectors":
  check hexOf(derOid([1, 2, 840, 113549, 1, 7, 2])) ==
    "06092A864886F70D010702"
  check hexOf(derOid([2, 5, 4, 3])) == "0603550403"
  check hexOf(derOid([1, 2, 840, 10045, 3, 1, 7])) ==
    "06082A8648CE3D030107"

test "length forms":
  check hexOf(derLen(0)) == "00"
  check hexOf(derLen(127)) == "7F"
  check hexOf(derLen(128)) == "8180"
  check hexOf(derLen(256)) == "820100"
  expect PdfError:
    discard derLen(-1)

test "constructed and context tags":
  check hexOf(derSeq(derInt(5))) == "3003020105"
  check hexOf(derSet(derInt(2), derInt(1))) ==
    hexOf(derSet(derInt(1), derInt(2)))
  check hexOf(derExplicit(0, derInt(1))) == "A003020101"
  check hexOf(derBitString("\x00")) == "03020000"
  check hexOf(derOctetString("hi")) == "04026869"
  check hexOf(derNull()) == "0500"

test "times are UTC":
  let t = dateTime(2026, mNov, 24, 12, 0, 0, 0, utc())
  check derUtcTime(t) == "\x17\x0D261124120000Z"
  check derGeneralizedTime(t) == "\x18\x0F20261124120000Z"

test "reader round-trips writer output":
  let blob = derSeq(derInt(5), derOid([2, 5, 4, 3]), derOctetString("hi"))
  var pos = 0
  let top = derRead(blob, pos)
  check pos == blob.len
  check top.tag == 0x30
  let kids = top.derChildren()
  check kids.len == 3
  check kids[0].tag == 0x02
  check kids[1].content == derOid([2, 5, 4, 3])[2 .. ^1]
  expect PdfError:
    discard derParse(blob & "trailing")

test "reader rejects indefinite and truncation":
  var p = 0
  expect PdfError:
    discard derRead("\x30\x80\x02\x01\x01\x00\x00", p)
  p = 0
  expect PdfError:
    discard derRead("\x30\x03\x02\x01", p)

test "openssl agrees on a nested sequence":
  # asn1parse is the oracle: our bytes must parse as SEQ{INT, OID}.
  # Skipped where openssl is absent (pure-Nim assertions above cover
  # the encoding either way). NB: unittest.skip marks but does not
  # stop the body, so the tool-gated part sits in the else branch.
  let blob = derSeq(derInt(128), derOid([1, 2, 840, 113549, 1, 7, 1]))
  check hexOf(blob) == "300F0202008006092A864886F70D010701"
  let exe = findExe("openssl")
  if exe.len == 0:
    skip()
  else:
    let oraclePath = getTempDir() / "der_oracle.der"
    writeFile(oraclePath, blob)
    let (outp, code) = execCmdEx(quoteShell(exe) &
      " asn1parse -inform DER -in " & quoteShell(oraclePath))
    check code == 0
    check "SEQUENCE" in outp
    check "INTEGER" in outp
    check "OBJECT" in outp
