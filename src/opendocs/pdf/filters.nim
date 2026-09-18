## Stream filter pipeline (ISO 32000 §7.4).
##
## decodeCosStream applies /Filter (name or array, long or abbreviated)
## with matching /DecodeParms to a coStream's raw bytes. FlateDecode
## uses zlib; LZW/ASCII85/ASCIIHex/RunLength are pure Nim. PNG and TIFF
## predictors run after Flate/LZW when parms carry Predictor > 1.
## Image filters (DCT/JPX/JBIG2/CCITT) pass bytes through untouched;
## decoding them is M5 work.

import std/strutils
import zlib/zlib_api
import ./types
import ./lexer
import ./cos

proc inflateRaw(data: string, windowBits: ZWindowBits): string =
  if data.len == 0:
    return ""
  var zs = ZStream(
    next_in: cast[ptr uint8](unsafeAddr data[0]),
    avail_in: data.len.cuint)
  var r = zs.inflateInit2(windowBits)
  if r != Z_OK:
    pdfFail("FlateDecode: inflateInit failed (" & $r & ")")
  var cap = max(data.len * 2 + 16, 64)
  result = newString(cap)
  var total = 0
  var lastIn: culong = 0
  while true:
    if total == cap:
      cap *= 2
      result.setLen(cap)
    zs.next_out = cast[ptr uint8](addr result[total])
    zs.avail_out = cuint(cap - total)
    r = zs.inflate(Z_FINISH)
    total = cap - int(zs.avail_out)
    if r == Z_STREAM_END:
      break
    if r == Z_NEED_DICT:
      discard zs.inflateEnd()
      pdfFail("FlateDecode: preset dictionary not supported")
    let roomLeft = int(zs.avail_out) > 0
    if (r == Z_OK or r == Z_BUF_ERROR) and
        (not roomLeft or zs.total_in > lastIn):
      # Output full (loop grows it) or input still being consumed.
      lastIn = zs.total_in
      continue
    let msg = if zs.msg == nil: $r else: $zs.msg
    discard zs.inflateEnd()
    if zs.avail_in == 0 and roomLeft:
      pdfFail("FlateDecode: truncated input")
    pdfFail("FlateDecode: inflate failed (" & msg & ")")
  discard zs.inflateEnd()
  result.setLen(total)

proc flateDecode*(data: string): string =
  ## zlib-wrapped deflate (RFC 1950). Falls back to raw deflate
  ## (RFC 1951) when no zlib header is present.
  if data.len >= 2 and (byte(data[0]) and 0x0F) == 8 and
      (int(byte(data[0])) * 256 + int(byte(data[1]))) mod 31 == 0:
    inflateRaw(data, Z_DEFAULT_WINDOW_BITS)
  else:
    inflateRaw(data, Z_RAW_DEFLATE)

proc deflateEncode*(data: string): string =
  ## zlib-wrapped deflate for tests and the M6 writer.
  if data.len == 0:
    return ""
  var zs = ZStream(
    next_in: cast[ptr uint8](unsafeAddr data[0]),
    avail_in: data.len.cuint)
  var r = zs.deflateInit(Z_DEFAULT_COMPRESSION)
  if r != Z_OK:
    pdfFail("deflateInit failed (" & $r & ")")
  let bound = int(zs.deflateBound(data.len.culong)) + 16
  result = newString(bound)
  zs.next_out = cast[ptr uint8](addr result[0])
  zs.avail_out = cuint(bound)
  r = zs.deflate(Z_FINISH)
  let total = bound - int(zs.avail_out)
  discard zs.deflateEnd()
  if r != Z_STREAM_END:
    pdfFail("deflate failed (" & $r & ")")
  result.setLen(total)

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
    columns: int): string =
  ## predictor 1 = none; 2 = TIFF horizontal; 10..15 = PNG None/Sub/Up/
  ## Average/Paeth/Optimum-per-row. M2 supports 8 bits per component.
  if predictor == 1:
    return data
  if bpc != 8:
    pdfFail("predictor with " & $bpc &
      " bits per component is not supported in M2 (need 8)")
  if colors < 1 or columns < 1:
    pdfFail("predictor needs positive Colors and Columns")
  let stride = colors * columns
  if predictor == 2:
    if data.len mod stride != 0:
      pdfFail("TIFF predictor: data length not a multiple of row stride")
    result = newString(data.len)
    for i in 0 ..< data.len:
      let left = if i mod stride < colors: 0
        else: int(byte(result[i - colors]))
      result[i] = char((int(byte(data[i])) + left) and 0xFF)
    return
  if predictor < 10 or predictor > 15:
    pdfFail("unknown predictor " & $predictor)
  let rowLen = stride + 1
  if data.len mod rowLen != 0:
    pdfFail("PNG predictor: data length not a multiple of row length")
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

proc lzwDecode*(data: string, earlyChange = 1): string =
  if earlyChange notin [0, 1]:
    pdfFail("LZW EarlyChange must be 0 or 1, got " & $earlyChange)
  if data.len == 0:
    return ""
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

proc ascii85Decode*(data: string): string =
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

proc asciiHexDecode*(data: string): string =
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

# ---------------------------------------------------------------------------
# RunLengthDecode
# ---------------------------------------------------------------------------

proc runLengthDecode*(data: string): string =
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
      for _ in 0 ..< 257 - n:
        result.add(data[i])
      inc i

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

proc applyOne(name: string, parms: CosObj, raw: string): string =
  case name
  of "FlateDecode":
    let p = parms.dictGet("Predictor")
    let decoded = flateDecode(raw)
    if p.kind == coNull:
      decoded
    else:
      applyPredictor(decoded, p.asInt(),
        parmInt(parms, "Colors", 1),
        parmInt(parms, "BitsPerComponent", 8),
        parmInt(parms, "Columns", 1))
  of "LZWDecode":
    let early = parmInt(parms, "EarlyChange", 1)
    let decoded = lzwDecode(raw, early)
    let p = parms.dictGet("Predictor")
    if p.kind == coNull:
      decoded
    else:
      applyPredictor(decoded, p.asInt(),
        parmInt(parms, "Colors", 1),
        parmInt(parms, "BitsPerComponent", 8),
        parmInt(parms, "Columns", 1))
  of "ASCII85Decode": ascii85Decode(raw)
  of "ASCIIHexDecode": asciiHexDecode(raw)
  of "RunLengthDecode", "RL": runLengthDecode(raw)
  else:
    if isPassthrough(name):
      raw
    else:
      pdfFail("unsupported stream filter /" & name)

proc decodeChain*(filter, parms: CosObj, raw: string): string =
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
    result = applyOne(name, plist[i], result)

proc decodeCosStream*(s: CosObj): string =
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
