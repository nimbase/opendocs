## Copyright (c) 2026 nimbase (MIT, see LICENSE at repo root).
## Portions derived from excelize (https://github.com/qax-os/excelize,
## commit 0434413, 2026-09-18): Copyright (c) 2016-2026 The excelize
## Authors, Copyright (c) 2011-2017 Geoffrey J. Teale, BSD-3-Clause.
## SPDX-License-Identifier: MIT AND BSD-3-Clause
##
## Workbook part: package rels -> workbook path -> sheets, date system.
## Ports of excelize `getWorkbookPath`, `getWorkbookRelsPath`,
## `getWorksheetPath`, `workbookReader`, `getSheetMap`.

type
  XlsxRel = tuple[id, target, relType: string]

proc readRels(node: XmlNode): seq[XlsxRel] =
  for r in childElemsL(node, "Relationship"):
    result.add (optAttr(r, "Id"), optAttr(r, "Target"), optAttr(r, "Type"))

proc normPkgPath(t: string): string =
  ## zip-name normalization: backslashes to slashes, leading `/` off.
  result = t.replace("\\", "/")
  if result.startsWith("/"): result = result[1 .. ^1]

proc joinPkgPath(base, target: string): string =
  ## Resolve a rel target against its source part path (handles absolute
  ## `/xl/...` targets and `..` segments; ports `getWorksheetPath`).
  if target.startsWith("/"): return normPkgPath(target)
  let t = normPkgPath(target)
  let dirEnd = base.rfind('/')
  var segs: seq[string]
  if dirEnd >= 0:
    for s in base[0 ..< dirEnd].split('/'): segs.add s
  for s in t.split('/'):
    if s == "" or s == ".": continue
    elif s == "..":
      if segs.len > 0: discard segs.pop()
    else: segs.add s
  segs.join("/")

proc workbookPath(f: XlsxFile): string =
  ## Workbook part via `_rels/.rels` (`officeDocument`), else the
  ## conventional `xl/workbook.xml` fallback.
  let rels = readXmlPart(f, "_rels/.rels")
  if rels != nil:
    for r in readRels(rels):
      if r.relType.endsWith("/officeDocument"):
        return normPkgPath(r.target)
  "xl/workbook.xml"

proc loadWorkbook(f: XlsxFile) =
  ## Eager workbook parse: sheet order/ids/parts + date system.
  let wbPath = workbookPath(f)
  let root = readXmlPart(f, wbPath)
  if root == nil:
    raise newException(XlsxError, "missing required part: " & wbPath)
  if localName(root.tag) != "workbook":
    raise newException(XlsxError,
      wbPath & " root is <" & root.tag & ">, want <workbook>")
  let pr = firstChildL(root, "workbookPr")
  f.date1904 = boolAttr(pr, "date1904")
  let sheets = firstChildL(root, "sheets")
  if sheets == nil:
    raise newException(XlsxError, wbPath & " has no sheets")
  # Workbook rels map rId -> sheet part.
  let wbDirEnd = wbPath.rfind('/')
  let relsPath =
    if wbDirEnd < 0: "_rels/" & wbPath & ".rels"
    else: wbPath[0 .. wbDirEnd] & "_rels/" & wbPath[wbDirEnd + 1 .. ^1] &
      ".rels"
  var relTargets = initTable[string, string]()
  let relsNode = readXmlPart(f, relsPath)
  if relsNode != nil:
    for r in readRels(relsNode):
      relTargets[r.id] = joinPkgPath(wbPath, r.target)
  for s in childElemsL(sheets, "sheet"):
    let name = optAttr(s, "name")
    if name == "": continue # unnamed sheet entries carry no data
    let rid = optAttr(s, "r:id")
    f.sheetOrder.add name
    f.sheetIds[name] = intAttr(s, "sheetId", 0)
    if rid != "" and relTargets.hasKey(rid):
      f.sheetParts[name] = relTargets[rid]
    # else: chartsheet/dialogsheet or dangling ref; getters report it.

proc resolveSheetName*(f: XlsxFile, name: string): string =
  ## Canonical sheet name (case-insensitive, excelize parity).
  ## Raises XlsxError for unknown sheets.
  for n in f.sheetOrder:
    if n.cmpIgnoreCase(name) == 0: return n
  raise newException(XlsxError, "unknown sheet: " & name)

proc sheetPart*(f: XlsxFile, name: string): string =
  ## Sheet part path for a (possibly any-case) sheet name.
  let real = resolveSheetName(f, name)
  if not f.sheetParts.hasKey(real):
    raise newException(XlsxError,
      "sheet has no worksheet part: " & real)
  f.sheetParts[real]
