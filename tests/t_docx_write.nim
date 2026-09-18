import std/[tables, strutils, os, sequtils, tempfiles, unittest]

import ../src/opendocs/docx
import ../src/opendocs/zip

const fixDir = "tests/fixtures/docx"

proc paras(b: Block, acc: var seq[string]) =
  ## Accept-view text (insertions/move destinations kept, deletions and
  ## move sources excluded) so round-trips cover revision content.
  case b.kind
  of bkParagraph:
    var s = ""
    for k in b.paragraph.kids:
      case k.kind
      of pkRun: s.add k.run.text
      of pkFldSimple:
        for r in k.fld.runs: s.add r.text
      of pkIns, pkMoveTo:
        for r in k.rev.runs: s.add r.text
      of pkDel, pkMoveFrom: discard
    acc.add s
  of bkTable:
    for row in b.table.rows:
      for cell in row.cells:
        for cb in cell.blocks: paras(cb, acc)
  of bkTextbox:
    for tb in b.textbox.blocks: paras(tb, acc)
  of bkSdt:
    for sb in b.sdt.blocks: paras(sb, acc)
  of bkIns:
    for ib in b.rev.blocks: paras(ib, acc)
  of bkDel: discard

proc blocksText(bs: seq[Block]): string =
  var acc: seq[string]
  for b in bs: paras(b, acc)
  acc.join("\n")

template checkRoundTrip(d: DocxDocument) =
  ## Full model equality after write -> read (minus `rawParts`, which
  ## is covered separately, and `blocks`, which the writer rebuilds).
  ## Template (not proc) so `check` attributes to the calling test.
  let doc = d
  let doc2 = readDocxBytes(writeDocxBytes(doc))
  check flatText(doc) == flatText(doc2)
  check doc.styles == doc2.styles
  check doc.numbering == doc2.numbering
  check doc.numberingDefs == doc2.numberingDefs
  check doc.coreProps == doc2.coreProps
  check doc.appProps == doc2.appProps
  check doc.customProps == doc2.customProps
  check doc.themeColors == doc2.themeColors
  check doc.hyperlinks == doc2.hyperlinks
  check doc.bookmarks == doc2.bookmarks
  check doc.images == doc2.images
  check doc.sections.len == doc2.sections.len
  check doc.footnotes.len == doc2.footnotes.len
  check doc.endnotes.len == doc2.endnotes.len
  check doc.comments.len == doc2.comments.len
  for i, s in doc.sections:
    check blocksText(s.blocks) == blocksText(doc2.sections[i].blocks)
    check s.props == doc2.sections[i].props
    for h in s.headers:
      var found = false
      for h2 in doc2.sections[i].headers:
        if h2.refKind == h.refKind and
            blocksText(h2.blocks) == blocksText(h.blocks):
          found = true
      check found
    for f in s.footers:
      var found = false
      for f2 in doc2.sections[i].footers:
        if f2.refKind == f.refKind and
            blocksText(f2.blocks) == blocksText(f.blocks):
          found = true
      check found
  for i, n in doc.footnotes:
    check doc2.footnotes[i].id == n.id
    check blocksText(doc2.footnotes[i].blocks) == blocksText(n.blocks)
  for i, n in doc.endnotes:
    check blocksText(doc2.endnotes[i].blocks) == blocksText(n.blocks)
  for i, c in doc.comments:
    check blocksText(doc2.comments[i].blocks) == blocksText(c.blocks)
    check (doc2.comments[i].author, doc2.comments[i].date,
      doc2.comments[i].initials) == (c.author, c.date, c.initials)

proc P(styleId = "", align = "", numId = -1, numIlvl = 0,
    runs: seq[Run] = @[], bookmarks: seq[Bookmark] = @[]): Paragraph =
  ## Blank paragraph with "unspecified" markers set (hand-built docs
  ## must opt out of formatting explicitly; the reader does the same).
  var kids: seq[ParaKid] = @[]
  for r in runs: kids.add pkRun(r)
  Paragraph(styleId: styleId, align: align, numId: numId,
    numIlvl: numIlvl, indentLeft: -1, indentFirstLine: -1,
    spacingBefore: -1, spacingAfter: -1, outlineLvl: -1, kids: kids,
    bookmarks: bookmarks)

proc freshDoc(): DocxDocument =
  ## Hand-built document exercising every modeled part.
  result = DocxDocument(
    numbering: initTable[int, seq[NumberingLevel]](),
    styles: initTable[string, StyleInfo](),
    hyperlinks: initTable[string, string](),
    drawings: initTable[string, Drawing](),
    themeColors: initTable[string, string](),
    rawParts: initTable[string, seq[byte]]())
  result.styles["Normal"] = StyleInfo(name: "Normal", kind: "paragraph",
    qFormat: true, isDefault: true)
  result.styles["Heading1"] = StyleInfo(name: "heading 1", kind: "paragraph",
    basedOn: "Normal", next: "Normal", qFormat: true)
  result.numbering[1] = @[NumberingLevel(ilvl: 0, format: "bullet",
    text: "o", start: 1, justification: "left",
    indentLeft: 720, indentHanging: 360)]
  result.numberingDefs.add NumberingDef(numId: 1, abstractId: 1,
    levels: result.numbering[1])
  result.hyperlinks["rId5"] = "https://example.com"
  result.images.add ("rId6", "image/png",
    @[137'u8, 80, 78, 71, 13, 10, 26, 10])
  result.drawings["rId6"] = Drawing(relId: "rId6", placement: dpInline,
    cxEmu: 914400, cyEmu: 914400, name: "pic")
  var section = Section(props: SectionProps(pgW: 11906, pgH: 16838,
    marginTop: 1440, marginRight: 1800, marginBottom: 1440,
    marginLeft: 1800, colsNum: 1, pgNumStart: -1, linePitch: -1))
  section.blocks.add Block(kind: bkParagraph, paragraph: P("Heading1",
    "center", runs = @[Run(text: "Title", bold: true, sizeHalfPts: 28,
      footnoteRef: -1, endnoteRef: -1, commentRef: -1)],
    bookmarks = @[Bookmark(id: 1, name: "bm")]))
  section.blocks.add Block(kind: bkParagraph, paragraph: P(numId = 1,
    runs = @[Run(text: "item", footnoteRef: -1, endnoteRef: -1,
      commentRef: -1),
      Run(text: "link", hyperlinkRid: "rId5", underline: true,
        footnoteRef: -1, endnoteRef: -1, commentRef: -1)]))
  section.blocks.add Block(kind: bkParagraph, paragraph: P(
    runs = @[Run(text: "pic", drawingRid: "rId6", footnoteRef: -1,
      endnoteRef: -1, commentRef: -1),
      Run(text: "note", footnoteRef: 1, endnoteRef: -1,
        commentRef: -1)]))
  var cell = TableCell(gridSpan: 2, width: -1,
    blocks: @[Block(kind: bkParagraph, paragraph: P(
      runs = @[Run(text: "wide", footnoteRef: -1, endnoteRef: -1,
        commentRef: -1)]))])
  section.blocks.add Block(kind: bkTable, table: DocxTable(
    styleId: "TableGrid", width: -1, cellSpacing: -1,
    grid: @[3000, 3000], rows: @[TableRow(cells: @[cell])]))
  section.headerRefs.add SectionRef(refKind: "default", relId: "rId7")
  section.headers.add HeaderFooter(refKind: "default", blocks: @[
    Block(kind: bkParagraph, paragraph: P(
      runs = @[Run(text: "head", footnoteRef: -1, endnoteRef: -1,
        commentRef: -1)]))])
  result.sections.add section
  result.footnotes.add Footnote(id: 1, blocks: @[
    Block(kind: bkParagraph, paragraph: P(
      runs = @[Run(text: "fn", footnoteRef: -1, endnoteRef: -1,
        commentRef: -1)]))])
  result.comments.add DocComment(id: 0, author: "me", blocks: @[
    Block(kind: bkParagraph, paragraph: P(
      runs = @[Run(text: "cm", footnoteRef: -1, endnoteRef: -1,
        commentRef: -1)]))])
  result.coreProps = CoreProps(title: "t", author: "a")
  result.blocks = result.sections[0].blocks # flat flow mirrors sections
  result.bookmarks = @[Bookmark(id: 1, name: "bm")] # aggregate mirrors content

suite "docx writer: fresh documents":
  test "write then read preserves every modeled part":
    let doc = freshDoc()
    checkRoundTrip(doc)

  test "writeDocx file round-trips from disk":
    let dir = createTempDir("opendocs_", "_wtest")
    defer: removeDir(dir)
    let path = dir / "fresh.docx"
    writeDocx(freshDoc(), path)
    let doc2 = readDocx(path)
    check flatText(doc2).contains("Title")
    check blocksText(getHeaders(doc2)).contains("head")
    check doc2.images.len == 1
    check doc2.images[0].data == @[137'u8, 80, 78, 71, 13, 10, 26, 10]
    check doc2.footnotes.len == 1
    check doc2.comments.len == 1

  test "empty document writes a valid single-section package":
    let doc = DocxDocument(
      numbering: initTable[int, seq[NumberingLevel]](),
      styles: initTable[string, StyleInfo](),
      hyperlinks: initTable[string, string](),
      drawings: initTable[string, Drawing](),
      themeColors: initTable[string, string](),
      rawParts: initTable[string, seq[byte]]())
    let doc2 = readDocxBytes(writeDocxBytes(doc))
    check doc2.sections.len == 1
    check flatText(doc2) == ""

  test "symbol glyphs and double strike round-trip":
    var doc = freshDoc()
    doc.sections[0].blocks.add Block(kind: bkParagraph, paragraph: P(
      runs = @[Run(symFont: "Symbol", symChar: "F0FC",
        footnoteRef: -1, endnoteRef: -1, commentRef: -1),
        Run(text: "hit", dstrike: true, footnoteRef: -1,
          endnoteRef: -1, commentRef: -1)]))
    doc.blocks = doc.sections[0].blocks
    let doc2 = readDocxBytes(writeDocxBytes(doc))
    let rs = doc2.sections[0].blocks[^1].paragraph.runs
    check rs[0].symFont == "Symbol"
    check rs[0].symChar == "F0FC"
    check rs[1].dstrike
    check not rs[1].strike

  test "typed custom properties round-trip":
    var doc = freshDoc()
    doc.customProps = @[
      CustomProp(name: "s", value: customStr("007")),
      CustomProp(name: "n", value: customInt(42)),
      CustomProp(name: "big", value: customInt(1'i64 shl 40)),
      CustomProp(name: "flag", value: customBool(true)),
      CustomProp(name: "pi", value: customFloat(3.14)),
      CustomProp(name: "when", value: customDate("2024-01-01T00:00:00Z")),
      CustomProp(name: "raw", value: CustomValue(kind: cvkRaw,
        tag: "blob", text: "aGVsbG8="))]
    let doc2 = readDocxBytes(writeDocxBytes(doc))
    check doc2.customProps == doc.customProps
    check doc2.customProps[0].value.kind == cvkString # stays a string
    check doc2.customProps[2].value == customInt(1'i64 shl 40) # i8 width

suite "docx writer: fixture round-trips":
  test "read, write, read preserves the model":
    for path in toSeq(walkFiles(fixDir / "*.docx")):
      checkRoundTrip(readDocx(path))

  test "raw parts survive byte-exact (except regenerated package rels)":
    for path in toSeq(walkFiles(fixDir / "*.docx")):
      let doc = readDocx(path)
      let doc2 = readDocxBytes(writeDocxBytes(doc))
      for k, v in doc.rawParts:
        if k == "_rels/.rels": continue # regenerated (same targets)
        check k in doc2.rawParts
        check doc2.rawParts[k] == v

suite "docx writer: validation errors":
  test "paragraph numId without a definition fails":
    var doc = freshDoc()
    doc.sections[0].blocks.add Block(kind: bkParagraph,
      paragraph: P(numId = 9, runs = @[Run(text: "x")]))
    expect DocxError:
      discard writeDocxBytes(doc)

  test "run with unknown hyperlink fails":
    var doc = freshDoc()
    doc.sections[0].blocks.add Block(kind: bkParagraph,
      paragraph: P(runs = @[Run(text: "x", hyperlinkRid: "rId99")]))
    expect DocxError:
      discard writeDocxBytes(doc)

  test "run with unknown image fails":
    var doc = freshDoc()
    doc.sections[0].blocks.add Block(kind: bkParagraph,
      paragraph: P(runs = @[Run(text: "x", drawingRid: "rId99")]))
    expect DocxError:
      discard writeDocxBytes(doc)

  test "image without rel id fails":
    var doc = freshDoc()
    doc.images.add ("", "image/png", @[1'u8])
    expect DocxError:
      discard writeDocxBytes(doc)

  test "reserved footnote id fails":
    var doc = freshDoc()
    doc.footnotes.add Footnote(id: -1, blocks: @[])
    expect DocxError:
      discard writeDocxBytes(doc)

  test "header reference without a header part fails":
    var doc = freshDoc()
    doc.sections[0].headerRefs.add SectionRef(refKind: "first",
      relId: "rId8")
    expect DocxError:
      discard writeDocxBytes(doc)

  test "conflicting abstract levels fail":
    var doc = freshDoc()
    doc.numberingDefs.add NumberingDef(numId: 2, abstractId: 1,
      levels: @[NumberingLevel(ilvl: 0, format: "decimal", text: "%1.",
        start: 1, indentLeft: -1, indentHanging: -1)])
    expect DocxError:
      discard writeDocxBytes(doc)

suite "docx writer: typed fields":
  proc fieldDoc(kids: seq[ParaKid]): DocxDocument =
    result = freshDoc()
    var p = P()
    p.kids = kids
    result.sections[0].blocks.add Block(kind: bkParagraph, paragraph: p)

  test "complex field round-trips markers and cached text":
    let kids = @[
      pkRun(Run(fldChar: fckBegin)),
      pkRun(Run(instrRaw: "TOC \\o \"1-3\" \\h",
        instr: parseInstr("TOC \\o \"1-3\" \\h"))),
      pkRun(Run(fldChar: fckSeparate)),
      pkRun(Run(text: "cached")),
      pkRun(Run(fldChar: fckEnd))]
    let doc2 = readDocxBytes(writeDocxBytes(fieldDoc(kids)))
    let back = doc2.sections[0].blocks[^1].paragraph.kids
    check back.len == kids.len
    check back[0].run.fldChar == fckBegin
    check back[1].run.instrRaw == "TOC \\o \"1-3\" \\h"
    check back[1].run.instr.kind == fikToc
    check back[1].run.instr.toc.switches == @[
      InstrSwitch(flag: "o", arg: "1-3", hasArg: true),
      InstrSwitch(flag: "h", arg: "", hasArg: false)]
    check back[2].run.fldChar == fckSeparate
    check back[3].run.text == "cached"
    check back[4].run.fldChar == fckEnd
    check flatText(doc2).contains("cached")
    check not flatText(doc2).contains("TOC")

  test "all instruction kinds parse":
    check parseInstr("PAGE").kind == fikPage
    check parseInstr("NUMPAGES").kind == fikNumPages
    check parseInstr("PAGE \\* MERGEFORMAT").kind == fikUnsupported
    let tc = parseInstr("TC \"entry\" \\f id \\l 2 \\n")
    check tc.kind == fikTc
    check tc.tc.text == "entry"
    check tc.tc.itemId == "id"
    check tc.tc.level == 2
    check tc.tc.omitsPageNum
    let pr = parseInstr("PAGEREF _Toc1 \\h \\p")
    check pr.kind == fikPageRef
    check pr.pageRef.bookmark == "_Toc1"
    check pr.pageRef.hyperlink
    check pr.pageRef.relPos
    let h = parseInstr("HYPERLINK \"https://x\" \\l")
    check h.kind == fikHyperlink
    check h.hyperlink.target == "https://x"
    check h.hyperlink.anchor
    check parseInstr("XE \"index\"").kind == fikUnsupported
    check parseInstr("").kind == fikUnsupported

  test "fresh runs serialize canonically":
    check serializeInstr(FieldInstr(kind: fikPage)) == "PAGE"
    check serializeInstr(FieldInstr(kind: fikTc,
      tc: TcInstr(text: "e", level: -1))) == "TC \"e\""
    let doc2 = readDocxBytes(writeDocxBytes(fieldDoc(@[
      pkRun(Run(fldChar: fckBegin, fldDirty: true)),
      pkRun(Run(instr: FieldInstr(kind: fikPage))),
      pkRun(Run(fldChar: fckSeparate)),
      pkRun(Run(text: "7")),
      pkRun(Run(fldChar: fckEnd))])))
    let back = doc2.sections[0].blocks[^1].paragraph.kids
    check back[0].run.fldDirty
    check back[1].run.instrRaw == "PAGE" # canonical fill on read-back
    check back[1].run.instr.kind == fikPage
    check back[3].run.text == "7"

  test "dirty, lock, and unknown fldCharType survive":
    let kids = @[
      pkRun(Run(fldChar: fckUnknown, fldCharRaw: "mystery",
        fldDirty: true)),
      pkRun(Run(fldLock: true, text: "x")),
      pkRun(Run(fldChar: fckEnd))]
    let doc2 = readDocxBytes(writeDocxBytes(fieldDoc(kids)))
    let back = doc2.sections[0].blocks[^1].paragraph.kids
    check back[0].run.fldChar == fckUnknown
    check back[0].run.fldCharRaw == "mystery"
    check back[0].run.fldDirty
    check back[1].run.fldLock
    check back[1].run.text == "x"

  test "entities and quoting in instructions":
    let kids = @[
      pkRun(Run(fldChar: fckBegin)),
      pkRun(Run(instrRaw: "TOC \\o \"1-3\" \\h",
        instr: parseInstr("TOC \\o \"1-3\" \\h"))),
      pkRun(Run(fldChar: fckSeparate)),
      pkRun(Run(text: "a & b")),
      pkRun(Run(fldChar: fckEnd))]
    let bytes = writeDocxBytes(fieldDoc(kids))
    let xml = cast[string](readEntry(openZipBytes(bytes),
      "word/document.xml"))
    check "TOC \\o \"1-3\" \\h" in xml # quotes stay literal in content
    check "a &amp; b" in xml
    let doc2 = readDocxBytes(writeDocxBytes(fieldDoc(kids)))
    let back = doc2.sections[0].blocks[^1].paragraph.kids
    check back[1].run.instrRaw == "TOC \\o \"1-3\" \\h"
    check back[3].run.text == "a & b"

  test "simple field round-trips":
    let kids = @[ParaKid(kind: pkFldSimple, fld: FldSimple(
      instrRaw: "PAGE", instr: FieldInstr(kind: fikPage),
      runs: @[Run(text: "7")]))]
    let doc2 = readDocxBytes(writeDocxBytes(fieldDoc(kids)))
    let back = doc2.sections[0].blocks[^1].paragraph.kids
    check back.len == 1
    check back[0].kind == pkFldSimple
    check back[0].fld.instrRaw == "PAGE"
    check back[0].fld.instr.kind == fikPage
    check back[0].fld.runs[0].text == "7"
    check flatText(doc2).contains("7")

  test "unbalanced field boundaries fail":
    var doc = freshDoc()
    doc.sections[0].blocks.add Block(kind: bkParagraph,
      paragraph: P(runs = @[Run(fldChar: fckBegin), Run(text: "x")]))
    expect DocxError:
      discard writeDocxBytes(doc)
    var doc2 = freshDoc()
    doc2.sections[0].blocks.add Block(kind: bkParagraph,
      paragraph: P(runs = @[Run(text: "x"), Run(fldChar: fckEnd)]))
    expect DocxError:
      discard writeDocxBytes(doc2)

suite "docx writer: tracked changes":
  proc revMeta(id: string, author = "", date = ""): RevisionMeta =
    RevisionMeta(id: id, author: author, date: date)

  proc revDoc(): DocxDocument =
    result = freshDoc()
    var p = P()
    p.kids = @[
      pkRun(Run(text: "keep")),
      ParaKid(kind: pkIns, rev: RevRun(
        meta: revMeta("10", "Ann", "2024-01-02"),
        runs: @[Run(text: "new")])),
      ParaKid(kind: pkDel, rev: RevRun(
        meta: revMeta("11", "Bob", "2024-01-03"),
        runs: @[Run(delText: "old")])),
      ParaKid(kind: pkMoveFrom, rev: RevRun(
        meta: revMeta("12", "Ann"), runs: @[Run(text: "src")])),
      ParaKid(kind: pkMoveTo, rev: RevRun(
        meta: revMeta("13", "Ann"), runs: @[Run(text: "dst")]))]
    result.sections[0].blocks.add Block(kind: bkParagraph, paragraph: p)
    result.blocks = result.sections[0].blocks # flatText reads blocks

  test "run wrappers round-trip with meta preserved":
    let doc2 = readDocxBytes(writeDocxBytes(revDoc()))
    let kids = doc2.sections[0].blocks[^1].paragraph.kids
    check kids.len == 5
    check kids[0].run.text == "keep"
    check kids[1].kind == pkIns
    check kids[1].rev.meta ==
      revMeta("10", "Ann", "2024-01-02") # ids preserved, not renumbered
    check kids[1].rev.runs[0].text == "new"
    check kids[2].kind == pkDel
    check kids[2].rev.runs[0].delText == "old"
    check kids[2].rev.runs[0].text == ""
    check kids[3].kind == pkMoveFrom
    check kids[4].kind == pkMoveTo
    check kids[4].rev.runs[0].text == "dst"

  test "flatText is the accept-changes view":
    check flatText(revDoc()).contains("keepnewdst")
    check not flatText(revDoc()).contains("old")
    check not flatText(revDoc()).contains("src")

  test "fresh wrappers take ids from the document counter":
    var doc = freshDoc()
    var p = P()
    p.kids = @[ParaKid(kind: pkIns,
      rev: RevRun(runs: @[Run(text: "a")]))]
    doc.sections[0].blocks.add Block(kind: bkParagraph, paragraph: p)
    let doc2 = readDocxBytes(writeDocxBytes(doc))
    check doc2.sections[0].blocks[^1].paragraph.kids[0].rev.meta.id ==
      "1"

  test "duplicate revision ids fail":
    var doc = revDoc()
    var p = P()
    p.kids = @[ParaKid(kind: pkIns,
      rev: RevRun(meta: revMeta("10"), runs: @[Run(text: "x")]))]
    doc.sections[0].blocks.add Block(kind: bkParagraph, paragraph: p)
    expect DocxError:
      discard writeDocxBytes(doc)

  test "run mixing text with delText fails":
    var doc = freshDoc()
    var p = P()
    p.kids = @[ParaKid(kind: pkDel, rev: RevRun(meta: revMeta("7"),
      runs: @[Run(text: "x", delText: "y")]))]
    doc.sections[0].blocks.add Block(kind: bkParagraph, paragraph: p)
    expect DocxError:
      discard writeDocxBytes(doc)

  test "paragraph and run marks round-trip":
    var doc = freshDoc()
    var inner = new(Paragraph)
    inner[].align = "center"
    inner[].numId = -1
    inner[].indentLeft = -1
    inner[].indentFirstLine = -1
    inner[].spacingBefore = -1
    inner[].spacingAfter = -1
    inner[].outlineLvl = -1
    var p = P()
    p.hasPPrIns = true
    p.pPrIns = revMeta("20", "Ann")
    p.hasPPrDel = true
    p.pPrDel = revMeta("21", "Bob")
    p.hasPPrChange = true
    p.pPrChange = ParaChange(meta: revMeta("22", "Ann"), ppr: inner)
    p.hasNumPrChange = true
    p.numPrChange = PropChange(meta: revMeta("23"),
      rawInner: "<w:numPr/>")
    p.rsidR = "00A1"
    p.rsidP = "00B2"
    var r = Run(text: "x")
    r.hasRIns = true
    r.rIns = revMeta("24")
    r.hasRDel = true
    r.rDel = revMeta("25")
    r.hasRPrChange = true
    r.rPrChange = PropChange(meta: revMeta("26"),
      rawInner: "<w:rPr/>")
    r.rsidR = "00C3"
    p.kids = @[pkRun(r)]
    doc.sections[0].blocks.add Block(kind: bkParagraph, paragraph: p)
    let doc2 = readDocxBytes(writeDocxBytes(doc))
    let q = doc2.sections[0].blocks[^1].paragraph
    check q.hasPPrIns and q.pPrIns == revMeta("20", "Ann")
    check q.hasPPrDel and q.pPrDel == revMeta("21", "Bob")
    check q.hasPPrChange
    check q.pPrChange.meta == revMeta("22", "Ann")
    check q.pPrChange.ppr[].align == "center"
    check q.hasNumPrChange
    check q.numPrChange.rawInner == "<w:numPr/>"
    check q.rsidR == "00A1"
    check q.rsidP == "00B2"
    let r2 = q.kids[0].run
    check r2.hasRIns and r2.rIns == revMeta("24")
    check r2.hasRDel and r2.rDel == revMeta("25")
    check r2.hasRPrChange
    check r2.rPrChange.rawInner == "<w:rPr/>"
    check r2.rsidR == "00C3"

  test "row, cell, and table marks round-trip":
    var doc = freshDoc()
    var cell = TableCell(gridSpan: 1, width: -1,
      blocks: @[Block(kind: bkParagraph, paragraph: P(
        runs = @[Run(text: "c")]))])
    cell.hasTcIns = true
    cell.tcIns = revMeta("30", "Ann")
    cell.hasTcDel = true
    cell.tcDel = revMeta("31", "Bob")
    cell.hasTcMerge = true
    cell.tcMerge = revMeta("32")
    cell.hasTcPrChange = true
    cell.tcPrChange = PropChange(meta: revMeta("33"),
      rawInner: "<w:tcPr/>")
    var row = TableRow(cells: @[cell])
    row.hasTrIns = true
    row.trIns = revMeta("34")
    row.hasTrDel = true
    row.trDel = revMeta("35")
    row.hasTrPrChange = true
    row.trPrChange = PropChange(meta: revMeta("36"),
      rawInner: "<w:trPr/>")
    var tbl = DocxTable(styleId: "TableGrid", width: -1, cellSpacing: -1,
      grid: @[3000], rows: @[row])
    tbl.hasTblPrChange = true
    tbl.tblPrChange = PropChange(meta: revMeta("37"),
      rawInner: "<w:tblPr/>")
    tbl.hasTblGridChange = true
    tbl.tblGridChange = PropChange(meta: revMeta("38"),
      rawInner: "<w:tblGrid/>")
    doc.sections[0].blocks.add Block(kind: bkTable, table: tbl)
    let doc2 = readDocxBytes(writeDocxBytes(doc))
    let t = doc2.sections[0].blocks[^1].table
    check t.hasTblPrChange and t.tblPrChange.rawInner == "<w:tblPr/>"
    check t.hasTblGridChange and
      t.tblGridChange.rawInner == "<w:tblGrid/>"
    check t.rows[0].hasTrIns and t.rows[0].trIns == revMeta("34")
    check t.rows[0].hasTrDel and t.rows[0].trDel == revMeta("35")
    check t.rows[0].hasTrPrChange
    let c = t.rows[0].cells[0]
    check c.hasTcIns and c.tcIns == revMeta("30", "Ann")
    check c.hasTcDel and c.tcDel == revMeta("31", "Bob")
    check c.hasTcMerge and c.tcMerge == revMeta("32")
    check c.hasTcPrChange and c.tcPrChange.rawInner == "<w:tcPr/>"

  test "body-level wrappers round-trip, del excluded from text":
    # NOTE: LibreOffice does not render body-level w:ins/w:del (import
    # gap; Word handles them). Round-trip here is lossless regardless.
    var doc = freshDoc()
    var p = P(runs = @[Run(text: "in")])
    doc.sections[0].blocks.add Block(kind: bkIns,
      rev: RevBlock(meta: revMeta("40", "Ann"),
        blocks: @[Block(kind: bkParagraph, paragraph: p)]))
    var q = P(runs = @[Run(text: "out")])
    doc.sections[0].blocks.add Block(kind: bkDel,
      rev: RevBlock(meta: revMeta("41", "Bob"),
        blocks: @[Block(kind: bkParagraph, paragraph: q)]))
    let doc2 = readDocxBytes(writeDocxBytes(doc))
    check doc2.sections[0].blocks[^2].kind == bkIns
    check doc2.sections[0].blocks[^2].rev.meta == revMeta("40", "Ann")
    check doc2.sections[0].blocks[^1].kind == bkDel
    check flatText(doc2).contains("in")
    check not flatText(doc2).contains("out")

  test "range markers round-trip":
    var doc = freshDoc()
    var p = P(runs = @[Run(text: "m")])
    p.rangeMarkers = @[
      RangeMarker(kind: rmkMoveFromStart, tag: "w:moveFromRangeStart",
        name: "mv", id: "50"),
      RangeMarker(kind: rmkMoveFromEnd, tag: "w:moveFromRangeEnd",
        name: "mv", id: "50"),
      RangeMarker(kind: rmkCustomXml, tag: "w:customXmlDelRangeStart",
        name: "item", id: "51", uri: "urn:x", element: "e")]
    doc.sections[0].blocks.add Block(kind: bkParagraph, paragraph: p)
    let doc2 = readDocxBytes(writeDocxBytes(doc))
    let q = doc2.sections[0].blocks[^1].paragraph
    check q.rangeMarkers.len == 3
    check q.rangeMarkers[0].tag == "w:moveFromRangeStart"
    check q.rangeMarkers[0].name == "mv"
    check q.rangeMarkers[2].tag == "w:customXmlDelRangeStart"
    check q.rangeMarkers[2].uri == "urn:x"
    check q.rangeMarkers[2].element == "e"

  test "dangling note references are dropped (LO cannot load them)":
    var doc = freshDoc()
    doc.sections[0].blocks.add Block(kind: bkParagraph,
      paragraph: P(runs = @[Run(text: "x", footnoteRef: 0, endnoteRef: 9,
        commentRef: 7)]))
    let bytes = writeDocxBytes(doc)
    let xml = cast[string](readEntry(openZipBytes(bytes),
      "word/document.xml"))
    check "footnoteReference w:id=\"0\"" notin xml
    check "endnoteReference w:id=\"9\"" notin xml
    check "commentReference w:id=\"7\"" notin xml
    let doc2 = readDocxBytes(bytes)
    let r = doc2.sections[0].blocks[^1].paragraph.kids[0].run
    check r.footnoteRef == -1
    check r.endnoteRef == -1
    check r.commentRef == -1
