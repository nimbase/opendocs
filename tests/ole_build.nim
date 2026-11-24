## Shared synthetic CFB builder for OLE tests.
##
## Hand-rolled minimal compound files (header + FAT + directory + data)
## with ASCII-only entry names. Real-world shapes (MiniFAT content,
## red-black imbalance, large DIFATs) come from the checked-in
## `tests/fixtures/ole/vbaProject.bin` instead.

import std/[strutils]

proc putU16le(dst: var seq[byte], off: int, v: uint16) =
  dst[off] = byte(v and 0xFF)
  dst[off + 1] = byte((v shr 8) and 0xFF)

proc putU32le(dst: var seq[byte], off: int, v: uint32) =
  dst[off] = byte(v and 0xFF)
  dst[off + 1] = byte((v shr 8) and 0xFF)
  dst[off + 2] = byte((v shr 16) and 0xFF)
  dst[off + 3] = byte((v shr 24) and 0xFF)

proc putI32le(dst: var seq[byte], off: int, v: int32) =
  putU32le(dst, off, cast[uint32](v))

proc cfbHeader*(major: int, numFat, firstDir, cutoff: int,
    firstMiniFat, numMiniFat, firstDifat, numDifat: int,
    difat: openArray[int32], sectorSize = 512): seq[byte] =
  ## 512-byte header. `major` 3 = 512B sectors, 4 = 4096B sectors.
  result = newSeq[byte](512)
  for i, b in [0xD0'u8, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]:
    result[i] = b
  putU16le(result, 24, 0) # minor
  putU16le(result, 26, major.uint16)
  putU16le(result, 28, 0xFFFE'u16)
  putU16le(result, 30, if major == 3: 9'u16 else: 12'u16)
  putU16le(result, 32, 6'u16)
  putU32le(result, 40, 1) # num directory sectors (v3 informational)
  putU32le(result, 44, numFat.uint32)
  putI32le(result, 48, firstDir.int32)
  putU32le(result, 56, cutoff.uint32)
  putI32le(result, 60, firstMiniFat.int32)
  putU32le(result, 64, numMiniFat.uint32)
  putI32le(result, 68, firstDifat.int32)
  putU32le(result, 72, numDifat.uint32)
  for i in 0 ..< 109:
    let s = if i < difat.len: difat[i] else: -1'i32
    putI32le(result, 76 + i * 4, s)

proc cfbDirEnt*(name: string, typ: byte, left, right, child: int32,
    start: int32, size: int64): seq[byte] =
  ## One 128-byte directory entry. ASCII names only (test scope).
  result = newSeq[byte](128)
  doAssert name.len <= 31
  for i, ch in name:
    result[i * 2] = byte(ch.ord)
  putU16le(result, 64, uint16((name.len + 1) * 2))
  result[66] = typ
  result[67] = 1 # black
  putI32le(result, 68, left)
  putI32le(result, 72, right)
  putI32le(result, 76, child)
  putU32le(result, 96, 0) # state
  putI32le(result, 116, start)
  putU32le(result, 120, uint32(size and 0xFFFFFFFF))
  putU32le(result, 124, uint32(size shr 32))

proc cfbFatSector*(vals: openArray[uint32],
    sectorSize = 512): seq[byte] =
  ## One FAT sector image (FREE-filled past `vals`).
  result = newSeq[byte](sectorSize)
  for i in 0 ..< sectorSize div 4: putU32le(result, i * 4, 0xFFFFFFFF'u32)
  for i, v in vals: putU32le(result, i * 4, v)

proc patchU32*(data: var seq[byte], off: int, v: uint32) =
  putU32le(data, off, v)

const
  CfbFree* = 0xFFFFFFFF'u32
  CfbEnd* = 0xFFFFFFFE'u32

proc buildMiniCfb*(major: int,
    dirEnts: openArray[seq[byte]],
    fatVals: openArray[uint32],
    dataSectors: openArray[seq[byte]],
    cutoff = 4096): seq[byte] =
  ## Assemble a single-FAT-sector CFB: header, FAT, directory, data.
  ## `dataSectors` land at consecutive sector numbers after the
  ## directory. All sizes must fit their sectors; directory entries
  ## reference absolute sector numbers.
  let ss = if major == 3: 512 else: 4096
  let perFat = ss div 4
  doAssert fatVals.len <= perFat
  let dirSecs = (dirEnts.len * 128 + ss - 1) div ss
  let firstDir = 1
  result = cfbHeader(major, 1, firstDir, cutoff, -2, 0, -2, 0,
    [0'i32], ss)
  result.add cfbFatSector(fatVals, ss)
  for e in dirEnts: result.add e
  let dirPad = dirSecs * ss - dirEnts.len * 128
  for _ in 0 ..< dirPad: result.add 0'u8
  for s in dataSectors:
    doAssert s.len <= ss
    result.add s
    for _ in s.len ..< ss: result.add 0'u8
