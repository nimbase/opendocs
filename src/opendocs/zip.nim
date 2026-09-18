## Minimal ZIP reader/writer for OOXML/ODF containers.
##
## Built on `zlib/zlib_api` (raw deflate + crc32). Whole-file in memory;
## office documents are small enough that streaming is not worth it yet.
## No ZIP64 support (raises ZipError); deflated + stored methods only.

import std/[times, strutils]
import zlib/zlib_api

type
  ZipError* = object of IOError

  ZipMethod* = enum
    zmStored = 0
    zmDeflated = 8

  ZipEntry* = object
    name*: string
    compressMethod*: ZipMethod
    compressedSize*: int
    uncompressedSize*: int
    crc*: uint32
    dataOffset*: int ## offset of entry raw data inside archive bytes

  ZipArchive* = object
    data*: seq[byte]
    entries*: seq[ZipEntry]

  ZipWriter* = object
    files: seq[tuple[name: string, meth: ZipMethod, data: seq[byte]]]

const
  DefaultMaxEntryBytes* = 64 * 1024 * 1024 ## zip-bomb guard per entry

  sigLocal = 0x04034B50'u32
  sigCentral = 0x02014B50'u32
  sigEocd = 0x06054B50'u32
  flagDataDescriptor = 0x08'u16
  flagUtf8 = 0x0800'u16

# ---------------------------------------------------------------- little-endian

func u16le(b: openArray[byte], off: int): uint16 =
  uint16(b[off]) or (uint16(b[off + 1]) shl 8)

func u32le(b: openArray[byte], off: int): uint32 =
  uint32(b[off]) or (uint32(b[off + 1]) shl 8) or
    (uint32(b[off + 2]) shl 16) or (uint32(b[off + 3]) shl 24)

func putU16le(dst: var seq[byte], v: uint16) =
  dst.add byte(v and 0xFF)
  dst.add byte((v shr 8) and 0xFF)

func putU32le(dst: var seq[byte], v: uint32) =
  dst.add byte(v and 0xFF)
  dst.add byte((v shr 8) and 0xFF)
  dst.add byte((v shr 16) and 0xFF)
  dst.add byte((v shr 24) and 0xFF)

# ---------------------------------------------------------------- raw deflate

proc deflateRaw*(data: openArray[byte],
    level: ZLevel = Z_DEFAULT_LEVEL): seq[byte] =
  ## Compress with raw deflate (no zlib/gzip wrapper), as ZIP requires.
  if data.len == 0:
    # Valid empty deflate stream (fixed Huffman empty block).
    return @[3'u8, 0]
  var strm = ZStream(
    next_in: cast[ptr uint8](unsafeAddr data[0]),
    avail_in: data.len.cuint)
  var r = strm.deflateInit2(level, Z_DEFLATED, Z_RAW_DEFLATE,
    Z_DEFAULT_MEM_LEVEL, Z_DEFAULT_STRATEGY)
  if r != Z_OK:
    raise newException(ZipError, "deflateInit failed: " & $r)
  var outBuf = newSeq[byte](strm.deflateBound(data.len.culong).int)
  strm.next_out = cast[ptr uint8](addr outBuf[0])
  strm.avail_out = outBuf.len.cuint
  r = strm.deflate(Z_FINISH)
  if r != Z_STREAM_END:
    discard strm.deflateEnd()
    raise newException(ZipError, "deflate failed: " & $r)
  outBuf.setLen(strm.total_out.int)
  r = strm.deflateEnd()
  if r != Z_OK:
    raise newException(ZipError, "deflateEnd failed: " & $r)
  outBuf

proc inflateRawInto*(data: openArray[byte], dest: var seq[byte],
    maxSize = DefaultMaxEntryBytes) =
  ## Decompress a raw deflate stream into `dest` (cleared first),
  ## capped at maxSize bytes. Reuse `dest` across calls to avoid
  ## repeated allocator trips.
  dest.setLen(0) # retain capacity for reuse across calls
  if data.len == 0:
    return
  var strm = ZStream(
    next_in: cast[ptr uint8](unsafeAddr data[0]),
    avail_in: data.len.cuint)
  var r = strm.inflateInit2(Z_RAW_DEFLATE)
  if r != Z_OK:
    raise newException(ZipError, "inflateInit failed: " & $r)
  var chunk: array[65536, byte]
  while true:
    strm.next_out = cast[ptr uint8](addr chunk[0])
    strm.avail_out = chunk.len.cuint
    r = strm.inflate(Z_SYNC_FLUSH)
    let got = chunk.len - strm.avail_out.int
    if dest.len + got > maxSize:
      discard strm.inflateEnd()
      raise newException(ZipError, "entry exceeds decompression limit")
    dest.add toOpenArray(chunk, 0, got - 1)
    if r == Z_STREAM_END:
      break
    elif r == Z_OK:
      if strm.avail_in == 0:
        # Needs more input but there is none: truncated stream.
        discard strm.inflateEnd()
        raise newException(ZipError, "truncated deflate stream")
      continue # output chunk was full; keep going
    else:
      discard strm.inflateEnd()
      raise newException(ZipError, "inflate failed: " & $r)
  discard strm.inflateEnd()

proc inflateRaw*(data: openArray[byte], maxSize = DefaultMaxEntryBytes): seq[byte] =
  ## Decompress a raw deflate stream, capped at maxSize bytes.
  result = newSeqOfCap[byte](min(data.len * 3, 65536))
  inflateRawInto(data, result, maxSize)

# ---------------------------------------------------------------- path safety

func checkNameSafe(name: string) =
  ## Zip-slip guard shared by reader and writer.
  if name.len == 0 or name[0] == '/' or name[0] == '\\':
    raise newException(ZipError, "unsafe zip path: " & name)
  if ':' in name: # windows drive letter
    raise newException(ZipError, "unsafe zip path: " & name)
  for part in name.split({'/', '\\'}):
    if part == "..":
      raise newException(ZipError, "unsafe zip path: " & name)

# ---------------------------------------------------------------- reader

proc findEocd(data: seq[byte]): int =
  # EOCD is at least 22 bytes; comment can push it back at most 64KB.
  if data.len < 22:
    raise newException(ZipError, "too small to be a zip file")
  let lo = max(0, data.len - (65536 + 22))
  var i = data.len - 22
  while i >= lo:
    if u32le(data, i) == sigEocd:
      return i
    dec i
  raise newException(ZipError, "end-of-central-directory not found")

proc openZipBytes*(data: seq[byte]): ZipArchive =
  ## Parse the central directory. Entry data stays in `data` (owned copy).
  let eocd = findEocd(data)
  let diskEntries = u16le(data, eocd + 8).int
  let centralSize = u32le(data, eocd + 12).int
  let centralOff = u32le(data, eocd + 16).int
  if centralOff + centralSize > data.len:
    raise newException(ZipError, "central directory out of bounds")
  if diskEntries == 0xFFFF:
    raise newException(ZipError, "ZIP64 not supported")
  result.data = data
  var off = centralOff
  for _ in 0 ..< diskEntries:
    if off + 46 > data.len or u32le(data, off) != sigCentral:
      raise newException(ZipError, "bad central directory entry")
    let flags = u16le(data, off + 8)
    let methRaw = u16le(data, off + 10).int
    let crc = u32le(data, off + 16)
    let compSize = u32le(data, off + 20).int
    let uncompSize = u32le(data, off + 24).int
    let nameLen = u16le(data, off + 28).int
    let extraLen = u16le(data, off + 30).int
    let commentLen = u16le(data, off + 32).int
    let localOff = u32le(data, off + 42).int
    if compSize == 0xFFFFFFFF or uncompSize == 0xFFFFFFFF or
        localOff == 0xFFFFFFFF:
      raise newException(ZipError, "ZIP64 not supported")
    if off + 46 + nameLen > data.len:
      raise newException(ZipError, "central directory entry truncated")
    var name = newString(nameLen)
    for i in 0 ..< nameLen:
      name[i] = char(data[off + 46 + i])
    checkNameSafe(name)
    # Resolve data offset from the local header.
    if localOff + 30 > data.len or u32le(data, localOff) != sigLocal:
      raise newException(ZipError, "bad local header for: " & name)
    let lhNameLen = u16le(data, localOff + 26).int
    let lhExtraLen = u16le(data, localOff + 28).int
    let dataOff = localOff + 30 + lhNameLen + lhExtraLen
    if dataOff + compSize > data.len:
      raise newException(ZipError, "entry data out of bounds: " & name)
    let meth =
      case methRaw
      of 0: zmStored
      of 8: zmDeflated
      else: raise newException(ZipError,
        "unsupported method " & $methRaw & " for: " & name)
    discard flags # bit 3 (data descriptor) tolerated: sizes come from here
    result.entries.add ZipEntry(name: name, compressMethod: meth,
      compressedSize: compSize, uncompressedSize: uncompSize,
      crc: crc, dataOffset: dataOff)
    off += 46 + nameLen + extraLen + commentLen

proc openZip*(path: string): ZipArchive =
  ## Read and parse a `.zip` / OOXML / ODF file.
  var f: File
  if not open(f, path, fmRead):
    raise newException(ZipError, "cannot open file: " & path)
  defer: close(f)
  let size = getFileSize(f).int
  var data = newSeq[byte](size)
  if size > 0 and readBytes(f, data, 0, size) != size:
    raise newException(ZipError, "short read: " & path)
  openZipBytes(data)

proc filenames*(a: ZipArchive): seq[string] =
  for e in a.entries: result.add e.name

proc findEntry*(a: ZipArchive, name: string): int =
  for i, e in a.entries:
    if e.name == name: return i
  -1

proc readEntryInto*(a: ZipArchive, idx: int, dest: var seq[byte],
    maxSize = DefaultMaxEntryBytes) =
  ## Extract + CRC-verify entry `idx` into `dest`. Output is sized
  ## exactly (no geometric regrowth); `dest` capacity is retained
  ## across calls for reuse.
  if idx < 0 or idx >= a.entries.len:
    raise newException(ZipError, "entry index out of range")
  let e = a.entries[idx]
  if e.uncompressedSize > maxSize:
    raise newException(ZipError, "entry exceeds decompression limit: " & e.name)
  # NB: dataOffset/compressedSize bounds were validated at openZipBytes.
  if e.compressedSize == 0:
    dest.setLen(0)
  else:
    case e.compressMethod
    of zmStored:
      dest.setLen(e.compressedSize)
      copyMem(addr dest[0], unsafeAddr a.data[e.dataOffset],
        e.compressedSize)
    of zmDeflated:
      if e.uncompressedSize == 0:
        dest.setLen(0)
        # Claims input but no output: still run the stream to surface
        # corrupt-data errors rather than silently accepting it.
        discard inflateRaw(a.data.toOpenArray(e.dataOffset,
          e.dataOffset + e.compressedSize - 1), maxSize)
      else:
        dest.setLen(e.uncompressedSize)
        var strm = ZStream(
          next_in: cast[ptr uint8](unsafeAddr a.data[e.dataOffset]),
          avail_in: e.compressedSize.cuint)
        var r = strm.inflateInit2(Z_RAW_DEFLATE)
        if r != Z_OK:
          raise newException(ZipError, "inflateInit failed: " & $r)
        strm.next_out = cast[ptr uint8](addr dest[0])
        strm.avail_out = e.uncompressedSize.cuint
        var produced = 0
        while true:
          r = strm.inflate(Z_SYNC_FLUSH)
          produced = e.uncompressedSize - strm.avail_out.int
          if r == Z_STREAM_END:
            break
          elif r == Z_OK:
            if strm.avail_in == 0:
              discard strm.inflateEnd()
              raise newException(ZipError, "truncated deflate stream")
            discard strm.inflateEnd()
            raise newException(ZipError,
              "size mismatch for: " & e.name)
          else:
            discard strm.inflateEnd()
            raise newException(ZipError, "inflate failed: " & $r)
        discard strm.inflateEnd()
        dest.setLen(produced)
  if dest.len != e.uncompressedSize:
    raise newException(ZipError, "size mismatch for: " & e.name)
  if crc32(dest).uint32 != e.crc:
    raise newException(ZipError, "CRC mismatch for: " & e.name)

proc readEntryByIndex*(a: ZipArchive, idx: int,
    maxSize = DefaultMaxEntryBytes): seq[byte] =
  ## Extract + CRC-verify entry `idx`.
  a.readEntryInto(idx, result, maxSize)

proc extractEntryToFile*(a: ZipArchive, idx: int, path: string,
    maxSize = DefaultMaxEntryBytes) =
  ## Stream-extract entry `idx` to `path` in 64KB chunks (constant
  ## memory), CRC-verified. Raises ZipError on any failure.
  if idx < 0 or idx >= a.entries.len:
    raise newException(ZipError, "entry index out of range")
  let e = a.entries[idx]
  if e.uncompressedSize > maxSize:
    raise newException(ZipError, "entry exceeds decompression limit: " & e.name)
  var f: File
  if not open(f, path, fmWrite):
    raise newException(ZipError, "cannot write file: " & path)
  try:
    var written = 0
    var crc = Z_CRC32_INIT
    case e.compressMethod
    of zmStored:
      let lo = e.dataOffset
      var off = 0
      while off < e.compressedSize:
        let n = min(65536, e.compressedSize - off)
        if writeBuffer(f, unsafeAddr a.data[lo + off], n) != n:
          raise newException(ZipError, "short write: " & path)
        crc = crc32(crc, unsafeAddr a.data[lo + off], n.cuint)
        off += n
        written += n
    of zmDeflated:
      if e.compressedSize > 0:
        var strm = ZStream(
          next_in: cast[ptr uint8](unsafeAddr a.data[e.dataOffset]),
          avail_in: e.compressedSize.cuint)
        var r = strm.inflateInit2(Z_RAW_DEFLATE)
        if r != Z_OK:
          raise newException(ZipError, "inflateInit failed: " & $r)
        var chunk: array[65536, byte]
        while true:
          strm.next_out = cast[ptr uint8](addr chunk[0])
          strm.avail_out = chunk.len.cuint
          r = strm.inflate(Z_SYNC_FLUSH)
          let got = chunk.len - strm.avail_out.int
          if written + got > maxSize:
            discard strm.inflateEnd()
            raise newException(ZipError, "entry exceeds decompression limit")
          if got > 0:
            if writeBuffer(f, addr chunk[0], got) != got:
              discard strm.inflateEnd()
              raise newException(ZipError, "short write: " & path)
            crc = crc32(crc, addr chunk[0], got.cuint)
            written += got
          if r == Z_STREAM_END:
            break
          elif r == Z_OK:
            if strm.avail_in == 0:
              discard strm.inflateEnd()
              raise newException(ZipError, "truncated deflate stream")
            continue
          else:
            discard strm.inflateEnd()
            raise newException(ZipError, "inflate failed: " & $r)
        discard strm.inflateEnd()
    if written != e.uncompressedSize:
      raise newException(ZipError, "size mismatch for: " & e.name)
    if crc.uint32 != e.crc:
      raise newException(ZipError, "CRC mismatch for: " & e.name)
  finally:
    close(f)

proc readEntry*(a: ZipArchive, name: string,
    maxSize = DefaultMaxEntryBytes): seq[byte] =
  let idx = a.findEntry(name)
  if idx < 0:
    raise newException(ZipError, "entry not found: " & name)
  a.readEntryByIndex(idx, maxSize)

# ---------------------------------------------------------------- writer

proc newZipWriter*(): ZipWriter = ZipWriter()

proc findEntry*(w: ZipWriter, name: string): int =
  for i, f in w.files:
    if f.name == name: return i
  -1

proc addFile*(w: var ZipWriter, name: string, data: seq[byte],
    meth: ZipMethod = zmDeflated) =
  ## Queue a file. Directory names must end with `/` and carry empty data.
  checkNameSafe(name)
  if w.findEntry(name) >= 0:
    raise newException(ZipError, "duplicate entry: " & name)
  w.files.add (name, meth, data)

proc addFile*(w: var ZipWriter, name: string, data: string,
    meth: ZipMethod = zmDeflated) =
  var b = newSeq[byte](data.len)
  for i, c in data: b[i] = byte(c)
  w.addFile(name, b, meth)

proc dosDateTime(): tuple[time, date: uint16] =
  let n = now().utc()
  let t = (uint16(n.hour) shl 11) or (uint16(n.minute) shl 5) or
    uint16(n.second div 2)
  let d = (uint16(max(n.year - 1980, 0)) shl 9) or (uint16(n.month.ord) shl 5) or
    uint16(n.monthday)
  (t, d)

proc toBytes*(w: ZipWriter): seq[byte] =
  ## Serialize queued files to a complete ZIP image.
  let (dosTime, dosDate) = dosDateTime()
  var central: seq[byte]
  for f in w.files:
    let isDir = f.name.endsWith("/")
    var nameBytes = newSeq[byte](f.name.len)
    for i, c in f.name: nameBytes[i] = byte(c)
    let meth = if isDir: zmStored else: f.meth
    let comp: seq[byte] =
      if isDir or f.data.len == 0 and meth == zmStored: @[]
      elif meth == zmStored: f.data
      else: deflateRaw(f.data)
    let crc = crc32(f.data).uint32
    let localOff = result.len.uint32
    # local header
    result.putU32le(sigLocal)
    result.putU16le(20) # version needed
    result.putU16le(flagUtf8)
    result.putU16le(meth.ord.uint16)
    result.putU16le(dosTime)
    result.putU16le(dosDate)
    result.putU32le(crc)
    result.putU32le(comp.len.uint32)
    result.putU32le(f.data.len.uint32)
    result.putU16le(nameBytes.len.uint16)
    result.putU16le(0) # extra len
    result.add nameBytes
    result.add comp
    # central header
    central.putU32le(sigCentral)
    central.putU16le(63) # version made by: unix, 6.3
    central.putU16le(20)
    central.putU16le(flagUtf8)
    central.putU16le(meth.ord.uint16)
    central.putU16le(dosTime)
    central.putU16le(dosDate)
    central.putU32le(crc)
    central.putU32le(comp.len.uint32)
    central.putU32le(f.data.len.uint32)
    central.putU16le(nameBytes.len.uint16)
    central.putU16le(0) # extra
    central.putU16le(0) # comment
    central.putU16le(0) # disk
    central.putU16le(0) # internal attrs
    central.putU32le(if isDir: 0o755 shl 16 or 0x10'u32
                     else: 0o644 shl 16) # external attrs
    central.putU32le(localOff)
    central.add nameBytes
  let centralOff = result.len
  result.add central
  # end of central directory
  result.putU32le(sigEocd)
  result.putU16le(0) # disk number
  result.putU16le(0) # central start disk
  result.putU16le(w.files.len.uint16)
  result.putU16le(w.files.len.uint16)
  result.putU32le(central.len.uint32)
  result.putU32le(centralOff.uint32)
  result.putU16le(0) # comment len

proc writeZip*(w: ZipWriter, path: string) =
  let img = w.toBytes()
  var f: File
  if not open(f, path, fmWrite):
    raise newException(ZipError, "cannot write file: " & path)
  defer: close(f)
  if img.len > 0 and writeBytes(f, img, 0, img.len) != img.len:
    raise newException(ZipError, "short write: " & path)
