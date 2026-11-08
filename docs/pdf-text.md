# PDF Text Extraction

Modules: `pdf/text.nim`, `pdf/doctext.nim`, `pdf/sheet.nim`, plus `pdf/cmap.nim`, `pdf/cjkmaps.nim`, `pdf/cjkdata.nim`, `pdf/sfntcmap.nim`.

```nim
import opendocs/pdf

var d = openMappedDoc("tests/data/pdf/file-example_PDF_500_kB.pdf")

let doc = d.extractDocumentText("1.4")
echo doc.pageCount
echo doc.text().len
for h in doc.searchText("Lorem"):
  echo "p", h.page, " line ", h.line, " col ", h.col, ": ", h.excerpt
d.close()
```

## Runs (`text.nim`)

- `FontDecoder(fontName, codeLen, cmap, diff, baseWinAnsi, widths, composite, ordering, encName, codes, sfntCmap, cidToGid, wmode, dw2vy, w2, ...)`.
- `TextRun(text, x, y, size, fontName, w, vert)`.
- `loadDecoder(d, fontRef, name)`, `showTextRun(d, wo, gs, cache, s): Option[TextRun]`, `extractText(d, index): seq[TextRun]` — handles `Tj/TJ/'/"`, `Tc/Tw/Tz/TL/Tr/Ts/Tm/Td`, ToUnicode -> Encoding/CMap -> sfnt -> ROS, `/W/DW/W2/DW2`, `WMode 1` vertical, Form `/BBox` clip.

## Document text (`doctext.nim`)

- `TextLine(text, x, y, size, runs, starts, idx)`, `TextBlock(text, x, y, w, h, lines)`, `PageText(index, width, height, runs, lines, blocks, text)`, `DocumentText(version, pages)`, `TextHit(page, line, col, x, y, size, fontName, excerpt)`, `maxExcerptLen = 120`.
- `pageCount(DocumentText)`, `text(DocumentText)` (FF-joined), `joinRuns`, `groupLines(lineTol, wordTol)`, `groupBlocks(blockGap)`, `pageText(d, index)`, `extractDocumentText(d, version)`, `searchText(doc, query, caseSensitive)` — exact, ASCII-fold.

CJK needs no flags: Identity-H/V without ToUnicode resolves via built-in ordering tables (Japan1/GB1/CNS1/Korea1), predefined encodings, or embedded font. Vertical (`WMode 1`) groups into columns. Unmapped stays U+FFFD.

Fuzzy search is caller-side (`openparser/fuzzy`):

```nim
import openparser/fuzzy
var lines: seq[string] = @[]
for p in doc.pages:
  for b in p.blocks:
    lines.add(b.text)
for m in fuzzySearch("lorem", lines, FuzzyOptions(limit: 3)):
  echo m.score, ": ", m.text
```

## Sheet (`sheet.nim`)

```nim
var d = openMappedDoc("tests/data/pdf/file-example_PDF_500_kB.pdf")
let sheet = d.extractSheet("1.4")
for p in sheet.pages:
  for t in p.tables:
    echo t.rows.len, "x", (if t.headers.len > 0: t.headers.len elif t.rows.len > 0: t.rows[0].len else: 0)
d.close()
```

- `BlockKind(bkHeading/bkParagraph/bkListItem/bkCaption/bkOther)`, `SheetRow(kind, text, x, y, w, h, size)`, `PdfTable(page, x, y, w, h, headers, rows)`, `SheetPage(index, width, height, rows, tables)`, `Sheet(version, pages)`.
- `pageCount(Sheet)`, `bodySize`, `classifyBlock`, `detectTables`, `sheetPage(d, index)`, `extractSheet(d, version)` — rows classified + whitespace-grid tables.

## CMaps

- `cmap.nim`: `CodeRange(lo, hi, len)`, `CMap(entries, maxKeyLen, codes, cids, hasCids)`, `winAnsiTable/macRomanTable`, `parseCMap`, `parseToUnicode` (bfchar/bfrange, UTF-16BE + surrogates), `glyphNameToUnicode` (Adobe + `uniXXXX/uXXXXXX`).
- `cjkmaps.nim`: `cidToUnicode(ordering, cid)`, `codeToCid(cmapName, code)`, `codeToUnicode`, `cmapCodespaces`.
- `cjkdata.nim`: generated Adobe CMaps (`rosJapan1/GB1/CNS1/Korea1`, `enc90ms-RKSJ-H/V`, GBK/EUC/CNS/KSC families). `rosCids`, `encRanges/Codes/Unicodes`, `hasCjkOrdering/Encoding`.
- `sfntcmap.nim`: `parseSfntCmap(fontBytes): Table[gid, unicode]` (formats 4+12, never fails).
