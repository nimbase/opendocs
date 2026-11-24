## Copyright (c) 2026 nimbase (MIT, see LICENSE at repo root).
##
## Plain-text reader and writer: encoding detection, BOM handling,
## line-ending detection/conversion, memory-mapped I/O and small
## text utilities.
##
## There is no behavioral oracle here (no reference implementation was
## consulted); byte layouts follow the Unicode standard facts: BOM
## signatures, UTF-8/16/32 codec rules, the Windows-1252 code page.
##
## Heuristics (documented because detection is inherently heuristic;
## everything else fails loudly):
## - BOM wins outright (`EF BB BF` UTF-8, `FF FE 00 00` UTF-32LE,
##   `FF FE` UTF-16LE, `FE FF` UTF-16BE, `00 00 FE FF` UTF-32BE).
## - Without a BOM, NUL-stride majority selects UTF-16: when at
##   least two in five odd byte positions are NUL the input is UTF-16LE
##   (even positions: UTF-16BE). ASCII UTF-16 always trips this, and
##   so does astral-plane text (surrogate halves scatter the odd NUL
##   or two). NUL-separated single-byte text is byte-identical to
##   ASCII UTF-16 and reads as UTF-16; odd-length hits fail loudly as
##   truncated. Fully-NUL input ties and stays UTF-8.
## - Otherwise strict UTF-8 validation decides: valid input is UTF-8.
## - The remainder is single-byte text. Bytes in `0x80-0x9F` select
##   Windows-1252 (they are printable there, C1 controls in Latin-1),
##   unless one of the five bytes undefined in 1252
##   (`81 8D 8F 90 9D`) is present, which selects Latin-1 wholesale.
##   Pure `0xA0-0xFF` input is identical in both and reports Latin-1.
## - BOM-less UTF-16 with no NUL bytes (e.g. pure CJK) is
##   indistinguishable from single-byte text and reads as Latin-1.
##   Producers that care must write a BOM. This is inherent, not a bug.
##
## Fail-loudly cases (`TxtError`): truncated UTF-16/32 (odd tail),
## lone surrogates, surrogate halves and >U+10FFFF in UTF-32, invalid
## UTF-8 after a BOM, invalid UTF-8 passed to an encoder, and
## unrepresentable codepoints on single-byte encode. Bare invalid
## UTF-8 without a BOM is single-byte text (the locked fallback),
## never an error.
##
## Zero-copy design (`std/memfiles` + `buffalo`):
## - Mapped reads scan BOM/validation windows on `memView` (no
##   `readBytes` copy); one decode pass produces the owned string.
## - Encodes stage in a reused `PooledBuffer[byte]`; mapped writes use
##   a size-known mapping with a single `copyToMemFile`.
## - `eachLine` streams over the mapping with O(longest line) memory;
##   per-line strings are the explicit copy-out (unavoidable: yielded
##   values must be owned).

import std/[strutils, os, unicode, memfiles]
import buffalo

type
  TxtError* = object of CatchableError

  TxtEncoding* = enum
    ## Source/selected byte codec. `encUtf8` has no BOM; `encUtf8Bom`
    ## is UTF-8 with one.
    encUtf8
    encUtf8Bom
    encUtf16LE
    encUtf16BE
    encUtf32LE
    encUtf32BE
    encLatin1
    encWindows1252

  TxtLineEnding* = enum
    ## Detected line-break mix. `leNone` means no breaks at all.
    leNone
    leLF
    leCRLF
    leCR
    leMixed

  TxtDoc* = object
    ## Decoded text (UTF-8, LF-normalized) plus the metadata needed to
    ## reproduce the source faithfully on write.
    text*: string
    encoding*: TxtEncoding
    lineEnding*: TxtLineEnding
    hasBom*: bool

  TxtWriteOpts* = object
    ## Explicit write settings. `writeTextFile(path, doc)` instead uses
    ## the doc's own encoding/BOM/line-ending (mixed/none write as LF).
    encoding*: TxtEncoding = encUtf8
    bom*: bool = false
    lineEnding*: TxtLineEnding = leLF

const
  # The five bytes undefined in Windows-1252. Their presence selects
  # Latin-1 wholesale (see header).
  Win1252Holes = [0x81'u8, 0x8D, 0x8F, 0x90, 0x9D]

  # 0x80-0x9F to codepoint (0 = undefined hole).
  Win1252Map: array[32, uint32] = [
    0x20AC'u32, 0, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
    0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0, 0x017D, 0,
    0, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
    0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0, 0x017E, 0x0178]

proc txtFail(msg: string) {.noreturn.} =
  raise newException(TxtError, msg)

# ------------------------------------------------------------ primitives

proc appendRuneUtf8(dst: var PooledBuffer[byte], cp: uint32) =
  ## Encode one scalar value as UTF-8. Caller guarantees `cp` is a
  ## scalar value (no surrogates, <= U+10FFFF).
  if cp < 0x80:
    dst.add(byte(cp))
  elif cp < 0x800:
    dst.add(byte(0xC0 or (cp shr 6)))
    dst.add(byte(0x80 or (cp and 0x3F)))
  elif cp < 0x10000:
    dst.add(byte(0xE0 or (cp shr 12)))
    dst.add(byte(0x80 or ((cp shr 6) and 0x3F)))
    dst.add(byte(0x80 or (cp and 0x3F)))
  else:
    dst.add(byte(0xF0 or (cp shr 18)))
    dst.add(byte(0x80 or ((cp shr 12) and 0x3F)))
    dst.add(byte(0x80 or ((cp shr 6) and 0x3F)))
    dst.add(byte(0x80 or (cp and 0x3F)))

func isValidUtf8*(data: openArray[byte]): bool =
  ## Strict validation: rejects overlongs, surrogate halves,
  ## >U+10FFFF and truncated sequences.
  var i = 0
  while i < data.len:
    let b0 = data[i]
    if b0 < 0x80'u8:
      inc i
    elif b0 >= 0xC2'u8 and b0 <= 0xDF'u8:
      if i + 1 >= data.len or data[i + 1] < 0x80'u8 or
          data[i + 1] > 0xBF'u8:
        return false
      i += 2
    elif b0 >= 0xE0'u8 and b0 <= 0xEF'u8:
      if i + 2 >= data.len: return false
      let (lo, hi) =
        if b0 == 0xE0'u8: (0xA0'u8, 0xBF'u8)
        elif b0 == 0xED'u8: (0x80'u8, 0x9F'u8)
        else: (0x80'u8, 0xBF'u8)
      if data[i + 1] < lo or data[i + 1] > hi or
          data[i + 2] < 0x80'u8 or data[i + 2] > 0xBF'u8:
        return false
      i += 3
    elif b0 >= 0xF0'u8 and b0 <= 0xF4'u8:
      if i + 3 >= data.len: return false
      let (lo, hi) =
        if b0 == 0xF0'u8: (0x90'u8, 0xBF'u8)
        elif b0 == 0xF4'u8: (0x80'u8, 0x8F'u8)
        else: (0x80'u8, 0xBF'u8)
      if data[i + 1] < lo or data[i + 1] > hi or
          data[i + 2] < 0x80'u8 or data[i + 2] > 0xBF'u8 or
          data[i + 3] < 0x80'u8 or data[i + 3] > 0xBF'u8:
        return false
      i += 4
    else:
      return false
  true

func validUtf8Str(s: string): bool =
  ## Empty-safe strict validation for string inputs.
  s.len == 0 or isValidUtf8(s.toOpenArrayByte(0, s.high))

proc detectBom*(data: openArray[byte]): tuple[enc: TxtEncoding,
    size: int] =
  ## BOM match. Returns `(encUtf8, 0)` when no BOM is present (the
  ## encoding slot is meaningless there; only `size` matters).
  if data.len >= 4 and data[0] == 0x00'u8 and data[1] == 0x00'u8 and
      data[2] == 0xFE'u8 and data[3] == 0xFF'u8:
    return (encUtf32BE, 4)
  if data.len >= 4 and data[0] == 0xFF'u8 and data[1] == 0xFE'u8 and
      data[2] == 0x00'u8 and data[3] == 0x00'u8:
    return (encUtf32LE, 4)
  if data.len >= 3 and data[0] == 0xEF'u8 and data[1] == 0xBB'u8 and
      data[2] == 0xBF'u8:
    return (encUtf8Bom, 3)
  if data.len >= 2 and data[0] == 0xFE'u8 and data[1] == 0xFF'u8:
    return (encUtf16BE, 2)
  if data.len >= 2 and data[0] == 0xFF'u8 and data[1] == 0xFE'u8:
    return (encUtf16LE, 2)
  (encUtf8, 0)

func utf16Heuristic*(data: openArray[byte]): tuple[hit: bool,
    bigEndian: bool] =
  ## NUL-stride test for BOM-less UTF-16 (see header). Odd tails still
  ## report a hit; the decoder fails loudly on them.
  if data.len < 2: return (false, false)
  let oddSlots = data.len div 2
  let evenSlots = data.len - oddSlots
  var evenNul = 0
  var oddNul = 0
  for i, b in data:
    if b == 0'u8:
      if i mod 2 == 0: inc evenNul
      else: inc oddNul
  let leHit = oddNul * 5 >= oddSlots * 2
  let beHit = evenNul * 5 >= evenSlots * 2
  if leHit == beHit: return (false, false) # neither or tied (all-NUL)
  (true, beHit)

# ---------------------------------------------------------------- decoders

proc decodeUtf16Units(data: openArray[byte], first: int,
    bigEndian: bool, what: string): string =
  ## Decode units from `first`; fails loudly on odd tails and lone
  ## surrogates.
  if (data.len - first) mod 2 != 0:
    txtFail("truncated UTF-16 input (" & what & ")")
  var pool = initPool(byte, max(data.len - first, 8))
  var i = first
  while i < data.len:
    let u: uint16 =
      if bigEndian: (uint16(data[i]) shl 8) or uint16(data[i + 1])
      else: uint16(data[i]) or (uint16(data[i + 1]) shl 8)
    if u >= 0xD800'u16 and u <= 0xDBFF'u16:
      if i + 3 >= data.len:
        txtFail("lone high surrogate at end of input (" & what & ")")
      let v: uint16 =
        if bigEndian: (uint16(data[i + 2]) shl 8) or uint16(data[i + 3])
        else: uint16(data[i + 2]) or (uint16(data[i + 3]) shl 8)
      if v < 0xDC00'u16 or v > 0xDFFF'u16:
        txtFail("lone high surrogate in input (" & what & ")")
      let cp = 0x10000'u32 + ((uint32(u) - 0xD800) shl 10) +
        (uint32(v) - 0xDC00)
      pool.appendRuneUtf8(cp)
      i += 4
    elif u >= 0xDC00'u16 and u <= 0xDFFF'u16:
      txtFail("lone low surrogate in input (" & what & ")")
    else:
      pool.appendRuneUtf8(uint32(u))
      i += 2
  pool.toString()

proc decodeUtf32Units(data: openArray[byte], first: int,
    bigEndian: bool, what: string): string =
  ## Decode units from `first`; fails loudly on odd tails, surrogate
  ## halves and >U+10FFFF.
  if (data.len - first) mod 4 != 0:
    txtFail("truncated UTF-32 input (" & what & ")")
  var pool = initPool(byte, max((data.len - first) div 2, 8))
  var i = first
  while i < data.len:
    let cp =
      if bigEndian:
        (uint32(data[i]) shl 24) or (uint32(data[i + 1]) shl 16) or
        (uint32(data[i + 2]) shl 8) or uint32(data[i + 3])
      else:
        uint32(data[i]) or (uint32(data[i + 1]) shl 8) or
        (uint32(data[i + 2]) shl 16) or (uint32(data[i + 3]) shl 24)
    if (cp >= 0xD800 and cp <= 0xDFFF) or cp > 0x10FFFF:
      txtFail("bad scalar value in input (" & what & ")")
    pool.appendRuneUtf8(cp)
    i += 4
  pool.toString()

proc decodeSingleByte(data: openArray[byte], win1252: bool): string =
  ## Latin-1, or Windows-1252 over the `0x80-0x9F` window.
  var pool = initPool(byte, max(data.len + data.len div 2, 8))
  for b in data:
    if b < 0x80'u8 or b >= 0xA0'u8:
      pool.appendRuneUtf8(uint32(b))
    elif win1252:
      pool.appendRuneUtf8(Win1252Map[b - 0x80])
    else:
      pool.appendRuneUtf8(uint32(b))
  pool.toString()

proc detectLineEnding*(text: string): TxtLineEnding =
  ## Break census over decoded text. No breaks is `leNone`; a single
  ## kind is that kind; anything else is `leMixed`.
  var crlf = 0
  var lf = 0
  var cr = 0
  var i = 0
  while i < text.len:
    if text[i] == '\n':
      if i > 0 and text[i - 1] == '\r': inc crlf
      else: inc lf
      inc i
    elif text[i] == '\r':
      if i + 1 >= text.len or text[i + 1] != '\n': inc cr
      inc i
    else:
      inc i
  let kinds = (if crlf > 0: 1 else: 0) + (if lf > 0: 1 else: 0) +
    (if cr > 0: 1 else: 0)
  if kinds == 0: leNone
  elif kinds > 1: leMixed
  elif crlf > 0: leCRLF
  elif lf > 0: leLF
  else: leCR

proc normalizeEndings*(text: string): string =
  ## `CRLF` and lone `CR` become `LF`. Already-LF text passes through
  ## with a single copy (no-op fast path by scan, not by hope).
  if '\r' notin text: return text
  result = newStringOfCap(text.len)
  var i = 0
  while i < text.len:
    if text[i] == '\r':
      result.add '\n'
      if i + 1 < text.len and text[i + 1] == '\n': i += 2
      else: inc i
    else:
      result.add text[i]
      inc i

proc decodeBytes*(data: openArray[byte]): TxtDoc =
  ## Detect and decode. See the header for the heuristic order; every
  ## malformed input raises `TxtError`.
  if data.len == 0:
    return TxtDoc(text: "", encoding: encUtf8, lineEnding: leNone,
      hasBom: false)
  let (bomEnc, bomSize) = detectBom(data)
  var body: string
  var enc: TxtEncoding
  var bom = false
  if bomSize > 0:
    bom = true
    enc = bomEnc
    case bomEnc
    of encUtf8Bom:
      body = newString(data.len - bomSize)
      if body.len > 0:
        copyMem(addr body[0], unsafeAddr data[bomSize], body.len)
      if not validUtf8Str(body): txtFail("invalid UTF-8 after BOM")
    of encUtf16LE:
      body = decodeUtf16Units(data, bomSize, false, "UTF-16LE")
    of encUtf16BE:
      body = decodeUtf16Units(data, bomSize, true, "UTF-16BE")
    of encUtf32LE:
      body = decodeUtf32Units(data, bomSize, false, "UTF-32LE")
    of encUtf32BE:
      body = decodeUtf32Units(data, bomSize, true, "UTF-32BE")
    else: txtFail("unreachable BOM kind")
  else:
    let (hit, be) = utf16Heuristic(data)
    if hit:
      enc = if be: encUtf16BE else: encUtf16LE
      body = decodeUtf16Units(data, 0, be,
        if be: "UTF-16BE" else: "UTF-16LE")
    else:
      body = newString(data.len)
      if body.len > 0:
        copyMem(addr body[0], unsafeAddr data[0], body.len)
      if not validUtf8Str(body):
        # Single-byte text (see header for the 1252/Latin-1 rule).
        var use1252 = false
        var hole = false
        for b in data:
          if b in Win1252Holes:
            hole = true
            break
          if b >= 0x80'u8 and b < 0xA0'u8: use1252 = true
        if hole: use1252 = false
        enc = if use1252: encWindows1252 else: encLatin1
        body = decodeSingleByte(data, use1252)
      else:
        enc = encUtf8
  let ending = detectLineEnding(body)
  TxtDoc(text: normalizeEndings(body), encoding: enc, lineEnding: ending,
    hasBom: bom)

proc decodeText*(s: string): TxtDoc =
  ## Decode a string's bytes (handy for literals and tests).
  if s.len == 0:
    return TxtDoc(text: "", encoding: encUtf8, lineEnding: leNone,
      hasBom: false)
  decodeBytes(s.toOpenArrayByte(0, s.high))

# ---------------------------------------------------------------- readers

proc readTextFile*(path: string): TxtDoc =
  ## Buffered read + decode. `TxtError` on missing/short files.
  var f: File
  if not open(f, path, fmRead):
    raise newException(TxtError, "cannot open file: " & path)
  defer: close(f)
  let size = getFileSize(f).int
  var data = newSeq[byte](size)
  if size > 0 and readBytes(f, data, 0, size) != size:
    raise newException(TxtError, "short read: " & path)
  decodeBytes(data)

proc readTextMapped*(path: string): TxtDoc =
  ## Memory-mapped read + decode. Detection windows scan the mapping
  ## (`memView`, zero-copy); one pass produces the owned text.
  var mf: MemFile
  try:
    mf = memfiles.open(path, fmRead)
  except OSError as e:
    raise newException(TxtError, "cannot map file: " & path & ": " &
      e.msg)
  try:
    if mf.size == 0:
      return TxtDoc(text: "", encoding: encUtf8, lineEnding: leNone,
        hasBom: false)
    decodeBytes(memView(mf))
  finally:
    memfiles.close(mf)

iterator eachLine*(path: string): string =
  ## Stream lines without materializing the file. Breaks are LF, CRLF
  ## and lone CR (all normalized away; terminators never yielded), with
  ## `splitlines` semantics (no phantom trailing empty). O(longest
  ## line) memory. Consume fully: the mapping closes at exhaustion.
  var mf: MemFile
  try:
    mf = memfiles.open(path, fmRead)
  except OSError as e:
    raise newException(TxtError, "cannot map file: " & path & ": " &
      e.msg)
  try:
    if mf.size > 0:
      let p = cast[ptr UncheckedArray[byte]](mf.mem)
      let n = mf.size
      var seg = newStringOfCap(256)
      var i = 0
      while i < n:
        if p[i] == byte('\n'):
          yield seg
          seg.setLen(0)
        elif p[i] == byte('\r'):
          yield seg
          seg.setLen(0)
          if i + 1 < n and p[i + 1] == byte('\n'): inc i
        else:
          seg.add(char(p[i]))
        inc i
      if seg.len > 0:
        yield seg
  finally:
    memfiles.close(mf)

proc readTextLines*(path: string): seq[string] =
  ## All lines via the streaming reader (`splitlines` semantics).
  for line in eachLine(path): result.add line

# ---------------------------------------------------------------- writers

proc encodeBody(text: string, enc: TxtEncoding): PooledBuffer[byte] =
  ## UTF-8 `text` (must already be valid; callers validate) to the
  ## target codec, without BOM. Unrepresentable codepoints fail loudly.
  result = initPool(byte, max(text.len + 8, 16))
  case enc
  of encUtf8, encUtf8Bom:
    result.appendMany(text)
  of encUtf16LE, encUtf16BE:
    let be = enc == encUtf16BE
    for r in text.runes:
      let cp = uint32(r)
      if cp < 0x10000:
        if be:
          result.add(byte(cp shr 8))
          result.add(byte(cp and 0xFF))
        else:
          result.add(byte(cp and 0xFF))
          result.add(byte(cp shr 8))
      else:
        let v = cp - 0x10000
        let hi = 0xD800'u32 + (v shr 10)
        let lo = 0xDC00'u32 + (v and 0x3FF)
        if be:
          result.add(byte(hi shr 8))
          result.add(byte(hi and 0xFF))
          result.add(byte(lo shr 8))
          result.add(byte(lo and 0xFF))
        else:
          result.add(byte(hi and 0xFF))
          result.add(byte(hi shr 8))
          result.add(byte(lo and 0xFF))
          result.add(byte(lo shr 8))
  of encUtf32LE, encUtf32BE:
    let be = enc == encUtf32BE
    for r in text.runes:
      let cp = uint32(r)
      if be:
        result.add(byte(cp shr 24))
        result.add(byte((cp shr 16) and 0xFF))
        result.add(byte((cp shr 8) and 0xFF))
        result.add(byte(cp and 0xFF))
      else:
        result.add(byte(cp and 0xFF))
        result.add(byte((cp shr 8) and 0xFF))
        result.add(byte((cp shr 16) and 0xFF))
        result.add(byte(cp shr 24))
  of encLatin1, encWindows1252:
    let win = enc == encWindows1252
    for r in text.runes:
      let cp = uint32(r)
      if cp < 0x80 or (cp >= 0xA0 and cp <= 0xFF):
        result.add(byte(cp))
      elif win:
        var mapped = false
        for i, v in Win1252Map:
          if v == cp and v != 0:
            result.add(byte(0x80 + i))
            mapped = true
            break
        if not mapped:
          txtFail("unrepresentable codepoint U+" & cp.toHex() &
            " for Windows-1252")
      else:
        txtFail("unrepresentable codepoint U+" & cp.toHex() &
          " for Latin-1")

proc convertEndings(text: string, le: TxtLineEnding): string =
  ## LF text to the target breaks. `leMixed`/`leNone` write as LF
  ## (there is no faithful "mixed" target; `leNone` text has no breaks
  ## to convert).
  case le
  of leLF, leNone, leMixed:
    text
  of leCRLF:
    text.replace("\n", "\r\n")
  of leCR:
    text.replace("\n", "\r")

proc bomFor(enc: TxtEncoding): string =
  case enc
  of encUtf8Bom: "\xEF\xBB\xBF"
  of encUtf16LE: "\xFF\xFE"
  of encUtf16BE: "\xFE\xFF"
  of encUtf32LE: "\xFF\xFE\x00\x00"
  of encUtf32BE: "\x00\x00\xFE\xFF"
  else: ""

proc encodeDoc*(text: string, opts = TxtWriteOpts()): seq[byte] =
  ## Encode explicit text under explicit settings. Invalid UTF-8 input
  ## and unrepresentable codepoints fail loudly.
  if not validUtf8Str(text):
    txtFail("input is not valid UTF-8")
  var pool = encodeBody(convertEndings(text, opts.lineEnding),
    opts.encoding)
  if opts.bom:
    let bom = bomFor(opts.encoding)
    if bom != "":
      var withBom = initPool(byte, pool.len + bom.len)
      withBom.appendMany(bom)
      withBom.appendMany(pool.toOpenArray())
      return withBom.toSeq()
  pool.toSeq()

proc encodeDoc*(doc: TxtDoc): seq[byte] =
  ## Encode with the doc's own metadata (faithful rewrite): its
  ## encoding, its BOM flag, its detected breaks (mixed/none as LF).
  let le =
    if doc.lineEnding in {leLF, leCRLF, leCR}: doc.lineEnding
    else: leLF
  encodeDoc(doc.text, TxtWriteOpts(encoding: doc.encoding,
    bom: doc.hasBom, lineEnding: le))

proc writeTextFile*(path, text: string, opts = TxtWriteOpts()) =
  ## Buffered write. `TxtError` on open/short-write. Non-atomic by
  ## design (documented); crash windows truncate, like `writeFile`.
  let data = encodeDoc(text, opts)
  var f: File
  if not open(f, path, fmWrite):
    raise newException(TxtError, "cannot write file: " & path)
  defer: close(f)
  if data.len > 0 and writeBytes(f, data, 0, data.len) != data.len:
    raise newException(TxtError, "short write: " & path)

proc writeTextFile*(path: string, doc: TxtDoc) =
  ## Faithful rewrite under the doc's own metadata.
  writeTextFile(path, doc.text, TxtWriteOpts(encoding: doc.encoding,
    bom: doc.hasBom,
    lineEnding: (if doc.lineEnding in {leLF, leCRLF, leCR}: doc.lineEnding
      else: leLF)))

proc writeTextMapped*(path, text: string, opts = TxtWriteOpts()) =
  ## Single-copy write through a size-known mapping: encode once into
  ## the staging pool, then `copyToMemFile`. Removes any prior file
  ## first (mappings cannot resize). Non-atomic by design.
  let data = encodeDoc(text, opts)
  if data.len == 0:
    writeFile(path, "")
    return
  if fileExists(path):
    try: removeFile(path)
    except OSError as e:
      raise newException(TxtError,
        "cannot remove file: " & path & ": " & e.msg)
  var mf: MemFile
  try:
    mf = memfiles.open(path, fmWrite, newFileSize = data.len)
  except OSError as e:
    raise newException(TxtError,
      "cannot map file: " & path & ": " & e.msg)
  try:
    if data.len > 0:
      var pool = initPool(byte, data.len)
      pool.appendMany(data)
      pool.copyToMemFile(mf)
  finally:
    memfiles.close(mf)

proc writeTextMapped*(path: string, doc: TxtDoc) =
  ## Faithful rewrite through a mapping.
  writeTextMapped(path, doc.text, TxtWriteOpts(encoding: doc.encoding,
    bom: doc.hasBom,
    lineEnding: (if doc.lineEnding in {leLF, leCRLF, leCR}: doc.lineEnding
      else: leLF)))

# ---------------------------------------------------------------- utilities

proc lines*(doc: TxtDoc): seq[string] =
  ## LF-split lines, `splitlines` semantics (no phantom trailing
  ## empty).
  if doc.text == "": return @[]
  result = doc.text.split('\n')
  if result[^1] == "": result.setLen(result.len - 1)

proc lineCount*(doc: TxtDoc): int =
  ## Number of lines (`splitlines` semantics).
  doc.lines().len

proc charCount*(doc: TxtDoc): int =
  ## Unicode scalar count (valid UTF-8 is guaranteed post-decode).
  doc.text.runeLen()

proc wordCount*(doc: TxtDoc): int =
  ## Whitespace-separated runs (`unicode.isWhiteSpace`).
  var inWord = false
  for r in doc.text.runes:
    if unicode.isWhiteSpace(r):
      inWord = false
    elif not inWord:
      inWord = true
      inc result

proc byteCount*(doc: TxtDoc): int =
  ## UTF-8 byte length of the decoded text (not the source size).
  doc.text.len

proc trimTrailingSpace*(text: string): string =
  ## Right-trim spaces/tabs per line, LF-joined.
  var parts = text.split('\n')
  for p in parts.mitems: p = p.strip(leading = false, chars = {' ',
      '\t'})
  parts.join("\n")

proc ensureTrailingNewline*(text: string,
    le: TxtLineEnding = leLF): string =
  ## Append one break iff the text does not end with one.
  if text == "" or text[^1] notin {'\n', '\r'}:
    result = text & (if le == leCRLF: "\r\n" elif le == leCR: "\r"
      else: "\n")
  else:
    result = text

proc decodeLatin1*(data: openArray[byte]): string =
  ## Explicit Latin-1 decode (bytes 1:1 to U+0000-U+00FF).
  decodeSingleByte(data, false)

proc decodeWindows1252*(data: openArray[byte]): string =
  ## Explicit Windows-1252 decode. The five undefined bytes fail loudly
  ## (mapping them anywhere would be invention).
  for b in data:
    if b in Win1252Holes:
      txtFail("undefined Windows-1252 byte 0x" & b.toHex(2))
  decodeSingleByte(data, true)

proc countUtf16Units*(s: string): int =
  ## UTF-16 code-unit count (astral runes count 2). Invalid UTF-8
  ## fails loudly.
  if not validUtf8Str(s):
    txtFail("input is not valid UTF-8")
  for r in s.runes:
    let cp = uint32(r)
    inc result, if cp > 0xFFFF: 2 else: 1

proc truncateUtf16Units*(s: string, maxUnits: int): string =
  ## Cut at a rune boundary so UTF-16 units stay within `maxUnits`.
  ## Invalid UTF-8 fails loudly.
  if not validUtf8Str(s):
    txtFail("input is not valid UTF-8")
  var units = 0
  for r in s.runes:
    let w = if uint32(r) > 0xFFFF: 2 else: 1
    if units + w > maxUnits: break
    units += w
    result.add($r)
