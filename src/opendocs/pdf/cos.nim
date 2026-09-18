## COS object model and value parser (ISO 32000 §7.3).
##
## Promoted from ai/pages.nim with stream-object support added: an
## indirect object whose value is a dictionary followed by
## `stream<CRLF>...<CRLF>endstream` parses to coStream holding the raw
## bytes. Streams are never decoded here; filters arrive in M2.
## Indirect /Length values need document context, so parseIndirect
## raises PdfError for them and docmodel resolves Length first.

import std/strutils
import ./lexer

export lexer

type
  CosKind* = enum
    coNull, coBool, coInt, coFloat, coName, coStr, coRef, coArray,
    coDict, coStream
  CosObj* = object
    case kind*: CosKind
    of coInt: ival*: int
    of coFloat: fval*: float64
    of coBool: bval*: bool
    of coName: name*: string
    of coStr: sval*: string
    of coRef: refNum*, refGen*: int
    of coArray: items*: seq[CosObj]
    of coDict:
      keys*: seq[string]
      vals*: seq[CosObj]
    of coStream:
      streamDict*: seq[string]
      streamVals*: seq[CosObj]
      raw*: string ## raw stream bytes (still filtered in M1)
    of coNull: discard

proc dictGet*(d: CosObj, key: string): CosObj =
  case d.kind
  of coDict:
    for i, k in d.keys:
      if k == key:
        return d.vals[i]
    CosObj(kind: coNull)
  of coStream:
    for i, k in d.streamDict:
      if k == key:
        return d.streamVals[i]
    CosObj(kind: coNull)
  else:
    CosObj(kind: coNull)

proc asFloat*(o: CosObj): float64 =
  case o.kind
  of coInt: float64(o.ival)
  of coFloat: o.fval
  else: pdfFail("expected PDF number, got " & $o.kind)

proc asInt*(o: CosObj): int =
  if o.kind == coInt: o.ival
  else: pdfFail("expected PDF integer, got " & $o.kind)

proc asName*(o: CosObj): string =
  if o.kind == coName: o.name
  else: pdfFail("expected PDF name, got " & $o.kind)

proc parseName(lx: var Lexer): string =
  ## Leading '/' already consumed. Decodes #xx escapes.
  while lx.pos < lx.s.len and not isDelim(lx.s[lx.pos]):
    if lx.s[lx.pos] == '#' and lx.pos + 2 < lx.s.len and
        lx.s[lx.pos + 1] in HexDigits and lx.s[lx.pos + 2] in HexDigits:
      try:
        result.add(chr(parseHexInt(lx.s.slice(lx.pos + 1, lx.pos + 3))))
      except ValueError:
        pdfFail("bad # escape in PDF name")
      lx.pos += 3
    else:
      result.add(lx.s[lx.pos])
      inc lx.pos
  if result.len == 0:
    pdfFail("empty PDF name at offset " & $lx.pos)

proc parseLiteral(lx: var Lexer): string =
  ## Leading '(' already consumed. Handles nesting and escapes.
  var depth = 1
  while lx.pos < lx.s.len:
    let c = lx.s[lx.pos]
    if c == '\\':
      inc lx.pos
      if lx.pos >= lx.s.len:
        break
      let e = lx.s[lx.pos]
      case e
      of 'n': result.add('\x0A'); inc lx.pos
      of 'r': result.add('\x0D'); inc lx.pos
      of 't': result.add('\x09'); inc lx.pos
      of 'b': result.add('\x08'); inc lx.pos
      of 'f': result.add('\x0C'); inc lx.pos
      of '(', ')', '\\': result.add(e); inc lx.pos
      of '\x0A': inc lx.pos
      of '\x0D':
        inc lx.pos
        if lx.pos < lx.s.len and lx.s[lx.pos] == '\x0A':
          inc lx.pos
      of '0'..'7':
        var v = 0
        for _ in 0 ..< 3:
          if lx.pos < lx.s.len and lx.s[lx.pos] in {'0'..'7'}:
            v = v * 8 + (ord(lx.s[lx.pos]) - ord('0'))
            inc lx.pos
          else:
            break
        result.add(chr(v))
      else: result.add(e); inc lx.pos
    elif c == '(':
      inc depth
      result.add(c)
      inc lx.pos
    elif c == ')':
      dec depth
      inc lx.pos
      if depth == 0:
        return
      result.add(c)
    else:
      result.add(c)
      inc lx.pos
  pdfFail("unterminated PDF string")

proc parseHexStr(lx: var Lexer): string =
  ## Leading '<' already consumed (not '<<').
  var hi = -1
  while lx.pos < lx.s.len and lx.s[lx.pos] != '>':
    let c = lx.s[lx.pos]
    inc lx.pos
    if isWs(c):
      continue
    if c notin HexDigits:
      pdfFail("bad hex digit in PDF string")
    let v = hexNibble(c)
    if hi < 0:
      hi = v
    else:
      result.add(chr(hi * 16 + v))
      hi = -1
  if lx.pos >= lx.s.len:
    pdfFail("unterminated PDF hex string")
  inc lx.pos # '>'
  if hi >= 0:
    result.add(chr(hi * 16))

proc parseCosValue*(lx: var Lexer): CosObj

proc parseDict(lx: var Lexer): tuple[keys: seq[string], vals: seq[CosObj]] =
  ## Leading '<<' already consumed.
  result = (@[], @[])
  while true:
    lx.skipWsAndComments()
    if lx.pos + 1 < lx.s.len and lx.s[lx.pos] == '>' and
        lx.s[lx.pos + 1] == '>':
      lx.pos += 2
      return
    if lx.pos >= lx.s.len:
      pdfFail("unterminated PDF dictionary")
    if lx.s[lx.pos] != '/':
      pdfFail("expected name key in PDF dictionary at offset " & $lx.pos)
    inc lx.pos
    result.keys.add(lx.parseName())
    result.vals.add(lx.parseCosValue())

proc parseArray(lx: var Lexer): CosObj =
  ## Leading '[' already consumed.
  result = CosObj(kind: coArray, items: @[])
  while true:
    lx.skipWsAndComments()
    if lx.pos >= lx.s.len:
      pdfFail("unterminated PDF array")
    if lx.s[lx.pos] == ']':
      inc lx.pos
      return
    result.items.add(lx.parseCosValue())

proc parseNumberOrRef(lx: var Lexer): CosObj =
  let start = lx.pos
  if lx.pos < lx.s.len and lx.s[lx.pos] in {'+', '-'}:
    inc lx.pos
  var hasDot = false
  var digits = 0
  while lx.pos < lx.s.len and (lx.s[lx.pos] in {'0'..'9'} or
      (lx.s[lx.pos] == '.' and not hasDot)):
    if lx.s[lx.pos] == '.':
      hasDot = true
    else:
      inc digits
    inc lx.pos
  let tok = lx.s.slice(start, lx.pos)
  if digits == 0:
    pdfFail("bad PDF number at offset " & $start)
  if not hasDot:
    # possible indirect reference: int int R
    let save = lx.pos
    lx.skipWsAndComments()
    var gen = ""
    while lx.pos < lx.s.len and lx.s[lx.pos] in {'0'..'9'}:
      gen.add(lx.s[lx.pos])
      inc lx.pos
    if gen.len > 0:
      lx.skipWsAndComments()
      if lx.pos < lx.s.len and lx.s[lx.pos] == 'R' and
          (lx.pos + 1 >= lx.s.len or isDelim(lx.s[lx.pos + 1])):
        inc lx.pos
        try:
          return CosObj(kind: coRef, refNum: parseInt(tok),
            refGen: parseInt(gen))
        except ValueError:
          pdfFail("bad indirect reference at offset " & $start)
    lx.pos = save
    try:
      return CosObj(kind: coInt, ival: parseInt(tok))
    except ValueError:
      pdfFail("bad PDF integer at offset " & $start)
  try:
    CosObj(kind: coFloat, fval: parseFloat(tok))
  except ValueError:
    pdfFail("bad PDF number at offset " & $start)

proc parseCosValue*(lx: var Lexer): CosObj =
  ## Parse one COS value at the cursor.
  lx.skipWsAndComments()
  if lx.pos >= lx.s.len:
    pdfFail("unexpected end in PDF object")
  case lx.s[lx.pos]
  of '<':
    if lx.pos + 1 < lx.s.len and lx.s[lx.pos + 1] == '<':
      lx.pos += 2
      let (keys, vals) = lx.parseDict()
      CosObj(kind: coDict, keys: keys, vals: vals)
    else:
      inc lx.pos
      CosObj(kind: coStr, sval: lx.parseHexStr())
  of '[':
    inc lx.pos
    lx.parseArray()
  of '(':
    inc lx.pos
    CosObj(kind: coStr, sval: lx.parseLiteral())
  of '/':
    inc lx.pos
    CosObj(kind: coName, name: lx.parseName())
  of '+', '-', '.', '0'..'9':
    lx.parseNumberOrRef()
  else:
    for kw in ["true", "false", "null"]:
      if lx.continuesWith(kw):
        let after = lx.pos + kw.len
        if after >= lx.s.len or isDelim(lx.s[after]):
          lx.pos = after
          if kw == "true":
            return CosObj(kind: coBool, bval: true)
          elif kw == "false":
            return CosObj(kind: coBool, bval: false)
          return CosObj(kind: coNull)
    pdfFail("unsupported PDF token at offset " & $lx.pos)

proc parseStreamBody*(data: PdfSource, pos: int, length: int): string =
  ## Slice `length` raw bytes after `stream` + EOL. The caller resolves
  ## /Length (direct integer here; indirect goes through docmodel).
  var p = pos
  if p < data.len and data[p] == '\x0D':
    inc p
    if p < data.len and data[p] == '\x0A':
      inc p
  elif p < data.len and data[p] == '\x0A':
    inc p
  else:
    pdfFail("expected EOL after 'stream' keyword at offset " & $pos)
  if length < 0 or p + length > data.len:
    pdfFail("stream length " & $length & " out of range at offset " & $p)
  result = data.slice(p, p + length)
  var q = p + length
  # optional EOL before endstream is not part of the data
  if q < data.len and data[q] == '\x0D':
    inc q
    if q < data.len and data[q] == '\x0A':
      inc q
  elif q < data.len and data[q] == '\x0A':
    inc q
  if not data.continuesWithAt("endstream", q):
    pdfFail("expected 'endstream' at offset " & $q)

proc parseIndirect*(data: PdfSource, offset: int):
    tuple[num, gen: int, obj: CosObj] =
  ## Parse one `N G obj ... endobj` at `offset`. Stream dictionaries
  ## with a direct integer /Length become coStream; an indirect
  ## /Length raises PdfError naming the docmodel path.
  var lx = initLexer(data, offset)
  let num = lx.readTableInt("object number")
  let gen = lx.readTableInt("object generation")
  lx.expectKeyword("obj", "indirect object " & $num)
  let val = lx.parseCosValue()
  if val.kind == coDict:
    let save = lx.pos
    lx.skipWsAndComments()
    if lx.continuesWith("stream"):
      # 'stream' must be followed by EOL per spec
      let after = lx.pos + 6
      if after < data.len and data[after] notin {'\x0A', '\x0D'}:
        pdfFail("expected EOL after 'stream' in object " & $num)
      lx.pos = after
      var length = -1
      for i, k in val.keys:
        if k == "Length":
          if val.vals[i].kind != coInt:
            pdfFail("indirect stream /Length in object " & $num &
              " needs document context (resolve via PdfDoc)")
          length = val.vals[i].ival
      if length < 0:
        pdfFail("stream object " & $num & " missing /Length")
      let raw = parseStreamBody(data, lx.pos, length)
      return (num, gen, CosObj(kind: coStream, streamDict: val.keys,
        streamVals: val.vals, raw: raw))
    lx.pos = save
  lx.skipWsAndComments()
  if lx.continuesWith("endstream"):
    pdfFail("stray 'endstream' in object " & $num)
  lx.expectKeyword("endobj", "indirect object " & $num)
  (num, gen, val)
