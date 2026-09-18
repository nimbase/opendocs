## Text extraction (ISO 32000 §9.4): positioned runs.
##
## extractText walks a page's content operators with the M3a graphics
## state, decoding each shown string through the font's ToUnicode CMap
## first, then composite fallbacks (Encoding CMap, embedded-font GID
## map, Registry/Ordering tables) or Differences plus the base
## encoding for simple fonts. Positions come from the text rendering
## matrix (font size, scale, rise, Tm, CTM); WMode 1 fonts advance
## downward per DW2/W2 with the position vector applied, and their
## runs are flagged for column grouping. Widths come from the font
## dictionary (/Widths, /DW plus /W); fonts without any widths fall
## back to 500 units with positions best-effort.

import std/tables
import std/unicode
import ./types
import ./lexer
import ./cos
import ./docmodel
import ./filters
import ./cmap
import ./cjkmaps
import ./sfntcmap
import ./gstate

export gstate

type
  FontDecoder* = object
    fontName*: string
    codeLen*: int ## bytes per code (1 simple, 2 composite default)
    cmap*: CMap
    hasCMap*: bool
    diff*: Table[int, int] ## Differences code -> scalar (-1 unknown)
    hasDiff*: bool
    baseWinAnsi*: bool ## false selects MacRoman
    hasBase*: bool
    widths*: Table[int, float64]
    missingWidth*: float64
    composite*: bool
    ordering*: string ## ROS collection from CIDSystemInfo ("" when none)
    hasOrdering*: bool
    encName*: string ## predefined /Encoding CMap ("" when none/Identity)
    hasEncName*: bool
    encCids*: Table[int, int] ## code -> CID from an /Encoding stream
    hasEncCids*: bool
    codes*: seq[CodeRange] ## effective codespaces for splitting
    sfntCmap*: Table[int, int] ## GID -> scalar from the embedded font
    hasSfntCmap*: bool
    cidToGid*: seq[int] ## empty means identity
    wmode*: int ## 0 horizontal, 1 vertical
    dw2vy*: float64 ## DW2 vertical origin (default 880)
    dw2w1*: float64 ## DW2 vertical advance (default -1000)
    w2*: Table[int, array[3, float64]] ## CID -> (w1y, vx, vy)

  TextRun* = object
    text*: string
    x*: float64 ## device-space origin via the rendering matrix
    y*: float64
    size*: float64
    fontName*: string
    w*: float64 ## device-space advance extent (x for horizontal, y for vertical)
    vert*: bool ## true for WMode 1 runs (column fragment, y-descending)

proc decodeCode(fd: FontDecoder, code: int): string =
  if fd.hasCMap and fd.cmap.entries.hasKey(code):
    return fd.cmap.entries[code]
  if fd.hasDiff and fd.diff.hasKey(code):
    let u = fd.diff[code]
    if u >= 0:
      return $Rune(u)
    return "\xEF\xBF\xBD"
  if fd.hasBase:
    let t = if fd.baseWinAnsi: winAnsiTable else: macRomanTable
    if code >= 0 and code < 256 and t[code] >= 0:
      return $Rune(t[code])
    if code >= 32 and code < 127:
      return $chr(code)
    return "\xEF\xBF\xBD"
  # No Encoding and no ToUnicode: the built-in encoding is unknown, so
  # only the ASCII range decodes (shared by all Latin encodings).
  if code >= 32 and code < 127:
    return $chr(code)
  "\xEF\xBF\xBD"

proc decodeCompositeCode(fd: FontDecoder, code: int): string =
  ## Composite chain: ToUnicode, then code to CID (/Encoding stream,
  ## predefined CMap, else Identity), then embedded-font GID map, then
  ## the Registry/Ordering tables. Anything unmapped is U+FFFD.
  if fd.hasCMap and fd.cmap.entries.hasKey(code):
    return fd.cmap.entries[code]
  var cid = code
  if fd.hasEncCids and fd.encCids.hasKey(code):
    cid = fd.encCids[code]
  elif fd.hasEncName:
    let c = codeToCid(fd.encName, code)
    if c >= 0:
      cid = c
  if fd.hasSfntCmap:
    let gid =
      if cid >= 0 and cid < fd.cidToGid.len: fd.cidToGid[cid]
      else: cid
    if fd.sfntCmap.hasKey(gid):
      return $Rune(fd.sfntCmap[gid])
  if fd.hasOrdering:
    let u = cidToUnicode(fd.ordering, cid)
    if u >= 0:
      return $Rune(u)
  if fd.hasEncName:
    let u = codeToUnicode(fd.encName, code)
    if u >= 0:
      return $Rune(u)
  "\xEF\xBF\xBD"

proc codeWidth(fd: FontDecoder, code: int): float64 =
  if fd.widths.hasKey(code):
    return fd.widths[code]
  fd.missingWidth

proc parseW(arr: CosObj, widths: var Table[int, float64]) =
  ## CID /W array in both range forms.
  var i = 0
  while i < arr.items.len:
    let first = arr.items[i].asInt()
    inc i
    if i < arr.items.len and arr.items[i].kind == coArray:
      var code = first
      for w in arr.items[i].items:
        widths[code] = w.asFloat()
        inc code
      inc i
    elif i < arr.items.len:
      let last = arr.items[i].asInt()
      inc i
      if i < arr.items.len:
        let w = arr.items[i].asFloat()
        inc i
        for code in first .. last:
          widths[code] = w

proc parseW2(arr: CosObj, w2: var Table[int, array[3, float64]]) =
  ## CID /W2 array: per-CID (w1y, vx, vy) triples or first/last
  ## ranges sharing one triple.
  var i = 0
  while i < arr.items.len:
    let first = arr.items[i].asInt()
    inc i
    if i < arr.items.len and arr.items[i].kind == coArray:
      var cid = first
      let xs = arr.items[i].items
      inc i
      var j = 0
      while j + 2 < xs.len:
        w2[cid] = [xs[j].asFloat(), xs[j + 1].asFloat(),
          xs[j + 2].asFloat()]
        inc cid
        j += 3
    elif i + 3 <= arr.items.len - 1:
      let last = arr.items[i].asInt()
      let m = [arr.items[i + 1].asFloat(), arr.items[i + 2].asFloat(),
        arr.items[i + 3].asFloat()]
      i += 4
      for cid in first .. last:
        w2[cid] = m
    else:
      break

proc loadDecoder*(d: var PdfDoc, fontRef: CosObj,
    name: string): FontDecoder =
  ## Build the decoder for one font resource (resolved reference).
  var font = fontRef
  if font.kind == coRef:
    font = d.resolve(font)
  if font.kind != coDict:
    pdfFail("font /" & name & " is not a dictionary")
  let subtype = font.dictGet("Subtype")
  let composite = subtype.kind == coName and subtype.name == "Type0"
  result = FontDecoder(fontName: name,
    codeLen: if composite: 2 else: 1,
    diff: initTable[int, int](), widths: initTable[int, float64](),
    encCids: initTable[int, int](), sfntCmap: initTable[int, int](),
    w2: initTable[int, array[3, float64]](),
    missingWidth: 500.0, composite: composite,
    dw2vy: 880.0, dw2w1: -1000.0)
  var uni = font.dictGet("ToUnicode")
  if uni.kind == coRef:
    uni = d.resolve(uni)
  if uni.kind == coStream:
    result.cmap = parseToUnicode(decodeCosStream(uni), d.limits)
    result.hasCMap = true
    if composite:
      result.codeLen = clamp(result.cmap.maxKeyLen, 1, 4)
  var enc = font.dictGet("Encoding")
  if enc.kind == coRef:
    enc = d.resolve(enc)
  if composite and enc.kind == coStream:
    let em = parseCMap(decodeCosStream(enc), d.limits)
    if em.cids.len > 0:
      result.encCids = em.cids
      result.hasEncCids = true
    if em.codes.len > 0:
      result.codes = em.codes
    if not result.hasCMap and em.entries.len > 0:
      result.cmap = em
      result.hasCMap = true
  elif composite and enc.kind == coName:
    if enc.name != "Identity-H" and enc.name != "Identity-V" and
        hasCjkEncoding(enc.name):
      result.encName = enc.name
      result.hasEncName = true
  elif enc.kind == coName:
    if enc.name == "WinAnsiEncoding":
      result.hasBase = true
      result.baseWinAnsi = true
    elif enc.name == "MacRomanEncoding":
      result.hasBase = true
      result.baseWinAnsi = false
  elif enc.kind == coDict:
    let base = enc.dictGet("BaseEncoding")
    if base.kind == coName:
      result.hasBase = true
      result.baseWinAnsi = base.name != "MacRomanEncoding"
    else:
      result.hasBase = true
      result.baseWinAnsi = true
    let diffs = enc.dictGet("Differences")
    if diffs.kind == coArray and diffs.items.len > 0:
      result.hasDiff = true
      var code = 0
      var started = false
      for item in diffs.items:
        if item.kind == coInt:
          code = item.ival
          started = true
        elif started and item.kind == coName:
          result.diff[code] = glyphNameToUnicode(item.name)
          inc code
  let wm = font.dictGet("WMode")
  if composite and wm.kind == coInt:
    result.wmode = wm.ival
  if composite:
    if result.codes.len == 0 and result.hasEncName:
      result.codes = cmapCodespaces(result.encName)
    var descFonts = font.dictGet("DescendantFonts")
    if descFonts.kind == coRef:
      descFonts = d.resolve(descFonts)
    if descFonts.kind == coArray and descFonts.items.len > 0:
      var cid = descFonts.items[0]
      if cid.kind == coRef:
        cid = d.resolve(cid)
      let dw = cid.dictGet("DW")
      if dw.kind == coInt:
        result.missingWidth = dw.asFloat()
      let w = cid.dictGet("W")
      if w.kind == coArray:
        parseW(w, result.widths)
      let dw2 = cid.dictGet("DW2")
      if dw2.kind == coArray and dw2.items.len >= 2:
        result.dw2vy = dw2.items[0].asFloat()
        result.dw2w1 = dw2.items[1].asFloat()
      let w2 = cid.dictGet("W2")
      if w2.kind == coArray:
        parseW2(w2, result.w2)
      var sys = cid.dictGet("CIDSystemInfo")
      if sys.kind == coRef:
        sys = d.resolve(sys)
      if sys.kind == coDict:
        let reg = sys.dictGet("Registry")
        let regName =
          if reg.kind == coStr: reg.sval
          elif reg.kind == coName: reg.name
          else: ""
        let ord = sys.dictGet("Ordering")
        let ordName =
          if ord.kind == coStr: ord.sval
          elif ord.kind == coName: ord.name
          else: ""
        if regName == "Adobe" and hasCjkOrdering(ordName):
          result.ordering = ordName
          result.hasOrdering = true
      var gidMap = cid.dictGet("CIDToGIDMap")
      if gidMap.kind == coRef:
        gidMap = d.resolve(gidMap)
      if gidMap.kind == coStream:
        let raw = decodeCosStream(gidMap)
        var i = 0
        while i + 1 < raw.len:
          result.cidToGid.add(
            int(byte(raw[i])) * 256 + int(byte(raw[i + 1])))
          i += 2
      var desc = cid.dictGet("FontDescriptor")
      if desc.kind == coRef:
        desc = d.resolve(desc)
      if desc.kind == coDict:
        for key in ["FontFile2", "FontFile3"]:
          var f = desc.dictGet(key)
          if f.kind == coRef:
            f = d.resolve(f)
          if f.kind == coStream:
            let cm = parseSfntCmap(decodeCosStream(f))
            if cm.len > 0:
              result.sfntCmap = cm
              result.hasSfntCmap = true
              break
  else:
    let mw = font.dictGet("MissingWidth")
    if mw.kind == coInt:
      result.missingWidth = mw.asFloat()
    let first = font.dictGet("FirstChar")
    let last = font.dictGet("LastChar")
    let arr = font.dictGet("Widths")
    if first.kind == coInt and arr.kind == coArray:
      let n = if last.kind == coInt: last.ival - first.ival + 1
        else: arr.items.len
      for i in 0 ..< min(n, arr.items.len):
        result.widths[first.ival + i] = arr.items[i].asFloat()

proc splitCodes(s: string, codeLen: int): seq[int] =
  var i = 0
  while i < s.len:
    if i + codeLen > s.len:
      pdfFail("truncated multi-byte code in text string")
    var code = 0
    for j in 0 ..< codeLen:
      code = code * 256 + int(byte(s[i + j]))
    result.add(code)
    i += codeLen

proc splitCompositeCodes(s: string, codes: seq[CodeRange],
    defaultLen: int): seq[int] =
  ## Longest match against the codespace ranges; without known ranges
  ## every code is defaultLen bytes (Identity behavior).
  var i = 0
  while i < s.len:
    var matched = false
    for L in countdown(min(4, s.len - i), 1):
      var code = 0
      for j in 0 ..< L:
        code = code * 256 + int(byte(s[i + j]))
      var ok = codes.len == 0 and L == defaultLen
      if not ok:
        for r in codes:
          if r.len == L and code >= r.lo and code <= r.hi:
            ok = true
            break
      if ok:
        result.add(code)
        i += L
        matched = true
        break
    if not matched:
      pdfFail("code outside codespace in composite text string")

proc cidOfCode(fd: FontDecoder, code: int): int =
  ## Code to CID without the Unicode step (for metrics lookup).
  if fd.hasEncCids and fd.encCids.hasKey(code):
    return fd.encCids[code]
  if fd.hasEncName:
    let c = codeToCid(fd.encName, code)
    if c >= 0:
      return c
  code

proc verticalMetric(fd: FontDecoder, cid: int): array[3, float64] =
  ## (w1y, vx, vy): per-CID /W2 override, else (DW2 advance,
  ## half the horizontal width, DW2 origin).
  if fd.w2.hasKey(cid):
    return fd.w2[cid]
  let w0 =
    if fd.widths.hasKey(cid): fd.widths[cid]
    else: fd.missingWidth
  [fd.dw2w1, w0 / 2.0, fd.dw2vy]

proc showTextVertical(gs: var GState, fd: FontDecoder,
    codes: seq[int], text: string, fs: float64,
    runs: var seq[TextRun]) =
  ## WMode 1: Tm advances downward per glyph (horizontal displacement
  ## is always 0); the run origin shifts by the first glyph's position
  ## vector in text space. charSpace and wordSpace apply vertically,
  ## unscaled by Th.
  let th = gs.text.scale / 100.0
  let m0 = fd.verticalMetric(fd.cidOfCode(codes[0]))
  let otm = concatMatrix(
    [1.0, 0.0, 0.0, 1.0, m0[1] * fs / 1000.0, m0[2] * fs / 1000.0],
    gs.textMatrix)
  let trm = concatMatrix([fs * th, 0.0, 0.0, fs, 0.0, gs.text.rise],
    concatMatrix(otm, gs.ctm))
  var advText = 0.0
  for code in codes:
    let decoded = fd.decodeCompositeCode(code)
    let m = fd.verticalMetric(fd.cidOfCode(code))
    var ty = m[0] * fs / 1000.0 + gs.text.charSpace
    if decoded == " ":
      ty += gs.text.wordSpace
    advText += ty
    let t: Matrix = [1.0, 0.0, 0.0, 1.0, 0.0, ty]
    gs.textMatrix = concatMatrix(t, gs.textMatrix)
  var w = 0.0
  if fs != 0.0:
    w = advText * abs(trm[3]) / fs
  runs.add(TextRun(text: text, x: trm[4], y: trm[5], size: fs,
    fontName: fd.fontName, w: w, vert: true))

proc showText(d: var PdfDoc, gs: var GState, fd: FontDecoder,
    s: string, runs: var seq[TextRun]) =
  if s.len == 0:
    return
  let th = gs.text.scale / 100.0
  let fs = gs.text.fontSize
  let trm = concatMatrix([fs * th, 0.0, 0.0, fs, 0.0, gs.text.rise],
    concatMatrix(gs.textMatrix, gs.ctm))
  var text = ""
  var codes: seq[int]
  if fd.composite:
    codes = splitCompositeCodes(s, fd.codes, fd.codeLen)
    for code in codes:
      text.add(fd.decodeCompositeCode(code))
  else:
    codes = splitCodes(s, fd.codeLen)
    for code in codes:
      text.add(fd.decodeCode(code))
  if fd.composite and fd.wmode == 1:
    showTextVertical(gs, fd, codes, text, fs, runs)
    return
  # Total text-space advance, mapped to device x by the rendering
  # rotation, which only affects space-vs-kern joining downstream.
  var advText = 0.0
  for code in codes:
    let decoded =
      if fd.composite: fd.decodeCompositeCode(code)
      else: fd.decodeCode(code)
    var tx = (fd.codeWidth(code) * fs / 1000.0 + gs.text.charSpace) * th
    if decoded == " ":
      tx += gs.text.wordSpace * th
    advText += tx
    let t: Matrix = [1.0, 0.0, 0.0, 1.0, tx, 0.0]
    # Showing text advances Tm only; Tlm keeps the line start for
    # Td, TD and T*.
    gs.textMatrix = concatMatrix(t, gs.textMatrix)
  var w = 0.0
  if fs != 0.0 and th != 0.0:
    w = advText * abs(trm[0]) / (fs * th)
  runs.add(TextRun(text: text, x: trm[4], y: trm[5], size: fs,
    fontName: fd.fontName, w: w))

proc decoderFor(d: var PdfDoc, res: CosObj,
    cache: var Table[string, FontDecoder], gs: GState): FontDecoder =
  if gs.text.fontName.len == 0:
    pdfFail("text showing operator without a selected font (Tf)")
  if cache.hasKey(gs.text.fontName):
    return cache[gs.text.fontName]
  var fonts = res.dictGet("Font")
  if fonts.kind == coRef:
    fonts = d.resolve(fonts)
  if fonts.kind != coDict:
    pdfFail("page /Resources has no /Font dictionary")
  let r = fonts.dictGet(gs.text.fontName)
  if r.kind != coRef and r.kind != coDict:
    pdfFail("font /" & gs.text.fontName & " missing from /Resources")
  result = d.loadDecoder(r, gs.text.fontName)
  cache[gs.text.fontName] = result

proc extractText*(d: var PdfDoc, index: int): seq[TextRun] =
  ## One run per shown string with its device-space origin. Tj
  ## numbers shift Tm only (Td restarts from Tlm); quote operators
  ## expand to their T* plus spacing equivalents.
  let ops = d.walkPageOps(index)
  let res = d.pageResources(index)
  var cache = initTable[string, FontDecoder]()
  var gs = initGState()
  result = @[]
  for op in ops:
    case op.name
    of "Tj":
      if op.operands.len != 1 or op.operands[0].kind != coStr:
        pdfFail("Tj needs one string operand")
      d.showText(gs, d.decoderFor(res, cache, gs),
        op.operands[0].sval, result)
    of "TJ":
      if op.operands.len != 1 or op.operands[0].kind != coArray:
        pdfFail("TJ needs one array operand")
      for item in op.operands[0].items:
        if item.kind == coStr:
          d.showText(gs, d.decoderFor(res, cache, gs), item.sval,
            result)
        else:
          let th = gs.text.scale / 100.0
          let t: Matrix = [1.0, 0.0, 0.0, 1.0,
            -item.asFloat() * gs.text.fontSize * th / 1000.0, 0.0]
          gs.textMatrix = concatMatrix(t, gs.textMatrix)
    of "'":
      if op.operands.len != 1 or op.operands[0].kind != coStr:
        pdfFail("' needs one string operand")
      gs.applyOp(ContentOp(name: "T*"))
      d.showText(gs, d.decoderFor(res, cache, gs),
        op.operands[0].sval, result)
    of "\"":
      if op.operands.len != 3 or op.operands[2].kind != coStr:
        pdfFail("\" needs word/char spacing plus a string")
      gs.text.wordSpace = op.operands[0].asFloat()
      gs.text.charSpace = op.operands[1].asFloat()
      gs.applyOp(ContentOp(name: "T*"))
      d.showText(gs, d.decoderFor(res, cache, gs),
        op.operands[2].sval, result)
    else:
      gs.applyOp(op)
