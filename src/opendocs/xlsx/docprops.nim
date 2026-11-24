## Copyright (c) 2026 nimbase (MIT, see LICENSE at repo root).
## Portions derived from excelize (https://github.com/qax-os/excelize,
## commit 0434413, 2026-09-18): Copyright (c) 2016-2026 The excelize
## Authors, Copyright (c) 2011-2017 Geoffrey J. Teale, BSD-3-Clause.
## SPDX-License-Identifier: MIT AND BSD-3-Clause
##
## Document properties (`docProps/` parts): core, application, custom.
##
## All values are flat strings, matching excelize's `docProps.go`: dates
## stay raw ISO 8601 (never parsed), custom `vt:*` typed values flatten
## to text with type-driven normalization (`bool` becomes
## "true"/"false"; integers, floats and filetimes keep their lexical
## text). That flattening loses type information by design.
##
## Lookups are by local name, not prefix (`dc:creator` and `creator`
## are the same; producers vary). Missing parts yield empty results,
## never an error, matching how `loadStyles` treats absent styles.
## Wrong roots fail loudly as `XlsxError`.
## `app.xml` `<TitlesOfParts>`/`<HeadingPairs>` describe sheets, not
## the document, so they are not duplicated: `getAppProps` surfaces
## the workbook sheet count under the `SheetCount` key instead.

type
  XlsxDocProps* = object
    title*, subject*, creator*, keywords*, description*, category*,
      contentStatus*, lastModifiedBy*, identifier*, language*,
      version*, revision*, created*, modified*: string

proc getDocProps*(f: XlsxFile): XlsxDocProps =
  ## Dublin Core from `docProps/core.xml`. Empty object when absent.
  let root = readXmlPart(f, "docProps/core.xml")
  if root == nil: return XlsxDocProps()
  if localName(root.tag) != "coreProperties":
    raise newException(XlsxError,
      "docProps/core.xml root is <" & root.tag &
      ">, want <coreProperties>")
  result = XlsxDocProps(
    title: childText(firstChildL(root, "title")),
    subject: childText(firstChildL(root, "subject")),
    creator: childText(firstChildL(root, "creator")),
    keywords: childText(firstChildL(root, "keywords")),
    description: childText(firstChildL(root, "description")),
    category: childText(firstChildL(root, "category")),
    contentStatus: childText(firstChildL(root, "contentStatus")),
    lastModifiedBy: childText(firstChildL(root, "lastModifiedBy")),
    identifier: childText(firstChildL(root, "identifier")),
    language: childText(firstChildL(root, "language")),
    version: childText(firstChildL(root, "version")),
    revision: childText(firstChildL(root, "revision")),
    created: childText(firstChildL(root, "created")),
    modified: childText(firstChildL(root, "modified")))

proc getAppProps*(f: XlsxFile): Table[string, string] =
  ## Flat map of `docProps/app.xml` scalar children (local names as
  ## keys) plus `SheetCount` from the parsed workbook. Empty table
  ## when the part is absent.
  let root = readXmlPart(f, "docProps/app.xml")
  if root == nil: return initTable[string, string]()
  if localName(root.tag) != "Properties":
    raise newException(XlsxError,
      "docProps/app.xml root is <" & root.tag & ">, want <Properties>")
  for c in root.children:
    if c.kind != xnElement: continue
    let ln = localName(c.tag)
    if ln == "TitlesOfParts" or ln == "HeadingPairs": continue
    if ln == "": continue
    result[ln] = childText(c)
  result["SheetCount"] = $f.sheetOrder.len

proc customValueText(tag, text: string): string =
  ## `vt:*` typed value flattened to string (type info lost, by design).
  case tag
  of "bool":
    if text.strip().toLowerAscii() in ["1", "true", "y", "yes"]: "true"
    else: "false"
  else: text

proc getCustomProps*(f: XlsxFile): Table[string, string] =
  ## `name -> flattened value` from `docProps/custom.xml`. Empty table
  ## when absent. Duplicate names: last wins.
  let root = readXmlPart(f, "docProps/custom.xml")
  if root == nil: return initTable[string, string]()
  if localName(root.tag) != "Properties":
    raise newException(XlsxError,
      "docProps/custom.xml root is <" & root.tag &
      ">, want <Properties>")
  for p in root.children:
    if p.kind != xnElement or localName(p.tag) != "property": continue
    let name = optAttr(p, "name")
    if name == "": continue
    for c in p.children: # first vt:* typed child carries the value
      if c.kind != xnElement: continue
      result[name] = customValueText(
        localName(c.tag).toLowerAscii(), childText(c))
      break
