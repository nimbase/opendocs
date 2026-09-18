## Mapped file sources: mmap loading, lazy resolve, close semantics.
import std/os
import unittest
import ../src/opendocs/pdf
import ../src/opendocs/pdf/source
import ../src/opendocs/pdf/docmodel
import pdf_support

const
  textPdf = "tests" / "data" / "pdf" / "m3b_text.pdf"
  imgPdf = "tests" / "data" / "pdf" / "m5_images.pdf"
  rc4Pdf = "tests" / "data" / "pdf" / "m4_rc4.pdf"

test "string view needs no mapping":
  let src = fromString("%PDF-1.7 test")
  check not src.isMapped
  check src.len == 13
  check src[0] == '%'
  check src.slice(0, 5) == "%PDF-"
  check src.continuesWithAt("1.7", 5)
  check fromString("").len == 0

test "mapFile maps regular files":
  var src = mapFile(textPdf)
  check src.isMapped
  check src.len == getFileSize(textPdf)
  check src.slice(0, 5) == "%PDF-"
  src.close()

test "mapFile on missing file raises IOError":
  expect(IOError):
    discard mapFile("tests" / "data" / "pdf" / "no-such.pdf")

test "openPdf snapshots through the mapping":
  let doc = openPdf(textPdf)
  check doc.version == "1.7"
  check doc.pageCount == 2

test "mapped doc resolves lazily then closes":
  var d = openMappedDoc(textPdf)
  check d.pageCount() == 2
  let runs = d.extractText(0)
  check runs.len > 0
  check runs[0].text.len > 0
  d.close()
  var fresh = openMappedDoc(textPdf)
  fresh.close()
  expect(Defect):
    discard fresh.pageCount()

test "mapped images and passwords":
  var imgs = openMappedDoc(imgPdf)
  var names: seq[string] = @[]
  for im in imgs.pageImages(0):
    names.add(im.name)
  check names.len == 7
  imgs.close()
  check openPdfPasswordFile(rc4Pdf)
  check not openPdfPasswordFile(textPdf)
  var locked = openMappedDoc(rc4Pdf, password = "user123")
  check locked.pageCount() == 1
  locked.close()

test "large document parses from the mapping":
  var lim = defaultPdfLimits()
  lim.maxPages = 5000
  var boxes: seq[tuple[w, h: float]] = @[]
  for i in 0 ..< 3000:
    boxes.add((w: 100.0 + float(i mod 7), h: 200.0))
  let path = getTempDir() / "opengraphics_big.pdf"
  writeFile(path, buildSimplePdf(boxes))
  check getFileSize(path) > 100000
  let snap = openPdf(path, lim)
  check snap.pageCount == 3000
  var d = openMappedDoc(path, lim)
  check d.pageCount() == 3000
  let all = d.pageBoxes()
  check all[2999].width == 103.0
  check all[2999].height == 200.0
  d.close()
  removeFile(path)
