## Optional content groups / layers (ISO 32000 §8.11).
##
## docLayers reports the catalog's /OCProperties /OCGs with the default
## config /D applied as on/off booleans. Visibility expressions (/VE)
## and JavaScript (/JS) are never evaluated: /OCMD handling needs a
## renderer and JS is out of scope everywhere. /Configs beyond /D are
## ignored. ON/OFF matching is by indirect object number; direct (inline)
## OCG dicts fall back to the /D /BaseState default, documented here.
## Absent /OCProperties reads empty. Malformed values fail loudly naming
## the object.

import std/strutils
import ./lexer
import ./cos
import ./docmodel
import ./catalog

type
  PdfLayer* = object
    name*: string ## /Name decoded, "" when absent
    on*: bool ## default-config state (BaseState + ON/OFF lists)
    intent*: string ## /Intent name, slash-joined when an array, "" when absent
    usage*: string ## /Usage category keys comma-joined, "" when absent/none
    objNum*: int ## OCG object number, -1 for direct dicts

proc intentString(node: CosObj, label: string): string =
  let v = node.dictGet("Intent")
  case v.kind
  of coNull:
    ""
  of coName:
    v.name
  of coArray:
    var parts: seq[string] = @[]
    for it in v.items:
      if it.kind != coName:
        pdfFail(label & " /Intent entry is not a name")
      parts.add(it.name)
    parts.join("/")
  else:
    pdfFail(label & " /Intent is not a name or array")

proc usageString(node: CosObj, label: string): string =
  let u = node.dictGet("Usage")
  case u.kind
  of coNull:
    ""
  of coDict:
    u.keys.join(",")
  else:
    pdfFail(label & " /Usage is not a dictionary")

proc refSet(d: var PdfDoc, v: CosObj, what: string): tuple[nums: seq[int], has: bool] =
  ## Object numbers listed in a /ON or /OFF array. Direct dict entries
  ## cannot be matched by number and are ignored (documented above).
  var arr = v
  if arr.kind == coRef:
    arr = d.resolve(arr)
  if arr.kind == coNull:
    return (@[], false)
  if arr.kind != coArray:
    pdfFail(what & " is not an array")
  for it in arr.items:
    if it.kind == coRef:
      result.nums.add(it.refNum)
  result.has = true

proc docLayers*(d: var PdfDoc): seq[PdfLayer] =
  ## Every OCG in /OCProperties /OCGs with default-config state.
  ## Empty when the catalog has no /OCProperties.
  var props = d.catalog().dictGet("OCProperties")
  if props.kind == coNull:
    return @[]
  if props.kind == coRef:
    props = d.resolve(props)
  if props.kind != coDict:
    pdfFail("catalog /OCProperties is not a dictionary")
  var ocgs = props.dictGet("OCGs")
  if ocgs.kind == coRef:
    ocgs = d.resolve(ocgs)
  if ocgs.kind == coNull:
    return @[]
  if ocgs.kind != coArray:
    pdfFail("catalog /OCProperties /OCGs is not an array")
  var dflt = props.dictGet("D")
  if dflt.kind == coRef:
    dflt = d.resolve(dflt)
  var baseOn = true
  var onNums: seq[int] = @[]
  var offNums: seq[int] = @[]
  if dflt.kind == coDict:
    let bs = dflt.dictGet("BaseState")
    if bs.kind == coName:
      if bs.name == "ON":
        baseOn = true
      elif bs.name == "OFF":
        baseOn = false
      else:
        pdfFail("catalog /OCProperties /D /BaseState is not ON or OFF")
    elif bs.kind != coNull:
      pdfFail("catalog /OCProperties /D /BaseState is not a name")
    onNums = d.refSet(dflt.dictGet("ON"), "catalog /OCProperties /D /ON").nums
    offNums = d.refSet(dflt.dictGet("OFF"), "catalog /OCProperties /D /OFF").nums
  elif dflt.kind != coNull:
    pdfFail("catalog /OCProperties /D is not a dictionary")
  for i, item in ocgs.items:
    if result.len >= d.limits.maxOutlineItems:
      pdfFail("optional content exceeds item limit")
    let label = "optional content group " & $i
    let refNum = if item.kind == coRef: item.refNum else: -1
    let node = d.resolve(item)
    if node.kind != coDict:
      pdfFail(label & " is not a dictionary")
    var name = ""
    let n = node.dictGet("Name")
    if n.kind == coStr:
      name = decodeTextString(n.sval)
    elif n.kind != coNull:
      pdfFail(label & " /Name is not a string")
    var on = baseOn
    if refNum >= 0:
      var inOff = false
      var inOn = false
      for o in offNums:
        if o == refNum:
          inOff = true
          break
      for o in onNums:
        if o == refNum:
          inOn = true
          break
      if inOff:
        on = false
      elif inOn:
        on = true
    result.add(PdfLayer(name: name, on: on,
      intent: intentString(node, label),
      usage: usageString(node, label), objNum: refNum))

proc layerOCGs*(d: var PdfDoc): seq[tuple[name: string, objNum: int]] =
  ## (name, object number) for every OCG, in /OCGs order.
  ## Direct dicts report objNum -1.
  for l in d.docLayers():
    result.add((l.name, l.objNum))
