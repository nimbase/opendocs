## Word `.docx` (OOXML WordprocessingML) reader.
##
## XML via `openparser/xml` DOM (`fromXml`), always with `xpStrict`.
## Packages via `opendocs/zip`. Unknown whole parts are preserved
## byte-exact in `rawParts`; unknown inline elements are skipped.

import std/[strutils, tables, os, tempfiles, memfiles]
import openparser/xml
import opendocs/zip
# NOTE: include-part of `opendocs/docx` (see docx.nim). Model types come
# from the `docx/types` include above this file; keep no imports of it
# here so every symbol keeps one canonical home in module `docx`.

const
  MaxXmlDepth = 64 ## nesting cap against hostile documents

let strictXmlOpts = XmlOptions(policy: xpStrict)

# ------------------------------------------------------------------ xml utils

proc parsePartXml(data: seq[byte], partName: string): XmlNode =
  ## Strict-parse one package part in place (borrowed buffer, no copy).
  ## Safe: the DOM owns its strings; `data` need only outlive the call.
  if data.len == 0:
    raise newException(DocxError, "empty XML part: " & partName)
  try:
    fromXml(cast[pointer](unsafeAddr data[0]), data.len, strictXmlOpts)
  except OpenParserXmlError as e:
    raise newException(DocxError, "bad XML in " & partName & ": " & e.msg)

func childElems(n: XmlNode, tag: string): seq[XmlNode] =
  if n != nil and n.kind == xnElement:
    for c in n.children:
      if c.kind == xnElement and c.tag == tag:
        result.add c

func firstChild(n: XmlNode, tag: string): XmlNode =
  for c in childElems(n, tag): return c
  nil

func optAttr(n: XmlNode, name: string): string =
  ## Nil-safe attribute read.
  if n == nil or n.kind != xnElement: "" else: n.getAttr(name)

func childText(n: XmlNode): string =
  ## Concatenated direct text/cdata children.
  if n != nil and n.kind == xnElement:
    for c in n.children:
      if c.kind == xnText: result.add c.text
      elif c.kind == xnCdata: result.add c.cdata

func intAttr(n: XmlNode, name: string, dflt: int): int =
  if n == nil or n.kind != xnElement: return dflt
  let v = n.getAttr(name)
  if v == "": return dflt
  try: parseInt(v)
  except ValueError: dflt

proc readEdge(n: XmlNode, tag: string): BorderEdge =
  let e = firstChild(n, tag)
  if e == nil: return
  BorderEdge(style: e.getAttr("w:val"),
    sizeEighths: intAttr(e, "w:sz", 0), space: intAttr(e, "w:space", 0),
    color: e.getAttr("w:color"))

proc readBorders(n: XmlNode): Borders =
  ## Nil-safe: nil node yields empty borders.
  if n == nil: return
  Borders(top: readEdge(n, "w:top"), left: readEdge(n, "w:left"),
    bottom: readEdge(n, "w:bottom"), right: readEdge(n, "w:right"),
    insideH: readEdge(n, "w:insideH"), insideV: readEdge(n, "w:insideV"))

# ------------------------------------------------------------------ run/para

func onOff(n: XmlNode): bool =
  ## OOXML on/off semantics: present without val, or val != "false"/"0".
  if n == nil or n.kind != xnElement: return false
  n.getAttr("w:val") notin ["false", "0", "off", "none"]

func findBlipRid(n: XmlNode, depth = 0): string =
  ## Deepest-first search for `a:blip r:embed` (drawing image reference).
  if n == nil or n.kind != xnElement or depth > MaxXmlDepth: return ""
  if n.tag == "a:blip":
    let rid = n.getAttr("r:embed")
    if rid != "": return rid
  for c in n.children:
    if c.kind == xnElement:
      let rid = findBlipRid(c, depth + 1)
      if rid != "": return rid
  ""

func findTxbx(n: XmlNode, depth = 0): XmlNode =
  ## First descendant `w:txbxContent` (covers wps: and v: textbox paths).
  if n == nil or n.kind != xnElement or depth > MaxXmlDepth: return nil
  if n.tag == "w:txbxContent": return n
  for c in n.children:
    if c.kind == xnElement:
      let hit = findTxbx(c, depth + 1)
      if hit != nil: return hit
  nil

func findExtent(n: XmlNode, depth = 0): tuple[cx, cy: int] =
  ## First descendant `wp:extent` (textbox shape size for rendering).
  if n == nil or n.kind != xnElement or depth > MaxXmlDepth: return (0, 0)
  if n.tag == "wp:extent":
    return (intAttr(n, "cx", 0), intAttr(n, "cy", 0))
  for c in n.children:
    if c.kind == xnElement:
      let hit = findExtent(c, depth + 1)
      if hit != (0, 0): return hit
  (0, 0)

proc readDrawing(dNode: XmlNode,
    drawings: var Table[string, Drawing]): string =
  ## Parse `w:drawing` geometry into the drawings table; returns image rid.
  let box = block:
    var b = firstChild(dNode, "wp:inline")
    if b == nil: b = firstChild(dNode, "wp:anchor")
    b
  if box == nil: return findBlipRid(dNode) # unknown shape: rid only
  let rid = findBlipRid(box)
  if rid == "": return ""
  let ext = firstChild(box, "wp:extent")
  let docPr = firstChild(box, "wp:docPr")
  drawings[rid] = Drawing(relId: rid,
    placement: if box.tag == "wp:anchor": dpAnchor else: dpInline,
    cxEmu: intAttr(ext, "cx", 0), cyEmu: intAttr(ext, "cy", 0),
    name: optAttr(docPr, "name"), descr: optAttr(docPr, "descr"),
    behindDoc: box.getAttr("behindDoc") notin ["", "0", "false"],
    posHFrom: optAttr(firstChild(box, "wp:positionH"), "relativeFrom"),
    posVFrom: optAttr(firstChild(box, "wp:positionV"), "relativeFrom"))
  rid

proc addMarks(n: XmlNode, marks: var seq[Bookmark]) =
  for m in childElems(n, "w:bookmarkStart"):
    marks.add Bookmark(id: intAttr(m, "w:id", -1), name: m.getAttr("w:name"))

proc readParagraph(pNode: XmlNode, depth: int = 0,
  drawings: var Table[string, Drawing],
  textboxes: var seq[Textbox]): Paragraph
  ## Forward: runs surface textbox content.

func readRevMeta(n: XmlNode): RevisionMeta =
  ## Shared `w:id`/`w:author`/`w:date` on revision wrappers.
  RevisionMeta(id: n.getAttr("w:id"), author: n.getAttr("w:author"),
    date: n.getAttr("w:date"))

func innerXml(n: XmlNode): string =
  ## Verbatim serialization of element children (change-content passthrough).
  if n != nil and n.kind == xnElement:
    for c in n.children:
      if c.kind == xnElement: result.add toXml(c)

func readPropChange(n: XmlNode): PropChange =
  ## `*PrChange` wrapper: meta parsed, inner XML kept verbatim.
  PropChange(meta: readRevMeta(n), rawInner: innerXml(n))

func rangeMarkerKind(tag: string): tuple[ok: bool, kind: RangeMarkerKind] =
  ## Move/customXml range-marker tags (w:bookmarkStart/End stay bookmarks).
  case tag
  of "w:moveFromRangeStart": (true, rmkMoveFromStart)
  of "w:moveFromRangeEnd": (true, rmkMoveFromEnd)
  of "w:moveToRangeStart": (true, rmkMoveToStart)
  of "w:moveToRangeEnd": (true, rmkMoveToEnd)
  of "w:customXmlInsRangeStart", "w:customXmlInsRangeEnd",
      "w:customXmlDelRangeStart", "w:customXmlDelRangeEnd",
      "w:customXmlMoveFromRangeStart", "w:customXmlMoveFromRangeEnd",
      "w:customXmlMoveToRangeStart", "w:customXmlMoveToRangeEnd":
    (true, rmkCustomXml)
  else: (false, rmkMoveFromStart)

proc parseRunProps(rPr: XmlNode, result: var Run) =
  ## Fill run formatting from a `w:rPr` node (nil-safe). Shared by runs
  ## and character-style definitions.
  if rPr == nil: return
  result.bold = onOff(firstChild(rPr, "w:b"))
  result.italic = onOff(firstChild(rPr, "w:i"))
  result.underline = onOff(firstChild(rPr, "w:u"))
  result.strike = onOff(firstChild(rPr, "w:strike"))
  result.dstrike = onOff(firstChild(rPr, "w:dstrike"))
  result.sizeHalfPts = intAttr(firstChild(rPr, "w:sz"), "w:val", 0)
  let color = firstChild(rPr, "w:color")
  if color != nil:
    if color.getAttr("w:val") notin ["", "auto"]:
      result.color = color.getAttr("w:val")
    result.colorTheme = color.getAttr("w:themeColor")
    result.colorShade = color.getAttr("w:themeShade")
    result.colorTint = color.getAttr("w:themeTint")
  let fonts = firstChild(rPr, "w:rFonts")
  if fonts != nil:
    result.fonts = fonts.getAttr("w:ascii")
    result.fontsEastAsia = fonts.getAttr("w:eastAsia")
    result.fontsHAnsi = fonts.getAttr("w:hAnsi")
  result.lang = optAttr(firstChild(rPr, "w:lang"), "w:val")
  result.highlight = optAttr(firstChild(rPr, "w:highlight"), "w:val")
  result.styleId = optAttr(firstChild(rPr, "w:rStyle"), "w:val")
  result.vertAlign = optAttr(firstChild(rPr, "w:vertAlign"), "w:val")
  result.spacingTwips = intAttr(firstChild(rPr, "w:spacing"), "w:val", 0)
  result.positionPts = intAttr(firstChild(rPr, "w:position"), "w:val", 0)
  result.kernHalfPts = intAttr(firstChild(rPr, "w:kern"), "w:val", 0)
  result.shading = optAttr(firstChild(rPr, "w:shd"), "w:fill")
  result.caps = onOff(firstChild(rPr, "w:caps"))
  result.smallCaps = onOff(firstChild(rPr, "w:smallCaps"))
  result.vanish = onOff(firstChild(rPr, "w:vanish")) or
    onOff(firstChild(rPr, "w:webHidden"))
  result.webHidden = onOff(firstChild(rPr, "w:webHidden"))
  result.outline = onOff(firstChild(rPr, "w:outline"))
  result.shadow = onOff(firstChild(rPr, "w:shadow"))
  result.emboss = onOff(firstChild(rPr, "w:emboss"))
  result.imprint = onOff(firstChild(rPr, "w:imprint"))
  result.noProof = firstChild(rPr, "w:noProof") != nil
  result.fitText = firstChild(rPr, "w:fitText") != nil
  result.boldCs = onOff(firstChild(rPr, "w:bCs"))
  result.italicCs = onOff(firstChild(rPr, "w:iCs"))
  result.sizeCsHalfPts = intAttr(firstChild(rPr, "w:szCs"), "w:val", 0)
  let rIns = firstChild(rPr, "w:ins")
  if rIns != nil:
    result.rIns = readRevMeta(rIns)
    result.hasRIns = true
  let rDel = firstChild(rPr, "w:del")
  if rDel != nil:
    result.rDel = readRevMeta(rDel)
    result.hasRDel = true
  let rCh = firstChild(rPr, "w:rPrChange")
  if rCh != nil:
    result.rPrChange = readPropChange(rCh)
    result.hasRPrChange = true

func splitInstr(s: string): seq[string] =
  ## Whitespace split honoring double quotes (quotes stripped).
  var cur = ""
  var inQ = false
  var had = false
  for ch in s:
    if ch == '"': inQ = not inQ; had = true
    elif ch in {' ', '\t', '\r', '\n'} and not inQ:
      if had: result.add cur; cur = ""; had = false
    else: cur.add ch; had = true
  if had: result.add cur

func parseSwitches(parts: openArray[string]): seq[InstrSwitch] =
  ## `\flag [arg]` tokens; a bare flag takes no arg, anything else skips.
  var i = 0
  while i < parts.len:
    let p = parts[i]
    if p.len > 1 and p[0] == '\\':
      if i + 1 < parts.len and
          not (parts[i + 1].len > 1 and parts[i + 1][0] == '\\'):
        result.add InstrSwitch(flag: p[1 .. ^1], arg: parts[i + 1],
          hasArg: true)
        inc i, 2
      else:
        result.add InstrSwitch(flag: p[1 .. ^1], arg: "", hasArg: false)
        inc i
    else: inc i

func parseInstr*(raw: string): FieldInstr =
  ## Typed view of a field instruction (`w:instrText` content).
  ## Unknown instructions stay verbatim under `fikUnsupported`.
  let parts = splitInstr(raw.strip())
  if parts.len == 0: return FieldInstr(kind: fikUnsupported, raw: raw)
  case parts[0]
  of "TOC":
    let rest = if parts.len > 1: parts[1 .. ^1] else: @[]
    FieldInstr(kind: fikToc, toc: TocInstr(switches: parseSwitches(rest)))
  of "TC":
    var tc = TcInstr(level: -1)
    var rest = if parts.len > 1: parts[1 .. ^1] else: @[]
    if rest.len > 0 and not rest[0].startsWith("\\"):
      tc.text = rest[0]
      rest = if rest.len > 1: rest[1 .. ^1] else: @[]
    for sw in parseSwitches(rest):
      case sw.flag
      of "f": tc.itemId = sw.arg
      of "l":
        try: tc.level = parseInt(sw.arg)
        except ValueError: discard
      of "n": tc.omitsPageNum = true
      else: discard
    FieldInstr(kind: fikTc, tc: tc)
  of "PAGE":
    if parts.len == 1: FieldInstr(kind: fikPage)
    else: FieldInstr(kind: fikUnsupported, raw: raw)
  of "NUMPAGES":
    if parts.len == 1: FieldInstr(kind: fikNumPages)
    else: FieldInstr(kind: fikUnsupported, raw: raw)
  of "PAGEREF":
    var pr = PageRefInstr()
    if parts.len > 1: pr.bookmark = parts[1]
    for i in 2 ..< parts.len:
      case parts[i]
      of "\\h": pr.hyperlink = true
      of "\\p": pr.relPos = true
      else: discard
    FieldInstr(kind: fikPageRef, pageRef: pr)
  of "HYPERLINK":
    var h = HyperlinkInstr()
    if parts.len > 1: h.target = parts[1]
    for i in 2 ..< parts.len:
      if parts[i] == "\\l": h.anchor = true
    FieldInstr(kind: fikHyperlink, hyperlink: h)
  else: FieldInstr(kind: fikUnsupported, raw: raw)

proc readRun(rNode: XmlNode, hyperlinkRid = "",
    drawings: var Table[string, Drawing],
    textboxes: var seq[Textbox]): Run =
  result = Run(hyperlinkRid: hyperlinkRid, footnoteRef: -1, endnoteRef: -1,
    commentRef: -1, rsidR: rNode.getAttr("w:rsidR"))
  parseRunProps(firstChild(rNode, "w:rPr"), result)
  for c in rNode.children:
    if c.kind != xnElement: continue
    case c.tag
    of "w:t": result.text.add childText(c)
    of "w:delText": result.delText.add childText(c)
    of "w:instrText", "w:delInstrText":
      # instruction text lives on the run; cached result follows separate.
      result.instrRaw.add childText(c)
      result.instr = parseInstr(result.instrRaw)
      if c.tag == "w:delInstrText": result.delInstr = true
    of "w:fldChar":
      case c.getAttr("w:fldCharType")
      of "begin": result.fldChar = fckBegin
      of "separate": result.fldChar = fckSeparate
      of "end": result.fldChar = fckEnd
      else:
        result.fldChar = fckUnknown
        result.fldCharRaw = c.getAttr("w:fldCharType")
      let d = c.getAttr("w:dirty")
      result.fldDirty = d notin ["", "false", "0", "off"]
    of "w:fldLock": result.fldLock = true
    of "w:tab": result.text.add "\t"
    of "w:br":
      case c.getAttr("w:type")
      of "page": result.text.add "\f"
      else: result.text.add "\n" # column, textWrapping
    of "w:cr": result.text.add "\n"
    of "w:noBreakHyphen": result.text.add "\u00A0"
    of "w:sym":
      # font symbol: font+code populate the run, text stays untouched so
      # flatText never mixes glyphs with content.
      if result.symChar == "":
        result.symFont = c.getAttr("w:font")
        result.symChar = c.getAttr("w:char")
    of "w:ins": # nested insertion: include text
      for rc in childElems(c, "w:r"):
        result.text.add readRun(rc, "", drawings, textboxes).text
    of "w:del", "w:moveFrom": discard # nested deletion: excluded
    of "w:drawing":
      let rid = readDrawing(c, drawings)
      if rid != "": result.drawingRid = rid
      let tx = findTxbx(c) # textbox content travels as trailing blocks
      if tx != nil:
        let (tcx, tcy) = findExtent(c)
        var tb = Textbox(cxEmu: tcx, cyEmu: tcy)
        for p in childElems(tx, "w:p"):
          tb.blocks.add Block(kind: bkParagraph,
            paragraph: readParagraph(p, 0, drawings, textboxes))
        textboxes.add tb
    of "mc:AlternateContent": # prefer Choice, ignore VML Fallback
      let choice = firstChild(c, "mc:Choice")
      if choice != nil:
        for cc in choice.children:
          if cc.kind != xnElement: continue
          if cc.tag == "w:drawing":
            let rid = readDrawing(cc, drawings)
            if rid != "" and result.drawingRid == "":
              result.drawingRid = rid
            let tx = findTxbx(cc)
            if tx != nil:
              let (tcx, tcy) = findExtent(cc)
              var tb = Textbox(cxEmu: tcx, cyEmu: tcy)
              for p in childElems(tx, "w:p"):
                tb.blocks.add Block(kind: bkParagraph,
                  paragraph: readParagraph(p, 0, drawings, textboxes))
              textboxes.add tb
          # nested runs inside Choice are unusual; ignored (noted)
    of "w:footnoteReference":
      result.footnoteRef = intAttr(c, "w:id", -1)
    of "w:endnoteReference":
      result.endnoteRef = intAttr(c, "w:id", -1)
    of "w:commentReference":
      result.commentRef = intAttr(c, "w:id", -1)
    else: discard

proc parseParaProps(pPr: XmlNode, result: var Paragraph) =
  ## Fill paragraph formatting from a `w:pPr` node (nil-safe). Shared
  ## by paragraphs and paragraph-style definitions. Section breaks
  ## (`w:sectPr`) are handled by the caller, not here.
  if pPr == nil: return
  result.styleId = optAttr(firstChild(pPr, "w:pStyle"), "w:val")
  result.align = optAttr(firstChild(pPr, "w:jc"), "w:val")
  let numPr = firstChild(pPr, "w:numPr")
  if numPr != nil:
    result.numId = intAttr(firstChild(numPr, "w:numId"), "w:val", -1)
    result.numIlvl = intAttr(firstChild(numPr, "w:ilvl"), "w:val", 0)
    let numCh = firstChild(numPr, "w:numPrChange")
    if numCh != nil:
      result.numPrChange = readPropChange(numCh)
      result.hasNumPrChange = true
  let ind = firstChild(pPr, "w:ind")
  if ind != nil:
    result.indentLeft = intAttr(ind, "w:left", -1)
    result.indentFirstLine = intAttr(ind, "w:firstLine", -1)
  let sp = firstChild(pPr, "w:spacing")
  if sp != nil:
    result.spacingBefore = intAttr(sp, "w:before", -1)
    result.spacingAfter = intAttr(sp, "w:after", -1)
  result.outlineLvl = intAttr(firstChild(pPr, "w:outlineLvl"), "w:val", -1)
  result.keepNext = firstChild(pPr, "w:keepNext") != nil
  result.keepLines = firstChild(pPr, "w:keepLines") != nil
  result.pageBreakBefore = firstChild(pPr, "w:pageBreakBefore") != nil
  result.widowControl = firstChild(pPr, "w:widowControl") != nil
  result.shading = optAttr(firstChild(pPr, "w:shd"), "w:fill")
  result.bidi = onOff(firstChild(pPr, "w:bidi"))
  result.textAlignment = optAttr(firstChild(pPr, "w:textAlignment"), "w:val")
  let tabs = firstChild(pPr, "w:tabs")
  if tabs != nil:
    for t in childElems(tabs, "w:tab"):
      result.tabs.add TabStop(kind: t.getAttr("w:val"),
        pos: intAttr(t, "w:pos", 0))
  result.borders = readBorders(firstChild(pPr, "w:pBdr"))
  let pIns = firstChild(pPr, "w:ins")
  if pIns != nil:
    result.pPrIns = readRevMeta(pIns)
    result.hasPPrIns = true
  let pDel = firstChild(pPr, "w:del")
  if pDel != nil:
    result.pPrDel = readRevMeta(pDel)
    result.hasPPrDel = true
  let pCh = firstChild(pPr, "w:pPrChange")
  if pCh != nil:
    var pc = ParaChange(meta: readRevMeta(pCh))
    let inner = firstChild(pCh, "w:pPr")
    if inner != nil:
      var ppr = new(Paragraph)
      ppr[] = Paragraph(numId: -1, indentLeft: -1, indentFirstLine: -1,
        spacingBefore: -1, spacingAfter: -1, outlineLvl: -1)
      parseParaProps(inner, ppr[])
      pc.ppr = ppr
    result.pPrChange = pc
    result.hasPPrChange = true
  result.rsidP = pPr.getAttr("w:rsidP")
  result.rsidRPr = pPr.getAttr("w:rsidRPr")
  result.rsidDel = pPr.getAttr("w:rsidDel")

proc readFldSimple(c: XmlNode,
    drawings: var Table[string, Drawing],
    textboxes: var seq[Textbox]): FldSimple =
  let raw = c.getAttr("w:instr")
  result = FldSimple(instrRaw: raw, instr: parseInstr(raw))
  for rc in childElems(c, "w:r"):
    result.runs.add readRun(rc, "", drawings, textboxes)

proc readRevRuns(parent: XmlNode, result: var Paragraph,
    drawings: var Table[string, Drawing],
    textboxes: var seq[Textbox]) =
  ## Paragraph children: runs, simple fields, revision wrappers,
  ## range markers. Deleted/move-source text stays wrapped (accept-view
  ## text comes from `flatText`, not the reader).
  for c in parent.children:
    if c.kind != xnElement: continue
    case c.tag
    of "w:r": result.kids.add pkRun(readRun(c, "", drawings, textboxes))
    of "w:fldSimple":
      result.kids.add ParaKid(kind: pkFldSimple,
        fld: readFldSimple(c, drawings, textboxes))
    of "w:hyperlink":
      addMarks(c, result.bookmarks)
      let rid = c.getAttr("r:id")
      for rc in childElems(c, "w:r"):
        result.kids.add pkRun(readRun(rc, rid, drawings, textboxes))
    of "w:ins", "w:del", "w:moveFrom", "w:moveTo":
      var rev = RevRun(meta: readRevMeta(c))
      addMarks(c, result.bookmarks)
      for rc in c.children:
        if rc.kind != xnElement: continue
        case rc.tag
        of "w:r": rev.runs.add readRun(rc, "", drawings, textboxes)
        of "w:hyperlink":
          let rid = rc.getAttr("r:id")
          for rrc in childElems(rc, "w:r"):
            rev.runs.add readRun(rrc, rid, drawings, textboxes)
        of "w:del":
          # ins>del>r nesting: splice inner runs into the wrapper
          if c.tag in ["w:ins", "w:moveTo"]:
            for rrc in childElems(rc, "w:r"):
              rev.runs.add readRun(rrc, "", drawings, textboxes)
          # else: del/moveFrom members stay runs-only; dropped with note
        of "w:moveFrom": discard # ghost text never flattens
        else: discard
      case c.tag
      of "w:ins": result.kids.add ParaKid(kind: pkIns, rev: rev)
      of "w:del": result.kids.add ParaKid(kind: pkDel, rev: rev)
      of "w:moveFrom": result.kids.add ParaKid(kind: pkMoveFrom, rev: rev)
      else: result.kids.add ParaKid(kind: pkMoveTo, rev: rev)
    of "w:moveFromRangeStart", "w:moveFromRangeEnd", "w:moveToRangeStart",
        "w:moveToRangeEnd", "w:customXmlInsRangeStart",
        "w:customXmlInsRangeEnd", "w:customXmlDelRangeStart",
        "w:customXmlDelRangeEnd", "w:customXmlMoveFromRangeStart",
        "w:customXmlMoveFromRangeEnd", "w:customXmlMoveToRangeStart",
        "w:customXmlMoveToRangeEnd":
      let (ok, kind) = rangeMarkerKind(c.tag)
      if ok:
        result.rangeMarkers.add RangeMarker(kind: kind, tag: c.tag,
          name: c.getAttr("w:name"), id: c.getAttr("w:id"),
          uri: c.getAttr("w:uri"), element: c.getAttr("w:element"))
    else: discard # bookmarkEnd, proofErr, perms, bare customXml…

proc readParagraph(pNode: XmlNode, depth: int = 0,
    drawings: var Table[string, Drawing],
    textboxes: var seq[Textbox]): Paragraph =
  result = Paragraph(numId: -1, indentLeft: -1, indentFirstLine: -1,
    spacingBefore: -1, spacingAfter: -1, outlineLvl: -1,
    rsidR: pNode.getAttr("w:rsidR"))
  parseParaProps(firstChild(pNode, "w:pPr"), result)
  addMarks(pNode, result.bookmarks)
  readRevRuns(pNode, result, drawings, textboxes)

proc readWrappedBlocks(c: XmlNode,
    drawings: var Table[string, Drawing],
    textboxes: var seq[Textbox]): seq[Block]
  ## Forward: blocks inside a body/cell-level `w:ins`/`w:del`.

proc readTable(tblNode: XmlNode, depth: int = 0,
  drawings: var Table[string, Drawing],
  textboxes: var seq[Textbox]): DocxTable
  ## Forward: cells recurse into nested tables.

proc readCellBlocks(tcNode: XmlNode, depth: int,
    drawings: var Table[string, Drawing],
    textboxes: var seq[Textbox]): seq[Block] =
  if depth > MaxXmlDepth:
    raise newException(DocxError, "table nesting too deep")
  for c in tcNode.children:
    if c.kind != xnElement: continue
    case c.tag
    of "w:p":
      result.add Block(kind: bkParagraph,
        paragraph: readParagraph(c, depth, drawings, textboxes))
      for tb in textboxes:
        result.add Block(kind: bkTextbox, textbox: tb)
      textboxes.setLen(0)
    of "w:tbl":
      result.add Block(kind: bkTable,
        table: readTable(c, depth + 1, drawings, textboxes))
    of "w:ins", "w:del":
      let rb = RevBlock(meta: readRevMeta(c),
        blocks: readWrappedBlocks(c, drawings, textboxes))
      if c.tag == "w:ins":
        result.add Block(kind: bkIns, rev: rb)
      else:
        result.add Block(kind: bkDel, rev: rb)
    else: discard

proc readTable(tblNode: XmlNode, depth = 0,
    drawings: var Table[string, Drawing],
    textboxes: var seq[Textbox]): DocxTable =
  if depth > MaxXmlDepth:
    raise newException(DocxError, "table nesting too deep")
  result = DocxTable(width: -1, cellSpacing: -1)
  let tblPr = firstChild(tblNode, "w:tblPr")
  if tblPr != nil:
    result.styleId = optAttr(firstChild(tblPr, "w:tblStyle"), "w:val")
    let tw = firstChild(tblPr, "w:tblW")
    if tw != nil:
      result.width = intAttr(tw, "w:w", -1)
      result.widthType = tw.getAttr("w:type")
    result.align = optAttr(firstChild(tblPr, "w:jc"), "w:val")
    result.look = optAttr(firstChild(tblPr, "w:tblLook"), "w:val")
    result.borders = readBorders(firstChild(tblPr, "w:tblBorders"))
    result.shading = optAttr(firstChild(tblPr, "w:shd"), "w:fill")
    let cs = firstChild(tblPr, "w:tblCellSpacing")
    if cs != nil:
      result.cellSpacing = intAttr(cs, "w:w", -1)
      result.cellSpacingType = cs.getAttr("w:type")
    result.layout = optAttr(firstChild(tblPr, "w:tblLayout"), "w:type")
    let tblCh = firstChild(tblPr, "w:tblPrChange")
    if tblCh != nil:
      result.tblPrChange = readPropChange(tblCh)
      result.hasTblPrChange = true
  let grid = firstChild(tblNode, "w:tblGrid")
  if grid != nil:
    for gc in childElems(grid, "w:gridCol"):
      result.grid.add intAttr(gc, "w:w", 0)
    let gridCh = firstChild(grid, "w:tblGridChange")
    if gridCh != nil:
      result.tblGridChange = readPropChange(gridCh)
      result.hasTblGridChange = true
  for tr in childElems(tblNode, "w:tr"):
    var row: TableRow
    let trPr = firstChild(tr, "w:trPr")
    if trPr != nil:
      let h = firstChild(trPr, "w:trHeight")
      if h != nil:
        row.height = intAttr(h, "w:val", 0)
        row.heightRule = h.getAttr("w:hRule")
      row.isHeader = firstChild(trPr, "w:tblHeader") != nil
      row.cantSplit = firstChild(trPr, "w:cantSplit") != nil
      let trIns = firstChild(trPr, "w:ins")
      if trIns != nil:
        row.trIns = readRevMeta(trIns)
        row.hasTrIns = true
      let trDel = firstChild(trPr, "w:del")
      if trDel != nil:
        row.trDel = readRevMeta(trDel)
        row.hasTrDel = true
      let trCh = firstChild(trPr, "w:trPrChange")
      if trCh != nil:
        row.trPrChange = readPropChange(trCh)
        row.hasTrPrChange = true
    for tc in childElems(tr, "w:tc"):
      var cell = TableCell(gridSpan: 1, width: -1)
      let tcPr = firstChild(tc, "w:tcPr")
      if tcPr != nil:
        cell.gridSpan = max(1,
          intAttr(firstChild(tcPr, "w:gridSpan"), "w:val", 1))
        let vm = firstChild(tcPr, "w:vMerge")
        cell.vMerge = if vm == nil: "" elif vm.getAttr("w:val") == "restart": "restart" else: "continue"
        cell.shading = optAttr(firstChild(tcPr, "w:shd"), "w:fill")
        let cw = firstChild(tcPr, "w:tcW")
        if cw != nil:
          cell.width = intAttr(cw, "w:w", -1)
          cell.widthType = cw.getAttr("w:type")
        cell.vAlign = optAttr(firstChild(tcPr, "w:vAlign"), "w:val")
        cell.borders = readBorders(firstChild(tcPr, "w:tcBorders"))
        let cellIns = firstChild(tcPr, "w:cellIns")
        if cellIns != nil:
          cell.tcIns = readRevMeta(cellIns)
          cell.hasTcIns = true
        let cellDel = firstChild(tcPr, "w:cellDel")
        if cellDel != nil:
          cell.tcDel = readRevMeta(cellDel)
          cell.hasTcDel = true
        let cellMerge = firstChild(tcPr, "w:cellMerge")
        if cellMerge != nil:
          cell.tcMerge = readRevMeta(cellMerge)
          cell.hasTcMerge = true
        let tcCh = firstChild(tcPr, "w:tcPrChange")
        if tcCh != nil:
          cell.tcPrChange = readPropChange(tcCh)
          cell.hasTcPrChange = true
      cell.blocks = readCellBlocks(tc, depth, drawings, textboxes)
      row.cells.add cell
    result.rows.add row

# ------------------------------------------------- styles/numbering/rels

proc readStyles(root: XmlNode): Table[string, StyleInfo] =
  if root.tag != "w:styles":
    raise newException(DocxError,
      "word/styles.xml root is <" & root.tag & ">, want <w:styles>")
  for s in childElems(root, "w:style"):
    let id = s.getAttr("w:styleId")
    if id == "": continue
    var info = StyleInfo(name: optAttr(firstChild(s, "w:name"), "w:val"),
      kind: s.getAttr("w:type"),
      basedOn: optAttr(firstChild(s, "w:basedOn"), "w:val"),
      next: optAttr(firstChild(s, "w:next"), "w:val"),
      link: optAttr(firstChild(s, "w:link"), "w:val"),
      qFormat: firstChild(s, "w:qFormat") != nil,
      isDefault: s.getAttr("w:default") notin ["", "0", "false"],
      custom: s.getAttr("w:customStyle") notin ["", "0", "false"])
    let pPr = firstChild(s, "w:pPr")
    if pPr != nil:
      info.pPr = Paragraph(numId: -1, indentLeft: -1, indentFirstLine: -1,
        spacingBefore: -1, spacingAfter: -1, outlineLvl: -1)
      parseParaProps(pPr, info.pPr)
      info.hasPPr = true
    let rPr = firstChild(s, "w:rPr")
    if rPr != nil:
      parseRunProps(rPr, info.rPr)
      info.hasRPr = true
    let tblPr = firstChild(s, "w:tblPr")
    if tblPr != nil:
      # table-style details (tblStylePr banding etc.) pass through
      # verbatim; only the wrapper is regenerated on write.
      var raw = ""
      for c in tblPr.children:
        if c.kind == xnElement: raw.add toXml(c)
      info.tblPrRaw = raw
    result[id] = info

proc readThemeColors(root: XmlNode): Table[string, string] =
  ## `a:clrScheme` children (lt1/accent1/…) to RRGGBB. Prefers srgbClr,
  ## falls back to sysClr lastClr.
  if root.tag != "a:theme":
    raise newException(DocxError,
      "word/theme/theme1.xml root is <" & root.tag & ">, want <a:theme>")
  let elems = firstChild(root, "a:themeElements")
  let scheme = firstChild(elems, "a:clrScheme")
  if scheme == nil: return
  for c in scheme.children:
    if c.kind != xnElement: continue
    let name = c.tag.split(':')[^1]
    var rgb = optAttr(firstChild(c, "a:srgbClr"), "val")
    if rgb == "":
      rgb = optAttr(firstChild(c, "a:sysClr"), "lastClr")
    if rgb != "": result[name] = rgb

proc readNumLevel(lvl: XmlNode, ilvlDflt: int): NumberingLevel =
  result = NumberingLevel(
    ilvl: intAttr(lvl, "w:ilvl", ilvlDflt),
    format: optAttr(firstChild(lvl, "w:numFmt"), "w:val"),
    text: optAttr(firstChild(lvl, "w:lvlText"), "w:val"),
    start: intAttr(firstChild(lvl, "w:start"), "w:val", 1),
    suffix: optAttr(firstChild(lvl, "w:suff"), "w:val"),
    justification: optAttr(firstChild(lvl, "w:lvlJc"), "w:val"),
    indentLeft: -1, indentHanging: -1, indentRight: -1,
    indentFirstLine: -1, indentLeftChars: -1, indentHangingChars: -1,
    indentFirstLineChars: -1, lvlRestart: -1,
    legacyVal: -1, legacySpace: -1, legacyIndent: -1)
  let pPr = firstChild(lvl, "w:pPr")
  if pPr != nil:
    result.pPrJc = optAttr(firstChild(pPr, "w:jc"), "w:val")
    let tabs = firstChild(pPr, "w:tabs")
    if tabs != nil:
      for t in childElems(tabs, "w:tab"):
        result.tabs.add TabStop(kind: t.getAttr("w:val"),
          pos: intAttr(t, "w:pos", 0))
    let ind = firstChild(pPr, "w:ind")
    if ind != nil:
      result.indentLeft = intAttr(ind, "w:left", -1)
      result.indentHanging = intAttr(ind, "w:hanging", -1)
      result.indentRight = intAttr(ind, "w:right", -1)
      result.indentFirstLine = intAttr(ind, "w:firstLine", -1)
      result.indentLeftChars = intAttr(ind, "w:leftChars", -1)
      result.indentHangingChars = intAttr(ind, "w:hangingChars", -1)
      result.indentFirstLineChars = intAttr(ind, "w:firstLineChars", -1)
    # NOTE: w:pPr/w:rPr inside levels is not modeled (empty in practice).
  let rPr = firstChild(lvl, "w:rPr")
  if rPr != nil:
    parseRunProps(rPr, result.lvlRPr)
    result.hasLvlRPr = true
  result.pStyle = optAttr(firstChild(lvl, "w:pStyle"), "w:val")
  result.lvlRestart = intAttr(firstChild(lvl, "w:lvlRestart"), "w:val", -1)
  result.isLgl = firstChild(lvl, "w:isLgl") != nil
  let legacy = firstChild(lvl, "w:legacy")
  if legacy != nil:
    result.legacyVal = intAttr(legacy, "w:legacy", -1)
    result.legacySpace = intAttr(legacy, "w:space", -1)
    result.legacyIndent = intAttr(legacy, "w:legacyIndent", -1)

proc readNumbering(root: XmlNode): tuple[
    collapsed: Table[int, seq[NumberingLevel]],
    defs: seq[NumberingDef]] =
  if root.tag != "w:numbering":
    raise newException(DocxError,
      "word/numbering.xml root is <" & root.tag & ">, want <w:numbering>")
  result.collapsed = initTable[int, seq[NumberingLevel]]()
  var abstracts: Table[int, seq[NumberingLevel]]
  for a in childElems(root, "w:abstractNum"):
    let id = intAttr(a, "w:abstractNumId", -1)
    if id < 0: continue
    var levels: seq[NumberingLevel]
    for lvl in childElems(a, "w:lvl"):
      levels.add readNumLevel(lvl, 0)
    abstracts[id] = levels
  for n in childElems(root, "w:num"):
    let numId = intAttr(n, "w:numId", -1)
    let absId = intAttr(firstChild(n, "w:abstractNumId"), "w:val", -1)
    if numId < 0 or not abstracts.hasKey(absId): continue
    var levels = abstracts[absId]
    var def = NumberingDef(numId: numId, abstractId: absId,
      levels: levels)
    for ov in childElems(n, "w:lvlOverride"):
      let ilvl = intAttr(ov, "w:ilvl", -1)
      if ilvl < 0 or ilvl >= levels.len: continue
      let repl = firstChild(ov, "w:lvl") # full level replacement
      if repl != nil:
        var nl = readNumLevel(repl, ilvl)
        if firstChild(repl, "w:start") == nil:
          nl.start = levels[ilvl].start # replacement without start keeps it
        levels[ilvl] = nl
        def.overrides.add NumOverride(ilvl: ilvl, hasLevel: true,
          level: nl, startOverride: -1)
      else:
        let so = intAttr(firstChild(ov, "w:startOverride"), "w:val", -1)
        if so >= 0: levels[ilvl].start = so
        def.overrides.add NumOverride(ilvl: ilvl, startOverride: so)
    result.collapsed[numId] = levels
    result.defs.add def

proc readDocRels(root: XmlNode): Table[string, tuple[relType, target: string]] =
  if root.tag != "Relationships":
    raise newException(DocxError,
      "document.xml.rels root is <" & root.tag & ">, want <Relationships>")
  for r in childElems(root, "Relationship"):
    let id = r.getAttr("Id")
    if id == "": continue
    result[id] = (r.getAttr("Type"), r.getAttr("Target"))

proc readContentTypes(
    root: XmlNode): tuple[over: Table[string, string],
                          byExt: Table[string, string]] =
  if root.tag != "Types":
    raise newException(DocxError,
      "[Content_Types].xml root is <" & root.tag & ">, want <Types>")
  for c in root.children:
    if c.kind != xnElement: continue
    case c.tag
    of "Override":
      var part = c.getAttr("PartName")
      if part.startsWith("/"): part = part[1 .. ^1]
      result.over[part] = c.getAttr("ContentType")
    of "Default":
      result.byExt[c.getAttr("Extension").toLowerAscii()] =
        c.getAttr("ContentType")
    else: discard

func resolveDocTarget(target: string): string =
  ## `word/`-relative rel target to package part name. External URLs and
  ## absolute paths pass through (leading `/` stripped).
  if "://" in target: return target
  if target.startsWith("/"): return target[1 .. ^1]
  "word/" & target

func contentTypeFor(part: string,
    over, byExt: Table[string, string]): string =
  if over.hasKey(part): return over[part]
  let dot = part.rfind('.')
  if dot >= 0:
    return byExt.getOrDefault(part[dot + 1 .. ^1].toLowerAscii(),
      "application/octet-stream")
  "application/octet-stream"

proc drainBoxes(dst: var seq[Block], textboxes: var seq[Textbox]) =
  for tb in textboxes:
    dst.add Block(kind: bkTextbox, textbox: tb)
  textboxes.setLen(0)

proc readBlocks(parent: XmlNode,
    drawings: var Table[string, Drawing],
    textboxes: var seq[Textbox]): seq[Block] =
  ## Shared block reader for body-adjacent containers (hdr/ftr/notes).
  if parent == nil or parent.kind != xnElement: return
  for c in parent.children:
    if c.kind != xnElement: continue
    case c.tag
    of "w:p":
      result.add Block(kind: bkParagraph,
        paragraph: readParagraph(c, 0, drawings, textboxes))
      drainBoxes(result, textboxes)
    of "w:tbl":
      result.add Block(kind: bkTable,
        table: readTable(c, 0, drawings, textboxes))
    of "w:ins", "w:del":
      let rb = RevBlock(meta: readRevMeta(c),
        blocks: readWrappedBlocks(c, drawings, textboxes))
      if c.tag == "w:ins":
        result.add Block(kind: bkIns, rev: rb)
      else:
        result.add Block(kind: bkDel, rev: rb)
    else: discard

proc readSdtInner(c: XmlNode,
    drawings: var Table[string, Drawing],
    textboxes: var seq[Textbox]): Sdt =
  ## Content control without `sdts` registration (caller owns that).
  let content = block:
    var n = firstChild(c, "w:sdtContent")
    if n == nil: n = c
    n
  var tb: seq[Textbox]
  let inner = readBlocks(content, drawings, tb)
  drainBoxes(result.blocks, tb)
  let pr = firstChild(c, "w:sdtPr")
  result = Sdt(alias: optAttr(firstChild(pr, "w:alias"), "w:val"),
    tag: optAttr(firstChild(pr, "w:tag"), "w:val"), blocks: inner)

proc readWrappedBlocks(c: XmlNode,
    drawings: var Table[string, Drawing],
    textboxes: var seq[Textbox]): seq[Block] =
  ## Blocks inside a body/cell-level `w:ins`/`w:del` (`w:p`, `w:tbl`,
  ## `w:sdt`; a `pPr`-embedded `sectPr` inside is ignored — sections
  ## never live inside revisions).
  for ic in c.children:
    if ic.kind != xnElement: continue
    case ic.tag
    of "w:p":
      result.add Block(kind: bkParagraph,
        paragraph: readParagraph(ic, 0, drawings, textboxes))
    of "w:tbl":
      result.add Block(kind: bkTable,
        table: readTable(ic, 0, drawings, textboxes))
    of "w:sdt":
      result.add Block(kind: bkSdt,
        sdt: readSdtInner(ic, drawings, textboxes))
    else: discard
  drainBoxes(result, textboxes)

proc readHdrFtr(root: XmlNode, wantTag, partName: string,
    drawings: var Table[string, Drawing],
    textboxes: var seq[Textbox]): seq[Block] =
  if root.tag != wantTag:
    raise newException(DocxError, partName & " root is <" & root.tag &
      ">, want <" & wantTag & ">")
  readBlocks(root, drawings, textboxes)

proc readNotes(root: XmlNode, itemTag, wantTag,
    partName: string,    drawings: var Table[string, Drawing],
    textboxes: var seq[Textbox]): seq[Footnote] =
  if root.tag != wantTag:
    raise newException(DocxError, partName & " root is <" & root.tag &
      ">, want <" & wantTag & ">")
  for fn in childElems(root, itemTag):
    if fn.getAttr("w:type") != "":
      continue # separator/continuationSeparator/continuationNotice
    result.add Footnote(id: intAttr(fn, "w:id", -1),
      blocks: readBlocks(fn, drawings, textboxes))

proc readComments(root: XmlNode,
    drawings: var Table[string, Drawing],
    textboxes: var seq[Textbox]): seq[DocComment] =
  if root.tag != "w:comments":
    raise newException(DocxError,
      "word/comments.xml root is <" & root.tag & ">, want <w:comments>")
  for c in childElems(root, "w:comment"):
    result.add DocComment(id: intAttr(c, "w:id", -1),
      author: c.getAttr("w:author"), date: c.getAttr("w:date"),
      initials: c.getAttr("w:initials"),
      blocks: readBlocks(c, drawings, textboxes))

proc readCoreProps(root: XmlNode): CoreProps =
  if root.tag != "cp:coreProperties":
    raise newException(DocxError,
      "docProps/core.xml root is <" & root.tag &
      ">, want <cp:coreProperties>")
  result = CoreProps(title: childText(firstChild(root, "dc:title")),
    author: childText(firstChild(root, "dc:creator")),
    created: childText(firstChild(root, "dcterms:created")),
    modified: childText(firstChild(root, "dcterms:modified")))

func intText(n: XmlNode, dflt: int): int =
  if n == nil: return dflt
  try: parseInt(childText(n).strip())
  except ValueError: dflt

proc readAppProps(root: XmlNode): AppProps =
  if root.tag != "Properties":
    raise newException(DocxError,
      "docProps/app.xml root is <" & root.tag & ">, want <Properties>")
  AppProps(application: childText(firstChild(root, "Application")),
    templateName: childText(firstChild(root, "Template")),
    pages: intText(firstChild(root, "Pages"), 0),
    words: intText(firstChild(root, "Words"), 0),
    characters: intText(firstChild(root, "Characters"), 0),
    paragraphs: intText(firstChild(root, "Paragraphs"), 0))

proc readCustomProps(root: XmlNode): seq[CustomProp] =
  if root.tag != "Properties":
    raise newException(DocxError,
      "docProps/custom.xml root is <" & root.tag & ">, want <Properties>")
  for p in childElems(root, "property"):
    let name = p.getAttr("name")
    if name == "": continue
    var value = customStr("")
    for c in p.children: # first vt:* typed child carries the value
      if c.kind != xnElement: continue
      let tag = c.tag.split(':')[^1].toLowerAscii()
      let text = childText(c)
      value = case tag
        of "lpstr", "lpwstr", "bstr": customStr(text)
        of "i1", "i2", "i4", "i8", "int", "uint", "ui1", "ui2", "ui4",
            "ui8":
          try: customInt(parseBiggestInt(text.strip()))
          except ValueError: CustomValue(kind: cvkRaw, tag: tag, text: text)
        of "bool":
          case text.strip().toLowerAscii()
          of "true", "1": customBool(true)
          of "false", "0": customBool(false)
          else: CustomValue(kind: cvkRaw, tag: tag, text: text)
        of "r4", "r8", "decimal":
          try: customFloat(parseFloat(text.strip()))
          except ValueError: CustomValue(kind: cvkRaw, tag: tag, text: text)
        of "filetime", "date": customDate(text)
        of "empty", "null": customStr("")
        else: CustomValue(kind: cvkRaw, tag: tag, text: text)
      break
    result.add CustomProp(name: name, value: value)

# ------------------------------------------------------------------ document

proc readSectPr(sNode: XmlNode,
    section: var Section) =
  ## Fill section props + header/footer refs from a `w:sectPr` node
  ## (body-final or inside `w:pPr`).
  for rc in childElems(sNode, "w:headerReference"):
    section.headerRefs.add SectionRef(refKind: rc.getAttr("w:type"),
      relId: rc.getAttr("r:id"))
  for rc in childElems(sNode, "w:footerReference"):
    section.footerRefs.add SectionRef(refKind: rc.getAttr("w:type"),
      relId: rc.getAttr("r:id"))
  section.props.sectType = optAttr(firstChild(sNode, "w:type"), "w:val")
  let pgSz = firstChild(sNode, "w:pgSz")
  if pgSz != nil:
    section.props.pgW = intAttr(pgSz, "w:w", 0)
    section.props.pgH = intAttr(pgSz, "w:h", 0)
    section.props.orient = pgSz.getAttr("w:orient")
  let pgMar = firstChild(sNode, "w:pgMar")
  if pgMar != nil:
    section.props.marginTop = intAttr(pgMar, "w:top", 0)
    section.props.marginRight = intAttr(pgMar, "w:right", 0)
    section.props.marginBottom = intAttr(pgMar, "w:bottom", 0)
    section.props.marginLeft = intAttr(pgMar, "w:left", 0)
    section.props.headerDist = intAttr(pgMar, "w:header", 0)
    section.props.footerDist = intAttr(pgMar, "w:footer", 0)
    section.props.gutter = intAttr(pgMar, "w:gutter", 0)
    section.props.mirrorMargins =
      pgMar.getAttr("w:mirrorMargins") notin ["", "0", "false"]
  let cols = firstChild(sNode, "w:cols")
  if cols != nil:
    section.props.colsNum = intAttr(cols, "w:num", 1)
    section.props.colsSpace = intAttr(cols, "w:space", 0)
  section.props.titlePg = firstChild(sNode, "w:titlePg") != nil
  let pgNum = firstChild(sNode, "w:pgNumType")
  if pgNum != nil:
    section.props.pgNumFmt = pgNum.getAttr("w:fmt")
    section.props.pgNumStart = intAttr(pgNum, "w:start", -1)
  section.props.textDirection =
    optAttr(firstChild(sNode, "w:textDirection"), "w:val")
  let grid = firstChild(sNode, "w:docGrid")
  if grid != nil:
    section.props.linePitch = intAttr(grid, "w:linePitch", -1)

proc readBodyChildren(body: XmlNode, doc: var DocxDocument) =
  var textboxes: seq[Textbox]
  var cur = Section(props: SectionProps(pgNumStart: -1, linePitch: -1, colsNum: 1))
  proc pushSection(doc: var DocxDocument, section: Section) =
    var s = section
    doc.sections.add s
    doc.blocks.add s.blocks
  for c in body.children:
    if c.kind != xnElement: continue
    case c.tag
    of "w:p":
      # A pPr-embedded sectPr ends the current section after this paragraph.
      let para = readParagraph(c, 0, doc.drawings, textboxes)
      cur.blocks.add Block(kind: bkParagraph, paragraph: para)
      drainBoxes(cur.blocks, textboxes)
      let pPrSect = firstChild(firstChild(c, "w:pPr"), "w:sectPr")
      if pPrSect != nil:
        readSectPr(pPrSect, cur)
        pushSection(doc, cur)
        cur = Section(props: SectionProps(pgNumStart: -1, linePitch: -1, colsNum: 1))
    of "w:tbl":
      cur.blocks.add Block(kind: bkTable,
        table: readTable(c, 0, doc.drawings, textboxes))
    of "w:sectPr": # body-final section properties
      readSectPr(c, cur)
      pushSection(doc, cur)
      cur = Section(props: SectionProps(pgNumStart: -1, linePitch: -1, colsNum: 1))
    of "w:ins", "w:del": # body-level tracked insertion/deletion
      let rb = RevBlock(meta: readRevMeta(c),
        blocks: readWrappedBlocks(c, doc.drawings, textboxes))
      if c.tag == "w:ins":
        cur.blocks.add Block(kind: bkIns, rev: rb)
      else:
        cur.blocks.add Block(kind: bkDel, rev: rb)
    of "w:sdt": # block-level content control: kept as bkSdt block
      var tb: seq[Textbox]
      let rec = readSdtInner(c, doc.drawings, tb)
      drainBoxes(cur.blocks, tb)
      cur.blocks.add Block(kind: bkSdt, sdt: rec)
      doc.sdts.add rec
    else: discard
  if cur.blocks.len > 0 or doc.sections.len == 0:
    pushSection(doc, cur) # no trailing sectPr: default section

type
  PartReader = object
    ## Uniform part access for both modes. Memory mode reuses one work
    ## buffer; spill mode reads memmapped temp files (page cache, no
    ## userspace copy of part bytes).
    archive: ZipArchive
    work: seq[byte]
    dir: string # "" = memory mode

func spillName(name: string): string =
  ## Temp-file name for a part. The zip-slip guard already vetted `name`
  ## (relative, no `..`), so flattening `/` is sufficient.
  name.replace("/", "__")

proc hasPart(pr: PartReader, name: string): bool =
  if pr.dir == "":
    pr.archive.findEntry(name) >= 0
  else:
    fileExists(pr.dir / spillName(name))

proc readXmlPart(pr: var PartReader, name: string): XmlNode =
  ## Strict-parse a part, nil when absent. Raises DocxError on failure.
  if pr.dir == "":
    if pr.archive.findEntry(name) < 0: return nil
    let idx = pr.archive.findEntry(name)
    try:
      pr.archive.readEntryInto(idx, pr.work)
    except ZipError as e:
      raise newException(DocxError, "cannot extract " & name & ": " & e.msg)
    parsePartXml(pr.work, name)
  else:
    let path = pr.dir / spillName(name)
    if not fileExists(path): return nil
    var mf = memfiles.open(path, fmRead)
    defer: mf.close()
    if mf.size == 0:
      raise newException(DocxError, "empty XML part: " & name)
    try:
      fromXml(mf, strictXmlOpts)
    except OpenParserXmlError as e:
      raise newException(DocxError, "bad XML in " & name & ": " & e.msg)

proc readBytesPart(pr: var PartReader, name: string): seq[byte] =
  ## Owned part bytes. Raises DocxError when missing or unreadable.
  if pr.dir == "":
    let idx = pr.archive.findEntry(name)
    if idx < 0:
      raise newException(DocxError, "missing required part: " & name)
    try:
      result = pr.archive.readEntryByIndex(idx)
    except ZipError as e:
      raise newException(DocxError, "cannot extract " & name & ": " & e.msg)
  else:
    let path = pr.dir / spillName(name)
    var f: File
    if not open(f, path, fmRead):
      raise newException(DocxError, "cannot read spilled part: " & name)
    defer: close(f)
    let size = getFileSize(f).int
    result = newSeq[byte](size)
    if size > 0 and readBytes(f, result, 0, size) != size:
      raise newException(DocxError, "short read: " & name)

proc readLinked(pr: var PartReader,
    docRels: Table[string, tuple[relType, target: string]],
    parts: seq[SectionRef], wantTag: string,
    drawings: var Table[string, Drawing],
    textboxes: var seq[Textbox]): tuple[items: seq[HeaderFooter],
      modeled: seq[string]] =
  ## Resolve sectPr refs through document rels into header/footer blocks.
  for sr in parts:
    if not docRels.hasKey(sr.relId):
      raise newException(DocxError, "section ref not in rels: " & sr.relId)
    let part = resolveDocTarget(docRels[sr.relId].target)
    let node = pr.readXmlPart(part)
    if node == nil:
      raise newException(DocxError,
        "section part missing from package: " & part)
    result.items.add HeaderFooter(refKind: sr.refKind,
      blocks: readHdrFtr(node, wantTag, part, drawings, textboxes))
    result.modeled.add part

proc collectParaBookmarks(p: Paragraph, marks: var seq[Bookmark]) =
  marks.add p.bookmarks

proc collectBlockBookmarks(bs: seq[Block], marks: var seq[Bookmark]) =
  for b in bs:
    case b.kind
    of bkParagraph: collectParaBookmarks(b.paragraph, marks)
    of bkTable:
      for row in b.table.rows:
        for cell in row.cells: collectBlockBookmarks(cell.blocks, marks)
    of bkTextbox:
      collectBlockBookmarks(b.textbox.blocks, marks)
    of bkSdt:
      collectBlockBookmarks(b.sdt.blocks, marks)
    of bkIns, bkDel:
      collectBlockBookmarks(b.rev.blocks, marks)

proc collectBookmarks(doc: DocxDocument): seq[Bookmark] =
  ## Paragraph-level bookmarks aggregated in document order.
  for s in doc.sections:
    collectBlockBookmarks(s.blocks, result)
    for h in s.headers: collectBlockBookmarks(h.blocks, result)
    for f in s.footers: collectBlockBookmarks(f.blocks, result)
  for n in doc.footnotes: collectBlockBookmarks(n.blocks, result)
  for n in doc.endnotes: collectBlockBookmarks(n.blocks, result)
  for c in doc.comments: collectBlockBookmarks(c.blocks, result)

proc readDocxBytes*(data: seq[byte],
    opts: DocxReadOpts = DocxReadOpts()): DocxDocument =
  ## Parse a `.docx` package from memory. `word/document.xml`, styles,
  ## numbering, rels and media are interpreted; every other part lands
  ## in `rawParts` byte-exact.
  ##
  ## When total inflated size exceeds `opts.spillThresholdBytes`, parts
  ## are streamed to temp files and parsed via memory mapping (RSS
  ## containment for huge documents); otherwise everything stays in
  ## memory with one reusable work buffer.
  result = DocxDocument(numbering: initTable[int, seq[NumberingLevel]](),
    styles: initTable[string, StyleInfo](),
    hyperlinks: initTable[string, string](),
    drawings: initTable[string, Drawing](),
    themeColors: initTable[string, string](),
    rawParts: initTable[string, seq[byte]]())
  var archive: ZipArchive
  try:
    archive = openZipBytes(data)
  except ZipError as e:
    raise newException(DocxError, "not a docx package: " & e.msg)

  var pr = PartReader(archive: archive)
  var spillDir = ""
  # NOTE: defer runs at proc scope; it must be registered here, not
  # inside the `if spill` block (which would clean up immediately).
  defer:
    if spillDir != "": removeDir(spillDir)
  var totalInflated = 0
  for e in archive.entries: totalInflated += e.uncompressedSize
  let spill = opts.spillThresholdBytes == 0 or
    (opts.spillThresholdBytes > 0 and
      totalInflated > opts.spillThresholdBytes)
  if spill:
    let base = if opts.spillDir == "": getTempDir() else: opts.spillDir
    try:
      spillDir = createTempDir("opendocs_", "_spill", base)
    except OSError as e:
      raise newException(DocxError, "cannot create spill dir: " & e.msg)
    pr.dir = spillDir
    var remaining =
      if opts.spillCapBytes > 0: opts.spillCapBytes
      else: DefaultSpillCapBytes
    for i, e in archive.entries:
      if e.uncompressedSize > remaining:
        raise newException(DocxError, "spill cap exceeded by: " & e.name)
      try:
        archive.extractEntryToFile(i, spillDir / spillName(e.name))
      except ZipError as e2:
        raise newException(DocxError,
          "cannot spill " & e.name & ": " & e2.msg)
      remaining -= e.uncompressedSize

  let root = pr.readXmlPart("word/document.xml")
  if root == nil:
    raise newException(DocxError, "missing required part: word/document.xml")
  if root.tag != "w:document":
    raise newException(DocxError,
      "word/document.xml root is <" & root.tag & ">, want <w:document>")
  let body = firstChild(root, "w:body")
  if body == nil:
    raise newException(DocxError, "word/document.xml has no w:body")
  readBodyChildren(body, result)

  var modeled = @["word/document.xml"]
  let ctNode = pr.readXmlPart("[Content_Types].xml")
  var over = initTable[string, string]()
  var byExt = initTable[string, string]()
  if ctNode != nil:
    (over, byExt) = readContentTypes(ctNode)
    modeled.add "[Content_Types].xml"

  let stylesNode = pr.readXmlPart("word/styles.xml")
  if stylesNode != nil:
    result.styles = readStyles(stylesNode)
    modeled.add "word/styles.xml"

  let numNode = pr.readXmlPart("word/numbering.xml")
  if numNode != nil:
    let (collapsed, defs) = readNumbering(numNode)
    result.numbering = collapsed
    result.numberingDefs = defs
    modeled.add "word/numbering.xml"

  # Relationships: hyperlinks, images, headers/footers.
  var consumedMedia: seq[string]
  var docRels = initTable[string, tuple[relType, target: string]]()
  let relsNode = pr.readXmlPart("word/_rels/document.xml.rels")
  if relsNode != nil:
    modeled.add "word/_rels/document.xml.rels"
    docRels = readDocRels(relsNode)
    for rid, rel in docRels:
      if rel.relType.endsWith("/hyperlink"):
        result.hyperlinks[rid] = rel.target
      elif rel.relType.endsWith("/image"):
        let part = resolveDocTarget(rel.target)
        if "://" in part:
          continue # external image: no bytes in package
        if not pr.hasPart(part):
          raise newException(DocxError,
            "image target missing from package: " & part)
        result.images.add (rid, contentTypeFor(part, over, byExt),
          pr.readBytesPart(part))
        consumedMedia.add part

  # Headers/footers resolved per section through document rels.
  # Their own part rels (word/_rels/header1.xml.rels) stay in rawParts.
  var linkBoxes: seq[Textbox]
  for i in 0 ..< result.sections.len:
    let (hdrs, hdrModeled) = readLinked(pr, docRels,
      result.sections[i].headerRefs, "w:hdr", result.drawings, linkBoxes)
    result.sections[i].headers = hdrs
    modeled.add hdrModeled
    let (ftrs, ftrModeled) = readLinked(pr, docRels,
      result.sections[i].footerRefs, "w:ftr", result.drawings, linkBoxes)
    result.sections[i].footers = ftrs
    modeled.add ftrModeled

  let fnNode = pr.readXmlPart("word/footnotes.xml")
  if fnNode != nil:
    result.footnotes = readNotes(fnNode, "w:footnote", "w:footnotes",
      "word/footnotes.xml", result.drawings, linkBoxes)
    modeled.add "word/footnotes.xml"

  let enNode = pr.readXmlPart("word/endnotes.xml")
  if enNode != nil:
    result.endnotes = readNotes(enNode, "w:endnote", "w:endnotes",
      "word/endnotes.xml", result.drawings, linkBoxes)
    modeled.add "word/endnotes.xml"

  let cmNode = pr.readXmlPart("word/comments.xml")
  if cmNode != nil:
    result.comments = readComments(cmNode, result.drawings, linkBoxes)
    modeled.add "word/comments.xml"

  let cpNode = pr.readXmlPart("docProps/core.xml")
  if cpNode != nil:
    result.coreProps = readCoreProps(cpNode)
    modeled.add "docProps/core.xml"

  let thNode = pr.readXmlPart("word/theme/theme1.xml")
  if thNode != nil:
    result.themeColors = readThemeColors(thNode)
    modeled.add "word/theme/theme1.xml"

  let appNode = pr.readXmlPart("docProps/app.xml")
  if appNode != nil:
    result.appProps = readAppProps(appNode)
    modeled.add "docProps/app.xml"

  let custNode = pr.readXmlPart("docProps/custom.xml")
  if custNode != nil:
    result.customProps = readCustomProps(custNode)
    modeled.add "docProps/custom.xml"

  result.bookmarks = collectBookmarks(result)

  for e in archive.entries:
    if e.name notin modeled and e.name notin consumedMedia:
      result.rawParts[e.name] = pr.readBytesPart(e.name)

proc readDocx*(path: string, opts: DocxReadOpts = DocxReadOpts()): DocxDocument =
  ## Parse a `.docx` file from disk.
  var f: File
  if not open(f, path, fmRead):
    raise newException(DocxError, "cannot open file: " & path)
  defer: close(f)
  let size = getFileSize(f).int
  var data = newSeq[byte](size)
  if size > 0 and readBytes(f, data, 0, size) != size:
    raise newException(DocxError, "short read: " & path)
  readDocxBytes(data, opts)

