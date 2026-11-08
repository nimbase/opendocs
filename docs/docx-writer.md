# DOCX Writer

Implementation: `src/opendocs/docx/writer.nim` + `writeDocxBytes/writeDocx` in `src/opendocs/docx/core.nim:116,136`. Low-level XML helper in `src/opendocs/docx/emit.nim`.

## Writing

```nim
let bytes = writeDocxBytes(doc)
writeDocx(doc, "out.docx")
```

- `writeDocxBytes(doc): seq[byte]` — serialize to complete `.docx` in memory. Modeled parts regenerated; `rawParts` re-emitted byte-exact except superseded (same name or per-part `.rels` for regenerated part); `_rels/.rels` always regenerated. `ZipError` -> `DocxError`.
- `writeDocx(doc, path)` — file wrapper, `DocxError` on open/short-write.
- `buildPackage(doc): seq[(name, content)]` (`writer.nim:1334`) — assemble full part set on validated copy. Validates, allocates header/footer/media names collision-free vs `rawParts`, fixed rel-ids `rId1...` yielding to model rids, per-part rels, `[Content_Types].xml` synthesis. Caller merges `rawParts` + zips.
- `writeDocumentXml(doc): string` (`writer.nim:602`) — body sections to `word/document.xml`. Non-final `sectPr` rides in last paragraph `pPr`, else trailing carrier paragraph.
- `writeNumberingXml(doc): string` (`writer.nim:689`) — `numberingDefs` to `word/numbering.xml`. Shared `abstractId` emitted once; conflicting level sets -> `DocxError`.
- `writeStylesXml(doc): string` (`writer.nim:726`) — `styles` to `word/styles.xml`. `tblPrRaw` verbatim.
- `serializeInstr(instr): string` (`writer.nim:192`) — canonical instruction text for freshly built runs (no `instrRaw`). `fikNone -> ""`, `fikUnsupported -> raw`. Read-back prefers `instrRaw`.
- `CommentsExtendedShell` const (`writer.nim:1173`) — verbatim Word empty Modern-Comments shell.

## Validation (`validateDoc`, `writer.nim:990`)

- `numId` without definition
- unknown hyperlink/image rid, empty image rid, duplicate image rid, rid reused across kinds
- unbalanced `fldChar`
- `run.text + delText` mix
- duplicate revision `id`
- reserved footnote/endnote `id` (`-1/0`)
- header/footer ref without part
- conflicting abstract levels
- dangling note refs silently dropped (Word/LibreOffice unloadable)

## Emitter (`emit.nim`)

`XmlEmit(buf)`, `decl`, `attr(name, val)` (escaped, leading space), `optAttr`, `optAttrI`, `open/close/empty`, `flag(e, tag, set, attrs)`, `text(e, s)` (xmlEscape), `elem(e, tag, body, attrs)`. Used only by writer, all exported.
