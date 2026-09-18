## M12 signatures P4a: parse, ByteRange hash, placeholder shell.
import std/os
import unittest
import ../src/opendocs/pdf
import ../src/opendocs/pdf/cos
import ../src/opendocs/pdf/docmodel
import ../src/opendocs/pdf/write
import pdf_support

proc blankPdf(): string =
  var b = newPdfBuilder()
  let res = CosObj(kind: coDict, keys: @[], vals: @[])
  discard b.addPage(200.0, 200.0, b.addContentStream("", flate = false),
    res)
  b.buildPdf()

proc sigPdf(byteRange, contents: string): string =
  assemblePdf(@[
    "<< /Type /Catalog /Pages 2 0 R /AcroForm 4 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] >>",
    "<< /Fields [5 0 R] >>",
    "<< /FT /Sig /T (Seal) /V 6 0 R >>",
    "<< /Type /Sig /Filter /Adobe.PPKLite " &
      "/SubFilter /adbe.pkcs7.detached /ByteRange " & byteRange &
      " /Contents " & contents & " /Reason (Approved) " &
      "/Location (Helsinki) /M (D:20260101) >>",
  ])

test "unsigned file lists no signatures":
  var d = openDoc(blankPdf())
  check docSignatures(d).len == 0

test "placeholder shell has valid ranges":
  let draft = addSignaturePlaceholder(blankPdf(), "Sig1", 512)
  check draft.byteRange[0] == 0
  check draft.byteRange[0] + draft.byteRange[1] == draft.contentsAt
  check draft.byteRange[2] + draft.byteRange[3] == draft.file.len
  check draft.byteRange[2] - draft.contentsAt == draft.contentsLen
  # The gap covers exactly the <hex> span.
  check draft.file[draft.contentsAt] == '<'
  check draft.file[draft.contentsAt + draft.contentsLen - 1] == '>'

test "placeholder parses back unsigned":
  let draft = addSignaturePlaceholder(blankPdf(), "Sig1", 512)
  var d = openDoc(draft.file)
  let sigs = docSignatures(d)
  check sigs.len == 1
  check sigs[0].field == "Sig1"
  check sigs[0].filter == "Adobe.PPKLite"
  check sigs[0].subFilter == "adbe.pkcs7.detached"
  check sigs[0].hasByteRange
  check sigs[0].byteRange == draft.byteRange
  check sigs[0].contents.len == 512
  check not sigs[0].signed
  check sigs[0].signDate.len > 0

test "ByteRange hash is stable and tamper-evident":
  let draft = addSignaturePlaceholder(blankPdf(), "Sig1", 256)
  var d = openDoc(draft.file)
  let sig = docSignatures(d)[0]
  let h1 = verifyByteRangeHash(draft.file, sig)
  check h1.len == 64
  check verifyByteRangeHash(draft.file, sig) == h1
  # Flip a byte inside a signed range: digest must change.
  var edited = draft.file
  edited[10] = chr(ord(edited[10]) xor 0xFF)
  check verifyByteRangeHash(edited, sig) != h1
  # Flip a byte inside the Contents gap: digest must not change.
  var gap = draft.file
  gap[draft.contentsAt + 4] = 'F'
  check verifyByteRangeHash(gap, sig) == h1

test "second placeholder joins the existing AcroForm":
  let first = addSignaturePlaceholder(blankPdf(), "Sig1", 128)
  let second = addSignaturePlaceholder(first.file, "Sig2", 128)
  var d = openDoc(second.file)
  let sigs = docSignatures(d)
  check sigs.len == 2
  check sigs[0].field == "Sig1"
  check sigs[1].field == "Sig2"

test "duplicate field name rejected":
  let first = addSignaturePlaceholder(blankPdf(), "Sig1", 128)
  expect PdfError:
    discard addSignaturePlaceholder(first.file, "Sig1", 128)
  expect PdfError:
    discard addSignaturePlaceholder(blankPdf(), "", 128)
  expect PdfError:
    discard addSignaturePlaceholder(blankPdf(), "S", 0)

test "hand-built signature parses metadata":
  var d = openDoc(sigPdf("[0 5 40 10]", "<AABB>"))
  let sigs = docSignatures(d)
  check sigs.len == 1
  check sigs[0].field == "Seal"
  check sigs[0].reason == "Approved"
  check sigs[0].location == "Helsinki"
  check sigs[0].signDate == "D:20260101"
  check sigs[0].contents == "\xAA\xBB"
  check sigs[0].signed

test "short ByteRange fails loudly on verify":
  var d = openDoc(sigPdf("[0 5 40]", "<AABB>"))
  let sig = docSignatures(d)[0]
  check not sig.hasByteRange
  expect PdfError:
    discard verifyByteRangeHash("x", sig)

test "out-of-bounds ByteRange fails loudly on verify":
  var d = openDoc(sigPdf("[0 5 40 999999]", "<AABB>"))
  let sig = docSignatures(d)[0]
  check sig.hasByteRange
  expect PdfError:
    discard verifyByteRangeHash("tiny", sig)

test "encrypted base rejected":
  expect PdfError:
    discard addSignaturePlaceholder(
      readFile("tests" / "data" / "pdf" / "m4_rc4.pdf"), "Sig1", 128)
