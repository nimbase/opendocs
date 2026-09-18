## CJK table generator (run manually, not a test).
##
## Builds src/opengraphics/pdf/cjkdata.nim from Adobe CMap resources:
## Unicode to CID ranges for ROS Japan1/GB1/CNS1/Korea1 (inverted to
## CID to Unicode at runtime by cjkmaps.nim) plus code to CID ranges
## for common predefined encodings, with codespace tables taken from
## the CMap files themselves.
##
##   clue run tests/gen_cjk_tables.nim -- --cmaps:/path/to/CMap
## or set ADOBE_CMAPS. Sources: https://github.com/adobe-fonts/adobe-cmaps
## (also bundled with Ghostscript under .../Resource/CMap).
##
## Origin of the numbers: Adobe CMap resources, Copyright 1990-2023
## Adobe, redistributed under the BSD terms in those files; the
## generated module retains the copyright notice. Rerun after changing
## the file lists below.

import std/algorithm
import std/base64
import std/os
import std/sequtils
import std/strutils
import std/tables
import std/unicode
import ../src/opendocs/pdf/cmap

const OutPath = "src/opengraphics/pdf/cjkdata.nim"

proc cmapDir(): string =
  for i in 1 .. paramCount():
    if paramStr(i).startsWith("--cmaps:"):
      return paramStr(i)[8 .. ^1]
  result = getEnv("ADOBE_CMAPS")
  if result.len == 0:
    quit("gen_cjk_tables: pass --cmaps:<dir> or set ADOBE_CMAPS " &
      "(Adobe CMap resources, e.g. Ghostscript Resource/CMap or " &
      "https://github.com/adobe-fonts/adobe-cmaps)")

proc readText(path: string): string =
  if not fileExists(path):
    quit("gen_cjk_tables: missing CMap file " & path)
  readFile(path)

proc fileOrdering(text: string): string =
  let j = text.find("/Ordering")
  if j < 0:
    quit("gen_cjk_tables: no /Ordering in CMap text")
  let a = text.find('(', j)
  let b = text.find(')', a)
  if a < 0 or b < 0:
    quit("gen_cjk_tables: bad /Ordering in CMap text")
  text[a + 1 .. b - 1]

proc usecmaps(text: string): seq[string] =
  var i = 0
  while true:
    let j = text.find("usecmap", i)
    if j < 0:
      break
    var k = j - 1
    while k >= 0 and text[k] in {' ', '\x09', '\x0A', '\x0C', '\x0D'}:
      dec k
    let e = k
    while k >= 0 and text[k] notin
        {' ', '\x09', '\x0A', '\x0C', '\x0D', '/', '<'}:
      dec k
    if e >= k + 1:
      result.add(text[k + 1 .. e])
    i = j + 7

proc mergeRuns(pairs: seq[(int, int)]): seq[(int, int, int)] =
  ## Merge key-sorted (key, val) pairs into (lo, hi, base) runs where
  ## both key and value advance by one.
  var ps = pairs
  ps.sort(proc(a, b: (int, int)): int = cmp(a[0], b[0]))
  var i = 0
  while i < ps.len:
    var lo = ps[i][0]
    var hi = lo
    var base = ps[i][1]
    while i + 1 < ps.len and ps[i + 1][0] == hi + 1 and
        ps[i + 1][1] == base + (hi + 1 - lo):
      inc hi
      inc i
    result.add((lo, hi, base))
    inc i

proc loadCids(dir, name: string,
    stack: var seq[string]): Table[int, int] =
  ## Parse one CMap file, resolving usecmap chains base-first so the
  ## file's own entries overlay (later wins).
  if name in stack:
    quit("gen_cjk_tables: usecmap cycle at " & name)
  stack.add(name)
  let text = readText(dir / name)
  for base in usecmaps(text):
    for k, v in loadCids(dir, base, stack):
      result[k] = v
  let cm = parseCMap(text)
  for k, v in cm.cids:
    result[k] = v
  # bfchar/bfrange destinations in encoding CMaps are raw codes;
  # keep numeric single-scalar ones as code to CID too.
  for k, v in cm.entries:
    if v.len > 0:
      var isNum = true
      var n = 0
      for c in v:
        if c notin {'0' .. '9'}:
          isNum = false
          break
        n = n * 10 + (ord(c) - ord('0'))
      if isNum:
        result[k] = n
  discard stack.pop()

proc loadCodes(dir, name: string): seq[CodeRange] =
  let text = readText(dir / name)
  result = parseCMap(text).codes
  for base in usecmaps(text):
    if result.len == 0:
      result = loadCodes(dir, base)

const RosSources = [
  ("Japan1", @["UniJIS-UCS2-H", "UniJIS2004-UTF32-H",
    "UniJISX0213-UTF32-H"]),
  ("GB1", @["UniGB-UCS2-H"]),
  ("CNS1", @["UniCNS-UCS2-H"]),
  ("Korea1", @["UniKS-UCS2-H"]),
]

const EncSources = [
  ("90ms-RKSJ-H", "Japan1", "90ms-RKSJ-UCS2"),
  ("90ms-RKSJ-V", "Japan1", "90ms-RKSJ-UCS2"),
  ("90msp-RKSJ-H", "Japan1", "90ms-RKSJ-UCS2"),
  ("90msp-RKSJ-V", "Japan1", "90ms-RKSJ-UCS2"),
  ("90pv-RKSJ-H", "Japan1", "90pv-RKSJ-UCS2C"),
  ("90pv-RKSJ-V", "Japan1", "90pv-RKSJ-UCS2C"),
  ("GBK-EUC-H", "GB1", "GBK-EUC-UCS2"),
  ("GBpc-EUC-H", "GB1", "GBpc-EUC-UCS2C"),
  ("GBpc-EUC-V", "GB1", "GBpc-EUC-UCS2C"),
  ("B5-H", "CNS1", "B5pc-UCS2C"),
  ("ETen-B5-H", "CNS1", "ETen-B5-UCS2"),
  ("KSC-EUC-H", "Korea1", "KSCpc-EUC-UCS2C"),
  ("KSCms-UHC-H", "Korea1", "KSCms-UHC-UCS2"),
]

const Ucs2Probes = [
  ("90ms-RKSJ-UCS2", 0x41, 0x41), ("90ms-RKSJ-UCS2", 0x93FA, 0x65E5),
  ("90pv-RKSJ-UCS2C", 0x41, 0x41), ("90pv-RKSJ-UCS2C", 0x93FA, 0x65E5),
  ("GBK-EUC-UCS2", 0x41, 0x41), ("GBK-EUC-UCS2", 0xD6D0, 0x4E2D),
  ("GBpc-EUC-UCS2C", 0x41, 0x41),
  ("B5pc-UCS2C", 0x41, 0x41), ("B5pc-UCS2C", 0xA440, 0x4E00),
  ("ETen-B5-UCS2", 0x41, 0x41), ("ETen-B5-UCS2", 0xA440, 0x4E00),
  ("KSCms-UHC-UCS2", 0x41, 0x41), ("KSCms-UHC-UCS2", 0xB0A1, 0xAC00),
  ("KSCpc-EUC-UCS2C", 0x41, 0x41), ("KSCpc-EUC-UCS2C", 0xB0A1, 0xAC00),
]

proc nimName(s: string): string =
  result = ""
  for c in s:
    if c in {'A' .. 'Z', 'a' .. 'z', '0' .. '9'}:
      result.add(c)

proc emitRanges(f: File, pairs: seq[(int, int, int)]) =
  f.write("@[")
  for i, r in pairs:
    if i > 0:
      f.write(", ")
    if i mod 6 == 5:
      f.write("\n  ")
    f.write("(0x" & r[0].toHex(8) & ", 0x" & r[1].toHex(8) &
      ", 0x" & r[2].toHex(8) & ")")
  f.write("]")

proc cidTier(u: int): int =
  ## Duplicate CID claims happen: Kangxi/compat aliases share CIDs
  ## with the unified forms (e.g. U+2F47 and U+65E5 both claim
  ## Japan1 CID 3284). Body text uses the unified forms, so alias
  ## zones lose ties. Both values stay Adobe-true; this only orders
  ## them, deterministically.
  if (u >= 0x2E80 and u <= 0x2EFF) or (u >= 0x2F00 and u <= 0x2FDF) or
      (u >= 0xF900 and u <= 0xFAFF) or
      (u >= 0x2F800 and u <= 0x2FA1D):
    1
  else:
    0

proc main() =
  let dir = cmapDir()
  var f = open(OutPath, fmWrite)
  f.write("""## GENERATED by tests/gen_cjk_tables.nim - do not edit.
##
## Numeric ranges derived from Adobe CMap resources:
## Copyright 1990-2023 Adobe. All rights reserved.
##
## Redistribution and use in source and binary forms, with or without
## modification, are permitted provided that the following conditions
## are met:
##
## Redistributions of source code must retain the above copyright
## notice, this list of conditions and the following disclaimer.
##
## Redistributions in binary form must reproduce the above copyright
## notice, this list of conditions and the following disclaimer in the
## documentation and/or other materials provided with the distribution.
##
## Neither the name of Adobe nor the names of its contributors may be
## used to endorse or promote products derived from this software
## without specific prior written permission.
##
## THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
## "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
## LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
## FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
## COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
## INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
## BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
## LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
## CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
## LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
## ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
## POSSIBILITY OF SUCH DAMAGE.

import ./cmap

type CjkMapRange* = tuple[lo, hi, base: int]

""")
  echo "ROS tables:"
  for entry in RosSources:
    let ordering = entry[0]
    let files = entry[1]
    var uniToCid = initTable[int, int]()
    var cidToUni = initTable[int, int]()
    var cidTierBest = initTable[int, int]()
    var maxCid = 0
    var order: seq[string] = @[]
    for fn in files:
      let text = readText(dir / fn)
      let ord = fileOrdering(text)
      if ord != ordering:
        quit("gen_cjk_tables: " & fn & " has Ordering " & ord &
          ", want " & ordering)
      var stack: seq[string] = @[]
      let cids = loadCids(dir, fn, stack)
      order.add(fn & ":" & $cids.len)
      var ps: seq[(int, int)] = @[]
      for code, cid in cids:
        ps.add((code, cid))
      ps.sort(proc(a, b: (int, int)): int = cmp(a[0], b[0]))
      for (uni, cid) in ps:
        if not uniToCid.hasKey(uni):
          uniToCid[uni] = cid
        let t = cidTier(uni)
        if not cidToUni.hasKey(cid) or t < cidTierBest[cid]:
          cidToUni[cid] = uni
          cidTierBest[cid] = t
        maxCid = max(maxCid, cid)
    # Dense CID array (collections are 0..N), 0 means unmapped.
    var arr = newSeq[uint32](maxCid + 1)
    for cid, uni in cidToUni:
      if uni > 0x10FFFF:
        quit("gen_cjk_tables: scalar out of range in " & ordering)
      arr[cid] = uint32(uni)
    # NUL (U+0000) never carries text; CID 0 stays the sentinel.
    arr[0] = 0
    var raw = newString(arr.len * 4)
    copyMem(raw[0].addr, arr[0].addr, raw.len)
    f.write("const ros" & ordering & "Cids*: string = \"\"\"\n" &
      encode(raw) & "\"\"\"\n")
    f.write("const ros" & ordering & "Top*: int = " & $arr.len & "\n\n")
    echo "  " & ordering & ": " & $cidToUni.len & " CIDs from [" &
      order.join(", ") & "], top " & $arr.len & ", b64 " &
      $(encode(raw).len div 1024) & "K"
  echo "Encoding tables:"
  var ucs2Done: seq[string] = @[]
  for entry in EncSources:
    let cmapName = entry[0]
    let ordering = entry[1]
    let ucs2fn = entry[2]
    var stack: seq[string] = @[]
    let cids = loadCids(dir, cmapName, stack)
    let text = readText(dir / cmapName)
    if fileOrdering(text) != ordering:
      quit("gen_cjk_tables: " & cmapName & " ordering mismatch")
    var ps: seq[(int, int)] = @[]
    for code, cid in cids:
      ps.add((code, cid))
    let ranges = mergeRuns(ps)
    if ranges.len == 0:
      quit("gen_cjk_tables: no code to CID entries in " & cmapName)
    f.write("const enc" & nimName(cmapName) &
      "*: seq[CjkMapRange] = ")
    f.emitRanges(ranges)
    f.write("\n")
    let codes = loadCodes(dir, cmapName)
    f.write("const enc" & nimName(cmapName) & "Codes*: seq[CodeRange] = @[")
    for i, c in codes:
      if i > 0:
        f.write(", ")
      f.write("CodeRange(lo: 0x" & c.lo.toHex(8) & ", hi: 0x" &
        c.hi.toHex(8) & ", len: " & $c.len & ")")
    f.write("]\n\n")
    echo "  " & cmapName & ": " & $ps.len & " codes, " &
      $ranges.len & " ranges, " & $codes.len & " codespaces"
    if ucs2fn notin ucs2Done:
      ucs2Done.add(ucs2fn)
      let ucm = parseCMap(readText(dir / ucs2fn))
      var ups: seq[(int, int)] = @[]
      for code, s in ucm.entries:
        let rs = toSeq(runes(s))
        if rs.len != 1:
          continue
        if code > 0xFFFF or int(rs[0]) > 0xFFFFFF:
          quit("gen_cjk_tables: entry out of packed range in " & ucs2fn)
        ups.add((code, int(rs[0])))
      ups.sort(proc(a, b: (int, int)): int = cmp(a[0], b[0]))
      if ups.len == 0:
        quit("gen_cjk_tables: no direct mappings in " & ucs2fn)
      # Packed code-sorted records: u16 code, u24 scalar, LE.
      var raw = newString(ups.len * 5)
      for i, p in ups:
        raw[5 * i] = char(p[0] and 0xFF)
        raw[5 * i + 1] = char((p[0] shr 8) and 0xFF)
        raw[5 * i + 2] = char(p[1] and 0xFF)
        raw[5 * i + 3] = char((p[1] shr 8) and 0xFF)
        raw[5 * i + 4] = char((p[1] shr 16) and 0xFF)
      f.write("const enc" & nimName(ucs2fn) &
        "UD*: string = \"\"\"\n" & encode(raw) & "\"\"\"\n\n")
      var probeOk = 0
      for p in Ucs2Probes:
        if p[0] == ucs2fn:
          var got = -1
          for u in ups:
            if u[0] == p[1]:
              got = u[1]
          if got != p[2]:
            quit("gen_cjk_tables: probe " & ucs2fn & " " &
              p[1].toHex(4) & " -> " & got.toHex(4) & ", want " &
              p[2].toHex(4))
          inc probeOk
      echo "  " & ucs2fn & ": " & $ups.len & " direct, b64 " &
        $(encode(raw).len div 1024) & "K, " & $probeOk & " probes"
  f.write("""proc rosCids*(ordering: string): string =
  ## Base64 little-endian uint32 array (index CID, 0 unmapped).
  case ordering
""")
  for entry in RosSources:
    f.write("  of \"" & entry[0] & "\": ros" & entry[0] & "Cids\n")
  f.write("""  else: ""

proc rosTop*(ordering: string): int =
  case ordering
""")
  for entry in RosSources:
    f.write("  of \"" & entry[0] & "\": ros" & entry[0] & "Top\n")
  f.write("""  else: 0

proc encRanges*(cmapName: string): seq[CjkMapRange] =
  case cmapName
""")
  for entry in EncSources:
    f.write("  of \"" & entry[0] & "\": enc" & nimName(entry[0]) & "\n")
  f.write("""  else: @[]

proc encCodes*(cmapName: string): seq[CodeRange] =
  case cmapName
""")
  for entry in EncSources:
    f.write("  of \"" & entry[0] & "\": enc" & nimName(entry[0]) &
      "Codes\n")
  f.write("""  else: @[]

proc encUnicodes*(cmapName: string): string =
  ## Packed code-sorted direct mappings (u16 code, u24 scalar, LE)
  ## from the encoding's UCS2 CMap. Gap-fills CIDs the ROS tables
  ## do not cover.
  case cmapName
""")
  for entry in EncSources:
    f.write("  of \"" & entry[0] & "\": enc" & nimName(entry[2]) & "UD\n")
  f.write("""  else: ""

proc hasCjkOrdering*(ordering: string): bool =
  ordering in ["Japan1", "GB1", "CNS1", "Korea1"]

proc hasCjkEncoding*(cmapName: string): bool =
  encRanges(cmapName).len > 0
""")
  f.close()
  echo "wrote " & OutPath

main()
