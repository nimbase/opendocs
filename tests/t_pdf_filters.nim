import std/strutils
import unittest
import zlib/zlib_api
import ../src/opendocs/pdf
import ../src/opendocs/pdf/cos
import ../src/opendocs/pdf/docmodel
import ../src/opendocs/pdf/filters
import ./pdf_support

proc rawDeflate(data: string): string =
  ## Raw RFC 1951 deflate (no zlib wrapper) for fallback-path tests.
  var zs = ZStream(next_in: cast[ptr uint8](unsafeAddr data[0]),
    avail_in: data.len.cuint)
  check zs.deflateInit2(Z_DEFAULT_COMPRESSION, Z_DEFLATED, Z_RAW_DEFLATE,
    Z_DEFAULT_MEM_LEVEL, Z_DEFAULT_STRATEGY) == Z_OK
  let bound = int(zs.deflateBound(data.len.culong)) + 8
  result = newString(bound)
  zs.next_out = cast[ptr uint8](addr result[0])
  zs.avail_out = cuint(bound)
  check zs.deflate(Z_FINISH) == Z_STREAM_END
  let total = bound - int(zs.avail_out)
  discard zs.deflateEnd()
  result.setLen(total)

proc lzwEncode(data: string, earlyChange = 1): string =
  ## Minimal PDF-flavor LZW encoder matching lzwDecode rules.
  var dict: seq[tuple[key: seq[byte], code: int]] = @[]
  var nextCode = 258
  var codeLen = 9
  var enc = ""
  var bitBuf = 0
  var bitN = 0
  proc emit(code: int) =
    bitBuf = (bitBuf shl codeLen) or code
    bitN += codeLen
    while bitN >= 8:
      bitN -= 8
      enc.add(char((bitBuf shr bitN) and 0xFF))
  proc dictFind(pat: seq[byte]): int =
    if pat.len == 1:
      return int(pat[0])
    for (k, c) in dict:
      if k == pat:
        return c
    -1
  emit(256)
  var w: seq[byte] = @[]
  for ch in data:
    let wk = w & @[byte(ch)]
    if dictFind(wk) >= 0:
      w = wk
    else:
      emit(dictFind(w))
      if nextCode < 4096:
        dict.add((wk, nextCode))
        inc nextCode
        if nextCode == (1 shl codeLen) - (1 - earlyChange):
          if codeLen < 12:
            inc codeLen
      w = @[byte(ch)]
  if w.len > 0:
    emit(dictFind(w))
  emit(257)
  if bitN > 0:
    enc.add(char(((bitBuf shl (8 - bitN))) and 0xFF))
  enc

proc cosName(n: string): CosObj = CosObj(kind: coName, name: n)
proc nullCos(): CosObj = CosObj(kind: coNull)

test "flate round-trip and empty":
  let plain = "hello flate world, ".repeat(20)
  check flateDecode(deflateEncode(plain)) == plain
  check flateDecode("") == ""
  check deflateEncode("") == ""

test "flate raw fallback":
  let plain = "raw deflate bytes ".repeat(10)
  check flateDecode(rawDeflate(plain)) == plain

test "flate truncated raises":
  let enc = deflateEncode("some compressible content here!!!")
  expect(PdfError):
    discard flateDecode(enc[0 ..< enc.len - 3])

test "tiff predictor":
  # stride 2 (Colors 1, Columns 2): raw 10 20 | 30 40
  # encoded row-wise as 10 10 | 30 10
  let params = CosObj(kind: coDict, keys: @["Predictor", "Columns"],
    vals: @[CosObj(kind: coInt, ival: 2),
      CosObj(kind: coInt, ival: 2)])
  let enc = "\x0A\x0A\x1E\x0A"
  check decodeChain(cosName("FlateDecode"), params,
    deflateEncode(enc)) == "\x0A\x14\x1E\x28"

test "png predictors":
  # two rows of 3 bytes, filter Sub(1): stored = raw - left(a)
  # row1 ABC -> A, B-A=1, C-B=1 ; row2 DEF -> D, 1, 1
  let sub = "\x01A\x01\x01" & "\x01D\x01\x01"
  check applyPredictor(sub, 12, 1, 8, 3) == "ABCDEF"
  # Up(2): row2 stored as raw - row1
  let up = "\x00ABC" & "\x02" & char(0) & char(0) & char(0)
  check applyPredictor(up, 12, 1, 8, 3) == "ABCABC"
  # Paeth(4): first row with zero prev behaves like Sub
  let paeth = "\x04A\x01\x01"
  check applyPredictor(paeth, 14, 1, 8, 3) == "ABC"
  # predictor 1 is a passthrough
  check applyPredictor("xyz", 1, 1, 8, 3) == "xyz"
  expect(PdfError):
    discard applyPredictor("xyz", 99, 1, 8, 3)
  expect(PdfError):
    discard applyPredictor("xyz", 12, 1, 4, 3)

test "lzw round-trip both early-change modes":
  let plain = "TOBEORNOTTOBEORTOBEORNOT quench ".repeat(5)
  for ec in [0, 1]:
    check lzwDecode(lzwEncode(plain, ec), ec) == plain
  check lzwDecode("") == ""
  expect(PdfError):
    discard lzwDecode(lzwEncode("abc"), 7)
  expect(PdfError):
    discard lzwDecode("\xFF\xFF")

test "ascii85 vectors":
  check ascii85Decode("9jqo^") == "Man "
  check ascii85Decode("z") == "\x00\x00\x00\x00"
  check ascii85Decode("9jqo^BlbD-BleB1DJ+*+F(f,q") ==
    "Man is distinguished"
  expect(PdfError):
    discard ascii85Decode("abzcd") # z inside a group

test "asciihex vectors":
  check asciiHexDecode("4142>") == "AB"
  check asciiHexDecode("41 42 43") == "ABC" # missing EOD tolerated
  check asciiHexDecode("414>") == "A@"

test "runlength vectors":
  check runLengthDecode("\x02ABC") == "ABC"
  check runLengthDecode("\xFE" & "X") == "XXX"
  check runLengthDecode("\x01AB\x80ZZ") == "AB" # EOD stops
  expect(PdfError):
    discard runLengthDecode("\x02AB") # truncated literal
  expect(PdfError):
    discard runLengthDecode("\xFE") # truncated replicate

test "filter chains and abbreviations":
  let plain = "chained filters! ".repeat(8)
  let flated = deflateEncode(plain)
  var hexed = ""
  for c in flated:
    hexed.add(toHex(ord(c), 2))
  let filt = CosObj(kind: coArray,
    items: @[cosName("AHx"), cosName("Fl")])
  check decodeChain(filt, nullCos(), hexed) == plain
  # single abbreviated filter with matching parms array
  let filt2 = CosObj(kind: coArray, items: @[cosName("A85")])
  let parms2 = CosObj(kind: coArray, items: @[nullCos()])
  check decodeChain(filt2, parms2, "9jqo^") == "Man "
  expect(PdfError):
    discard decodeChain(cosName("NopeDecode"), nullCos(), "x")

test "passthrough image filters":
  check decodeChain(cosName("DCTDecode"), nullCos(), "jpegbytes") ==
    "jpegbytes"
  check decodeChain(cosName("CCF"), nullCos(), "faxbytes") == "faxbytes"

test "end-to-end stream decode through docmodel":
  let plain = "stream through docmodel ".repeat(10)
  let enc = deflateEncode(plain)
  let data = assemblePdf(@["<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [] /Count 0 >>",
    "<< /Filter /FlateDecode /Length " & $enc.len & " >>\nstream\n" &
    enc & "\nendstream"])
  var doc = openDoc(data)
  let s = doc.resolve(CosObj(kind: coRef, refNum: 3, refGen: 0))
  check s.kind == coStream
  check decodeCosStream(s) == plain
