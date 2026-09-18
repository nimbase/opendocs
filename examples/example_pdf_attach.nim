## Embedded files: attach at build time, append later, extract back.
import ../src/opendocs/pdf
import ../src/opendocs/pdf/cos
import ../src/opendocs/pdf/docmodel
import ../src/opendocs/pdf/write

proc blankPdf(): string =
  var b = newPdfBuilder()
  let res = CosObj(kind: coDict, keys: @[], vals: @[])
  discard b.addPage(200.0, 200.0, b.addContentStream("", flate = false),
    res)
  b.buildPdf()

# Attach at build time; the catalog /Names tree is emitted on build.
var b = newPdfBuilder()
let res = CosObj(kind: coDict, keys: @[], vals: @[])
discard b.addPage(200.0, 200.0, b.addContentStream("", flate = false),
  res)
discard b.embedFile("hello.txt", "Hello attachment",
  desc = "greeting", mime = "text/plain")
discard b.embedFile("data.bin", "\x00\x01\x02\x03")
let base = b.buildPdf()

var d = openDoc(base)
for f in embeddedFiles(d):
  echo f.name, ": ", f.data.len, " bytes (", f.mime, ") desc='",
    f.desc, "'"

# Append one more file incrementally; history stays intact.
var donor = openDoc(base)
var u = beginUpdate(base)
u.embedFileUpdate(donor, "added.txt", "late bytes")
let v2 = u.finishUpdate()

var d2 = openDoc(v2)
echo "after update:"
for f in embeddedFiles(d2):
  echo "  ", f.name, ": ", f.data.len, " bytes"
echo "pages still: ", d2.pageCount()

writeFile("attached.pdf", v2)
echo "wrote attached.pdf"
