## Copyright (c) 2026 nimbase (MIT, see LICENSE at repo root).
## Portions derived from excelize (https://github.com/qax-os/excelize,
## commit 0434413, 2026-09-18) and xuri/nfp
## (https://github.com/xuri/nfp/tree/2ddeb826f9a9, BSD-3-Clause).
## SPDX-License-Identifier: MIT AND BSD-3-Clause
##
## Format-code tokenizer: pure port of the pinned `nfp` state machine.
## Parsing only; rendering and value formatting stay in `xlsx/numfmt`.
##
## Each token keeps delimiter information structurally (`quoted`, `escaped`,
## `marker`, bracket interiors in `text`) so the tested corpus can be
## reconstructed exactly. Section names and token-type names match `nfp`.

import std/[strutils, unicode]

const
  numFmtSectionKinds = ["Positive", "Negative", "Zero", "Text"]
  numFmtColorNames = ["black", "blue", "cyan", "green", "magenta", "red",
    "white", "yellow"]
  numFmtSwitchArgs = ["AIUEO", "ALPHABETIC", "alphabetic", "Arabic",
    "ARABICABJAD", "ARABICALPHA", "ArabicDash", "BAHTTEXT", "CardText",
    "CHINESENUM1", "CHINESENUM2", "CHINESENUM3", "CHOSUNG", "CIRCLENUM",
    "DBCHAR", "DBNUM1", "DBNUM2", "DBNUM3", "DBNUM4", "DollarText", "GANADA",
    "GB1", "GB2", "GB3", "GB4", "HEBREW1", "HEBREW2", "Hex", "HINDIARABIC",
    "HINDICARDTEXT", "HINDILETTER1", "HINDILETTER2", "IROHA", "KANJINUM1",
    "KANJINUM2", "KANJINUM3", "Ordinal", "OrdText", "Roman", "roman",
    "SBCHAR", "THAIARABIC", "THAICARDTEXT", "THAILETTER", "VIETCARDTEXT",
    "ZODIAC1", "ZODIAC2", "ZODIAC3"]
  numFmtAmPm = ["AM/PM", "A/P", "\u4e0a\u5348/\u4e0b\u5348"]
  numFmtConditions = ["<", "<=", ">", ">=", "<>", "="]
  numFmtDateChars = "ABDEGHMRSY"

type
  NumFmtPart* = object
    kind*: string
    value*: string

  NumFmtToken* = object
    kind*: string
    text*: string
    quoted*: bool
    escaped*: bool
    marker*: string
    parts*: seq[NumFmtPart]

  NumFmtSection* = object
    kind*: string
    items*: seq[NumFmtToken]

  NumFmtAst* = object
    ok*: bool
    sections*: seq[NumFmtSection]

  NumFmtParser = object
    runes: seq[Rune]
    offset: int
    inBracket: bool
    inString: bool
    sections: seq[NumFmtSection]
    sectionIndex: int
    pendingKind: string
    pendingText: string
    pendingSkipped: string
    pendingQuoted: bool
    pendingEscaped: bool
    pendingMarker: string
    pendingParts: seq[NumFmtPart]
    valid: bool

func isAsciiDigitR(r: Rune): bool =
  let o = int(r)
  o >= ord('0') and o <= ord('9')

func upperAsciiRune(r: Rune): Rune =
  let o = int(r)
  if o >= ord('a') and o <= ord('z'): Rune(o - 32)
  else: r

func asciiFoldEq(a, b: string): bool =
  if a == b: return true
  if a.len != b.len: return false
  toUpperAscii(a) == toUpperAscii(b)

func containsAsciiDate(value: string): bool =
  for r in toRunes(value):
    if $upperAsciiRune(r) in numFmtDateChars: return true
  false

func isDateCharsLit(lit: string): bool =
  if lit.len == 0: return false
  for r in toRunes(lit):
    if $upperAsciiRune(r) notin numFmtDateChars: return false
  true

func matchRunes(p: NumFmtParser, pat: string, want: int): bool =
  if p.offset + want > p.runes.len: return false
  let pr = toRunes(pat)
  if pr.len != want:
    # Byte-length quirk in the pinned parser: a multibyte pattern can
    # demand more runes than it contains, in which case it never matches.
    # Preserve the observable behavior instead of fixing it here.
    if pr.len > want: return false
  for i in 0 ..< want:
    if i >= pr.len: return false
    let a = p.runes[p.offset + i]
    let b = pr[i]
    if a == b: continue
    let ao = int(a)
    let bo = int(b)
    if ao < 128 and bo < 128 and upperAsciiRune(a) == upperAsciiRune(b):
      continue
    return false
  true

func apMatch(p: NumFmtParser): string =
  for pat in numFmtAmPm:
    # The pinned implementation compares a byte length against rune
    # offsets, so the multibyte AM/PM form never matches. Mirror that.
    let want = if pat == numFmtAmPm[2]: pat.len
      else: toRunes(pat).len
    if matchRunes(p, pat, want): return pat
  ""

func generalMatch(p: NumFmtParser): string =
  if matchRunes(p, "General", 7): return "General"
  ""

func curRune(p: NumFmtParser): Rune =
  p.runes[p.offset]

func nextRune(p: NumFmtParser): Rune =
  if p.offset + 1 < p.runes.len: p.runes[p.offset + 1]
  else: Rune(0)

func doubleStr(p: NumFmtParser): string =
  if p.offset + 1 < p.runes.len: $p.runes[p.offset] & $p.runes[p.offset + 1]
  else: ""

proc ensureSection(p: var NumFmtParser) =
  while p.sections.len <= p.sectionIndex:
    p.sections.add NumFmtSection(kind: numFmtSectionKinds[p.sectionIndex])

proc emitToken(p: var NumFmtParser, kind, text: string, quoted, escaped: bool,
    marker: string, parts: seq[NumFmtPart]) =
  ensureSection(p)
  p.sections[p.sectionIndex].items.add NumFmtToken(kind: kind, text: text,
    quoted: quoted, escaped: escaped, marker: marker, parts: parts)

proc resetPending(p: var NumFmtParser) =
  p.pendingKind = ""
  p.pendingText = ""
  p.pendingSkipped = ""
  p.pendingQuoted = false
  p.pendingEscaped = false
  p.pendingMarker = ""
  p.pendingParts = @[]

proc hasPending(p: NumFmtParser): bool =
  p.pendingText != "" or p.pendingKind != "" or p.pendingParts.len > 0 or
    p.pendingQuoted or p.pendingEscaped or p.pendingMarker != ""

proc alignmentText(p: NumFmtParser): string =
  if p.pendingText.len > 1: p.pendingSkipped & p.pendingText[1 .. ^1]
  else: p.pendingSkipped

proc emitPending(p: var NumFmtParser) =
  if not hasPending(p): return
  if p.pendingKind == "Alignment":
    emitToken(p, "Alignment", alignmentText(p), false, false, "_", p.pendingParts)
  else:
    let kind = if p.pendingKind == "": "Literal" else: p.pendingKind
    emitToken(p, kind, p.pendingText, p.pendingQuoted, p.pendingEscaped,
      p.pendingMarker, p.pendingParts)
  resetPending(p)

proc parseNumFmt*(code: string): NumFmtAst =
  ## Tokenize one format code. `ok` is false only for an invalid shape
  ## (currently more than three `;` separators). No value formatting happens
  ## here, so existing formatted output is unchanged.
  var p = NumFmtParser(runes: toRunes(code.strip()), valid: true)
  while p.offset < p.runes.len:
    let r = curRune(p)
    let rs = $r
    let rn = nextRune(p)
    let rns = if p.offset + 1 < p.runes.len: $rn else: ""

    if p.inBracket:
      if p.pendingKind == "CurrencyLanguage":
        if rs != "-" and rs != "]":
          if p.pendingParts.len == 0:
            p.pendingParts.add NumFmtPart(kind: "CurrencyString", value: "")
          p.pendingParts[^1].value.add rs
        if rs == "-" and rns != "]":
          if p.pendingParts.len == 0:
            p.pendingParts.add NumFmtPart(kind: "LanguageInfo", value: "")
          else:
            if p.pendingParts[0].kind != "LanguageInfo" and
                p.pendingParts[0].value != "":
              p.pendingParts.add NumFmtPart(kind: "LanguageInfo", value: "")
            else:
              p.pendingParts[^1].value.add rs
        if rs == ",":
          p.pendingText.add rs
          p.offset += 1
          continue

      if p.pendingText.len > 1 and p.pendingText[1 .. ^1] in numFmtConditions:
        if rs == "-" or isAsciiDigitR(r):
          p.pendingKind = "Condition"
          p.pendingParts = @[NumFmtPart(kind: "Operator",
            value: p.pendingText[1 .. ^1]),
            NumFmtPart(kind: "Operand", value: "")]
          p.pendingText = ""
          p.pendingText.add rs
          p.offset += 1
          continue

      if rs == "]":
        p.inBracket = false
        if p.pendingKind == "Condition" and p.pendingParts.len == 2:
          p.pendingParts[1].value = p.pendingText
          emitToken(p, "Condition",
            p.pendingParts[0].value & p.pendingParts[1].value,
            false, false, "", p.pendingParts)
          resetPending(p)
          p.offset += 1
          continue
        p.pendingText.add rs
        if p.pendingText.len > 2:
          let lit = p.pendingText[1 .. ^2]
          var matched = false
          for name in numFmtColorNames:
            if asciiFoldEq(lit, name):
              emitToken(p, "Color", lit, false, false, "", @[])
              matched = true
              break
          if matched:
            resetPending(p)
            p.offset += 1
            continue
          for sw in numFmtSwitchArgs:
            if asciiFoldEq(lit, sw):
              emitToken(p, "SwitchArgument", lit, false, false, "", @[])
              matched = true
              break
          if matched:
            resetPending(p)
            p.offset += 1
            continue
          if p.pendingKind == "CurrencyLanguage":
            emitToken(p, "CurrencyLanguage", lit, false, false, "",
              p.pendingParts)
            resetPending(p)
            p.offset += 1
            continue
          let kind = if isDateCharsLit(lit): "ElapsedDateTimes" else: "Unknown"
          emitToken(p, kind, lit, false, false, "", p.pendingParts)
          resetPending(p)
          p.offset += 1
          continue

    if not p.inBracket:
      if isAsciiDigitR(r):
        if p.pendingKind == "ZeroPlaceHolder" or
            p.pendingKind == "Denominator":
          p.pendingText.add rs
          p.offset += 1
          continue
        if p.pendingKind == "Fraction":
          emitPending(p)
          p.pendingKind = "Denominator"
          p.pendingText = rs
          p.offset += 1
          continue
        if toUpperAscii(p.pendingText) == "B":
          if rs == "1" or rs == "2":
            emitToken(p, p.pendingKind, p.pendingText & rs, p.pendingQuoted,
              p.pendingEscaped, p.pendingMarker, p.pendingParts)
            resetPending(p)
            p.offset += 1
            continue
          p.pendingKind = "Literal"
          p.pendingText.add rs
          p.offset += 1
          continue
        if p.pendingKind != "":
          emitPending(p)
        p.pendingKind = if rs == "0": "ZeroPlaceHolder" else: "Literal"
        p.pendingText.add rs
        p.offset += 1
        continue

      if rs == "#":
        if p.pendingKind != "HashPlaceHolder" and p.pendingKind != "":
          if p.pendingText == ".":
            p.pendingKind = "DecimalPoint"
          emitPending(p)
        p.pendingKind = "HashPlaceHolder"
        p.pendingText.add rs
        p.offset += 1
        continue

      if rs == ".":
        if p.pendingKind == "ZeroPlaceHolder" or
            p.pendingKind == "HashPlaceHolder":
          emitPending(p)
          emitToken(p, "DecimalPoint", rs, false, false, "", p.pendingParts)
          resetPending(p)
          p.offset += 1
          continue
        if p.pendingKind == "DateTimes" and not isAsciiDigitR(rn):
          emitPending(p)
          emitToken(p, "Literal", rs, false, false, "", p.pendingParts)
          resetPending(p)
          p.offset += 1
          continue
        if not p.inString:
          if p.pendingKind != "" and isAsciiDigitR(rn):
            emitPending(p)
          p.pendingKind = "DecimalPoint"
        p.pendingText.add rs
        p.offset += 1
        continue

    if rs in ["$", "-", "+", "(", ")", ":", " "]:
      if p.inBracket:
        p.pendingText.add rs
        p.pendingKind = "CurrencyLanguage"
        p.offset += 1
        continue
      if p.pendingKind != "Literal" and p.pendingKind != "DateTimes" and
          p.pendingKind != "":
        let oldParts = p.pendingParts
        emitToken(p, p.pendingKind, p.pendingText, p.pendingQuoted,
          p.pendingEscaped, p.pendingMarker, oldParts)
        resetPending(p)
        p.pendingKind = "Literal"
        p.pendingText = rs
        p.pendingParts = oldParts
        p.offset += 1
        continue
      if p.pendingText != "\\" and p.pendingKind == "" and
          not asciiFoldEq(p.pendingText, "AM/PM") and
          not asciiFoldEq(p.pendingText, "A/P") and
          p.pendingText != numFmtAmPm[2]:
        p.pendingKind = "Literal"
      if p.pendingKind == "Literal":
        p.pendingText.add rs
        p.offset += 1
        continue

    if rs == "_":
      if p.pendingKind != "":
        emitPending(p)
      p.pendingKind = "Alignment"
      p.pendingText = " "
      p.pendingSkipped = rns
      p.pendingMarker = "_"
      p.offset += 2
      continue

    if rs == "*":
      if p.pendingText != "":
        emitPending(p)
      emitToken(p, "RepeatsChar", rns, false, false, "*", @[])
      resetPending(p)
      p.offset += 2
      continue

    if rs == "\\":
      if p.pendingText != "":
        emitPending(p)
      emitToken(p, "Literal", rns, false, true, "", @[])
      resetPending(p)
      p.offset += 2
      continue

    if rs == "-":
      let oldParts = p.pendingParts
      let oldQuoted = p.pendingQuoted
      let oldEscaped = p.pendingEscaped
      let oldMarker = p.pendingMarker
      if p.pendingKind != "":
        emitToken(p, p.pendingKind, p.pendingText, oldQuoted, oldEscaped,
          oldMarker, oldParts)
        resetPending(p)
      p.pendingKind = "Literal"
      p.pendingQuoted = p.inString
      if rns != "":
        emitToken(p, "Literal", rs, p.inString, false, "", oldParts)
        resetPending(p)
      p.offset += 1
      continue

    if rs == ",":
      if p.pendingKind == "ZeroPlaceHolder" or
          p.pendingKind == "HashPlaceHolder":
        emitPending(p)
        emitToken(p, "ThousandsSeparator", rs, false, false, "",
          p.pendingParts)
        resetPending(p)
        p.offset += 1
        continue
      if not p.inString:
        let oldParts = p.pendingParts
        if p.pendingKind == "Literal":
          emitToken(p, "Literal", p.pendingText, p.pendingQuoted,
            p.pendingEscaped, p.pendingMarker, oldParts)
          resetPending(p)
          p.pendingKind = "ThousandsSeparator"
        if p.pendingKind == "DateTimes":
          emitToken(p, "DateTimes", p.pendingText, p.pendingQuoted,
            p.pendingEscaped, p.pendingMarker, oldParts)
          resetPending(p)
          p.pendingKind = "Literal"
        if rns != "":
          if p.pendingKind == "":
            p.pendingKind = "Literal"
          emitToken(p, p.pendingKind, rs, p.inString, false, "", oldParts)
          resetPending(p)
        else:
          resetPending(p)
        p.offset += 1
        continue
      p.pendingKind = "Literal"
      p.pendingText.add rs
      p.offset += 1
      continue

    if rs == " ":
      if p.pendingKind != "" and p.pendingKind != "Literal":
        emitPending(p)
      p.pendingKind = "Literal"
      p.pendingQuoted = p.inString
      emitToken(p, "Literal", rs, p.inString, false, "", p.pendingParts)
      resetPending(p)
      p.offset += 1
      continue

    if rs == "/":
      if p.pendingKind == "DateTimes":
        let oldParts = p.pendingParts
        emitToken(p, "DateTimes", p.pendingText, p.pendingQuoted,
          p.pendingEscaped, p.pendingMarker, oldParts)
        resetPending(p)
        emitToken(p, "Literal", rs, p.inString, false, "", oldParts)
        resetPending(p)
        p.offset += 1
        continue
      if p.pendingKind == "DigitalPlaceHolder":
        emitPending(p)
        p.pendingKind = "Fraction"
        p.pendingText = rs
        p.offset += 1
        continue

    if rs == ":" and p.pendingKind == "DateTimes":
      let oldParts = p.pendingParts
      emitToken(p, "DateTimes", p.pendingText, p.pendingQuoted,
        p.pendingEscaped, p.pendingMarker, oldParts)
      resetPending(p)
      emitToken(p, "Literal", rs, p.inString, false, "", oldParts)
      resetPending(p)
      p.offset += 1
      continue

    if rs == "\"":
      p.offset += 1
      if p.inString:
        emitToken(p, "Literal", p.pendingText, true, false, "",
          p.pendingParts)
        resetPending(p)
        p.inString = false
        continue
      if p.pendingText != "":
        emitPending(p)
      p.inString = true
      p.pendingKind = "Literal"
      p.pendingQuoted = true
      continue

    if rs == "@":
      if p.sections.len <= p.sectionIndex:
        p.sections.add NumFmtSection(kind: "Text")
      p.sections[p.sectionIndex].kind = "Text"
      if p.pendingKind != "" and not p.inBracket:
        emitPending(p)
      resetPending(p)
      p.pendingKind = "TextPlaceHolder"
      p.pendingText = rs
      p.pendingQuoted = p.inString
      p.offset += 1
      continue

    if rs == "[":
      if p.pendingKind != "" and not p.inBracket:
        emitPending(p)
      p.inBracket = true
      p.pendingText.add rs
      p.offset += 1
      continue

    if rs == "?":
      if p.pendingKind != "" and p.pendingKind != "DigitalPlaceHolder":
        emitPending(p)
      p.pendingKind = "DigitalPlaceHolder"
      p.pendingText.add rs
      p.offset += 1
      continue

    if rs == "%":
      if p.pendingKind != "":
        emitPending(p)
      p.pendingKind = "Percent"
      p.pendingText = rs
      p.pendingQuoted = p.inString
      p.offset += 1
      continue

    if rs == ";":
      if p.pendingKind != "":
        emitPending(p)
      if p.sections.len <= p.sectionIndex:
        p.sections.add NumFmtSection(
          kind: numFmtSectionKinds[p.sectionIndex])
      p.sectionIndex += 1
      if p.sectionIndex > 3:
        return NumFmtAst(ok: false, sections: @[])
      resetPending(p)
      p.sections.add NumFmtSection(
        kind: numFmtSectionKinds[p.sectionIndex])
      p.offset += 1
      continue

    if asciiFoldEq(doubleStr(p), "E+"):
      if p.pendingKind != "":
        emitPending(p)
      p.pendingKind = "Exponential"
      p.pendingText = doubleStr(p)
      p.offset += 2
      continue

    let ap = apMatch(p)
    if ap != "":
      emitToken(p, "DateTimes", ap, false, false, "", p.pendingParts)
      resetPending(p)
      p.offset += toRunes(ap).len
      continue

    if generalMatch(p) != "":
      emitToken(p, "General", "General", false, false, "", p.pendingParts)
      resetPending(p)
      p.offset += 7
      continue

    if not p.inBracket and not p.inString:
      if $upperAsciiRune(r) in numFmtDateChars:
        if asciiFoldEq(p.pendingText, "AM/PM") or
            asciiFoldEq(p.pendingText, "A/P") or
            p.pendingText == numFmtAmPm[2]:
          p.pendingKind = "DateTimes"
          emitPending(p)
        if p.pendingKind == "Literal" or (p.pendingKind == "DateTimes" and
            $r notin p.pendingText):
          emitPending(p)
        if p.pendingKind != "" and p.pendingKind != "DateTimes":
          emitPending(p)
        p.pendingKind = "DateTimes"
        p.pendingText.add rs
        p.offset += 1
        continue
      if containsAsciiDate(p.pendingText):
        emitToken(p, "DateTimes", p.pendingText, p.pendingQuoted,
          p.pendingEscaped, p.pendingMarker, p.pendingParts)
        resetPending(p)
        p.pendingKind = "Literal"
        p.pendingText = rs
        p.pendingQuoted = p.inString
        p.offset += 1
        continue
      if rn != Rune(0) and $upperAsciiRune(rn) in numFmtDateChars:
        p.pendingText.add rs
        p.pendingKind = "Literal"
        p.pendingQuoted = p.inString
        p.offset += 1
        continue
      if rs == "'":
        p.offset += 1
        continue
      if not isAsciiDigitR(r) and p.pendingKind == "ZeroPlaceHolder":
        emitPending(p)
        continue
      p.pendingKind = "Literal"
      p.pendingQuoted = p.inString

    p.pendingText.add rs
    if asciiFoldEq(p.pendingText, "AM/PM") or
        asciiFoldEq(p.pendingText, "A/P") or
        p.pendingText == numFmtAmPm[2]:
      p.pendingKind = "DateTimes"
      emitPending(p)
      p.offset += 1
      continue
    p.offset += 1

  if hasPending(p):
    if p.pendingKind == "Alignment":
      emitToken(p, "Alignment", alignmentText(p), false, false, "_", @[])
    else:
      let kind = if p.pendingKind == "": "Literal" else: p.pendingKind
      emitToken(p, kind, p.pendingText, p.pendingQuoted, p.pendingEscaped,
        p.pendingMarker, @[])
  NumFmtAst(ok: true, sections: p.sections)

func renderNumFmtToken*(t: NumFmtToken): string =
  ## Exact source spelling for one token in the tested corpus.
  if t.quoted:
    return "\"" & t.text & "\""
  if t.escaped:
    return "\\" & t.text
  if t.marker == "_":
    return "_" & t.text
  if t.marker == "*":
    return "*" & t.text
  if t.kind in ["Color", "Condition", "ElapsedDateTimes", "Unknown",
      "SwitchArgument", "CurrencyLanguage"]:
    return "[" & t.text & "]"
  t.text

func renderNumFmt*(ast: NumFmtAst): string =
  ## Join sections with `;`. Invalid parses render as empty.
  if not ast.ok: return ""
  for i, sec in ast.sections:
    if i > 0: result.add ";"
    for item in sec.items:
      result.add renderNumFmtToken(item)
