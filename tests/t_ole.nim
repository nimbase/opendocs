## OLE2 compound-file container tests. The real `vbaProject.bin`
## (copied from `references/excelize/test/`, 16384 bytes, the 14-entry
## VBA project) pins the red-black walk, the MiniFAT path and the exact
## stream inventory; everything else is a hand-rolled synthetic from
## `ole_build` (no extra binaries).

import std/[unittest, os, strutils]
import opendocs/ole2
import ole_build

const OleFixture = "tests/fixtures/ole/vbaProject.bin"

proc streamNames(o: OleFile): seq[string] =
  for e in o.entries():
    if e.kind == oekStream: result.add e.name

suite "ole container happy path":
  test "real vbaProject.bin pins the full inventory":
    let data = cast[seq[byte]](readFile(OleFixture))
    check data.len == 16384
    let o = openOleBytes(data)
    defer: o.closeOle()
    var got: seq[(string, string, int64)] = @[]
    for e in o.entries():
      got.add ($e.kind, e.name, e.size)
    check got == @[
      ("oekRoot", "Root Entry", 11840'i64),
      ("oekStorage", "VBA", 0'i64),
      ("oekStream", "VBA/dir", 883'i64),
      ("oekStream", "VBA/Sheet1", 1564'i64),
      ("oekStream", "VBA/Module1", 1050'i64),
      ("oekStream", "VBA/__SRP_0", 1507'i64),
      ("oekStream", "VBA/__SRP_1", 78'i64),
      ("oekStream", "VBA/__SRP_2", 84'i64),
      ("oekStream", "VBA/__SRP_3", 103'i64),
      ("oekStream", "VBA/ThisWorkbook", 985'i64),
      ("oekStream", "VBA/_VBA_PROJECT", 3463'i64),
      ("oekStream", "VBA/ThisWorkbook1", 986'i64),
      ("oekStream", "PROJECT", 578'i64),
      ("oekStream", "PROJECTwm", 128'i64)]

  test "PROJECT stream decodes through the MiniFAT":
    let o = openOleBytes(cast[seq[byte]](readFile(OleFixture)))
    defer: o.closeOle()
    let proj = cast[string](o.readStream("PROJECT"))
    check proj.startsWith("ID=\"{393F1BD5-8571-43B5-BE00-73D2AA4AA62C}\"")
    check o.readStream("VBA/dir").len == 883
    check o.readStream("PROJECTwm").len == 128
    check o.readStream("project").len == 578 # case-insensitive
    check o.contains("VBA/DIR")
    check not o.contains("VBA/nope")

  test "missing stream and missing file fail loudly":
    let o = openOleBytes(cast[seq[byte]](readFile(OleFixture)))
    defer: o.closeOle()
    expect OleError:
      discard o.readStream("VBA/nope")
    expect OleError:
      discard openOle("tests/fixtures/ole/no-such-file.bin")
    o.closeOle() # idempotent, safe twice

suite "ole synthetic v3":
  test "regular multi-sector chain reads in order":
    var big: seq[byte] = @[]
    for i in 0 ..< 5000: big.add byte(i mod 251)
    var words: seq[seq[byte]] = @[]
    for s in 0 ..< 9: words.add big[s * 512 ..< s * 512 + 512]
    words.add big[9 * 512 ..< 5000]
    words.add @[0xAA'u8, 0xAA]
    let data = buildMiniCfb(3,
      [cfbDirEnt("Root Entry", 5, -1, -1, 1, -2, 0),
       cfbDirEnt("Data", 1, -1, -1, 2, -2, 0),
       cfbDirEnt("big", 2, -1, 3, -1, 2, 5000),
       cfbDirEnt("trunc", 2, -1, -1, -1, 12, 2000)],
      [CfbEnd, CfbEnd, 3'u32, 4, 5, 6, 7, 8, 9, 10, 11, CfbEnd,
        CfbEnd],
      words)
    let o = openOleBytes(data)
    defer: o.closeOle()
    check o.streamNames() == @["Data/big", "Data/trunc"]
    check o.readStream("Data/big") == big
    check o.readStream("DATA/BIG") == big # case-insensitive
    expect OleError:
      discard o.readStream("Data/trunc") # chain shorter than size

  test "empty streams read empty":
    let data = buildMiniCfb(3,
      [cfbDirEnt("Root Entry", 5, -1, -1, 1, -2, 0),
       cfbDirEnt("nothing", 2, -1, -1, -1, -2, 0)],
      [CfbEnd, CfbEnd], [])
    let o = openOleBytes(data)
    defer: o.closeOle()
    check o.readStream("nothing") == newSeq[byte](0)

  test "right siblings are visited, not just left children":
    # A left-child-only walk finds "lone" but drops "found".
    let data = buildMiniCfb(3,
      [cfbDirEnt("Root Entry", 5, -1, -1, 1, -2, 0),
       cfbDirEnt("S", 1, -1, -1, 2, -2, 0),
       cfbDirEnt("lone", 2, -1, 3, -1, -2, 0),
       cfbDirEnt("found", 2, -1, -1, -1, -2, 0)],
      [CfbEnd, CfbEnd], [])
    let o = openOleBytes(data)
    defer: o.closeOle()
    check o.streamNames() == @["S/lone", "S/found"]

  test "cyclic FAT raises instead of hanging":
    let data = buildMiniCfb(3,
      [cfbDirEnt("Root Entry", 5, -1, -1, 1, -2, 0),
       cfbDirEnt("loop", 2, -1, -1, -1, 2, 5000)],
      [CfbEnd, CfbEnd, 3'u32, 2'u32], [])
    let o = openOleBytes(data)
    defer: o.closeOle()
    expect OleError:
      discard o.readStream("loop")

suite "ole synthetic v4 and DIFAT":
  test "4096-byte sectors work":
    var big: seq[byte] = @[]
    for i in 0 ..< 5000: big.add byte(i mod 251)
    let data = buildMiniCfb(4,
      [cfbDirEnt("Root Entry", 5, -1, -1, 1, -2, 0),
       cfbDirEnt("big4", 2, -1, -1, -1, 2, 5000)],
      [CfbEnd, CfbEnd, 3'u32, CfbEnd],
      [big[0 ..< 4096], big[4096 ..< 5000]])
    let o = openOleBytes(data)
    defer: o.closeOle()
    check o.readStream("big4") == big

  test "110 FAT sectors route through a DIFAT sector":
    # Layout: sectors 0..109 FAT, 110 DIFAT, 111 DIR, 112..121 data.
    var difat109: seq[int32] = @[]
    for i in 0 ..< 109: difat109.add i.int32
    var img = cfbHeader(3, 110, 111, 4096, -2, 0, 110, 1, difat109)
    for _ in 0 ..< 110: img.add cfbFatSector([]) # all FREE initially
    var difatSec = cfbFatSector([109'u32]) # FAT#109, then FREE...
    patchU32(difatSec, 508, CfbEnd) # ...with ENDOFCHAIN chaining off
    img.add difatSec
    img.add cfbDirEnt("Root Entry", 5, -1, -1, 1, -2, 0) &
      cfbDirEnt("big", 2, -1, -1, -1, 112, 5000)
    for _ in 0 ..< 512 - 256: img.add 0'u8 # pad DIR to one sector
    var big: seq[byte] = @[]
    for i in 0 ..< 5000: big.add byte(i mod 251)
    img.add big
    while img.len mod 512 != 0: img.add 0'u8
    # Wire the FAT: single dir sector, data chain 112..121.
    proc fatPatch(entry: int, val: uint32) =
      img[512 + (entry div 128) * 512 + (entry mod 128) * 4 + 0] =
        byte(val and 0xFF)
      img[512 + (entry div 128) * 512 + (entry mod 128) * 4 + 1] =
        byte((val shr 8) and 0xFF)
      img[512 + (entry div 128) * 512 + (entry mod 128) * 4 + 2] =
        byte((val shr 16) and 0xFF)
      img[512 + (entry div 128) * 512 + (entry mod 128) * 4 + 3] =
        byte((val shr 24) and 0xFF)
    fatPatch(111, CfbEnd)
    for s in 112 ..< 121: fatPatch(s, uint32(s + 1))
    fatPatch(121, CfbEnd)
    let o = openOleBytes(img)
    defer: o.closeOle()
    check o.readStream("big") == big

suite "ole malformed inputs":
  test "headers fail loudly":
    expect OleError:
      discard openOleBytes(newSeq[byte](0))
    expect OleError:
      discard openOleBytes(@[0xD0'u8, 0xCF, 0x11, 0xE0, 0xA1, 0xB1,
        0x1A, 0xE1]) # magic only, no header
    var bad = newSeq[byte](512)
    expect OleError:
      discard openOleBytes(bad) # bad signature
    var wrongMajor = cfbHeader(2, 1, 1, 4096, -2, 0, -2, 0, [0'i32])
    expect OleError:
      discard openOleBytes(wrongMajor)
    var badShift = cfbHeader(3, 1, 1, 4096, -2, 0, -2, 0, [0'i32])
    patchU32(badShift, 30, 12) # v3 must use shift 9
    expect OleError:
      discard openOleBytes(badShift)

  test "directory defects fail loudly":
    var data = buildMiniCfb(3,
      [cfbDirEnt("Root Entry", 5, -1, -1, 1, -2, 0),
       cfbDirEnt("ok", 2, -1, -1, -1, -2, 0)],
      [CfbEnd, CfbEnd], [])
    const dirBase = 1024 # header 512 + FAT sector 0
    var badChild = data
    patchU32(badChild, dirBase + 76, 99) # root child out of range
    expect OleError:
      discard openOleBytes(badChild).entries()
    var badType = data
    badType[dirBase + 66] = 9 # unknown entry type
    expect OleError:
      discard openOleBytes(badType)
    var notRoot = data
    notRoot[dirBase + 66] = 2 # entry 0 must be the root storage
    expect OleError:
      discard openOleBytes(notRoot)

  test "stream defects fail loudly":
    var data = buildMiniCfb(3,
      [cfbDirEnt("Root Entry", 5, -1, -1, 1, -2, 0),
       cfbDirEnt("s", 2, -1, -1, -1, 99, 10)],
      [CfbEnd, CfbEnd], [])
    let o = openOleBytes(data)
    defer: o.closeOle()
    expect OleError:
      discard o.readStream("s") # start sector out of range
    var bigSize = buildMiniCfb(3,
      [cfbDirEnt("Root Entry", 5, -1, -1, 1, -2, 0),
       cfbDirEnt("huge", 2, -1, -1, -1, -2, 0)],
      [CfbEnd, CfbEnd], [])
    patchU32(bigSize, 1024 + 128 + 120, 0xFFFFFFFF'u32) # > 64MB cap
    let o2 = openOleBytes(bigSize)
    defer: o2.closeOle()
    expect OleError:
      discard o2.readStream("huge")
