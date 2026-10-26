## Word `.docx` (OOXML WordprocessingML) high-level API.
##
## The implementation lives in `docx/core` (model, reader, writer). This
## module re-exports it and adds convenience helpers for composing
## documents without touching the model directly.

# High-level helpers for composing `DocxDocument` values

import std/tables

import docx/core
export core

proc defaultSectionProps*(): SectionProps =
  ## Page settings used for a fresh section.
  SectionProps(pgNumStart: -1, linePitch: -1, colsNum: 1)

proc newDocx*(title = "", author = ""): DocxDocument =
  ## Create an empty document with one default section and initialized
  ## lookup tables.
  result = DocxDocument(
    sections: @[Section(props: defaultSectionProps())],
    numbering: initTable[int, seq[NumberingLevel]](),
    styles: initTable[string, StyleInfo](),
    hyperlinks: initTable[string, string](),
    drawings: initTable[string, Drawing](),
    themeColors: initTable[string, string](),
    rawParts: initTable[string, seq[byte]]())
  if title != "" or author != "":
    result.coreProps = CoreProps(title: title, author: author)

proc newRun*(text = "", bold = false, italic = false, sizePt = 0,
    color = "", style = ""): Run =
  ## Create a run with common formatting. `sizePt` is in points and is
  ## stored as half-points.
  Run(text: text, bold: bold, italic: italic,
    sizeHalfPts: sizePt * 2, color: color, styleId: style,
    footnoteRef: -1, endnoteRef: -1, commentRef: -1)

proc newParagraph*(text = "", style = "", align = ""): Paragraph =
  ## Create a paragraph. When `text` is non-empty, a single run is
  ## added for it.
  var kids: seq[ParaKid] = @[]
  if text != "":
    kids.add pkRun(newRun(text))
  Paragraph(styleId: style, align: align, numId: -1, numIlvl: 0,
    indentLeft: -1, indentFirstLine: -1, spacingBefore: -1,
    spacingAfter: -1, outlineLvl: -1, kids: kids)


proc addParagraph*(doc: var DocxDocument, p: Paragraph) =
  ## Append a paragraph to the last section.
  if doc.sections.len == 0:
    doc.sections.add Section(props: defaultSectionProps())
  doc.sections[^1].blocks.add Block(kind: bkParagraph, paragraph: p)

proc addParagraph*(doc: var DocxDocument, text: string, style = "") =
  ## Convenience overload appending a single-text paragraph.
  doc.addParagraph(newParagraph(text, style))

proc addParagraph*(section: var Section, p: Paragraph) =
  ## Append a paragraph to a specific section.
  section.blocks.add Block(kind: bkParagraph, paragraph: p)

proc addRun*(p: var Paragraph, r: Run) =
  ## Append a run to a paragraph.
  p.kids.add pkRun(r)

proc addText*(p: var Paragraph, text: string, bold = false,
    italic = false, sizePt = 0, color = "", style = "") =
  ## Convenience helper appending a formatted run.
  p.addRun(newRun(text, bold, italic, sizePt, color, style))

proc newTable*(rows = 0, cols = 0, style = "TableGrid"): DocxTable =
  ## Create a table with the requested grid size.
  var rs: seq[TableRow] = @[]
  for i in 0 ..< rows:
    var cells: seq[TableCell] = @[]
    for j in 0 ..< cols:
      cells.add TableCell(width: -1, blocks: @[])
    rs.add TableRow(cells: cells)
  DocxTable(styleId: style, width: -1, cellSpacing: -1,
    grid: newSeq[int](cols), rows: rs)

proc addTable*(doc: var DocxDocument, t: DocxTable) =
  ## Append a table to the last section.
  if doc.sections.len == 0:
    doc.sections.add Section(props: defaultSectionProps())
  doc.sections[^1].blocks.add Block(kind: bkTable, table: t)

proc addTable*(section: var Section, t: DocxTable) =
  ## Append a table to a specific section.
  section.blocks.add Block(kind: bkTable, table: t)

template cell*(t: var DocxTable, r, c: int): var TableCell =
  ## Lvalue access to a table cell.
  t.rows[r].cells[c]

proc newSection*(props = defaultSectionProps()): Section =
  ## Create an empty section.
  Section(props: props, blocks: @[])

proc addSection*(doc: var DocxDocument, s: Section) =
  ## Append a section to the document.
  doc.sections.add s

proc nextRelId*(doc: DocxDocument): string =
  ## Generate a relationship id not already used by content references.
  var used: seq[string] = @[]
  for s in doc.sections:
    for rf in s.headerRefs: used.add rf.relId
    for rf in s.footerRefs: used.add rf.relId
  for im in doc.images: used.add im.relId
  for rid in doc.hyperlinks.keys: used.add rid
  var n = 1
  while "rId" & $n in used:
    inc n
  "rId" & $n

proc addHeader*(doc: var DocxDocument, blocks: seq[Block],
    kind = "default", sectionIdx = -1) =
  ## Add a header part to a section.
  let si = if sectionIdx < 0: doc.sections.high else: sectionIdx
  let rid = nextRelId(doc)
  var sec = doc.sections[si]
  sec.headerRefs.add SectionRef(refKind: kind, relId: rid)
  sec.headers.add HeaderFooter(refKind: kind, blocks: blocks)
  doc.sections[si] = sec

proc addFooter*(doc: var DocxDocument, blocks: seq[Block],
    kind = "default", sectionIdx = -1) =
  ## Add a footer part to a section.
  let si = if sectionIdx < 0: doc.sections.high else: sectionIdx
  let rid = nextRelId(doc)
  var sec = doc.sections[si]
  sec.footerRefs.add SectionRef(refKind: kind, relId: rid)
  sec.footers.add HeaderFooter(refKind: kind, blocks: blocks)
  doc.sections[si] = sec

proc addHyperlink*(doc: var DocxDocument, text, target: string,
    external = true): Run =
  ## Register a hyperlink target and return a run referencing it.
  let rid = nextRelId(doc)
  doc.hyperlinks[rid] = target
  Run(text: text, hyperlinkRid: rid, underline: true,
    footnoteRef: -1, endnoteRef: -1, commentRef: -1)

proc addImage*(doc: var DocxDocument, contentType: string,
    data: seq[byte], cxEmu = 914400, cyEmu = 914400,
    name = "", relId = ""): Run =
  ## Register an image and return a run drawing it.
  let rid = if relId == "": nextRelId(doc) else: relId
  doc.images.add (rid, contentType, data)
  doc.drawings[rid] = Drawing(relId: rid, placement: dpInline,
    cxEmu: cxEmu, cyEmu: cyEmu, name: name)
  Run(text: "", drawingRid: rid, footnoteRef: -1, endnoteRef: -1,
    commentRef: -1)

proc addFootnote*(doc: var DocxDocument, blocks: seq[Block]): int =
  ## Add a footnote and return its id.
  var maxId = 0
  for n in doc.footnotes:
    if n.id > maxId: maxId = n.id
  result = maxId + 1
  if result <= 0: result = 1
  doc.footnotes.add Footnote(id: result, blocks: blocks)

proc addComment*(doc: var DocxDocument, author: string,
    blocks: seq[Block], date = "", initials = ""): int =
  ## Add a comment and return its id.
  var maxId = -1
  for c in doc.comments:
    if c.id > maxId: maxId = c.id
  result = maxId + 1
  if result < 0: result = 0
  doc.comments.add DocComment(id: result, author: author, date: date,
    initials: initials, blocks: blocks)

proc addNumbering*(doc: var DocxDocument, levels: seq[NumberingLevel]): int =
  ## Register a numbering definition and return its numId.
  var maxId = 0
  for d in doc.numberingDefs:
    if d.numId > maxId: maxId = d.numId
  result = maxId + 1
  if result <= 0: result = 1
  doc.numbering[result] = levels
  doc.numberingDefs.add NumberingDef(numId: result,
    abstractId: result, levels: levels)

proc addStyle*(doc: var DocxDocument, id, name: string,
    kind = "paragraph"): string =
  ## Register a style and return its id.
  doc.styles[id] = StyleInfo(name: name, kind: kind, qFormat: true)
  id

# Accept / reject tracked revisions in a `DocxDocument`.
proc cleanRun(r: var Run) =
  r.hasRIns = false
  r.hasRDel = false
  r.hasRPrChange = false

proc cleanParagraphMarks(p: var Paragraph) =
  p.hasPPrIns = false
  p.hasPPrDel = false
  p.hasPPrChange = false
  p.hasNumPrChange = false
  p.rangeMarkers.setLen(0)

proc cleanTableMarks(t: var DocxTable) =
  t.hasTblPrChange = false
  t.hasTblGridChange = false
  for row in t.rows.mitems:
    row.hasTrIns = false
    row.hasTrDel = false
    row.hasTrPrChange = false
    for cell in row.cells.mitems:
      cell.hasTcIns = false
      cell.hasTcDel = false
      cell.hasTcMerge = false
      cell.hasTcPrChange = false

proc restoreParagraphProps(p: var Paragraph) =
  if not p.hasPPrChange or p.pPrChange.ppr.isNil:
    cleanParagraphMarks(p)
    return
  let old = p.pPrChange.ppr[]
  p.styleId = old.styleId
  p.align = old.align
  p.numId = old.numId
  p.numIlvl = old.numIlvl
  p.indentLeft = old.indentLeft
  p.indentFirstLine = old.indentFirstLine
  p.spacingBefore = old.spacingBefore
  p.spacingAfter = old.spacingAfter
  p.outlineLvl = old.outlineLvl
  p.keepNext = old.keepNext
  p.keepLines = old.keepLines
  p.pageBreakBefore = old.pageBreakBefore
  p.widowControl = old.widowControl
  p.shading = old.shading
  p.bidi = old.bidi
  p.textAlignment = old.textAlignment
  p.tabs = old.tabs
  p.borders = old.borders
  cleanParagraphMarks(p)

proc processParagraphAccept(p: var Paragraph) =
  var newKids: seq[ParaKid] = @[]
  for k in p.kids:
    case k.kind
    of pkRun:
      var r = k.run
      cleanRun(r)
      newKids.add pkRun(r)
    of pkFldSimple:
      var f = k.fld
      for r in f.runs.mitems: cleanRun(r)
      newKids.add ParaKid(kind: pkFldSimple, fld: f)
    of pkIns, pkMoveTo:
      for r in k.rev.runs:
        var rr = r
        cleanRun(rr)
        newKids.add pkRun(rr)
    of pkDel, pkMoveFrom:
      discard
  p.kids = newKids
  cleanParagraphMarks(p)

proc processParagraphReject(p: var Paragraph) =
  var newKids: seq[ParaKid] = @[]
  for k in p.kids:
    case k.kind
    of pkRun:
      var r = k.run
      cleanRun(r)
      newKids.add pkRun(r)
    of pkFldSimple:
      var f = k.fld
      for r in f.runs.mitems: cleanRun(r)
      newKids.add ParaKid(kind: pkFldSimple, fld: f)
    of pkDel, pkMoveFrom:
      for r in k.rev.runs:
        var rr = r
        if rr.delText != "": rr.text = rr.delText
        rr.delText = ""
        cleanRun(rr)
        newKids.add pkRun(rr)
    of pkIns, pkMoveTo:
      discard
  p.kids = newKids
  restoreParagraphProps(p)

proc processBlocksAccept(blocks: var seq[Block]) =
  var outBlocks: seq[Block] = @[]
  for b in blocks:
    case b.kind
    of bkParagraph:
      var p = b.paragraph
      processParagraphAccept(p)
      outBlocks.add Block(kind: bkParagraph, paragraph: p)
    of bkTable:
      var t = b.table
      cleanTableMarks(t)
      for row in t.rows.mitems:
        for cell in row.cells.mitems:
          processBlocksAccept(cell.blocks)
      outBlocks.add Block(kind: bkTable, table: t)
    of bkTextbox:
      var tb = b.textbox
      processBlocksAccept(tb.blocks)
      outBlocks.add Block(kind: bkTextbox, textbox: tb)
    of bkSdt:
      var s = b.sdt
      processBlocksAccept(s.blocks)
      outBlocks.add Block(kind: bkSdt, sdt: s)
    of bkIns:
      var bs = b.rev.blocks
      processBlocksAccept(bs)
      for ib in bs: outBlocks.add ib
    of bkDel:
      discard
  blocks = outBlocks

proc processBlocksReject(blocks: var seq[Block]) =
  var outBlocks: seq[Block] = @[]
  for b in blocks:
    case b.kind
    of bkParagraph:
      var p = b.paragraph
      processParagraphReject(p)
      outBlocks.add Block(kind: bkParagraph, paragraph: p)
    of bkTable:
      var t = b.table
      cleanTableMarks(t)
      for row in t.rows.mitems:
        for cell in row.cells.mitems:
          processBlocksReject(cell.blocks)
      outBlocks.add Block(kind: bkTable, table: t)
    of bkTextbox:
      var tb = b.textbox
      processBlocksReject(tb.blocks)
      outBlocks.add Block(kind: bkTextbox, textbox: tb)
    of bkSdt:
      var s = b.sdt
      processBlocksReject(s.blocks)
      outBlocks.add Block(kind: bkSdt, sdt: s)
    of bkDel:
      var bs = b.rev.blocks
      processBlocksReject(bs)
      for ib in bs: outBlocks.add ib
    of bkIns:
      discard
  blocks = outBlocks

proc acceptAllRevisions*(doc: var DocxDocument) =
  ## Accept every tracked change: keep insertions/move destinations,
  ## drop deletions/move sources, and clear revision metadata.
  for s in doc.sections.mitems:
    processBlocksAccept(s.blocks)
    s.props.hasSectPrChange = false
  processBlocksAccept(doc.blocks)
  doc.blocks.setLen(0)
  for s in doc.sections: doc.blocks.add s.blocks

proc rejectAllRevisions*(doc: var DocxDocument) =
  ## Reject every tracked change: drop insertions/move destinations,
  ## restore deletions/move sources as normal content.
  for s in doc.sections.mitems:
    processBlocksReject(s.blocks)
    s.props.hasSectPrChange = false
  processBlocksReject(doc.blocks)
  doc.blocks.setLen(0)
  for s in doc.sections: doc.blocks.add s.blocks

