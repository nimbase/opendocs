# PDF Reading

Entry: `src/opendocs/pdf.nim` re-exports reader modules. Low-level handle `PdfDoc`, high-level handle `PdfDocument`.

```nim
import opendocs/pdf

let doc = openPdf("file.pdf")
echo doc.version, " pages: ", doc.pageCount
echo openPdfPassword(readFile("enc.pdf")) # true if /Encrypt present

var d = openDoc(readFile("file.pdf"))
echo d.pageCount()
for run in d.extractText(0):
  echo run.text, " @", run.x, ",", run.y
d.close()

var m = openMappedDoc("big.pdf") # mmap, not full copy
defer: m.close()
```

## Handles

- `PdfDocument(version, pages, hasEncrypt)` in `pdf/document.nim`.
  - `readPdfBytes(string|seq[byte], limits, password): PdfDocument`
  - `openPdf(path, limits, password): PdfDocument` (mmap snapshot)
  - `openPdfPassword(data)`, `openPdfPasswordFile(path)` — `/Encrypt` presence
  - `pageCount(PdfDocument)`
- `PdfDoc(data: PdfSource, xref, limits, cache, crypt)` in `pdf/docmodel.nim`.
  - `openDoc(PdfSource|string, limits, password)`, `openMappedDoc(path)`, `close` (idempotent), `cacheSize`
  - `resolve(ref, depth)` — cache, cycle guard, indirect `/Length`, ObjStm, decrypt
  - `catalog`, `pageCount(var PdfDoc)`, `pageBoxes(): seq[PageBox]`
- Limits: `PdfLimits(maxPages, maxScanBytes, maxObjects, maxWalkDepth, maxContentOps, maxImagePixels, maxNestedXObject)` in `pdf/types.nim`, `defaultPdfLimits()`, `checkCount()`. `PdfError` on violation.

## Parsing stack

- `source.nim`: `PdfSource(base, slen, owned, map)`, `slice(a, b)`, `fromString/fromFile/mapFile`, `isMapped`, `close`.
- `lexer.nim`: `Lexer`, `skipWsAndComments`, `peek`, `atEnd`, `parsePdfVersion`, `readTableInt`, hex helpers.
- `cos.nim`: `CosKind(coNull/coBool/coInt/coFloat/coName/coStr/coRef/coArray/coDict/coStream)`, `CosObj`, `dictGet`, `asFloat/asInt/asName`, `parseCosValue`, `parseStreamBody`, `parseIndirect` (direct `/Length` only).
- `xref.nim`: `XRefEntry(offset, gen, live, compressed, stmNum, stmIdx)`, `XRef(entries, root, encrypt, ids, size)`, `parseStartxref`, `parseXRef` (classic + xref-stream `/W/Index/Prev`, ObjStm entries).
- `filters.nim`: `flateDecode/deflateEncode`, `applyPredictor`, `lzwDecode`, `ascii85Decode`, `asciiHexDecode`, `runLengthDecode`, `canonFilterName`, `isPassthrough` (DCT/JPX/JBIG2/CCITT), `decodeChain`, `decodeCosStream`.
- `content.nim`: `ContentOp(name, operands)`, `parseContentStream` (inline `BI..ID..EI` as `BI` op).
- `gstate.nim`: `Matrix[6]`, `TextState`, `GState`, `WalkedOp`, `BBoxRect`, `initGState`, `applyOp` (q/Q/cm/BT/ET/Tm/Td/TD/T*/Tf/Tc/Tw/Tz/TL/Tr/Ts), `walkOps`, `pageDicts/pageResources/pageContentStream`, `walkPageOps`, `lookupXObject`, `walkNested` (Form `Do` expansion, per-invocation CTM, `/Matrix/BBox/Resources`, `maxNestedXObject`).

Encrypted files: pass `password` to `openDoc/openPdf/readPdfBytes`. See `pdf-encryption.md`. `merge/write/forms/attach/sign` reject encrypted inputs.
