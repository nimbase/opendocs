## Tagged PDF structure tree (ISO 32000 §14.7).
##
## structTree returns the /StructTreeRoot as a typed tree: structure
## elements with their /S type (RoleMap applied), MCR leaves carrying
## (page, MCID) pairs, OBJR leaves for object references, and per-node
## /Alt, /ActualText, /T plus shallow /A attributes. /K integers are
## MCIDs; /ParentTree is not traversed beyond what /K needs. Absent
## trees read as an empty root. Cycles fail loudly; depth and item
## counts are bounded.

import std/tables
import ./types
import ./lexer
import ./cos
import ./docmodel
import ./names
import ./catalog

type
  PdfStructElem* = object
    structType*: string ## /S with /RoleMap applied ("" on the root/MCR)
    kids*: seq[PdfStructElem]
    mcid*: int ## /MCID, -1 when absent
    pageIndex*: int ## via /Pg, -1 when absent/unresolvable
    alt*, actualText*, title*: string
    attrs*: seq[tuple[key, value: string]]

proc structString(v: CosObj): string =
  case v.kind
  of coStr: decodeTextString(v.sval)
  of coName: v.name
  else: ""

proc attrString(v: CosObj): tuple[ok: bool, s: string] =
  case v.kind
  of coStr: (true, v.sval)
  of coName: (true, v.name)
  of coInt: (true, $v.ival)
  of coFloat: (true, $v.fval)
  of coBool: (true, $v.bval)
  else: (false, "")

proc readStructKids(d: var PdfDoc, k: CosObj, roleMap: Table[string, string],
    pageIdx: Table[int, int], depth: int, seen: var Table[int, bool],
    count: var int): seq[PdfStructElem]

proc readStructElem(d: var PdfDoc, nodeVal: CosObj,
    roleMap: Table[string, string], pageIdx: Table[int, int], depth: int,
    seen: var Table[int, bool], count: var int): PdfStructElem =
  if depth > d.limits.maxWalkDepth:
    pdfFail("structure tree exceeds nesting depth")
  inc count
  if count > d.limits.maxOutlineItems:
    pdfFail("structure tree exceeds item limit")
  let node = d.resolve(nodeVal)
  if node.kind != coDict:
    pdfFail("structure element is not a dictionary")
  if nodeVal.kind == coRef:
    if seen.hasKey(nodeVal.refNum):
      pdfFail("structure tree cycle at object " & $nodeVal.refNum)
    seen[nodeVal.refNum] = true
  let t = node.dictGet("Type")
  if t.kind == coName and t.name == "MCR":
    # Marked-content reference: (page, MCID) leaf.
    result = PdfStructElem(mcid: -1, pageIndex: -1)
    let mc = node.dictGet("MCID")
    if mc.kind == coInt:
      result.mcid = mc.ival
    let pg = node.dictGet("Pg")
    if pg.kind == coRef and pageIdx.hasKey(pg.refNum):
      result.pageIndex = pageIdx[pg.refNum]
    return
  if t.kind == coName and t.name == "OBJR":
    result = PdfStructElem(structType: "OBJR", mcid: -1, pageIndex: -1)
    let pg = node.dictGet("Pg")
    if pg.kind == coRef and pageIdx.hasKey(pg.refNum):
      result.pageIndex = pageIdx[pg.refNum]
    return
  result = PdfStructElem(mcid: -1, pageIndex: -1)
  let s = node.dictGet("S")
  if s.kind == coName:
    result.structType = s.name
    if roleMap.hasKey(s.name):
      result.structType = roleMap[s.name]
  result.alt = structString(node.dictGet("Alt"))
  result.actualText = structString(node.dictGet("ActualText"))
  result.title = structString(node.dictGet("T"))
  let pg = node.dictGet("Pg")
  if pg.kind == coRef and pageIdx.hasKey(pg.refNum):
    result.pageIndex = pageIdx[pg.refNum]
  let mc = node.dictGet("MCID")
  if mc.kind == coInt:
    result.mcid = mc.ival
  var attrs = node.dictGet("A")
  if attrs.kind == coRef:
    attrs = d.resolve(attrs)
  if attrs.kind == coDict:
    for i, k in attrs.keys:
      let (ok, s) = attrString(attrs.vals[i])
      if ok:
        result.attrs.add((k, s))
  elif attrs.kind == coArray:
    for item in attrs.items:
      var ad = item
      if ad.kind == coRef:
        ad = d.resolve(ad)
      if ad.kind != coDict:
        continue
      for i, k in ad.keys:
        let (ok, s) = attrString(ad.vals[i])
        if ok:
          result.attrs.add((k, s))
  result.kids = d.readStructKids(node.dictGet("K"), roleMap, pageIdx,
    depth + 1, seen, count)

proc readStructKids(d: var PdfDoc, k: CosObj,
    roleMap: Table[string, string], pageIdx: Table[int, int], depth: int,
    seen: var Table[int, bool], count: var int): seq[PdfStructElem] =
  var v = k
  if v.kind == coRef:
    v = d.resolve(v)
  case v.kind
  of coDict:
    result.add(d.readStructElem(k, roleMap, pageIdx, depth, seen, count))
  of coArray:
    for item in v.items:
      var e = item
      if e.kind == coRef:
        e = d.resolve(e)
      case e.kind
      of coDict:
        result.add(d.readStructElem(item, roleMap, pageIdx, depth, seen,
          count))
      of coInt:
        # Bare MCID: leaf on the ambient page (unknown here: -1).
        result.add(PdfStructElem(mcid: e.ival, pageIndex: -1))
      else:
        pdfFail("structure tree /K entry is not a dict or MCID")
  of coInt:
    result.add(PdfStructElem(mcid: v.ival, pageIndex: -1))
  of coNull:
    discard
  else:
    pdfFail("structure tree /K is not a dict, array or MCID")

proc structTree*(d: var PdfDoc): PdfStructElem =
  ## The /StructTreeRoot as a tree (empty root when absent). MCR kids
  ## become leaves with mcid/pageIndex; /RoleMap maps each /S.
  result = PdfStructElem(mcid: -1, pageIndex: -1)
  let root = d.catalog().dictGet("StructTreeRoot")
  if root.kind == coNull:
    return
  var resolved = root
  if resolved.kind == coRef:
    resolved = d.resolve(resolved)
  if resolved.kind != coDict:
    pdfFail("catalog /StructTreeRoot is not a dictionary")
  var roleMap = initTable[string, string]()
  let rm = resolved.dictGet("RoleMap")
  if rm.kind == coDict or rm.kind == coRef:
    let r = d.resolve(rm)
    if r.kind == coDict:
      for i, k in r.keys:
        if r.vals[i].kind == coName:
          roleMap[k] = r.vals[i].name
  let pageIdx = d.pageRefIndex()
  var seen = initTable[int, bool]()
  var count = 0
  result.kids = d.readStructKids(resolved.dictGet("K"), roleMap, pageIdx,
    0, seen, count)
