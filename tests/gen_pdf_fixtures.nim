## PDF fixture generator (run manually, not a test).
##
## Writes genuine parseable PDFs under tests/data/pdf/ using the test
## assembler plus the real deflate encoder. Fixtures are checked in so
## tests stay hermetic; rerun after any assembler change:
##   clue run tests/gen_pdf_fixtures.nim   (or build + exec)
##
## Origin: synthetic, generated locally by this script. No licensing
## concerns. Each file: single/System Adler? No: plain classic xref,
## unencrypted, Flate or ASCIIHex content streams.

import std/os
import std/strutils
import std/unicode
import nimcypher/algos/rc4
import nimcypher/algos/sha256
import checksums/md5
import harfbuzz
import libvips/api
import libvips/bindings/vips
import ./pdf_support
import ../src/opendocs/pdf

const OutDir = "tests/data/pdf"

proc toAsciiHex(s: string): string =
  const digits = "0123456789ABCDEF"
  for c in s:
    result.add(digits[ord(c) shr 4])
    result.add(digits[ord(c) and 0x0F])
  result.add('>')

proc streamFlate(payload: string): string =
  streamObj("/Filter /FlateDecode", deflateEncode(payload))

proc streamHex(payload: string): string =
  streamObj("/Filter /ASCIIHexDecode", toAsciiHex(payload))

proc writeBasic() =
  let c1 = "BT /F1 24 Tf 72 720 Td (Hello page one) Tj ET\n" &
    "q 1 0 0 1 10 10 cm BI /W 2 /H 1 /CS /G /BPC 8 ID " &
    "\xAA\xBB EI Q"
  let c2a = "BT /F1 12 Tf 1 0 0 1 50 700 Tm (Second) Tj ET"
  let c2b = "q 2 0 0 2 10 20 cm Q"
  let font = "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
  let objs = @[
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] " &
      "/Resources << /Font << /F1 5 0 R >> >> /Contents 6 0 R >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] " &
      "/Resources << /Font << /F1 5 0 R >> >> " &
      "/Contents [7 0 R 8 0 R] >>",
    font,
    streamFlate(c1),
    streamHex(c2a),
    streamObj("", c2b),
  ]
  writeFile(OutDir / "m3a_basic.pdf", assemblePdf(objs))

proc writeUpdate() =
  ## Base revision says "First"; appended revision redefines contents
  ## to "Second" plus fresh page/pages/catalog objects and a /Prev
  ## trailer. Exercises incremental newest-wins through the page tree.
  let baseObjs = @[
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] " &
      "/Contents 4 0 R >>",
    streamObj("", "BT (First) Tj ET"),
  ]
  var base = assemblePdf(baseObjs)
  let baseXref = base.find("xref\n")
  doAssert baseXref > 0, "base xref not found"
  var rev = ""
  var offsets: seq[int] = @[]
  let bodies = @[
    streamObj("", "BT (Second) Tj ET"), # 5: new contents
    "<< /Type /Page /Parent 7 0 R /MediaBox [0 0 200 200] " &
      "/Contents 5 0 R >>", # 6: new page
    "<< /Type /Pages /Kids [6 0 R] /Count 1 >>", # 7: new pages
    "<< /Type /Catalog /Pages 7 0 R >>", # 8: new catalog
  ]
  for i, body in bodies:
    offsets.add(base.len + rev.len)
    rev.add($(i + 5) & " 0 obj\n")
    rev.add(body)
    rev.add("\nendobj\n")
  let revXref = base.len + rev.len
  rev.add("xref\n0 1\n0000000000 65535 f \n5 4\n")
  for off in offsets:
    var s = $off
    while s.len < 10:
      s = "0" & s
    rev.add(s & " 00000 n \n")
  rev.add("trailer\n<< /Size 9 /Root 8 0 R /Prev " & $baseXref &
    " >>\nstartxref\n" & $revXref & "\n%%EOF\n")
  writeFile(OutDir / "m3a_update.pdf", base & rev)

proc sanity(path: string, pages, minOps: int, password = "") =
  let data = readFile(path)
  let doc = readPdfBytes(data, defaultPdfLimits(), password)
  doAssert doc.pages.len == pages, path & ": page count " &
    $doc.pages.len
  var d = openDoc(data, defaultPdfLimits(), password)
  var total = 0
  for i in 0 ..< pages:
    total += d.walkPageOps(i).len
  doAssert total >= minOps, path & ": only " & $total & " ops"
  echo "ok " & path & " (" & $total & " ops)"

# --- M4 encrypted fixtures (independent derivation for round-trip) ---

proc esc(s: string): string =
  ## Literal-string escaping for arbitrary bytes (O/U/OE/UE/Perms).
  for c in s:
    case c
    of '\\', '(', ')':
      result.add('\\')
      result.add(c)
    else:
      if ord(c) < 32 or ord(c) > 126:
        result.add('\\')
        result.add(char(ord('0') + (ord(c) shr 6)))
        result.add(char(ord('0') + ((ord(c) shr 3) and 7)))
        result.add(char(ord('0') + (ord(c) and 7)))
      else:
        result.add(c)

proc toHex(s: string): string =
  const digits = "0123456789ABCDEF"
  for c in s:
    result.add(digits[ord(c) shr 4])
    result.add(digits[ord(c) and 0x0F])

proc md5raw(s: string): string =
  let d = toMD5(s)
  result = newString(d.len)
  for i in 0 ..< d.len:
    result[i] = char(d[i])

proc sha256raw(s: string): string =
  var bs = newSeq[byte](s.len)
  for i in 0 ..< s.len:
    bs[i] = byte(s[i])
  let d = sha256(bs)
  result = newString(32)
  for i in 0 ..< 32:
    result[i] = char(d[i])

proc rc4s(key, data: string): string =
  var kb = newSeq[byte](key.len)
  for i in 0 ..< key.len:
    kb[i] = byte(key[i])
  var db = newSeq[byte](data.len)
  for i in 0 ..< data.len:
    db[i] = byte(data[i])
  let o = rc4Crypt(kb, db)
  result = newString(o.len)
  for i in 0 ..< o.len:
    result[i] = char(o[i])

proc le32s(v: int): string =
  let u = uint32(v and 0xFFFFFFFF)
  result = newString(4)
  result[0] = char(u and 0xFF)
  result[1] = char((u shr 8) and 0xFF)
  result[2] = char((u shr 16) and 0xFF)
  result[3] = char((u shr 24) and 0xFF)

proc objKey(fileKey: string, objNum, gen, keyLen: int,
    salted: bool): string =
  var m = fileKey
  m.add(char(objNum and 0xFF))
  m.add(char((objNum shr 8) and 0xFF))
  m.add(char((objNum shr 16) and 0xFF))
  m.add(char(gen and 0xFF))
  m.add(char((gen shr 8) and 0xFF))
  if salted:
    m.add("sAlT")
  md5raw(m)[0 ..< min(keyLen + 5, 16)]

proc fileKeyR26(password, o: string, p: int, idFirst: string,
    keyLen, r: int): string =
  let pp = if password.len >= 32: password[0 ..< 32]
    else: password & cryptPad[0 ..< 32 - password.len]
  var h = md5raw(pp & o & le32s(p) & idFirst)
  if r >= 3:
    for _ in 1 .. 50:
      h = md5raw(h[0 ..< keyLen])
  h[0 ..< keyLen]

const
  M4Id = "M4FIXTUREID12345" # 16 bytes
  M4P = -4

proc writeRc4() =
  let userPw = "user123"
  let o = computeO("owner123", userPw, 16, 3)
  let fk = fileKeyR26(userPw, o, M4P, M4Id, 16, 3)
  let u = computeU(fk, M4Id, 16, 3)
  let body = "BT /F1 12 Tf (Secret RC4) Tj ET"
  let encBody = rc4s(objKey(fk, 4, 0, 16, false), body)
  let encTag = rc4s(objKey(fk, 4, 0, 16, false), "hidden")
  let objs = @[
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] " &
      "/Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",
    "<< /MyKey (" & esc(encTag) & ") /Length " & $encBody.len &
      " >>\nstream\n" & encBody & "\nendstream",
    "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    "<< /Filter /Standard /V 2 /R 3 /Length 128 /P " & $M4P &
      " /O (" & esc(o) & ") /U (" & esc(u) & ") >>",
  ]
  let trailer = "/Encrypt 6 0 R /ID [<" & toHex(M4Id) & "> <" &
    toHex(M4Id) & ">]"
  writeFile(OutDir / "m4_rc4.pdf", assemblePdf(objs, @[], trailer))

proc writeAes() =
  let userPw = "user123"
  let o = computeO("owner123", userPw, 16, 4)
  let fk = fileKeyR26(userPw, o, M4P, M4Id, 16, 4)
  let u = computeU(fk, M4Id, 16, 4)
  let iv = "0123456789ABCDEF"
  let body = "BT /F1 12 Tf (Secret AES) Tj ET"
  # Producer order: Flate first, AESV2 over the Flate bytes. resolve
  # strips AESV2, then /FlateDecode applies to the plaintext.
  let flateThenAes = aesCbcEnc(objKey(fk, 4, 0, 16, true), iv,
    deflateEncode(body))
  let encTag = aesCbcEnc(objKey(fk, 4, 0, 16, true), iv, "hidden2")
  let objs = @[
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] " &
      "/Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",
    "<< /Filter /FlateDecode /MyKey (" & esc(encTag) & ") /Length " &
      $flateThenAes.len & " >>\nstream\n" & flateThenAes &
      "\nendstream",
    "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    "<< /Filter /Standard /V 4 /R 4 /Length 128 /P " & $M4P &
      " /O (" & esc(o) & ") /U (" & esc(u) &
      ") /CF 7 0 R /StmF /StdCF /StrF /StdCF >>",
    "<< /StdCF << /CFM /AESV2 >> >>",
  ]
  let trailer = "/Encrypt 6 0 R /ID [<" & toHex(M4Id) & "> <" &
    toHex(M4Id) & ">]"
  writeFile(OutDir / "m4_aes.pdf", assemblePdf(objs, @[], trailer))

proc writeR6() =
  let userPw = "user456"
  let ownerPw = "owner456"
  let fk = "0123456789ABCDEF0123456789ABCDEF" # 32-byte file key
  # Owner validation and key mix in the 48-byte U (Algorithm 2.A/2.B).
  let u = sha256raw(userPw & "USERVALS") & "USERVALS" & "USERKSAL"
  let o = sha256raw(ownerPw & "OWNRVALS" & u) & "OWNRVALS" & "OWNRKSAL"
  let ue = aesEcbEnc(sha256raw(userPw & "USERKSAL"), fk)
  let oe = aesEcbEnc(sha256raw(ownerPw & "OWNRKSAL" & u), fk)
  let perms = aesEcbEnc(fk, le32s(M4P) & "\xFF\xFF\xFF\xFF" & "Tadbperm")
  let iv = "FEDCBA9876543210"
  let encBody = aesCbcEnc(fk, iv, "BT /F1 12 Tf (Secret R6) Tj ET")
  let objs = @[
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] " &
      "/Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",
    "<< /Length " & $encBody.len & " >>\nstream\n" & encBody &
      "\nendstream",
    "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    "<< /Filter /Standard /V 5 /R 6 /Length 256 /P " & $M4P &
      " /O (" & esc(o) & ") /U (" & esc(u) & ") /OE (" & esc(oe) &
      ") /UE (" & esc(ue) & ") /Perms (" & esc(perms) & ") >>",
  ]
  let trailer = "/Encrypt 6 0 R /ID [<" & toHex(M4Id) & "> <" &
    toHex(M4Id) & ">]"
  writeFile(OutDir / "m4_r6.pdf", assemblePdf(objs, @[], trailer))

# --- M3b text fixture: WinAnsi + TJ + subset TrueType with ToUnicode ---
#
# The embedded font is subset from the sibling harfbuzz checkout
# (../harfbuzz/tests/data/DejaVuSans.ttf, Bitstream Vera license);
# that path is only needed when regenerating fixtures, never at test
# time. Tests read the font bytes back out of the PDF itself.

const DejaVuPath = "../harfbuzz/tests/data/DejaVuSans.ttf"

proc subsetDejaVu(unicodes: seq[int]): tuple[bytes: string,
    advances: seq[float64]] =
  if not fileExists(DejaVuPath):
    quit("missing " & DejaVuPath &
      " (sibling harfbuzz checkout required to regenerate fixtures)")
  let src = readFile(DejaVuPath)
  let blob = hb_blob_create(src.cstring, src.len.cuint,
    HB_MEMORY_MODE_READONLY, nil, nil)
  let face = hb_face_create(blob, 0)
  let input = hb_subset_input_create_or_fail()
  let uset = hb_subset_input_unicode_set(input)
  for u in unicodes:
    hb_set_add(uset, hb_codepoint_t(u))
  let sub = hb_subset_or_fail(face, input)
  let sblob = hb_face_reference_blob(sub)
  var n: cuint = 0
  let data = hb_blob_get_data(sblob, addr n)
  result.bytes = newString(n)
  if n > 0:
    copyMem(addr result.bytes[0], data, n)
  var txt = ""
  for u in unicodes:
    txt.add($Rune(u))
  let shaped = shapeText(result.bytes, txt)
  result.advances = newSeq[float64](unicodes.len)
  for g in shaped.glyphs:
    if g.cluster >= 0 and g.cluster < unicodes.len:
      result.advances[g.cluster] = g.xAdvance
  hb_blob_destroy(sblob)
  hb_face_destroy(sub)
  hb_subset_input_destroy(input)
  hb_face_destroy(face)
  hb_blob_destroy(blob)

proc writeText() =
  let sub = subsetDejaVu(@[65, 66, 67])
  var widths = ""
  for i, a in sub.advances:
    if i > 0:
      widths.add(" ")
    widths.add($int(a + 0.5))
  let cmapText = "/CIDInit /ProcSet findresource begin\n" &
    "12 dict begin\nbegincmap\n" &
    "/CIDSystemInfo <</Registry (Adobe) /Ordering (UCS) " &
    "/Supplement 0>> def\n" &
    "/CMapName /Test-ToU def\n/CMapType 2 def\n" &
    "1 begincodespacerange\n<00> <03>\nendcodespacerange\n" &
    "1 beginbfrange\n<01> <03> <0041>\nendbfrange\n" &
    "endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n"
  let c1 = "BT /F1 24 Tf 72 720 Td (Hello \\226 world) Tj ET"
  let c1b = "BT /F1 24 Tf 72 700 Td [(A) 120 (B) -30 (C)] TJ ET " &
    "(Q1) ' ET"
  let c2 = "BT /F2 24 Tf 72 700 Td (\x01\x02\x03) Tj ET"
  let objs = @[
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] " &
      "/Resources << /Font << /F1 5 0 R >> >> " &
      "/Contents [6 0 R 7 0 R] >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] " &
      "/Resources << /Font << /F2 9 0 R >> >> /Contents 8 0 R >>",
    "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica " &
      "/Encoding /WinAnsiEncoding >>",
    streamFlate(c1),
    streamObj("", c1b),
    streamObj("", c2),
    "<< /Type /Font /Subtype /TrueType /BaseFont /DejaVuSans " &
      "/FirstChar 1 /LastChar 3 /Widths [" & widths & "] " &
      "/FontDescriptor 10 0 R /ToUnicode 12 0 R >>",
    "<< /Type /FontDescriptor /FontName /DejaVuSans /Flags 32 " &
      "/FontBBox [-1000 -500 3000 2000] /FontFile2 11 0 R >>",
    "<< /Length1 " & $sub.bytes.len & " /Length " &
      $deflateEncode(sub.bytes).len & " /Filter /FlateDecode >>\n" &
      "stream\n" & deflateEncode(sub.bytes) & "\nendstream",
    streamObj("", cmapText),
  ]
  writeFile(OutDir / "m3b_text.pdf", assemblePdf(objs))

# --- M8 CJK fixtures: Type0 fonts decoded without full ToUnicode.
#
# Page 0: Identity-H with no ToUnicode over Adobe-Japan1, so codes are
# Japan1 CIDs resolved through the vendored ROS tables (日あA).
# Page 1: same setup with /WMode 1 plus DW2/W2, two column fragments.
# Page 2: predefined 90ms-RKSJ-H with no ToUnicode (mixed 1/2-byte
# codes, CID path plus direct UCS2 gap-fill).
# Page 3: Identity-H with a layout-hostile ToUnicode (multi-pair line
# plus an entry split across lines).
# Page 4: CIDFontType2 with Identity ordering, no ToUnicode: the
# embedded minimal sfnt cmap maps GID 1 back to U+0041.

proc writeCjk() =
  let sfnt = "\x00\x01\x00\x00\x00\x01\x00\x10\x00\x00\x00\x00" &
    "cmap\x00\x00\x00\x00\x00\x00\x00\x1C\x00\x00\x00\x2C" &
    "\x00\x00\x00\x01\x00\x03\x00\x01\x00\x00\x00\x0C" &
    "\x00\x04\x00\x20\x00\x00\x00\x04\x00\x04\x00\x01\x00\x00" &
    "\x00\x41\xFF\xFF\x00\x00\x00\x41\xFF\xFF" &
    "\xFF\xC0\x00\x01\x00\x00\x00\x00"
  doAssert sfnt.len == 72, "minimal sfnt length " & $sfnt.len
  let touPack = "3 beginbfchar <0001> <0041> <0002> <0042> <0003>\n" &
    "<0043> endbfchar\n"
  let c0 = "BT /F1 24 Tf 72 700 Td <0CD4034B0022> Tj ET"
  let c1 = "BT /F2 12 Tf 400 700 Td <0CD4> Tj ET\n" &
    "BT /F2 12 Tf 388 700 Td <034B> Tj ET"
  let c2 = "BT /F3 24 Tf 72 700 Td <4193FA> Tj ET"
  let c3 = "BT /F4 24 Tf 72 700 Td <000100020003> Tj ET"
  let c4 = "BT /F5 24 Tf 72 700 Td <0001> Tj ET"
  let objs = @[
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R 6 0 R 7 0 R] /Count 5 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] " &
      "/Resources << /Font << /F1 8 0 R >> >> /Contents 9 0 R >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] " &
      "/Resources << /Font << /F2 10 0 R >> >> /Contents 11 0 R >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] " &
      "/Resources << /Font << /F3 12 0 R >> >> /Contents 13 0 R >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] " &
      "/Resources << /Font << /F4 14 0 R >> >> /Contents 16 0 R >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] " &
      "/Resources << /Font << /F5 17 0 R >> >> /Contents 18 0 R >>",
    "<< /Type /Font /Subtype /Type0 /BaseFont /TestCJK-JP " &
      "/Encoding /Identity-H /DescendantFonts 26 0 R >>",
    streamObj("", c0),
    "<< /Type /Font /Subtype /Type0 /BaseFont /TestCJK-V " &
      "/Encoding /Identity-H /WMode 1 /DescendantFonts [21 0 R] >>",
    streamObj("", c1),
    "<< /Type /Font /Subtype /Type0 /BaseFont /TestCJK-RKSJ " &
      "/Encoding /90ms-RKSJ-H /DescendantFonts [22 0 R] >>",
    streamObj("", c2),
    "<< /Type /Font /Subtype /Type0 /BaseFont /TestCJK-ToU " &
      "/Encoding /Identity-H /DescendantFonts [23 0 R] " &
      "/ToUnicode 15 0 R >>",
    streamObj("", touPack),
    streamObj("", c3),
    "<< /Type /Font /Subtype /Type0 /BaseFont /TestCJK-Sfnt " &
      "/Encoding /Identity-H /DescendantFonts [24 0 R] >>",
    streamObj("", c4),
    streamObj("/Length1 72 /Subtype /TrueType", sfnt),
    "<< /Type /Font /Subtype /CIDFontType2 /BaseFont /TestCJK-JP " &
      "/CIDSystemInfo << /Registry (Adobe) /Ordering (Japan1) " &
      "/Supplement 4 >> /DW 1000 " &
      "/W [34 34 1000 843 843 1000 3284 3284 1000] >>",
    "<< /Type /Font /Subtype /CIDFontType0 /BaseFont /TestCJK-V " &
      "/CIDSystemInfo << /Registry (Adobe) /Ordering (Japan1) " &
      "/Supplement 4 >> /DW 1000 /DW2 [880 -1000] " &
      "/W2 [34 34 -1000 500 880] >>",
    "<< /Type /Font /Subtype /CIDFontType0 /BaseFont /TestCJK-RKSJ " &
      "/CIDSystemInfo << /Registry (Adobe) /Ordering (Japan1) " &
      "/Supplement 4 >> /DW 1000 >>",
    "<< /Type /Font /Subtype /CIDFontType2 /BaseFont /TestCJK-ToU " &
      "/CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) " &
      "/Supplement 0 >> /DW 1000 >>",
    "<< /Type /Font /Subtype /CIDFontType2 /BaseFont /TestCJK-Sfnt " &
      "/CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) " &
      "/Supplement 0 >> /DW 1000 /W [1 1 1000] " &
      "/FontDescriptor 25 0 R >>",
    "<< /Type /FontDescriptor /FontName /TestCJK-Sfnt /Flags 4 " &
      "/FontBBox [0 0 1000 1000] /FontFile2 19 0 R >>",
    "[20 0 R]",
  ]
  writeFile(OutDir / "m8_cjk.pdf", assemblePdf(objs))

proc jpegBytes(w, h: int, rgb: array[3, uint8]): string =
  init_vips:
    var px = newSeq[uint8](w * h * 3)
    for i in 0 ..< w * h:
      px[3 * i] = rgb[0]
      px[3 * i + 1] = rgb[1]
      px[3 * i + 2] = rgb[2]
    let buf = fromMemory(px, w, h, 3, VIPS_FORMAT_UCHAR).saveJPEG(
      quality = 95)
    result = newString(buf.len)
    copyMem(addr result[0], unsafeAddr buf[0], buf.len)

proc writeImages() =
  let rgbSamples = "\xFF\x00\x00\x00\xFF\x00\x00\x00\xFF\xFF\xFF\xFF"
  let graySamples = "\x00\x55\xAA\xFF"
  let maskSamples = "\xFF\xFF\x00\x00"
  let idxSamples = "\x00\x01\x01\x00"
  let jpg = jpegBytes(4, 4, [255'u8, 0, 0])
  let cmykSample = "\x00\xFF\xFF\x00"
  let stencil = "\x80\x40"
  let keyed = "\xFF\x00"
  let objs = @[
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] " &
      "/Resources << /XObject << /Im1 4 0 R /Im2 5 0 R /Im3 7 0 R " &
      "/Im4 8 0 R /Im5 9 0 R /Im6 10 0 R /Im7 11 0 R >> >> " &
      "/Contents 12 0 R >>",
    "<< /Type /XObject /Subtype /Image /Width 2 /Height 2 " &
      "/ColorSpace /DeviceRGB /BitsPerComponent 8 /Length " &
      $deflateEncode(rgbSamples).len & " /Filter /FlateDecode >>\n" &
      "stream\n" & deflateEncode(rgbSamples) & "\nendstream",
    "<< /Type /XObject /Subtype /Image /Width 2 /Height 2 " &
      "/ColorSpace /DeviceGray /BitsPerComponent 8 /SMask 6 0 R " &
      "/Length " & $deflateEncode(graySamples).len &
      " /Filter /FlateDecode >>\nstream\n" &
      deflateEncode(graySamples) & "\nendstream",
    "<< /Type /XObject /Subtype /Image /Width 2 /Height 2 " &
      "/ColorSpace /DeviceGray /BitsPerComponent 8 /Length " &
      $deflateEncode(maskSamples).len & " /Filter /FlateDecode >>\n" &
      "stream\n" & deflateEncode(maskSamples) & "\nendstream",
    "<< /Type /XObject /Subtype /Image /Width 2 /Height 2 " &
      "/ColorSpace [/Indexed /DeviceRGB 1 <FF000000FF00>] " &
      "/BitsPerComponent 8 /Length " &
      $deflateEncode(idxSamples).len & " /Filter /FlateDecode >>\n" &
      "stream\n" & deflateEncode(idxSamples) & "\nendstream",
    "<< /Type /XObject /Subtype /Image /Width 4 /Height 4 " &
      "/ColorSpace /DeviceRGB /BitsPerComponent 8 /Length " &
      $jpg.len & " /Filter /DCTDecode >>\nstream\n" & jpg &
      "\nendstream",
    "<< /Type /XObject /Subtype /Image /Width 1 /Height 1 " &
      "/ColorSpace /DeviceCMYK /BitsPerComponent 8 /Length 4 >>\n" &
      "stream\n" & cmykSample & "\nendstream",
    "<< /Type /XObject /Subtype /Image /Width 2 /Height 2 " &
      "/ImageMask true /BitsPerComponent 1 /Length 2 >>\nstream\n" &
      stencil & "\nendstream",
    "<< /Type /XObject /Subtype /Image /Width 2 /Height 1 " &
      "/ColorSpace /DeviceGray /BitsPerComponent 8 /Mask [200 255] " &
      "/Length 2 >>\nstream\n" & keyed & "\nendstream",
    streamObj("", "/Im1 Do /Im2 Do /Im3 Do /Im4 Do /Im5 Do /Im6 Do /Im7 Do"),
  ]
  writeFile(OutDir / "m5_images.pdf", assemblePdf(objs))

createDir(OutDir)
writeBasic()
writeUpdate()
writeRc4()
writeAes()
writeR6()
writeText()
writeImages()
writeCjk()
sanity(OutDir / "m3a_basic.pdf", 2, 8)
sanity(OutDir / "m3a_update.pdf", 1, 3)
sanity(OutDir / "m4_rc4.pdf", 1, 3, "user123")
sanity(OutDir / "m4_aes.pdf", 1, 3, "user123")
sanity(OutDir / "m4_r6.pdf", 1, 3, "user456")
sanity(OutDir / "m3b_text.pdf", 2, 16)
sanity(OutDir / "m5_images.pdf", 1, 7)
sanity(OutDir / "m8_cjk.pdf", 5, 10)
