## Writer-side font pipeline: measure, subset, embed, draw, wrap.
##
## The font program is the full DejaVuSans from the sibling harfbuzz
## checkout when present; otherwise our own m3b_text.pdf fixture
## (embedded subset holding only A, B, C) covers the same paths with
## ABC-only text.
##
## CID micro-fonts under tests/data/fonts (self-contained, no system
## fonts): cjk-cff-micro.otf is 6 glyphs (A, X, あ, 日, 本, 語)
## subset from NotoSansJP-Regular.otf (OFL 1.1,
## https://github.com/googlefonts/noto-cjk/raw/main/Sans/SubsetOTF/JP/NotoSansJP-Regular.otf,
## CFF outlines) via
## `hb-subset NotoSansJP-Regular.otf
## --unicodes=U+0041,U+0058,U+3042,U+65E5,U+672C,U+8A9E`;
## emoji-cbdt-micro.ttf is 2 glyphs (U+1F600, U+1F389) subset from
## NotoColorEmoji.ttf (OFL 1.1,
## https://github.com/googlefonts/noto-emoji/raw/main/fonts/NotoColorEmoji.ttf,
## CBDT bitmaps) via `hb-subset NotoColorEmoji.ttf
## --unicodes=U+1F600,U+1F389`. Both with hb-subset 14.2.1 defaults.
import std/os
import std/strutils
import std/tables
import std/unicode
import unittest
import ../src/opendocs/pdf
import ../src/opendocs/pdf/cos
import ../src/opendocs/pdf/docmodel
import ../src/opendocs/pdf/shape
import ../src/opendocs/pdf/write
import ../src/opendocs/pdf/fontembed
import ../src/opendocs/pdf/gstate

const
  TextPdf = "tests/data/pdf/m3b_text.pdf"
  DejaVuPath = "../harfbuzz/tests/data/DejaVuSans.ttf"

proc subsetProgram(): string =
  var d = openDoc(readFile(TextPdf))
  var fonts = d.pageResources(1).dictGet("Font")
  if fonts.kind == coRef:
    fonts = d.resolve(fonts)
  var font = fonts.dictGet("F2")
  if font.kind == coRef:
    font = d.resolve(font)
  loadFontBytes(font, d)

proc fontProgram(): string =
  if fileExists(DejaVuPath):
    readFile(DejaVuPath)
  else:
    subsetProgram()

proc demoText(): string =
  if fileExists(DejaVuPath): "Hello writer" else: "ABC BAC"

proc runesOf(s: string): seq[uint32] =
  for r in s.runes:
    result.add(uint32(r))

test "measureText sanity":
  var sf = openShapedFont(fontProgram())
  defer: close(sf)
  let t = demoText()
  check measureText(sf, "", 12.0) == 0.0
  check measureText(sf, " ", 12.0) > 0.0
  check measureText(sf, t, 12.0) > measureText(sf, $t[0], 12.0)
  check measureText(sf, t, 24.0) == 2.0 * measureText(sf, t, 12.0)
  if fileExists(DejaVuPath):
    check measureText(sf, "ii", 12.0) < measureText(sf, "mm", 12.0)

test "winAnsiByte mapping":
  check winAnsiByte(Rune(0x41)) == 65
  check winAnsiByte(Rune(0xE9)) == 0xE9
  check winAnsiByte(Rune(0x20AC)) == 0x80
  check winAnsiByte(Rune(0x4E2D)) == -1

test "noteUse records codes":
  var u = FontUse(fontBytes: fontProgram(), baseName: "DejaVuSans")
  u.noteUse(demoText())
  check u.codes.len > 0
  expect(PdfError):
    u.noteUse("日本語")

test "wrapText breaks on shaped width":
  var sf = openShapedFont(fontProgram())
  defer: close(sf)
  let t3 = if fileExists(DejaVuPath): "Hello brave writer"
    else: "ABC BAC CAB"
  let words = strutils.split(t3, ' ')
  let w = measureText(sf, words[0] & " " & words[1], 12.0)
  check wrapText(sf, t3, 12.0, w) ==
    @[words[0] & " " & words[1], words[2]]
  check wrapText(sf, "A\nB", 12.0, w * 4.0) == @["A", "B"]
  check wrapText(sf, words[0] & "x-long-word " & words[1], 12.0, w) ==
    @[words[0] & "x-long-word", words[1]]

test "subset keeps used glyphs":
  let prog = subsetProgram()
  let sub = subsetFont(prog, runesOf("AB"))
  check sub.len > 0
  check sub.len <= prog.len
  var sf = openShapedFont(sub)
  defer: close(sf)
  check sf.nominalGlyph(uint32('A')) != 0

test "full DejaVu subset is tiny":
  if fileExists(DejaVuPath):
    let full = readFile(DejaVuPath)
    check full.len > 500_000
    let sub = subsetFont(full, runesOf("Hello writer"))
    check sub.len > 0
    check sub.len < 50_000
    var sf = openShapedFont(sub)
    defer: close(sf)
    check sf.nominalGlyph(uint32('H')) != 0
  else:
    echo "no sibling harfbuzz checkout; full-font subset skipped"

proc embeddedDemo(): string =
  let t = demoText()
  var use = FontUse(fontBytes: fontProgram(), baseName: "DejaVuSans")
  use.noteUse(t)
  let content = drawTextLine(72.0, 720.0, "F2", 24.0, t)
  var b = newPdfBuilder()
  let fonts = b.finalizeFonts({"F2": use}.toTable)
  let cnum = b.addContentStream(content)
  discard b.addPage(612.0, 792.0, cnum, fontResources(fonts))
  b.buildPdf()

test "embedded font round-trips text":
  var d = openDoc(embeddedDemo())
  check d.pageCount() == 1
  var texts: seq[string] = @[]
  for r in d.extractText(0):
    texts.add(r.text)
  check texts == @[demoText()]

test "embedded font has full Widths range":
  let t = demoText()
  var first = 256
  var last = -1
  for r in t.runes:
    let b = winAnsiByte(r)
    first = min(first, b)
    last = max(last, b)
  var d = openDoc(embeddedDemo())
  var fonts = d.pageResources(0).dictGet("Font")
  if fonts.kind == coRef:
    fonts = d.resolve(fonts)
  var font = fonts.dictGet("F2")
  if font.kind == coRef:
    font = d.resolve(font)
  let widths = font.dictGet("Widths")
  check widths.kind == coArray
  check font.dictGet("FirstChar").ival == first
  check font.dictGet("LastChar").ival == last
  check widths.items.len == last - first + 1

test "finalizeFonts is deterministic":
  check embeddedDemo() == embeddedDemo()

test "embedFont rejects empty codes":
  var b = newPdfBuilder()
  expect(PdfError):
    discard b.embedFont("DejaVuSans", fontProgram(),
      initTable[int, uint32]())

test "subsetFont rejects empty program":
  expect(PdfError):
    discard subsetFont("", runesOf("Hi"))

# ---------------------------------------------------------------------------
# CID-keyed Type0 path (CidFontUse): full Unicode, shaped emission
# ---------------------------------------------------------------------------

const
  CjkMicro = "tests/data/fonts/cjk-cff-micro.otf"
  EmojiMicro = "tests/data/fonts/emoji-cbdt-micro.ttf"

proc cidDemoBytes(prog, name, text: string): tuple[pdf, content: string] =
  var sf = openShapedFont(prog)
  defer: close(sf)
  var use = CidFontUse(fontBytes: prog, baseName: name)
  let content = drawCidLine(use, sf, 72.0, 720.0, "F9", 24.0, text)
  var b = newPdfBuilder()
  let fonts = b.finalizeFonts({"F9": use}.toTable)
  let cnum = b.addContentStream(content)
  discard b.addPage(612.0, 792.0, cnum, fontResources(fonts))
  (b.buildPdf(), content)

proc cidTexts(pdf: string): seq[string] =
  ## Extraction yields one run per TJ segment (kern splits), so the
  ## line text is the concatenation of its runs.
  var d = openDoc(pdf)
  var line = ""
  for r in d.extractText(0):
    line.add(r.text)
  @[line]

test "cid mixed scripts round-trip":
  if not fileExists(DejaVuPath):
    echo "no sibling harfbuzz checkout; cid scripts skipped"
  else:
    let t = "αβγ Жж →☺"
    check cidTexts(cidDemoBytes(readFile(DejaVuPath), "DejaVuSans",
      t).pdf) == @[t]

test "cid ligature maps to two runes":
  if not fileExists(DejaVuPath):
    echo "no sibling harfbuzz checkout; cid ligature skipped"
  else:
    check cidTexts(cidDemoBytes(readFile(DejaVuPath), "DejaVuSans",
      "fi").pdf) == @["fi"]

test "cid astral emoji round-trips":
  if not fileExists(DejaVuPath):
    echo "no sibling harfbuzz checkout; cid astral skipped"
  else:
    let t = "😀"
    check cidTexts(cidDemoBytes(readFile(DejaVuPath), "DejaVuSans",
      t).pdf) == @[t]

test "cid kern emits TJ and still round-trips":
  if not fileExists(DejaVuPath):
    echo "no sibling harfbuzz checkout; cid kern skipped"
  else:
    let (pdf, content) = cidDemoBytes(readFile(DejaVuPath),
      "DejaVuSans", "AV")
    check " TJ" in content # A kerns -131 under V in DejaVu
    check cidTexts(pdf) == @["AV"]

test "cid cjk micro font round-trips":
  let t = "日本語あAX"
  check cidTexts(cidDemoBytes(readFile(CjkMicro), "NotoSansJP",
    t).pdf) == @[t]

test "cid cbdt emoji round-trips":
  let t = "😀🎉"
  check cidTexts(cidDemoBytes(readFile(EmojiMicro), "NotoEmoji",
    t).pdf) == @[t]

test "cid structures pin correctly":
  let (pdf, _) = cidDemoBytes(readFile(CjkMicro), "NotoSansJP",
    "日本語")
  var d = openDoc(pdf)
  var fonts = d.pageResources(0).dictGet("Font")
  if fonts.kind == coRef:
    fonts = d.resolve(fonts)
  var font = fonts.dictGet("F9")
  if font.kind == coRef:
    font = d.resolve(font)
  check font.dictGet("Subtype").name == "Type0"
  check font.dictGet("Encoding").name == "Identity-H"
  var cid = font.dictGet("DescendantFonts").items[0]
  if cid.kind == coRef:
    cid = d.resolve(cid)
  check cid.dictGet("Subtype").name == "CIDFontType0" # CFF outlines
  check cid.dictGet("DW").kind == coInt
  let w = cid.dictGet("W")
  check w.kind == coArray
  check w.items.len mod 2 == 0
  var map = cid.dictGet("CIDToGIDMap")
  if map.kind == coRef:
    map = d.resolve(map)
  check map.kind == coStream
  check font.dictGet("ToUnicode").kind == coRef

test "cid ttf descendant is CIDFontType2":
  if not fileExists(DejaVuPath):
    echo "no sibling harfbuzz checkout; cid type2 skipped"
  else:
    let (pdf, _) = cidDemoBytes(readFile(DejaVuPath), "DejaVuSans",
      "αβ")
    var d = openDoc(pdf)
    var fonts = d.pageResources(0).dictGet("Font")
    if fonts.kind == coRef:
      fonts = d.resolve(fonts)
    var font = fonts.dictGet("F9")
    if font.kind == coRef:
      font = d.resolve(font)
    var cid = font.dictGet("DescendantFonts").items[0]
    if cid.kind == coRef:
      cid = d.resolve(cid)
    check cid.dictGet("Subtype").name == "CIDFontType2"

test "cid missing glyph fails loudly":
  if not fileExists(DejaVuPath):
    echo "no sibling harfbuzz checkout; cid missing skipped"
  else:
    var sf = openShapedFont(readFile(DejaVuPath))
    defer: close(sf)
    var use = CidFontUse(fontBytes: readFile(DejaVuPath),
      baseName: "DejaVuSans")
    expect(PdfError):
      discard drawCidLine(use, sf, 72.0, 720.0, "F9", 24.0, "日本")

test "cid subset stays tiny":
  if not fileExists(DejaVuPath):
    echo "no sibling harfbuzz checkout; cid tiny skipped"
  else:
    let full = readFile(DejaVuPath)
    check full.len > 500_000
    let sub = subsetFont(full, runesOf("αβγ Ж"))
    check sub.len > 0
    check sub.len < 50_000

test "cid finalize is deterministic":
  let a = cidDemoBytes(readFile(CjkMicro), "NotoSansJP", "日本語")
  let b = cidDemoBytes(readFile(CjkMicro), "NotoSansJP", "日本語")
  check a.pdf == b.pdf

test "embedCidFont rejects empty use":
  var b = newPdfBuilder()
  expect(PdfError):
    discard b.embedCidFont("NotoSansJP", readFile(CjkMicro),
      initTable[uint32, int](), initTable[int, string]())
