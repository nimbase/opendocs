<p align="center">
  Open parsers and writers for popular graphics file formats<br>
</p>

<p align="center">
  <code>nimble install opendocs</code> | <code>clue install opendocs</code>
</p>

<p align="center">
  <a href="https://nimbase.github.io/opendocs/">API reference</a><br>
  <img src="https://github.com/nimbase/opendocs/workflows/test/badge.svg" alt="Github Actions">  <img src="https://github.com/nimbase/opendocs/workflows/docs/badge.svg" alt="Github Actions">
</p>


## Features
- Read & Write DOCX and PDFs programatically
- Encrypt & Decrypt using [nimcypher](https://github.com/nimbase/nimcypher)
- Built-in compressor and decompressor via [zlib](https://github.com/status-im/nim-zlib)
- Text shaping & Font embedding via [harfbuzz](https://github.com/nimbase/harfbuzz-nim)<br>
  _shaping, measuring, wrapping & subsetting TTF/OpenType, incl. CJK & emoji_
- High-performance image handling via [libvips](https://github.com/openpeeps/libvips-nim) (TO BE MOVED AT NIMBASE)<br>
  _decode, resize & recompress JPEG/PNG with alpha for embedding & extraction_
- DOCX Reader and Writer
  - Paragraphs, runs, text formatting, borders, tabs, and breaks
  - Inline and floating images
  - Tables, nested tables, numberig, styles, and theme colors
  - Headers, footers, page settings and sections
  - Hyperlinks, bookmarks, comments, footnotes, and tracked changes
  - Tables of contents, structured data tags, custom properties and custom XML
- PDF read and write: parse, build, rewrite, and incremental update
  - Encryption RC4, AES-128, AES-256 (R2-R6)
  - Signatures: list fields, check ByteRange digests, append unsigned placeholder shells
  - Form filling (text, checkbox, radio, dropdown)
  - Form flattening (fields into page content)
  - Merge & Split (Combine or extract specific pages)
  - Attachments: Embed and extract files
  - Text extraction with position info
  - Font Embedding TTF/OpenType with subsetting
  - Images JPEG PNG (supporting alpha)
  - Incremental saves: Append changes, preserve signatures

## Examples

### DOCX reader

```nim
import opendocs/docx

let doc = readDocx("report.docx")  # or readDocxBytes(bytes)
echo flatText(doc)

for b in doc.blocks:
  case b.kind
  of bkParagraph:
    for r in b.paragraph.runs:
      echo r.text, " bold=", r.bold,
        " color=#", effectiveColor(r, doc.themeColors)
  of bkTable:
    for row in b.table.rows:
      for cell in row.cells:
        echo "cell span=", cell.gridSpan, " merge=", cell.vMerge
  of bkTextbox: echo "textbox with ", b.textbox.blocks.len, " blocks"
  of bkSdt: echo "content control: ", b.sdt.alias
```

Sections, headers, footers and page settings via getters:

```nim
echo getSections(doc).len
let ps = getPageSettings(doc)  # last section by default
echo ps.pgW, "x", ps.pgH, " ", ps.orient
for b in getHeaders(doc, 0, "default"):
  echo b.kind
for n in doc.footnotes: echo "note #", n.id
for c in doc.comments: echo "#", c.id, " by ", c.author
for img in doc.images: echo img.relId, " ", img.contentType
```

`DocxError` is raised for corrupt packages, with the offending part
named in the message. Strict XML parsing rejects mismatched tags.

Large documents can spill parts to temp files instead of holding them
in memory (threshold-gated, capped, always cleaned up):

```nim
let doc = readDocx("huge.docx", DocxReadOpts(
  spillThresholdBytes: 64 * 1024 * 1024, # spill past 64MB inflated
  spillCapBytes: 512 * 1024 * 1024))     # hard disk-use cap
# spillThresholdBytes = 0 forces spill (testing); < 0 disables it.
```

Full showcase: [`examples/docx_read_example.nim`](examples/docx_read_example.nim)
— run it with `clue build examples/docx_read_example.nim`.

### PDF Documents
#### Reading a .pdf file
```nim
import opendocs/pdf

# High-level handle: version, page count, metadata.
let doc = openPdf("tests/data/pdf/m3b_text.pdf")
echo "PDF ", doc.version, " pages: ", doc.pageCount

# Low-level handle: positioned text runs (string plus x/y origin).
var d = openDoc(readFile("tests/data/pdf/m3b_text.pdf"))
for run in d.extractText(0):
  echo "\"", run.text, "\" at (", run.x, ", ", run.y, ")"

# Embedded images decode through libvips (JPEG, JPX, masks, CMYK).
var imgs = openDoc(readFile("tests/data/pdf/m5_images.pdf"))
for im in imgs.pageImages(0):
  echo im.name, ": ", im.width, "x", im.height, " ", im.encoding
  im.saveImage("/tmp/" & im.name & ".png")

# Encrypted files announce themselves; pass the password to open.
echo "needs password: ", openPdfPassword(readFile("tests/data/pdf/m4_rc4.pdf"))
let locked = openPdf("tests/data/pdf/m4_rc4.pdf", password = "user123")
echo "unlocked pages: ", locked.pageCount
```

#### Writing a .pdf file (high level)
```nim
import opendocs/pdf

# A4 by default (psLetter, psLegal, psA5, psA3, psCustom available).
# No font file needed: the body starts on builtin Helvetica
# (unembedded, viewer-rendered, WinAnsi text only).
var doc = newPdf()
# Or start embedded: the program shapes via HarfBuzz and embeds as a
# subset on save, with full Unicode.
# var doc = newPdf("../harfbuzz/tests/data/DejaVuSans.ttf")
doc.setTitle("Hello")
doc.heading("Hello writer")
doc.paragraph("Wrapped on shaped widths, auto page breaks.")
doc.textAt("absolute at x, y", 72.0, 72.0)

# JPEG embeds byte-for-byte; anything else embeds lossless.
# With compress the pixels run through libvips (optional downscale
# to maxWidthPx, alpha over white) and re-encode at jpegQuality.
doc.imageFromFile("photo.jpg")
doc.imageFromFile("photo.jpg", ImageOpts(compress: true,
  jpegQuality: 60, maxWidthPx: 800, widthPt: 400.0))

doc.save("hello.pdf")
doc.close()
```

#### Writing a .pdf file (low level)
```nim
import opendocs/pdf
import opendocs/pdf/write
import opendocs/pdf/cos
import opendocs/pdf/docmodel
import opendocs/pdf/text

var b = newPdfBuilder() # catalog 1, page tree 2, content from 3 up

# A content stream is just marked-up text: font F1 at 24pt, positioned
# at (72, 720). Streams Flate-compress by default.
let cnum = b.addContentStream(
  "BT /F1 24 Tf 72 720 Td (Hello writer) Tj ET")

# Pages point at a /Resources dict; here F1 is plain Helvetica
# (not embedded, so any reader can render it).
let helv = CosObj(kind: coDict, keys: @["Type", "Subtype", "BaseFont"],
  vals: @[CosObj(kind: coName, name: "Font"),
    CosObj(kind: coName, name: "Type1"),
    CosObj(kind: coName, name: "Helvetica")])
let res = CosObj(kind: coDict, keys: @["Font"],
  vals: @[CosObj(kind: coDict, keys: @["F1"], vals: @[helv])])
discard b.addPage(612.0, 792.0, cnum, res)
writeFile("hello.pdf", b.buildPdf())

# Read it back through a defragmenting rewrite (fresh offsets).
var d = openDoc(rewritePdf(readFile("hello.pdf")))
echo "pages: ", d.pageCount()

# Or append without rewriting: new objects plus an xref with /Prev.
var u = beginUpdate(readFile("hello.pdf"))
# ... u.addObject(...) / u.updateObject(...) ...
writeFile("hello-v2.pdf", u.finishUpdate())
```

#### Embedding a font (harfbuzz, low level)
```nim
import opendocs/pdf
import opendocs/pdf/write
import opendocs/pdf/shape
import opendocs/pdf/fontembed
import std/tables

# Any TrueType/OpenType program works; DejaVu ships with harfbuzz.
let prog = readFile("../harfbuzz/tests/data/DejaVuSans.ttf")

# One cached HarfBuzz face per program: shaping, measuring, subsetting.
var sf = openShapedFont(prog)
defer: close(sf)

# Collect every codepoint you draw; the subset is cut at the end.
var use = FontUse(fontBytes: prog, baseName: "DejaVuSans")
var content: string

# wrapText breaks on shaped widths so lines fit the 468pt column.
for i, line in wrapText(sf, "Hello embedded writer", 24.0, 468.0):
  use.noteUse(line) # WinAnsi only; anything else fails loudly
  content.add(drawTextLine(72.0, 720.0 - float64(i) * 28.0,
    "F2", 24.0, line) & "\n")
var b = newPdfBuilder()

# finalizeFonts subsets the program, embeds it with matching /Widths
# and /ToUnicode, and returns resource name to font object number.
let fonts = b.finalizeFonts({"F2": use}.toTable)
let cnum = b.addContentStream(content)
discard b.addPage(612.0, 792.0, cnum, fontResources(fonts))
writeFile("embedded.pdf", b.buildPdf())
```

#### Full Unicode (CID-keyed Type0, low level)
```nim
import opendocs/pdf
import opendocs/pdf/write
import opendocs/pdf/shape
import opendocs/pdf/fontembed
import std/tables

# Any TrueType/OpenType program works, including CFF outlines and
# CBDT color emoji; the CJK micro-subset ships under tests/data/fonts.
let prog = readFile("tests/data/fonts/cjk-cff-micro.otf")
var sf = openShapedFont(prog)
defer: close(sf)

# CIDs key on shaped glyphs (ligatures, reordering), so the open
# font travels with the use from the first call.
var use = CidFontUse(fontBytes: prog, baseName: "NotoSansJP")

# Lines shape through HarfBuzz and show as 2-byte Identity-H CIDs;
# kern corrections land in the TJ array automatically.
let content = drawCidLine(use, sf, 72.0, 720.0, "F3", 24.0, "日本語あAX")
var b = newPdfBuilder()

# finalizeFonts embeds a Type0 font (CIDFontType0/FontFile3 for CFF,
# CIDFontType2/FontFile2 for TrueType) with /CIDToGIDMap, /W and
# /ToUnicode, so our own reader round-trips the text unchanged.
let fonts = b.finalizeFonts({"F3": use}.toTable)
let cnum = b.addContentStream(content)

discard b.addPage(612.0, 792.0, cnum, fontResources(fonts))
writeFile("cid.pdf", b.buildPdf())
```

#### Document text and search
```nim
import opendocs/pdf

# Memory-mapped: the 500kB file is never fully copied.
var d = openMappedDoc("tests/data/pdf/file-example_PDF_500_kB.pdf")

# Runs grouped into lines, blocks, and pages of plain text.
let doc = d.extractDocumentText("1.4")
echo "pages: ", doc.pageCount

# Exact substring search from the stdlib, with page/line/col hits.
for h in doc.searchText("Lorem"):
  echo "p", h.page, " line ", h.line, " col ", h.col, ": ", h.excerpt
d.close()

# CJK needs no flags: Identity-H fonts without ToUnicode resolve
# through built-in ordering tables (Japan1/GB1/CNS1/Korea1),
# predefined encodings, or the embedded font itself. Vertical
# (WMode 1) text groups into columns. Unmapped codes stay U+FFFD,
# never guesses.

# Fuzzy search is caller-side (openparser), not an opendocs dep.
import openparser/fuzzy
var lines: seq[string] = @[]
for p in doc.pages:
  for b in p.blocks:
    lines.add(b.text)
for m in fuzzySearch("lorem", lines, FuzzyOptions(limit: 3)):
  echo "fuzzy score ", m.score, ": ", m.text
```

#### Sheet rows and tables
```nim
import opendocs/pdf

var d = openMappedDoc("tests/data/pdf/file-example_PDF_500_kB.pdf")
# Each page as classified rows (heading/paragraph/list/caption/other)

# plus whitespace-grid tables (headers and rows of cell strings).
let sheet = d.extractSheet("1.4")
for p in sheet.pages:
  for t in p.tables:
    let ncols = if t.headers.len > 0: t.headers.len
      elif t.rows.len > 0: t.rows[0].len else: 0
    echo "table: ", t.rows.len, " rows x ", ncols, " cols"
    for r in t.rows:
      echo "  ", r.join(" | ")
d.close()
```

### Roadmap
- [x] ZIP package layer (stored/deflated, writer, spill-to-disk)
- [x] DOCX reader (runs, tables, numbering, styles, images, headers/footers, notes, comments, textboxes, SDT)
- [x] DOCX writer (full package assembly, model-identical round-trips, LibreOffice PDF acceptance)
- [x] DOCX typed fields (complex + simple, all instruction kinds)
- [x] DOCX tracked changes (run/body wrappers, marks, changes, ranges, rsids, accept-view text)
- [x] PDF read/write (parse, build, encrypt, sign, fill, flatten, merge, extract, embed, incremental)
- [ ] Legacy DOC read + write (binary Word format)
- [ ] ODT read + write
- [ ] RTF read + write
- [ ] TXT read + write
- [x] XLSX reader Phase A (lazy sheets, shared strings, raw values, A1 utils; xlsx/xlsm/xltx/xltm/xlam open flow)
- [x] XLSX reader Phase B (eager styles, builtin formats, dates, 576-cell excelize oracle parity)
- [ ] XLSX reader Phase C (rich text, hyperlinks, merges, dimensions, docProps)
- [ ] XLSX reader Phase D (read-only OLE for vbaProject.bin)
- [ ] XLSX writer
- [ ] PPTX read + write
- [ ] DOCX high-level builder API (compose documents without touching the model)
- [ ] DOCX accept/reject revisions API

### ❤ Contributions & Support
- 🐛 Found a bug? [Create a new Issue](https://github.com/nimbase/opendocs/issues)
- 👋 Wanna help? [Fork it!](https://github.com/nimbase/opendocs/fork)

### 🎩 License
MIT license | Nim Community.
