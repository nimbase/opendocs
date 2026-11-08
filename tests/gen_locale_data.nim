## Locale data generator (run manually, not a test).
##
## Regenerates `src/opendocs/xlsx/locale_data.nim` from the pinned
## excelize checkout: month/weekday/apFmt tables plus the
## `supportedLanguageInfo` map from `numfmt.go`, materializing one
## `XlsxLocale` per LCID exactly as excelize's `localMonthsName*`
## funcs evaluate them for abbr 3/4/5 (incl. byte-slice narrow quirks,
## Khmer +11 indexing, and the French/Russian/CroatianLatin/Quechua/
## Sami/Thai/Tibetan special cases).
##
## Usage (from the package root):
##   clue build tests/gen_locale_data.nim --out:/tmp/genloc && /tmp/genloc
## then diff `src/opendocs/xlsx/locale_data.nim` (output is deterministic;
## entries sort by LCID).

import std/[algorithm, os, sequtils, strutils, tables, unicode]

const Pin = "0434413, 2026-09-18"

let Here = currentSourcePath().parentDir()
let Src = Here / ".." / ".." / ".." / "references" / "excelize" /
  "numfmt.go"
let Out = Here / ".." / "src" / "opendocs" / "xlsx" / "locale_data.nim"

const NfpAmPm = ["AM/PM", "A/P", "上午/下午"]
const EnMonths = ["January", "February", "March", "April", "May", "June",
  "July", "August", "September", "October", "November", "December"]

func goUnescape(s: string): string =
  var i = 0
  while i < s.len:
    if s[i] == '\\' and i + 1 < s.len:
      let n = s[i + 1]
      if n == 'u' and i + 5 < s.len:
        result.add $Rune(parseHexInt(s[i + 2 .. i + 5]))
        i += 6
        continue
      if n == 'U' and i + 9 < s.len:
        result.add $Rune(parseHexInt(s[i + 2 .. i + 9]))
        i += 10
        continue
      if n == 'n': result.add '\n'; i += 2; continue
      if n == 't': result.add '\t'; i += 2; continue
      if n in {'"', '\'', '\\'}: result.add n; i += 2; continue
      result.add s[i]; i += 1
    else:
      result.add s[i]; i += 1

func findMatching(src: string, openAt: int): int =
  ## Index of the `}` matching the `{` at openAt (string-aware).
  var depth = 0
  var instr = false
  var esc = false
  var k = openAt
  while k < src.len:
    let c = src[k]
    if instr:
      if esc: esc = false
      elif c == '\\': esc = true
      elif c == '"': instr = false
    else:
      if c == '"': instr = true
      elif c == '{': inc depth
      elif c == '}':
        dec depth
        if depth == 0: return k
    inc k
  -1

func parseGoStrings(body: string): seq[string] =
  ## Go `"..."` literals in a `[]string{...}` body, unescaped.
  var i = 0
  while i < body.len:
    if body[i] == '"':
      var j = i + 1
      var esc = false
      while j < body.len:
        if esc: esc = false
        elif body[j] == '\\': esc = true
        elif body[j] == '"': break
        inc j
      result.add goUnescape(body[i + 1 ..< j])
      i = j + 1
    else:
      inc i

func isWordChar(c: char): bool =
  c.isAlphaNumeric or c == '_'

func parseArrays(src: string): Table[string, seq[string]] =
  var i = 0
  while true:
    let eq = src.find("= []string{", i)
    if eq < 0: break
    var ns = eq
    while ns > 0 and src[ns - 1] in {' ', '\t'}: dec ns
    let nameEnd = ns
    while ns > 0 and src[ns - 1].isWordChar: dec ns
    let name = src[ns ..< nameEnd]
    let openAt = src.find('{', eq)
    let closeAt = findMatching(src, openAt)
    if name.startsWith("monthNames") or name.startsWith("monthsName") or
        name.startsWith("weekdayNames"):
      result[name] = parseGoStrings(src[openAt + 1 ..< closeAt])
    i = closeAt + 1

func parseApFmt(src: string): Table[string, string] =
  var i = 0
  while true:
    let a = src.find("apFmt", i)
    if a < 0: break
    if a > 0 and src[a - 1].isWordChar:
      i = a + 5
      continue
    var ne = a
    while ne < src.len and src[ne].isWordChar: inc ne
    let name = src[a ..< ne]
    var eq = ne
    while eq < src.len and src[eq] in {' ', '\t'}: inc eq
    if eq >= src.len or src[eq] != '=':
      i = ne
      continue
    let lit = src.find('"', eq)
    if lit < 0:
      i = ne
      continue
    var j = lit + 1
    var esc = false
    while j < src.len:
      if esc: esc = false
      elif src[j] == '\\': esc = true
      elif src[j] == '"': break
      inc j
    result[name] = goUnescape(src[lit + 1 ..< j])
    i = j + 1

func extractFuncs(src: string): Table[string, string] =
  let marker = "func localMonthsName"
  var i = 0
  while true:
    let f = src.find(marker, i)
    if f < 0: break
    var ne = f + marker.len
    while ne < src.len and src[ne].isWordChar: inc ne
    let name = "localMonthsName" & src[f + marker.len ..< ne]
    let openAt = src.find('{', ne)
    let closeAt = findMatching(src, openAt)
    result[name] = src[openAt + 1 ..< closeAt]
    i = closeAt + 1

func firstRune(s: string): string =
  for r in s.runes: return $r
  ""

func evalIndex(e: string, month: int): int =
  var e2 = e.replace("int(t.Month())", "M").replace("t.Month()", "M")
  e2 = e2.replace(" ", "").strip(chars = {'(', ')'})
  if e2 == "M-1": return month - 1
  if e2.startsWith("M+"): return month + parseInt(e2[2 .. ^1])
  raise newException(ValueError, "unhandled index: " & e)

func bracketClose(s: string, openBr: int): int =
  ## Matching `]` for the `[` at openBr (no nesting inside).
  s.find(']', openBr)

func evalExpr(e: string, month: int,
    arrays: Table[string, seq[string]]): string =
  let ex = e.strip()
  if ex.startsWith("string([]rune(") and ex.endsWith(")"):
    # string([]rune(ARR[idx])[:N])
    let core = ex["string([]rune(".len .. ^2]
    let splitAt = core.rfind("])[:")
    let arrIdx = core[0 .. splitAt]
    let n = parseInt(core[splitAt + 4 .. ^2])
    let br = arrIdx.find('[')
    let arr = arrIdx[0 ..< br]
    let idx = evalIndex(arrIdx[br + 1 ..< splitAt], month)
    let runes = toSeq(arrays[arr][idx].runes)
    return runes[0 ..< min(n, runes.len)].join("")
  if ex == "t.Month().String()": return EnMonths[month - 1]
  if ex.startsWith("t.Month().String()[:"):
    let n = parseInt(ex["t.Month().String()[:".len .. ^2])
    return EnMonths[month - 1][0 ..< n]
  if ex.endsWith("[:1]") and not ex.startsWith("string("):
    # ARR[idx][:1] byte slice (Go bytes, not runes)
    let br = ex.find('[')
    let ce = bracketClose(ex, br)
    let arr = ex[0 ..< br]
    let s = arrays[arr][evalIndex(ex[br + 1 ..< ce], month)]
    if s.len > 0 and s[0].ord < 0x80: return s[0 .. 0]
    return "@@BYTE1:" & toHex(s[0].ord, 2)
  if ex.endsWith("]") and not ex.startsWith("fmt.") and
      not ex.startsWith("strconv."):
    let br = ex.find('[')
    if br > 0:
      let arr = ex[0 ..< br]
      if arr in arrays:
        let ce = bracketClose(ex, br)
        return arrays[arr][evalIndex(ex[br + 1 ..< ce], month)]
  if ex == "strconv.Itoa(int(t.Month()))": return $month
  if ex.startsWith("fmt.Sprintf(\"%02d\""): return align($month, 2, '0')
  if ex.startsWith("fmt.Sprintf(\"%d-"):
    let q1 = ex.find('"') + 1
    let q2 = ex.rfind('"')
    let lit = ex[q1 ..< q2]
    let pct = lit.find("%d")
    return goUnescape(lit[0 ..< pct]) & $month &
      goUnescape(lit[pct + 2 .. ^1])
  if ex.startsWith("\"") and ex.endsWith("\"") and ex.len >= 2:
    return goUnescape(ex[1 .. ^2])
  raise newException(ValueError, "unhandled expr: " & ex)

func tryParseInt(s: string): tuple[ok: bool, v: int] =
  try: (true, parseInt(s.strip()))
  except ValueError: (false, 0)

func condMatches(cond: string, abbr: int): bool =
  for p in cond.split("||"):
    let q = p.strip()
    if q.startsWith("abbr =="):
      let (ok, v) = tryParseInt(q["abbr ==".len .. ^1])
      if ok and abbr == v: return true
    elif q.startsWith("abbr >="):
      let (ok, v) = tryParseInt(q["abbr >=".len .. ^1])
      if ok and abbr >= v: return true
    elif q.startsWith("abbr >"):
      let (ok, v) = tryParseInt(q["abbr >".len .. ^1])
      if ok and abbr > v: return true
  false

func firstRunes(s: string, n: int): string =
  toSeq(s.runes)[0 ..< min(n, s.runeLen)].join("")

func monthTriple(funcName: string, body: string,
    arrays: Table[string, seq[string]]): tuple[ab, fu, na: seq[string]] =
  if funcName in ["localMonthsNameFrench", "localMonthsNameRussian"]:
    let base = if funcName.endsWith("French"): "monthNamesFrench"
      else: "monthNamesRussian"
    let abbr = arrays[base & "Abbr"]
    let full = arrays[base]
    var ab, na: seq[string]
    for i in 0 ..< 12:
      ab.add if full[i].runeLen <= 4: full[i] else: abbr[i]
      na.add firstRune(full[i])
    return (ab, full, na)
  if funcName == "localMonthsNameCroatianLatin":
    let arr = arrays["monthNamesCroatian"]
    var ab, na: seq[string]
    for m in 1 .. 12:
      ab.add if m == 2: firstRunes(arr[1], 4)
        else: firstRunes(arr[m - 1], 3)
      na.add firstRune(arr[m - 1])
    return (ab, arr, na)
  if funcName == "localMonthsNameQuechuaEcuador":
    let arr = arrays["monthNamesQuechuaEcuador"]
    var ab, na: seq[string]
    for m in 1 .. 12:
      ab.add if m == 1: firstRunes(arr[0], 4)
        else: firstRunes(arr[m - 1], 3)
      na.add firstRune(arr[m - 1])
    return (ab, arr, na)
  if funcName == "localMonthsNameSamiNorthernFI":
    let ab = arrays["monthNamesSamiNorthernAbbr"]
    let full = arrays["monthNamesSamiNorthern"]
    var fu, na: seq[string]
    for m in 1 .. 12:
      fu.add if m == 1: "ođđajagemánu" else: full[m - 1]
      na.add firstRune(full[m - 1])
    return (ab, fu, na)
  if funcName == "localMonthsNameThai":
    let arr = arrays["monthNamesThai"]
    var ab, na: seq[string]
    for m in arr:
      let r = toSeq(m.runes)
      ab.add $r[0] & "." & $r[^2] & "."
      na.add $r[0]
    return (ab, arr, na)
  if funcName == "localMonthsNameTibetan":
    let ab = arrays["monthNamesTibetanAbbr"]
    let fu = arrays["monthNamesTibetan"]
    var na: seq[string]
    for m in 1 .. 12:
      na.add if m == 10: "ས" else: "ཟ" # Go "\u0F66" / "\u0F5F"
    return (ab, fu, na)
  if funcName == "localMonthsNamePashto":
    # Month 6 has abbr3/abbr4 specials; every other slot (incl. the
    # whole narrow row) reads the full array verbatim.
    let arr = arrays["monthNamesPashto"]
    var ab = arr
    ab[5] = "چنګا ښ" # Go "\u0686\u0646\u06AB\u0627 \u069A"
    return (ab, arr, arr)
  # generic: top-level `if` + final return (special shapes handled above)
  var conds, rets: seq[string]
  var bi = 0
  while true:
    let f = body.find("if ", bi)
    if f < 0: break
    let br = body.find('{', f)
    if br < 0: break
    let ret = body.find("return ", br)
    if ret < 0: break
    if body[br + 1 ..< ret].contains('{'):
      # nested `if` (e.g. Pashto gates on the month first): skip the
      # whole outer block so inner branches never pose as top-level.
      bi = findMatching(body, br) + 1
      continue
    var rx = ret
    while rx < body.len and body[rx] notin {'\n', ';'}: inc rx
    conds.add body[f + 3 ..< br].strip()
    rets.add body[ret + 7 ..< rx].strip()
    bi = rx
  let lastRet = body.rfind("return ")
  let tail = body[lastRet + 7 .. ^1].strip()
  var tab: array[3, seq[string]]
  for ai, abbr in [3, 4, 5]:
    var expr = tail
    for k in 0 ..< conds.len:
      if condMatches(conds[k], abbr):
        expr = rets[k]
        break
    for mo in 1 .. 12:
      tab[ai].add evalExpr(expr, mo, arrays)
  (tab[0], tab[1], tab[2])

type LangEntry = tuple[lcid: int, tags: seq[string], fn, ap, wn,
  wna: string, gannen: bool]

func splitEntries(body: string): seq[tuple[lcid: int, text: string]] =
  var i = 0
  while i < body.len:
    var j = i
    while j < body.len and not body[j].isDigit: inc j
    if j >= body.len: break
    var k = j
    while k < body.len and body[k].isDigit: inc k
    if k + 1 >= body.len or body[k] != ':' or body[k + 1] != ' ':
      i = k
      continue
    var o = k + 2
    while o < body.len and body[o] in {' ', '\t', '\n'}: inc o
    if o >= body.len or body[o] != '{':
      i = k + 1
      continue
    let closeAt = findMatching(body, o)
    result.add (parseInt(body[j ..< k]), body[o + 1 ..< closeAt])
    i = closeAt + 1

func wordAfter(text: string, key: string): string =
  ## First whitespace/comma-delimited word after `key`.
  let p = text.find(key)
  if p < 0: return ""
  var i = p + key.len
  while i < text.len and text[i] in {' ', '\t', '\n', ','}: inc i
  var j = i
  while j < text.len and text[j] notin {' ', '\t', '\n', ','}: inc j
  text[i ..< j]

func nimStr(s: string): string =
  if s.startsWith("@@BYTE1:"):
    return "\"\\x" & s["@@BYTE1:".len .. ^1] & "\""
  result = "\""
  for c in s:
    case c
    of '"': result.add "\\\""
    of '\\': result.add "\\\\"
    of '\n': result.add "\\n"
    of '\t': result.add "\\t"
    else: result.add c
  result.add "\""

func nimArr(items: seq[string]): string =
  "[" & items.mapIt(nimStr(it)).join(", ") & "]"

proc main() =
  let src = readFile(Src)
  let arrays = parseArrays(src)
  let apfmt = parseApFmt(src)
  let funcs = extractFuncs(src)
  echo "arrays: ", arrays.len
  echo "apFmt: ", apfmt.len
  echo "month funcs: ", funcs.len
  let mi = src.find("supportedLanguageInfo = map[int]languageInfo{")
  let openAt = src.find('{', mi)
  let closeAt = findMatching(src, openAt)
  let langBody = src[openAt + 1 ..< closeAt]
  var entries: seq[LangEntry]
  for (lcid, text) in splitEntries(langBody):
    let ts = text.find("[]string{")
    let te = text.find('}', ts)
    let tags = parseGoStrings(text[ts + 9 ..< te])
    let fn = wordAfter(text, "localMonth:")
    let api = text.find("apFmt:")
    let wni = text.find(", weekdayNames:", api)
    let ap = text[api + 6 ..< wni].strip()
    let wn = wordAfter(text, "weekdayNames:")
    let wna = wordAfter(text, "weekdayNamesAbbr:")
    entries.add (lcid, tags, fn, ap, wn, wna,
      text.contains("useGannen: true"))
  entries.sort(proc(a, b: LangEntry): int = cmp(a.lcid, b.lcid))
  echo "lcid entries: ", entries.len
  var lines: seq[string]
  lines.add "## Copyright (c) 2026 nimbase (MIT, see LICENSE at repo root)."
  lines.add "## Portions derived from excelize (https://github.com/qax-os/excelize,"
  lines.add "## commit " & Pin &
    "): locale date-format data. DO NOT EDIT;"
  lines.add "## generated by `clue build tests/gen_locale_data.nim" &
    " --out:/tmp/genloc && /tmp/genloc` from the pinned"
  lines.add "## excelize `numfmt.go` (`supportedLanguageInfo`, `localMonthsName*`,"
  lines.add "## `weekdayNames*`, `apFmt*`). Rerun after any pinned-commit bump"
  lines.add "## and diff the result."
  lines.add "##"
  lines.add "## SPDX-License-Identifier: MIT AND BSD-3-Clause"
  lines.add ""
  lines.add "let XlsxLocaleById* = {"
  var items: seq[string]
  for e in entries:
    let (ab, fu, na) = monthTriple(e.fn, funcs[e.fn], arrays)
    var wf = arrays[e.wn]
    var wa = arrays[e.wna]
    if wf.len != 7: wf = arrays["weekdayNamesEnglish"]
    if wa.len != 7: wa = arrays["weekdayNamesEnglishAbbr"]
    var apv: string
    if e.ap.startsWith("nfp.AmPm["):
      apv = NfpAmPm[parseInt($e.ap["nfp.AmPm[".len])]
    elif e.ap.startsWith("strings.ToLower(nfp.AmPm["):
      apv = NfpAmPm[parseInt(
        $e.ap["strings.ToLower(nfp.AmPm[".len])].toLowerAscii()
    elif e.ap in apfmt:
      apv = apfmt[e.ap]
    else:
      raise newException(ValueError, "unhandled apFmt: " & e.ap)
    var tags = ""
    for t in e.tags:
      if tags.len > 0: tags.add ", "
      tags.add nimStr(t)
    items.add "  " & $e.lcid & ": XlsxLocale(tags: @[" & tags & "],\n" &
      "    monthsFull: " & nimArr(fu) & ",\n" &
      "    monthsAbbrev: " & nimArr(ab) & ",\n" &
      "    monthsNarrow: " & nimArr(na) & ",\n" &
      "    weekdaysFull: " & nimArr(wf) & ",\n" &
      "    weekdaysAbbrev: " & nimArr(wa) & ",\n" &
      "    apFmt: " & nimStr(apv) & ", useGannen: " &
      (if e.gannen: "true" else: "false") & "),"
  lines.add items.join("\n")
  lines.add "}.toTable"
  writeFile(Out, lines.join("\n") & "\n")
  echo "wrote ", Out, " entries: ", entries.len

main()
