## M10 embedded files: builder embed, incremental embed, extract.
import std/os
import std/strutils
import unittest
import ../src/opendocs/pdf
import ../src/opendocs/pdf/cos
import ../src/opendocs/pdf/docmodel
import ../src/opendocs/pdf/write
import pdf_support

proc blankPdf(): string =
  var b = newPdfBuilder()
  let res = CosObj(kind: coDict, keys: @[], vals: @[])
  discard b.addPage(100.0, 100.0, b.addContentStream("", flate = false),
    res)
  b.buildPdf()

proc filesByName(d: var PdfDoc): seq[FileAttachment] =
  embeddedFiles(d)

test "builder embed round-trips bytes and metadata":
  var b = newPdfBuilder()
  let res = CosObj(kind: coDict, keys: @[], vals: @[])
  discard b.addPage(100.0, 100.0, b.addContentStream("", flate = false),
    res)
  discard b.embedFile("hello.txt", "Hello attachment",
    desc = "greeting", mime = "text/plain")
  var d = openDoc(b.buildPdf())
  let files = d.filesByName()
  check files.len == 1
  check files[0].name == "hello.txt"
  check files[0].fileName == "hello.txt"
  check files[0].desc == "greeting"
  check files[0].mime == "text/plain"
  check files[0].data == "Hello attachment"

test "mime guessed from extension":
  var b = newPdfBuilder()
  let res = CosObj(kind: coDict, keys: @[], vals: @[])
  discard b.addPage(100.0, 100.0, b.addContentStream("", flate = false),
    res)
  discard b.embedFile("report.pdf", "%PDF-fake")
  var d = openDoc(b.buildPdf())
  check d.filesByName()[0].mime == "application/pdf"

test "multiple files sort by name":
  var b = newPdfBuilder()
  let res = CosObj(kind: coDict, keys: @[], vals: @[])
  discard b.addPage(100.0, 100.0, b.addContentStream("", flate = false),
    res)
  discard b.embedFile("zeta.bin", "z")
  discard b.embedFile("alpha.bin", "a")
  discard b.embedFile("mid.bin", "m")
  var d = openDoc(b.buildPdf())
  let files = d.filesByName()
  check files.len == 3
  check files[0].name == "alpha.bin"
  check files[1].name == "mid.bin"
  check files[2].name == "zeta.bin"
  check files[0].data == "a"
  check files[2].data == "z"

test "plain file has no attachments":
  var d = openDoc(blankPdf())
  check d.filesByName().len == 0

test "missing file stream fails loudly":
  let pdf = assemblePdf(@[
    "<< /Type /Catalog /Pages 2 0 R /Names << /EmbeddedFiles " &
      "<< /Names [(gone.txt) 4 0 R] >> >> >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 10 10] >>",
    "<< /Type /Filespec /F (gone.txt) >>",
  ])
  var d = openDoc(pdf)
  expect PdfError:
    discard d.filesByName()

test "incremental embed keeps content and history":
  let base = blankPdf()
  var donor = openDoc(base)
  var u = beginUpdate(base)
  u.embedFileUpdate(donor, "added.txt", "late bytes")
  let v2 = u.finishUpdate()
  var d = openDoc(v2)
  check d.pageCount() == 1
  let files = d.filesByName()
  check files.len == 1
  check files[0].name == "added.txt"
  check files[0].data == "late bytes"
  # The base file still opens on its own (update appended only).
  var old = openDoc(base)
  check old.filesByName().len == 0

test "incremental embed preserves older attachments":
  var b = newPdfBuilder()
  let res = CosObj(kind: coDict, keys: @[], vals: @[])
  discard b.addPage(100.0, 100.0, b.addContentStream("", flate = false),
    res)
  discard b.embedFile("first.txt", "one")
  let base = b.buildPdf()
  var donor = openDoc(base)
  var u = beginUpdate(base)
  u.embedFileUpdate(donor, "second.txt", "two")
  var d = openDoc(u.finishUpdate())
  let files = d.filesByName()
  check files.len == 2
  check files[0].name == "first.txt"
  check files[0].data == "one"
  check files[1].name == "second.txt"
  check files[1].data == "two"

test "empty attachment name rejected":
  var b = newPdfBuilder()
  expect PdfError:
    discard b.embedFile("", "data")
  var donor = openDoc(blankPdf())
  var u = beginUpdate(blankPdf())
  expect PdfError:
    u.embedFileUpdate(donor, "", "data")
