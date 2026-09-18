## M3b tests: CMaps, encodings, positioned extraction, shaping.
##
## Fixture tests/data/pdf/m3b_text.pdf (see tests/gen_pdf_fixtures.nim):
## page 0 WinAnsi Helvetica with Tj, TJ kerning and a quote op;
## page 1 subset DejaVuSans TrueType with ToUnicode, Widths and an
## embedded FontFile2 (font bytes read back out of the PDF, so tests
## stay hermetic).

import std/math
import std/os
import std/strutils
import std/tables
import unittest
import ../src/opendocs/pdf
import ../src/opendocs/pdf/cos
import ../src/opendocs/pdf/docmodel
import ../src/opendocs/pdf/cmap
import ../src/opendocs/pdf/cjkmaps
import ../src/opendocs/pdf/shape
import ../src/opendocs/pdf/gstate
import ../src/opendocs/pdf/doctext
import ../src/opendocs/pdf/sfntcmap
import ./pdf_support

const TextPdf = "tests/data/pdf/m3b_text.pdf"
const CjkPdf = "tests/data/pdf/m8_cjk.pdf"
const JpPdf = "tests/data/pdf/525J-001.pdf"

test "bfchar maps codes":
  let cm = parseToUnicode(
    "2 beginbfchar\n<01> <0041>\n<02> <0048>\nendbfchar\n")
  check cm.entries[1] == "A"
  check cm.entries[2] == "H"
  check cm.maxKeyLen == 1

test "bfrange single destination increments":
  let cm = parseToUnicode(
    "1 beginbfrange\n<0A> <0C> <0060>\nendbfrange\n")
  check cm.entries[10] == "`"
  check cm.entries[11] == "a"
  check cm.entries[12] == "b"

test "bfrange array destination":
  let cm = parseToUnicode(
    "1 beginbfrange\n<20> <22> [<0041> <0042> <0043>]\nendbfrange\n")
  check cm.entries[0x20] == "A"
  check cm.entries[0x22] == "C"

test "surrogate pair decodes":
  let cm = parseToUnicode("1 beginbfchar\n<01> <D83DDE00>\nendbfchar\n")
  check cm.entries[1] == "\xF0\x9F\x98\x80"

test "two-byte codes set key length":
  let cm = parseToUnicode("1 beginbfchar\n<0001> <0041>\nendbfchar\n")
  check cm.maxKeyLen == 2
  check cm.entries[1] == "A"

test "bfchar multi-pair lines":
  let cm = parseToUnicode(
    "3 beginbfchar\n<01> <0041> <02> <0042>\n<03> <0043>\nendbfchar\n")
  check cm.entries[1] == "A"
  check cm.entries[2] == "B"
  check cm.entries[3] == "C"

test "bfchar entry split across lines":
  let cm = parseToUnicode("1 beginbfchar\n<0001>\n<0041>\nendbfchar\n")
  check cm.entries[1] == "A"
  check cm.maxKeyLen == 2

test "bfrange array split across lines":
  let cm = parseToUnicode(
    "1 beginbfrange\n<20> <22>\n[<0041>\n<0042> <0043>]\nendbfrange\n")
  check cm.entries[0x20] == "A"
  check cm.entries[0x21] == "B"
  check cm.entries[0x22] == "C"

test "codespace ranges parse":
  let cm = parseCMap(
    "2 begincodespacerange\n<00> <80>\n<8140> <9FFC>\nendcodespacerange\n")
  check cm.codes.len == 2
  check cm.codes[0] == CodeRange(lo: 0x00, hi: 0x80, len: 1)
  check cm.codes[1] == CodeRange(lo: 0x8140, hi: 0x9FFC, len: 2)

test "cidchar and cidrange map to CIDs":
  let cm = parseCMap(
    "1 begincidchar\n<21> 65\nendcidchar\n" &
    "1 begincidrange\n<3042> <3044> 8278\nendcidrange\n")
  check cm.hasCids
  check cm.cids[0x21] == 65
  check cm.cids[0x3042] == 8278
  check cm.cids[0x3044] == 8280

test "ROS tables map CIDs to Unicode":
  check cidToUnicode("Japan1", 3284) == 0x65E5 # 日
  check cidToUnicode("Japan1", 843) == 0x3042 # ひ
  check cidToUnicode("Japan1", 34) == 0x0041 # A
  check cidToUnicode("GB1", 3248) == 0x65E5
  check cidToUnicode("CNS1", 730) == 0x65E5
  check cidToUnicode("Korea1", 6464) == 0x65E5
  check cidToUnicode("Japan1", 999999) == -1
  check cidToUnicode("NoSuchROS", 65) == -1
  check hasCjkOrdering("Japan1")
  check not hasCjkOrdering("Identity")

test "predefined encodings map codes to CIDs":
  check codeToCid("90ms-RKSJ-H", 0x41) == 264
  check codeToCid("90ms-RKSJ-H", 0x889F) == 1125
  check codeToCid("90ms-RKSJ-H", 0xFFFF) == -1
  check codeToCid("NoSuchCMap", 0x41) == -1
  check hasCjkEncoding("90ms-RKSJ-H")
  check not hasCjkEncoding("Identity-H")

test "encoding UCS2 tables map codes to Unicode":
  check codeToUnicode("90ms-RKSJ-H", 0x41) == 0x41
  check codeToUnicode("90ms-RKSJ-H", 0x93FA) == 0x65E5 # 日
  check codeToUnicode("GBK-EUC-H", 0xD6D0) == 0x4E2D # 中
  check codeToUnicode("B5-H", 0xA440) == 0x4E00 # 一
  check codeToUnicode("KSCms-UHC-H", 0xB0A1) == 0xAC00
  check codeToUnicode("90ms-RKSJ-H", 0xFFFF) == -1
  check codeToUnicode("NoSuchCMap", 0x41) == -1

test "codespaces split variable-length codes":
  check cmapCodespaces("Identity-H") ==
    @[CodeRange(lo: 0, hi: 0xFFFF, len: 2)]
  let rksj = cmapCodespaces("90ms-RKSJ-H")
  check rksj.len == 4
  check CodeRange(lo: 0x00, hi: 0x80, len: 1) in rksj
  check CodeRange(lo: 0x8140, hi: 0x9FFC, len: 2) in rksj
  check cmapCodespaces("90ms-RKSJ-V") == rksj
  check cmapCodespaces("NoSuchCMap").len == 0

test "glyph names":
  check glyphNameToUnicode("Aacute") == 193
  check glyphNameToUnicode("uni00E9") == 233
  check glyphNameToUnicode("u1F600") == 128512
  check glyphNameToUnicode("A") == 65
  check glyphNameToUnicode("fi") == 64257
  check glyphNameToUnicode("NoSuchGlyphXYZ") == -1

test "byte tables":
  check winAnsiTable[0x96] == 8211
  check winAnsiTable[0x81] == -1
  check winAnsiTable[0x41] == 65
  check macRomanTable[0xF0] == 63743
  check macRomanTable[0x80] == 196

test "winansi run with en dash":
  var d = openDoc(readFile(TextPdf))
  let runs = d.extractText(0)
  check runs[0].text == "Hello \xE2\x80\x93 world"
  check abs(runs[0].x - 72.0) < 1e-6
  check abs(runs[0].y - 720.0) < 1e-6
  check abs(runs[0].size - 24.0) < 1e-9
  check runs[0].fontName == "F1"

test "TJ kerning shifts positions":
  var d = openDoc(readFile(TextPdf))
  let runs = d.extractText(0)
  check runs[1].text == "A"
  check runs[2].text == "B"
  check runs[3].text == "C"
  check abs(runs[1].x - 72.0) < 1e-6
  check abs(runs[2].x - 81.12) < 1e-6
  check abs(runs[3].x - 93.84) < 1e-6
  check runs[4].text == "Q1"

test "subset truetype through tounicode":
  var d = openDoc(readFile(TextPdf))
  let runs = d.extractText(1)
  check runs.len == 1
  check runs[0].text == "ABC"
  check abs(runs[0].x - 72.0) < 1e-6
  check abs(runs[0].y - 700.0) < 1e-6
  check runs[0].fontName == "F2"

test "differences encoding":
  let data = assemblePdf(@[
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] " &
      "/Resources << /Font << /F3 5 0 R >> >> /Contents 4 0 R >>",
    streamObj("", "BT /F3 12 Tf 10 10 Td (\\103) Tj ET"),
    "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica " &
      "/Encoding << /Type /Encoding /BaseEncoding /WinAnsiEncoding " &
      "/Differences [67 /Aacute] >> >>",
  ])
  var d = openDoc(data)
  check d.extractText(0)[0].text == "\xC3\x81"

test "unknown difference name becomes replacement":
  let data = assemblePdf(@[
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] " &
      "/Resources << /Font << /F3 5 0 R >> >> /Contents 4 0 R >>",
    streamObj("", "BT /F3 12 Tf 10 10 Td (A) Tj ET"),
    "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica " &
      "/Encoding << /Type /Encoding /BaseEncoding /WinAnsiEncoding " &
      "/Differences [65 /NoSuchGlyphXYZ] >> >>",
  ])
  var d = openDoc(data)
  check d.extractText(0)[0].text == "\xEF\xBF\xBD"

test "text without font fails":
  let data = assemblePdf(@[
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] " &
      "/Contents 4 0 R >>",
    streamObj("", "BT (Hi) Tj ET"),
  ])
  var d = openDoc(data)
  expect(PdfError):
    discard d.extractText(0)

proc fontBytes(d: var PdfDoc, page: int, name: string): string =
  var fonts = d.pageResources(page).dictGet("Font")
  if fonts.kind == coRef:
    fonts = d.resolve(fonts)
  var font = fonts.dictGet(name)
  if font.kind == coRef:
    font = d.resolve(font)
  loadFontBytes(font, d)

test "embedded font loads from fixture":
  var d = openDoc(readFile(TextPdf))
  let bytes = fontBytes(d, 1, "F2")
  check bytes.len > 100
  check bytes[0] == '\x00' and bytes[1] == '\x01'

test "shaping subset text":
  var d = openDoc(readFile(TextPdf))
  let shaped = shapeText(fontBytes(d, 1, "F2"), "ABC")
  check shaped.glyphs.len == 3
  for g in shaped.glyphs:
    check g.glyphId != 0
    check g.xAdvance > 0.0

test "shaping empty text is empty":
  var d = openDoc(readFile(TextPdf))
  check shapeText(fontBytes(d, 1, "F2"), "").glyphs.len == 0

test "base-14 font has no program":
  var d = openDoc(readFile(TextPdf))
  expect(PdfError):
    discard fontBytes(d, 0, "F1")

test "identity CIDs resolve through ROS tables":
  var d = openDoc(readFile(CjkPdf))
  let runs = d.extractText(0)
  check runs.len == 1
  check runs[0].text == "日あA"
  check abs(runs[0].x - 72.0) < 1e-6
  check abs(runs[0].y - 700.0) < 1e-6
  check not runs[0].vert

test "vertical font advances downward with position vector":
  var d = openDoc(readFile(CjkPdf))
  let runs = d.extractText(1)
  check runs.len == 2
  check runs[0].vert and runs[1].vert
  check runs[0].text == "日"
  check runs[1].text == "あ"
  check abs(runs[0].x - 406.0) < 1e-6
  check abs(runs[0].y - 710.56) < 1e-6
  check abs(runs[1].x - 394.0) < 1e-6

test "predefined encoding splits and maps codes":
  var d = openDoc(readFile(CjkPdf))
  let runs = d.extractText(2)
  check runs.len == 1
  check runs[0].text == "A日"

test "packed ToUnicode lines parse through file":
  var d = openDoc(readFile(CjkPdf))
  let runs = d.extractText(3)
  check runs.len == 1
  check runs[0].text == "ABC"

test "embedded sfnt cmap answers GIDs":
  var d = openDoc(readFile(CjkPdf))
  let runs = d.extractText(4)
  check runs.len == 1
  check runs[0].text == "A"

test "real-world Identity-H CIDs decode without ToUnicode":
  if not fileExists(JpPdf):
    echo "skip real-world CJK (no " & JpPdf & ")"
  else:
    var d = openDoc(readFile(JpPdf))
    let runs = d.extractText(0)
    check runs.len > 4
    check runs[0].text & runs[1].text & runs[2].text & runs[3].text ==
      "インテル"
    let doc = d.extractDocumentText("1.5")
    check "OpenMP" in doc.text
    check "インテル" in doc.text

test "sfnt cmap parser reads format 4":
  let sfnt = "\x00\x01\x00\x00\x00\x01\x00\x10\x00\x00\x00\x00" &
    "cmap\x00\x00\x00\x00\x00\x00\x00\x1C\x00\x00\x00\x2C" &
    "\x00\x00\x00\x01\x00\x03\x00\x01\x00\x00\x00\x0C" &
    "\x00\x04\x00\x20\x00\x00\x00\x04\x00\x04\x00\x01\x00\x00" &
    "\x00\x41\xFF\xFF\x00\x00\x00\x41\xFF\xFF" &
    "\xFF\xC0\x00\x01\x00\x00\x00\x00"
  let cm = parseSfntCmap(sfnt)
  check cm[1] == 0x41
  check parseSfntCmap("").len == 0
  check parseSfntCmap("not a font at all...............").len == 0
