## DER codec (M19 P1/P4): definite-length writer + structural reader.
##
## The writer emits definite-length DER only, with minimal integer and
## length forms. The reader accepts definite lengths (short or long,
## minimal or not — length-form leniency has no security impact) and
## rejects indefinite lengths, trailing garbage, truncation, and
## overlong content. Content interpretation (minimal-integer checks on
## signatures, OID matching) lives in `cert.nim` and `sign.nim`, not
## here: this module only splits TLVs.
##
## `DateTime` conversions use UTC always. BIT STRING carries an unused
## bit count (0 for keys and signatures). Context tags cover the CMS
## [0]/[1] EXPLICIT/IMPLICIT slots the builder and parser need.

import std/algorithm
import std/times
import ./types
import ./lexer

type
  DerTag* = enum
    dtBoolean, dtInteger, dtBitString, dtOctetString, dtNull, dtOid,
    dtUtf8String, dtSequence, dtSet, dtPrintableString, dtIa5String,
    dtUtcTime, dtGeneralizedTime

  DerNode* = object
    tag*: byte
    constructed*: bool
    content*: string ## value bytes (children concatenated for constructed)
    total*: int ## TLV span length (header + content)

proc tagByte(t: DerTag): byte =
  case t
  of dtBoolean: 0x01
  of dtInteger: 0x02
  of dtBitString: 0x03
  of dtOctetString: 0x04
  of dtNull: 0x05
  of dtOid: 0x06
  of dtUtf8String: 0x0C
  of dtSequence: 0x30
  of dtSet: 0x31
  of dtPrintableString: 0x13
  of dtIa5String: 0x16
  of dtUtcTime: 0x17
  of dtGeneralizedTime: 0x18

proc derLen*(n: int): string =
  ## Definite-length form, minimal. Fails on negative or absurd sizes.
  if n < 0:
    pdfFail("DER length must not be negative")
  if n > 0xFFFFFF:
    pdfFail("DER length " & $n & " exceeds 16 MiB cap")
  if n < 128:
    return $char(n)
  var tmp = n
  var be: seq[byte] = @[]
  while tmp > 0:
    be.add(byte(tmp and 0xFF))
    tmp = tmp shr 8
  result = $char(0x80 or be.len)
  for i in countdown(be.len - 1, 0):
    result.add(char(be[i]))

proc derTlv*(tag: DerTag, content: string): string =
  $char(tagByte(tag)) & derLen(content.len) & content

proc derIntBytes*(raw: string): string =
  ## Minimal signed encoding of big-endian bytes with a sign bit.
  ## Callers pass magnitude bytes plus a leading zero when the high bit
  ## is set (non-negative), or pre-formed two's complement.
  var i = 0
  while i + 1 < raw.len and raw[i] == '\0' and
      (byte(raw[i + 1]) and 0x80) == 0:
    inc i
  if i >= raw.len:
    return derTlv(dtInteger, "\0")
  derTlv(dtInteger, raw[i .. ^1])

proc derInt*(v: int64): string =
  ## Minimal two's complement for a machine int.
  if v == 0:
    return derTlv(dtInteger, "\0")
  var neg = v < 0
  var mag: uint64
  if neg:
    mag = uint64(-(v + 1)) + 1u64 # avoid overflow on low(int64)
  else:
    mag = uint64(v)
  var be: seq[byte] = @[]
  while mag > 0:
    be.add(byte(mag and 0xFF))
    mag = mag shr 8
  if not neg and (be[^1] and 0x80) != 0:
    be.add(0)
  if neg:
    # Sign-extend the magnitude first: two's complement needs a width
    # whose top bit reads positive before inversion.
    if (be[^1] and 0x80) != 0:
      be.add(0)
    var carry = 1u64
    var i = 0
    while i < be.len:
      let inv = (not uint64(be[i])) and 0xFF
      let s = inv + carry
      be[i] = byte(s and 0xFF)
      carry = s shr 8
      inc i
    if carry != 0:
      be.add(0xFF)
    while be.len > 1 and be[^1] == 0xFF and
        (be[^2] and 0x80) != 0:
      discard be.pop()
  result = $char(tagByte(dtInteger)) & derLen(be.len)
  for i in countdown(be.len - 1, 0):
    result.add(char(be[i]))

proc packBase128(v: int, body: var string) =
  ## One base-128 OID arc, continuation bits set on all but the last.
  var parts: seq[byte] = @[byte(v mod 128)]
  var rest = v div 128
  while rest > 0:
    parts.add(byte((rest mod 128) or 0x80))
    rest = rest div 128
  for i in countdown(parts.len - 1, 0):
    if i == 0:
      body.add(char(parts[i] and 0x7F))
    else:
      body.add(char(parts[i]))

proc derOid*(arcs: openArray[int]): string =
  ## OBJECT IDENTIFIER with base-128 packing. Fails on short or
  ## negative arcs; first arc must be 0..2, second 0..39 when first < 2.
  if arcs.len < 2:
    pdfFail("OID needs at least 2 arcs")
  if arcs[0] < 0 or arcs[0] > 2 or arcs[1] < 0:
    pdfFail("OID has out-of-range leading arcs")
  if arcs[0] < 2 and arcs[1] > 39:
    pdfFail("OID second arc exceeds 39")
  var body = ""
  packBase128(arcs[0] * 40 + arcs[1], body)
  for a in arcs[2 .. ^1]:
    if a < 0:
      pdfFail("OID arc must not be negative")
    packBase128(a, body)
  derTlv(dtOid, body)

proc derBitString*(bytes: string, unusedBits = 0): string =
  if unusedBits < 0 or unusedBits > 7:
    pdfFail("BIT STRING unused bits must be 0..7")
  if bytes.len == 0 and unusedBits != 0:
    pdfFail("empty BIT STRING cannot have unused bits")
  derTlv(dtBitString, char(unusedBits) & bytes)

proc derOctetString*(s: string): string =
  derTlv(dtOctetString, s)

proc derNull*(): string =
  derTlv(dtNull, "")

proc derBool*(v: bool): string =
  derTlv(dtBoolean, if v: "\xFF" else: "\0")

proc derUtf8*(s: string): string =
  derTlv(dtUtf8String, s)

proc derPrintable*(s: string): string =
  for c in s:
    if c notin {'A'..'Z', 'a'..'z', '0'..'9', ' ', '\'', '(', ')',
        '+', ',', '-', '.', '/', ':', '=', '?'}:
      pdfFail("PrintableString holds '" & $c & "'")
  derTlv(dtPrintableString, s)

proc derIa5*(s: string): string =
  for c in s:
    if ord(c) > 127:
      pdfFail("IA5String holds non-ASCII")
  derTlv(dtIa5String, s)

proc derSeq*(parts: varargs[string]): string =
  var body = ""
  for p in parts:
    body.add(p)
  derTlv(dtSequence, body)

proc derSet*(parts: varargs[string]): string =
  ## SET OF with bytewise-sorted members (DER §8.11.3).
  var ps: seq[string] = @[]
  for p in parts:
    ps.add(p)
  ps.sort()
  var body = ""
  for p in ps:
    body.add(p)
  derTlv(dtSet, body)

proc derContext*(n: int, constructed: bool, content: string): string =
  ## [n] context tag (CMS [0]/[1] slots). Fails outside 0..30.
  if n < 0 or n > 30:
    pdfFail("context tag must be 0..30")
  let b = byte(0x80 or (if constructed: 0x20 else: 0) or n)
  $char(b) & derLen(content.len) & content

proc derExplicit*(n: int, content: string): string =
  derContext(n, true, content)

proc derUtcTime*(t: DateTime): string =
  derTlv(dtUtcTime, t.format("yyMMddHHmmss") & "Z")

proc derGeneralizedTime*(t: DateTime): string =
  derTlv(dtGeneralizedTime, t.format("yyyyMMddHHmmss") & "Z")

# ---------------------------------------------------------------------------
# Structural reader
# ---------------------------------------------------------------------------

proc derRead*(data: string, pos: var int): DerNode =
  ## One TLV at `pos`; advances past it. Rejects indefinite lengths,
  ## truncation, and absurd sizes. Tag class and number come through
  ## `tag` raw; `constructed` mirrors bit 6; `total` is the TLV span.
  let start = pos
  if pos >= data.len:
    pdfFail("DER ends where a tag was expected")
  let tag = byte(data[pos])
  inc pos
  if pos >= data.len:
    pdfFail("DER ends inside a length")
  let lb = byte(data[pos])
  inc pos
  var length = 0
  if (lb and 0x80) == 0:
    length = int(lb)
  else:
    let n = int(lb and 0x7F)
    if n == 0:
      pdfFail("DER indefinite length is not accepted")
    if n > 4:
      pdfFail("DER length prefix exceeds 4 bytes")
    for _ in 0 ..< n:
      if pos >= data.len:
        pdfFail("DER ends inside a long length")
      length = length * 256 + int(byte(data[pos]))
      inc pos
    if length > 0xFFFFFF:
      pdfFail("DER length exceeds 16 MiB cap")
  if pos + length > data.len:
    pdfFail("DER length runs past the input")
  let content =
    if length == 0: ""
    else: data[pos ..< pos + length]
  pos += length
  DerNode(tag: tag, constructed: (tag and 0x20) != 0,
    content: content, total: pos - start)

proc derChildren*(n: DerNode): seq[DerNode] =
  ## Value bytes as a TLV sequence; trailing garbage fails.
  var pos = 0
  while pos < n.content.len:
    result.add(derRead(n.content, pos))
  if pos != n.content.len:
    pdfFail("DER children overran their parent")

proc derParse*(data: string): DerNode =
  ## Single top-level TLV; trailing bytes fail.
  var pos = 0
  result = derRead(data, pos)
  if pos != data.len:
    pdfFail("DER has trailing bytes after the top-level TLV")

proc derOidContent*(arcs: openArray[int]): string =
  ## OID value bytes (without tag/length) for byte comparisons.
  derOid(arcs)[2 .. ^1]
