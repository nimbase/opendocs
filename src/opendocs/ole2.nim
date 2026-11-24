## Copyright (c) 2026 nimbase (MIT, see LICENSE at repo root).
## Portions derived from TalentFormula/msdoc `ole2/reader.go`
## (https://github.com/TalentFormula/msdoc, MIT): Copyright (c) 2024
## TalentFormula. SPDX-License-Identifier: MIT
##
## MS-CFB (OLE2 compound file) read-only container reader.
##
## Behavioral oracle: `references/msdoc/ole2/reader.go` for happy-path
## shapes only. That reader guesses sequential sectors, assumes 512-byte
## sectors, and has no MiniFAT; this port follows MS-CFB instead and
## diverges deliberately everywhere the oracle is loose (all divergences
## fail loudly rather than guess). Clean-room: no code copied.
##
## Shared plumbing, not a spreadsheet concern: lives at
## `src/opendocs/ole2.nim` (plan 19) so the future `.doc` reader reuses
## it for `WordDocument`/`Data`/`0Table`/`1Table`.
##
## Bounds (every length and chain is attacker-controlled):
## - Every sector number is validated `< sectorCount` before use.
## - Every chain walk (FAT, MiniFAT, DIFAT, directory, stream) is
##   capped at `sectorCount + 1` steps: cycles and over-long chains
##   raise deterministically instead of hanging. No timeouts needed.
## - Stream bytes are capped at 64 MB before allocating (matches
##   `opendocs/zip`'s `DefaultMaxEntryBytes`).
## - Sibling/child ids must be -1 or in range; freed (type 0) entries
##   are skipped without descending (their pointers are stale).
##
## Heuristics, documented because decoding has judgment calls:
## - Directory names decode UTF-16LE with U+FFFD substitution for lone
##   surrogates. A bad name must not brick the container; everything
##   structural still fails loudly.
## - Stream lookup is case-insensitive (Unicode fold, matching the
##   zip reader's sheet-name behavior); producers vary.
## - The mini-stream cutoff honors the header value (standard 4096).

import std/strutils

type
  OleError* = object of CatchableError

  OleEntryKind* = enum
    oekUnknown ## unallocated directory slot (never emitted)
    oekStorage
    oekStream
    oekRoot

  OleEntry* = object
    name*: string
    kind*: OleEntryKind
    size*: int64
    startSector*: int32
    clsid*: string ## canonical GUID, "" when all zero

  OleFileObj* = object
    data*: seq[byte]
    sectorSize*: int
    sectorCount*: int
    fat*: seq[uint32]
    entries*: seq[OleRawEntry]
    miniFat*: seq[uint32]
    miniStream*: seq[byte]
    miniCutoff*: uint32

  OleFile* = ref OleFileObj

  OleRawEntry = object
    name*: string
    kind*: OleEntryKind
    left*, right*, child*: int32
    startSector*: int32
    size*: int64
    clsid*: string

const
  MaxOleStreamBytes* = 64 * 1024 * 1024 ## zip-bomb guard, zip parity
  oleSig: array[8, byte] = [0xD0'u8, 0xCF, 0x11, 0xE0,
    0xA1, 0xB1, 0x1A, 0xE1]
  FREE_SECTOR = 0xFFFFFFFF'u32
  ENDOFCHAIN = 0xFFFFFFFE'u32

proc oleFail(msg: string) {.noreturn.} =
  raise newException(OleError, msg)

# ------------------------------------------------------------ accessors

proc u16at(d: openArray[byte], off: int): uint16 =
  if off < 0 or off + 2 > d.len: oleFail("ole: offset out of range")
  uint16(d[off]) or (uint16(d[off + 1]) shl 8)

proc u32at(d: openArray[byte], off: int): uint32 =
  if off < 0 or off + 4 > d.len: oleFail("ole: offset out of range")
  uint32(d[off]) or (uint32(d[off + 1]) shl 8) or
    (uint32(d[off + 2]) shl 16) or (uint32(d[off + 3]) shl 24)

proc i32at(d: openArray[byte], off: int): int32 =
  cast[int32](u32at(d, off))

proc sectorOffset(o: OleFile, sec: int32): int =
  ## File offset of a sector body. The 512-byte header is sector -1:
  ## sector 0 starts at offset 512 regardless of sector size
  ## (`(sec+1)*size` is only correct for 512-byte sectors).
  if sec < 0 or sec >= o.sectorCount:
    oleFail("ole: sector out of range: " & $sec)
  let off = 512 + sec.int * o.sectorSize
  if off + o.sectorSize > o.data.len:
    oleFail("ole: sector extends past end of file: " & $sec)
  off

# ---------------------------------------------------------------- parse

proc checkSectorNum(o: OleFile, sec: int32, what: string) =
  if sec < 0 or sec >= o.sectorCount:
    oleFail("ole: " & what & " out of range: " & $sec)

proc collectChain(o: OleFile, first: int32, fat: openArray[uint32],
    what: string): seq[int32] =
  ## Follow a FAT/MiniFAT chain with a deterministic step cap.
  if first < 0: return @[]
  var sec = first
  while true:
    o.checkSectorNum(sec, what & " chain sector")
    result.add sec
    if result.len > o.sectorCount + 1:
      oleFail("ole: " & what & " chain too long (cyclic?)")
    if sec.int >= fat.len:
      oleFail("ole: " & what & " chain past end of FAT: " & $sec)
    let nxt = fat[sec.int]
    if nxt == ENDOFCHAIN or nxt == FREE_SECTOR: break
    if nxt == 0xFFFFFFFDu32 or nxt == 0xFFFFFFFCu32:
      oleFail("ole: reserved sector in " & what & " chain: " & $sec)
    sec = cast[int32](nxt)

proc parseDirectory(o: OleFile, firstDir: int32) =
  let chain = o.collectChain(firstDir, o.fat, "directory")
  var raw: seq[byte]
  for sec in chain:
    let off = o.sectorOffset(sec)
    let prev = raw.len
    raw.setLen(prev + o.sectorSize)
    for i in 0 ..< o.sectorSize: raw[prev + i] = o.data[off + i]
  if raw.len mod 128 != 0:
    oleFail("ole: directory stream is not a multiple of 128")
  let count = raw.len div 128
  for i in 0 ..< count:
    let base = i * 128
    var name = ""
    let nameLen = u16at(raw, base + 64).int
    if nameLen mod 2 != 0 or nameLen > 64:
      oleFail("ole: bad directory name length")
    let units = nameLen div 2
    var j = 0
    while j < units:
      let u = u16at(raw, base + j * 2)
      if u == 0: break
      if u >= 0xD800'u16 and u <= 0xDBFF'u16:
        if j + 1 < units:
          let v = u16at(raw, base + (j + 1) * 2)
          if v >= 0xDC00'u16 and v <= 0xDFFF'u16:
            let cp = 0x10000'u32 + ((uint32(u) - 0xD800) shl 10) +
              (uint32(v) - 0xDC00)
            name.add(char(0xF0 or (cp shr 18)))
            name.add(char(0x80 or ((cp shr 12) and 0x3F)))
            name.add(char(0x80 or ((cp shr 6) and 0x3F)))
            name.add(char(0x80 or (cp and 0x3F)))
            j += 2
            continue
        name.add("\xEF\xBF\xBD") # U+FFFD, documented substitution
        inc j
      elif u >= 0xDC00'u16 and u <= 0xDFFF'u16:
        name.add("\xEF\xBF\xBD")
        inc j
      elif u < 0x80:
        name.add(char(u))
        inc j
      elif u < 0x800:
        name.add(char(0xC0 or (u shr 6)))
        name.add(char(0x80 or (u and 0x3F)))
        inc j
      else:
        name.add(char(0xE0 or (u shr 12)))
        name.add(char(0x80 or ((u shr 6) and 0x3F)))
        name.add(char(0x80 or (u and 0x3F)))
        inc j
    let typ = raw[base + 66]
    let kind =
      case typ
      of 0: oekUnknown
      of 1: oekStorage
      of 2: oekStream
      of 5: oekRoot
      else: oleFail("ole: bad directory entry type: " & $typ)
    let left = i32at(raw, base + 68)
    let right = i32at(raw, base + 72)
    let child = i32at(raw, base + 76)
    var clsid = ""
    var allZero = true
    for k in 0 ..< 16:
      if raw[base + 80 + k] != 0: allZero = false
    if not allZero:
      let d1 = u32at(raw, base + 80)
      let d2 = u16at(raw, base + 84)
      let d3 = u16at(raw, base + 86)
      clsid = d1.toHex(8).toLowerAscii() & "-" &
        d2.toHex(4).toLowerAscii() & "-" &
        d3.toHex(4).toLowerAscii() & "-"
      for k in 0 .. 1:
        clsid.add raw[base + 88 + k].toHex(2).toLowerAscii()
      clsid.add "-"
      for k in 2 .. 7:
        clsid.add raw[base + 88 + k].toHex(2).toLowerAscii()
    let lo = u32at(raw, base + 120)
    let hi = u32at(raw, base + 124)
    o.entries.add OleRawEntry(name: name, kind: kind, left: left,
      right: right, child: child, startSector: i32at(raw, base + 116),
      size: (uint64(hi) shl 32 or uint64(lo)).int64, clsid: clsid)

proc openOleBytes*(data: openArray[byte]): OleFile =
  ## Parse an OLE2 compound file. All structural defects raise
  ## `OleError`; nothing is guessed.
  if data.len < 512: oleFail("ole: too small for a header")
  for i in 0 ..< 8:
    if data[i] != oleSig[i]: oleFail("ole: bad signature")
  let major = u16at(data, 26)
  if major != 3 and major != 4:
    oleFail("ole: unsupported major version: " & $major)
  if u16at(data, 28) != 0xFFFE'u16:
    oleFail("ole: bad byte-order mark")
  let sectorShift = u16at(data, 30)
  if (major == 3 and sectorShift != 9) or
      (major == 4 and sectorShift != 12):
    oleFail("ole: sector shift does not match version")
  if u16at(data, 32) != 6:
    oleFail("ole: unsupported mini sector shift")
  let sectorSize = 1 shl sectorShift.int
  result = OleFile(data: @data, sectorSize: sectorSize,
    sectorCount: (data.len - 512) div sectorSize)
  if result.sectorCount < 1:
    oleFail("ole: no sectors after header")
  let numFatSectors = u32at(data, 44).int
  let firstDir = i32at(data, 48)
  result.miniCutoff = u32at(data, 56)
  let firstMiniFat = i32at(data, 60)
  let numMiniFatSectors = u32at(data, 64).int
  let firstDifat = i32at(data, 68)
  let numDifatSectors = u32at(data, 72).int
  # DIFAT: 109 header slots, then chained DIFAT sectors.
  var fatSectors: seq[int32] = @[]
  for i in 0 ..< 109:
    if fatSectors.len >= numFatSectors: break
    let s = i32at(data, 76 + i * 4)
    if s == -1: break # FREE: no more entries
    if s < -1: oleFail("ole: bad DIFAT entry")
    fatSectors.add s
  var difat = firstDifat
  var difatSteps = 0
  while fatSectors.len < numFatSectors:
    if difatSteps > result.sectorCount + 1:
      oleFail("ole: DIFAT chain too long (cyclic?)")
    if difat < 0: oleFail("ole: truncated DIFAT")
    result.checkSectorNum(difat, "DIFAT sector")
    let doff = result.sectorOffset(difat)
    let per = result.sectorSize div 4 - 1
    for i in 0 ..< per:
      if fatSectors.len >= numFatSectors: break
      let s = cast[int32](u32at(result.data, doff + i * 4))
      if s == -1: break
      if s < -1: oleFail("ole: bad DIFAT entry")
      fatSectors.add s
    let nxt = cast[int32](u32at(result.data, doff + result.sectorSize - 4))
    if fatSectors.len < numFatSectors and
        (nxt == -1 or nxt == -2):
      oleFail("ole: truncated DIFAT")
    difat = nxt
    inc difatSteps
    if numDifatSectors > 0 and difatSteps > numDifatSectors + 1:
      oleFail("ole: DIFAT count exceeded")
  if fatSectors.len < numFatSectors:
    oleFail("ole: truncated DIFAT")
  # FAT.
  for s in fatSectors: result.checkSectorNum(s, "FAT sector")
  let fatEntries = numFatSectors * (result.sectorSize div 4)
  for s in fatSectors:
    let off = result.sectorOffset(s)
    for i in 0 ..< result.sectorSize div 4:
      if result.fat.len >= fatEntries: break
      result.fat.add u32at(result.data, off + i * 4)
  if result.fat.len < fatEntries:
    oleFail("ole: truncated FAT")
  # Directory + MiniFAT + mini stream.
  result.parseDirectory(firstDir)
  if result.entries.len == 0:
    oleFail("ole: empty directory")
  if result.entries[0].kind != oekRoot:
    oleFail("ole: entry 0 is not the root storage")
  let miniChain = result.collectChain(firstMiniFat, result.fat,
    "MiniFAT")
  if miniChain.len < numMiniFatSectors:
    oleFail("ole: truncated MiniFAT")
  for s in miniChain:
    let moff = result.sectorOffset(s)
    for i in 0 ..< result.sectorSize div 4:
      result.miniFat.add u32at(result.data, moff + i * 4)
  let rootChain = result.collectChain(result.entries[0].startSector,
    result.fat, "mini stream")
  for s in rootChain:
    let roff = result.sectorOffset(s)
    let prev = result.miniStream.len
    result.miniStream.setLen(prev + result.sectorSize)
    for i in 0 ..< result.sectorSize:
      result.miniStream[prev + i] = result.data[roff + i]
  let wantMini = result.entries[0].size
  if wantMini < 0 or wantMini > MaxOleStreamBytes:
    oleFail("ole: bad mini stream size")
  if result.miniStream.len < wantMini.int:
    oleFail("ole: truncated mini stream")
  result.miniStream.setLen(wantMini.int)

proc openOle*(path: string): OleFile =
  ## File-backed `openOleBytes`. `OleError` on missing/short files.
  var f: File
  if not open(f, path, fmRead):
    raise newException(OleError, "cannot open file: " & path)
  defer: close(f)
  let size = getFileSize(f).int
  var data = newSeq[byte](size)
  if size > 0 and readBytes(f, data, 0, size) != size:
    raise newException(OleError, "short read: " & path)
  openOleBytes(data)

# ---------------------------------------------------------------- query

proc walk(o: OleFile, id: int32, prefix: string,
    acc: var seq[OleEntry]) =
  ## In-order red-black walk. Freed (type 0) subtrees are skipped
  ## without descending: their pointers are stale. Names carry their
  ## storage path (`VBA/dir`); root-level entries are bare.
  if id < 0: return
  if id.int >= o.entries.len:
    oleFail("ole: directory id out of range: " & $id)
  let e = o.entries[id.int]
  if e.kind == oekUnknown: return
  walk(o, e.left, prefix, acc)
  let path =
    if prefix == "": e.name
    else: prefix & "/" & e.name
  acc.add OleEntry(name: path, kind: e.kind, size: e.size,
    startSector: e.startSector, clsid: e.clsid)
  if e.kind == oekStorage or e.kind == oekRoot:
    let childPrefix =
      if e.kind == oekRoot: ""
      else: path
    walk(o, e.child, childPrefix, acc)
  walk(o, e.right, prefix, acc)

proc entries*(o: OleFile): seq[OleEntry] =
  ## Every live directory entry in tree order (root included).
  ## Stream names carry storage paths (`VBA/dir`).
  walk(o, 0, "", result)

proc readBytes(o: OleFile, chain: seq[int32], size: int64,
    what: string): seq[byte] =
  ## Concatenate a sector chain, truncated to `size`. Short chains
  ## fail loudly (truncated input), never silently.
  if size == 0: return @[]
  if size < 0 or size > MaxOleStreamBytes:
    oleFail("ole: bad stream size for " & what)
  var remaining = size.int
  for sec in chain:
    let off = o.sectorOffset(sec)
    let take = min(remaining, o.sectorSize)
    let prev = result.len
    result.setLen(prev + take)
    for i in 0 ..< take: result[prev + i] = o.data[off + i]
    remaining -= take
    if remaining == 0: break
  if remaining > 0:
    oleFail("ole: truncated stream " & what)

proc readStream*(o: OleFile, name: string): seq[byte] =
  ## Stream bytes by name (case-insensitive). Mini streams (below the
  ## header cutoff) resolve through the MiniFAT; regular streams
  ## through the FAT. Reading through the wrong table yields plausible
  ## garbage, so the cutoff decides, never the caller.
  var found = false
  var ent: OleEntry
  for e in o.entries():
    if (e.kind == oekStream or e.kind == oekRoot) and
        e.name.cmpIgnoreCase(name) == 0:
      found = true
      ent = e
      break
  if not found: oleFail("ole: stream not found: " & name)
  if ent.size == 0: return @[]
  if ent.kind == oekRoot:
    return o.readBytes(o.collectChain(ent.startSector, o.fat,
      "root stream"), ent.size, name)
  if ent.size.uint64 < o.miniCutoff:
    var idx = ent.startSector
    var chain: seq[int32] = @[]
    let miniCap = o.miniStream.len div 64 + 1
    while idx >= 0:
      if idx.int * 64 + 64 > o.miniStream.len:
        oleFail("ole: mini sector out of range in " & name)
      chain.add idx
      if chain.len > miniCap:
        oleFail("ole: mini chain too long (cyclic?) in " & name)
      if idx.int >= o.miniFat.len:
        oleFail("ole: mini chain past end of MiniFAT in " & name)
      let nxt = o.miniFat[idx.int]
      if nxt == ENDOFCHAIN or nxt == FREE_SECTOR: break
      if nxt == 0xFFFFFFFDu32 or nxt == 0xFFFFFFFCu32:
        oleFail("ole: reserved sector in mini chain in " & name)
      idx = cast[int32](nxt)
    var outp: seq[byte] = @[]
    var remaining = ent.size
    for ms in chain:
      let off = ms.int * 64
      let take = min(remaining, 64).int
      let prev = outp.len
      outp.setLen(prev + take)
      for i in 0 ..< take: outp[prev + i] = o.miniStream[off + i]
      remaining -= take.int64
      if remaining == 0: break
    if remaining > 0:
      oleFail("ole: truncated mini stream " & name)
    return outp
  o.readBytes(o.collectChain(ent.startSector, o.fat, "stream " & name),
    ent.size, name)

proc contains*(o: OleFile, name: string): bool =
  ## Case-insensitive stream existence (storages excluded, like reads).
  for e in o.entries():
    if (e.kind == oekStream or e.kind == oekRoot) and
        e.name.cmpIgnoreCase(name) == 0:
      return true
  false

proc closeOle*(o: OleFile) =
  ## Release hook for API symmetry (`openOle`/`openOleBytes` own plain
  ## memory, so there is nothing to spill; safe to call twice or on
  ## nil).
  if o == nil: discard
