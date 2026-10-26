import std/[tables, strutils, os, tempfiles, unittest]

import ../src/opendocs/docx

proc hasText(bs: seq[Block], needle: string): bool =
  for b in bs:
    case b.kind
    of bkParagraph:
      for r in b.paragraph.runs:
        if needle in r.text: return true
    of bkTable:
      for row in b.table.rows:
        for cell in row.cells:
          if hasText(cell.blocks, needle): return true
    of bkTextbox:
      if hasText(b.textbox.blocks, needle): return true
    of bkSdt:
      if hasText(b.sdt.blocks, needle): return true
    of bkIns:
      if hasText(b.rev.blocks, needle): return true
    of bkDel: discard
  false

suite "docx builder":
  test "builds a simple document":
    var doc = newDocx("Title", "Author")
    var p = newParagraph("Hello", "Heading1")
    p.addText(" world", italic = true)
    doc.addParagraph(p)

    var t = newTable(2, 2)
    t.cell(0, 0).blocks.add Block(kind: bkParagraph,
      paragraph: newParagraph("A"))
    t.cell(1, 1).blocks.add Block(kind: bkParagraph,
      paragraph: newParagraph("B"))
    doc.addTable(t)

    let doc2 = readDocxBytes(writeDocxBytes(doc))
    check flatText(doc2).contains("Hello")
    check flatText(doc2).contains("world")
    check flatText(doc2).contains("A")
    check flatText(doc2).contains("B")
    check doc2.coreProps.title == "Title"
    check doc2.coreProps.author == "Author"

  test "newRun and addText formatting survive":
    var doc = newDocx()
    var p = newParagraph()
    p.addRun(newRun("bold", bold = true, sizePt = 12))
    p.addText(" red", color = "FF0000")
    doc.addParagraph(p)
    let doc2 = readDocxBytes(writeDocxBytes(doc))
    let rs = doc2.sections[0].blocks[0].paragraph.runs
    check rs.len == 2
    check rs[0].bold
    check rs[0].sizeHalfPts == 24
    check rs[1].color == "FF0000"

suite "docx builder parts":
  test "header, hyperlink, image, footnote, comment round-trip":
    var doc = newDocx()
    doc.addHeader(@[Block(kind: bkParagraph,
      paragraph: newParagraph("head"))])
    doc.addFooter(@[Block(kind: bkParagraph,
      paragraph: newParagraph("foot"))])

    let r = doc.addHyperlink("link", "https://example.com")
    var p = newParagraph()
    p.addRun(r)
    doc.addParagraph(p)

    let imgRun = doc.addImage("image/png",
      @[137'u8, 80, 78, 71, 13, 10, 26, 10])
    var p2 = newParagraph()
    p2.addRun(imgRun)
    doc.addParagraph(p2)

    let fid = doc.addFootnote(@[Block(kind: bkParagraph,
      paragraph: newParagraph("fn"))])
    var p3 = newParagraph()
    p3.addRun(Run(text: "note", footnoteRef: fid,
      endnoteRef: -1, commentRef: -1))
    doc.addParagraph(p3)

    let cid = doc.addComment("me", @[Block(kind: bkParagraph,
      paragraph: newParagraph("cm"))])
    check cid >= 0

    let doc2 = readDocxBytes(writeDocxBytes(doc))
    check hasText(getHeaders(doc2), "head")
    check hasText(getFooters(doc2), "foot")
    check flatText(doc2).contains("link")
    check doc2.images.len == 1
    check doc2.footnotes.len == 1
    check doc2.comments.len == 1

suite "docx revisions":
  test "accept and reject tracked changes":
    var doc = newDocx()
    var p = Paragraph(kids: @[
      ParaKid(kind: pkDel, rev: RevRun(meta: RevisionMeta(id: "1"),
        runs: @[Run(text: "", delText: "gone", footnoteRef: -1,
          endnoteRef: -1, commentRef: -1)])),
      ParaKid(kind: pkIns, rev: RevRun(meta: RevisionMeta(id: "2"),
        runs: @[Run(text: "here", footnoteRef: -1, endnoteRef: -1,
          commentRef: -1)]))],
      numId: -1, indentLeft: -1, indentFirstLine: -1,
      spacingBefore: -1, spacingAfter: -1, outlineLvl: -1)
    doc.addParagraph(p)

    var accepted = doc
    accepted.acceptAllRevisions()
    check flatText(accepted) == "here"

    var rejected = doc
    rejected.rejectAllRevisions()
    check flatText(rejected) == "gone"
