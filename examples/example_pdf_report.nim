## High-level PDF report: metadata, two fonts, flowing multi-page
## text, and compressed images. Run from the package root.
import std/os
import std/strutils
import ../src/opendocs/pdf
import libvips/api

const DejaVuPath = "../harfbuzz/tests/data/DejaVuSans.ttf"
const Micro = "tests/data/fonts/cjk-cff-micro.otf"

var doc =
  if fileExists(DejaVuPath): newPdf(DejaVuPath, psLetter)
  else: newPdf(readFile(Micro), "NotoSansJP", psLetter)
doc.setTitle("Quarterly report")
doc.setAuthor("opengraphics")

if fileExists(DejaVuPath):
  doc.loadFont("alt", DejaVuPath)
  echo "fonts: ", doc.fontNames()

doc.heading("Quarterly report")
doc.paragraph("This report flows across pages on its own. Each " &
  "paragraph wraps on HarfBuzz shaped widths and the writer embeds " &
  "only the glyphs that were actually drawn.")

if fileExists(DejaVuPath):
  doc.setFont("alt", 12.0)
  doc.heading("Second section", 15.0)
  doc.paragraph("Switched to the second loaded font with setFont. " &
    "Both fonts subset and embed when the file is saved.")
  doc.setFont("body", 12.0)

for i in 1 .. 40:
  doc.paragraph("Filler paragraph " & $i & ": enough text here to " &
    "push the document past one page so page breaks kick in.")

# Generated figures: raw pixels embed lossless, compress re-encodes
# through libvips with an optional downscale.
let fig = getTempDir() / "opengraphics_report_fig.jpg"
black(320, 200, 3).saveJPEG(fig, 90)
doc.newPage()
doc.heading("Figures", 15.0)
doc.imageFromFile(fig)
doc.imageFromFile(fig, ImageOpts(compress: true, jpegQuality: 60,
  maxWidthPx: 160, widthPt: 300.0))
removeFile(fig)

doc.save("report.pdf")
echo "wrote report.pdf with ", doc.pageCount(), " pages"
doc.close()

let info = openPdf("report.pdf")
echo "read back: ", info.pageCount, " pages"
var d = openDoc(readFile("report.pdf"))
var hits = 0
for p in 0 ..< d.pageCount():
  var pageText = ""
  for r in d.extractText(p):
    pageText.add(r.text)
  if "report" in pageText.toLowerAscii():
    inc hits
echo "pages mentioning report: ", hits
