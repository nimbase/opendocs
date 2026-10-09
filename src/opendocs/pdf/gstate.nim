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
  ## Parsed operators for one page's own /Contents (empty when absent).
  ## This is the flat view: no Form XObject expansion, and no resource
  ## context per op. Use walkNested for anything that interprets the
  ## operators, since a form's resources shadow the page's.
  parseContentStream(d.pageContentStream(index), d.limits)

# ---------------------------------------------------------------------------
# Form XObject descent (M7)
#
# A page's content stream can invoke `/Subtype /Form` XObjects with `Do`.
# The invoked stream carries its own /Matrix, /BBox and /Resources, so
# an op is only interpretable together with the resource frame that was
# in effect when it ran. walkPageOps cannot express that (it returns a
# flat list), which is why WalkedOp carries the frame with the operator
# rather than exposing the frame as a parallel array: a consumer then
# cannot pair an op with the wrong resources by accident.
#
# Descent is per `Do`-execution, not per object. The same form drawn 40
# times on a page is walked 40 times, because each invocation has its own
# CTM. Recursion is bounded by maxNestedXObject, not maxWalkDepth (which
# governs the page tree).
# ---------------------------------------------------------------------------

type
  WalkedOp* = object
    op*: ContentOp
    resources*: CosObj ## resource frame in effect for this op
    ctm*: Matrix ## CTM in effect for this op (includes form /Matrix)
    bbox*: array[4, float64] ## clipped /BBox in device space, NaN-free
    hasBBox*: bool ## false for page-level ops
    depth*: int ## 0 at page level, +1 per nested form

proc resolveDict(d: var PdfDoc, v: CosObj): CosObj =
  ## Resolve one indirection; a non-dict or missing value is coNull.
  if v.kind == coRef:
    return d.resolve(v)
  v

proc lookupXObject*(d: var PdfDoc, resources: CosObj,
    name: string): CosObj =
  ## One category lookup in a resolved /Resources dict. coNull when the
  ## category or the entry is absent; callers decide whether that is an
  ## error (a `Do` naming a missing XObject is) or expected (optional
  ## categories like /ExtGState are not).
  let cat = resources.dictGet("XObject")
  let cats = resolveDict(d, cat)
  if cats.kind != coDict:
    return CosObj(kind: coNull)
  resolveDict(d, cats.dictGet(name))

proc formMatrix(form: CosObj): Matrix =
  ## /Matrix for a form XObject; identity when absent. A malformed or
  ## wrongly-typed /Matrix is ignored rather than fatal, matching how the
  ## spec treats an optional entry.
  let m = form.dictGet("Matrix")
  if m.kind != coArray or m.items.len != 6:
    return identityMatrix()
  try:
    var v: Matrix
    for i in 0 .. 5:
      v[i] = m.items[i].asFloat()
    v
  except PdfError:
    identityMatrix()

type
  BBoxRect* = object
    present*: bool ## false when the form carries no usable /BBox
    rect*: array[4, float64] ## form space, x0 <= x1 and y0 <= y1

proc formBBox(form: CosObj): BBoxRect =
  ## /BBox in form space, normalised so x0 <= x1 and y0 <= y1.
  let b = form.dictGet("BBox")
  if b.kind != coArray or b.items.len != 4:
    return BBoxRect()
  try:
    var r: array[4, float64]
    for i in 0 .. 3:
      r[i] = b.items[i].asFloat()
    BBoxRect(present: true, rect: [min(r[0], r[2]), min(r[1], r[3]),
      max(r[0], r[2]), max(r[1], r[3])])
  except PdfError:
    BBoxRect()

proc deviceBox(b: array[4, float64], m: Matrix): array[4, float64] =
  ## Device-space bounding box of a form-space rectangle: transform all
  ## four corners, then renormalise. Transforming two corners is not
  ## enough when the matrix rotates or skews.
  let p0 = transformPoint(m, b[0], b[1])
  let p1 = transformPoint(m, b[2], b[1])
  let p2 = transformPoint(m, b[2], b[3])
  let p3 = transformPoint(m, b[0], b[3])
  [min(min(p0.x, p1.x), min(p2.x, p3.x)),
    min(min(p0.y, p1.y), min(p2.y, p3.y)),
    max(max(p0.x, p1.x), max(p2.x, p3.x)),
    max(max(p0.y, p1.y), max(p2.y, p3.y))]

proc matrixOp(m: Matrix): ContentOp =
  ## `cm` operator applying m, used to enter a Form XObject.
  var ops: seq[CosObj]
  ops = newSeq[CosObj](6)
  for i in 0 .. 5:
    ops[i] = CosObj(kind: coFloat, fval: m[i])
  ContentOp(name: "cm", operands: ops)

proc walkInto(d: var PdfDoc, gs: var GState, ops: seq[ContentOp],
    resources: CosObj, bbox: array[4, float64], hasBBox: bool,
    depth: int, acc: var seq[WalkedOp]) =
  ## Recursive worker for walkNested. Graphics state flows through `gs`
  ## so the CTM seen by each op is the one in effect where it ran.
  if depth > d.limits.maxNestedXObject:
    pdfFail("Form XObject nesting exceeds limit " &
      $d.limits.maxNestedXObject)
  for op in ops:
    if op.name != "Do" or op.operands.len != 1 or
        op.operands[0].kind != coName:
      acc.add(WalkedOp(op: op, resources: resources, ctm: gs.ctm,
        bbox: bbox, hasBBox: hasBBox, depth: depth))
      gs.applyOp(op)
      continue
    let name = op.operands[0].name
    let xo = d.lookupXObject(resources, name)
    if xo.kind == coNull:
      pdfFail("XObject /" & name & " missing from /Resources")
    if xo.kind != coDict and xo.kind != coStream:
      pdfFail("XObject /" & name & " is not a dictionary")
    let sub = xo.dictGet("Subtype")
    if sub.kind != coName or sub.name != "Form":
      # Images are collected by images.nim, which uses the CTM carried
      # here. Other subtypes have no nested content to interpret.
      acc.add(WalkedOp(op: op, resources: resources, ctm: gs.ctm,
        bbox: bbox, hasBBox: hasBBox, depth: depth))
      continue
    if xo.kind != coStream:
      pdfFail("Form XObject /" & name & " is not a stream")
    # Per ISO 32000 8.10.1 a form runs as if wrapped in q/Q, so the
    # caller's graphics state survives even an unbalanced q/Q inside the
    # form. The synthesised q/cm/Q are emitted into the output so a
    # consumer replaying the ops linearly lands on the same CTM this walk
    # recorded; applying them only to the local gs would make WalkedOp.ctm
    # disagree with what a linear replay computes. The `Do` itself is
    # emitted too, with the caller's frame: consumers that need the
    # invocation (a form's own /OC entry scopes everything it draws)
    # can see it, and the ops that follow are its expansion.
    let enterQ = ContentOp(name: "q")
    let enterCm = matrixOp(formMatrix(xo))
    let exitQ = ContentOp(name: "Q")
    acc.add(WalkedOp(op: op, resources: resources, ctm: gs.ctm,
      bbox: bbox, hasBBox: hasBBox, depth: depth))
    gs.applyOp(enterQ)
    gs.applyOp(enterCm)
    var formRes = resources
    let own = resolveDict(d, xo.dictGet("Resources"))
    if own.kind == coDict:
      formRes = own
    let bb = formBBox(xo)
    let device = if bb.present: deviceBox(bb.rect, gs.ctm) else: bbox
    let inner = parseContentStream(decodeCosStream(xo), d.limits)
    acc.add(WalkedOp(op: enterQ, resources: formRes, ctm: gs.ctm,
      bbox: bbox, hasBBox: hasBBox, depth: depth))
    acc.add(WalkedOp(op: enterCm, resources: formRes, ctm: gs.ctm,
      bbox: bbox, hasBBox: hasBBox, depth: depth))
    walkInto(d, gs, inner, formRes, device, hasBBox or bb.present,
      depth + 1, acc)
    gs.applyOp(exitQ)
    # The synthesised Q restores the caller's graphics state, so it
    # belongs to the caller's resource frame, not the form's.
    acc.add(WalkedOp(op: exitQ, resources: resources, ctm: gs.ctm,
      bbox: bbox, hasBBox: hasBBox, depth: depth))

proc walkNested*(d: var PdfDoc, index: int): seq[WalkedOp] =
  ## Page operators with Form XObjects expanded in place. Each op
  ## carries the resource frame, CTM and (inside a form) the device-space
  ## BBox in effect where it ran. A `Do` that invokes a form is emitted
  ## with the caller's frame ahead of its expansion, so the invocation
  ## itself (notably a form's own /OC entry) stays visible.
  ##
  ## A form with no /Resources inherits the page's frame, per spec; that
  ## is common and must not be an error. A `Do` naming an XObject that is
  ## neither /Form nor /Image is passed through, since image collection
  ## handles those and other subtypes have no content to interpret.
  let pageRes = d.pageResources(index)
  var gs = initGState()
  let ops = parseContentStream(d.pageContentStream(index), d.limits)
  walkInto(d, gs, ops, pageRes, [0.0, 0.0, 0.0, 0.0], false, 0, result)
