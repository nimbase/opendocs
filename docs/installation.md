# Installation

Requires Nim >= 2.0.0.

```sh
nimble install opendocs
```

or with `clue`:

```sh
clue install opendocs
```

Dependencies (from `opendocs.nimble`):

- `archive >= 0.1.0` ([nimbase/archive](https://github.com/nimbase/archive)) — used by `zip.nim` for flate/crc32/io
- `image >= 0.1.0` ([nimbase/image](https://github.com/nimbase/image)) — used by `exports.nim` and PDF image pipeline
- `openparser >= 0.3.4` — XML parsing for XLSX/DOCX, colors, tempfiles
- `nimcypher >= 0.2.4` — PDF encryption (RC4/AES)
- `https://github.com/nimbase/harfnim` — text shaping, measuring, subsetting TTF/OpenType

Source layout:

```text
src/opendocs.nim        # stub, do not import directly
src/opendocs/docx.nim   # DOCX reader + writer + builder + revisions
src/opendocs/docx/      # types, reader, writer, core, emit
src/opendocs/pdf.nim    # PDF high-level reader + Pdf writer
src/opendocs/pdf/       # 27 modules: cos, lexer, xref, crypt, filters, content, gstate, docmodel, document, cmap, text, doctext, sheet, write, merge, forms, attach, sign, images, imgpipe, shape, fontembed, etc.
src/opendocs/xlsx.nim   # XLSX reader (includes types, base, cell, styles, numfmt, workbook, sharedstrings, sheet, richtext, reader)
src/opendocs/xlsx/      # implementation includes
src/opendocs/zip.nim    # ZIP package layer
src/opendocs/exports.nim # image export helpers
```
