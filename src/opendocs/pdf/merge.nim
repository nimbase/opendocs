## Page transplant for merge and split (M9).
##
## `copyPage` clones one donor page plus every object it reaches
## (contents, resources, annotations) into a `PdfBuilder` under fresh
## numbers, so references never collide. Inherited `/MediaBox` and
## `/Resources` are materialized onto the copied page dict; stream
## bytes travel untouched (no decode/re-encode, so DCT/JPX survive).
## `extractPages` and `mergePdfs` assemble the results into fresh
## files. Encrypted donors are rejected loudly, like M6 rewrite.

import std/tables
import ./types
import ./cos
import ./docmodel
import ./write

type
  PageRef* = tuple[pageRef: CosObj, mediaBox: CosObj, resources: CosObj]
    ## One donor page: its indirect reference plus the effective
    ## /MediaBox value (never coNull) and /Resources value (coNull
    ## when neither page nor tree defines any).

proc isNum(o: CosObj): bool =
  o.kind == coInt or o.kind == coFloat

proc validBox(box: CosObj): bool =
  if box.kind != coArray or box.items.len != 4:
    return false
  for item in box.items:
    if not isNum(item):
      return false
  true

proc collectPages(d: var PdfDoc, nodeRef: CosObj, box, res: CosObj,
    depth: int, pages: var seq[PageRef]) =
  if depth > d.limits.maxWalkDepth:
    pdfFail("page tree exceeds nesting depth " & $d.limits.maxWalkDepth)
  if pages.len >= d.limits.maxPages:
    pdfFail("page count exceeds limit " & $d.limits.maxPages)
  let node = d.resolve(nodeRef)
  if node.kind != coDict:
    pdfFail("page tree node is not a dictionary")
  var effBox = box
  let mb = node.dictGet("MediaBox")
  if mb.kind == coArray:
    if not validBox(mb):
      pdfFail("page /MediaBox must be an array of 4 numbers")
    effBox = mb
  var effRes = res
  let rs = node.dictGet("Resources")
  if rs.kind == coDict:
    effRes = rs
  let kids = node.dictGet("Kids")
  if kids.kind == coArray:
    for k in kids.items:
      if k.kind != coRef:
        pdfFail("page tree kid is not an indirect reference")
      d.collectPages(k, effBox, effRes, depth + 1, pages)
  else:
    let t = node.dictGet("Type")
    if t.kind == coName and t.name == "Pages":
      pdfFail("empty /Pages node in page tree")
    if effBox.kind == coNull:
      pdfFail("page missing /MediaBox and no inherited box")
    pages.add((nodeRef, effBox, effRes))

proc pageRefs*(d: var PdfDoc): seq[PageRef] =
  ## Page references in page-tree order with inherited boxes and
  ## resources resolved.
  let cat = d.catalog()
  let pagesRef = cat.dictGet("Pages")
  if pagesRef.kind != coRef:
    pdfFail("PDF catalog missing /Pages reference")
  result = @[]
  d.collectPages(pagesRef, CosObj(kind: coNull), CosObj(kind: coNull),
    0, result)

proc cloneDirect(b: var PdfBuilder, d: var PdfDoc, v: CosObj,
    remap: var Table[int, int], depth: int): CosObj
proc cloneTarget(b: var PdfBuilder, d: var PdfDoc, v: CosObj,
    remap: var Table[int, int], depth: int): int =
  ## Store a resolved donor value under a fresh number; return it.
  if v.kind == coStream:
    var keys: seq[string] = @[]
    var vals: seq[CosObj] = @[]
    for i, k in v.streamDict:
      if k == "Length":
        continue
      keys.add(k)
      vals.add(b.cloneDirect(d, v.streamVals[i], remap, depth + 1))
    return b.addStream(CosObj(kind: coDict, keys: keys, vals: vals),
      v.raw)
  b.addValue(b.cloneDirect(d, v, remap, depth + 1))

proc cloneDirect(b: var PdfBuilder, d: var PdfDoc, v: CosObj,
    remap: var Table[int, int], depth: int): CosObj =
  ## Deep-copy a donor value, remapping indirect references to fresh
  ## numbers (resolved once, shared on repeat visits).
  if depth > d.limits.maxWalkDepth:
    pdfFail("page object graph too deep (possible reference cycle)")
  case v.kind
  of coRef:
    if remap.hasKey(v.refNum):
      return CosObj(kind: coRef, refNum: remap[v.refNum], refGen: 0)
    let target = d.resolve(v)
    let num = b.cloneTarget(d, target, remap, depth)
    remap[v.refNum] = num
    CosObj(kind: coRef, refNum: num, refGen: 0)
  of coArray:
    var items: seq[CosObj] = @[]
    for item in v.items:
      items.add(b.cloneDirect(d, item, remap, depth + 1))
    CosObj(kind: coArray, items: items)
  of coDict:
    var keys: seq[string] = @[]
    var vals: seq[CosObj] = @[]
    for i, k in v.keys:
      keys.add(k)
      vals.add(b.cloneDirect(d, v.vals[i], remap, depth + 1))
    CosObj(kind: coDict, keys: keys, vals: vals)
  of coStream:
    var keys: seq[string] = @[]
    var vals: seq[CosObj] = @[]
    for i, k in v.streamDict:
      keys.add(k)
      vals.add(b.cloneDirect(d, v.streamVals[i], remap, depth + 1))
    CosObj(kind: coStream, streamDict: keys, streamVals: vals,
      raw: v.raw)
  else:
    v

proc copyPage*(b: var PdfBuilder, donor: var PdfDoc,
    index: int): int =
  ## Transplant donor page `index` (0-based, page-tree order) into
  ## `b`; returns the new page object number. The copy carries an
  ## explicit /MediaBox and /Resources, so it never depends on the
  ## donor page tree.
  if donor.crypt.present:
    pdfFail("merge supports unencrypted donors only (page " & $index &
      " of an encrypted file)")
  let pages = donor.pageRefs()
  if index < 0 or index >= pages.len:
    pdfFail("page index " & $index & " out of range (0.." &
      $(pages.len - 1) & ")")
  let p = pages[index]
  let pdict = donor.resolve(p.pageRef)
  if pdict.kind != coDict:
    pdfFail("page tree leaf is not a dictionary")
  var remap = initTable[int, int]()
  var keys: seq[string] = @[]
  var vals: seq[CosObj] = @[]
  for i, k in pdict.keys:
    if k == "Parent":
      continue
    keys.add(k)
    vals.add(b.cloneDirect(donor, pdict.vals[i], remap, 0))
  var page = CosObj(kind: coDict, keys: keys, vals: vals)
  if page.dictGet("MediaBox").kind == coNull:
    page.keys.add("MediaBox")
    page.vals.add(b.cloneDirect(donor, p.mediaBox, remap, 0))
  if page.dictGet("Resources").kind == coNull:
    page.keys.add("Resources")
    if p.resources.kind == coDict:
      page.vals.add(b.cloneDirect(donor, p.resources, remap, 0))
    else:
      page.vals.add(CosObj(kind: coDict, keys: @[], vals: @[]))
  page.keys.add("Parent")
  page.vals.add(CosObj(kind: coRef, refNum: pagesNum, refGen: 0))
  b.adoptPage(page)

proc extractPages*(donor: var PdfDoc, pages: seq[int]): string =
  ## Fresh file with `pages` (0-based donor indexes, in the given
  ## order, repeats allowed).
  if pages.len == 0:
    pdfFail("extractPages needs at least one page index")
  var b = newPdfBuilder()
  for p in pages:
    discard b.copyPage(donor, p)
  b.buildPdf()

proc mergePdfs*(donors: var seq[PdfDoc]): string =
  ## Fresh file concatenating every page of each donor in order.
  if donors.len == 0:
    pdfFail("mergePdfs needs at least one document")
  var b = newPdfBuilder()
  for i in 0 ..< donors.len:
    let n = donors[i].pageCount()
    for p in 0 ..< n:
      discard b.copyPage(donors[i], p)
  b.buildPdf()
