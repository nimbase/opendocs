# docx — build plan (locked)

Scope: **full model, preserve unknown parts, vendor fixtures, openparser
for XML** (`fromXml` DOM + strict policy `xpStrict`).

## 0. Deps — done

- `opendocs.nimble`: `zlib >= 0.2.0`, `openparser >= 0.3.4` (dev-mode
  discovery from `~/development/packages/openparser`).
- openparser XML change (this workstream): `XmlPolicy` enum
  (`xpLenient` default / `xpStrict`), `XmlOptions.policy` field, strict
  mismatch error in DOM `parseHook`, `opts` param on `fromXml` string /
  MemFile / file overloads. Verified: 41/41 openparser xml tests pass,
  strict raises on `</w:r>`-for-`<w:p>`, `w:` prefixes + `xml:space`
  preserved, `toXml` round-trips byte-exact.
- XML strategy: DOM walk comparing raw `"w:p"`/`"w:r"`/`"w:t"` tags.
  No typed `parseHook` for v1.

## 1. Module `src/opendocs/docx.nim`

Single file until ~1500 lines. `DocxError = object of CatchableError`,
wrapping `ZipError`/`OpenParserXmlError` with part-name context.

```nim
Run: text, bold, italic, underline, strike, sizeHalfPts, color,
     fonts, highlight, hyperlinkRid, drawingRid
Paragraph: styleId, align, numId/numIlvl, spacing/indent, runs
TableCell: paragraphs, gridSpan, vMerge, shading
Table: rows
Block = Paragraph | Table
DocxDocument:
  blocks, headers, footers, footnotes, endnotes, comments,
  styles (id → name/type), numbering (numId → levels),
  images: seq[(relId, contentType, bytes)],
  coreProps (title/author/created),
  rawParts: Table[string, seq[byte]]
```

Text mapping: `w:tab`/`w:br`/`w:cr` → `\t`/`\n`; `w:instrText` → keep
visible result; `w:txbxContent` recursed. Drawings/images by rel-id only.

## 2. Reader

1. `openZip` → require `word/document.xml`; optional styles, numbering,
   `word/_rels/document.xml.rels`, header*/footer*, footnotes, endnotes,
   comments, `docProps/core.xml`, `word/media/*`. One corrupt part =
   `DocxError` naming the part. Parse every XML part with `xpStrict`.
2. Walk `w:document/w:body`: `w:p` (pStyle, jc, numPr, r/t honoring
   `xml:space`), `w:tbl` (gridSpan, vMerge), `w:sectPr` (page size/margins
   stored + re-emitted). Unknown block-level elements skipped.
3. Unparsed parts (settings, fontTable, theme, customXml, …) → `rawParts`
   byte-exact.

## 3. Writer

Mirror `references/docx-rs/hello.docx` (17 parts): `[Content_Types].xml`,
`_rels/.rels`, `docProps/app+core(+custom)`, `word/document.xml`,
`styles.xml`, `settings.xml`, `fontTable.xml`, `numbering.xml` (iff lists),
`comments(+Extended).xml` (iff comments), rels, media.
- document/styles/numbering via string builder + openparser
  `xmlEscape`/`xmlAttrEscape`; prepend
  `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>`
  (`toXml` emits no declaration).
- `rawParts` re-emitted byte-exact; `[Content_Types].xml` synthesized over
  all emitted + preserved parts. Pack with `ZipWriter`.

## 4. Fixtures + tests (`tests/t_docx.nim`)

Vendor ~10 small `docx-rs/fixtures/` dirs + `hello.docx` to
`tests/fixtures/docx/` (license check). `hello.json` as text oracle.
Tests: fixture parse counts/spot-checks, no-crash sweep, write→read
round-trip (headings, table merge, list, hyperlink, image bytes),
read→write→read (`rawParts` byte-identical, `unzip -t` clean), malformed
inputs raise `DocxError` with part name.

## 5. Order (each gated by `clue test`)

types → document.xml reader → styles/numbering/rels/images → secondary
parts → writer → preserve → fixtures/interop.

Risks: openparser lenient default — always pass explicit strict opts in
docx code; `dumpHook` self-closes empties (fine for Word, normalize in
diff tests); depth cap for hostile nesting to be added in reader.
