## Name trees and number trees (ISO 32000 §7.9.6–7.9.7).
##
## One shared node walk serves outlines (/Names /Dests name tree plus
## the older catalog /Dests dict), page labels (/PageLabels number
## tree) and layers. Intermediate nodes carry /Kids, leaves carry
## /Names (string keys) or /Nums (integer keys); values stay unresolved
## (they may be refs the caller resolves with context). Cycles fail
## loudly via a visited set; depth and item counts are bounded.

import std/tables
import ./types
import ./lexer
import ./cos
import ./docmodel

proc treeNodes(d: var PdfDoc, root: CosObj): seq[CosObj] =
  ## Every node dictionary under a tree root, parents before children.
  var seen = initTable[int, bool]()
  var stack: seq[(CosObj, int)] = @[(root, 0)]
  while stack.len > 0:
    let (nodeVal, depth) = stack.pop()
    if depth > d.limits.maxWalkDepth:
      pdfFail("name/number tree exceeds nesting depth")
    let node = d.resolve(nodeVal)
    if node.kind != coDict:
      pdfFail("name/number tree node is not a dictionary")
    if nodeVal.kind == coRef:
      if seen.hasKey(nodeVal.refNum):
        pdfFail("name/number tree cycle at object " & $nodeVal.refNum)
      seen[nodeVal.refNum] = true
    result.add(node)
    let kids = node.dictGet("Kids")
    if kids.kind == coArray:
      for i in countdown(kids.items.len - 1, 0):
        stack.add((kids.items[i], depth + 1))
    elif kids.kind != coNull:
      pdfFail("name/number tree /Kids is not an array")

proc nameTreePairs*(d: var PdfDoc, root: CosObj):
    seq[tuple[name: string, value: CosObj]] =
  ## All (name, value) pairs under a name-tree root, in tree order.
  ## Values are unresolved; /Limits is informational, not enforced.
  var count = 0
  for node in d.treeNodes(root):
    let names = node.dictGet("Names")
    if names.kind == coNull:
      continue
    if names.kind != coArray:
      pdfFail("name tree /Names is not an array")
    if names.items.len mod 2 != 0:
      pdfFail("name tree /Names must hold key/value pairs")
    var i = 0
    while i < names.items.len:
      let k = names.items[i]
      if k.kind != coStr:
        pdfFail("name tree key is not a string")
      result.add((k.sval, names.items[i + 1]))
      inc count
      if count > d.limits.maxOutlineItems:
        pdfFail("name tree exceeds item limit")
      i += 2

proc numberTreePairs*(d: var PdfDoc, root: CosObj):
    seq[tuple[num: int, value: CosObj]] =
  ## All (number, value) pairs under a number-tree root, in tree order.
  var count = 0
  for node in d.treeNodes(root):
    let nums = node.dictGet("Nums")
    if nums.kind == coNull:
      continue
    if nums.kind != coArray:
      pdfFail("number tree /Nums is not an array")
    if nums.items.len mod 2 != 0:
      pdfFail("number tree /Nums must hold key/value pairs")
    var i = 0
    while i < nums.items.len:
      let k = nums.items[i]
      if k.kind != coInt:
        pdfFail("number tree key is not an integer")
      result.add((k.ival, nums.items[i + 1]))
      inc count
      if count > d.limits.maxOutlineItems:
        pdfFail("number tree exceeds item limit")
      i += 2

proc pageRefIndex*(d: var PdfDoc): Table[int, int] =
  ## Indirect object number -> 0-based page index, via the /Kids walk.
  ## Shared by outline/annotation/structure destination resolution.
  let cat = d.catalog()
  let pagesRef = cat.dictGet("Pages")
  if pagesRef.kind != coRef:
    pdfFail("PDF catalog missing /Pages reference")
  let pages = d.resolve(pagesRef)
  if pages.kind != coDict:
    pdfFail("page tree root is not a dictionary")
  let top = pages.dictGet("Kids")
  if top.kind != coArray:
    pdfFail("page tree root has no /Kids array")
  if top.items.len > d.limits.maxPages:
    pdfFail("page count exceeds limit")
  var seen = initTable[int, bool]()
  var stack: seq[(CosObj, int)] = @[]
  for i in countdown(top.items.len - 1, 0):
    stack.add((top.items[i], 1))
  while stack.len > 0:
    let (nodeRef, depth) = stack.pop()
    if depth > d.limits.maxWalkDepth:
      pdfFail("page tree exceeds nesting depth")
    if nodeRef.kind != coRef:
      pdfFail("page tree kid is not an indirect reference")
    if seen.hasKey(nodeRef.refNum):
      pdfFail("page tree cycle at object " & $nodeRef.refNum)
    seen[nodeRef.refNum] = true
    let node = d.resolve(nodeRef)
    if node.kind != coDict:
      pdfFail("page tree node is not a dictionary")
    let kids = node.dictGet("Kids")
    if kids.kind == coArray:
      if result.len + kids.items.len > d.limits.maxPages:
        pdfFail("page count exceeds limit")
      for i in countdown(kids.items.len - 1, 0):
        stack.add((kids.items[i], depth + 1))
    else:
      result[nodeRef.refNum] = result.len
