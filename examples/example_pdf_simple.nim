## High-level PDF writer: headings, paragraphs, images, metadata.
import std/os
import ../src/opendocs/pdf
import libvips/api

const DejaVuPath = "../harfbuzz/tests/data/DejaVuSans.ttf"
const Micro = "tests/data/fonts/cjk-cff-micro.otf"

var doc =
  if fileExists(DejaVuPath): newPdf(DejaVuPath)
  else: newPdf(readFile(Micro), "NotoSansJP")

doc.setTitle("Simple PDF")
doc.setAuthor("opengraphics")
doc.heading("Hello writer")
doc.paragraph("This paragraph wraps on HarfBuzz widths and flows " &
  "onto new pages automatically. The font subset embeds on save.")
doc.textAt("absolute at 72, 72", 72.0, 72.0)

# A generated JPEG shows the image path: passthrough by default,
# libvips downscale plus re-encode with compress.
let jpg = getTempDir() / "opengraphics_simple.jpg"
black(128, 96, 3).saveJPEG(jpg, 85)
doc.imageFromFile(jpg)
doc.imageFromFile(jpg, ImageOpts(compress: true, jpegQuality: 60,
  maxWidthPx: 64, widthPt: 200.0))
removeFile(jpg)

doc.save("simple.pdf")
doc.close()

var d = openDoc(readFile("simple.pdf"))
echo "pages: ", d.pageCount()
for r in d.extractText(0):
  echo "\"", r.text, "\" at (", r.x, ", ", r.y, ")"
