## Graphics state walker (ISO 32000 §8.4).
##
## Tracks what M3b text extraction and M5 image placement need: the CTM
## (`q/Q/cm`), text matrices (`BT/ET/Tm/Td/TD/T*`), and the text state
## (`Tf/Tc/Tw/Tz/TL/Tr/Ts`). All other operators (path construction,
## painting, `Do`, `gs`, color) are ignored here; M3b and M5 consume the
## raw op list for those.
##
## Matrices are `[a b c d e f]`. concat(m1, m2) returns m1 x m2, which
## is what `cm` does: CTM = M x CTM.

import ./types
import ./lexer
import ./cos
import ./docmodel
import ./filters
import ./content

export content

type
  Matrix* = array[6, float64] ## [a b c d e f]

  TextState* = object
    fontName*: string
    fontSize*: float64
    charSpace*: float64 ## Tc
    wordSpace*: float64 ## Tw
    scale*: float64 ## Tz (percent)
    leading*: float64 ## TL (negative down)
    renderMode*: int ## Tr
    rise*: float64 ## Ts

  SavedState* = object
    ctm*: Matrix
    textMatrix*: Matrix
    textLine*: Matrix
    text*: TextState

  GState* = object
    ctm*: Matrix
    textMatrix*: Matrix
    textLine*: Matrix
    text*: TextState
    inText*: bool
    stack*: seq[SavedState]

proc identityMatrix*(): Matrix =
  [1.0, 0.0, 0.0, 1.0, 0.0, 0.0]

proc concatMatrix*(m1, m2: Matrix): Matrix =
  ## m1 x m2 in PDF [a b c d e f] convention.
  [m1[0] * m2[0] + m1[1] * m2[2],
   m1[0] * m2[1] + m1[1] * m2[3],
   m1[2] * m2[0] + m1[3] * m2[2],
   m1[2] * m2[1] + m1[3] * m2[3],
   m1[4] * m2[0] + m1[5] * m2[2] + m2[4],
   m1[4] * m2[1] + m1[5] * m2[3] + m2[5]]

proc transformPoint*(m: Matrix, x, y: float64): tuple[x, y: float64] =
  (m[0] * x + m[2] * y + m[4], m[1] * x + m[3] * y + m[5])

proc initGState*(): GState =
  GState(ctm: identityMatrix(), textMatrix: identityMatrix(),
    textLine: identityMatrix(), inText: false, stack: @[],
    text: TextState(scale: 100.0))

proc numOperands(op: ContentOp, want: int): seq[float64] =
  if op.operands.len != want:
    pdfFail("operator " & op.name & " needs " & $want & " operands, got " &
      $op.operands.len)
  result = newSeq[float64](want)
  for i in 0 ..< want:
    result[i] = op.operands[i].asFloat()

proc applyOp*(gs: var GState, op: ContentOp) =
  ## Update graphics state for one operator. Unknown operators are
  ## ignored; tracked operators with wrong operand types fail loudly.
  case op.name
  of "q":
    gs.stack.add(SavedState(ctm: gs.ctm, textMatrix: gs.textMatrix,
      textLine: gs.textLine, text: gs.text))
  of "Q":
    if gs.stack.len == 0:
      pdfFail("unbalanced Q (graphics stack underflow)")
    let s = gs.stack[^1]
    gs.stack.setLen(gs.stack.len - 1)
    gs.ctm = s.ctm
    gs.textMatrix = s.textMatrix
    gs.textLine = s.textLine
    gs.text = s.text
  of "cm":
    let v = numOperands(op, 6)
    gs.ctm = concatMatrix([v[0], v[1], v[2], v[3], v[4], v[5]], gs.ctm)
  of "BT":
    gs.inText = true
    gs.textMatrix = identityMatrix()
    gs.textLine = identityMatrix()
  of "ET":
    gs.inText = false
  of "Tm":
    let v = numOperands(op, 6)
    gs.textMatrix = [v[0], v[1], v[2], v[3], v[4], v[5]]
    gs.textLine = gs.textMatrix
  of "Td":
    let v = numOperands(op, 2)
    let t: Matrix = [1.0, 0.0, 0.0, 1.0, v[0], v[1]]
    gs.textLine = concatMatrix(t, gs.textLine)
    gs.textMatrix = gs.textLine
  of "TD":
    let v = numOperands(op, 2)
    gs.text.leading = -v[1]
    let t: Matrix = [1.0, 0.0, 0.0, 1.0, v[0], v[1]]
    gs.textLine = concatMatrix(t, gs.textLine)
    gs.textMatrix = gs.textLine
  of "T*":
    let t: Matrix = [1.0, 0.0, 0.0, 1.0, 0.0, -gs.text.leading]
    gs.textLine = concatMatrix(t, gs.textLine)
    gs.textMatrix = gs.textLine
  of "Tf":
    if op.operands.len != 2:
      pdfFail("operator Tf needs 2 operands, got " & $op.operands.len)
    gs.text.fontName = op.operands[0].asName()
    gs.text.fontSize = op.operands[1].asFloat()
  of "Tc": gs.text.charSpace = numOperands(op, 1)[0]
  of "Tw": gs.text.wordSpace = numOperands(op, 1)[0]
  of "Tz": gs.text.scale = numOperands(op, 1)[0]
  of "TL": gs.text.leading = numOperands(op, 1)[0]
  of "Tr": gs.text.renderMode = numOperands(op, 1)[0].int
  of "Ts": gs.text.rise = numOperands(op, 1)[0]
  else:
    discard # path/paint/XObject/color ops belong to M3b and M5

proc walkOps*(ops: seq[ContentOp]): GState =
  ## Fold a whole op list; returns the end state (M3b tracks per-op).
  result = initGState()
  for op in ops:
    result.applyOp(op)

proc collectPages(d: var PdfDoc, nodeRef: CosObj,
    parentRes: CosObj, depth: int, pages: var seq[CosObj]) =
  if depth > d.limits.maxWalkDepth:
    pdfFail("page tree exceeds nesting depth " & $d.limits.maxWalkDepth)
  if pages.len >= d.limits.maxPages:
    pdfFail("page count exceeds limit " & $d.limits.maxPages)
  let node = d.resolve(nodeRef)
  if node.kind != coDict:
    pdfFail("page tree node is not a dictionary")
  var res = parentRes
  let own = node.dictGet("Resources")
  if own.kind == coDict:
    res = own
  let kids = node.dictGet("Kids")
  if kids.kind == coArray:
    for k in kids.items:
      if k.kind != coRef:
        pdfFail("page tree kid is not an indirect reference")
      d.collectPages(k, res, depth + 1, pages)
  else:
    pages.add(node)

proc pageDicts*(d: var PdfDoc): seq[CosObj] =
  ## Leaf page dictionaries in page-tree order (docmodel.pageBoxes
  ## twin that keeps the dicts for resource/content lookup).
  let cat = d.catalog()
  let pagesRef = cat.dictGet("Pages")
  if pagesRef.kind != coRef:
    pdfFail("PDF catalog missing /Pages reference")
  result = @[]
  d.collectPages(pagesRef, CosObj(kind: coNull), 0, result)

proc pageResources*(d: var PdfDoc, index: int): CosObj =
  ## Inherited /Resources for one page; coNull when absent entirely.
  let pages = d.pageDicts()
  if index < 0 or index >= pages.len:
    pdfFail("page index " & $index & " out of range")
  let node = pages[index]
  var res = node.dictGet("Resources")
  if res.kind == coRef:
    res = d.resolve(res)
  res

proc pageContentStream*(d: var PdfDoc, index: int): string =
  ## Concatenated, filter-decoded page content. /Contents may be a
  ## stream, an array of streams, or an indirect reference to either.
  let pages = d.pageDicts()
  if index < 0 or index >= pages.len:
    pdfFail("page index " & $index & " out of range")
  var c = pages[index].dictGet("Contents")
  if c.kind == coRef:
    c = d.resolve(c)
  var streams: seq[CosObj] = @[]
  if c.kind == coArray:
    for item in c.items:
      var s = item
      if s.kind == coRef:
        s = d.resolve(s)
      if s.kind != coStream:
        pdfFail("page /Contents entry is not a stream")
      streams.add(s)
  elif c.kind == coStream:
    streams.add(c)
  elif c.kind != coNull:
    pdfFail("page /Contents is not a stream or array")
  for s in streams:
    if result.len > 0:
      result.add("\n")
    result.add(decodeCosStream(s))

proc walkPageOps*(d: var PdfDoc, index: int): seq[ContentOp] =
  ## Parsed operators for one page (empty when /Contents is missing).
  parseContentStream(d.pageContentStream(index), d.limits)
