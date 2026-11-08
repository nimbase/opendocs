# PDF Writing

Two levels: high-level `Pdf` composer in `src/opendocs/pdf.nim`, low-level `PdfBuilder` in `src/opendocs/pdf/write.nim`.

## High-level (`Pdf`)

```nim
import opendocs/pdf

var doc = newPdf() # A4, builtin Helvetica, WinAnsi only
# var doc = newPdf("tests/data/fonts/DejaVuSans.ttf") # embedded subset, full Unicode
doc.setTitle("Hello")
doc.heading("Hello writer")
doc.paragraph("Wrapped on shaped widths, auto page breaks.")
doc.textAt("absolute at x, y", 72.0, 72.0)
doc.imageFromFile("photo.jpg")
doc.imageFromFile("photo.jpg", ImageOpts(compress: true, jpegQuality: 60, maxWidthPx: 800, widthPt: 400.0))
doc.save("hello.pdf")
doc.close()
```

- `PageSize(psA5/psA4/psA3/psLetter/psLegal/psCustom)`, `ImageOpts(compress, jpegQuality, maxWidthPx, widthPt)`.
- `Pdf(builder, pages, curContent, curImages, pageW/H, margin, cursorY, fonts, fontOrder, curFont/Size, title/author, nextImage)`.
- `pageDims`, `newPdf(fontPath|builtin|fontBytes+baseName; size, customW/H, margin)`, `loadFont(name, path)`, `setFont(name, size)`, `fontNames`, `setPageSize`, `setMargin`, `setTitle/setAuthor`, `newPage`, `pageCount(Pdf)`, `paragraph`, `heading(text, size)`, `textAt(text, x, y, size)`.
- `imageFromFile(path, opts)` — JPEG embeds byte-for-byte; anything else embeds lossless. With `compress` pixels go through `image` package (optional downscale to `maxWidthPx`, alpha over white) and re-encode at `jpegQuality`. CMYK/YCCK guarded.
- `build(): string`, `save(path)`, `close` (releases harfnim).

## Low-level (`PdfBuilder`)

```nim
import opendocs/pdf
import opendocs/pdf/write
import opendocs/pdf/cos

var b = newPdfBuilder() # catalog 1, page tree 2, content from 3 up
let cnum = b.addContentStream("BT /F1 24 Tf 72 720 Td (Hello writer) Tj ET")
let helv = CosObj(kind: coDict, keys: @["Type", "Subtype", "BaseFont"],
  vals: @[CosObj(kind: coName, name: "Font"),
    CosObj(kind: coName, name: "Type1"),
    CosObj(kind: coName, name: "Helvetica")])
let res = CosObj(kind: coDict, keys: @["Font"],
  vals: @[CosObj(kind: coDict, keys: @["F1"], vals: @[helv])])
discard b.addPage(612.0, 792.0, cnum, res)
writeFile("hello.pdf", b.buildPdf())

var d = openDoc(rewritePdf(readFile("hello.pdf")))
echo d.pageCount()

var u = beginUpdate(readFile("hello.pdf"))
writeFile("hello-v2.pdf", u.finishUpdate())
```

- Consts: `catalogNum = 1`, `pagesNum = 2`, `firstContentNum = 3`.
- Types: `RawObj(num, gen, body)`, `PdfBuilder(objs, kids, nextNum, infoTitle/Author, attachSpecs)`, `PdfUpdate(base, added, nextNum, rootNum/Gen, ids, prevStart, baseSize, limits)`.
- `writeStr/writeCos/writeIndirect`, `newPdfBuilder`, `setInfo`, `addObject(body)`, `addValue`, `addStream` (normalizes `/Length`), `addContentStream(flate)`, `addPage(w, h, contentNum, resources)`, `adoptPage`, `addJpegImage/addRgbImage`, `buildPdf`.
- `rewritePdf(src, reflate)` — defragmenting rewrite (fresh offsets). Unencrypted only, DCT/JPX passthrough.
- `beginUpdate(base)`, `addObject(u, ...)`, `updateObject(num, body)`, `finishUpdate` — append without rewriting, new objects + xref with `/Prev`.

Covers `tests/t_pdf_write.nim`, `t_pdf_docwrite.nim`, `examples/example_pdf*.nim`.
