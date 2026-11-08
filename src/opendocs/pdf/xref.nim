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
    recovered*: bool ## true when lenient/brute-force recovery was used
    notes*: seq[string] ## what recovery skipped or rebuilt

proc finishXRef(entries: Table[int, XRefEntry],
    trailer: CosObj): XRef =
  ## Newest-trailer fields into an XRef (recovered=false, no notes;
  ## recovery paths set those after calling this).
  if trailer.kind != coDict:
    pdfFail("missing PDF trailer dictionary")
  let root = trailer.dictGet("Root")
  if root.kind != coRef:
    pdfFail("PDF trailer missing /Root reference")
  let size = trailer.dictGet("Size")
  var idFirst = ""
  var idSecond = ""
  let id = trailer.dictGet("ID")
  if id.kind == coArray and id.items.len > 0 and
      id.items[0].kind == coStr:
    idFirst = id.items[0].sval
  if id.kind == coArray and id.items.len > 1 and
      id.items[1].kind == coStr:
    idSecond = id.items[1].sval
  XRef(entries: entries, root: root,
    encrypt: trailer.dictGet("Encrypt"), idFirst: idFirst,
    idSecond: idSecond,
    size: if size.kind == coInt: size.ival else: entries.len)

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
  let raw = decodeCosStream(obj, limits)
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

proc parseXRefStrict*(src: PdfSource, limits = defaultPdfLimits()): XRef =
  ## Strict /Prev chain (current behaviour): any malformed section or
  ## entry fails. A revisited section offset is a cycle, failed
  ## immediately instead of looping to the section cap.
  var off = parseStartxref(src, limits)
  var entries = initTable[int, XRefEntry]()
  var newestTrailer: CosObj = CosObj(kind: coNull)
  var first = true
  var sections = 0
  var visited = initTable[int, bool]()
  while true:
    if sections > limits.maxObjects:
      pdfFail("too many xref sections (possible /Prev cycle)")
    inc sections
    if visited.hasKey(off):
      pdfFail("xref /Prev cycle at offset " & $off)
    visited[off] = true
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
  result = finishXRef(entries, newestTrailer)

# ---------------------------------------------------------------------------
# Recovery (M13): lenient chain + brute-force sweep.
##
## Strict parsing stays the default. When it fails, the chain is retried
## leniently (bad entries skipped line-wise, broken older sections stop
## the chain with a note instead of killing the file), then by sweeping
## the whole file for `N G obj` headers with the last file-order
## definition winning. Either fallback sets recovered/notes. Total
## failure re-raises the strict error so messages stay precise.
# ---------------------------------------------------------------------------

proc findKeywordFrom(data: PdfSource, kw: string, start: int): int =
  ## First offset >= start where kw begins, or -1.
  var i = max(start, 0)
  while i + kw.len <= data.len:
    if data.continuesWithAt(kw, i):
      return i
    inc i
  -1

proc rfindKeyword(data: PdfSource, kw: string, fromPos: int): int =
  ## Last offset <= fromPos where kw begins, or -1.
  var i = min(fromPos, data.len - kw.len)
  while i >= 0:
    if data.continuesWithAt(kw, i):
      return i
    dec i
  -1

proc startxrefCandidates(data: PdfSource,
    limits: PdfLimits): seq[int] =
  ## Newest-last startxref value offsets: the last few occurrences
  ## file-wide (covers trailing junk past the tail scan window).
  var seen = initTable[int, bool]()
  var at = data.len - 1
  while result.len < 4 and at >= 0:
    let p = rfindKeyword(data, "startxref", at)
    if p < 0: break
    try:
      var lx = initLexer(data, p + "startxref".len)
      let off = lx.readTableInt("startxref offset")
      if off >= 0 and off <= data.len and not seen.hasKey(off):
        seen[off] = true
        result.add(off)
    except PdfError:
      discard
    at = p - 1

proc parseClassicSectionLenient(data: PdfSource, off: int,
    limits: PdfLimits, entries: var Table[int, XRefEntry],
    notes: var seq[string]): CosObj =
  ## Merge one classic table, skipping unparseable entries line-wise.
  ## A mangled subsection header resyncs at the trailer so /Prev and
  ## /Root survive a damaged middle. Returns coNull (with a note) when
  ## the trailer itself is unreadable.
  var lx = initLexer(data, off)
  try:
    lx.expectKeyword("xref", "cross-reference section")
  except PdfError:
    pdfFail("unreadable xref section at offset " & $off)
  while true:
    lx.skipWsAndComments()
    if lx.continuesWith("trailer"):
      lx.pos += 7
      try:
        let t = lx.parseCosValue()
        if t.kind != coDict:
          notes.add("xref section at " & $off &
            " has a non-dictionary trailer (ignored)")
          return CosObj(kind: coNull)
        return t
      except PdfError:
        notes.add("xref section at " & $off &
          " has an unreadable trailer (ignored)")
        return CosObj(kind: coNull)
    if lx.atEnd:
      notes.add("unterminated xref table at offset " & $off &
        " (stopped section)")
      return CosObj(kind: coNull)
    var first, count: int
    try:
      first = lx.readTableInt("xref subsection first")
      count = lx.readTableInt("xref subsection count")
    except PdfError:
      # Resync at the trailer so the chain keeps /Prev and /Root.
      let tp = findKeywordFrom(data, "trailer", lx.pos)
      if tp < 0 or tp - off > limits.maxObjects * 24 + 1024 * 1024:
        notes.add("xref section at " & $off &
          " has an unreadable subsection header (stopped section)")
        return CosObj(kind: coNull)
      notes.add("xref section at " & $off &
        " skipped a mangled subsection header")
      lx.pos = tp + 7
      try:
        let t = lx.parseCosValue()
        if t.kind != coDict:
          return CosObj(kind: coNull)
        return t
      except PdfError:
        return CosObj(kind: coNull)
    if count < 0 or count > limits.maxObjects:
      notes.add("implausible xref subsection size " & $count &
        " at offset " & $off & " (stopped section)")
      return CosObj(kind: coNull)
    limits.checkCount(first + count, "xref")
    for n in 0 ..< count:
      let save = lx.pos
      try:
        let eoff = lx.readTableInt("xref entry offset")
        let egen = lx.readTableInt("xref entry generation")
        lx.skipWsAndComments()
        if lx.atEnd:
          raise newException(PdfError, "truncated xref entry")
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
          raise newException(PdfError,
            "bad xref entry flag, expected n or f")
      except PdfError:
        var q = save
        while q < data.len and data[q] != '\x0A': inc q
        lx.pos = min(q + 1, data.len)
        if notes.len < 32:
          notes.add("skipped bad xref entry for object " & $(first + n))

proc parseXRefLenient(src: PdfSource, limits: PdfLimits,
    notes: var seq[string]): XRef =
  ## Newest section must parse (lenient classic or strict stream);
  ## older /Prev sections are best-effort: any failure stops the chain
  ## with a note, keeping newer entries.
  let offs = startxrefCandidates(src, limits)
  if offs.len == 0:
    pdfFail("PDF trailer not found (no startxref in file)")
  var entries = initTable[int, XRefEntry]()
  var newestTrailer = CosObj(kind: coNull)
  var first = true
  var off = -1
  for cand in offs:
    if src.continuesWithAt("xref", cand):
      try:
        newestTrailer = parseClassicSectionLenient(src, cand, limits,
          entries, notes)
        first = false
        off = cand
        break
      except PdfError as e:
        notes.add("skipped unreadable newest xref section at " & $cand &
          " (" & e.msg & ")")
        continue
    else:
      var probed = false
      try:
        let (_, _, obj) = parseIndirect(src, cand)
        let typ = obj.dictGet("Type")
        probed = obj.kind == coStream and typ.kind == coName and
          typ.name == "XRef"
        if probed:
          newestTrailer = parseXRefStreamSection(src, cand, limits,
            entries)
          first = false
          off = cand
          break
      except PdfError:
        probed = false
      if not probed:
        notes.add("startxref at " & $cand & " is not an xref section")
        continue
  if first:
    pdfFail("no readable xref section")
  var curTrailer = newestTrailer
  var visited = initTable[int, bool]()
  visited[off] = true
  var sections = 1
  while true:
    if sections > limits.maxObjects:
      notes.add("stopped xref chain: too many sections")
      break
    var prev = CosObj(kind: coNull)
    if curTrailer.kind == coDict:
      prev = curTrailer.dictGet("Prev")
    if prev.kind == coNull:
      break
    if prev.kind != coInt or prev.ival < 0 or prev.ival >= src.len or
        visited.hasKey(prev.ival):
      notes.add("stopped xref chain at bad /Prev")
      break
    off = prev.ival
    visited[off] = true
    inc sections
    if src.continuesWithAt("xref", off):
      try:
        curTrailer = parseClassicSectionLenient(src, off, limits,
          entries, notes)
      except PdfError as e:
        notes.add("stopped xref chain: unreadable section at " & $off &
          " (" & e.msg & ")")
        break
    else:
      var ok = false
      try:
        let (_, _, obj) = parseIndirect(src, off)
        let typ = obj.dictGet("Type")
        if obj.kind == coStream and typ.kind == coName and
            typ.name == "XRef":
          curTrailer = parseXRefStreamSection(src, off, limits, entries)
          ok = true
      except PdfError:
        ok = false
      if not ok:
        notes.add("stopped xref chain: unreadable section at " & $off)
        break
  finishXRef(entries, newestTrailer)

proc tryObjHeader(data: PdfSource, at: int):
    tuple[ok: bool, num, gen, after: int] =
  ## `N G obj` + delimiter at `at`. Digit runs cap at 10 chars so noise
  ## cannot overflow the accumulators.
  var i = at
  var num = 0
  var nd = 0
  while i < data.len and data[i] in {'0'..'9'}:
    if nd >= 10: return (false, 0, 0, at + 1)
    num = num * 10 + (ord(data[i]) - ord('0'))
    inc i
    inc nd
  if nd == 0: return (false, 0, 0, at + 1)
  var sp = i
  while sp < data.len and data[sp] in {'\x00', '\x09', '\x0A', '\x0C',
      '\x0D', '\x20'}:
    inc sp
  if sp == i: return (false, 0, 0, at + 1)
  i = sp
  var gen = 0
  var gd = 0
  while i < data.len and data[i] in {'0'..'9'}:
    if gd >= 10: return (false, 0, 0, at + 1)
    gen = gen * 10 + (ord(data[i]) - ord('0'))
    inc i
    inc gd
  if gd == 0: return (false, 0, 0, at + 1)
  sp = i
  while sp < data.len and data[sp] in {'\x00', '\x09', '\x0A', '\x0C',
      '\x0D', '\x20'}:
    inc sp
  if sp == i: return (false, 0, 0, at + 1)
  i = sp
  if not data.continuesWithAt("obj", i):
    return (false, 0, 0, at + 1)
  let after = i + 3
  if after < data.len and not isDelim(data[after]):
    return (false, 0, 0, at + 1)
  (true, num, gen, after)

proc bruteScanXRef(src: PdfSource, limits: PdfLimits,
    notes: var seq[string]): XRef =
  ## Sweep for `N G obj` headers; the last file-order definition of an
  ## object number wins (incremental-update convention). Candidates are
  ## verified with parseIndirect so `N G obj` byte runs inside streams
  ## and strings do not become phantom entries (streams with indirect
  ## /Length are accepted by message carve-out: their offsets are still
  ## right and docmodel resolves their lengths with context).
  var entries = initTable[int, XRefEntry]()
  var count = 0
  var i = 0
  while i < src.len:
    if src[i] notin {'0'..'9'}:
      inc i
      continue
    let h = tryObjHeader(src, i)
    if not h.ok:
      i = h.after
      continue
    if h.num < 0 or h.num > limits.maxObjects or h.gen < 0 or
        h.gen > 65535:
      i = h.after
      continue
    var verified = false
    try:
      discard parseIndirect(src, i)
      verified = true
    except PdfError as e:
      if "needs document context" in e.msg:
        verified = true
    if verified:
      entries[h.num] = XRefEntry(offset: i, gen: h.gen, live: true,
        compressed: false, stmNum: 0, stmIdx: 0)
      inc count
      if count > limits.maxObjects:
        pdfFail("brute-force scan found too many objects (noise?)")
      notes.add("brute-force: object " & $h.num & " at offset " & $i)
    i = h.after
  if entries.len == 0:
    pdfFail("brute-force scan found no objects")
  # Last parseable trailer with a /Root reference wins.
  var trailer = CosObj(kind: coNull)
  var tpos = src.len - 1
  var attempts = 0
  while attempts < 8 and tpos >= 0:
    let p = rfindKeyword(src, "trailer", tpos)
    if p < 0: break
    let beforeOk = p == 0 or isDelim(src[p - 1])
    let after = p + 7
    let afterOk = after >= src.len or isDelim(src[after])
    if beforeOk and afterOk:
      try:
        var lx = initLexer(src, after)
        let t = lx.parseCosValue()
        if t.kind == coDict and t.dictGet("Root").kind == coRef:
          trailer = t
          break
      except PdfError:
        discard
    tpos = p - 1
    inc attempts
  if trailer.kind != coDict:
    pdfFail("brute-force recovery found objects but no usable trailer")
  if notes.len > 64:
    notes.setLen(64)
    notes.add("... (notes truncated)")
  finishXRef(entries, trailer)

proc parseXRef*(src: PdfSource, limits = defaultPdfLimits()): XRef =
  ## Strict chain first; lenient chain, then brute-force sweep. Either
  ## fallback sets recovered/notes. Total failure re-raises the strict
  ## error so messages stay precise.
  var strictMsg = ""
  try:
    return parseXRefStrict(src, limits)
  except PdfError as e:
    strictMsg = e.msg
  var notes = @["strict xref failed: " & strictMsg]
  try:
    result = parseXRefLenient(src, limits, notes)
    result.recovered = true
    result.notes = notes
    return
  except PdfError as e:
    notes.add("lenient xref failed: " & e.msg)
  try:
    result = bruteScanXRef(src, limits, notes)
    result.recovered = true
    result.notes = notes
    return
  except PdfError as e:
    notes.add("brute-force scan failed: " & e.msg)
  pdfFail(strictMsg)

proc parseXRef*(data: string, limits = defaultPdfLimits()): XRef =
  ## String convenience wrapper; the parser itself reads from the
  ## source without copying.
  parseXRef(fromString(data), limits)
