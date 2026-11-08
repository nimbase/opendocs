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
## `IndexedColorMapping` palette (`templates.go:328`).
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

const IndexedColorMapping*: array[66, string] = [
  "000000", "FFFFFF", "FF0000", "00FF00", "0000FF", "FFFF00", "FF00FF",
  "00FFFF", "000000", "FFFFFF", "FF0000", "00FF00", "0000FF", "FFFF00",
  "FF00FF", "00FFFF", "800000", "008000", "000080", "808000", "800080",
  "008080", "C0C0C0", "808080", "9999FF", "993366", "FFFFCC", "CCFFFF",
  "660066", "FF8080", "0066CC", "CCCCFF", "000080", "FF00FF", "FFFF00",
  "00FFFF", "800080", "800000", "008080", "0000FF", "00CCFF", "CCFFFF",
  "CCFFCC", "FFFF99", "99CCFF", "FF99CC", "CC99FF", "FFCC99", "3366FF",
  "33CCCC", "99CC00", "FFCC00", "FF9900", "FF6600", "666699", "969696",
  "003366", "339966", "003300", "333300", "993300", "993366", "333399",
  "333333", "000000", "FFFFFF",
]

const ThemeSlotNames = ["lt1", "dk1", "lt2", "dk2", "accent1", "accent2",
  "accent3", "accent4", "accent5", "accent6"]
  ## excelize `GetBaseColor` maps theme indexes 0..9 only (`styles.go`);
  ## `hlink`/`folHlink` exist in the scheme but are never addressable.

proc isHexStr(s: string): bool =
  if s.len == 0: return false
  for ch in s:
    if ch notin {'0' .. '9', 'a' .. 'f', 'A' .. 'F'}: return false
  true

proc normalizeThemeEntry(raw: string): string =
  ## Theme entries to 6-digit hex; unusable entries stay empty so the
  ## caller falls through (excelize `GetBaseColor` order).
  if raw.len == 6 and isHexStr(raw): raw
  elif raw.len == 8 and isHexStr(raw):
    if raw[0 .. 1] == "FF": raw[2 .. 7] else: raw[0 .. 5]
  else: ""

proc parseHexByte(s: string): int =
  ## Two hex digits to a byte; raises XlsxError (fail loudly).
  if s.len != 2:
    raise newException(XlsxError, "bad hex byte: " & s)
  try: parseHexInt(s)
  except ValueError:
    raise newException(XlsxError, "bad hex byte: " & s)

proc themeColors(f: XlsxFile): tuple[present: bool,
    colors: array[10, string]] =
  ## Workbook theme palette in `IndexedColorMapping` order (lt1 first).
  ## Loaded once; a missing `xl/theme/theme1.xml` reports absent (like
  ## excelize's nil `Theme`: no theme means no color at all).
  if f.themeLoaded: return (true, f.themeColors)
  f.themeLoaded = true
  let root = readXmlPart(f, "xl/theme/theme1.xml")
  if root == nil: return (false, f.themeColors)
  if localName(root.tag) != "theme":
    raise newException(XlsxError,
      "xl/theme/theme1.xml root is <" & root.tag & ">, want <theme>")
  let elems = firstChildL(root, "themeElements")
  let scheme = if elems != nil: firstChildL(elems, "clrScheme") else: nil
  if scheme == nil:
    raise newException(XlsxError,
      "xl/theme/theme1.xml has no clrScheme")
  for i, slot in ThemeSlotNames:
    let slotNode = firstChildL(scheme, slot)
    if slotNode == nil: continue
    var raw = ""
    let srgb = firstChildL(slotNode, "srgbClr")
    if srgb != nil: raw = optAttr(srgb, "val")
    else:
      let sys = firstChildL(slotNode, "sysClr")
      if sys != nil: raw = optAttr(sys, "lastClr")
    f.themeColors[i] = normalizeThemeEntry(raw)
  (true, f.themeColors)

proc applyTint(base6: string, tint: float64): tuple[r, g, b: int] =
  ## Port of excelize `ThemeColor` minus the `FF` prefix: the tint
  ## applies in HSL space (LPeg-free, via openparser/colors).
  let r0 = parseHexByte(base6[0 .. 1])
  let g0 = parseHexByte(base6[2 .. 3])
  let b0 = parseHexByte(base6[4 .. 5])
  if tint == 0.0: return (r0, g0, b0)
  let c = Color(r: float(r0) / 255.0, g: float(g0) / 255.0,
    b: float(b0) / 255.0, a: 1.0, format: cfHex, valid: true)
  let hsl = c.toHsl()
  var l = hsl.l
  if tint < 0.0: l = l * (1.0 + tint)
  else: l = l * (1.0 - tint) + (1.0 - (1.0 - tint))
  if l < 0.0: l = 0.0
  elif l > 1.0: l = 1.0
  let c2 = fromHsl(Hsl(h: hsl.h, s: hsl.s, l: l, a: 1.0))
  (int(c2.r * 255.0 + 0.5), int(c2.g * 255.0 + 0.5),
    int(c2.b * 255.0 + 0.5))

proc resolveColor(f: XlsxFile, n: XmlNode): Color =
  ## Mirror of excelize `getThemeColor` + `GetBaseColor` + `ThemeColor`:
  ## theme (needs the theme part) wins, then 6/8-digit `rgb`, then the
  ## styles custom palette, then the default indexed palette. Invalid
  ## when the element is absent or nothing resolves (negative or wild
  ## indexes stay invalid instead of panicking like the Go indexing).
  result = Color(valid: false)
  if n == nil: return
  let (themePresent, theme) = themeColors(f)
  if not themePresent: return
  let rgb = optAttr(n, "rgb")
  let indexedS = optAttr(n, "indexed")
  let themeS = optAttr(n, "theme")
  let tint = floatAttr(n, "tint", 0.0)
  var base = ""
  var alpha = 1.0
  var ok = false
  if themeS != "":
    let ti =
      try: parseInt(themeS)
      except ValueError:
        raise newException(XlsxError,
          "bad theme color index: " & themeS)
    if ti >= 0 and ti < theme.len and theme[ti] != "":
      base = theme[ti]
      ok = true
  if not ok and rgb != "":
    if rgb.len == 6 and isHexStr(rgb):
      base = rgb
      ok = true
    elif rgb.len == 8 and isHexStr(rgb):
      if rgb[0 .. 1] == "FF": base = rgb[2 .. 7]
      else:
        alpha = float(parseHexByte(rgb[0 .. 1])) / 255.0
        base = rgb[2 .. 7]
      ok = true
  if not ok:
    var idx = 0
    if indexedS != "":
      try: idx = parseInt(indexedS)
      except ValueError:
        raise newException(XlsxError,
          "bad indexed color: " & indexedS)
    if idx < 0: return
    if f.styles.indexedColors.len > 0:
      if idx < f.styles.indexedColors.len:
        let entry = f.styles.indexedColors[idx]
        if entry.len == 8 and isHexStr(entry):
          if entry[0 .. 1] == "FF": base = entry[2 .. 7]
          else:
            alpha = float(parseHexByte(entry[0 .. 1])) / 255.0
            base = entry[2 .. 7]
          ok = true
        elif entry.len == 6 and isHexStr(entry):
          base = entry
          ok = true
    elif idx < IndexedColorMapping.len:
      base = IndexedColorMapping[idx]
      ok = true
  if not ok: return
  let (r, g, b) = applyTint(base, tint)
  result = Color(r: float(r) / 255.0, g: float(g) / 255.0, b: float(b) / 255.0,
    a: alpha, format: cfHex, valid: true)

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
