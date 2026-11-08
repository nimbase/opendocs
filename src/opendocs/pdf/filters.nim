## Stream filter pipeline (ISO 32000 §7.4).
##
## decodeCosStream applies /Filter (name or array, long or abbreviated)
## with matching /DecodeParms to a coStream's raw bytes. FlateDecode
## uses the pure-Nim `archive` package (zlib framing with a raw-deflate
## fallback); LZW/ASCII85/ASCIIHex/RunLength are pure Nim. PNG and TIFF
## predictors run after Flate/LZW when parms carry Predictor > 1.
## Coded image filters (DCT/JPX/JBIG2) pass bytes through untouched;
## CCITTFaxDecode stays passthrough in the generic chain too, and real
## 1D/Group-4 decoding happens image-aware in images.nim (Columns
## defaults to /Width, Rows to /Height there), via ccittFaxDecode below.

import std/strutils
import archive/flate
import archive/zlibf
import ./types
import ./lexer
import ./cos

proc checkDecodeBudget*(limits: PdfLimits, n: int, what: string) =
  ## Refuse an allocation or decoded output larger than maxDecodeBytes
  ## *before* it happens (fuzz-hardening: oversized Columns/W/Length
  ## must fail, not allocate).
  if n < 0:
    pdfFail(what & " has negative size " & $n)
  if n > limits.maxDecodeBytes:
    pdfFail(what & " size " & $n & " exceeds decode limit " &
      $limits.maxDecodeBytes)

proc flateDecode*(data: string, limits = defaultPdfLimits()): string =
  ## zlib-wrapped deflate (RFC 1950). Falls back to raw deflate
  ## (RFC 1951) when no zlib header is present. Output past the decode
  ## budget fails instead of allocating without bound.
  if data.len == 0:
    return ""
  checkDecodeBudget(limits, data.len, "FlateDecode input")
  try:
    if data.len >= 2 and (byte(data[0]) and 0x0F) == 8 and
        (int(byte(data[0])) * 256 + int(byte(data[1]))) mod 31 == 0:
      result = zlibDecompress(data)
    else:
      result = inflateAll(data)
  except FlateError as e:
    pdfFail("FlateDecode: inflate failed (" & e.msg & ")")
  except ZlibError as e:
    pdfFail("FlateDecode: inflate failed (" & e.msg & ")")
  checkDecodeBudget(limits, result.len, "FlateDecode output")

proc deflateEncode*(data: string): string =
  ## zlib-wrapped deflate for tests and the M6 writer.
  if data.len == 0:
    return ""
  zlibCompress(data)

# ---------------------------------------------------------------------------
# Predictors (applied after Flate/LZW when parms say so)
# ---------------------------------------------------------------------------

proc paeth(a, b, c: int): int =
  let p = a + b - c
  let pa = abs(p - a)
  let pb = abs(p - b)
  let pc = abs(p - c)
  if pa <= pb and pa <= pc: a
  elif pb <= pc: b
  else: c

proc applyPredictor*(data: string, predictor, colors, bpc,
    columns: int, limits = defaultPdfLimits()): string =
  ## predictor 1 = none; 2 = TIFF horizontal; 10..15 = PNG None/Sub/Up/
  ## Average/Paeth/Optimum-per-row. M2 supports 8 bits per component.
  ## Widths are saturating: a zero width is refused and a row longer
  ## than the data is refused *before* allocating (fuzz-hardening).
  if predictor == 1:
    return data
  if bpc != 8:
    pdfFail("predictor with " & $bpc &
      " bits per component is not supported in M2 (need 8)")
  if colors < 1 or columns < 1:
    pdfFail("predictor needs positive Colors and Columns")
  if colors > limits.maxDecodeBytes or columns > limits.maxDecodeBytes:
    pdfFail("predictor dimensions exceed decode limit " &
      $limits.maxDecodeBytes)
  let stride64 = int64(colors) * int64(columns)
  if stride64 <= 0 or stride64 > int64(limits.maxDecodeBytes):
    pdfFail("predictor row width exceeds decode limit " &
      $limits.maxDecodeBytes)
  let stride = int(stride64)
  if predictor == 2:
    if data.len mod stride != 0:
      pdfFail("TIFF predictor: data length not a multiple of row stride")
    checkDecodeBudget(limits, data.len, "TIFF predictor output")
    result = newString(data.len)
    for i in 0 ..< data.len:
      let left = if i mod stride < colors: 0
        else: int(byte(result[i - colors]))
      result[i] = char((int(byte(data[i])) + left) and 0xFF)
    return
  if predictor < 10 or predictor > 15:
    pdfFail("unknown predictor " & $predictor)
  let rowLen64 = stride64 + 1
  if rowLen64 <= 1 or rowLen64 > int64(limits.maxDecodeBytes) + 1:
    pdfFail("PNG predictor row width exceeds decode limit")
  let rowLen = int(rowLen64)
  if stride == 0:
    pdfFail("PNG predictor has zero row width")
  if data.len mod rowLen != 0:
    pdfFail("PNG predictor: data length not a multiple of row length")
  # Output is data.len - rows (one filter byte per row); refuse a row
  # longer than the data before touching `prev`.
  if data.len > 0 and rowLen > data.len:
    pdfFail("PNG predictor row longer than the data")
  checkDecodeBudget(limits, data.len, "PNG predictor output")
  result = newStringOfCap(data.len)
  var prev = newSeq[byte](stride)
  var i = 0
  # PNG mode (Predictor 10..15): every row starts with its own filter
  # byte 0..4 (None/Sub/Up/Average/Paeth). The file-level value only
  # selects PNG mode; "Optimum" (15) just lets rows vary.
  while i < data.len:
    let f = int(byte(data[i]))
    inc i
    if f < 0 or f > 4:
      pdfFail("bad PNG predictor row filter " & $f)
    for j in 0 ..< stride:
      let a = if j < colors: 0 else: int(byte(result[result.len - colors]))
      let b = int(prev[j])
      let c = if j < colors: 0 else: int(prev[j - colors])
      let v = int(byte(data[i + j]))
      let rec = case f
        of 0: v
        of 1: (v + a) and 0xFF
        of 2: (v + b) and 0xFF
        of 3: (v + (a + b) div 2) and 0xFF
        else: (v + paeth(a, b, c)) and 0xFF
      result.add(char(rec))
    for j in 0 ..< stride:
      prev[j] = byte(result[result.len - stride + j])
    i += stride

# ---------------------------------------------------------------------------
# LZWDecode (EarlyChange 0 or 1)
# ---------------------------------------------------------------------------

const
  LzwClear = 256
  LzwEod = 257
  LzwMaxBits = 12

type BitReader = object
  s: string
  pos: int # bit position

proc readBits(br: var BitReader, n: int): int =
  result = 0
  for _ in 0 ..< n:
    result = result shl 1
    if br.pos div 8 < br.s.len and
        (int(byte(br.s[br.pos div 8])) and (0x80 shr (br.pos mod 8))) != 0:
      result = result or 1
    inc br.pos

proc lzwDecode*(data: string, earlyChange = 1,
    limits = defaultPdfLimits()): string =
  if earlyChange notin [0, 1]:
    pdfFail("LZW EarlyChange must be 0 or 1, got " & $earlyChange)
  if data.len == 0:
    return ""
  checkDecodeBudget(limits, data.len, "LZWDecode input")
  var table = newSeq[seq[byte]](4096)
  for i in 0 ..< 256:
    table[i] = @[byte(i)]
  var nextCode = 258
  var codeLen = 9
  var br = BitReader(s: data, pos: 0)

  template reset() =
    nextCode = 258
    codeLen = 9

  reset()
  if br.pos + codeLen > data.len * 8:
    pdfFail("LZWDecode: truncated input")
  var code = br.readBits(codeLen)
  if code == LzwEod:
    return ""
  if code == LzwClear:
    reset()
    code = br.readBits(codeLen)
    if code == LzwEod:
      return ""
  if code > 257:
    pdfFail("LZWDecode: bad first code " & $code)
  result = ""
  for b in table[code]:
    result.add(char(b))
  var prev = table[code]
  while true:
    if br.pos + codeLen > data.len * 8:
      pdfFail("LZWDecode: truncated input")
    code = br.readBits(codeLen)
    if code == LzwEod:
      return
    if code == LzwClear:
      reset()
      code = br.readBits(codeLen)
      if code == LzwEod:
        return
      if code > 257:
        pdfFail("LZWDecode: bad code after clear " & $code)
      for b in table[code]:
        result.add(char(b))
      prev = table[code]
      continue
    var entry: seq[byte]
    if code < nextCode:
      entry = table[code]
    elif code == nextCode:
      entry = prev & @[prev[0]]
    else:
      pdfFail("LZWDecode: bad code " & $code)
    for b in entry:
      result.add(char(b))
    if result.len > limits.maxDecodeBytes:
      pdfFail("LZWDecode output exceeds decode limit " &
        $limits.maxDecodeBytes)
    if nextCode < 4096:
      table[nextCode] = prev & @[entry[0]]
      inc nextCode
      if nextCode == (1 shl codeLen) - (1 - earlyChange):
        if codeLen < LzwMaxBits:
          inc codeLen
    prev = entry

# ---------------------------------------------------------------------------
# ASCII armor
# ---------------------------------------------------------------------------

proc ascii85Decode*(data: string, limits = defaultPdfLimits()): string =
  checkDecodeBudget(limits, data.len, "ASCII85Decode input")
  var group: array[5, int]
  var n = 0
  var i = 0
  while i < data.len:
    let c = data[i]
    inc i
    if c in {'\x00', '\x09', '\x0A', '\x0C', '\x0D', '\x20'}:
      continue
    if c == 'z':
      if n != 0:
        pdfFail("ASCII85Decode: 'z' inside a group")
      result.add("\x00\x00\x00\x00")
      continue
    if c == '~':
      if i < data.len and data[i] == '>':
        inc i
      break
    if c < '!' or c > 'u':
      pdfFail("ASCII85Decode: bad character")
    group[n] = ord(c) - ord('!')
    inc n
    if n == 5:
      var v = 0
      for g in group:
        v = v * 85 + g
      result.add(char((v shr 24) and 0xFF))
      result.add(char((v shr 16) and 0xFF))
      result.add(char((v shr 8) and 0xFF))
      result.add(char(v and 0xFF))
      n = 0
  if n > 0:
    if n == 1:
      pdfFail("ASCII85Decode: trailing single character")
    for j in n ..< 5:
      group[j] = 84 # 'u'
    var v = 0
    for g in group:
      v = v * 85 + g
    for j in 0 ..< n - 1:
      result.add(char((v shr (24 - 8 * j)) and 0xFF))
  checkDecodeBudget(limits, result.len, "ASCII85Decode output")

proc asciiHexDecode*(data: string, limits = defaultPdfLimits()): string =
  checkDecodeBudget(limits, data.len, "ASCIIHexDecode input")
  var hi = -1
  for c in data:
    if c in {'\x00', '\x09', '\x0A', '\x0C', '\x0D', '\x20'}:
      continue
    if c == '>':
      break
    if c notin HexDigits:
      pdfFail("ASCIIHexDecode: bad character")
    let v = hexNibble(c)
    if hi < 0:
      hi = v
    else:
      result.add(char(hi * 16 + v))
      hi = -1
  if hi >= 0:
    result.add(char(hi * 16))
  checkDecodeBudget(limits, result.len, "ASCIIHexDecode output")

# ---------------------------------------------------------------------------
# RunLengthDecode
# ---------------------------------------------------------------------------

proc runLengthDecode*(data: string, limits = defaultPdfLimits()): string =
  checkDecodeBudget(limits, data.len, "RunLengthDecode input")
  var i = 0
  while i < data.len:
    let n = int(byte(data[i]))
    inc i
    if n == 128:
      return
    if n < 128:
      if i + n >= data.len:
        pdfFail("RunLengthDecode: truncated literal run")
      result.add(data[i ..< i + n + 1])
      i += n + 1
    else:
      if i >= data.len:
        pdfFail("RunLengthDecode: truncated replicate run")
      if 257 - n > limits.maxDecodeBytes - result.len:
        pdfFail("RunLengthDecode output exceeds decode limit " &
          $limits.maxDecodeBytes)
      for _ in 0 ..< 257 - n:
        result.add(data[i])
      inc i
  checkDecodeBudget(limits, result.len, "RunLengthDecode output")

# ---------------------------------------------------------------------------
# Dispatcher
# ---------------------------------------------------------------------------

proc canonFilterName*(n: string): string =
  ## Accept abbreviated filter names (§7.4.1 Table 5).
  case n
  of "Fl": "FlateDecode"
  of "LZW": "LZWDecode"
  of "AHx": "ASCIIHexDecode"
  of "A85": "ASCII85Decode"
  of "LZWDecode", "FlateDecode", "ASCIIHexDecode", "ASCII85Decode",
     "RunLengthDecode", "RL": n
  of "CCF": "CCITTFaxDecode"
  of "DCT": "DCTDecode"
  else: n

proc isPassthrough*(name: string): bool =
  ## Image filters pass bytes through in M2; decoding them is M5 work.
  name in ["DCTDecode", "JPXDecode", "JBIG2Decode", "CCITTFaxDecode"]

proc parmInt(parms: CosObj, key: string, dflt: int): int =
  let v = parms.dictGet(key)
  case v.kind
  of coInt: v.ival
  of coNull: dflt
  else: pdfFail("filterDecodeParms: /" & key & " must be an integer")

proc parmBool(parms: CosObj, key: string, dflt: bool): bool =
  let v = parms.dictGet(key)
  case v.kind
  of coBool: v.bval
  of coNull: dflt
  else: pdfFail("filterDecodeParms: /" & key & " must be a boolean")

# ---------------------------------------------------------------------------
# CCITTFaxDecode (ITU-T T.4 1D + T.6 2D). Pure Nim.
##
## Code words verified against the `fax` crate's maps.rs tables (same T.4
## words this reference ships; the words themselves are ITU spec facts) and
## decoder semantics (EOL/fill/RTC framing, transitions, pels padding,
## checked arithmetic) from its decoder.rs. Independent vectors come from
## tiffcp-written G3/G4 strips (tests/t_pdf_ccitt.nim); the decoder must
## agree with libtiff, not with itself.
## Output is packed rows ((Columns+7) div 8 bytes, MSB first) in PDF image
## convention (1 = white) with /BlackIs1 applied (true inverts).
## K > 0 (Group 3 2D) fails loudly. /DamagedRowsBeforeError substitutes
## white rows: 1D resyncs at the next EOL; G4 has no resync points, so the
## reference row is kept and decoding continues (budget-bounded).
# ---------------------------------------------------------------------------

type
  CcRun = tuple[bits, nbits, val: int]
  CcBitReader = object
    s: string
    pos: int ## bit position, MSB-first

proc ccPeek(br: CcBitReader, n: int): int =
  ## Next n bits as an integer, or -1 when fewer than n bits remain.
  if n <= 0 or n > 24: return -1
  if br.pos + n > br.s.len * 8: return -1
  for i in 0 ..< n:
    let p = br.pos + i
    result = result * 2 +
      ((int(byte(br.s[p div 8])) shr (7 - (p mod 8))) and 1)

proc ccEat(br: var CcBitReader, n: int) = br.pos += n

proc ccBitsLeft(br: CcBitReader): int = br.s.len * 8 - br.pos

const
  CcWhiteRuns: array[104, CcRun] = [
    (0b00110101, 8, 0), (0b000111, 6, 1), (0b0111, 4, 2),
    (0b1000, 4, 3), (0b1011, 4, 4), (0b1100, 4, 5),
    (0b1110, 4, 6), (0b1111, 4, 7), (0b10011, 5, 8),
    (0b10100, 5, 9), (0b00111, 5, 10), (0b01000, 5, 11),
    (0b001000, 6, 12), (0b000011, 6, 13), (0b110100, 6, 14),
    (0b110101, 6, 15), (0b101010, 6, 16), (0b101011, 6, 17),
    (0b0100111, 7, 18), (0b0001100, 7, 19), (0b0001000, 7, 20),
    (0b0010111, 7, 21), (0b0000011, 7, 22), (0b0000100, 7, 23),
    (0b0101000, 7, 24), (0b0101011, 7, 25), (0b0010011, 7, 26),
    (0b0100100, 7, 27), (0b0011000, 7, 28), (0b00000010, 8, 29),
    (0b00000011, 8, 30), (0b00011010, 8, 31), (0b00011011, 8, 32),
    (0b00010010, 8, 33), (0b00010011, 8, 34), (0b00010100, 8, 35),
    (0b00010101, 8, 36), (0b00010110, 8, 37), (0b00010111, 8, 38),
    (0b00101000, 8, 39), (0b00101001, 8, 40), (0b00101010, 8, 41),
    (0b00101011, 8, 42), (0b00101100, 8, 43), (0b00101101, 8, 44),
    (0b00000100, 8, 45), (0b00000101, 8, 46), (0b00001010, 8, 47),
    (0b00001011, 8, 48), (0b01010010, 8, 49), (0b01010011, 8, 50),
    (0b01010100, 8, 51), (0b01010101, 8, 52), (0b00100100, 8, 53),
    (0b00100101, 8, 54), (0b01011000, 8, 55), (0b01011001, 8, 56),
    (0b01011010, 8, 57), (0b01011011, 8, 58), (0b01001010, 8, 59),
    (0b01001011, 8, 60), (0b00110010, 8, 61), (0b00110011, 8, 62),
    (0b00110100, 8, 63), (0b11011, 5, 64), (0b10010, 5, 128),
    (0b010111, 6, 192), (0b0110111, 7, 256), (0b00110110, 8, 320),
    (0b00110111, 8, 384), (0b01100100, 8, 448), (0b01100101, 8, 512),
    (0b01101000, 8, 576), (0b01100111, 8, 640), (0b011001100, 9, 704),
    (0b011001101, 9, 768), (0b011010010, 9, 832), (0b011010011, 9, 896),
    (0b011010100, 9, 960), (0b011010101, 9, 1024), (0b011010110, 9, 1088),
    (0b011010111, 9, 1152), (0b011011000, 9, 1216), (0b011011001, 9, 1280),
    (0b011011010, 9, 1344), (0b011011011, 9, 1408), (0b010011000, 9, 1472),
    (0b010011001, 9, 1536), (0b010011010, 9, 1600), (0b011000, 6, 1664),
    (0b010011011, 9, 1728), (0b00000001000, 11, 1792),
    (0b00000001100, 11, 1856), (0b00000001101, 11, 1920),
    (0b000000010010, 12, 1984), (0b000000010011, 12, 2048),
    (0b000000010100, 12, 2112), (0b000000010101, 12, 2176),
    (0b000000010110, 12, 2240), (0b000000010111, 12, 2304),
    (0b000000011100, 12, 2368), (0b000000011101, 12, 2432),
    (0b000000011110, 12, 2496), (0b000000011111, 12, 2560),
  ]
  CcBlackRuns: array[104, CcRun] = [
    (0b0000110111, 10, 0), (0b010, 3, 1), (0b11, 2, 2),
    (0b10, 2, 3), (0b011, 3, 4), (0b0011, 4, 5),
    (0b0010, 4, 6), (0b00011, 5, 7), (0b000101, 6, 8),
    (0b000100, 6, 9), (0b0000100, 7, 10), (0b0000101, 7, 11),
    (0b0000111, 7, 12), (0b00000100, 8, 13), (0b00000111, 8, 14),
    (0b000011000, 9, 15), (0b0000010111, 10, 16), (0b0000011000, 10, 17),
    (0b0000001000, 10, 18), (0b00001100111, 11, 19),
    (0b00001101000, 11, 20), (0b00001101100, 11, 21),
    (0b00000110111, 11, 22), (0b00000101000, 11, 23),
    (0b00000010111, 11, 24), (0b00000011000, 11, 25),
    (0b000011001010, 12, 26), (0b000011001011, 12, 27),
    (0b000011001100, 12, 28), (0b000011001101, 12, 29),
    (0b000001101000, 12, 30), (0b000001101001, 12, 31),
    (0b000001101010, 12, 32), (0b000001101011, 12, 33),
    (0b000011010010, 12, 34), (0b000011010011, 12, 35),
    (0b000011010100, 12, 36), (0b000011010101, 12, 37),
    (0b000011010110, 12, 38), (0b000011010111, 12, 39),
    (0b000001101100, 12, 40), (0b000001101101, 12, 41),
    (0b000011011010, 12, 42), (0b000011011011, 12, 43),
    (0b000001010100, 12, 44), (0b000001010101, 12, 45),
    (0b000001010110, 12, 46), (0b000001010111, 12, 47),
    (0b000001100100, 12, 48), (0b000001100101, 12, 49),
    (0b000001010010, 12, 50), (0b000001010011, 12, 51),
    (0b000000100100, 12, 52), (0b000000110111, 12, 53),
    (0b000000111000, 12, 54), (0b000000100111, 12, 55),
    (0b000000101000, 12, 56), (0b000001011000, 12, 57),
    (0b000001011001, 12, 58), (0b000000101011, 12, 59),
    (0b000000101100, 12, 60), (0b000001011010, 12, 61),
    (0b000001100110, 12, 62), (0b000001100111, 12, 63),
    (0b0000001111, 10, 64), (0b000011001000, 12, 128),
    (0b000011001001, 12, 192), (0b000001011011, 10, 256),
    (0b000000110011, 10, 320), (0b000000110100, 10, 384),
    (0b000000110101, 10, 448), (0b0000001101100, 13, 512),
    (0b0000001101101, 13, 576), (0b0000001001010, 13, 640),
    (0b0000001001011, 13, 704), (0b0000001001100, 13, 768),
    (0b0000001001101, 13, 832), (0b0000001110010, 13, 896),
    (0b0000001110011, 13, 960), (0b0000001110100, 13, 1024),
    (0b0000001110101, 13, 1088), (0b0000001110110, 13, 1152),
    (0b0000001110111, 13, 1216), (0b0000001010010, 13, 1280),
    (0b0000001010011, 13, 1344), (0b0000001010100, 13, 1408),
    (0b0000001010101, 13, 1472), (0b0000001011010, 13, 1536),
    (0b0000001011011, 13, 1600), (0b0000001100100, 13, 1664),
    (0b0000001100101, 13, 1728), (0b00000001000, 11, 1792),
    (0b00000001100, 11, 1856), (0b00000001101, 11, 1920),
    (0b000000010010, 12, 1984), (0b000000010011, 12, 2048),
    (0b000000010100, 12, 2112), (0b000000010101, 12, 2176),
    (0b000000010110, 12, 2240), (0b000000010111, 12, 2304),
    (0b000000011100, 12, 2368), (0b000000011101, 12, 2432),
    (0b000000011110, 12, 2496), (0b000000011111, 12, 2560),
  ]

type CcModeKind = enum cmPass, cmHoriz, cmV0, cmVR, cmVL, cmExt, cmEol

const CcModes: array[11, tuple[bits, nbits: int,
    kind: CcModeKind, delta: int]] = [
  (0b0001, 4, cmPass, 0), (0b001, 3, cmHoriz, 0), (0b1, 1, cmV0, 0),
  (0b011, 3, cmVR, 1), (0b000011, 6, cmVR, 2), (0b0000011, 7, cmVR, 3),
  (0b010, 3, cmVL, -1), (0b000010, 6, cmVL, -2), (0b0000010, 7, cmVL, -3),
  (0b0000001, 7, cmExt, 0), (0b000000000001, 12, cmEol, 0),
]

proc ccDecodeRun(br: var CcBitReader, white: bool): tuple[run, code: int] =
  ## One run: makeup accumulation plus terminating. code 0 ok, 1 EOL
  ## where a run was expected, -1 corrupt/truncated.
  var total = 0
  while true:
    var matched = false
    for nbits in 1 .. 12:
      let v = br.ccPeek(nbits)
      if v < 0: return (0, -1)
      if nbits == 12 and v == 1:
        return (0, if total == 0: 1 else: -1)
      let tab = if white: CcWhiteRuns else: CcBlackRuns
      var found = -1
      for t in tab:
        if t.nbits == nbits and t.bits == v:
          found = t.val
          break
      if found >= 0:
        br.ccEat(nbits)
        if total > (1 shl 21) - found: return (0, -1)
        if found < 64:
          return (total + found, 0)
        total += found
        matched = true
        break
    if not matched: return (0, -1)

proc ccDecodeMode(br: var CcBitReader):
    tuple[kind: CcModeKind, delta, code: int] =
  ## One 2D mode. code 0 ok (cmEol included), -1 truncated/corrupt.
  for nbits in 1 .. 12:
    let v = br.ccPeek(nbits)
    if v < 0: return (cmEol, 0, -1)
    for m in CcModes:
      if m.nbits == nbits and m.bits == v:
        br.ccEat(nbits)
        return (m.kind, m.delta, 0)
  (cmEol, 0, -1)

proc ccEolAhead(br: CcBitReader): bool =
  ## Fill+EOL (or bare EOL) ahead: 9 zero bits cannot start any run or
  ## mode code (the longest leading-zero run in any code is 8).
  br.ccPeek(9) == 0

proc ccSkipEol(br: var CcBitReader): bool =
  ## Skip fill zeros and consume the EOL's terminating 1. False when no
  ## EOL is present (or input ends).
  while br.ccPeek(1) == 0: br.ccEat(1)
  if br.ccPeek(1) == 1:
    br.ccEat(1)
    return true
  false

type CcTrans = object
  edges: seq[int]
  pos: int

proc ccSeekBack(t: var CcTrans, start: int) =
  t.pos = min(t.pos, max(0, t.edges.len - 1))
  while t.pos > 0 and start < t.edges[t.pos - 1]:
    dec t.pos

proc ccNextColor(t: var CcTrans, start: int, black,
    rowStart: bool): int =
  ## Next changing element of the wanted color right of start, or -1.
  if rowStart:
    if black:
      t.pos = 1
      return if t.edges.len > 0: t.edges[0] else: -1
    t.pos = 2
    return if t.edges.len > 1: t.edges[1] else: -1
  while t.pos < t.edges.len:
    if t.edges[t.pos] <= start:
      inc t.pos
      continue
    if (t.pos mod 2 == 0) != black:
      inc t.pos
    break
  if t.pos < t.edges.len:
    result = t.edges[t.pos]
    inc t.pos
  else:
    result = -1

proc ccNextEdge(t: var CcTrans): int =
  if t.pos < t.edges.len:
    result = t.edges[t.pos]
    inc t.pos
  else:
    result = -1
proc ccSetBit(buf: var string, x: int, one: bool) =
  let bi = x div 8
  let m = 0x80 shr (x mod 8)
  let cur = int(byte(buf[bi]))
  buf[bi] = char(if one: cur or m else: cur and (255 - m))

proc ccPackRow(tr: seq[int], width, stride: int,
    blackIs1: bool): string =
  ## Transitions (color changes from white) to packed bits, 1 = white.
  result = newString(stride)
  let whiteByte = if blackIs1: '\x00' else: '\xFF'
  for i in 0 ..< stride: result[i] = whiteByte
  let blackBit = blackIs1
  let fullBlack = if blackBit: '\xFF' else: '\x00'
  var x = 0
  var white = true
  var ti = 0
  while x < width:
    let runEnd = if ti < tr.len: min(tr[ti], width) else: width
    if not white:
      var px = x
      while px < runEnd and px mod 8 != 0:
        ccSetBit(result, px, blackBit)
        inc px
      while px + 8 <= runEnd:
        result[px div 8] = fullBlack
        px += 8
      while px < runEnd:
        ccSetBit(result, px, blackBit)
        inc px
    x = runEnd
    white = not white
    inc ti

proc ccittParms*(parms: CosObj): tuple[columns, rows, k: int,
    blackIs1, byteAlign, endOfLine: bool, damaged: int] =
  ## /DecodeParms for CCITTFaxDecode with Table-22 defaults. Columns 0
  ## means absent (callers with image context substitute /Width).
  result = (0, 0, 0, false, false, false, 0)
  if parms.kind == coNull: return
  if parms.kind != coDict:
    pdfFail("/DecodeParms for CCITTFaxDecode must be a dict or null")
  result = (parmInt(parms, "Columns", 0), parmInt(parms, "Rows", 0),
    parmInt(parms, "K", 0), parmBool(parms, "BlackIs1", false),
    parmBool(parms, "EncodedByteAlign", false),
    parmBool(parms, "EndOfLine", false),
    parmInt(parms, "DamagedRowsBeforeError", 0))

proc ccittFaxDecode*(data: string, columns, rows, k: int,
    blackIs1, byteAlign, endOfLine: bool, damagedRows: int,
    limits = defaultPdfLimits()): string =
  ## Group 3 1D (K == 0) or Group 4 2D (K < 0) to packed rows. K > 0
  ## (mixed 1D/2D) fails loudly. rows <= 0 decodes until RTC or data
  ## end; rows > 0 decodes exactly that many, padding short data with
  ## white. Corrupt rows fail unless damagedRows covers them (white
  ## substitute; 1D resyncs at the next EOL, G4 keeps the reference).
  if k > 0:
    pdfFail("CCITTFaxDecode with K > 0 (Group 3 2D) is not supported")
  if columns < 1 or columns > 1 shl 20:
    pdfFail("CCITTFaxDecode: bad /Columns " & $columns)
  if rows < 0 or rows > 1 shl 24:
    pdfFail("CCITTFaxDecode: bad /Rows " & $rows)
  if damagedRows < 0:
    pdfFail("CCITTFaxDecode: bad /DamagedRowsBeforeError")
  checkDecodeBudget(limits, columns, "CCITT /Columns")
  let stride = (columns + 7) div 8
  checkDecodeBudget(limits, stride, "CCITT row stride")
  let target = rows # <= 0 means unlimited
  if target > 0:
    let total64 = int64(target) * int64(stride)
    if total64 > int64(limits.maxDecodeBytes):
      pdfFail("CCITT output size exceeds decode limit " &
        $limits.maxDecodeBytes)
  var br = CcBitReader(s: data, pos: 0)
  var budget = damagedRows
  var rowsDone = 0
  var whiteRow = newString(stride)
  let wb = if blackIs1: '\x00' else: '\xFF'
  for i in 0 ..< stride: whiteRow[i] = wb
  if k == 0:
    # Group 3 1D with optional EOL framing.
    var lead = 0
    while br.ccEolAhead() and lead < 16:
      discard br.ccSkipEol()
      inc lead
    while target <= 0 or rowsDone < target:
      if br.ccBitsLeft() <= 0: break
      if rowsDone > 0 and br.ccBitsLeft() < 12: break # trailing pad
      var pre = 0
      while br.ccEolAhead() and pre < 16:
        discard br.ccSkipEol() # stray framing EOLs never widen rows
        inc pre
      var tr: seq[int] = @[]
      var a0 = 0
      var white = true
      var bad = false
      while a0 < columns:
        if br.ccEolAhead(): break
        let r = br.ccDecodeRun(white)
        if r.code == 1: break # EOL ends a short row; pack pads white
        if r.code != 0:
          bad = true
          break
        if r.run < 0 or a0 > (1 shl 21) - r.run:
          bad = true
          break
        a0 += r.run
        tr.add(a0)
        white = not white
      if bad:
        if budget > 0:
          dec budget
          result.add(whiteRow)
          inc rowsDone
          var guard = 0
          while br.ccBitsLeft() > 0 and not br.ccEolAhead():
            br.ccEat(1)
            inc guard
            if guard > limits.maxDecodeBytes * 8 + 16:
              pdfFail("CCITTFaxDecode: resync runaway")
          if br.ccBitsLeft() <= 0: break
          discard br.ccSkipEol()
          continue
        pdfFail("CCITTFaxDecode: corrupt 1D row " & $rowsDone)
      result.add(ccPackRow(tr, columns, stride, blackIs1))
      inc rowsDone
      if target > 0 and rowsDone >= target: break
      if br.ccBitsLeft() <= 0: break
      if br.ccEolAhead():
        discard br.ccSkipEol()
        if byteAlign:
          while br.pos mod 8 != 0 and br.ccPeek(1) == 0: br.ccEat(1)
        var eols = 1
        while eols < 6 and br.ccEolAhead():
          discard br.ccSkipEol()
          inc eols
        if eols == 6: break # RTC
      elif endOfLine:
        if budget > 0:
          dec budget
        else:
          pdfFail("CCITTFaxDecode: missing EOL after row " &
            $(rowsDone - 1))
  else:
    # Group 4 2D. Reference starts all-white; EOFB ends the data.
    var rf = CcTrans(edges: @[], pos: 0)
    var ended = false
    while (target <= 0 or rowsDone < target) and not ended:
      if br.ccBitsLeft() <= 0: break
      if rowsDone > 0 and br.ccBitsLeft() < 12: break # trailing pad
      if br.ccPeek(12) == 1:
        br.ccEat(12)
        break # EOFB
      var cur: seq[int] = @[]
      var a0 = 0
      var white = true
      var rowStart = true
      var bad = false
      while a0 < columns:
        let m = br.ccDecodeMode()
        if m.code != 0:
          bad = true
          break
        case m.kind
        of cmPass:
          if rowStart and white:
            rf.pos += 1
          else:
            # wanted change is the opposite of the current color
            if rf.ccNextColor(a0, white, false) < 0:
              bad = true
              break
          let b2 = rf.ccNextEdge()
          if b2 < 0:
            bad = true
            break
          a0 = b2
        of cmHoriz:
          let r1 = br.ccDecodeRun(white)
          if r1.code != 0:
            bad = true
            break
          let r2 = br.ccDecodeRun(not white)
          if r2.code != 0:
            bad = true
            break
          if r1.run < 0 or r2.run < 0 or a0 > (1 shl 21) - r1.run or
              a0 + r1.run > (1 shl 21) - r2.run:
            bad = true
            break
          let a1 = a0 + r1.run
          let a2 = a1 + r2.run
          if a1 < columns: cur.add(a1)
          if a2 >= columns: break
          cur.add(a2)
          a0 = a2
        of cmV0, cmVR, cmVL:
          # b1 is the reference change of the opposite color (the new run's
          # color); missing means the reference stays put -> use width.
          let b1 = rf.ccNextColor(a0, white, rowStart)
          let bb = if b1 < 0: columns else: b1
          let a1 = bb + m.delta
          if a1 < 0 or a1 > columns:
            bad = true
            break
          if a1 < columns: cur.add(a1)
          white = not white
          a0 = a1
          if m.delta < 0: rf.ccSeekBack(a0)
        of cmExt:
          if br.ccPeek(3) >= 0: br.ccEat(3)
          bad = true
          break
        of cmEol:
          ended = true
          bad = true # discard the partial row; loop exits below
          break
        rowStart = false
      if ended: break
      if bad:
        if budget > 0:
          dec budget
          result.add(whiteRow) # reference row kept, decoding continues
          inc rowsDone
          continue
        pdfFail("CCITTFaxDecode: corrupt 2D row " & $rowsDone)
      rf.edges = cur
      rf.pos = 0
      result.add(ccPackRow(cur, columns, stride, blackIs1))
      inc rowsDone
  if rowsDone == 0:
    pdfFail("CCITTFaxDecode: no rows decoded")
  if target > 0:
    var pad = target - rowsDone
    while pad > 0:
      result.add(whiteRow)
      dec pad

proc applyOne(name: string, parms: CosObj, raw: string,
    limits = defaultPdfLimits()): string =
  case name
  of "FlateDecode":
    let p = parms.dictGet("Predictor")
    let decoded = flateDecode(raw, limits)
    if p.kind == coNull:
      decoded
    else:
      applyPredictor(decoded, p.asInt(),
        parmInt(parms, "Colors", 1),
        parmInt(parms, "BitsPerComponent", 8),
        parmInt(parms, "Columns", 1), limits)
  of "LZWDecode":
    let early = parmInt(parms, "EarlyChange", 1)
    let decoded = lzwDecode(raw, early, limits)
    let p = parms.dictGet("Predictor")
    if p.kind == coNull:
      decoded
    else:
      applyPredictor(decoded, p.asInt(),
        parmInt(parms, "Colors", 1),
        parmInt(parms, "BitsPerComponent", 8),
        parmInt(parms, "Columns", 1), limits)
  of "ASCII85Decode": ascii85Decode(raw, limits)
  of "ASCIIHexDecode": asciiHexDecode(raw, limits)
  of "RunLengthDecode", "RL": runLengthDecode(raw, limits)
  else:
    if isPassthrough(name):
      raw
    else:
      pdfFail("unsupported stream filter /" & name)

proc decodeChain*(filter, parms: CosObj, raw: string,
    limits = defaultPdfLimits()): string =
  ## Apply /Filter with /DecodeParms (each a name/dict, array, or null).
  if filter.kind == coNull:
    return raw
  var names: seq[string] = @[]
  var plist: seq[CosObj] = @[]
  case filter.kind
  of coName: names.add(canonFilterName(filter.name))
  of coArray:
    for f in filter.items:
      if f.kind != coName:
        pdfFail("/Filter array must hold names")
      names.add(canonFilterName(f.name))
  else:
    pdfFail("/Filter must be a name or array")
  case parms.kind
  of coNull:
    for _ in names:
      plist.add(CosObj(kind: coNull))
  of coDict:
    for _ in names:
      plist.add(parms)
  of coArray:
    if parms.items.len != names.len:
      pdfFail("/DecodeParms array length must match /Filter")
    plist = parms.items
  else:
    pdfFail("/DecodeParms must be a dict, array, or null")
  result = raw
  for i, name in names:
    result = applyOne(name, plist[i], result, limits)

proc decodeCosStream*(s: CosObj,
    limits = defaultPdfLimits()): string =
  ## Decode a coStream using its own /Filter + /DecodeParms.
  if s.kind != coStream:
    pdfFail("decodeCosStream needs a stream object")
  var filter = CosObj(kind: coNull)
  var parms = CosObj(kind: coNull)
  for i, k in s.streamDict:
    if k == "Filter":
      filter = s.streamVals[i]
    elif k == "DecodeParms":
      parms = s.streamVals[i]
  decodeChain(filter, parms, s.raw)
