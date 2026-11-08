## Page labels (ISO 32000 §12.4.2): "i, ii, iii, 1, 2, A-1…".
##
## /PageLabels is a number tree of ranges: from page `start` on, print
## `prefix` plus the style numeral of first + (page - start). Styles:
## D decimal, R/R upper/lower roman, A/a upper/lower alpha, absent/else
## prefix-only (/St ignored then). Ranges sort by start with later
## duplicates winning, like readers that overwrite. No /PageLabels (or
## no range covering a page) is "", never guessed.

import std/algorithm
import std/strutils
import ./cos
import ./docmodel
import ./names

type
  PdfPageLabel* = object
    style*: string ## D R r A a, "" for prefix-only
    prefix*: string
    start*: int ## 0-based first page of the range
    first*: int ## /St: number of the range's first page (>= 1)

proc romanNumeral(n: int): string =
  ## Uppercase roman, subtractive. Empty for n < 1 (caller falls back).
  if n < 1: return ""
  var m = n
  const table = [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"),
    (100, "C"), (90, "XC"), (50, "L"), (40, "XL"), (10, "X"), (9, "IX"),
    (5, "V"), (4, "IV"), (1, "I")]
  for (v, s) in table:
    while m >= v:
      result.add(s)
      m -= v

proc alphaLabel(n: int): string =
  ## Uppercase A..Z, AA..AZ… like spreadsheet columns. Empty for n < 1.
  if n < 1: return ""
  var m = n
  while m > 0:
    dec m
    result = char(ord('A') + (m mod 26)) & result
    m = m div 26

proc formatNumeral(style: string, n: int): string =
  ## Style numeral for n >= 1, capped: overlong numerals fall back to
  ## decimal (reference parity).
  case style
  of "D":
    $n
  of "R", "r":
    let r = romanNumeral(n)
    if r.len == 0 or r.len > 1024:
      return $n
    if style == "r": r.toLowerAscii() else: r
  of "A", "a":
    let a = alphaLabel(n)
    if a.len == 0 or a.len > 1024:
      return $n
    if style == "a": a.toLowerAscii() else: a
  else:
    ""

proc labelStyleName(s: CosObj): string =
  if s.kind == coName and s.name in ["D", "R", "r", "A", "a"]:
    s.name
  else:
    ""

proc pageLabels*(d: var PdfDoc): seq[PdfPageLabel] =
  ## Label ranges sorted by start page (empty when no /PageLabels).
  ## A start given twice keeps its later range.
  let tree = d.catalog().dictGet("PageLabels")
  if tree.kind == coNull:
    return @[]
  var ranges: seq[PdfPageLabel] = @[]
  for (num, spec) in d.numberTreePairs(tree):
    if num < 0: continue
    var v = spec
    if v.kind == coRef:
      v = d.resolve(v)
    if v.kind != coDict: continue
    let style = labelStyleName(v.dictGet("S"))
    var prefix = ""
    let p = v.dictGet("P")
    if p.kind == coStr:
      prefix = p.sval
    elif p.kind != coNull:
      continue
    var first = 1 # /St without a style is ignored downstream
    let st = v.dictGet("St")
    if st.kind == coInt and st.ival >= 1:
      first = st.ival
    ranges.add(PdfPageLabel(style: style, prefix: prefix, start: num,
      first: first))
  ranges.sort(proc(a, b: PdfPageLabel): int = cmp(a.start, b.start))
  for r in ranges:
    if result.len > 0 and result[^1].start == r.start:
      result[^1] = r
    else:
      result.add(r)

proc labelForPage*(labels: seq[PdfPageLabel], pageIndex: int): string =
  ## Printed label for a 0-based page, "" when no range covers it.
  var at = -1
  for i, r in labels:
    if r.start <= pageIndex:
      at = i
    else:
      break
  if at < 0: return ""
  let r = labels[at]
  if r.style.len == 0:
    return r.prefix
  r.prefix & formatNumeral(r.style, r.first + (pageIndex - r.start))
