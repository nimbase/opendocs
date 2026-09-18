## Merge and split: combine pages from several files, extract subsets.
import ../src/opendocs/pdf
import ../src/opendocs/pdf/cos
import ../src/opendocs/pdf/docmodel
import ../src/opendocs/pdf/write

proc helvResources(): CosObj =
  let f1 = CosObj(kind: coDict, keys: @["Type", "Subtype", "BaseFont"],
    vals: @[CosObj(kind: coName, name: "Font"),
      CosObj(kind: coName, name: "Type1"),
      CosObj(kind: coName, name: "Helvetica")])
  CosObj(kind: coDict, keys: @["Font"],
    vals: @[CosObj(kind: coDict, keys: @["F1"], vals: @[f1])])

proc textPdf(lines: seq[string]): string =
  var b = newPdfBuilder()
  for line in lines:
    let cnum = b.addContentStream(
      "BT /F1 24 Tf 72 720 Td (" & line & ") Tj ET")
    discard b.addPage(612.0, 792.0, cnum, helvResources())
  b.buildPdf()

# Two single-page sources built in memory.
var a = openDoc(textPdf(@["Alpha page"]))
var b = openDoc(textPdf(@["Beta page"]))

# Merge: every page of each donor, in order.
var donors = @[a, b]
var m = openDoc(mergePdfs(donors))
echo "merged pages: ", m.pageCount()
for p in 0 ..< m.pageCount():
  for r in m.extractText(p):
    echo "  p", p, ": \"", r.text, "\""

# Split: reorder and repeat pages of the merged file.
var both = openDoc(mergePdfs(donors))
var s = openDoc(extractPages(both, @[1, 0, 1]))
echo "split pages: ", s.pageCount()
for p in 0 ..< s.pageCount():
  for r in s.extractText(p):
    echo "  p", p, ": \"", r.text, "\""

writeFile("merged.pdf", mergePdfs(donors))
echo "wrote merged.pdf"
