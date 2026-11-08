## Annotation read (ISO 32000 §12.5).
##
## pageAnnots/docAnnots return one flat PdfAnnot per annotation dict:
## links (URI + internal), text notes, squares, highlights with quad
## points, ink lists, and widgets (which also appear in formFields;
## both views are kept, never deduplicated). /Rect is normalised
## (reversed corners fixed); genuinely unparseable values fail naming
## the object. Appearance streams are not synthesised (needs a
## renderer); /AP presence is not reported.

import ./lexer
import ./cos
import ./docmodel
import ./gstate
import ./names
import ./outline

type
  PdfAnnot* = object
    subtype*: string ## /Link /Text /Square /Widget /...
    rect*: array[4, float64] ## normalised [x1 y1 x2 y2]
    hasRect*: bool ## false only when /Rect is absent (not for widgets)
    contents*: string ## /Contents (note the plural spelling)
    author*: string ## /T on markup annotations, "" on widgets
    title*: string ## /Title, rarely present
    subject*: string ## /Subj
    modified*: string ## raw /M date string
    flags*: int ## /F bitfield, 0 when absent
    border*: seq[float64] ## /Border h/v/width or /BS /W, empty when absent
    color*: seq[float64] ## /C components, empty when absent
    uri*: string ## link /A /URI target
    destPage*: int ## resolved page, -1 when absent/unresolvable
    dest*: string ## named destination, "" for explicit destinations
    quadPoints*: seq[array[8, float64]] ## one entry per quadrilateral
    inkList*: seq[seq[float64]] ## /InkList strokes
    name*: string ## /T on widgets (field name), /NM otherwise

proc annotNumbers(v: CosObj, what: string): seq[float64] =
  if v.kind != coArray:
    pdfFail(what & " is not an array")
  for it in v.items:
    result.add(it.asFloat())

proc readAnnotRect(node: CosObj, label: string): tuple[r: array[4, float64],
    has: bool] =
  let r = node.dictGet("Rect")
  if r.kind == coNull:
    return ([0.0, 0.0, 0.0, 0.0], false)
  let xs = annotNumbers(r, label & " /Rect")
  if xs.len != 4:
    pdfFail(label & " /Rect must hold 4 numbers")
  ([min(xs[0], xs[2]), min(xs[1], xs[3]),
    max(xs[0], xs[2]), max(xs[1], xs[3])], true)

proc readAnnot*(d: var PdfDoc, nodeVal: CosObj,
    label: string): PdfAnnot =
  ## One annotation dict (ref or direct) into a PdfAnnot.
  let node = d.resolve(nodeVal)
  if node.kind != coDict:
    pdfFail(label & " is not a dictionary")
  let sub = node.dictGet("Subtype")
  result.subtype = if sub.kind == coName: sub.name else: ""
  result.destPage = -1
  let (r, has) = readAnnotRect(node, label)
  result.rect = r
  result.hasRect = has
  if not has and result.subtype == "Widget":
    pdfFail(label & " widget annotation missing /Rect")
  let c = node.dictGet("Contents")
  if c.kind == coStr:
    result.contents = c.sval
  let t = node.dictGet("T")
  if t.kind == coStr:
    if result.subtype == "Widget":
      result.name = t.sval
    else:
      result.author = t.sval
      result.name = t.sval
  let title = node.dictGet("Title")
  if title.kind == coStr:
    result.title = title.sval
  let subj = node.dictGet("Subj")
  if subj.kind == coStr:
    result.subject = subj.sval
  let m = node.dictGet("M")
  if m.kind == coStr:
    result.modified = m.sval
  let f = node.dictGet("F")
  if f.kind == coInt:
    result.flags = f.ival
  let nm = node.dictGet("NM")
  if nm.kind == coStr and result.name.len == 0:
    result.name = nm.sval
  let col = node.dictGet("C")
  if col.kind == coArray:
    result.color = annotNumbers(col, label & " /C")
  let bs = node.dictGet("BS")
  if bs.kind == coDict:
    let w = bs.dictGet("W")
    if w.kind == coInt or w.kind == coFloat:
      result.border = @[w.asFloat()]
  else:
    let b = node.dictGet("Border")
    if b.kind == coArray and b.items.len >= 3:
      result.border = @[b.items[0].asFloat(), b.items[1].asFloat(),
        b.items[2].asFloat()]
  let qp = node.dictGet("QuadPoints")
  if qp.kind == coArray:
    let xs = annotNumbers(qp, label & " /QuadPoints")
    if xs.len mod 8 != 0:
      pdfFail(label & " /QuadPoints length is not a multiple of 8")
    var i = 0
    while i < xs.len:
      result.quadPoints.add([xs[i], xs[i + 1], xs[i + 2], xs[i + 3],
        xs[i + 4], xs[i + 5], xs[i + 6], xs[i + 7]])
      i += 8
  let ink = node.dictGet("InkList")
  if ink.kind == coArray:
    for stroke in ink.items:
      if stroke.kind != coArray:
        pdfFail(label & " /InkList stroke is not an array")
      result.inkList.add(annotNumbers(stroke, label & " /InkList stroke"))
  let pageIdx = d.pageRefIndex()
  let dest = node.dictGet("Dest")
  if dest.kind != coNull:
    var v = dest
    if v.kind == coStr:
      result.dest = v.sval
    elif v.kind == coName:
      result.dest = v.name
    result.destPage = d.destPageIndex(v, pageIdx)
  var a = node.dictGet("A")
  if a.kind == coRef:
    a = d.resolve(a)
  if a.kind == coDict:
    let s = a.dictGet("S")
    if s.kind == coName and s.name == "URI":
      let u = a.dictGet("URI")
      if u.kind == coStr:
        result.uri = u.sval
    elif s.kind == coName and s.name == "GoTo":
      let dd = a.dictGet("D")
      if dd.kind == coStr:
        result.dest = dd.sval
      elif dd.kind == coName:
        result.dest = dd.name
      result.destPage = d.destPageIndex(dd, pageIdx)

proc pageAnnots*(d: var PdfDoc, index: int): seq[PdfAnnot] =
  ## Every annotation on one page, in /Annots order. Widgets included.
  let pages = d.pageDicts()
  if index < 0 or index >= pages.len:
    pdfFail("page index " & $index & " out of range")
  var annots = pages[index].dictGet("Annots")
  if annots.kind == coNull:
    return @[]
  if annots.kind == coRef:
    annots = d.resolve(annots)
  if annots.kind != coArray:
    pdfFail("page /Annots is not an array")
  for i, a in annots.items:
    let label = "annotation " & $i & " on page " & $index
    result.add(d.readAnnot(a, label))

proc docAnnots*(d: var PdfDoc): seq[tuple[page: int, annot: PdfAnnot]] =
  ## Every annotation in the document with its 0-based page.
  let n = d.pageDicts().len
  for i in 0 ..< n:
    for a in d.pageAnnots(i):
      result.add((i, a))
