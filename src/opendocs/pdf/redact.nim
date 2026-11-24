## Redaction: mark, apply, verify (M17).
##
## Marking adds /Redact annotations for a review workflow; applying
## removes content and drops the marks; verifying proves nothing
## extractable remains. All three take explicit rects so no step guesses:
## `RedactRect = (page, rect)` with 0-based pages.
##
## Apply removes whole runs, never glyphs: a text-showing op (Tj, TJ,
## ', ") whose run bbox overlaps a rect is dropped entirely, as is a
## `Do`/inline image whose placement bbox overlaps. Text inside a Form
## XObject condemns the whole `Do` invocation (coarse but safe; the
## form's other content goes with it). A black filled rectangle is
## painted over each rect as the visible indicator. Pages whose
## /Contents are direct streams are re-emitted as indirect ones.
##
## Run bboxes are heuristics documented here: horizontal runs use
## [x, y-0.3*size, x+w, y+size], vertical runs
## [x-size, y-w, x+0.3*size, y]. Image bboxes transform the unit square
## by the CTM at the `Do`/BI. Over-removal (a run only grazed by a
## rect) is intended; under-removal fails verification loudly.
## Encrypted input fails loudly (decrypt first). Inline images are
## handled like `Do` images through the same bbox test.

import std/options
import std/tables
import ./types
import ./lexer
import ./cos
import ./docmodel
import ./filters
import ./gstate
import ./text
import ./write
import ./merge
import ./organize

type
  RedactRect* = tuple[page: int, rect: array[4, float64]]

  StreamItem = object
    objNum*: int ## indirect number, -1 for direct streams
    gen*: int
    dict*: CosObj ## stream dict without /Length
    raw*: string ## decoded bytes

proc normRedactRect(r: array[4, float64]): array[4, float64] =
  for v in r:
    if v != v or v == Inf or v == -Inf:
      pdfFail("redact rect has non-finite coordinate")
  let x1 = min(r[0], r[2])
  let y1 = min(r[1], r[3])
  let x2 = max(r[0], r[2])
  let y2 = max(r[1], r[3])
  if x2 <= x1 or y2 <= y1:
    pdfFail("redact rect has non-positive size")
  [x1, y1, x2, y2]

proc overlap(a, b: array[4, float64]): bool =
  a[0] < b[2] and a[2] > b[0] and a[1] < b[3] and a[3] > b[1]

proc hitsAny(b: array[4, float64],
    rects: seq[array[4, float64]]): bool =
  for r in rects:
    if overlap(b, r):
      return true
  false

proc runBox(r: TextRun): array[4, float64] =
  if r.vert:
    [r.x - r.size, r.y - r.w, r.x + r.size * 0.3, r.y]
  else:
    [r.x, r.y - r.size * 0.3, r.x + r.w, r.y + r.size]

proc ctmBox(m: Matrix): array[4, float64] =
  let p0 = transformPoint(m, 0.0, 0.0)
  let p1 = transformPoint(m, 1.0, 0.0)
  let p2 = transformPoint(m, 1.0, 1.0)
  let p3 = transformPoint(m, 0.0, 1.0)
  [min(min(p0.x, p1.x), min(p2.x, p3.x)),
    min(min(p0.y, p1.y), min(p2.y, p3.y)),
    max(max(p0.x, p1.x), max(p2.x, p3.x)),
    max(max(p0.y, p1.y), max(p2.y, p3.y))]

proc rectBox(b: array[4, float64], m: Matrix): array[4, float64] =
  let p0 = transformPoint(m, b[0], b[1])
  let p1 = transformPoint(m, b[2], b[1])
  let p2 = transformPoint(m, b[2], b[3])
  let p3 = transformPoint(m, b[0], b[3])
  [min(min(p0.x, p1.x), min(p2.x, p3.x)),
    min(min(p0.y, p1.y), min(p2.y, p3.y)),
    max(max(p0.x, p1.x), max(p2.x, p3.x)),
    max(max(p0.y, p1.y), max(p2.y, p3.y))]

proc emitOp(op: ContentOp): string =
  ## One content operator back to bytes. Operands serialize via
  ## writeCos; inline images use the same bare `key value` lines the
  ## parser accepts, framed by `ID`/`EI` with separating whitespace.
  if op.name == "BI":
    if op.operands.len != 2 or op.operands[0].kind != coDict or
        op.operands[1].kind != coStr:
      pdfFail("inline image needs a dict and data")
    result = "BI\n"
    for i, k in op.operands[0].keys:
      result.add("/" & k & " " & writeCos(op.operands[0].vals[i]) & "\n")
    let raw = op.operands[1].sval
    result.add("ID ")
    result.add(raw)
    if raw.len == 0 or raw[^1] notin {'\x09', '\x0A', '\x0C', '\x0D',
        '\x20'}:
      result.add(" ")
    result.add("EI")
    return
  for o in op.operands:
    result.add(writeCos(o))
    result.add(" ")
  result.add(op.name)

proc emitOps(ops: seq[ContentOp]): string =
  for op in ops:
    result.add(emitOp(op))
    result.add("\n")

proc formMatrixOf(form: CosObj): Matrix =
  ## /Matrix of a form, identity when absent or malformed (the spec
  ## treats it as optional; walkInto does the same).
  let m = form.dictGet("Matrix")
  if m.kind != coArray or m.items.len != 6:
    return identityMatrix()
  try:
    [m.items[0].asFloat(), m.items[1].asFloat(),
      m.items[2].asFloat(), m.items[3].asFloat(),
      m.items[4].asFloat(), m.items[5].asFloat()]
  except PdfError:
    identityMatrix()

proc formDeviceBox(form: CosObj, m: Matrix): tuple[box: array[4, float64],
    has: bool] =
  let b = form.dictGet("BBox")
  if b.kind != coArray or b.items.len != 4:
    return ([0.0, 0.0, 0.0, 0.0], false)
  try:
    let r = [min(b.items[0].asFloat(), b.items[2].asFloat()),
      min(b.items[1].asFloat(), b.items[3].asFloat()),
      max(b.items[0].asFloat(), b.items[2].asFloat()),
      max(b.items[1].asFloat(), b.items[3].asFloat())]
    (rectBox(r, m), true)
  except PdfError:
    ([0.0, 0.0, 0.0, 0.0], false)

proc showHit(d: var PdfDoc, op: ContentOp, res: CosObj, gs: var GState,
    cache: var Table[string, FontDecoder], s: string,
    bbox: array[4, float64], hasBBox: bool, depth: int,
    rects: seq[array[4, float64]]): bool =
  ## Advance through one shown string exactly like extraction, reporting
  ## whether its run overlaps a rect. Empty and BBox-clipped strings
  ## (no run) are misses.
  let wo = WalkedOp(op: op, resources: res, ctm: gs.ctm, bbox: bbox,
    hasBBox: hasBBox, depth: depth)
  let r = d.showTextRun(wo, gs, cache, s)
  if r.isNone:
    return false
  hitsAny(runBox(r.get()), rects)

proc scanOps(d: var PdfDoc, ops: seq[ContentOp], res: CosObj,
    gs: var GState, cache: var Table[string, FontDecoder],
    rects: seq[array[4, float64]], drops: var seq[bool],
    bbox: array[4, float64], hasBBox: bool, depth: int): bool =
  ## Mirror of extractText's dispatch that marks intersecting showing
  ## ops and image invocations instead of collecting runs. Text inside
  ## a form condemns the whole invoking `Do`. Returns true on any hit.
  result = false
  for i, op in ops:
    case op.name
    of "Tj":
      if op.operands.len != 1 or op.operands[0].kind != coStr:
        pdfFail("Tj needs one string operand")
      if d.showHit(op, res, gs, cache, op.operands[0].sval, bbox,
          hasBBox, depth, rects):
        drops[i] = true
        result = true
    of "TJ":
      if op.operands.len != 1 or op.operands[0].kind != coArray:
        pdfFail("TJ needs one array operand")
      var hit = false
      for item in op.operands[0].items:
        if item.kind == coStr:
          if d.showHit(op, res, gs, cache, item.sval, bbox, hasBBox,
              depth, rects):
            hit = true
        else:
          let th = gs.text.scale / 100.0
          let t: Matrix = [1.0, 0.0, 0.0, 1.0,
            -item.asFloat() * gs.text.fontSize * th / 1000.0, 0.0]
          gs.textMatrix = concatMatrix(t, gs.textMatrix)
      if hit:
        drops[i] = true
        result = true
    of "'":
      if op.operands.len != 1 or op.operands[0].kind != coStr:
        pdfFail("' needs one string operand")
      gs.applyOp(ContentOp(name: "T*"))
      if d.showHit(op, res, gs, cache, op.operands[0].sval, bbox,
          hasBBox, depth, rects):
        drops[i] = true
        result = true
    of "\"":
      if op.operands.len != 3 or op.operands[2].kind != coStr:
        pdfFail("\" needs word/char spacing plus a string")
      gs.text.wordSpace = op.operands[0].asFloat()
      gs.text.charSpace = op.operands[1].asFloat()
      gs.applyOp(ContentOp(name: "T*"))
      if d.showHit(op, res, gs, cache, op.operands[2].sval, bbox,
          hasBBox, depth, rects):
        drops[i] = true
        result = true
    of "Do":
      if op.operands.len != 1 or op.operands[0].kind != coName:
        pdfFail("Do needs one name operand")
      let xo = d.lookupXObject(res, op.operands[0].name)
      if xo.kind == coNull:
        pdfFail("XObject /" & op.operands[0].name &
          " missing from /Resources")
      if xo.kind != coDict and xo.kind != coStream:
        pdfFail("XObject /" & op.operands[0].name &
          " is not a dictionary")
      let sub = xo.dictGet("Subtype")
      if sub.kind == coName and sub.name == "Form":
        if xo.kind != coStream:
          pdfFail("Form XObject /" & op.operands[0].name &
            " is not a stream")
        if depth >= d.limits.maxNestedXObject:
          pdfFail("Form XObject nesting exceeds limit " &
            $d.limits.maxNestedXObject)
        var gs2 = gs
        gs2.applyOp(ContentOp(name: "q"))
        let fm = formMatrixOf(xo)
        var cmOps: seq[CosObj] = @[]
        for v in fm:
          cmOps.add(CosObj(kind: coFloat, fval: v))
        gs2.applyOp(ContentOp(name: "cm", operands: cmOps))
        var fres = res
        let own = xo.dictGet("Resources")
        let ro =
          if own.kind == coRef: d.resolve(own)
          else: own
        if ro.kind == coDict:
          fres = ro
        let (dev, has) = formDeviceBox(xo, gs2.ctm)
        let inner = parseContentStream(decodeCosStream(xo, d.limits),
          d.limits)
        var innerDrops = newSeq[bool](inner.len)
        let hit = d.scanOps(inner, fres, gs2, cache, rects, innerDrops,
          dev, has or hasBBox, depth + 1)
        gs2.applyOp(ContentOp(name: "Q"))
        gs = gs2
        if hit:
          drops[i] = true
          result = true
      else:
        if hitsAny(ctmBox(gs.ctm), rects):
          drops[i] = true
          result = true
    of "BI":
      if hitsAny(ctmBox(gs.ctm), rects):
        drops[i] = true
        result = true
    else:
      gs.applyOp(op)

proc contentItems(d: var PdfDoc,
    page: int): tuple[dict: CosObj, items: seq[StreamItem]] =
  ## Decoded /Contents streams with their dicts (sans /Length).
  ## Indirect streams keep their numbers; direct ones read -1 and are
  ## re-emitted as indirect on apply.
  let prefs = d.pageRefs()
  if page < 0 or page >= prefs.len:
    pdfFail("redact page " & $page & " out of range")
  if prefs[page].pageRef.kind != coRef:
    pdfFail("page tree leaf is not an indirect reference")
  let pdict = d.resolve(prefs[page].pageRef)
  if pdict.kind != coDict:
    pdfFail("page tree leaf is not a dictionary")
  result.dict = pdict
  let c = pdict.dictGet("Contents")
  if c.kind == coNull:
    discard
  elif c.kind == coRef:
    let v = d.resolve(c)
    if v.kind != coStream:
      pdfFail("page /Contents entry is not a stream")
    var keys: seq[string] = @[]
    var vals: seq[CosObj] = @[]
    for i, k in v.streamDict:
      if k == "Length":
        continue
      keys.add(k)
      vals.add(v.streamVals[i])
    result.items.add(StreamItem(objNum: c.refNum, gen: c.refGen,
      dict: CosObj(kind: coDict, keys: keys, vals: vals),
      raw: decodeCosStream(v, d.limits)))
  elif c.kind == coStream:
    var keys: seq[string] = @[]
    var vals: seq[CosObj] = @[]
    for i, k in c.streamDict:
      if k == "Length":
        continue
      keys.add(k)
      vals.add(c.streamVals[i])
    result.items.add(StreamItem(objNum: -1, gen: 0,
      dict: CosObj(kind: coDict, keys: keys, vals: vals),
      raw: decodeCosStream(c, d.limits)))
  elif c.kind == coArray:
    for it in c.items:
      if it.kind == coRef:
        let v = d.resolve(it)
        if v.kind != coStream:
          pdfFail("page /Contents entry is not a stream")
        var keys: seq[string] = @[]
        var vals: seq[CosObj] = @[]
        for i, k in v.streamDict:
          if k == "Length":
            continue
          keys.add(k)
          vals.add(v.streamVals[i])
        result.items.add(StreamItem(objNum: it.refNum, gen: it.refGen,
          dict: CosObj(kind: coDict, keys: keys, vals: vals),
          raw: decodeCosStream(v, d.limits)))
      elif it.kind == coStream:
        var keys: seq[string] = @[]
        var vals: seq[CosObj] = @[]
        for i, k in it.streamDict:
          if k == "Length":
            continue
          keys.add(k)
          vals.add(it.streamVals[i])
        result.items.add(StreamItem(objNum: -1, gen: 0,
          dict: CosObj(kind: coDict, keys: keys, vals: vals),
          raw: decodeCosStream(it, d.limits)))
      else:
        pdfFail("page /Contents entry is not a stream")
  else:
    pdfFail("page /Contents is not a stream or array")

proc pageHits(d: var PdfDoc, page: int,
    rects: seq[array[4, float64]]): seq[seq[bool]] =
  ## Per-stream drop flags for one page. Shared by apply (drop) and
  ## verify (any true fails).
  let res = d.pageResources(page)
  let (_, items) = d.contentItems(page)
  var gs = initGState()
  var cache = initTable[string, FontDecoder]()
  for s in items:
    let ops = parseContentStream(s.raw, d.limits)
    var drops = newSeq[bool](ops.len)
    discard d.scanOps(ops, res, gs, cache, rects, drops,
      [0.0, 0.0, 0.0, 0.0], false, 0)
    result.add(drops)

proc markRedactions*(base: string, rects: seq[RedactRect]): string =
  ## Add one /Redact annotation per rect for the review workflow.
  ## Returns new file bytes; the base is untouched.
  if rects.len == 0:
    pdfFail("no redact rects to mark")
  var specs: seq[tuple[page: int, dict: CosObj]] = @[]
  for r in rects:
    let q = normRedactRect(r.rect)
    let rc = CosObj(kind: coArray, items: @[
      CosObj(kind: coFloat, fval: q[0]),
      CosObj(kind: coFloat, fval: q[1]),
      CosObj(kind: coFloat, fval: q[2]),
      CosObj(kind: coFloat, fval: q[3])])
    let qp = CosObj(kind: coArray, items: @[
      CosObj(kind: coFloat, fval: q[0]),
      CosObj(kind: coFloat, fval: q[3]),
      CosObj(kind: coFloat, fval: q[2]),
      CosObj(kind: coFloat, fval: q[3]),
      CosObj(kind: coFloat, fval: q[0]),
      CosObj(kind: coFloat, fval: q[1]),
      CosObj(kind: coFloat, fval: q[2]),
      CosObj(kind: coFloat, fval: q[1])])
    specs.add((r.page, CosObj(kind: coDict,
      keys: @["Type", "Subtype", "Rect", "QuadPoints"],
      vals: @[CosObj(kind: coName, name: "Annot"),
        CosObj(kind: coName, name: "Redact"), rc, qp])))
  addAnnotsUpdate(base, specs)

proc applyRedactions*(base: string, rects: seq[RedactRect]): string =
  ## Remove intersecting text/image ops, drop /Redact annots, paint a
  ## black rectangle over each rect. Returns new file bytes.
  if rects.len == 0:
    pdfFail("no redact rects to apply")
  var u = beginUpdate(base)
  var d = openDoc(u.base, u.limits)
  var byPage = initTable[int, seq[array[4, float64]]]()
  for r in rects:
    byPage.mgetOrPut(r.page, @[]).add(normRedactRect(r.rect))
  let prefs = d.pageRefs()
  for page in byPage.keys:
    if page < 0 or page >= prefs.len:
      pdfFail("redact page " & $page & " out of range")
  for page, rs in byPage.pairs:
    let hits = d.pageHits(page, rs)
    let (pdict, items) = d.contentItems(page)
    if prefs[page].pageRef.kind != coRef:
      pdfFail("page tree leaf is not an indirect reference")
    let pageNum = prefs[page].pageRef.refNum
    var streams = items
    var opsPerStream: seq[seq[ContentOp]] = @[]
    for s in streams:
      opsPerStream.add(parseContentStream(s.raw, d.limits))
    # Overlay on the last stream (or a fresh one when no content).
    var overlay = ""
    for r in rs:
      overlay.add("q 0 g " & $r[0] & " " & $r[1] & " " & $(r[2] - r[0]) &
        " " & $(r[3] - r[1]) & " re f Q\n")
    if opsPerStream.len == 0:
      let num = u.addObject(writeCos(CosObj(kind: coStream,
        streamDict: @["Length"], streamVals: @[CosObj(kind: coInt,
          ival: overlay.len)], raw: overlay)))
      var keys = pdict.keys
      var vals = pdict.vals
      var replaced = false
      for i, k in keys:
        if k == "Contents":
          keys[i] = k
          vals[i] = CosObj(kind: coRef, refNum: num, refGen: 0)
          replaced = true
      if not replaced:
        keys.add("Contents")
        vals.add(CosObj(kind: coRef, refNum: num, refGen: 0))
      discard u.updateObject(pageNum,
        writeCos(CosObj(kind: coDict, keys: keys, vals: vals)))
    else:
      for si in 0 ..< streams.len:
        var kept: seq[ContentOp] = @[]
        for oi, op in opsPerStream[si]:
          if oi < hits[si].len and hits[si][oi]:
            continue
          kept.add(op)
        var raw = emitOps(kept)
        if si == streams.len - 1:
          raw.add(overlay)
        let enc = deflateEncode(raw)
        var keys: seq[string] = @[]
        var vals: seq[CosObj] = @[]
        for i, k in streams[si].dict.keys:
          if k == "Filter" or k == "DecodeParms" or k == "DL":
            continue
          keys.add(k)
          vals.add(streams[si].dict.vals[i])
        keys.add("Filter")
        vals.add(CosObj(kind: coName, name: "FlateDecode"))
        keys.add("Length")
        vals.add(CosObj(kind: coInt, ival: enc.len))
        let body = writeCos(CosObj(kind: coStream, streamDict: keys,
          streamVals: vals, raw: enc))
        if streams[si].objNum >= 0:
          discard u.updateObject(streams[si].objNum, body)
        else:
          streams[si].objNum = u.addObject(body)
      # Converted direct streams need the page /Contents rewired.
      var needRewire = false
      for s in streams:
        if s.objNum < 0:
          needRewire = true
          break
      if needRewire:
        var refs: seq[CosObj] = @[]
        for s in streams:
          refs.add(CosObj(kind: coRef, refNum: s.objNum,
            refGen: s.gen))
        var keys = pdict.keys
        var vals = pdict.vals
        var replaced = false
        for i, k in keys:
          if k == "Contents":
            vals[i] =
              if refs.len == 1: refs[0]
              else: CosObj(kind: coArray, items: refs)
            replaced = true
        if not replaced:
          keys.add("Contents")
          vals.add(
            if refs.len == 1: refs[0]
            else: CosObj(kind: coArray, items: refs))
        discard u.updateObject(pageNum,
          writeCos(CosObj(kind: coDict, keys: keys, vals: vals)))
    # Drop /Redact annots on this page.
    let annots = pdict.dictGet("Annots")
    if annots.kind == coNull:
      continue
    var kept: seq[CosObj] = @[]
    var arrRef = -1
    var arrGen = 0
    var arrItems: seq[CosObj] = @[]
    if annots.kind == coArray:
      arrItems = annots.items
    elif annots.kind == coRef:
      let arr = d.resolve(annots)
      if arr.kind != coArray:
        pdfFail("page /Annots is not an array")
      arrItems = arr.items
      arrRef = annots.refNum
      arrGen = annots.refGen
    else:
      pdfFail("page /Annots is not an array")
    for a in arrItems:
      let node = d.resolve(a)
      if node.kind == coDict and node.dictGet("Subtype").kind == coName and
          node.dictGet("Subtype").name == "Redact":
        continue
      kept.add(a)
    if kept.len == arrItems.len:
      continue
    if arrRef >= 0:
      discard u.updateObject(arrRef,
        writeCos(CosObj(kind: coArray, items: kept)))
    else:
      var keys = pdict.keys
      var vals = pdict.vals
      for i, k in keys:
        if k == "Annots":
          vals[i] = CosObj(kind: coArray, items: kept)
      discard u.updateObject(pageNum,
        writeCos(CosObj(kind: coDict, keys: keys, vals: vals)))
  u.finishUpdate()

proc verifyNoFauxRedaction*(data: string, rects: seq[RedactRect]) =
  ## Fail when any text run or image placement on the data overlaps a
  ## rect. Run after apply (must pass) and on any file handed to a
  ## third party after redaction. Uses the same bboxes as apply, so a
  ## file apply produced always verifies.
  if rects.len == 0:
    pdfFail("no redact rects to verify")
  var d = openDoc(data)
  var byPage = initTable[int, seq[array[4, float64]]]()
  for r in rects:
    byPage.mgetOrPut(r.page, @[]).add(normRedactRect(r.rect))
  let n = d.pageCount()
  for page in byPage.keys:
    if page < 0 or page >= n:
      pdfFail("redact page " & $page & " out of range")
  for page, rs in byPage.pairs:
    let hits = d.pageHits(page, rs)
    for si, drops in hits:
      for oi, drop in drops:
        if drop:
          pdfFail("faux redaction: content remains on page " & $page &
            " (stream " & $si & " op " & $oi & ")")
