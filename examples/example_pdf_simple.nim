## High-level PDF writer: headings, paragraphs, images, metadata.
import std/os
import image/buffer
import image/color
import image/dynamic
import image/codecs/jpeg
import ../src/opendocs/pdf

const DejaVuPath = "tests/data/fonts/DejaVuSans.ttf"
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
# downscale plus re-encode with compress.
let jpg = getTempDir() / "opengraphics_simple.jpg"
block:
  var px = newSeq[Rgb[uint8]](128 * 96)
  for i in 0 ..< px.len:
    px[i] = Rgb[uint8](data: [0'u8, 0, 0])
  let img = DynamicImage(kind: dkRgb8, rgb8: RgbImage(width: 128,
    height: 96, pixels: px))
  let enc = encodeJpeg(img, 85)
  if not enc.ok:
    raise newException(IOError, "figure encode failed: " & enc.err.msg)
  var s = newString(enc.value.len)
  if s.len > 0:
    copyMem(addr s[0], unsafeAddr enc.value[0], s.len)
  writeFile(jpg, s)
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
