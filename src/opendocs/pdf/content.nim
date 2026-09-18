## Content-stream parser (ISO 32000 §7.8, §8.2).
##
## A content stream is a flat sequence of operands followed by an
## operator: `BT /F1 12 Tf 72 720 Td (Hi) Tj ET`. Operands reuse COS
## value syntax, so they parse through cos.parseCosValue; operators are
## bare keywords terminated by a delimiter.
##
## Inline images (`BI` dict `ID` raw `EI`) carry byte data of unknown
## length. After the single whitespace following `ID`, scanning takes
## the first whitespace + `EI` + delimiter match as the end. A payload
## containing that exact byte run truncates early; producers must avoid
## it and M5 image work treats any `EI` split as suspect.

import std/strutils
import ./types
import ./lexer
import ./cos

export cos

type
  ContentOp* = object
    name*: string
    operands*: seq[CosObj]

proc scanName(lx: var Lexer): string =
  ## Inline-image dict key: '/' already consumed, `#xx` decoded.
  while lx.pos < lx.s.len and not isDelim(lx.s[lx.pos]):
    if lx.s[lx.pos] == '#' and lx.pos + 2 < lx.s.len and
        lx.s[lx.pos + 1] in HexDigits and lx.s[lx.pos + 2] in HexDigits:
      try:
        result.add(chr(parseHexInt(lx.s.slice(lx.pos + 1, lx.pos + 3))))
      except ValueError:
        pdfFail("bad # escape in inline image key")
      lx.pos += 3
    else:
      result.add(lx.s[lx.pos])
      inc lx.pos
  if result.len == 0:
    pdfFail("empty key in inline image dictionary")

proc atKeyword(lx: Lexer, kw: string): bool =
  ## Cursor sits exactly on kw followed by a delimiter or end of input.
  if not lx.continuesWith(kw):
    return false
  let after = lx.pos + kw.len
  after >= lx.s.len or isDelim(lx.s[after])

proc parseInlineImage(lx: var Lexer, limits: PdfLimits): ContentOp =
  ## Leading `BI` already consumed. Parses bare `key value` pairs to
  ## `ID`, then slices raw bytes to the first `EI` match.
  var keys: seq[string] = @[]
  var vals: seq[CosObj] = @[]
  while true:
    lx.skipWsAndComments()
    if lx.pos >= lx.s.len:
      pdfFail("unterminated inline image dictionary")
    if lx.atKeyword("ID"):
      lx.pos += 2
      break
    if lx.s[lx.pos] != '/':
      pdfFail("expected name key in inline image dictionary at offset " &
        $lx.pos)
    inc lx.pos
    keys.add(lx.scanName())
    vals.add(lx.parseCosValue())
    if keys.len > limits.maxObjects:
      pdfFail("inline image dictionary exceeds limit " &
        $limits.maxObjects)
  if lx.pos >= lx.s.len or not isWs(lx.s[lx.pos]):
    pdfFail("expected single whitespace after ID in inline image")
  inc lx.pos # exactly one whitespace byte per spec
  let dataStart = lx.pos
  var dataEnd = -1
  var i = dataStart
  while i < lx.s.len:
    if isWs(lx.s[i]) and i + 3 <= lx.s.len and
        lx.s[i + 1] == 'E' and lx.s[i + 2] == 'I' and
        (i + 3 >= lx.s.len or isDelim(lx.s[i + 3])):
      dataEnd = i
      break
    inc i
  if dataEnd < 0:
    pdfFail("unterminated inline image data")
  lx.pos = dataEnd + 3
  let dict = CosObj(kind: coDict, keys: keys, vals: vals)
  let bytes = CosObj(kind: coStr, sval: lx.s.slice(dataStart, dataEnd))
  ContentOp(name: "BI", operands: @[dict, bytes])

proc parseContentStream*(data: string,
    limits = defaultPdfLimits()): seq[ContentOp] =
  ## Tokenize one decoded content stream into operators. Trailing
  ## operands without an operator, and unknown binary garbage where a
  ## token must start, raise PdfError.
  var lx = initLexer(data)
  var operands: seq[CosObj] = @[]
  result = @[]
  while true:
    lx.skipWsAndComments()
    if lx.pos >= lx.s.len:
      break
    let c = lx.s[lx.pos]
    if c in {'+', '-', '.', '0'..'9'} or c in {'(', '<', '[', '/'}:
      operands.add(lx.parseCosValue())
      continue
    if c == 'B' and lx.atKeyword("BI"):
      if operands.len > 0:
        pdfFail("dangling operands before BI at offset " & $lx.pos)
      lx.pos += 2
      result.add(lx.parseInlineImage(limits))
    else:
      var name = ""
      while lx.pos < lx.s.len and not isDelim(lx.s[lx.pos]):
        name.add(lx.s[lx.pos])
        inc lx.pos
      if name.len == 0:
        pdfFail("bad content operator at offset " & $lx.pos)
      result.add(ContentOp(name: name, operands: operands))
      operands = @[]
    if result.len > limits.maxContentOps:
      pdfFail("content stream exceeds limit " & $limits.maxContentOps &
        " operators")
  if operands.len > 0:
    pdfFail("dangling operands at end of content stream")
