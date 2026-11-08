# DOCX Builder

High-level compose API in `src/opendocs/docx.nim:14-195`. No need to touch the raw model.

```nim
import opendocs/docx

var doc = newDocx(title = "Q1", author = "me")
doc.addParagraph(newParagraph("Hello", style = "Heading1"))
var p = newParagraph()
p.addText("bold ", bold = true)
p.addRun(newRun("red", color = "FF0000"))
doc.addParagraph(p)

var t = newTable(2, 2, style = "TableGrid")
t.cell(0, 0).blocks.add(Block(kind: bkParagraph, paragraph: newParagraph("a1")))
doc.addTable(t)

let rid = doc.addHyperlink("site", "https://example.com")
var hp = newParagraph()
hp.addRun(rid)
doc.addParagraph(hp)

doc.addImage("image/png", readFile("a.png").toSeq, cxEmu = 914400, cyEmu = 914400)
discard doc.addFootnote(@[Block(kind: bkParagraph, paragraph: newParagraph("note"))])
discard doc.addComment("alice", @[Block(kind: bkParagraph, paragraph: newParagraph("hi"))])
let numId = doc.addNumbering(@[NumberingLevel(ilvl: 0, format: "decimal", text: "%1.")])
var lp = newParagraph("item")
lp.numId = numId
doc.addParagraph(lp)

doc.addHeader(@[Block(kind: bkParagraph, paragraph: newParagraph("hdr"))])
doc.writeDocx("out.docx")
```

## API

- `defaultSectionProps(): SectionProps` (`docx.nim:14`) — `pgNumStart = -1`, `linePitch = -1`, `colsNum = 1`.
- `newDocx(title = "", author = ""): DocxDocument` — empty doc + one default section + init tables; sets `coreProps` if given.
- `newRun(text = "", bold = false, italic = false, sizePt = 0, color = "", style = ""): Run` — `sizePt -> sizeHalfPts (*2)`.
- `newParagraph(text = "", style = "", align = ""): Paragraph` — `numId = -1`; single `pkRun` if text non-empty.
- `addParagraph(doc, p)` / `addParagraph(doc, text, style = "")` / `addParagraph(section, p)` — append to last section (auto-creates if none) / shorthand / explicit section.
- `addRun(p, r)`, `addText(p, text, bold, italic, sizePt, color, style)` — formatted-run shorthand.
- `newTable(rows = 0, cols = 0, style = "TableGrid"): DocxTable`, `addTable(doc/sections, t)`, `cell(t, r, c): var TableCell` template (lvalue).
- `newSection(props = defaultSectionProps()): Section`, `addSection(doc, s)`.
- `nextRelId(doc): string` — fresh `rIdN` unused by header/footer refs, images, hyperlinks.
- `addHeader(doc, blocks, kind = "default", sectionIdx = -1)`, `addFooter(...)` — mints rel-id, appends `SectionRef` + `HeaderFooter`. `sectionIdx < 0` = last.
- `addHyperlink(doc, text, target, external = true): Run` — registers `hyperlinks[rid]`, returns `Run(text, hyperlinkRid = rid, underline = true)`. Caller `addRun`s it.
- `addImage(doc, contentType, data, cxEmu = 914400, cyEmu = 914400, name = "", relId = ""): Run` — registers `images` + `drawings[rid]` (`dpInline`). Default 1in x 1in (914400 EMU/in).
- `addFootnote(doc, blocks): int` — new id (max+1, >= 1). Caller creates `Run(footnoteRef = id)`.
- `addComment(doc, author, blocks, date = "", initials = ""): int` — new id (max+1, >= 0).
- `addNumbering(doc, levels: seq[NumberingLevel]): int` — registers `numbering[numId]` + `NumberingDef(numId, abstractId = numId)`. Set `Paragraph.numId` to use.
- `addStyle(doc, id, name, kind = "paragraph"): string` — registers `styles[id]`, returns `id`.

See `examples/docx_write_example.nim` and `tests/t_docx_builder.nim`.
