## XFDF import/export (M17): form values + markup annotations.
##
## Subset, documented here: fields round-trip name/value (text one
## <value>; choice multi-select one <value> per export; buttons the
## on-state or "Off"); annotations round-trip text, square, highlight
## (quadpoints), ink (strokes) and URI links. Internal-link targets
## export as an opendocs `dest-page` extension attribute (0-based) and
## import restores them; anything else on a link is rect-only.
## Signature, pushbutton and unknown field values fail loudly on import.
## No JavaScript, no XFA, ever. Dates/flags/colors are not exchanged.
##
## `exportXfdf` reads; `importXfdf(base, xfdf)` returns new file bytes
## (fields via the string fill chain, annots appended through an
## incremental update). Malformed XFDF fails, never partial-applies:
## the base is untouched until the whole packet parses.

import std/strutils
import std/tables
import openparser/xml
import ./types
import ./lexer
import ./cos
import ./docmodel
import ./forms
import ./annotread
import ./organize

proc xmlEscape(s: string): string =
  result = ""
  for c in s:
    case c
    of '&': result.add("&amp;")
    of '<': result.add("&lt;")
    of '>': result.add("&gt;")
    of '"': result.add("&quot;")
    of '\'': result.add("&apos;")
    else: result.add(c)

proc localTag(tag: string): string =
  let k = tag.rfind(':')
  if k < 0: tag else: tag[k + 1 .. ^1]

proc kidElems(n: XmlNode): seq[XmlNode] =
  result = @[]
  if n.kind != xnElement:
    return
  for c in n.children:
    if c.kind == xnElement:
      result.add(c)

proc elemText(n: XmlNode): string =
  result = ""
  if n.kind != xnElement:
    return
  for c in n.children:
    if c.kind == xnText:
      result.add(c.text)

proc findChild(n: XmlNode, name: string): XmlNode =
  for c in n.kidElems():
    if localTag(c.tag) == name:
      return c
  nil

proc parseRect(s: string): array[4, float64] =
  let parts = s.split(',')
  if parts.len != 4:
    pdfFail("XFDF rect needs 4 comma-separated numbers")
  try:
    [parseFloat(parts[0]), parseFloat(parts[1]),
      parseFloat(parts[2]), parseFloat(parts[3])]
  except ValueError:
    pdfFail("XFDF rect holds a non-number")

proc exportXfdf*(d: var PdfDoc): string =
  ## Fields + supported annotations as an XFDF 1.0 packet.
  result = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" &
    "<xfdf xmlns=\"http://ns.adobe.com/xfdf/\" xml:space=\"preserve\">\n<fields>\n"
  for f in d.formFields():
    result.add("<field name=\"" & xmlEscape(f.name) & "\">\n")
    case f.kind
    of fkText:
      result.add("<value>" & xmlEscape(f.value) & "</value>\n")
    of fkCheckbox, fkRadio:
      # Unchecked buttons read as "" (none/Off); XFDF spells that Off.
      result.add("<value>" & xmlEscape(if f.value.len > 0: f.value
        else: "Off") & "</value>\n")
    of fkDropdown, fkListBox:
      if "\n" in f.value:
        for v in f.value.split('\n'):
          result.add("<value>" & xmlEscape(v) & "</value>\n")
      else:
        result.add("<value>" & xmlEscape(f.value) & "</value>\n")
    of fkSignature, fkPushButton, fkUnknown:
      discard
    result.add("</field>\n")
  result.add("</fields>\n<annots>\n")
  for (page, a) in d.docAnnots():
    let r = $a.rect[0] & "," & $a.rect[1] & "," & $a.rect[2] & "," &
      $a.rect[3]
    case a.subtype
    of "Text":
      result.add("<text page=\"" & $page & "\" rect=\"" & r &
        "\" title=\"" & xmlEscape(a.author) & "\">" &
        xmlEscape(a.contents) & "</text>\n")
    of "Square":
      result.add("<square page=\"" & $page & "\" rect=\"" & r & "\">" &
        xmlEscape(a.contents) & "</square>\n")
    of "Highlight":
      var q = ""
      for i, qp in a.quadPoints:
        if i > 0: q.add(";")
        q.add($qp[0] & "," & $qp[1] & "," & $qp[2] & "," & $qp[3] &
          "," & $qp[4] & "," & $qp[5] & "," & $qp[6] & "," & $qp[7])
      result.add("<highlight page=\"" & $page & "\" rect=\"" & r &
        "\" quadpoints=\"" & q & "\">" & xmlEscape(a.contents) &
        "</highlight>\n")
    of "Ink":
      result.add("<ink page=\"" & $page & "\" rect=\"" & r & "\">")
      for st in a.inkList:
        var p = ""
        for i in countup(0, st.len - 1, 2):
          if i > 0: p.add(";")
          p.add($st[i] & "," & $st[i + 1])
        result.add("<gesture>" & p & "</gesture>")
      result.add(xmlEscape(a.contents) & "</ink>\n")
    of "Link":
      if a.uri.len > 0:
        result.add("<link page=\"" & $page & "\" rect=\"" & r &
          "\" href=\"" & xmlEscape(a.uri) & "\"/>\n")
      elif a.destPage >= 0:
        result.add("<link page=\"" & $page & "\" rect=\"" & r &
          "\" dest-page=\"" & $a.destPage & "\"/>\n")
    else:
      discard
  result.add("</annots>\n</xfdf>\n")

proc importXfdf*(base, xfdf: string): string =
  ## New file bytes with the packet's field values applied and its
  ## annots appended. Fields apply first (string fill chain), then one
  ## incremental update carries the new annotations.
  var root: XmlNode
  try:
    root = fromXml(xfdf)
  except CatchableError as e:
    pdfFail("malformed XFDF packet (" & e.msg & ")")
  if root == nil or localTag(root.tag) != "xfdf":
    pdfFail("XFDF packet has no <xfdf> root")
  result = base
  let fields = root.findChild("fields")
  if fields != nil:
    for f in fields.kidElems():
      if localTag(f.tag) != "field":
        continue
      let name = f.attrs.getOrDefault("name", "")
      if name.len == 0:
        pdfFail("XFDF <field> without a name")
      var vals: seq[string] = @[]
      for v in f.kidElems():
        if localTag(v.tag) == "value":
          vals.add(v.elemText())
      var dd = openDoc(result)
      var found = false
      var kind = fkUnknown
      for f in dd.formFields():
        if f.name == name:
          kind = f.kind
          found = true
          break
      if not found:
        pdfFail("XFDF field '" & name & "' not in this document")
      case kind
      of fkText:
        result = fillText(result, name,
          if vals.len > 0: vals[0] else: "")
      of fkCheckbox:
        let raw = if vals.len > 0: vals[0] else: "Off"
        # Foreign packets spell unchecked as "" or omit the value.
        if raw == "Off" or raw == "":
          result = resetFields(result, @[name])
        else:
          result = setCheck(result, name, true)
          var dd2 = openDoc(result)
          if getField(dd2, name).value != raw:
            pdfFail("XFDF value '" & raw &
              "' is not this checkbox's on-state")
      of fkRadio:
        let raw = if vals.len > 0: vals[0] else: "Off"
        if raw == "Off" or raw == "":
          result = resetFields(result, @[name])
        else:
          result = selectRadio(result, name, raw)
      of fkDropdown, fkListBox:
        if vals.len > 1:
          result = selectChoices(result, name, vals)
        elif vals.len == 1 and vals[0].len > 0:
          result = selectChoice(result, name, vals[0])
        else:
          result = resetFields(result, @[name])
      of fkSignature, fkPushButton, fkUnknown:
        pdfFail("XFDF cannot fill field '" & name & "' (unsupported kind)")
  let annots = root.findChild("annots")
  if annots == nil:
    return
  var specs: seq[tuple[page: int, dict: CosObj]] = @[]
  for a in annots.kidElems():
    let t = localTag(a.tag)
    let pageStr = a.attrs.getOrDefault("page", "")
    var page = -1
    try:
      page = parseInt(pageStr)
    except ValueError:
      pdfFail("XFDF annot has a bad page '" & pageStr & "'")
    if page < 0:
      pdfFail("XFDF annot page out of range")
    let rect =
      try: parseRect(a.attrs.getOrDefault("rect", ""))
      except PdfError as e:
        pdfFail("XFDF annot: " & e.msg)
    let x1 = min(rect[0], rect[2])
    let y1 = min(rect[1], rect[3])
    let x2 = max(rect[0], rect[2])
    let y2 = max(rect[1], rect[3])
    let r = CosObj(kind: coArray, items: @[
      CosObj(kind: coFloat, fval: x1), CosObj(kind: coFloat, fval: y1),
      CosObj(kind: coFloat, fval: x2), CosObj(kind: coFloat, fval: y2)])
    case t
    of "text":
      specs.add((page, CosObj(kind: coDict,
        keys: @["Type", "Subtype", "Rect", "Contents", "T"],
        vals: @[CosObj(kind: coName, name: "Annot"),
          CosObj(kind: coName, name: "Text"), r,
          CosObj(kind: coStr, sval: a.elemText()),
          CosObj(kind: coStr,
            sval: a.attrs.getOrDefault("title", ""))])))
    of "square":
      specs.add((page, CosObj(kind: coDict,
        keys: @["Type", "Subtype", "Rect", "Contents"],
        vals: @[CosObj(kind: coName, name: "Annot"),
          CosObj(kind: coName, name: "Square"), r,
          CosObj(kind: coStr, sval: a.elemText())])))
    of "highlight":
      let q = a.attrs.getOrDefault("quadpoints", "")
      var qp: seq[array[8, float64]] = @[]
      if q.len > 0:
        for quad in q.split(';'):
          let ns = quad.split(',')
          if ns.len != 8:
            pdfFail("XFDF highlight quad needs 8 numbers")
          try:
            qp.add([parseFloat(ns[0]), parseFloat(ns[1]),
              parseFloat(ns[2]), parseFloat(ns[3]), parseFloat(ns[4]),
              parseFloat(ns[5]), parseFloat(ns[6]), parseFloat(ns[7])])
          except ValueError:
            pdfFail("XFDF highlight quad holds a non-number")
      var flat: seq[CosObj] = @[]
      for quad in qp:
        for v in quad:
          flat.add(CosObj(kind: coFloat, fval: v))
      specs.add((page, CosObj(kind: coDict,
        keys: @["Type", "Subtype", "Rect", "QuadPoints", "Contents"],
        vals: @[CosObj(kind: coName, name: "Annot"),
          CosObj(kind: coName, name: "Highlight"), r,
          CosObj(kind: coArray, items: flat),
          CosObj(kind: coStr, sval: a.elemText())])))
    of "ink":
      var strokes: seq[CosObj] = @[]
      for g in a.kidElems():
        if localTag(g.tag) != "gesture":
          continue
        var pts: seq[CosObj] = @[]
        for pair in g.elemText().split(';'):
          let ns = pair.split(',')
          if ns.len != 2:
            pdfFail("XFDF ink point needs 2 numbers")
          try:
            pts.add(CosObj(kind: coFloat, fval: parseFloat(ns[0])))
            pts.add(CosObj(kind: coFloat, fval: parseFloat(ns[1])))
          except ValueError:
            pdfFail("XFDF ink point holds a non-number")
        strokes.add(CosObj(kind: coArray, items: pts))
      specs.add((page, CosObj(kind: coDict,
        keys: @["Type", "Subtype", "Rect", "InkList", "Contents"],
        vals: @[CosObj(kind: coName, name: "Annot"),
          CosObj(kind: coName, name: "Ink"), r,
          CosObj(kind: coArray, items: strokes),
          CosObj(kind: coStr, sval: a.elemText())])))
    of "link":
      let href = a.attrs.getOrDefault("href", "")
      if href.len > 0:
        specs.add((page, CosObj(kind: coDict,
          keys: @["Type", "Subtype", "Rect", "Border", "A"],
          vals: @[CosObj(kind: coName, name: "Annot"),
            CosObj(kind: coName, name: "Link"), r,
            CosObj(kind: coArray, items: @[
              CosObj(kind: coInt, ival: 0),
              CosObj(kind: coInt, ival: 0),
              CosObj(kind: coInt, ival: 1)]),
            CosObj(kind: coDict, keys: @["S", "URI"],
              vals: @[CosObj(kind: coName, name: "URI"),
                CosObj(kind: coStr, sval: href)])])))
      else:
        specs.add((page, CosObj(kind: coDict,
          keys: @["Type", "Subtype", "Rect", "Border", "Dest"],
          vals: @[CosObj(kind: coName, name: "Annot"),
            CosObj(kind: coName, name: "Link"), r,
            CosObj(kind: coArray, items: @[
              CosObj(kind: coInt, ival: 0),
              CosObj(kind: coInt, ival: 0),
              CosObj(kind: coInt, ival: 1)]),
            CosObj(kind: coStr,
              sval: a.attrs.getOrDefault("dest", ""))])))
    else:
      pdfFail("unsupported XFDF annot <" & t & ">")
  if specs.len == 0:
    return
  result = addAnnotsUpdate(result, specs)
