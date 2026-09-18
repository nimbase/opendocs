## Cross-reference tables and streams with incremental-update chains.
##
## M1 covers classic `xref` tables; M9 adds compressed xref streams
## (`/Type /XRef` with `/W`, `/Index`, Flate-decoded like any stream)
## plus the `/ObjStm` entries they point at (resolved in docmodel).
## The newest section is the one named by the last `startxref`; each
## trailer (classic dict or stream dict) may carry /Prev pointing at an
## older section, and entries from newer sections win. Classic and
## stream sections may mix along one /Prev chain.

import std/strutils
import std/tables
import ./types
import ./lexer
import ./cos
import ./filters

type
  XRefEntry* = object
    offset*: int
    gen*: int
    live*: bool
    compressed*: bool ## object lives in an object stream (/ObjStm)
    stmNum*: int ## containing /ObjStm object number when compressed
    stmIdx*: int ## index inside the /ObjStm when compressed

  XRef* = object
    entries*: Table[int, XRefEntry]
    root*: CosObj ## /Root reference from the newest trailer
    encrypt*: CosObj ## /Encrypt (coNull when absent)
    idFirst*: string ## first /ID string ("" when absent; never encrypted)
    idSecond*: string ## second /ID string ("" when absent)
    size*: int ## /Size from the newest trailer

proc parseStartxref*(data: PdfSource, limits: PdfLimits): int =
  let tail = data.slice(max(0, data.len - limits.maxScanBytes), data.len)
  let sx = rfind(tail, "startxref")
  if sx < 0:
    pdfFail("PDF trailer not found (no startxref near EOF)")
  var lx = initLexer(tail, sx + "startxref".len)
  let off = lx.readTableInt("startxref offset")
  if off < 0 or off > data.len:
    pdfFail("startxref offset out of range: " & $off)
  off

proc parseClassicSection(data: PdfSource, off: int, limits: PdfLimits,
    entries: var Table[int, XRefEntry]): CosObj =
  ## Parse one classic table at off; merge entries (caller decides
  ## precedence) and return the trailer dictionary.
  var lx = initLexer(data, off)
  lx.expectKeyword("xref", "cross-reference section")
  while true:
    lx.skipWsAndComments()
    if lx.continuesWith("trailer"):
      lx.pos += 7
      let t = lx.parseCosValue()
      if t.kind != coDict:
        pdfFail("bad PDF trailer dictionary at offset " & $lx.pos)
      return t
    if lx.atEnd:
      pdfFail("unterminated xref table at offset " & $off)
    let first = lx.readTableInt("xref subsection first")
    let count = lx.readTableInt("xref subsection count")
    if count < 0 or count > limits.maxObjects:
      pdfFail("implausible xref subsection size " & $count)
    limits.checkCount(first + count, "xref")
    for n in 0 ..< count:
      let eoff = lx.readTableInt("xref entry offset")
      let egen = lx.readTableInt("xref entry generation")
      lx.skipWsAndComments()
      if lx.atEnd:
        pdfFail("truncated xref entry at offset " & $lx.pos)
      let flag = lx.s[lx.pos]
      inc lx.pos
      if flag == 'n':
        if not entries.hasKey(first + n):
          entries[first + n] = XRefEntry(offset: eoff, gen: egen,
            live: true, compressed: false, stmNum: 0, stmIdx: 0)
      elif flag == 'f':
        if not entries.hasKey(first + n):
          entries[first + n] = XRefEntry(offset: eoff, gen: egen,
            live: false, compressed: false, stmNum: 0, stmIdx: 0)
      else:
        pdfFail("bad xref entry flag, expected n or f at offset " &
          $(lx.pos - 1))

proc readField(raw: string, pos, width: int): int =
  ## Big-endian unsigned field; zero-width fields are defined as 0.
  result = 0
  if width < 0 or pos < 0 or pos + width > raw.len:
    pdfFail("xref stream entry out of range at offset " & $pos)
  for i in 0 ..< width:
    result = result * 256 + ord(raw[pos + i])

proc parseXRefStreamSection(data: PdfSource, off: int,
    limits: PdfLimits, entries: var Table[int, XRefEntry]): CosObj =
  ## Parse one `N G obj ...stream... endobj` xref-stream section at
  ## `off`; merge entries (caller decides precedence) and return the
  ## stream dictionary as the trailer dictionary.
  let (_, _, obj) = parseIndirect(data, off)
  if obj.kind != coStream:
    pdfFail("bad xref section at offset " & $off &
      " (not a classic table or xref stream)")
  let typ = obj.dictGet("Type")
  if typ.kind != coName or typ.name != "XRef":
    pdfFail("bad xref section at offset " & $off &
      " (stream is not /Type /XRef)")
  let sizeObj = obj.dictGet("Size")
  if sizeObj.kind != coInt:
    pdfFail("xref stream missing integer /Size")
  let size = sizeObj.ival
  let wObj = obj.dictGet("W")
  if wObj.kind != coArray or wObj.items.len != 3:
    pdfFail("xref stream missing /W array of 3 integers")
  var w = [0, 0, 0]
  for i in 0 .. 2:
    if wObj.items[i].kind != coInt or wObj.items[i].ival < 0 or
        wObj.items[i].ival > 8:
      pdfFail("xref stream /W entry " & $i & " out of range 0..8")
    w[i] = wObj.items[i].ival
  let entryLen = w[0] + w[1] + w[2]
  if entryLen <= 0:
    pdfFail("xref stream /W sums to zero")
  var spans: seq[tuple[first, count: int]] = @[]
  let idxObj = obj.dictGet("Index")
  if idxObj.kind == coNull:
    spans.add((0, size))
  elif idxObj.kind == coArray and idxObj.items.len mod 2 == 0 and
      idxObj.items.len > 0:
    for i in countup(0, idxObj.items.len - 1, 2):
      if idxObj.items[i].kind != coInt or
          idxObj.items[i + 1].kind != coInt or
          idxObj.items[i].ival < 0 or idxObj.items[i + 1].ival < 0:
        pdfFail("xref stream /Index must hold non-negative integers")
      spans.add((idxObj.items[i].ival, idxObj.items[i + 1].ival))
  else:
    pdfFail("xref stream /Index must be pairs of integers")
  let raw = decodeCosStream(obj)
  var pos = 0
  for s in spans:
    limits.checkCount(s.first + s.count, "xref")
    if s.count > 0 and
        raw.len - pos < s.count * entryLen:
      pdfFail("xref stream shorter than its /Index claims")
    for n in 0 ..< s.count:
      let num = s.first + n
      let f0 = readField(raw, pos, w[0])
      let f1 = readField(raw, pos + w[0], w[1])
      let f2 = readField(raw, pos + w[0] + w[1], w[2])
      pos += entryLen
      if entries.hasKey(num):
        continue
      case f0
      of 0:
        entries[num] = XRefEntry(offset: f1, gen: f2, live: false,
          compressed: false, stmNum: 0, stmIdx: 0)
      of 1:
        entries[num] = XRefEntry(offset: f1, gen: f2, live: true,
          compressed: false, stmNum: 0, stmIdx: 0)
      of 2:
        limits.checkCount(f1, "xref")
        entries[num] = XRefEntry(offset: 0, gen: 0, live: true,
          compressed: true, stmNum: f1, stmIdx: f2)
      else:
        pdfFail("bad xref stream entry type " & $f0 & " for object " &
          $num)
  CosObj(kind: coDict, keys: obj.streamDict, vals: obj.streamVals)

proc parseXRef*(src: PdfSource, limits = defaultPdfLimits()): XRef =
  var off = parseStartxref(src, limits)
  var entries = initTable[int, XRefEntry]()
  var newestTrailer: CosObj = CosObj(kind: coNull)
  var first = true
  var sections = 0
  while true:
    if sections > limits.maxObjects:
      pdfFail("too many xref sections (possible /Prev cycle)")
    inc sections
    if off + 4 > src.len:
      pdfFail("xref section offset out of range: " & $off)
    if src.continuesWithAt("xref", off):
      let trailer = parseClassicSection(src, off, limits, entries)
      if first:
        newestTrailer = trailer
        first = false
      let prev = trailer.dictGet("Prev")
      if prev.kind == coNull:
        break
      if prev.kind != coInt:
        pdfFail("/Prev must be an integer offset")
      off = prev.ival
      if off < 0 or off >= src.len:
        pdfFail("/Prev offset out of range: " & $off)
    else:
      var isXRefStream = false
      try:
        let (_, _, obj) = parseIndirect(src, off)
        let typ = obj.dictGet("Type")
        isXRefStream = obj.kind == coStream and typ.kind == coName and
          typ.name == "XRef"
      except PdfError:
        discard
      if isXRefStream:
        let trailer = parseXRefStreamSection(src, off, limits, entries)
        if first:
          newestTrailer = trailer
          first = false
        let prev = trailer.dictGet("Prev")
        if prev.kind == coNull:
          break
        if prev.kind != coInt:
          pdfFail("/Prev must be an integer offset")
        off = prev.ival
        if off < 0 or off >= src.len:
          pdfFail("/Prev offset out of range: " & $off)
      else:
        let probe = src.slice(off, min(src.len, off + 300))
        if find(probe, "XRef") >= 0 or find(probe, "obj") >= 0:
          pdfFail("unreadable xref section at offset " & $off &
            " (not a classic table or well-formed xref stream)")
        pdfFail("bad xref section at offset " & $off)
  if newestTrailer.kind != coDict:
    pdfFail("missing PDF trailer dictionary")
  let root = newestTrailer.dictGet("Root")
  if root.kind != coRef:
    pdfFail("PDF trailer missing /Root reference")
  let size = newestTrailer.dictGet("Size")
  var idFirst = ""
  var idSecond = ""
  let id = newestTrailer.dictGet("ID")
  if id.kind == coArray and id.items.len > 0 and
      id.items[0].kind == coStr:
    idFirst = id.items[0].sval
  if id.kind == coArray and id.items.len > 1 and
      id.items[1].kind == coStr:
    idSecond = id.items[1].sval
  result = XRef(entries: entries, root: root,
    encrypt: newestTrailer.dictGet("Encrypt"), idFirst: idFirst,
    idSecond: idSecond,
    size: if size.kind == coInt: size.ival else: entries.len)

proc parseXRef*(data: string, limits = defaultPdfLimits()): XRef =
  ## String convenience wrapper; the parser itself reads from the
  ## source without copying.
  parseXRef(fromString(data), limits)
