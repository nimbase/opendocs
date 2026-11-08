## Copyright (c) 2026 nimbase (MIT, see LICENSE at repo root).
## Portions derived from xuri/efp (https://github.com/xuri/efp,
## commit 2ddeb826f9a9, 2026-05-30, BSD-3-Clause): Copyright (c) 2016-2026
## The excelize Authors. SPDX-License-Identifier: MIT AND BSD-3-Clause
##
## Formula tokenizer: exact port of efp's `getTokens` + `Render`
## (Bachtal's algorithm). Token type/subtype vocabulary mirrors efp
## because shared-formula expansion keys on `Operand`/`Range`, and
## `getCellFormula` parity needs byte-identical re-rendering.
##
## Deliberate efp quirks, all reproduced and fixture-tested:
## - The first raw token is always dropped. efp's `ExcelParser` returns a
##   bare `Parser{}` whose cursor starts at 0 (not -1), so the copy loop
##   begins at raw index 1. The `=` prepend masks it: formulas without a
##   leading `=` lose the synthetic one, formulas with one lose it too
##   (`=A1` and `A1` tokenize identically; `==A1` keeps one `=`).
## - Quoted sheet names lose their quotes (`'My Sheet'!A1` renders as
##   `My Sheet!A1`); text literals lose their doubling (`"a""b"` renders
##   `"a"b"`); `{1,2;3,4}` renders as `ARRAY(ARRAYROW(1,2),ARRAYROW(3,4))`.
## - Whitespace is only ASCII space; tabs/newlines accumulate into
##   operands. Only single spaces can become intersection operators.
## - A leading `+` becomes `Noop` and vanishes; `-` becomes prefix.
## - Go `ParseFloat` classifies operands: hex float literals and the
##   like count as numbers there but as ranges here (exotic; the common
##   decimal/exponent forms agree).

import std/[strutils, unicode]

type
  FmTokKind* = enum
    ## efp `TokenType` vocabulary.
    ftkOperand, ftkFunction, ftkSubexpr, ftkArgument, ftkOpPrefix,
    ftkOpInfix, ftkOpPostfix, ftkWhitespace, ftkUnknown, ftkNoop
  FmTokSub* = enum
    ## efp `TokenSubType` vocabulary (`ftsNone` = efp's `""`).
    ftsNone, ftsStart, ftsStop, ftsText, ftsNumber, ftsLogical, ftsError,
    ftsRange, ftsMath, ftsConcat, ftsIntersect, ftsUnion
  FmTok* = object
    kind*: FmTokKind
    sub*: FmTokSub
    text*: string

const fmErrors = ["#NULL!", "#DIV/0!", "#VALUE!", "#REF!", "#NAME?",
  "#NUM!", "#N/A", "#SPILL!", "#CALC!", "#GETTING_DATA"]
  ## efp `isAnError` list, order irrelevant (exact match).

func isInfixOp(r: Rune): bool =
  $r in ["+", "-", "*", "/", "^", "&", "=", ">", "<"]

func isComparisonPair(a, b: Rune): bool =
  ## efp `isInComparisonSet`: `<=`, `>=`, `<>`.
  if $a != ">" and $a != "<": return false
  $b == "=" or ($a == "<" and $b == ">")

func matchesExp(s: string): bool =
  ## efp `expRegex` (`^[1-9](\.[0-9]+)?E$`) over the pending token.
  if s.len < 2 or s[0] notin {'1' .. '9'}: return false
  if s[^1] != 'E': return false
  let mid = s[1 .. ^2]
  if mid.len == 0: return true
  if not mid.startsWith("."): return false
  if mid.len == 1: return false
  for ch in mid[1 .. ^1]:
    if ch notin {'0' .. '9'}: return false
  true

proc parseFormulaToks*(formula: string): seq[FmTok] =
  ## Tokenize a formula (stored form, without leading `=`), exactly like
  ## efp `Parse`: synthetic `=` prepend, state machine, the drop-first
  ## quirk, whitespace filtering, unary/subtype resolution, noop removal.
  var runes = toRunes(formula.strip())
  if runes.len > 0 and runes[0] != Rune('='):
    runes = @[Rune('=')] & runes
  var raw: seq[FmTok]
  var stack: seq[FmTok]
  var tok = ""
  var inString, inPath, inRange, inError: bool
  var off = 0
  template cur(): Rune = runes[off]
  template nxt(): Rune =
    if off + 1 < runes.len: runes[off + 1] else: Rune(0)
  proc flushOperand() =
    if tok.len > 0:
      raw.add FmTok(kind: ftkOperand, sub: ftsNone, text: tok)
      tok = ""
  proc popStop(): FmTok =
    ## efp `Tokens.pop`: empty stack yields Function/Stop; otherwise the
    ## popped type with cleared text and forced Stop.
    if stack.len == 0:
      return FmTok(kind: ftkFunction, sub: ftsStop, text: "")
    var t = stack.pop()
    t.text = ""
    t.sub = ftsStop
    t
  while off < runes.len:
    if inString:
      if cur() == Rune('"'):
        if nxt() == Rune('"'):
          tok.add '"'
          inc off
        else:
          inString = false
          raw.add FmTok(kind: ftkOperand, sub: ftsText, text: tok)
          tok = ""
      else:
        tok.add $cur()
      inc off
      continue
    if inPath:
      if cur() == Rune('\''):
        if nxt() == Rune('\''):
          tok.add '\''
          inc off
        else:
          inPath = false
      else:
        tok.add $cur()
      inc off
      continue
    if inRange:
      if cur() == Rune(']'): inRange = false
      tok.add $cur()
      inc off
      continue
    if inError:
      tok.add $cur()
      inc off
      if tok in fmErrors:
        raw.add FmTok(kind: ftkOperand, sub: ftsError, text: tok)
        tok = ""
      continue
    if tok.runeLen > 1 and (cur() == Rune('+') or cur() == Rune('-')) and
        matchesExp(tok):
      tok.add $cur()
      inc off
      continue
    if cur() == Rune('"'):
      if tok.len > 0:
        raw.add FmTok(kind: ftkUnknown, sub: ftsNone, text: tok)
        tok = ""
      inString = true
      inc off
      continue
    if cur() == Rune('\''):
      if tok.len > 0:
        raw.add FmTok(kind: ftkUnknown, sub: ftsNone, text: tok)
        tok = ""
      inPath = true
      inc off
      continue
    if cur() == Rune('['):
      inRange = true
      tok.add $cur()
      inc off
      continue
    if cur() == Rune('#'):
      if tok.len > 0:
        raw.add FmTok(kind: ftkUnknown, sub: ftsNone, text: tok)
        tok = ""
      inError = true
      tok.add $cur()
      inc off
      continue
    if cur() == Rune('{'):
      if tok.len > 0:
        raw.add FmTok(kind: ftkUnknown, sub: ftsNone, text: tok)
        tok = ""
      # efp `add` appends to the stream and pushes a copy to the stack.
      raw.add FmTok(kind: ftkFunction, sub: ftsStart, text: "ARRAY")
      stack.add FmTok(kind: ftkFunction, sub: ftsStart, text: "ARRAY")
      raw.add FmTok(kind: ftkFunction, sub: ftsStart, text: "ARRAYROW")
      stack.add FmTok(kind: ftkFunction, sub: ftsStart, text: "ARRAYROW")
      inc off
      continue
    if cur() == Rune(';'):
      flushOperand()
      raw.add popStop()
      raw.add FmTok(kind: ftkArgument, sub: ftsNone, text: ",")
      raw.add FmTok(kind: ftkFunction, sub: ftsStart, text: "ARRAYROW")
      stack.add FmTok(kind: ftkFunction, sub: ftsStart, text: "ARRAYROW")
      inc off
      continue
    if cur() == Rune('}'):
      flushOperand()
      raw.add popStop()
      raw.add popStop()
      inc off
      continue
    if cur() == Rune(' '):
      flushOperand()
      raw.add FmTok(kind: ftkWhitespace, sub: ftsNone, text: "")
      inc off
      while off < runes.len and runes[off] == Rune(' '): inc off
      continue
    if off + 1 < runes.len and isComparisonPair(cur(), nxt()):
      flushOperand()
      raw.add FmTok(kind: ftkOpInfix, sub: ftsLogical,
        text: $cur() & $nxt())
      off += 2
      continue
    if isInfixOp(cur()):
      flushOperand()
      raw.add FmTok(kind: ftkOpInfix, sub: ftsNone, text: $cur())
      inc off
      continue
    if cur() == Rune('%'):
      flushOperand()
      raw.add FmTok(kind: ftkOpPostfix, sub: ftsNone, text: $cur())
      inc off
      continue
    if cur() == Rune('('):
      if tok.len > 0:
        let ft = FmTok(kind: ftkFunction, sub: ftsStart, text: tok)
        raw.add ft
        stack.add ft
        tok = ""
      else:
        let st = FmTok(kind: ftkSubexpr, sub: ftsStart, text: "")
        raw.add st
        stack.add st
      inc off
      continue
    if cur() == Rune(','):
      flushOperand()
      if stack.len > 0 and stack[^1].kind == ftkFunction:
        raw.add FmTok(kind: ftkArgument, sub: ftsNone, text: ",")
      else:
        raw.add FmTok(kind: ftkOpInfix, sub: ftsUnion, text: ",")
      inc off
      continue
    if cur() == Rune(')'):
      flushOperand()
      raw.add popStop()
      inc off
      continue
    tok.add $cur()
    inc off
  flushOperand()
  # efp `ExcelParser` zero-value cursor: the whitespace-filter copy loop
  # starts at raw index 1, silently dropping raw index 0 (always the
  # synthetic `=`). Reproduce by deleting it; the sandwich checks below
  # are unaffected (a dropped `=` infix could never satisfy them).
  if raw.len > 0: raw.delete(0)
  # whitespace filtering: survivors become intersection operators
  var filt: seq[FmTok]
  for i, t in raw:
    if t.kind != ftkWhitespace:
      filt.add t
      continue
    if i == 0 or i == raw.len - 1: continue
    let pv = raw[i - 1]
    let nx = raw[i + 1]
    let prevOk = (pv.kind == ftkFunction and pv.sub == ftsStop) or
      (pv.kind == ftkSubexpr and pv.sub == ftsStop) or
      pv.kind == ftkOperand
    let nextOk = (nx.kind == ftkFunction and nx.sub == ftsStart) or
      (nx.kind == ftkSubexpr and nx.sub == ftsStart) or
      nx.kind == ftkOperand
    if prevOk and nextOk:
      filt.add FmTok(kind: ftkOpInfix, sub: ftsIntersect, text: "")
  # unary operators and subtype resolution (in place, forward)
  for i in 0 ..< filt.len:
    let pvKind = if i == 0: ftkNoop else: filt[i - 1].kind
    let pvSub = if i == 0: ftsNone else: filt[i - 1].sub
    if filt[i].kind == ftkOpInfix and filt[i].text == "-":
      if i == 0:
        filt[i].kind = ftkOpPrefix
      elif (pvKind == ftkFunction and pvSub == ftsStop) or
          (pvKind == ftkSubexpr and pvSub == ftsStop) or
          pvKind == ftkOpPostfix or pvKind == ftkOperand:
        filt[i].sub = ftsMath
      else:
        filt[i].kind = ftkOpPrefix
    elif filt[i].kind == ftkOpInfix and filt[i].text == "+":
      if i == 0:
        filt[i].kind = ftkNoop
      elif (pvKind == ftkFunction and pvSub == ftsStop) or
          (pvKind == ftkSubexpr and pvSub == ftsStop) or
          pvKind == ftkOpPostfix or pvKind == ftkOperand:
        filt[i].sub = ftsMath
      else:
        filt[i].kind = ftkNoop
    elif filt[i].kind == ftkOpInfix and filt[i].sub == ftsNone:
      if filt[i].text[0] in {'<', '>', '='}:
        filt[i].sub = ftsLogical
      elif filt[i].text.len == 1 and filt[i].text[0] == '&':
        filt[i].sub = ftsConcat
      else:
        filt[i].sub = ftsMath
    elif filt[i].kind == ftkOperand and filt[i].sub == ftsNone:
      let (_, ok) =
        try: (parseFloat(filt[i].text), true)
        except ValueError: (0.0, false)
      if not ok:
        if filt[i].text == "TRUE" or filt[i].text == "FALSE":
          filt[i].sub = ftsLogical
        else:
          filt[i].sub = ftsRange
      else:
        filt[i].sub = ftsNumber
    elif filt[i].kind == ftkFunction and filt[i].text.len > 0 and
        filt[i].text[0] == '@':
      filt[i].text = filt[i].text[1 .. ^1]
  # noop removal
  for t in filt:
    if t.kind != ftkNoop: result.add t

func renderFormulaToks*(toks: seq[FmTok]): string =
  ## efp `Render`: functions and subexpressions regain parens, text
  ## regains (undoubled) quotes, intersections regain a space.
  for t in toks:
    case t.kind
    of ftkFunction:
      if t.sub == ftsStart:
        result &= t.text
        result &= "("
      else:
        result &= ")"
    of ftkSubexpr:
      if t.sub == ftsStart: result &= "("
      else: result &= ")"
    of ftkOperand:
      if t.sub == ftsText:
        result &= "\"" & t.text & "\""
      else:
        result &= t.text
    of ftkOpInfix:
      if t.sub == ftsIntersect: result &= " "
      else: result &= t.text
    else:
      result &= t.text

proc shiftSharedToken*(val: string, dCol, dRow: int): string =
  ## Port of excelize `shiftCell`: shift each `:`-separated part by the
  ## anchor-to-target delta, honoring `$` absolutes. Whole-column names
  ## shift columns, whole-row numbers shift rows; cross-sheet and
  ## otherwise unparseable parts pass through. Overflow blanks the part
  ## (excelize ignores the `CoordinatesToCellName` error, yielding `""`).
  ## Column letters resolve case-insensitively like Go's
  ## `ColumnNameToNumber` (output stays uppercase); leading-zero rows
  ## (`A01`) do not resolve here (they do in excelize) — see header.
  var parts = val.split(':')
  for j in 0 ..< parts.len:
    let cell = parts[j]
    let trimmed = cell.replace("$", "").toUpperAscii()
    try:
      let (c, r) = splitCellRef(trimmed)
      let absCol = cell.startsWith("$")
      let absRow = cell.rfind('$') > 0
      if not absCol and not absRow:
        try: parts[j] = joinCellName(c + dCol, r + dRow)
        except XlsxError: parts[j] = ""
      elif not absCol and absRow:
        try: parts[j] = columnNumberToName(c + dCol) & "$" & $r
        except XlsxError: parts[j] = ""
      elif absCol and not absRow:
        try: parts[j] = "$" & columnNumberToName(c) & $(r + dRow)
        except XlsxError: parts[j] = ""
      continue # both absolute: unchanged
    except XlsxError:
      discard
    try:
      if not cell.startsWith("$"):
        let cn = columnNameToNumber(trimmed)
        try: parts[j] = columnNumberToName(cn + dCol)
        except XlsxError: parts[j] = ""
        continue
    except XlsxError:
      discard
    try:
      if not cell.startsWith("$"):
        parts[j] = $(parseInt(trimmed) + dRow)
    except ValueError:
      discard
  parts.join(":")

proc expandSharedFormula*(content: string, anchorCol, anchorRow,
    targetCol, targetRow: int): string =
  ## Port of excelize `convertSharedFormula`: tokenize the anchor
  ## formula, shift every `Operand`/`Range` token by the anchor-to-target
  ## delta, re-render. Overflows blank the shifted part.
  let dCol = targetCol - anchorCol
  let dRow = targetRow - anchorRow
  var toks = parseFormulaToks(content)
  for i in 0 ..< toks.len:
    if toks[i].kind == ftkOperand and toks[i].sub == ftsRange:
      toks[i].text = shiftSharedToken(toks[i].text, dCol, dRow)
  renderFormulaToks(toks)
