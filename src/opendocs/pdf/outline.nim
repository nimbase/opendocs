## Document outlines / bookmarks (ISO 32000 §12.3.3).
##
## docOutlines walks /Outlines /First//Next with the item tree's /Count
## openness (positive means expanded). Destinations resolve against the
## page tree: explicit [page /XYZ ...] arrays, named strings via the
## /Names /Dests name tree (falling back to the older catalog /Dests
## dict), and /A actions (/GoTo, /GoToR, /URI, /Named). Anything else
## surfaces with its raw kind and empty target rather than guessed.
## Widget annotations are not outlines; see annotread.

import std/tables
import ./types
import ./lexer
import ./cos
import ./docmodel
import ./names
import ./catalog

type
  PdfOutline* = object
    title*: string
    dest*: string ## named destination, or the remote file for GoToR
    pageIndex*: int ## resolved 0-based page, -1 when not in this document
    kind*: string ## dest, actionGoTo, actionGoToR, actionURI,
      ## actionNamed, unknown
    uri*: string ## for /URI actions
    open*: bool ## /Count positive when the item has children
    children*: seq[PdfOutline]

proc outlineTitle(node: CosObj): string =
  let t = node.dictGet("Title")
  if t.kind == coStr:
    return decodeTextString(t.sval)
  ""

proc namedDest(d: var PdfDoc, name: string): CosObj =
  ## Named destination value: /Names /Dests tree first, then the older
  ## catalog /Dests dict. coNull when unknown.
  let cat = d.catalog()
  let names = cat.dictGet("Names")
  if names.kind == coDict or names.kind == coRef:
    let resolved = d.resolve(names)
    if resolved.kind == coDict:
      let tree = resolved.dictGet("Dests")
      if tree.kind == coDict or tree.kind == coRef:
        for (n, v) in d.nameTreePairs(tree):
          if n == name:
            return v
  let old = cat.dictGet("Dests")
  if old.kind == coDict or old.kind == coRef:
    let resolved = d.resolve(old)
    if resolved.kind == coDict:
      let v = resolved.dictGet(name)
      if v.kind != coNull:
        return v
  CosObj(kind: coNull)

proc destPageIndex*(d: var PdfDoc, dest: CosObj,
    pageIdx: Table[int, int]): int =
  ## Destination value -> page: explicit arrays ([pageRef /XYZ ...],
  ## possibly wrapped in a /D dict or a reference), or named strings
  ## resolved through /Names /Dests then the older /Dests dict. -1 when
  ## the target is not a page of this document (remote GoTo page
  ## numbers, unresolvable names, anything else).
  var v = dest
  if v.kind == coRef:
    v = d.resolve(v)
  if v.kind == coStr or v.kind == coName:
    let name = if v.kind == coStr: v.sval else: v.name
    v = d.namedDest(name)
    if v.kind == coNull:
      return -1
    if v.kind == coRef:
      v = d.resolve(v)
  if v.kind == coDict:
    v = v.dictGet("D")
    if v.kind == coRef:
      v = d.resolve(v)
  if v.kind != coArray or v.items.len == 0:
    return -1
  let head = v.items[0]
  if head.kind == coRef and pageIdx.hasKey(head.refNum):
    return pageIdx[head.refNum]
  -1

proc outlineDest(d: var PdfDoc, node: CosObj,
    pageIdx: Table[int, int]): tuple[kind, dest, uri: string,
    page: int] =
  ## (kind, dest, uri, page) for an outline item's /Dest//A.
  let dest = node.dictGet("Dest")
  if dest.kind != coNull:
    var name = ""
    if dest.kind == coStr:
      name = dest.sval
    elif dest.kind == coName:
      name = dest.name
    return ("dest", name, "", d.destPageIndex(dest, pageIdx))
  var a = node.dictGet("A")
  if a.kind == coRef:
    a = d.resolve(a)
  if a.kind != coDict:
    return ("unknown", "", "", -1)
  let s = a.dictGet("S")
  if s.kind != coName:
    return ("unknown", "", "", -1)
  case s.name
  of "GoTo":
    var v = a.dictGet("D")
    var name = ""
    if v.kind == coStr:
      name = v.sval
    elif v.kind == coName:
      name = v.name
    return ("actionGoTo", name, "", d.destPageIndex(v, pageIdx))
  of "GoToR":
    var file = ""
    let f = a.dictGet("F")
    if f.kind == coStr:
      file = f.sval
    elif f.kind == coDict:
      let u = f.dictGet("UF")
      if u.kind == coStr:
        file = u.sval
      else:
        let ff = f.dictGet("F")
        if ff.kind == coStr:
          file = ff.sval
    return ("actionGoToR", file, "", -1)
  of "URI":
    let u = a.dictGet("URI")
    if u.kind == coStr:
      return ("actionURI", "", u.sval, -1)
    return ("actionURI", "", "", -1)
  of "Named":
    let n = a.dictGet("N")
    if n.kind == coName:
      return ("actionNamed", n.name, "", -1)
    return ("actionNamed", "", "", -1)
  else:
    return (s.name, "", "", -1)

proc readOutlineItem(d: var PdfDoc, nodeVal: CosObj,
    pageIdx: Table[int, int], depth: int, seen: var Table[int, bool],
    count: var int): PdfOutline =
  if depth > d.limits.maxWalkDepth:
    pdfFail("outline exceeds nesting depth")
  inc count
  if count > d.limits.maxOutlineItems:
    pdfFail("outline exceeds item limit")
  let node = d.resolve(nodeVal)
  if node.kind != coDict:
    pdfFail("outline item is not a dictionary")
  if nodeVal.kind == coRef:
    if seen.hasKey(nodeVal.refNum):
      pdfFail("outline cycle at object " & $nodeVal.refNum)
    seen[nodeVal.refNum] = true
  let (kind, dest, uri, page) = d.outlineDest(node, pageIdx)
  result = PdfOutline(title: outlineTitle(node), dest: dest,
    pageIndex: page, kind: kind, uri: uri)
  let cnt = node.dictGet("Count")
  var kid = node.dictGet("First")
  if kid.kind == coRef:
    kid = d.resolve(kid)
    if kid.kind != coDict:
      pdfFail("outline /First is not a dictionary")
  if kid.kind == coDict:
    result.open = cnt.kind == coInt and cnt.ival > 0
    var k = node.dictGet("First")
    while k.kind == coRef or k.kind == coDict:
      let knode = d.resolve(k)
      if knode.kind != coDict:
        pdfFail("outline item is not a dictionary")
      result.children.add(d.readOutlineItem(k, pageIdx, depth + 1,
        seen, count))
      let nx = knode.dictGet("Next")
      if nx.kind == coNull:
        break
      if nx.kind != coRef and nx.kind != coDict:
        pdfFail("outline /Next is not a dictionary")
      k = nx

proc docOutlines*(d: var PdfDoc): seq[PdfOutline] =
  ## Top-level outline items (empty when the catalog has no /Outlines).
  ## Unresolvable targets read pageIndex -1 with the name kept in dest.
  let outlines = d.catalog().dictGet("Outlines")
  if outlines.kind == coNull:
    return @[]
  var root = outlines
  if root.kind == coRef:
    root = d.resolve(root)
  if root.kind != coDict:
    pdfFail("catalog /Outlines is not a dictionary")
  let pageIdx = d.pageRefIndex()
  var first = root.dictGet("First")
  if first.kind == coNull:
    return @[]
  var seen = initTable[int, bool]()
  var count = 0
  var k = first
  while k.kind == coRef or k.kind == coDict:
    let knode = d.resolve(k)
    if knode.kind != coDict:
      pdfFail("outline item is not a dictionary")
    result.add(d.readOutlineItem(k, pageIdx, 0, seen, count))
    let nx = knode.dictGet("Next")
    if nx.kind == coNull:
      break
    if nx.kind != coRef and nx.kind != coDict:
      pdfFail("outline /Next is not a dictionary")
    k = nx
