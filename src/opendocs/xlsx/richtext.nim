## Copyright (c) 2026 nimbase (MIT, see LICENSE at repo root).
## Portions derived from excelize (https://github.com/qax-os/excelize,
## commit 0434413, 2026-09-18): Copyright (c) 2016-2026 The excelize
## Authors, Copyright (c) 2011-2017 Geoffrey J. Teale, BSD-3-Clause.
## SPDX-License-Identifier: MIT AND BSD-3-Clause
##
## Rich text: per-run text plus direct formatting (`rPr`), from shared
## strings (`si/r`) and inline strings (`is/r`). Ports of excelize
## `GetCellRichText` / `getCellRichText` (`cell.go`), `getFont`
## (`cell.go:1281`), `extractFont` (`styles.go:1572`), `getThemeColor`
## + `GetBaseColor` + `ThemeColor` (`styles.go`), and the
## `IndexedColorMapping` palette (`templates.go:328`). Color resolution
## (theme/tint/indexed) lives in `xlsx/styles`; this file only parses
## run properties on top of it.
##
## Two deliberate divergences from excelize, both documented and
## fixture-tested:
## - Bare boolean elements (`<b/>`) read as true (OOXML-correct).
##   excelize's `attrValBool.Value()` returns false for a missing `val`,
##   so it misreads real-world bold runs.
## - 8-digit `rgb` honors the alpha channel (AARRGGBB). excelize slices
##   the first six digits, reading alpha as red.
## Resolved rich-text colors are also richer than excelize: it leaves
## theme references raw on runs, while we resolve them (the locked
## "full support" decision).

proc rprBool(rpr: XmlNode, local: string): bool =
  ## OOXML on/off: present without `val` means true (diverges from
  ## excelize, which reads a missing `val` as false).
  let e = firstChildL(rpr, local)
  if e == nil: return false
  let v = optAttr(e, "val")
  v == "" or v in ["1", "true", "on"]

proc parseRPr(f: XlsxFile, rpr: XmlNode): tuple[hasFont: bool,
    font: XlsxFont] =
  ## One `rPr` element to an `XlsxFont` (excelize `getFont` +
  ## `extractFont`). Missing `rPr` reports no font.
  if rpr == nil: return (false, XlsxFont())
  var ft = XlsxFont()
  ft.name = optAttr(firstChildL(rpr, "rFont"), "val")
  ft.size = floatAttr(firstChildL(rpr, "sz"), "val", 0.0)
  ft.bold = rprBool(rpr, "b")
  ft.italic = rprBool(rpr, "i")
  ft.strike = rprBool(rpr, "strike")
  ft.outline = rprBool(rpr, "outline")
  ft.shadow = rprBool(rpr, "shadow")
  ft.condense = rprBool(rpr, "condense")
  ft.extend = rprBool(rpr, "extend")
  let u = firstChildL(rpr, "u")
  if u != nil:
    let v = optAttr(u, "val")
    ft.underline = if v == "": "single" else: v
  ft.vertAlign = optAttr(firstChildL(rpr, "vertAlign"), "val")
  ft.scheme = optAttr(firstChildL(rpr, "scheme"), "val")
  let cs = firstChildL(rpr, "charset")
  if cs != nil:
    try:
      ft.charset = parseInt(optAttr(cs, "val"))
      ft.hasCharset = true
    except ValueError:
      raise newException(XlsxError,
        "bad charset in rich text: " & optAttr(cs, "val"))
  let fam = firstChildL(rpr, "family")
  if fam != nil:
    try:
      ft.family = parseInt(optAttr(fam, "val"))
      ft.hasFamily = true
    except ValueError:
      raise newException(XlsxError,
        "bad family in rich text: " & optAttr(fam, "val"))
  ft.color = resolveColor(f, firstChildL(rpr, "color"))
  (true, ft)

proc richRunsOf(f: XlsxFile, si: XmlNode): seq[XlsxRichRun] =
  ## Runs of one shared-string `si` or inline `is` element: direct
  ## `<t>` first (excelize `getCellRichText` order), then each `<r>`.
  if si == nil: return @[]
  for t in childElemsL(si, "t"):
    result.add XlsxRichRun(text: childText(t))
  for r in childElemsL(si, "r"):
    let tNode = firstChildL(r, "t")
    let txt = if tNode != nil: childText(tNode) else: ""
    let (hasF, ft) = parseRPr(f, firstChildL(r, "rPr"))
    result.add XlsxRichRun(text: txt, hasFont: hasF, font: ft)

proc getCellRichText*(f: XlsxFile, sheet, cellRef: string): seq[
    XlsxRichRun] =
  ## Rich-text runs of a cell, in order. Shared-string cells resolve
  ## through the SST, inline-string cells read their stored `is`
  ## element; anything else (or an absent cell) yields no runs.
  ## Merge-covered cells report their anchor's runs.
  let (col, row) = splitCellRef(cellRef)
  let s = getSheet(f, sheet)
  let (covered, anchor) = mergedCell(s, col, row)
  var c: Cell
  var found = false
  if covered:
    c = anchor
    found = true
  else:
    (found, c) = findCell(s, col, row)
  if not found: return @[]
  if c.cellType == ctySharedString:
    if c.raw == "": return @[]
    let idx =
      try: parseInt(c.raw)
      except ValueError:
        raise newException(XlsxError,
          "bad shared string index: " & c.raw)
    discard sharedStrings(f)
    if idx < 0 or idx >= f.sstNodes.len:
      raise newException(XlsxError,
        "shared string index out of range: " & $idx)
    return richRunsOf(f, f.sstNodes[idx])
  if c.cellType == ctyInlineString:
    return richRunsOf(f, c.isNode)
  @[]
