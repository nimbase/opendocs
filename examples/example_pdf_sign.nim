## Document signatures: placeholder shell plus ByteRange integrity.
##
## Appends an unsigned signature shell, reads it back, hashes the
## signed ranges, then shows that editing a signed byte flips the
## digest while touching only the Contents gap does not. Real CMS
## signing (the bytes an external signer would inject into the gap)
## is P4b work.
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

let draft = addSignaturePlaceholder(blankPdf(), "Signature1", 1024)
echo "bytes: ", draft.file.len
echo "byteRange: ", draft.byteRange
echo "contents span: ", draft.contentsAt, "+",
  draft.contentsLen

var d = openDoc(draft.file)
for s in docSignatures(d):
  echo s.field, ": ", s.filter, " / ", s.subFilter,
    " signed=", s.signed, " date=", s.signDate

let sig = docSignatures(d)[0]
let digest = verifyByteRangeHash(draft.file, sig)
echo "sha256 over signed ranges: ", digest

var edited = draft.file
edited[20] = chr(ord(edited[20]) xor 0xFF)
echo "edited byte flips digest: ",
  verifyByteRangeHash(edited, sig) != digest

var gap = draft.file
gap[draft.contentsAt + 4] = 'F'
echo "gap-only touch keeps digest: ",
  verifyByteRangeHash(gap, sig) == digest

writeFile("sign-shell.pdf", draft.file)
echo "wrote sign-shell.pdf (unsigned shell, zeroed Contents)"
