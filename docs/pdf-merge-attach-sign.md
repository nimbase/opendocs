# PDF Merge, Attachments, Signatures

## Merge / split (`pdf/merge.nim`)

```nim
import opendocs/pdf

var a = openDoc(readFile("a.pdf"))
var b = openDoc(readFile("b.pdf"))
writeFile("merged.pdf", mergePdfs(@[readFile("a.pdf"), readFile("b.pdf")]))
writeFile("pages.pdf", extractPages(a, @[0, 2]))
```

- `PageRef(pageRef, mediaBox, resources)` — inherited, materialized.
- `pageRefs(d)`, `copyPage(b, donor, index): newNum` (deep clone, fresh numbers, stream bytes untouched), `extractPages(donor, pages): string` (ordered, repeats allowed), `mergePdfs(donors): string`.

Rejects encrypted inputs. See `examples/example_pdf_merge.nim`, `tests/t_pdf_merge.nim`.

## Attachments (`pdf/attach.nim`)

```nim
import opendocs/pdf
import opendocs/pdf/write

var d = openDoc(readFile("a.pdf"))
for f in embeddedFiles(d):
  echo f.name, " ", f.data.len, " ", f.mime

var b = newPdfBuilder()
let spec = embedFile(b, "note.txt", "hi", desc = "note")
writeFile("with-attach.pdf", b.buildPdf())
```

- `FileAttachment(name, fileName, desc, mime, data)`.
- `guessMime(name)`, `embeddedFiles(d): seq[FileAttachment]` (flat + `/Kids` name tree, `/EF F|UF`, decoded), `embedFile(b, name, data, desc, mime): specNum` (surfaced in `buildPdf` catalog `/Names/EmbeddedFiles`), `embedFileUpdate(u, donor, name, data, desc, mime)` (keep old specs by ref, sorted merge).

See `examples/example_pdf_attach.nim`, `tests/t_pdf_attach.nim`.

## Signatures (`pdf/sign.nim`)

```nim
import opendocs/pdf

var d = openDoc(readFile("signed.pdf"))
for s in docSignatures(d):
  echo s.field, " signed=", s.signed, " ", s.byteRange
  echo verifyByteRangeHash(readFile("signed.pdf"), s)

let draft = addSignaturePlaceholder(readFile("a.pdf"), "Sig1", 8192)
# write draft.file, sign externally, patch contentsAt..contentsAt+contentsLen
```

- `DocSignature(field, filter, subFilter, byteRange[4], hasByteRange, contents, signed, reason, location, contact, signDate)`, `SigDraft(file, field, byteRange, contentsAt, contentsLen)`.
- `docSignatures(d)`, `verifyByteRangeHash(data, sig): hex SHA-256` (`r1+r2` ranges), `addSignaturePlaceholder(base, fieldName, size): SigDraft` (incremental `/Sig/Adobe.PPKLite/adbe.pkcs7.detached`, zeroed `/Contents` hex, patched `/ByteRange`, invisible field, joins/creates `/AcroForm`).

See `examples/example_pdf_sign.nim`, `tests/t_pdf_sign.nim`.
