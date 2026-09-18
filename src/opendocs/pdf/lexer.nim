## Byte-level lexer cursor shared by the COS and xref parsers.
##
## Operates on a PdfSource, which is either a zero-copy view of a
## string or a memory-mapped file. All scanning is bounded by the
## input length; structural caps live in PdfLimits.

import std/strutils
import ./types
import ./source

export source

type
  Lexer* = object
    s*: PdfSource
    pos*: int

proc initLexer*(s: string, pos = 0): Lexer =
  Lexer(s: fromString(s), pos: pos)

proc initLexer*(src: PdfSource, pos = 0): Lexer =
  Lexer(s: src, pos: pos)

proc pdfFail*(msg: string) {.noreturn.} =
  raise newException(PdfError, msg)

proc isWs*(c: char): bool {.inline.} =
  c in {'\x00', '\x09', '\x0A', '\x0C', '\x0D', '\x20'}

proc isDelim*(c: char): bool {.inline.} =
  c in {'(', ')', '<', '>', '[', ']', '{', '}', '/', '%'} or isWs(c)

proc skipWsAndComments*(lx: var Lexer) =
  while lx.pos < lx.s.len:
    if isWs(lx.s[lx.pos]):
      inc lx.pos
    elif lx.s[lx.pos] == '%':
      while lx.pos < lx.s.len and lx.s[lx.pos] notin {'\x0A', '\x0D'}:
        inc lx.pos
    else:
      break

proc peek*(lx: Lexer): char {.inline.} =
  if lx.pos < lx.s.len: lx.s[lx.pos] else: '\x00'

proc atEnd*(lx: Lexer): bool {.inline.} =
  lx.pos >= lx.s.len

proc continuesWith*(lx: Lexer, kw: string): bool =
  lx.s.continuesWithAt(kw, lx.pos)

proc expectKeyword*(lx: var Lexer, kw: string, what: string) =
  ## Consume kw; the next byte must be a delimiter or end of input.
  lx.skipWsAndComments()
  if not lx.continuesWith(kw):
    pdfFail("expected '" & kw & "' for " & what & " at offset " & $lx.pos)
  let after = lx.pos + kw.len
  if after < lx.s.len and not isDelim(lx.s[after]):
    pdfFail("expected '" & kw & "' for " & what & " at offset " & $lx.pos)
  lx.pos = after

proc readTableInt*(lx: var Lexer, what: string): int =
  ## Unsigned decimal integer (xref offsets, object numbers).
  lx.skipWsAndComments()
  let start = lx.pos
  while lx.pos < lx.s.len and lx.s[lx.pos] in {'0'..'9'}:
    inc lx.pos
  if start == lx.pos:
    pdfFail("expected integer for " & what & " at offset " & $start)
  try:
    parseInt(lx.s.slice(start, lx.pos))
  except ValueError:
    pdfFail("bad integer for " & what & " at offset " & $start)

proc hexNibble*(c: char): int =
  case c
  of '0'..'9': ord(c) - ord('0')
  of 'a'..'f': ord(c) - ord('a') + 10
  of 'A'..'F': ord(c) - ord('A') + 10
  else: pdfFail("bad hex digit in PDF string")

proc parsePdfVersion*(head: string): string =
  ## Version token after %PDF-, e.g. "1.7". Empty when absent.
  let p = find(head, "%PDF-")
  if p < 0:
    return ""
  var v = ""
  var i = p + 5
  while i < head.len and head[i] notin {'\x00', '\x09', '\x0A', '\x0C',
      '\x0D', '\x20'}:
    v.add(head[i])
    inc i
  if v.len > 0 and v[0] in {'0'..'9'}: v else: ""
