import std/os
import ../src/opendocs/pdf

let doc = openPdf("tests" / "data" / "pdf" / "m3b_text.pdf")
echo "PDF ", doc.version, " pages: ", doc.pageCount
for page in doc.pages:
  echo "page ", page.index, ": ", page.width, "x", page.height, "pt"

var d = openDoc(readFile("tests" / "data" / "pdf" / "m3b_text.pdf"))
for run in d.extractText(0):
  echo "\"", run.text, "\" at (", run.x, ", ", run.y, ") ", run.size,
    "pt ", run.fontName

var imgs = openDoc(readFile("tests" / "data" / "pdf" / "m5_images.pdf"))
for im in imgs.pageImages(0):
  echo im.name, ": ", im.width, "x", im.height, " ", im.encoding,
    " alpha=", im.hasAlpha, " bytes=", im.pixels.len

let encPath = "tests" / "data" / "pdf" / "m4_rc4.pdf"
echo "needs password: ", openPdfPassword(readFile(encPath))
let locked = openPdf(encPath, password = "user123")
echo "unlocked pages: ", locked.pageCount
