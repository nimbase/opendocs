## Plain-text reader/writer tests. Fully hermetic: every fixture is
## an inline byte literal (no checked-in binaries), temp files live
## under `getTempDir()` with cleanup. No tools, no network.

import std/[unittest, os, tempfiles, unicode]
import opendocs/txt

func bs(s: string): seq[byte] =
  ## String bytes as a sequence (literals may hold arbitrary bytes).
  result = newSeq[byte](s.len)
  if s.len > 0:
    copyMem(addr result[0], unsafeAddr s[0], s.len)

let emoji = $Rune(0x1F600) # 😀 (no 8-digit \U escape in literals)

suite "txt decode":
  test "empty input is an empty utf-8 doc":
    let d = decodeBytes(newSeq[byte](0))
    check d.text == ""
    check d.encoding == encUtf8
    check d.lineEnding == leNone
    check not d.hasBom

  test "plain ascii is utf-8":
    let d = decodeBytes(bs("hello\nworld\n"))
    check d.text == "hello\nworld\n"
    check d.encoding == encUtf8
    check d.lineEnding == leLF
    check not d.hasBom

  test "utf-8 BOM is stripped and reported":
    let d = decodeBytes(bs("\xEF\xBB\xBFhi"))
    check d.text == "hi"
    check d.encoding == encUtf8Bom
    check d.hasBom

  test "utf-16le ascii via NUL alternation":
    let d = decodeBytes(bs("h\x00i\x00!\x00"))
    check d.text == "hi!"
    check d.encoding == encUtf16LE
    check not d.hasBom

  test "utf-16be via BOM and via alternation":
    let b = decodeBytes(bs("\xFE\xFF\x00h\x00i"))
    check b.text == "hi"
    check b.encoding == encUtf16BE
    check b.hasBom
    let n = decodeBytes(bs("\x00h\x00i"))
    check n.text == "hi"
    check n.encoding == encUtf16BE

  test "utf-16 round-trips CJK and emoji":
    let src = "A\x00B\x00\x2D\x4E\x3D\xD8\x00\xDE"
    let d = decodeBytes(bs(src))
    check d.text == "AB\u4E2D" & emoji
    check d.encoding == encUtf16LE
    let rt = encodeDoc(d.text,
      TxtWriteOpts(encoding: encUtf16LE, lineEnding: leLF))
    check rt == bs(src)

  test "utf-32 BOMs decode":
    let le = decodeBytes(bs("\xFF\xFE\x00\x00A\x00\x00\x00"))
    check le.text == "A"
    check le.encoding == encUtf32LE
    check le.hasBom
    let be = decodeBytes(bs("\x00\x00\xFE\xFF\x00\x00\x00A"))
    check be.text == "A"
    check be.encoding == encUtf32BE

  test "lone surrogates fail loudly":
    expect TxtError:
      discard decodeBytes(bs("\xFF\xFE\x00\xD8")) # lone high
    expect TxtError:
      discard decodeBytes(bs("\xFF\xFE\x00\xDC")) # lone low
    expect TxtError:
      discard decodeBytes(bs("h\x00i")) # odd-length truncates units

  test "invalid utf-8 falls back per design, fails only after BOM":
    # Bare invalid bytes are single-byte text (locked fallback), not
    # errors: overlongs, surrogate halves, >U+10FFFF and truncated
    # sequences all decode as Latin-1/Windows-1252.
    check decodeBytes(bs("\xC0\xAF")).encoding == encLatin1
    check decodeBytes(bs("\xED\xA0\x80")).encoding == encWindows1252
    check decodeBytes(bs("\xF4\x90\x00\x00")).encoding == encLatin1
    check decodeBytes(bs("abc\xE2\x82")).encoding == encWindows1252
    # A BOM commits to its codec: garbage after it fails loudly.
    expect TxtError:
      discard decodeBytes(bs("\xEF\xBB\xBF\xC0\xAF"))
    expect TxtError:
      discard decodeBytes(bs("\xEF\xBB\xBFabc\xE2\x82"))

  test "latin-1 fallback maps bytes 1:1":
    let d = decodeBytes(bs("caf\xE9"))
    check d.text == "caf\xC3\xA9"
    check d.encoding == encLatin1

  test "windows-1252 auto-detect with the hole guard":
    let euro = decodeBytes(bs("price: \x80"))
    check euro.text == "price: \xE2\x82\xAC"
    check euro.encoding == encWindows1252
    let holey = decodeBytes(bs("a\x81b"))
    check holey.encoding == encLatin1
    check holey.text == "a\xC2\x81b"

  test "pure high bytes report latin-1":
    let d = decodeBytes(bs("\xE9\xE0"))
    check d.encoding == encLatin1

suite "txt line endings":
  test "all five detections":
    check decodeText("a\nb").lineEnding == leLF
    check decodeText("a\r\nb").lineEnding == leCRLF
    check decodeText("a\rb").lineEnding == leCR
    check decodeText("a\nb\r\nc\rd").lineEnding == leMixed
    check decodeText("abc").lineEnding == leNone

  test "normalization folds CRLF and lone CR":
    check decodeText("a\r\nb\rc\nd").text == "a\nb\nc\nd"

  test "crlf file round-trips faithfully":
    let d = decodeText("one\r\ntwo\r\n")
    check d.lineEnding == leCRLF
    check d.text == "one\ntwo\n"
    let rt = decodeBytes(encodeDoc(d))
    check rt.lineEnding == leCRLF
    check rt.text == "one\ntwo\n"

  test "write converts line endings on demand":
    let crlf = encodeDoc("a\nb",
      TxtWriteOpts(lineEnding: leCRLF, encoding: encUtf8))
    check crlf == bs("a\r\nb")
    let cr = encodeDoc("a\nb",
      TxtWriteOpts(lineEnding: leCR, encoding: encUtf8))
    check cr == bs("a\rb")

suite "txt encode":
  test "write-read round-trip per encoding":
    let text = "hi \xC3\xA9 \xE2\x82\xAC " & emoji
    for enc in [encUtf8, encUtf8Bom, encUtf16LE, encUtf16BE,
        encUtf32LE, encUtf32BE]:
      let data = encodeDoc(text, TxtWriteOpts(encoding: enc,
        bom: enc != encUtf8, lineEnding: leLF))
      let back = decodeBytes(data)
      check back.text == text
      if enc == encUtf8:
        check back.encoding == encUtf8
      elif enc == encUtf8Bom:
        check back.hasBom

  test "single-byte round-trips":
    check decodeBytes(encodeDoc("caf\xC3\xA9",
      TxtWriteOpts(encoding: encLatin1))) ==
      TxtDoc(text: "caf\xC3\xA9", encoding: encLatin1,
        lineEnding: leNone, hasBom: false)
    let w = decodeBytes(encodeDoc("100 \xE2\x82\xAC",
      TxtWriteOpts(encoding: encWindows1252)))
    check w.text == "100 \xE2\x82\xAC"
    check w.encoding == encWindows1252

  test "unrepresentable codepoints fail loudly":
    expect TxtError:
      discard encodeDoc("\xE2\x82\xAC",
        TxtWriteOpts(encoding: encLatin1)) # euro not latin-1
    expect TxtError:
      discard encodeDoc("\xF0\x9F\x98\x80",
        TxtWriteOpts(encoding: encWindows1252)) # emoji not 1252
    expect TxtError:
      discard encodeDoc("\xFF", TxtWriteOpts()) # invalid utf-8 input

suite "txt files and mapping":
  test "buffered and mapped reads agree":
    let path = getTempDir() / "nimbase-txt-agree.txt"
    try:
      writeTextFile(path, "l1\nl2\n", TxtWriteOpts(
        lineEnding: leCRLF, encoding: encUtf8))
      let a = readTextFile(path)
      let b = readTextMapped(path)
      check a == b
      check a.lineEnding == leCRLF
      check a.text == "l1\nl2\n"
    finally:
      try: removeFile(path)
      except OSError: discard

  test "mapped write is a single copy and reads back":
    let path = getTempDir() / "nimbase-txt-mapped.txt"
    try:
      writeTextMapped(path, "a\nb\nc\n")
      let back = readTextFile(path)
      check back.text == "a\nb\nc\n"
      # Encoded form is byte-exact (no BOM, LF as written).
      let raw = readFile(path)
      check raw == "a\nb\nc\n"
    finally:
      try: removeFile(path)
      except OSError: discard

  test "eachLine streams splitlines without materializing":
    let path = getTempDir() / "nimbase-txt-lines.txt"
    try:
      var f: File
      doAssert open(f, path, fmWrite)
      for i in 1 .. 20_000:
        f.writeLine("row " & $i)
      close(f)
      var n = 0
      var first = ""
      var last = ""
      for line in eachLine(path):
        if n == 0: first = line
        last = line
        inc n
      check n == 20_000
      check first == "row 1"
      check last == "row 20000"
      check readTextLines(path).len == 20_000
    finally:
      try: removeFile(path)
      except OSError: discard

  test "eachLine handles CRLF and lone CR":
    let path = getTempDir() / "nimbase-txt-breaks.txt"
    try:
      let f = open(path, fmWrite)
      doAssert f != nil
      var fh: File
      doAssert open(fh, path, fmWrite)
      fh.write("a\r\nb\rc\n")
      close(fh)
      var got: seq[string] = @[]
      for line in eachLine(path): got.add line
      check got == @["a", "b", "c"]
    finally:
      try: removeFile(path)
      except OSError: discard

  test "missing files fail loudly":
    expect TxtError:
      discard readTextFile(getTempDir() / "nimbase-no-such.txt")
    expect TxtError:
      discard readTextMapped(getTempDir() / "nimbase-no-such.txt")
    expect TxtError:
      writeTextFile(getTempDir(), "x") # a directory, not a file

suite "txt utilities":
  test "counts":
    let d = decodeText("a b\nc\n")
    check d.lineCount() == 2
    check d.charCount() == 6
    check d.wordCount() == 3
    check d.byteCount() == 6
    check decodeText("").lineCount() == 0
    check decodeText("no-break").lineCount() == 1

  test "trimmers":
    check trimTrailingSpace("a  \n b\t\nc") == "a\n b\nc"
    check ensureTrailingNewline("a") == "a\n"
    check ensureTrailingNewline("a\n") == "a\n"
    check ensureTrailingNewline("a", leCRLF) == "a\r\n"

  test "explicit single-byte decoders":
    check decodeLatin1(bs("\xE9")) == "\xC3\xA9"
    check decodeWindows1252(bs("\x80")) == "\xE2\x82\xAC"
    expect TxtError:
      discard decodeWindows1252(bs("\x81"))

  test "utf-16 unit helpers":
    check countUtf16Units("A\u4E2D" & emoji) == 1 + 1 + 2
    check truncateUtf16Units("A\u4E2D" & emoji, 2) == "A\u4E2D"
    check truncateUtf16Units("A\u4E2D" & emoji, 3) == "A\u4E2D"
    expect TxtError:
      discard countUtf16Units("\xFF")

  test "bom and validation helpers":
    let (enc, size) = detectBom(bs("\xEF\xBB\xBFx"))
    check enc == encUtf8Bom
    check size == 3
    check detectBom(bs("ab")).size == 0
    check isValidUtf8(bs("ok"))
    check not isValidUtf8(bs("\xFF"))
