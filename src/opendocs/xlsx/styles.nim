## Copyright (c) 2026 nimbase (MIT, see LICENSE at repo root).
## Portions derived from excelize (https://github.com/qax-os/excelize,
## commit 0434413, 2026-09-18): Copyright (c) 2016-2026 The excelize
## Authors, Copyright (c) 2011-2017 Geoffrey J. Teale, BSD-3-Clause.
## SPDX-License-Identifier: MIT AND BSD-3-Clause
##
## Stylesheet: eager parse of `xl/styles.xml` for value formatting and
## style records. Ports of excelize `stylesReader` (missing part ->
## empty, never an error), the `formattedValue` stylesheet half (custom
## codes plus the `cellXfs` number-format index), `GetStyle`
## (`styles.go:1670`), `extractFont`/`extractFills`/`extractBorders`/
## `extractAlignment`/`extractProtection`, `getThemeColor` +
## `GetBaseColor` + `ThemeColor`, and the `IndexedColorMapping` palette
## (`templates.go:328`).
##
## Two deliberate divergences from excelize, shared with the rich-text
## reader (which resolves colors through this file):
## - Bare boolean elements (`<b/>`) read as true (OOXML-correct).
##   excelize's `attrValBool.Value()` returns false for a missing `val`,
##   so it misreads real-world bold runs.
## - 8-digit `rgb` honors the alpha channel (AARRGGBB). excelize slices
##   the first six digits, reading alpha as red.
## Style colors are also richer than excelize: `GetStyle` leaves theme
## references raw, while we resolve them (the locked "full support"
## decision).
##
## `cellStyleXfs` (named-style masters) is parsed but unused: cell
## formatting resolves through `cellXfs` only, like excelize's value
## and style paths.

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
    if idx >= 0:
      # excelize `GetBaseColor` order: custom palette hit wins, then
      # the default palette (even when a short custom palette exists).
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
      if not ok and idx < IndexedColorMapping.len:
        base = IndexedColorMapping[idx]
        ok = true
  if not ok: return
  let (r, g, b) = applyTint(base, tint)
  result = Color(r: float(r) / 255.0, g: float(g) / 255.0, b: float(b) / 255.0,
    a: alpha, format: cfHex, valid: true)

# ------------------------------------------------- style records

proc styleBool(n: XmlNode, local: string): bool =
  ## OOXML on/off element: present without `val` means true (same
  ## divergence as the rich-text reader).
  let e = firstChildL(n, local)
  if e == nil: return false
  let v = optAttr(e, "val")
  v == "" or v in ["1", "true", "on"]

proc parseStyleFont(f: XlsxFile, fn: XmlNode): XlsxFont =
  ## One `fonts/font` element (excelize `extractFont`). Missing element
  ## yields the zero font; the caller decides presence from the xf id.
  if fn == nil: return XlsxFont()
  result.name = optAttr(firstChildL(fn, "name"), "val")
  if result.name == "":
    result.name = optAttr(firstChildL(fn, "rFont"), "val")
  result.size = floatAttr(firstChildL(fn, "sz"), "val", 0.0)
  result.bold = styleBool(fn, "b")
  result.italic = styleBool(fn, "i")
  result.strike = styleBool(fn, "strike")
  result.outline = styleBool(fn, "outline")
  result.shadow = styleBool(fn, "shadow")
  result.condense = styleBool(fn, "condense")
  result.extend = styleBool(fn, "extend")
  let u = firstChildL(fn, "u")
  if u != nil:
    let v = optAttr(u, "val")
    result.underline = if v == "": "single" else: v
  result.vertAlign = optAttr(firstChildL(fn, "vertAlign"), "val")
  result.scheme = optAttr(firstChildL(fn, "scheme"), "val")
  let cs = firstChildL(fn, "charset")
  if cs != nil:
    try:
      result.charset = parseInt(optAttr(cs, "val"))
      result.hasCharset = true
    except ValueError:
      raise newException(XlsxError,
        "bad charset in styles: " & optAttr(cs, "val"))
  let fam = firstChildL(fn, "family")
  if fam != nil:
    try:
      result.family = parseInt(optAttr(fam, "val"))
      result.hasFamily = true
    except ValueError:
      raise newException(XlsxError,
        "bad family in styles: " & optAttr(fam, "val"))
  result.color = resolveColor(f, firstChildL(fn, "color"))

proc parseFillColor(f: XlsxFile, n: XmlNode): Color =
  ## Fill `fgColor`/`bgColor`: `auto` means absent (excelize checks
  ## `!BgColor.Auto` before resolving).
  if n == nil: return Color(valid: false)
  if optAttr(n, "auto") in ["1", "true", "on"]: return Color(valid: false)
  resolveColor(f, n)

proc gradientShading(degree, left, right, top, bottom: float,
    typ: string, stops: int): int =
  ## excelize `styleFillVariants` order: first variant whose geometry
  ## matches, -1 when none does. Stops only gate the 2-vs-3-stop choice
  ## implicitly through the table (positions are not compared).
  const variants = [(90.0, 0.0, 0.0, 0.0, 0.0, "", 2),
    (270.0, 0.0, 0.0, 0.0, 0.0, "", 2), (90.0, 0.0, 0.0, 0.0, 0.0, "", 3),
    (0.0, 0.0, 0.0, 0.0, 0.0, "", 2), (180.0, 0.0, 0.0, 0.0, 0.0, "", 2),
    (0.0, 0.0, 0.0, 0.0, 0.0, "", 3), (45.0, 0.0, 0.0, 0.0, 0.0, "", 2),
    (255.0, 0.0, 0.0, 0.0, 0.0, "", 2),
    (45.0, 0.0, 0.0, 0.0, 0.0, "", 3), (135.0, 0.0, 0.0, 0.0, 0.0, "", 2),
    (315.0, 0.0, 0.0, 0.0, 0.0, "", 2),
    (135.0, 0.0, 0.0, 0.0, 0.0, "", 3),
    (0.0, 0.0, 0.0, 0.0, 0.0, "path", 2),
    (0.0, 1.0, 1.0, 0.0, 0.0, "path", 2),
    (0.0, 0.0, 0.0, 1.0, 1.0, "path", 2),
    (0.0, 1.0, 1.0, 1.0, 1.0, "path", 2),
    (0.0, 0.5, 0.5, 0.5, 0.5, "path", 2)]
  for i, v in variants:
    if degree == v[0] and left == v[1] and right == v[2] and
        top == v[3] and bottom == v[4] and typ == v[5] and stops == v[6]:
      return i
  -1

proc parseStyleFill(f: XlsxFile, fn: XmlNode): XlsxFill =
  ## One `fills/fill` element (excelize `extractFills`). Missing element
  ## yields the zero fill; the caller decides presence from the xf id.
  if fn == nil: return XlsxFill()
  let pf = firstChildL(fn, "patternFill")
  if pf != nil:
    result.kind = "pattern"
    result.pattern = optAttr(pf, "patternType")
    result.fgColor = parseFillColor(f, firstChildL(pf, "fgColor"))
    result.bgColor = parseFillColor(f, firstChildL(pf, "bgColor"))
    return
  let gf = firstChildL(fn, "gradientFill")
  if gf == nil: return
  result.kind = "gradient"
  result.gradientType = optAttr(gf, "type")
  result.gradientDegree = floatAttr(gf, "degree", 0.0)
  let bottom = floatAttr(gf, "bottom", 0.0)
  let left = floatAttr(gf, "left", 0.0)
  let right = floatAttr(gf, "right", 0.0)
  let top = floatAttr(gf, "top", 0.0)
  for stop in childElemsL(gf, "stop"):
    result.gradientColors.add resolveColor(f, firstChildL(stop, "color"))
  result.shading = gradientShading(result.gradientDegree, left, right,
    top, bottom, result.gradientType, result.gradientColors.len)

proc parseBorderSide(f: XlsxFile, n: XmlNode): XlsxBorderSide =
  ## One border edge (excelize `extractBorders` inner closure): recorded
  ## only with a non-empty style upstream; color resolves when present.
  if n == nil: return XlsxBorderSide()
  XlsxBorderSide(style: optAttr(n, "style"),
    color: resolveColor(f, firstChildL(n, "color")))

proc parseStyleBorder(f: XlsxFile, bn: XmlNode): XlsxBorder =
  ## One `borders/border` element (excelize `extractBorders`).
  if bn == nil: return XlsxBorder()
  result.left = parseBorderSide(f, firstChildL(bn, "left"))
  result.right = parseBorderSide(f, firstChildL(bn, "right"))
  result.top = parseBorderSide(f, firstChildL(bn, "top"))
  result.bottom = parseBorderSide(f, firstChildL(bn, "bottom"))
  result.diagonal = parseBorderSide(f, firstChildL(bn, "diagonal"))
  result.vertical = parseBorderSide(f, firstChildL(bn, "vertical"))
  result.horizontal = parseBorderSide(f, firstChildL(bn, "horizontal"))
  result.diagonalUp = boolAttr(bn, "diagonalUp")
  result.diagonalDown = boolAttr(bn, "diagonalDown")
  result.outline = boolAttr(bn, "outline")

proc parseXfAlignment(n: XmlNode): tuple[present: bool,
    a: XlsxAlignment] =
  ## Inline `xf/alignment` element. Excelize creates the record whenever
  ## the element is present (and the apply flag passes).
  let an = firstChildL(n, "alignment")
  if an == nil: return (false, XlsxAlignment())
  (true, XlsxAlignment(horizontal: optAttr(an, "horizontal"),
    vertical: optAttr(an, "vertical"),
    wrapText: boolAttr(an, "wrapText"),
    shrinkToFit: boolAttr(an, "shrinkToFit"),
    justifyLastLine: boolAttr(an, "justifyLastLine"),
    indent: intAttr(an, "indent", 0),
    relativeIndent: intAttr(an, "relativeIndent", 0),
    readingOrder: intAttr(an, "readingOrder", 0),
    textRotation: intAttr(an, "textRotation", 0)))

proc parseXfProtection(n: XmlNode): tuple[present: bool,
    p: XlsxProtection] =
  ## Inline `xf/protection` element (absent attributes read false,
  ## excelize `extractProtection` parity).
  let pn = firstChildL(n, "protection")
  if pn == nil: return (false, XlsxProtection())
  (true, XlsxProtection(hidden: boolAttr(pn, "hidden"),
    locked: boolAttr(pn, "locked")))

proc optId(n: XmlNode, name: string): int =
  ## Optional id reference: -1 when the attribute is absent (nil in
  ## excelize); malformed values raise loudly.
  let raw = optAttr(n, name)
  if raw == "": return -1
  try: parseInt(raw)
  except ValueError:
    raise newException(XlsxError,
      "bad " & name & " in styles: " & raw)

proc optApply(n: XmlNode, name: string): tuple[has, val: bool] =
  ## Optional `apply*` flag: absent counts as apply (excelize nil check).
  let raw = optAttr(n, name)
  if raw == "": return (false, false)
  (true, raw in ["1", "true", "on"])

proc parseXf(x: XmlNode): XlsxXf =
  ## One `cellXfs/xf` element: ids plus inline alignment/protection.
  result.numFmtId = intAttr(x, "numFmtId", 0)
  result.fontId = optId(x, "fontId")
  result.fillId = optId(x, "fillId")
  result.borderId = optId(x, "borderId")
  result.xfId = optId(x, "xfId")
  let (hNf, vNf) = optApply(x, "applyNumberFormat")
  result.hasApplyNumberFormat = hNf
  result.applyNumberFormat = vNf
  let (hFo, vFo) = optApply(x, "applyFont")
  result.hasApplyFont = hFo
  result.applyFont = vFo
  let (hFi, vFi) = optApply(x, "applyFill")
  result.hasApplyFill = hFi
  result.applyFill = vFi
  let (hBo, vBo) = optApply(x, "applyBorder")
  result.hasApplyBorder = hBo
  result.applyBorder = vBo
  let (hAl, vAl) = optApply(x, "applyAlignment")
  result.hasApplyAlignment = hAl
  result.applyAlignment = vAl
  let (hPr, vPr) = optApply(x, "applyProtection")
  result.hasApplyProtection = hPr
  result.applyProtection = vPr
  let (hasA, a) = parseXfAlignment(x)
  result.hasAlignment = hasA
  result.alignment = a
  let (hasP, p) = parseXfProtection(x)
  result.hasProtection = hasP
  result.protection = p

# ------------------------------------------------------------------ load

proc loadStyles*(f: XlsxFile) =
  ## Eager stylesheet load at open. Missing part loads empty, never an
  ## error; malformed ids and colors raise loudly.
  f.styles = XlsxStylesheet()
  let root = readXmlPart(f, "xl/styles.xml")
  if root == nil: return
  if localName(root.tag) != "styleSheet":
    raise newException(XlsxError,
      "xl/styles.xml root is <" & root.tag & ">, want <styleSheet>")
  let nf = firstChildL(root, "numFmts")
  if nf != nil:
    for n in childElemsL(nf, "numFmt"):
      let code = optAttr(n, "formatCode")
      if code != "":
        f.styles.numFmts[intAttr(n, "numFmtId", -1)] = code
  # Custom palette before fonts/fills/borders: their `indexed` colors
  # resolve through it at parse time (excelize `GetBaseColor` order).
  let colors = firstChildL(root, "colors")
  if colors != nil:
    let indexed = firstChildL(colors, "indexedColors")
    if indexed != nil:
      for rc in childElemsL(indexed, "rgbColor"):
        f.styles.indexedColors.add optAttr(rc, "rgb")
  let fonts = firstChildL(root, "fonts")
  if fonts != nil:
    for fn in childElemsL(fonts, "font"):
      f.styles.fonts.add parseStyleFont(f, fn)
  let fills = firstChildL(root, "fills")
  if fills != nil:
    for fn in childElemsL(fills, "fill"):
      f.styles.fills.add parseStyleFill(f, fn)
  let borders = firstChildL(root, "borders")
  if borders != nil:
    for bn in childElemsL(borders, "border"):
      f.styles.borders.add parseStyleBorder(f, bn)
  let xfs = firstChildL(root, "cellXfs")
  if xfs != nil:
    for x in childElemsL(xfs, "xf"):
      f.styles.cellXfs.add parseXf(x)

proc numFmtIdFor*(st: XlsxStylesheet, styleIdx: int): int =
  ## Number-format id for a cell style index, or -1 for the raw-value
  ## fallback (`S<=0`, matching excelize `formattedValue`, or out of
  ## range, where excelize returns the value with a nil error).
  if styleIdx <= 0 or styleIdx >= st.cellXfs.len: return -1
  st.cellXfs[styleIdx].numFmtId

# ------------------------------------------------------------------ style getters

proc getStyle*(f: XlsxFile, idx: int): XlsxStyle =
  ## Resolved style for a `cellXfs` index (excelize `GetStyle` parity).
  ## Out-of-range indices raise; absent parts, `apply*` opt-outs, and
  ## dangling ids report `has* == false` rather than raising.
  if idx < 0 or idx >= f.styles.cellXfs.len:
    raise newException(XlsxError, "style index out of range: " & $idx)
  let xf = f.styles.cellXfs[idx]
  result = XlsxStyle(numFmtId: xf.numFmtId, fontId: xf.fontId,
    fillId: xf.fillId, borderId: xf.borderId)
  if (not xf.hasApplyFont or xf.applyFont) and xf.fontId >= 0 and
      xf.fontId < f.styles.fonts.len:
    result.hasFont = true
    result.font = f.styles.fonts[xf.fontId]
  if (not xf.hasApplyFill or xf.applyFill) and xf.fillId >= 0 and
      xf.fillId < f.styles.fills.len:
    result.hasFill = true
    result.fill = f.styles.fills[xf.fillId]
  if (not xf.hasApplyBorder or xf.applyBorder) and xf.borderId >= 0 and
      xf.borderId < f.styles.borders.len:
    result.hasBorder = true
    result.border = f.styles.borders[xf.borderId]
  if (not xf.hasApplyAlignment or xf.applyAlignment) and xf.hasAlignment:
    result.hasAlignment = true
    result.alignment = xf.alignment
  if (not xf.hasApplyProtection or xf.applyProtection) and
      xf.hasProtection:
    result.hasProtection = true
    result.protection = xf.protection

