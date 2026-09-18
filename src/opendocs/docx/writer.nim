## Word `.docx` writer (include-part of `opendocs/docx`, see docx.nim).
##
## Serializes the owned `DocxDocument` model back to OOXML parts with the
## `XmlEmit` string builder. Only non-default properties are emitted, so a
## read→write round-trip preserves every modeled value.
##
## Known accept-view losses (same philosophy as the reader): tracked
## insert/delete author/date metadata, field instruction boundaries
## (cached text stays), and the original textbox host run (textboxes
## reattach to the preceding paragraph when there is one).

import opendocs/docx/emit

const
  DocNs = " xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"" &
    " xmlns:m=\"http://schemas.openxmlformats.org/officeDocument/2006/math\"" &
    " xmlns:o=\"urn:schemas-microsoft-com:office:office\"" &
    " xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"" &
    " xmlns:v=\"urn:schemas-microsoft-com:vml\"" &
    " xmlns:w10=\"urn:schemas-microsoft-com:office:word\"" &
    " xmlns:w14=\"http://schemas.microsoft.com/office/word/2010/wordml\"" &
    " xmlns:w15=\"http://schemas.microsoft.com/office/word/2012/wordml\"" &
    " xmlns:wp=\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\"" &
    " xmlns:wp14=\"http://schemas.microsoft.com/office/word/2010/wordprocessingDrawing\"" &
    " xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\"" &
    " xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"" &
    " xmlns:wps=\"http://schemas.microsoft.com/office/word/2010/wordprocessingShape\"" &
    " xmlns:mc=\"http://schemas.openxmlformats.org/markup-compatibility/2006\"" &
    " mc:Ignorable=\"w14 wp14\""
  DrawNs = " xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\"" &
    " xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\""
  WNs = " xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\""

proc writeEdge(e: var XmlEmit, tag: string, ed: BorderEdge) =
  if ed.style == "": return
  e.empty(tag, attr("w:val", ed.style) & optAttrI("w:sz", ed.sizeEighths, 0) &
    optAttrI("w:space", ed.space, 0) & optAttr("w:color", ed.color))

proc writeBorders(e: var XmlEmit, tag: string, b: Borders) =
  if b == Borders(): return
  e.open(tag)
  e.writeEdge("w:top", b.top)
  e.writeEdge("w:left", b.left)
  e.writeEdge("w:bottom", b.bottom)
  e.writeEdge("w:right", b.right)
  e.writeEdge("w:insideH", b.insideH)
  e.writeEdge("w:insideV", b.insideV)
  e.close(tag)

func writeRevAttrs(meta: RevisionMeta): string =
  ## Shared `w:id`/`w:author`/`w:date` (ids assigned in the pre-pass).
  attr("w:id", meta.id) & optAttr("w:author", meta.author) &
    optAttr("w:date", meta.date)

proc writePropChange(e: var XmlEmit, tag: string, ch: PropChange) =
  ## `*PrChange` wrapper with verbatim inner XML.
  e.open(tag, writeRevAttrs(ch.meta))
  e.buf.add ch.rawInner
  e.close(tag)

proc writeRunRPr(e: var XmlEmit, r: Run) =
  e.open("w:rPr")
  e.flag("w:b", r.bold)
  e.flag("w:i", r.italic)
  if r.underline: e.empty("w:u", attr("w:val", "single"))
  e.flag("w:strike", r.strike)
  e.flag("w:dstrike", r.dstrike)
  if r.sizeHalfPts != 0: e.empty("w:sz", attr("w:val", $r.sizeHalfPts))
  if r.color != "" or r.colorTheme != "":
    e.empty("w:color", optAttr("w:val", r.color) &
      optAttr("w:themeColor", r.colorTheme) &
      optAttr("w:themeShade", r.colorShade) &
      optAttr("w:themeTint", r.colorTint))
  if r.fonts != "" or r.fontsEastAsia != "" or r.fontsHAnsi != "":
    e.empty("w:rFonts", optAttr("w:ascii", r.fonts) &
      optAttr("w:eastAsia", r.fontsEastAsia) & optAttr("w:hAnsi", r.fontsHAnsi))
  if r.lang != "": e.empty("w:lang", attr("w:val", r.lang))
  if r.highlight != "": e.empty("w:highlight", attr("w:val", r.highlight))
  if r.styleId != "": e.empty("w:rStyle", attr("w:val", r.styleId))
  if r.vertAlign != "": e.empty("w:vertAlign", attr("w:val", r.vertAlign))
  if r.spacingTwips != 0: e.empty("w:spacing", attr("w:val", $r.spacingTwips))
  if r.positionPts != 0: e.empty("w:position", attr("w:val", $r.positionPts))
  if r.kernHalfPts != 0: e.empty("w:kern", attr("w:val", $r.kernHalfPts))
  if r.shading != "":
    e.empty("w:shd", attr("w:val", "clear") & attr("w:fill", r.shading))
  e.flag("w:caps", r.caps)
  e.flag("w:smallCaps", r.smallCaps)
  e.flag("w:vanish", r.vanish or r.webHidden)
  e.flag("w:webHidden", r.webHidden)
  e.flag("w:outline", r.outline)
  e.flag("w:shadow", r.shadow)
  e.flag("w:emboss", r.emboss)
  e.flag("w:imprint", r.imprint)
  e.flag("w:noProof", r.noProof)
  e.flag("w:fitText", r.fitText)
  e.flag("w:bCs", r.boldCs)
  e.flag("w:iCs", r.italicCs)
  if r.sizeCsHalfPts != 0:
    e.empty("w:szCs", attr("w:val", $r.sizeCsHalfPts))
  if r.hasRIns: e.empty("w:ins", writeRevAttrs(r.rIns))
  if r.hasRDel: e.empty("w:del", writeRevAttrs(r.rDel))
  if r.hasRPrChange: e.writePropChange("w:rPrChange", r.rPrChange)
  e.close("w:rPr")

proc hasRPr(r: Run): bool =
  ## Whether the run carries any formatting worth an `w:rPr`.
  r.bold or r.italic or r.underline or r.strike or r.dstrike or
    r.sizeHalfPts != 0 or
    r.color != "" or r.colorTheme != "" or r.fonts != "" or
    r.fontsEastAsia != "" or r.fontsHAnsi != "" or r.lang != "" or
    r.highlight != "" or r.styleId != "" or r.vertAlign != "" or
    r.spacingTwips != 0 or r.positionPts != 0 or r.kernHalfPts != 0 or
    r.shading != "" or r.caps or r.smallCaps or r.vanish or r.webHidden or
    r.outline or r.shadow or r.emboss or r.imprint or r.noProof or
    r.fitText or r.boldCs or r.italicCs or r.sizeCsHalfPts != 0 or
    r.hasRIns or r.hasRDel or r.hasRPrChange

proc writeRunText(e: var XmlEmit, s: string) =
  ## Split text into `w:t` runs with `w:tab`/`w:br` for control chars
  ## (inverse of the reader mapping).
  var seg = ""
  proc flush(e: var XmlEmit, seg: string) =
    if seg == "": return
    let preserve = seg[0] == ' ' or seg[^1] == ' ' or seg.strip() == ""
    if preserve:
      e.elem("w:t", seg, attr("xml:space", "preserve"))
    else:
      e.elem("w:t", seg)
  for ch in s:
    case ch
    of '\t':
      e.flush(seg); seg = ""
      e.empty("w:tab")
    of '\n':
      e.flush(seg); seg = ""
      e.empty("w:br")
    of '\f':
      e.flush(seg); seg = ""
      e.empty("w:br", attr("w:type", "page"))
    else: seg.add ch
  e.flush(seg)

proc writeDrawing(e: var XmlEmit, rid: string, d: Drawing, id: int) =
  ## Image drawing; unknown geometry (fresh docs) emits a 0x0 inline.
  e.open("w:drawing")
  let box = if d.placement == dpAnchor: "wp:anchor" else: "wp:inline"
  var a = attr("distT", "0") & attr("distB", "0") & attr("distL", "0") &
    attr("distR", "0")
  if d.placement == dpAnchor:
    if d.behindDoc: a.add attr("behindDoc", "1")
  e.open(box, a)
  e.empty("wp:extent", attr("cx", $d.cxEmu) & attr("cy", $d.cyEmu))
  if d.placement == dpAnchor:
    e.empty("wp:positionH", attr("relativeFrom", d.posHFrom))
    e.empty("wp:positionV", attr("relativeFrom", d.posVFrom))
  e.empty("wp:docPr", attr("id", $id) & optAttr("name", d.name) &
    optAttr("descr", d.descr))
  e.empty("wp:cNvGraphicFramePr")
  e.open("a:graphic", DrawNs)
  e.open("a:graphicData",
    attr("uri", "http://schemas.openxmlformats.org/drawingml/2006/picture"))
  e.open("pic:pic")
  e.open("pic:nvPicPr")
  e.empty("pic:cNvPr", attr("id", $id) & optAttr("name", d.name))
  e.empty("pic:cNvPicPr")
  e.close("pic:nvPicPr")
  e.open("pic:blipFill")
  e.empty("a:blip", attr("r:embed", rid))
  e.open("a:stretch")
  e.empty("a:fillRect")
  e.close("a:stretch")
  e.close("pic:blipFill")
  e.open("pic:spPr")
  e.open("a:xfrm")
  e.empty("a:off", attr("x", "0") & attr("y", "0"))
  e.empty("a:ext", attr("cx", $d.cxEmu) & attr("cy", $d.cyEmu))
  e.close("a:xfrm")
  e.open("a:prstGeom", attr("prst", "rect"))
  e.empty("a:avLst")
  e.close("a:prstGeom")
  e.close("pic:spPr")
  e.close("pic:pic")
  e.close("a:graphicData")
  e.close("a:graphic")
  e.close(box)
  e.close("w:drawing")

func quoteInstrArg(arg: string): string =
  ## Instruction argument in canonical form (always quoted).
  "\"" & arg & "\""

func serializeInstr*(instr: FieldInstr): string =
  ## Canonical instruction text for freshly built runs. Round-trips
  ## prefer `instrRaw`; this covers runs constructed without source.
  case instr.kind
  of fikNone: result = ""
  of fikToc:
    result = "TOC"
    for sw in instr.toc.switches:
      result.add " \\" & sw.flag
      if sw.hasArg: result.add " " & quoteInstrArg(sw.arg)
  of fikTc:
    result = "TC " & quoteInstrArg(instr.tc.text)
    if instr.tc.itemId != "": result.add " \\f " & instr.tc.itemId
    if instr.tc.level != -1: result.add " \\l " & $instr.tc.level
    if instr.tc.omitsPageNum: result.add " \\n"
  of fikPage: result = "PAGE"
  of fikNumPages: result = "NUMPAGES"
  of fikPageRef:
    result = "PAGEREF " & instr.pageRef.bookmark
    if instr.pageRef.hyperlink: result.add " \\h"
    if instr.pageRef.relPos: result.add " \\p"
  of fikHyperlink:
    result = "HYPERLINK " & quoteInstrArg(instr.hyperlink.target)
    if instr.hyperlink.anchor: result.add " \\l"
  of fikUnsupported: result = instr.raw

proc writeRun(e: var XmlEmit, r: Run, doc: DocxDocument, drawId: var int) =
  e.open("w:r", optAttr("w:rsidR", r.rsidR))
  if r.hasRPr: e.writeRunRPr(r)
  if r.fldChar != fckNone:
    let kind = case r.fldChar
      of fckBegin: "begin"
      of fckSeparate: "separate"
      of fckEnd: "end"
      of fckUnknown: r.fldCharRaw
      of fckNone: ""
    e.empty("w:fldChar", attr("w:fldCharType", kind) &
      attr("w:dirty", if r.fldDirty: "true" else: "false"))
  if r.fldLock: e.empty("w:fldLock")
  if r.instrRaw != "" or r.instr.kind != fikNone:
    let tag = if r.delInstr: "w:delInstrText" else: "w:instrText"
    let body = if r.instrRaw != "": r.instrRaw
      else: serializeInstr(r.instr)
    e.elem(tag, body, attr("xml:space", "preserve"))
  if r.delText != "":
    e.elem("w:delText", r.delText, attr("xml:space", "preserve"))
  if r.symChar != "":
    # symbol glyph first (matches observed files); text follows.
    e.empty("w:sym", attr("w:font", r.symFont) & attr("w:char", r.symChar))
  e.writeRunText(r.text)
  if r.footnoteRef != -1:
    e.empty("w:footnoteReference", attr("w:id", $r.footnoteRef))
  if r.endnoteRef != -1:
    e.empty("w:endnoteReference", attr("w:id", $r.endnoteRef))
  if r.commentRef != -1:
    e.empty("w:commentReference", attr("w:id", $r.commentRef))
  if r.drawingRid != "":
    inc drawId
    e.writeDrawing(r.drawingRid, doc.drawings.getOrDefault(r.drawingRid),
      drawId)
  e.close("w:r")

proc writeParaInner(e: var XmlEmit, p: Paragraph) =
  ## `w:pPr` children without the wrapper (lets section breaks append
  ## a `w:sectPr` inside the same `w:pPr`).
  if p.styleId != "": e.empty("w:pStyle", attr("w:val", p.styleId))
  if p.align != "": e.empty("w:jc", attr("w:val", p.align))
  if p.numId != -1 or p.numIlvl != 0 or p.hasNumPrChange:
    e.open("w:numPr")
    e.empty("w:ilvl", attr("w:val", $p.numIlvl))
    if p.numId != -1:
      e.empty("w:numId", attr("w:val", $p.numId))
    if p.hasNumPrChange:
      e.writePropChange("w:numPrChange", p.numPrChange)
    e.close("w:numPr")
  if p.indentLeft != -1 or p.indentFirstLine != -1:
    e.empty("w:ind", optAttrI("w:left", p.indentLeft, -1) &
      optAttrI("w:firstLine", p.indentFirstLine, -1))
  if p.spacingBefore != -1 or p.spacingAfter != -1:
    e.empty("w:spacing", optAttrI("w:before", p.spacingBefore, -1) &
      optAttrI("w:after", p.spacingAfter, -1))
  if p.outlineLvl != -1:
    e.empty("w:outlineLvl", attr("w:val", $p.outlineLvl))
  e.flag("w:keepNext", p.keepNext)
  e.flag("w:keepLines", p.keepLines)
  e.flag("w:pageBreakBefore", p.pageBreakBefore)
  e.flag("w:widowControl", p.widowControl)
  if p.shading != "":
    e.empty("w:shd", attr("w:val", "clear") & attr("w:fill", p.shading))
  e.flag("w:bidi", p.bidi)
  if p.textAlignment != "":
    e.empty("w:textAlignment", attr("w:val", p.textAlignment))
  if p.tabs.len > 0:
    e.open("w:tabs")
    for t in p.tabs:
      e.empty("w:tab", optAttr("w:val", t.kind) & attr("w:pos", $t.pos))
    e.close("w:tabs")
  e.writeBorders("w:pBdr", p.borders)
  if p.hasPPrIns: e.empty("w:ins", writeRevAttrs(p.pPrIns))
  if p.hasPPrDel: e.empty("w:del", writeRevAttrs(p.pPrDel))
  if p.hasPPrChange:
    e.open("w:pPrChange", writeRevAttrs(p.pPrChange.meta))
    e.open("w:pPr")
    if not p.pPrChange.ppr.isNil:
      e.writeParaInner(p.pPrChange.ppr[])
    e.close("w:pPr")
    e.close("w:pPrChange")

func paraAttrs(p: Paragraph): string =
  ## `w:p` attributes (revision ids).
  optAttr("w:rsidR", p.rsidR)

func pprAttrs(p: Paragraph): string =
  ## `w:pPr` attributes (revision ids).
  optAttr("w:rsidP", p.rsidP) & optAttr("w:rsidRPr", p.rsidRPr) &
    optAttr("w:rsidDel", p.rsidDel)

proc writeParaPPr(e: var XmlEmit, p: Paragraph) =
  e.open("w:pPr", pprAttrs(p))
  e.writeParaInner(p)
  e.close("w:pPr")

proc hasPPr(p: Paragraph): bool =
  p.styleId != "" or p.align != "" or p.numId != -1 or p.numIlvl != 0 or
    p.indentLeft != -1 or p.indentFirstLine != -1 or
    p.spacingBefore != -1 or p.spacingAfter != -1 or p.outlineLvl != -1 or
    p.keepNext or p.keepLines or p.pageBreakBefore or p.widowControl or
    p.shading != "" or p.bidi or p.textAlignment != "" or
    p.tabs.len > 0 or p.borders != Borders() or p.hasPPrIns or
    p.hasPPrDel or p.hasPPrChange or p.hasNumPrChange or
    p.rsidP != "" or p.rsidRPr != "" or p.rsidDel != ""

proc writeRunGroup(e: var XmlEmit, runs: openArray[Run], doc: DocxDocument,
    drawId: var int) =
  ## Consecutive runs with shared-hyperlink grouping.
  var i = 0
  while i < runs.len:
    let rid = runs[i].hyperlinkRid
    if rid == "":
      e.writeRun(runs[i], doc, drawId)
      inc i
    else: # group consecutive same-target runs into one hyperlink
      e.open("w:hyperlink", attr("r:id", rid))
      while i < runs.len and runs[i].hyperlinkRid == rid:
        e.writeRun(runs[i], doc, drawId)
        inc i
      e.close("w:hyperlink")

proc writeParaRuns(e: var XmlEmit, p: Paragraph, doc: DocxDocument,
    drawId: var int) =
  for b in p.bookmarks:
    e.empty("w:bookmarkStart", attr("w:id", $b.id) &
      attr("w:name", b.name))
    e.empty("w:bookmarkEnd", attr("w:id", $b.id))
  for m in p.rangeMarkers: # normalized before runs (order not modeled)
    e.empty(m.tag, attr("w:id", m.id) & optAttr("w:name", m.name) &
      optAttr("w:uri", m.uri) & optAttr("w:element", m.element))
  var i = 0
  while i < p.kids.len:
    case p.kids[i].kind
    of pkRun:
      # longest pkRun stretch shares hyperlink grouping
      var j = i
      while j < p.kids.len and p.kids[j].kind == pkRun: inc j
      var grp: seq[Run] = @[]
      for k in i ..< j: grp.add p.kids[k].run
      e.writeRunGroup(grp, doc, drawId)
      i = j
    of pkFldSimple:
      let f = p.kids[i].fld
      let body = if f.instrRaw != "": f.instrRaw
        else: serializeInstr(f.instr)
      e.open("w:fldSimple", attr("w:instr", body))
      e.writeRunGroup(f.runs, doc, drawId)
      e.close("w:fldSimple")
      inc i
    of pkIns, pkDel, pkMoveFrom, pkMoveTo:
      let tag = case p.kids[i].kind
        of pkIns: "w:ins"
        of pkDel: "w:del"
        of pkMoveFrom: "w:moveFrom"
        else: "w:moveTo"
      e.open(tag, writeRevAttrs(p.kids[i].rev.meta))
      e.writeRunGroup(p.kids[i].rev.runs, doc, drawId)
      e.close(tag)
      inc i

proc writeBlocks(e: var XmlEmit, blocks: seq[Block], doc: DocxDocument,
    drawId: var int)

proc writeTable(e: var XmlEmit, t: DocxTable, doc: DocxDocument,
    drawId: var int) =
  e.open("w:tbl")
  e.open("w:tblPr")
  if t.styleId != "": e.empty("w:tblStyle", attr("w:val", t.styleId))
  if t.width != -1 or t.widthType != "":
    e.empty("w:tblW", optAttrI("w:w", t.width, -1) &
      optAttr("w:type", t.widthType))
  if t.align != "": e.empty("w:jc", attr("w:val", t.align))
  if t.look != "": e.empty("w:tblLook", attr("w:val", t.look))
  e.writeBorders("w:tblBorders", t.borders)
  if t.shading != "":
    e.empty("w:shd", attr("w:val", "clear") & attr("w:fill", t.shading))
  if t.cellSpacing != -1 or t.cellSpacingType != "":
    e.empty("w:tblCellSpacing", optAttrI("w:w", t.cellSpacing, -1) &
      optAttr("w:type", t.cellSpacingType))
  if t.layout != "": e.empty("w:tblLayout", attr("w:type", t.layout))
  if t.hasTblPrChange: e.writePropChange("w:tblPrChange", t.tblPrChange)
  e.close("w:tblPr")
  if t.grid.len > 0 or t.hasTblGridChange:
    e.open("w:tblGrid")
    for w in t.grid: e.empty("w:gridCol", attr("w:w", $w))
    if t.hasTblGridChange:
      e.writePropChange("w:tblGridChange", t.tblGridChange)
    e.close("w:tblGrid")
  for row in t.rows:
    e.open("w:tr")
    if row.height != 0 or row.heightRule != "" or row.isHeader or
        row.cantSplit or row.hasTrIns or row.hasTrDel or
        row.hasTrPrChange:
      e.open("w:trPr")
      if row.height != 0 or row.heightRule != "":
        e.empty("w:trHeight", optAttrI("w:val", row.height, 0) &
          optAttr("w:hRule", row.heightRule))
      e.flag("w:tblHeader", row.isHeader)
      e.flag("w:cantSplit", row.cantSplit)
      if row.hasTrIns: e.empty("w:ins", writeRevAttrs(row.trIns))
      if row.hasTrDel: e.empty("w:del", writeRevAttrs(row.trDel))
      if row.hasTrPrChange:
        e.writePropChange("w:trPrChange", row.trPrChange)
      e.close("w:trPr")
    for cell in row.cells:
      e.open("w:tc")
      e.open("w:tcPr")
      if cell.gridSpan > 1:
        e.empty("w:gridSpan", attr("w:val", $cell.gridSpan))
      if cell.vMerge == "restart":
        e.empty("w:vMerge", attr("w:val", "restart"))
      elif cell.vMerge == "continue":
        e.empty("w:vMerge")
      if cell.shading != "":
        e.empty("w:shd", attr("w:val", "clear") &
          attr("w:fill", cell.shading))
      if cell.width != -1 or cell.widthType != "":
        e.empty("w:tcW", optAttrI("w:w", cell.width, -1) &
          optAttr("w:type", cell.widthType))
      if cell.vAlign != "":
        e.empty("w:vAlign", attr("w:val", cell.vAlign))
      e.writeBorders("w:tcBorders", cell.borders)
      if cell.hasTcIns: e.empty("w:cellIns", writeRevAttrs(cell.tcIns))
      if cell.hasTcDel: e.empty("w:cellDel", writeRevAttrs(cell.tcDel))
      if cell.hasTcMerge:
        e.empty("w:cellMerge", writeRevAttrs(cell.tcMerge))
      if cell.hasTcPrChange:
        e.writePropChange("w:tcPrChange", cell.tcPrChange)
      e.close("w:tcPr")
      e.writeBlocks(cell.blocks, doc, drawId)
      e.close("w:tc")
    e.close("w:tr")
  e.close("w:tbl")

proc writeTextboxDrawing(e: var XmlEmit, tb: Textbox, doc: DocxDocument,
    drawId: var int) =
  ## Floating-shape drawing fragment (caller provides the host run).
  ## The original host run is not modeled; callers attach to the
  ## preceding paragraph when there is one.
  inc drawId
  e.open("mc:AlternateContent")
  e.open("mc:Choice", attr("Requires", "wps"))
  e.open("w:drawing")
  e.open("wp:anchor", attr("distT", "0") & attr("distB", "0") &
    attr("distL", "0") & attr("distR", "0"))
  e.empty("wp:extent", attr("cx", $tb.cxEmu) & attr("cy", $tb.cyEmu))
  e.empty("wp:docPr", attr("id", $drawId))
  e.empty("wp:cNvGraphicFramePr")
  e.open("a:graphic", DrawNs)
  e.open("a:graphicData",
    attr("uri", "http://schemas.microsoft.com/office/word/2010/wordprocessingShape"))
  e.open("wps:wsp")
  e.empty("wps:cNvSpPr", attr("txBox", "1"))
  e.open("wps:spPr")
  e.open("a:xfrm")
  e.empty("a:off", attr("x", "0") & attr("y", "0"))
  e.empty("a:ext", attr("cx", $tb.cxEmu) & attr("cy", $tb.cyEmu))
  e.close("a:xfrm")
  e.open("a:prstGeom", attr("prst", "rect"))
  e.empty("a:avLst")
  e.close("a:prstGeom")
  e.close("wps:spPr")
  e.open("wps:txbx")
  e.open("w:txbxContent")
  e.writeBlocks(tb.blocks, doc, drawId)
  e.close("w:txbxContent")
  e.close("wps:txbx")
  e.close("wps:wsp")
  e.close("a:graphicData")
  e.close("a:graphic")
  e.close("wp:anchor")
  e.close("w:drawing")
  e.close("mc:Choice")
  e.close("mc:AlternateContent")

proc writeParagraphRuns(e: var XmlEmit, p: Paragraph,
    textboxes: seq[Textbox], doc: DocxDocument, drawId: var int) =
  ## Paragraph runs plus trailing textbox drawings in their own runs
  ## (no extra paragraph, so flat text is unchanged).
  e.writeParaRuns(p, doc, drawId)
  for tb in textboxes:
    e.open("w:r")
    e.writeTextboxDrawing(tb, doc, drawId)
    e.close("w:r")

proc writeParagraph(e: var XmlEmit, p: Paragraph, doc: DocxDocument,
    drawId: var int) =
  e.open("w:p", paraAttrs(p))
  if p.hasPPr: e.writeParaPPr(p)
  e.writeParagraphRuns(p, @[], doc, drawId)
  e.close("w:p")

proc writeStandaloneTextbox(e: var XmlEmit, tb: Textbox,
    doc: DocxDocument, drawId: var int) =
  ## Textbox with no preceding paragraph (or outside one): wrapper
  ## paragraph hosts the shape.
  e.open("w:p")
  e.open("w:r")
  e.writeTextboxDrawing(tb, doc, drawId)
  e.close("w:r")
  e.close("w:p")

proc writeSdt(e: var XmlEmit, s: Sdt, doc: DocxDocument, drawId: var int) =
  e.open("w:sdt")
  e.open("w:sdtPr")
  if s.alias != "": e.empty("w:alias", attr("w:val", s.alias))
  if s.tag != "": e.empty("w:tag", attr("w:val", s.tag))
  e.close("w:sdtPr")
  e.open("w:sdtContent")
  e.writeBlocks(s.blocks, doc, drawId)
  e.close("w:sdtContent")
  e.close("w:sdt")

proc writeBlocks(e: var XmlEmit, blocks: seq[Block], doc: DocxDocument,
    drawId: var int) =
  var i = 0
  while i < blocks.len:
    case blocks[i].kind
    of bkParagraph:
      # textboxes drained after their host paragraph reattach to it.
      var j = i + 1
      var tbs: seq[Textbox]
      while j < blocks.len and blocks[j].kind == bkTextbox:
        tbs.add blocks[j].textbox
        inc j
      e.open("w:p", paraAttrs(blocks[i].paragraph))
      let p = blocks[i].paragraph
      if p.hasPPr: e.writeParaPPr(p)
      e.writeParagraphRuns(p, tbs, doc, drawId)
      e.close("w:p")
      i = j
    of bkTable:
      e.writeTable(blocks[i].table, doc, drawId)
      inc i
    of bkTextbox:
      e.writeStandaloneTextbox(blocks[i].textbox, doc, drawId)
      inc i
    of bkSdt:
      e.writeSdt(blocks[i].sdt, doc, drawId)
      inc i
    of bkIns, bkDel:
      let tag = if blocks[i].kind == bkIns: "w:ins" else: "w:del"
      e.open(tag, writeRevAttrs(blocks[i].rev.meta))
      e.writeBlocks(blocks[i].rev.blocks, doc, drawId)
      e.close(tag)
      inc i

proc writeSectPr(e: var XmlEmit, s: Section) =
  e.open("w:sectPr")
  for r in s.headerRefs:
    e.empty("w:headerReference", attr("w:type", r.refKind) &
      attr("r:id", r.relId))
  for r in s.footerRefs:
    e.empty("w:footerReference", attr("w:type", r.refKind) &
      attr("r:id", r.relId))
  if s.props.sectType != "":
    e.empty("w:type", attr("w:val", s.props.sectType))
  if s.props.pgW > 0 or s.props.pgH > 0:
    e.empty("w:pgSz", attr("w:w", $s.props.pgW) & attr("w:h", $s.props.pgH) &
      optAttr("w:orient", s.props.orient))
  let m = s.props
  if m.marginTop != 0 or m.marginRight != 0 or m.marginBottom != 0 or
      m.marginLeft != 0 or m.headerDist != 0 or m.footerDist != 0 or
      m.gutter != 0 or m.mirrorMargins:
    e.empty("w:pgMar", attr("w:top", $m.marginTop) &
      attr("w:right", $m.marginRight) & attr("w:bottom", $m.marginBottom) &
      attr("w:left", $m.marginLeft) & attr("w:header", $m.headerDist) &
      attr("w:footer", $m.footerDist) & attr("w:gutter", $m.gutter))
  if m.colsNum != 1 or m.colsSpace != 0:
    e.empty("w:cols", attr("w:num", $m.colsNum) &
      attr("w:space", $m.colsSpace))
  e.flag("w:titlePg", m.titlePg)
  if m.pgNumFmt != "" or m.pgNumStart != -1:
    e.empty("w:pgNumType", optAttr("w:fmt", m.pgNumFmt) &
      optAttrI("w:start", m.pgNumStart, -1))
  if m.textDirection != "":
    e.empty("w:textDirection", attr("w:val", m.textDirection))
  if m.linePitch != -1:
    e.empty("w:docGrid", attr("w:linePitch", $m.linePitch))
  if s.props.hasSectPrChange:
    e.writePropChange("w:sectPrChange", s.props.sectPrChange)
  e.close("w:sectPr")

proc writeDocumentXml*(doc: DocxDocument): string =
  ## Serialize body sections to a `word/document.xml` part. Header/footer
  ## rel-ids come straight from the section refs (minted in the assembly
  ## pre-pass for fresh documents); non-final sections carry their
  ## `sectPr` in the last paragraph, the final one ends the body.
  var e = XmlEmit()
  e.decl()
  e.open("w:document", DocNs)
  e.open("w:body")
  var drawId = 0
  for si, s in doc.sections:
    if si == doc.sections.len - 1:
      e.writeBlocks(s.blocks, doc, drawId)
    elif s.blocks.len > 0 and s.blocks[^1].kind == bkParagraph:
      # non-final section: sectPr rides in the last paragraph's pPr.
      e.writeBlocks(s.blocks[0 .. ^2], doc, drawId)
      let p = s.blocks[^1].paragraph
      e.open("w:p", paraAttrs(p))
      e.open("w:pPr", pprAttrs(p))
      e.writeParaInner(p)
      e.writeSectPr(s)
      e.close("w:pPr")
      e.writeParaRuns(p, doc, drawId)
      e.close("w:p")
    else:
      # section ends with a table/textbox/sdt or is empty: a trailing
      # carrier paragraph holds the sectPr.
      e.writeBlocks(s.blocks, doc, drawId)
      e.open("w:p")
      e.open("w:pPr")
      e.writeSectPr(s)
      e.close("w:pPr")
      e.close("w:p")
  if doc.sections.len == 0:
    e.writeSectPr(Section(props: SectionProps(pgNumStart: -1,
      linePitch: -1, colsNum: 1)))
  else:
    e.writeSectPr(doc.sections[^1])
  e.close("w:body")
  e.close("w:document")
  e.buf

# ------------------------------------------------------ styles + numbering

proc writeNumLevel(e: var XmlEmit, lvl: NumberingLevel) =
  e.open("w:lvl", attr("w:ilvl", $lvl.ilvl))
  e.empty("w:start", attr("w:val", $lvl.start))
  if lvl.format != "": e.empty("w:numFmt", attr("w:val", lvl.format))
  if lvl.pStyle != "": e.empty("w:pStyle", attr("w:val", lvl.pStyle))
  if lvl.text != "": e.empty("w:lvlText", attr("w:val", lvl.text))
  if lvl.justification != "":
    e.empty("w:lvlJc", attr("w:val", lvl.justification))
  if lvl.pPrJc != "" or lvl.tabs.len > 0 or lvl.indentLeft != -1 or
      lvl.indentHanging != -1 or lvl.indentRight != -1 or
      lvl.indentFirstLine != -1 or lvl.indentLeftChars != -1 or
      lvl.indentHangingChars != -1 or lvl.indentFirstLineChars != -1:
    e.open("w:pPr")
    if lvl.tabs.len > 0:
      e.open("w:tabs")
      for t in lvl.tabs:
        e.empty("w:tab", optAttr("w:val", t.kind) & attr("w:pos", $t.pos))
      e.close("w:tabs")
    if lvl.indentLeft != -1 or lvl.indentHanging != -1 or
        lvl.indentRight != -1 or lvl.indentFirstLine != -1 or
        lvl.indentLeftChars != -1 or lvl.indentHangingChars != -1 or
        lvl.indentFirstLineChars != -1:
      e.empty("w:ind", optAttrI("w:left", lvl.indentLeft, -1) &
        optAttrI("w:hanging", lvl.indentHanging, -1) &
        optAttrI("w:right", lvl.indentRight, -1) &
        optAttrI("w:firstLine", lvl.indentFirstLine, -1) &
        optAttrI("w:leftChars", lvl.indentLeftChars, -1) &
        optAttrI("w:hangingChars", lvl.indentHangingChars, -1) &
        optAttrI("w:firstLineChars", lvl.indentFirstLineChars, -1))
    if lvl.pPrJc != "": e.empty("w:jc", attr("w:val", lvl.pPrJc))
    e.close("w:pPr")
  if lvl.hasLvlRPr: e.writeRunRPr(lvl.lvlRPr)
  if lvl.lvlRestart != -1:
    e.empty("w:lvlRestart", attr("w:val", $lvl.lvlRestart))
  e.flag("w:isLgl", lvl.isLgl)
  if lvl.legacyVal != -1 or lvl.legacySpace != -1 or
      lvl.legacyIndent != -1:
    e.empty("w:legacy", optAttrI("w:legacy", lvl.legacyVal, -1) &
      optAttrI("w:space", lvl.legacySpace, -1) &
      optAttrI("w:legacyIndent", lvl.legacyIndent, -1))
  if lvl.suffix != "": e.empty("w:suff", attr("w:val", lvl.suffix))
  e.close("w:lvl")

proc writeNumberingXml*(doc: DocxDocument): string =
  ## Serialize caller-supplied `numberingDefs` to `word/numbering.xml`.
  ## Shared abstract ids emit once (the normal override-sharing
  ## pattern); conflicting level sets for one abstract id fail loudly.
  var e = XmlEmit()
  e.decl()
  e.open("w:numbering", WNs)
  var doneAbs: seq[int]
  for def in doc.numberingDefs:
    if def.abstractId in doneAbs:
      for prev in doc.numberingDefs:
        if prev.abstractId == def.abstractId:
          if prev.levels != def.levels:
            raise newException(DocxError,
              "conflicting levels for abstractNumId " & $def.abstractId)
          break
      continue
    doneAbs.add def.abstractId
    e.open("w:abstractNum", attr("w:abstractNumId", $def.abstractId))
    e.empty("w:multiLevelType", attr("w:val",
      if def.levels.len > 1: "multilevel" else: "singleLevel"))
    for lvl in def.levels: e.writeNumLevel(lvl)
    e.close("w:abstractNum")
  for def in doc.numberingDefs:
    e.open("w:num", attr("w:numId", $def.numId))
    e.empty("w:abstractNumId", attr("w:val", $def.abstractId))
    for ov in def.overrides:
      e.open("w:lvlOverride", attr("w:ilvl", $ov.ilvl))
      if ov.hasLevel:
        e.writeNumLevel(ov.level)
      elif ov.startOverride >= 0:
        e.empty("w:startOverride", attr("w:val", $ov.startOverride))
      e.close("w:lvlOverride")
    e.close("w:num")
  e.close("w:numbering")
  e.buf

proc writeStylesXml*(doc: DocxDocument): string =
  ## Serialize the `styles` table to `word/styles.xml`. Style paragraph
  ## and run formatting reuse the body emitters; table-style `w:tblPr`
  ## passes through verbatim from the reader.
  var e = XmlEmit()
  e.decl()
  e.open("w:styles", WNs)
  for id, s in doc.styles:
    e.open("w:style", attr("w:type", s.kind) & attr("w:styleId", id) &
      (if s.isDefault: attr("w:default", "1") else: "") &
      (if s.custom: attr("w:customStyle", "1") else: ""))
    if s.name != "": e.empty("w:name", attr("w:val", s.name))
    if s.basedOn != "": e.empty("w:basedOn", attr("w:val", s.basedOn))
    if s.next != "": e.empty("w:next", attr("w:val", s.next))
    if s.link != "": e.empty("w:link", attr("w:val", s.link))
    e.flag("w:qFormat", s.qFormat)
    if s.hasPPr: e.writeParaPPr(s.pPr)
    if s.hasRPr: e.writeRunRPr(s.rPr)
    if s.tblPrRaw != "":
      e.open("w:tblPr")
      e.buf.add s.tblPrRaw
      e.close("w:tblPr")
    e.close("w:style")
  e.close("w:styles")
  e.buf

# ---------------------------------------------------------- package assembly

const
  PkgCtNs = "http://schemas.openxmlformats.org/package/2006/content-types"
  PkgRelNs = "http://schemas.openxmlformats.org/package/2006/relationships"
  DocRelNs = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

type
  RelEntry = tuple[id, typ, target: string, external: bool]

proc writeRelsXml(entries: seq[RelEntry]): string =
  var e = XmlEmit()
  e.decl()
  e.open("Relationships", attr("xmlns", PkgRelNs))
  for en in entries:
    e.empty("Relationship", attr("Id", en.id) &
      attr("Type", en.typ) & attr("Target", en.target) &
      (if en.external: attr("TargetMode", "External") else: ""))
  e.close("Relationships")
  e.buf

func docRel(kind: string): string = DocRelNs & "/" & kind

func extForContentType(ct: string): string =
  case ct.toLowerAscii()
  of "image/png": "png"
  of "image/jpeg": "jpg"
  of "image/gif": "gif"
  of "image/bmp": "bmp"
  of "image/tiff": "tiff"
  of "image/webp": "webp"
  else: "bin"

func mimeForExt(ext: string): string =
  case ext.toLowerAscii()
  of "png": "image/png"
  of "jpg", "jpeg": "image/jpeg"
  of "gif": "image/gif"
  of "bmp": "image/bmp"
  of "tiff", "tif": "image/tiff"
  of "webp": "image/webp"
  else: "application/octet-stream"

func partContentType(part: string): string =
  ## Content type for a generated part (mirrors common Word output).
  case part
  of "_rels/.rels": PkgRelNs
  of "docProps/core.xml":
    "application/vnd.openxmlformats-package.core-properties+xml"
  of "docProps/app.xml":
    "application/vnd.openxmlformats-officedocument.extended-properties+xml"
  of "docProps/custom.xml":
    "application/vnd.openxmlformats-officedocument.custom-properties+xml"
  of "word/document.xml":
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"
  of "word/styles.xml":
    "application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"
  of "word/numbering.xml":
    "application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"
  of "word/settings.xml":
    "application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml"
  of "word/fontTable.xml":
    "application/vnd.openxmlformats-officedocument.wordprocessingml.fontTable+xml"
  of "word/comments.xml":
    "application/vnd.openxmlformats-officedocument.wordprocessingml.comments+xml"
  of "word/commentsExtended.xml":
    "application/vnd.openxmlformats-officedocument.wordprocessingml.commentsExtended+xml"
  of "word/footnotes.xml":
    "application/vnd.openxmlformats-officedocument.wordprocessingml.footnotes+xml"
  of "word/endnotes.xml":
    "application/vnd.openxmlformats-officedocument.wordprocessingml.endnotes+xml"
  of "word/theme/theme1.xml":
    "application/vnd.openxmlformats-officedocument.theme+xml"
  else:
    if part.startsWith("word/header"):
      "application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml"
    elif part.startsWith("word/footer"):
      "application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml"
    elif part.endsWith(".rels"):
      PkgRelNs
    elif part.endsWith(".xml"):
      "application/xml"
    else:
      "application/octet-stream"

proc writeContentTypesXml(partNames: seq[string],
    mediaExts: seq[string]): string =
  ## Synthesized over emitted parts: Defaults for rels/xml plus every
  ## used media extension, Overrides for everything else.
  var e = XmlEmit()
  e.decl()
  e.open("Types", attr("xmlns", PkgCtNs))
  e.empty("Default", attr("Extension", "rels") &
    attr("ContentType", PkgRelNs))
  e.empty("Default", attr("Extension", "xml") &
    attr("ContentType", "application/xml"))
  var seen: seq[string]
  for x in mediaExts:
    if x notin seen:
      seen.add x
      e.empty("Default", attr("Extension", x) &
        attr("ContentType", mimeForExt(x)))
  var seenParts: seq[string]
  for p in partNames:
    if p == "[Content_Types].xml" or p.endsWith("/"): continue
    if p in seenParts: continue
    seenParts.add p
    if p.startsWith("word/media/"): continue # covered by Defaults above
    let dot = p.rfind('.')
    let ext = if dot >= 0: p[dot + 1 .. ^1].toLowerAscii() else: ""
    if ext == "rels": continue # Default covers
    if ext in seen: continue # media Default covers
    let ct = partContentType(p)
    if ext == "xml" and ct == "application/xml": continue # Default covers
    e.empty("Override", attr("PartName", "/" & p) &
      attr("ContentType", ct))
  e.close("Types")
  e.buf

# ------------------------------------------------------------- block walking

proc eachRunInBlocks(blocks: var seq[Block], cb: proc(r: var Run) {.closure.}) =
  proc runCb(k: var ParaKid) =
    if k.kind == pkRun: cb(k.run)
    elif k.kind == pkFldSimple:
      for r in k.fld.runs.mitems: cb(r)
    else:
      for r in k.rev.runs.mitems: cb(r)
  for b in blocks.mitems:
    case b.kind
    of bkParagraph:
      for k in b.paragraph.kids.mitems: runCb(k)
    of bkTable:
      for row in b.table.rows.mitems:
        for cell in row.cells.mitems:
          eachRunInBlocks(cell.blocks, cb)
    of bkTextbox: eachRunInBlocks(b.textbox.blocks, cb)
    of bkSdt: eachRunInBlocks(b.sdt.blocks, cb)
    of bkIns, bkDel: eachRunInBlocks(b.rev.blocks, cb)

proc eachParaInBlocks(blocks: var seq[Block], cb: proc(p: var Paragraph) {.closure.}) =
  for b in blocks.mitems:
    case b.kind
    of bkParagraph: cb(b.paragraph)
    of bkTable:
      for row in b.table.rows.mitems:
        for cell in row.cells.mitems:
          eachParaInBlocks(cell.blocks, cb)
    of bkTextbox: eachParaInBlocks(b.textbox.blocks, cb)
    of bkSdt: eachParaInBlocks(b.sdt.blocks, cb)
    of bkIns, bkDel: eachParaInBlocks(b.rev.blocks, cb)

proc eachContainer(doc: var DocxDocument,
    cb: proc(blocks: var seq[Block]) {.closure.}) =
  ## Every block list in the document: sections, headers, footers,
  ## footnotes, endnotes, comments.
  for s in doc.sections.mitems:
    cb(s.blocks)
    for h in s.headers.mitems: cb(h.blocks)
    for f in s.footers.mitems: cb(f.blocks)
  for n in doc.footnotes.mitems: cb(n.blocks)
  for n in doc.endnotes.mitems: cb(n.blocks)
  for c in doc.comments.mitems: cb(c.blocks)

proc collectRids(blocks: seq[Block], rids: var Table[string, bool]) =
  ## hyperlink + drawing rel-ids referenced from a block list.
  ## Direct recursion (no walker closures) so callers may hold borrows.
  for b in blocks:
    case b.kind
    of bkParagraph:
      for k in b.paragraph.kids:
        if k.kind == pkRun:
          if k.run.hyperlinkRid != "": rids[k.run.hyperlinkRid] = true
          if k.run.drawingRid != "": rids[k.run.drawingRid] = true
        elif k.kind == pkFldSimple:
          for r in k.fld.runs:
            if r.hyperlinkRid != "": rids[r.hyperlinkRid] = true
            if r.drawingRid != "": rids[r.drawingRid] = true
        else:
          for r in k.rev.runs:
            if r.hyperlinkRid != "": rids[r.hyperlinkRid] = true
            if r.drawingRid != "": rids[r.drawingRid] = true
    of bkTable:
      for row in b.table.rows:
        for cell in row.cells: collectRids(cell.blocks, rids)
    of bkTextbox: collectRids(b.textbox.blocks, rids)
    of bkSdt: collectRids(b.sdt.blocks, rids)
    of bkIns, bkDel: collectRids(b.rev.blocks, rids)

# ----------------------------------------------------------------- pre-pass

proc failDoc(msg: string) {.noreturn.} =
  raise newException(DocxError, msg)

proc eachRevMeta(blocks: var seq[Block], cb: proc(m: var RevisionMeta) {.closure.}) =
  ## Every revision meta in a block list: wrappers, marks, changes.
  proc kidCb(k: var ParaKid) =
    proc runMarks(r: var Run) =
      if r.hasRIns: cb(r.rIns)
      if r.hasRDel: cb(r.rDel)
      if r.hasRPrChange: cb(r.rPrChange.meta)
    case k.kind
    of pkRun: runMarks(k.run)
    of pkFldSimple:
      for r in k.fld.runs.mitems: runMarks(r)
    else:
      cb(k.rev.meta)
      for r in k.rev.runs.mitems: runMarks(r)
  proc paraCb(p: var Paragraph) =
    if p.hasPPrIns: cb(p.pPrIns)
    if p.hasPPrDel: cb(p.pPrDel)
    if p.hasPPrChange: cb(p.pPrChange.meta)
    if p.hasNumPrChange: cb(p.numPrChange.meta)
    for k in p.kids.mitems: kidCb(k)
  proc blkCb(blocks: var seq[Block]) =
    for b in blocks.mitems:
      case b.kind
      of bkParagraph: paraCb(b.paragraph)
      of bkTable:
        if b.table.hasTblPrChange: cb(b.table.tblPrChange.meta)
        if b.table.hasTblGridChange: cb(b.table.tblGridChange.meta)
        for row in b.table.rows.mitems:
          if row.hasTrIns: cb(row.trIns)
          if row.hasTrDel: cb(row.trDel)
          if row.hasTrPrChange: cb(row.trPrChange.meta)
          for cell in row.cells.mitems:
            if cell.hasTcIns: cb(cell.tcIns)
            if cell.hasTcDel: cb(cell.tcDel)
            if cell.hasTcMerge: cb(cell.tcMerge)
            if cell.hasTcPrChange: cb(cell.tcPrChange.meta)
            blkCb(cell.blocks)
      of bkTextbox: blkCb(b.textbox.blocks)
      of bkSdt: blkCb(b.sdt.blocks)
      of bkIns, bkDel:
        cb(b.rev.meta)
        blkCb(b.rev.blocks)
  blkCb(blocks)

proc validateDoc(doc: var DocxDocument) =
  ## Pre-pass on the working copy: default section, rebuilt flat flow,
  ## numbering coverage, rel-id presence and cross-reference integrity.
  if doc.sections.len == 0:
    doc.sections.add Section(props: SectionProps(pgNumStart: -1,
      linePitch: -1, colsNum: 1))
  doc.blocks = @[]
  for s in doc.sections: doc.blocks.add s.blocks
  var defIds: seq[int]
  for d in doc.numberingDefs: defIds.add d.numId
  # revision ids: seed the counter past preserved numeric ids, fill
  # blanks, reject duplicates (move/range pairing keys on these).
  var maxId = 0
  proc one(m: RevisionMeta) =
    if m.id == "": return
    try: maxId = max(maxId, parseInt(m.id))
    except ValueError: discard
  proc seedCb(blocks: var seq[Block]) =
    eachRevMeta(blocks, proc(m: var RevisionMeta) = one(m))
  eachContainer(doc, seedCb)
  for s in doc.sections.mitems:
    if s.props.hasSectPrChange: one(s.props.sectPrChange.meta)
  if doc.revNextId <= maxId: doc.revNextId = maxId + 1
  if doc.revNextId <= 0: doc.revNextId = 1
  var nextId = doc.revNextId # local: closures cannot capture `doc`
  var seenIds: seq[string]
  proc idCb(blocks: var seq[Block]) =
    eachRevMeta(blocks, proc(m: var RevisionMeta) =
      if m.id == "":
        m.id = $nextId
        inc nextId
      if m.id in seenIds:
        failDoc("duplicate revision id " & m.id)
      seenIds.add m.id)
  eachContainer(doc, idCb)
  for s in doc.sections.mitems:
    if s.props.hasSectPrChange:
      if s.props.sectPrChange.meta.id == "":
        s.props.sectPrChange.meta.id = $nextId
        inc nextId
      if s.props.sectPrChange.meta.id in seenIds:
        failDoc("duplicate revision id " &
          s.props.sectPrChange.meta.id)
      seenIds.add s.props.sectPrChange.meta.id
  doc.revNextId = nextId
  var fieldDepth = 0 # complex fields span paragraphs: balance doc-globally
  var fieldUnknown = false # unknown boundary kinds defeat balance checks
  proc markCb(r: Run) =
    case r.fldChar
    of fckBegin: inc fieldDepth
    of fckEnd:
      dec fieldDepth
      if fieldDepth < 0 and not fieldUnknown:
        failDoc("field end without matching begin")
    of fckUnknown: fieldUnknown = true
    of fckNone, fckSeparate: discard
  proc paraCb(p: var Paragraph) =
    if p.numId != -1 and p.numId notin defIds:
      failDoc("paragraph uses numId " & $p.numId &
        " with no numbering definition")
    for k in p.kids:
      if k.kind == pkRun: markCb(k.run)
      elif k.kind == pkFldSimple:
        for r in k.fld.runs: markCb(r)
      else:
        for r in k.rev.runs: markCb(r)
  proc blkCb(blocks: var seq[Block]) = eachParaInBlocks(blocks, paraCb)
  eachContainer(doc, blkCb)
  if fieldDepth != 0 and not fieldUnknown:
    failDoc("unbalanced field boundaries (" & $fieldDepth &
      " unclosed begin)")
  var imageIds: seq[string]
  for im in doc.images:
    if im.relId == "":
      failDoc("image (" & im.contentType & ", " &
        $im.data.len & " bytes) has no rel id")
    if im.relId in imageIds:
      failDoc("duplicate image rel id " & im.relId)
    imageIds.add im.relId
  for rid, target in doc.hyperlinks:
    if rid == "": failDoc("hyperlink target '" & target & "' has no rel id")
    if target == "": failDoc("hyperlink " & rid & " has no target")
    if rid in imageIds:
      failDoc("rel id " & rid & " is both image and hyperlink")
  var seen: seq[string]
  let hypers = doc.hyperlinks # local snapshot: closures cannot capture
  var footIds, endIds, commentIds: seq[int] # note targets for ref repair
  for n in doc.footnotes: footIds.add n.id
  for n in doc.endnotes: endIds.add n.id
  for c in doc.comments: commentIds.add c.id
  proc runCb(r: var Run) =    # the var param `doc` while it is borrowed
    if r.hyperlinkRid != "" and r.hyperlinkRid notin hypers:
      failDoc("run references unknown hyperlink " & r.hyperlinkRid)
    if r.text != "" and r.delText != "":
      failDoc("run mixes w:t text with w:delText")
    # dangling note references are unrepresentable (Word/LO refuse to
    # load them): drop against the existing note ids.
    if r.footnoteRef != -1 and r.footnoteRef notin footIds:
      r.footnoteRef = -1
    if r.endnoteRef != -1 and r.endnoteRef notin endIds:
      r.endnoteRef = -1
    if r.commentRef != -1 and r.commentRef notin commentIds:
      r.commentRef = -1
    if r.drawingRid != "":
      if r.drawingRid notin imageIds:
        failDoc("run references unknown image " & r.drawingRid)
      if r.drawingRid in seen: return
      seen.add r.drawingRid
  proc blkCb2(blocks: var seq[Block]) = eachRunInBlocks(blocks, runCb)
  eachContainer(doc, blkCb2)
  for s in doc.sections:
    for rf in s.headerRefs:
      if rf.relId == "": failDoc("header reference has no rel id")
      if rf.relId in imageIds or rf.relId in doc.hyperlinks:
        failDoc("header rel id " & rf.relId & " reused across kinds")
    for rf in s.footerRefs:
      if rf.relId == "": failDoc("footer reference has no rel id")
      if rf.relId in imageIds or rf.relId in doc.hyperlinks:
        failDoc("footer rel id " & rf.relId & " reused across kinds")
  for n in doc.footnotes:
    if n.id == -1 or n.id == 0:
      failDoc("footnote id " & $n.id & " is reserved for separators")
  for n in doc.endnotes:
    if n.id == -1 or n.id == 0:
      failDoc("endnote id " & $n.id & " is reserved for separators")

# ------------------------------------------------------------- part writers

proc writeHdrFtrXml(doc: DocxDocument, isHeader: bool,
    blocks: seq[Block]): string =
  var e = XmlEmit()
  e.decl()
  var ro: seq[Block] = blocks
  var drawId = 0
  e.open(if isHeader: "w:hdr" else: "w:ftr", WNs)
  e.writeBlocks(ro, doc, drawId)
  e.close(if isHeader: "w:hdr" else: "w:ftr")
  e.buf

proc writeSeparator(e: var XmlEmit, tag: string, id: int,
    sepKind, sepElem: string) =
  e.open(tag, attr("w:type", sepKind) & attr("w:id", $id))
  e.open("w:p")
  e.open("w:r")
  e.empty(sepElem)
  e.close("w:r")
  e.close("w:p")
  e.close(tag)

proc writeNotesXml(doc: DocxDocument, endnotes: bool): string =
  ## footnotes.xml / endnotes.xml with Word-convention separators
  ## (id -1/-0) ahead of content notes.
  var e = XmlEmit()
  e.decl()
  var drawId = 0
  let notes = if endnotes: doc.endnotes else: doc.footnotes
  if endnotes:
    e.open("w:endnotes", WNs)
    if notes.len > 0:
      e.writeSeparator("w:endnote", -1, "separator", "w:separator")
      e.writeSeparator("w:endnote", 0, "continuationSeparator",
        "w:continuationSeparator")
    for n in notes:
      e.open("w:endnote", attr("w:id", $n.id))
      var ro: seq[Block] = n.blocks
      e.writeBlocks(ro, doc, drawId)
      e.close("w:endnote")
    e.close("w:endnotes")
  else:
    e.open("w:footnotes", WNs)
    if notes.len > 0:
      e.writeSeparator("w:footnote", -1, "separator", "w:separator")
      e.writeSeparator("w:footnote", 0, "continuationSeparator",
        "w:continuationSeparator")
    for n in notes:
      e.open("w:footnote", attr("w:id", $n.id))
      var ro: seq[Block] = n.blocks
      e.writeBlocks(ro, doc, drawId)
      e.close("w:footnote")
    e.close("w:footnotes")
  e.buf

## Word's empty Modern-Comments shell (verbatim bytes).
const CommentsExtendedShell* =
  """<w15:commentsEx xmlns:wpc="http://schemas.microsoft.com/office/word/2010/wordprocessingCanvas" xmlns:cx="http://schemas.microsoft.com/office/drawing/2014/chartex" xmlns:cx1="http://schemas.microsoft.com/office/drawing/2015/9/8/chartex" xmlns:cx2="http://schemas.microsoft.com/office/drawing/2015/10/21/chartex" xmlns:cx3="http://schemas.microsoft.com/office/drawing/2016/5/9/chartex" xmlns:cx4="http://schemas.microsoft.com/office/drawing/2016/5/10/chartex" xmlns:cx5="http://schemas.microsoft.com/office/drawing/2016/5/11/chartex" xmlns:cx6="http://schemas.microsoft.com/office/drawing/2016/5/12/chartex" xmlns:cx7="http://schemas.microsoft.com/office/drawing/2016/5/13/chartex" xmlns:cx8="http://schemas.microsoft.com/office/drawing/2016/5/14/chartex" xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" xmlns:aink="http://schemas.microsoft.com/office/drawing/2016/ink" xmlns:am3d="http://schemas.microsoft.com/office/drawing/2017/model3d" xmlns:o="urn:schemas-microsoft-com:office:office" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:m="http://schemas.openxmlformats.org/officeDocument/2006/math" xmlns:v="urn:schemas-microsoft-com:vml" xmlns:wp14="http://schemas.microsoft.com/office/word/2010/wordprocessingDrawing" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:w10="urn:schemas-microsoft-com:office:word" xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:w14="http://schemas.microsoft.com/office/word/2010/wordml" xmlns:w15="http://schemas.microsoft.com/office/word/2012/wordml" xmlns:w16cex="http://schemas.microsoft.com/office/word/2018/wordml/cex" xmlns:w16cid="http://schemas.microsoft.com/office/word/2016/wordml/cid" xmlns:w16="http://schemas.microsoft.com/office/word/2018/wordml" xmlns:w16se="http://schemas.microsoft.com/office/word/2015/wordml/symex" xmlns:wpg="http://schemas.microsoft.com/office/word/2010/wordprocessingGroup" xmlns:wpi="http://schemas.microsoft.com/office/word/2010/wordprocessingInk" xmlns:wne="http://schemas.microsoft.com/office/word/2006/wordml" xmlns:wps="http://schemas.microsoft.com/office/word/2010" />"""

proc writeCommentsXml(doc: DocxDocument): string =
  var e = XmlEmit()
  e.decl()
  var drawId = 0
  e.open("w:comments", WNs)
  for c in doc.comments:
    e.open("w:comment", attr("w:id", $c.id) &
      optAttr("w:author", c.author) & optAttr("w:date", c.date) &
      optAttr("w:initials", c.initials))
    var ro: seq[Block] = c.blocks
    e.writeBlocks(ro, doc, drawId)
    e.close("w:comment")
  e.close("w:comments")
  e.buf

proc writeCommentsExtendedXml(): string =
  ## Word's empty Modern-Comments shell, byte-verbatim from Word output
  ## (no XML declaration, single self-closing `w15:commentsEx`).
  CommentsExtendedShell

const OfficePalette = [
  ("dk1", "000000"), ("lt1", "FFFFFF"), ("dk2", "44546A"),
  ("lt2", "E7E6E6"), ("accent1", "4472C4"), ("accent2", "ED7D31"),
  ("accent3", "A5A5A5"), ("accent4", "FFC000"), ("accent5", "5B9BD5"),
  ("accent6", "70AD47"), ("hlink", "0563C1"), ("folHlink", "954F72")]

proc writeThemeXml(doc: DocxDocument): string =
  ## Minimal theme carrying the modeled accent colors (missing slots
  ## fall back to the Office palette); explicit run colors always win.
  var e = XmlEmit()
  e.decl()
  e.open("a:theme",
    attr("xmlns:a", "http://schemas.openxmlformats.org/drawingml/2006/main") &
    attr("name", "Office Theme"))
  e.open("a:themeElements")
  e.open("a:clrScheme", attr("name", "Office"))
  for (slot, dflt) in OfficePalette:
    let rgb = doc.themeColors.getOrDefault(slot, dflt)
    e.open("a:" & slot)
    e.empty("a:srgbClr", attr("val", rgb))
    e.close("a:" & slot)
  e.close("a:clrScheme")
  e.open("a:fmtScheme", attr("name", "Office"))
  for lst in ["a:fillStyleLst", "a:lnStyleLst", "a:effectStyleLst",
      "a:bgFillStyleLst"]:
    e.open(lst)
    e.open("a:solidFill")
    e.empty("a:schemeClr", attr("val", "phClr"))
    e.close("a:solidFill")
    e.close(lst)
  e.close("a:fmtScheme")
  e.open("a:fontScheme", attr("name", "Office"))
  for kind in ["a:majorFont", "a:minorFont"]:
    e.open(kind)
    e.empty("a:latin", attr("typeface", "Calibri Light"))
    e.empty("a:ea", attr("typeface", ""))
    e.empty("a:cs", attr("typeface", ""))
    e.close(kind)
  e.close("a:fontScheme")
  e.close("a:themeElements")
  e.close("a:theme")
  e.buf

proc writeCoreXml(doc: DocxDocument): string =
  var e = XmlEmit()
  e.decl()
  e.open("cp:coreProperties",
    attr("xmlns:cp", "http://schemas.openxmlformats.org/package/2006/metadata/core-properties") &
    attr("xmlns:dc", "http://purl.org/dc/elements/1.1/") &
    attr("xmlns:dcterms", "http://purl.org/dc/terms/") &
    attr("xmlns:xsi", "http://www.w3.org/2001/XMLSchema-instance"))
  if doc.coreProps.title != "": e.elem("dc:title", doc.coreProps.title)
  if doc.coreProps.author != "": e.elem("dc:creator", doc.coreProps.author)
  if doc.coreProps.created != "":
    e.elem("dcterms:created", doc.coreProps.created,
      attr("xsi:type", "dcterms:W3CDTF"))
  if doc.coreProps.modified != "":
    e.elem("dcterms:modified", doc.coreProps.modified,
      attr("xsi:type", "dcterms:W3CDTF"))
  e.close("cp:coreProperties")
  e.buf

proc writeAppXml(doc: DocxDocument): string =
  var e = XmlEmit()
  e.decl()
  e.open("Properties",
    attr("xmlns", "http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"))
  e.elem("Application", doc.appProps.application)
  if doc.appProps.templateName != "":
    e.elem("Template", doc.appProps.templateName)
  if doc.appProps.pages != 0: e.elem("Pages", $doc.appProps.pages)
  if doc.appProps.words != 0: e.elem("Words", $doc.appProps.words)
  if doc.appProps.characters != 0:
    e.elem("Characters", $doc.appProps.characters)
  if doc.appProps.paragraphs != 0:
    e.elem("Paragraphs", $doc.appProps.paragraphs)
  e.close("Properties")
  e.buf

proc writeCustomXml(doc: DocxDocument): string =
  ## Custom props by stored type (integers keep width, bools stay bools;
  ## unknown vt:* tags pass through verbatim).
  var e = XmlEmit()
  e.decl()
  e.open("Properties",
    attr("xmlns", "http://schemas.openxmlformats.org/officeDocument/2006/custom-properties") &
    attr("xmlns:vt", "http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"))
  var pid = 2
  for p in doc.customProps:
    e.open("property", attr("fmtid", "{D5CDD505-2E9C-101B-9397-08002B2CF9AE}") &
      attr("pid", $pid) & attr("name", p.name))
    case p.value.kind
    of cvkString: e.elem("vt:lpwstr", p.value.str)
    of cvkInt:
      if p.value.num >= low(int32).int64 and
          p.value.num <= high(int32).int64:
        e.elem("vt:i4", $p.value.num)
      else:
        e.elem("vt:i8", $p.value.num)
    of cvkBool: e.elem("vt:bool", if p.value.b: "true" else: "false")
    of cvkFloat: e.elem("vt:r8", $p.value.f)
    of cvkDate: e.elem("vt:filetime", p.value.iso)
    of cvkRaw: e.elem("vt:" & p.value.tag, p.value.text)
    e.close("property")
    inc pid
  e.close("Properties")
  e.buf

proc writeSettingsXml(): string =
  var e = XmlEmit()
  e.decl()
  e.open("w:settings", WNs)
  e.close("w:settings")
  e.buf

proc writeFontTableXml(): string =
  ## Fixed Times/Symbol/Arial skeleton (same as Word defaults).
  var e = XmlEmit()
  e.decl()
  e.open("w:fonts", WNs)
  for (name, charset, family) in [
      ("Times New Roman", "00", "roman"), ("Symbol", "02", "roman"),
      ("Arial", "00", "swiss")]:
    e.open("w:font", attr("w:name", name))
    e.empty("w:charset", attr("w:val", charset))
    e.empty("w:family", attr("w:val", family))
    e.empty("w:pitch", attr("w:val", "variable"))
    e.close("w:font")
  e.close("w:fonts")
  e.buf

# ------------------------------------------------------------------ assembly

proc linkTarget(doc: DocxDocument, rid: string): tuple[target: string,
    external: bool] =
  let t = doc.hyperlinks[rid]
  (t, "://" in t)

proc buildPackage*(doc: DocxDocument): seq[tuple[name, content: string]] =
  ## Assemble the full `.docx` part set (name → bytes) from the model.
  ## Works on a copy: validates, rebuilds the flat flow, normalizes
  ## rel-ids on collision. Raw-part merge and zipping are the caller's
  ## job (see `writeDocxBytes`).
  var d = doc
  d.validateDoc()
  for s in d.sections:
    for rf in s.headerRefs:
      var found = false
      for h in s.headers:
        if h.refKind == rf.refKind: found = true
      if not found:
        failDoc("header reference '" & rf.refKind & "' (" & rf.relId &
          ") has no header part")
    for rf in s.footerRefs:
      var found = false
      for f in s.footers:
        if f.refKind == rf.refKind: found = true
      if not found:
        failDoc("footer reference '" & rf.refKind & "' (" & rf.relId &
          ") has no footer part")

  # header/footer part names in encounter order, deduplicated by rel-id
  # and kept clear of raw-part names.
  var hdrNames, ftrNames: Table[string, string]
  var hdrBlocks, ftrBlocks: Table[string, seq[Block]]
  var hn, fn = 1
  for s in d.sections:
    for rf in s.headerRefs:
      if rf.relId notin hdrNames:
        while "word/header" & $hn & ".xml" in d.rawParts: inc hn
        hdrNames[rf.relId] = "word/header" & $hn & ".xml"
        inc hn
      for h in s.headers:
        if h.refKind == rf.refKind:
          hdrBlocks[hdrNames[rf.relId]] = h.blocks
    for rf in s.footerRefs:
      if rf.relId notin ftrNames:
        while "word/footer" & $fn & ".xml" in d.rawParts: inc fn
        ftrNames[rf.relId] = "word/footer" & $fn & ".xml"
        inc fn
      for f in s.footers:
        if f.refKind == rf.refKind:
          ftrBlocks[ftrNames[rf.relId]] = f.blocks

  # media names, likewise collision-free.
  var mediaNames: Table[string, string]
  var mediaExts: seq[string]
  var mn = 1
  for im in d.images:
    let ext = extForContentType(im.contentType)
    while "word/media/image" & $mn & "." & ext in d.rawParts: inc mn
    mediaNames[im.relId] = "word/media/image" & $mn & "." & ext
    mediaExts.add ext
    inc mn

  # document rels: fixed ids for structural parts (yielding to model
  # rids on collision); model rids pass through for content references.
  var contentRids: seq[string]
  for s in d.sections:
    for rf in s.headerRefs: contentRids.add rf.relId
    for rf in s.footerRefs: contentRids.add rf.relId
  for im in d.images: contentRids.add im.relId
  for rid in d.hyperlinks.keys: contentRids.add rid
  var rels: seq[RelEntry]
  var usedIds: seq[string]
  proc takeId(want: string): string =
    if want notin usedIds and want notin contentRids:
      usedIds.add want
      return want
    var k = 100
    while "rId" & $k in usedIds or "rId" & $k in contentRids: inc k
    usedIds.add "rId" & $k
    "rId" & $k
  rels.add (takeId("rId1"), docRel("styles"), "styles.xml", false)
  rels.add (takeId("rId2"), docRel("fontTable"), "fontTable.xml", false)
  rels.add (takeId("rId3"), docRel("settings"), "settings.xml", false)
  let hasCustom = d.customProps.len > 0 or
    "docProps/custom.xml" in d.rawParts
  if hasCustom:
    rels.add (takeId("rId4"), docRel("customProperties"), "../docProps/custom.xml", false)
  let hasNumbering = d.numberingDefs.len > 0 or
    "word/numbering.xml" in d.rawParts
  let hasComments = d.comments.len > 0 or "word/comments.xml" in d.rawParts
  # Modern-Comments shell: Word writes it even with zero comments, so it
  # precedes numbering/comments in the fixed-id order (Word: rId5).
  let hasCommentsEx = hasComments or
    "word/commentsExtended.xml" in d.rawParts
  if hasCommentsEx:
    rels.add (takeId("rId5"),
      "http://schemas.microsoft.com/office/2011/relationships/commentsExtended",
      "commentsExtended.xml", false)
  if hasNumbering:
    rels.add (takeId("rId5"), docRel("numbering"), "numbering.xml", false)
  if hasComments:
    rels.add (takeId("rId6"), docRel("comments"), "comments.xml", false)
  let hasFootnotes = d.footnotes.len > 0 or
    "word/footnotes.xml" in d.rawParts
  if hasFootnotes:
    rels.add (takeId("rId7"), docRel("footnotes"), "footnotes.xml", false)
  let hasEndnotes = d.endnotes.len > 0 or
    "word/endnotes.xml" in d.rawParts
  if hasEndnotes:
    rels.add (takeId("rId8"), docRel("endnotes"), "endnotes.xml", false)
  let hasTheme = d.themeColors.len > 0 or
    "word/theme/theme1.xml" in d.rawParts
  if hasTheme:
    rels.add (takeId("rId9"), docRel("theme"), "theme/theme1.xml", false)
  for relId, part in hdrNames:
    rels.add (relId, docRel("header"), part[5 .. ^1], false)
  for relId, part in ftrNames:
    rels.add (relId, docRel("footer"), part[5 .. ^1], false)
  for im in d.images:
    rels.add (im.relId, docRel("image"), mediaNames[im.relId][5 .. ^1], false)
  for rid in d.hyperlinks.keys:
    let (target, external) = d.linkTarget(rid)
    rels.add (rid, docRel("hyperlink"), target, external)

  # per-part rels for headers/footers/notes/comments (spec: r:id
  # resolves against the containing part's rels).
  proc partRelsFor(blocks: var seq[Block]): seq[RelEntry] =
    var rids = initTable[string, bool]()
    collectRids(blocks, rids)
    for rid in rids.keys:
      if rid in d.hyperlinks:
        let (target, external) = d.linkTarget(rid)
        result.add (rid, docRel("hyperlink"), target, external)
      else:
        for im in d.images:
          if im.relId == rid:
            result.add (rid, docRel("image"),
              "../" & mediaNames[rid], false)
  var partRels: Table[string, seq[RelEntry]]
  for part, blocks in hdrBlocks.mpairs:
    let es = partRelsFor(blocks)
    if es.len > 0: partRels["word/_rels/" & part[5 .. ^1] & ".rels"] = es
  for part, blocks in ftrBlocks.mpairs:
    let es = partRelsFor(blocks)
    if es.len > 0: partRels["word/_rels/" & part[5 .. ^1] & ".rels"] = es
  if hasFootnotes:
    var all: seq[Block]
    for n in d.footnotes.mitems: all.add n.blocks
    let es = partRelsFor(all)
    if es.len > 0: partRels["word/_rels/footnotes.xml.rels"] = es
  if hasEndnotes:
    var all: seq[Block]
    for n in d.endnotes.mitems: all.add n.blocks
    let es = partRelsFor(all)
    if es.len > 0: partRels["word/_rels/endnotes.xml.rels"] = es
  if hasComments:
    var all: seq[Block]
    for c in d.comments.mitems: all.add c.blocks
    let es = partRelsFor(all)
    if es.len > 0: partRels["word/_rels/comments.xml.rels"] = es

  # emit everything.
  result.add ("[Content_Types].xml", "") # placeholder, filled below
  result.add ("_rels/.rels", writeRelsXml(@[
    ("rId1", PkgRelNs & "/core-properties", "docProps/core.xml", false),
    ("rId2", PkgRelNs & "/extended-properties", "docProps/app.xml", false),
    ("rId3", DocRelNs & "/officeDocument",
      "word/document.xml", false)] &
    (if hasCustom: @[("rId4", PkgRelNs & "/custom-properties",
      "docProps/custom.xml", false)] else: @[])))
  result.add ("docProps/core.xml", writeCoreXml(d))
  result.add ("docProps/app.xml", writeAppXml(d))
  if hasCustom: result.add ("docProps/custom.xml", writeCustomXml(d))
  result.add ("word/document.xml", writeDocumentXml(d))
  result.add ("word/styles.xml", writeStylesXml(d))
  if hasNumbering and (d.numberingDefs.len > 0 or
      "word/numbering.xml" notin d.rawParts):
    result.add ("word/numbering.xml", writeNumberingXml(d))
  if "word/settings.xml" notin d.rawParts:
    result.add ("word/settings.xml", writeSettingsXml())
  if "word/fontTable.xml" notin d.rawParts:
    result.add ("word/fontTable.xml", writeFontTableXml())
  if hasComments and (d.comments.len > 0 or
      "word/comments.xml" notin d.rawParts):
    result.add ("word/comments.xml", writeCommentsXml(d))
  if hasCommentsEx and "word/commentsExtended.xml" notin d.rawParts:
    # Word's empty Modern-Comments shell (verbatim); a raw part from the
    # source package wins via the merge.
    result.add ("word/commentsExtended.xml", writeCommentsExtendedXml())
  if hasFootnotes and (d.footnotes.len > 0 or
      "word/footnotes.xml" notin d.rawParts):
    result.add ("word/footnotes.xml", writeNotesXml(d, false))
  if hasEndnotes and (d.endnotes.len > 0 or
      "word/endnotes.xml" notin d.rawParts):
    result.add ("word/endnotes.xml", writeNotesXml(d, true))
  if d.themeColors.len > 0:
    result.add ("word/theme/theme1.xml", writeThemeXml(d))
  for part in hdrNames.values:
    result.add (part, writeHdrFtrXml(d, true, hdrBlocks[part]))
  for part in ftrNames.values:
    result.add (part, writeHdrFtrXml(d, false, ftrBlocks[part]))
  for im in d.images:
    var s = newString(im.data.len)
    if im.data.len > 0:
      copyMem(addr s[0], unsafeAddr im.data[0], im.data.len)
    result.add (mediaNames[im.relId], s)
  result.add ("word/_rels/document.xml.rels", writeRelsXml(rels))
  for name, es in partRels: result.add (name, writeRelsXml(es))

  var names: seq[string]
  for (name, _) in result: names.add name
  for name in d.rawParts.keys:
    names.add name # merge preserves these
    if name.startsWith("word/media/"): # raw media needs its Default too
      let dot = name.rfind('.')
      if dot >= 0: mediaExts.add name[dot + 1 .. ^1].toLowerAscii()
  result[0] = ("[Content_Types].xml",
    writeContentTypesXml(names, mediaExts))
