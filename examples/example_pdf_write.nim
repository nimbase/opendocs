## Build a one-page PDF, rewrite it, and read it back.
import std/os
import std/tables
import ../src/opendocs/pdf
import ../src/opendocs/pdf/cos
import ../src/opendocs/pdf/docmodel
import ../src/opendocs/pdf/write
import ../src/opendocs/pdf/shape
import ../src/opendocs/pdf/fontembed

var b = newPdfBuilder()
let f1 = CosObj(kind: coDict, keys: @["Type", "Subtype", "BaseFont"],
  vals: @[CosObj(kind: coName, name: "Font"),
    CosObj(kind: coName, name: "Type1"),
    CosObj(kind: coName, name: "Helvetica")])
let res = CosObj(kind: coDict, keys: @["Font"],
  vals: @[CosObj(kind: coDict, keys: @["F1"], vals: @[f1])])
let cnum = b.addContentStream(
  "BT /F1 24 Tf 72 720 Td (Hello writer) Tj ET")
discard b.addPage(612.0, 792.0, cnum, res)

const DejaVuPath = "../harfbuzz/tests/data/DejaVuSans.ttf"
if fileExists(DejaVuPath):
  let prog = readFile(DejaVuPath)
  var sf = openShapedFont(prog)
  defer: close(sf)
  var use = FontUse(fontBytes: prog, baseName: "DejaVuSans")
  var content: string
  for i, line in wrapText(sf, "Hello embedded writer", 24.0, 468.0):
    use.noteUse(line)
    content.add(drawTextLine(72.0, 720.0 - float64(i) * 28.0,
      "F2", 24.0, line) & "\n")
  let fonts = b.finalizeFonts({"F2": use}.toTable)
  let ecnum = b.addContentStream(content)
  discard b.addPage(612.0, 792.0, ecnum, fontResources(fonts))
  echo "embedded subset: full ", prog.len, " bytes"
else:
  echo "no sibling harfbuzz checkout; embedded-font page skipped"

const CjkMicro = "tests/data/fonts/cjk-cff-micro.otf"
if fileExists(CjkMicro):
  let cprog = readFile(CjkMicro)
  var csf = openShapedFont(cprog)
  defer: close(csf)
  var cuse = CidFontUse(fontBytes: cprog, baseName: "NotoSansJP")
  let ctext = "日本語あAX"
  let ccontent = drawCidLine(cuse, csf, 72.0, 720.0, "F3", 24.0,
    ctext)
  let cfonts = b.finalizeFonts({"F3": cuse}.toTable)
  let ccnum = b.addContentStream(ccontent)
  discard b.addPage(612.0, 792.0, ccnum, fontResources(cfonts))
  echo "cid subset: full ", cprog.len, " bytes"
else:
  echo "cid micro font missing; cid page skipped"
writeFile("hello.pdf", b.buildPdf())

var d = openDoc(rewritePdf(readFile("hello.pdf")))
echo "pages: ", d.pageCount()
for p in 0 ..< d.pageCount():
  for r in d.extractText(p):
    echo "\"", r.text, "\" at (", r.x, ", ", r.y, ")"
