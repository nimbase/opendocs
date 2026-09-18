## Minimal sfnt 'cmap' reader for the extraction fallback path.
##
## For CIDFontType2 fonts without /ToUnicode, glyph IDs map back to
## Unicode through the embedded font's 'cmap' table (after the
## /CIDToGIDMap step, which text.nim handles). Only Unicode subtables
## in formats 4 and 12 are read; entries apply full-coverage-first
## with first mapping wins. Font bytes are untrusted third-party data
## and better fallback links may exist downstream, so anything
## unparseable yields an empty map instead of failing.

import std/tables

type SfntCursor = object
  buf: string
  ok: bool

proc u16(c: var SfntCursor, pos: int): int =
  if pos < 0 or pos + 1 >= c.buf.len:
    c.ok = false
    return 0
  int(byte(c.buf[pos])) * 256 + int(byte(c.buf[pos + 1]))

proc u32(c: var SfntCursor, pos: int): int =
  if pos < 0 or pos + 3 >= c.buf.len:
    c.ok = false
    return 0
  int(byte(c.buf[pos])) * 16777216 + int(byte(c.buf[pos + 1])) * 65536 +
    int(byte(c.buf[pos + 2])) * 256 + int(byte(c.buf[pos + 3]))

proc parseFormat4(c: var SfntCursor, at: int,
    into: var Table[int, int]) =
  let segN = c.u16(at + 6) div 2
  if not c.ok or segN <= 0 or segN > 200:
    c.ok = false
    return
  var ends = newSeq[int](segN)
  var starts = newSeq[int](segN)
  var deltas = newSeq[int](segN)
  var offsets = newSeq[int](segN)
  for i in 0 ..< segN:
    ends[i] = c.u16(at + 14 + i * 2)
  for i in 0 ..< segN:
    starts[i] = c.u16(at + 16 + segN * 2 + i * 2)
  for i in 0 ..< segN:
    deltas[i] = c.u16(at + 16 + segN * 4 + i * 2)
  let rangeBase = at + 16 + segN * 6
  for i in 0 ..< segN:
    offsets[i] = c.u16(rangeBase + i * 2)
  if not c.ok:
    return
  for i in 0 ..< segN:
    if starts[i] > ends[i]:
      continue
    for ch in starts[i] .. ends[i]:
      if ch == 0xFFFF:
        break
      var gid: int
      if offsets[i] == 0:
        gid = (ch + deltas[i]) and 0xFFFF
      else:
        let p = rangeBase + i * 2 + offsets[i] + (ch - starts[i]) * 2
        gid = c.u16(p)
        if not c.ok:
          return
        if gid != 0:
          gid = (gid + deltas[i]) and 0xFFFF
      if gid != 0 and not into.hasKey(gid):
        into[gid] = ch

proc parseFormat12(c: var SfntCursor, at: int,
    into: var Table[int, int]) =
  let groups = c.u32(at + 12)
  if not c.ok or groups > 5000:
    c.ok = false
    return
  for i in 0 ..< groups:
    let lo = c.u32(at + 16 + i * 12)
    let hi = c.u32(at + 20 + i * 12)
    let gid = c.u32(at + 24 + i * 12)
    if not c.ok or hi > 0x10FFFF or hi < lo or gid > 0xFFFFFF:
      c.ok = false
      return
    for ch in lo .. hi:
      let g = gid + (ch - lo)
      if not into.hasKey(g):
        into[g] = ch

proc parseSfntCmap*(fontBytes: string): Table[int, int] =
  ## Glyph ID to Unicode scalar from an sfnt font program.
  ## Empty when absent, truncated or otherwise unparseable.
  result = initTable[int, int]()
  var c = SfntCursor(buf: fontBytes, ok: true)
  if fontBytes.len < 12:
    return
  let tables = c.u16(4)
  if not c.ok or tables <= 0 or tables > 64:
    return
  var cmapOff = -1
  for i in 0 ..< tables:
    let p = 12 + i * 16
    if p + 15 >= fontBytes.len:
      return
    if fontBytes[p .. p + 3] == "cmap":
      cmapOff = c.u32(p + 8)
      break
  if cmapOff < 0:
    return
  let subs = c.u16(cmapOff + 2)
  if not c.ok or subs <= 0 or subs > 32:
    return
  type Sub = tuple[plat, kind, off: int]
  var unicodeSubs: seq[Sub] = @[]
  for i in 0 ..< subs:
    let p = cmapOff + 4 + i * 8
    let plat = c.u16(p)
    let kind = c.u16(p + 2)
    let off = c.u32(p + 4)
    if not c.ok:
      return
    if (plat == 0) or (plat == 3 and kind in [0, 1, 10]):
      unicodeSubs.add((plat, kind, off))
  # Full-repertoire formats first so first mapping wins.
  for pass in [12, 4]:
    for s in unicodeSubs:
      let at = cmapOff + s.off
      let fmt = c.u16(at)
      if not c.ok:
        return
      if fmt == pass and at + 16 < fontBytes.len:
        if pass == 12:
          c.parseFormat12(at, result)
        else:
          c.parseFormat4(at, result)
        if not c.ok:
          return result
