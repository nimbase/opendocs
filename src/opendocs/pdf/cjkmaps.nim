## CID to Unicode fallback maps (ISO 32000 §9.7.5.2).
##
## When a composite font has no (or incomplete) /ToUnicode, shown codes
## are CIDs in the descendant's Registry/Ordering collection. The
## numeric ranges live in ./cjkdata (generated from Adobe CMap
## resources, see tests/gen_cjk_tables.nim); this module inverts the
## Unicode to CID ranges once per ordering and answers CID to Unicode
## queries. Unknown CIDs return -1 so the caller emits U+FFFD; nothing
## here guesses.
##
## Predefined /Encoding CMaps (90ms-RKSJ-H and kin) map codes to CIDs
## through the same generated ranges, and their codespace tables come
## from the CMap files themselves, so code splitting needs no hand
## data. Identity-H/V are built in (codes are CIDs, 2 bytes).

import std/base64
import std/tables
import ./cmap
import ./cjkdata

export cjkdata

var cjkCidCache = initTable[string, seq[uint32]]()

proc cjkCidTable(ordering: string): seq[uint32] =
  ## Little-endian uint32 array indexed by CID (0 means unmapped),
  ## decoded once per ordering.
  if cjkCidCache.hasKey(ordering):
    return cjkCidCache[ordering]
  let raw = decode(rosCids(ordering))
  result = newSeq[uint32](raw.len div 4)
  if raw.len > 0:
    copyMem(result[0].addr, raw[0].unsafeAddr, raw.len)
  cjkCidCache[ordering] = result

proc cidToUnicode*(ordering: string, cid: int): int =
  ## Unicode scalar for a CID in a Registry/Ordering collection
  ## (Japan1, GB1, CNS1, Korea1), or -1 when unmapped.
  if not hasCjkOrdering(ordering) or cid < 0:
    return -1
  let t = cjkCidTable(ordering)
  if cid >= t.len or t[cid] == 0:
    return -1
  int(t[cid])

proc rangeLookup(ranges: seq[CjkMapRange], code: int): int =
  var lo = 0
  var hi = ranges.len - 1
  while lo <= hi:
    let mid = (lo + hi) shr 1
    if code < ranges[mid].lo:
      hi = mid - 1
    elif code > ranges[mid].hi:
      lo = mid + 1
    else:
      return ranges[mid].base + (code - ranges[mid].lo)
  -1

proc codeToCid*(cmapName: string, code: int): int =
  ## Code to CID through a predefined /Encoding CMap
  ## (90ms-RKSJ-H and kin), or -1 when unmapped or unknown.
  rangeLookup(encRanges(cmapName), code)

proc codeToUnicode*(cmapName: string, code: int): int =
  ## Code straight to Unicode through the encoding's UCS2 CMap.
  ## Gap-fills CIDs the ROS tables do not cover (alternate alphabet
  ## CIDs and friends); -1 when unmapped or unknown.
  if code < 0 or code > 0xFFFF:
    return -1
  let b = decode(encUnicodes(cmapName))
  let n = b.len div 5
  var lo = 0
  var hi = n - 1
  while lo <= hi:
    let mid = (lo + hi) shr 1
    let c = int(byte(b[5 * mid])) + int(byte(b[5 * mid + 1])) * 256
    if c == code:
      return int(byte(b[5 * mid + 2])) +
        int(byte(b[5 * mid + 3])) * 256 +
        int(byte(b[5 * mid + 4])) * 65536
    elif c < code:
      lo = mid + 1
    else:
      hi = mid - 1
  -1

proc cmapCodespaces*(cmapName: string): seq[CodeRange] =
  ## Codespace ranges for splitting variable-length codes. Identity
  ## CMaps are built in; vertical variants share their H codespace.
  case cmapName
  of "Identity-H", "Identity-V":
    return @[CodeRange(lo: 0, hi: 0xFFFF, len: 2)]
  else:
    discard
  let direct = encCodes(cmapName)
  if direct.len > 0:
    return direct
  if cmapName.len > 2 and cmapName[^2 .. ^1] == "-V":
    return encCodes(cmapName[0 .. ^3] & "-H")
  @[]
