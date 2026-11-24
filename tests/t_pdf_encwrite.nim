## M16e tests: encryption writer (R4/AESV2 + R6/AESV3).

import std/strutils
import unittest
import ../src/opendocs/pdf
import ../src/opendocs/pdf/cos
import ../src/opendocs/pdf/crypt
import ../src/opendocs/pdf/docmodel
import ../src/opendocs/pdf/gstate
import ../src/opendocs/pdf/write
import ./pdf_support

proc textPdf(): string =
  var doc = newPdf()
  doc.paragraph("Secret text here")
  doc.build()

test "r4 round-trips with user password":
  let opts = EncryptOptions(userPassword: "user123",
    ownerPassword: "owner123", revision: 4, permissions: -4,
    encryptMetadata: true)
  let enc = rewritePdfEncrypted(textPdf(), opts)
  var d = openDoc(enc, defaultPdfLimits(), "user123")
  check d.pageCount() == 1
  check d.extractText(0).join(" ").contains("Secret")

test "r4 wrong password fails":
  let opts = EncryptOptions(userPassword: "user123",
    ownerPassword: "", revision: 4, permissions: -4,
    encryptMetadata: true)
  let enc = rewritePdfEncrypted(textPdf(), opts)
  expect PdfError:
    discard openDoc(enc, defaultPdfLimits(), "nope")

test "r4 owner password opens":
  let opts = EncryptOptions(userPassword: "user123",
    ownerPassword: "owner999", revision: 4, permissions: -4,
    encryptMetadata: true)
  let enc = rewritePdfEncrypted(textPdf(), opts)
  var d = openDoc(enc, defaultPdfLimits(), "owner999")
  check d.pageCount() == 1

test "r6 round-trips":
  let opts = EncryptOptions(userPassword: "user456",
    ownerPassword: "owner456", revision: 6, permissions: -4,
    encryptMetadata: true)
  let enc = rewritePdfEncrypted(textPdf(), opts)
  var du = openDoc(enc, defaultPdfLimits(), "user456")
  check du.pageCount() == 1
  check du.extractText(0).join(" ").contains("Secret")
  var dOwn = openDoc(enc, defaultPdfLimits(), "owner456")
  check dOwn.pageCount() == 1

test "r6 wrong password fails":
  let opts = EncryptOptions(userPassword: "user456",
    ownerPassword: "", revision: 6, permissions: -4,
    encryptMetadata: true)
  let enc = rewritePdfEncrypted(textPdf(), opts)
  expect PdfError:
    discard openDoc(enc, defaultPdfLimits(), "wrong")

test "bad revision fails":
  let opts = EncryptOptions(userPassword: "u", ownerPassword: "",
    revision: 5, permissions: -4, encryptMetadata: true)
  expect PdfError:
    discard rewritePdfEncrypted(textPdf(), opts)

test "id preserved across rewrite":
  let opts = EncryptOptions(userPassword: "user123",
    ownerPassword: "", revision: 4, permissions: -4,
    encryptMetadata: true)
  let enc = rewritePdfEncrypted(textPdf(), opts)
  var a = openDoc(enc, defaultPdfLimits(), "user123")
  check a.pageCount() == 1
  let idA = a.xref.idFirst
  var b = openDoc(rewritePdf(enc, false, defaultPdfLimits(), "user123"))
  check b.pageCount() == 1
  check b.xref.idFirst == idA

test "per-object encryption differs and decrypts":
  let fk = "0123456789ABCDEF0123456789ABCDEF"
  let c = PdfCrypt(present: true, v: 5, r: 6, keyLen: 32, fileKey: fk,
    stmCrypt: ccAESV3, strCrypt: ccAESV3, encryptMetadata: true,
    encryptObjNum: -2)
  let e1 = encryptData(fk, 4, 0, "hello", ccAESV3, 32)
  let e2 = encryptData(fk, 5, 0, "hello", ccAESV3, 32)
  check e1 != e2
  check c.decryptData(4, 0, e1, ccAESV3) == "hello"
  check c.decryptData(5, 0, e2, ccAESV3) == "hello"

test "deterministic with fixed key and iv (r4)":
  let opts = EncryptOptions(userPassword: "user123",
    ownerPassword: "owner123", revision: 4, permissions: -4,
    encryptMetadata: true)
  let base = textPdf()
  let a = rewritePdfEncryptedImpl(fromString(base), opts, "", defaultPdfLimits(),
    "", "0123456789ABCDEF", "FEDCBA9876543210")
  let b = rewritePdfEncryptedImpl(fromString(base), opts, "", defaultPdfLimits(),
    "", "0123456789ABCDEF", "FEDCBA9876543210")
  check a == b
  var d = openDoc(a, defaultPdfLimits(), "user123")
  check d.pageCount() == 1

test "metadata carve-out stays readable":
  var b = newPdfBuilder()
  let r = CosObj(kind: coDict, keys: @[], vals: @[])
  let c = b.addContentStream("BT ET", false)
  discard b.addPage(100.0, 100.0, c, r)
  b.setInfo("T", "A")
  b.setXmpPacket("<x>x</x>")
  let plain = b.buildPdf()
  let opts = EncryptOptions(userPassword: "u1", ownerPassword: "",
    revision: 4, permissions: -4, encryptMetadata: false)
  let enc = rewritePdfEncrypted(plain, opts)
  var d = openDoc(enc, defaultPdfLimits(), "u1")
  check d.pageCount() == 1

test "finish update encrypted rewrites":
  var u = beginUpdate(textPdf())
  u.setPageRotation(0, 90)
  let opts = EncryptOptions(userPassword: "upw", ownerPassword: "",
    revision: 4, permissions: -4, encryptMetadata: true)
  let enc = u.finishUpdateEncrypted(opts)
  var d = openDoc(enc, defaultPdfLimits(), "upw")
  check d.pageCount() == 1
