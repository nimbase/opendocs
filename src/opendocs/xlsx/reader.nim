## Spreadsheet `.xlsx` etc. reader: package open flow.
##
## Shared XML/part helpers live in `xlsx/base` (included before the
## part readers); the open flow runs last so it can call them.

const oleMagic: array[8, byte] =
  [0xD0'u8, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]

proc openXlsxBytes*(data: seq[byte],
    opts: XlsxReadOpts = XlsxReadOpts()): XlsxFile =
  ## Open a spreadsheet package from memory. All five OOXML variants
  ## (`xlsx/xlsm/xltx/xltm/xlam`) share the generic zip+rels flow; macro
  ## parts (`xl/vbaProject.bin`) ride along untouched. Raises XlsxError
  ## for corrupt packages; encrypted (OLE) inputs are rejected, never
  ## silently misread.
  if data.len >= 8 and data[0 .. 7] == @oleMagic:
    raise newException(XlsxError,
      "encrypted or legacy OLE package: password-protected workbooks " &
      "are not supported")
  var archive: ZipArchive
  try:
    archive = openZipBytes(data)
  except ZipError as e:
    raise newException(XlsxError, "not a spreadsheet package: " & e.msg)
  result = XlsxFile(archive: archive, opts: opts)
  # Spill decision on total inflated size (same policy as docx).
  var totalInflated = 0
  for e in archive.entries: totalInflated += e.uncompressedSize
  let spill = opts.spillThresholdBytes == 0 or
    (opts.spillThresholdBytes > 0 and
      totalInflated > opts.spillThresholdBytes)
  if spill:
    let base = if opts.spillDir == "": getTempDir() else: opts.spillDir
    try:
      result.spillDir = createTempDir("opendocs_", "_spill", base)
    except OSError as e:
      raise newException(XlsxError, "cannot create spill dir: " & e.msg)
    var remaining =
      if opts.spillCapBytes > 0: opts.spillCapBytes
      else: DefaultXlsxSpillCapBytes
    for i, e in archive.entries:
      if e.uncompressedSize > remaining:
        try: removeDir(result.spillDir)
        except OSError: discard
        result.spillDir = ""
        raise newException(XlsxError, "spill cap exceeded by: " & e.name)
      try:
        archive.extractEntryToFile(i, result.spillDir / spillName(e.name))
      except ZipError as e2:
        raise newException(XlsxError,
          "cannot spill " & e.name & ": " & e2.msg)
      remaining -= e.uncompressedSize
  loadWorkbook(result)
  loadStyles(result)

proc openXlsx*(path: string,
    opts: XlsxReadOpts = XlsxReadOpts()): XlsxFile =
  ## Open a spreadsheet file from disk.
  var fh: File
  if not open(fh, path, fmRead):
    raise newException(XlsxError, "cannot open file: " & path)
  defer: close(fh)
  let size = getFileSize(fh).int
  var data = newSeq[byte](size)
  if size > 0 and readBytes(fh, data, 0, size) != size:
    raise newException(XlsxError, "short read: " & path)
  openXlsxBytes(data, opts)

proc closeXlsx*(f: XlsxFile) =
  ## Release the spill dir, if any. Safe to call twice or on nil.
  if f == nil or f.spillDir == "": return
  try: removeDir(f.spillDir)
  except OSError: discard
  f.spillDir = ""
