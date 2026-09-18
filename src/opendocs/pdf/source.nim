## File-byte source for the PDF reader: owned string or mmap.
##
## Large documents stay out of the Nim heap: the lexer, COS parser,
## xref scanner and registry read directly from the mapped region and
## only copy the small slices they keep (names, strings, stream bodies
## the caller actually resolves). A source built from a string is a
## zero-copy view of that string's buffer; the string is retained in
## `owned` so the view stays alive as long as the source does.
##
## A mapped source is closed with `close` (idempotent). Using a
## document after its source is closed raises Defect.

import std/memfiles
import ./types

type
  PdfMapHandle = ref object
    mf: MemFile
    closed: bool

  PdfSource* = object
    base*: pointer ## first byte; nil when empty or after close
    slen*: int
    owned*: string ## retains a viewed string buffer
    map*: PdfMapHandle ## retains a file mapping (nil for strings)

proc len*(src: PdfSource): int {.inline.} = src.slen

proc checkLive(src: PdfSource) {.inline.} =
  # Map state lives behind a shared handle, so copies of a source
  # fail loudly too instead of touching unmapped memory.
  if src.map != nil and src.map.closed:
    raise newException(Defect, "PDF source is closed")
  if src.base == nil and src.slen > 0:
    raise newException(Defect, "PDF source is closed")

proc `[]`*(src: PdfSource, i: int): char {.inline.} =
  if i < 0 or i >= src.slen:
    raise newException(RangeDefect, "PDF source index out of range: " & $i)
  src.checkLive()
  cast[ptr UncheckedArray[char]](src.base)[i]

proc slice*(src: PdfSource, a, b: int): string =
  ## Copy of bytes [a, b). Out-of-range slices raise RangeDefect;
  ## corrupt-input truncation is reported as PdfError by callers
  ## before slicing.
  if a < 0 or b < a or b > src.slen:
    raise newException(RangeDefect,
      "PDF source slice out of range: " & $a & "..<" & $b)
  result = newString(b - a)
  if b > a:
    src.checkLive()
    copyMem(addr result[0], cast[pointer](cast[int](src.base) + a), b - a)

proc continuesWithAt*(src: PdfSource, kw: string, pos: int): bool =
  if pos < 0 or pos + kw.len > src.slen:
    return false
  if kw.len == 0:
    return true
  src.checkLive()
  equalMem(cast[pointer](cast[int](src.base) + pos), unsafeAddr kw[0],
    kw.len)

proc fromString*(s: string): PdfSource =
  ## Zero-copy view of `s`. The source retains `s`, so the caller may
  ## drop its own reference.
  if s.len == 0:
    PdfSource(base: nil, slen: 0, owned: s)
  else:
    PdfSource(base: unsafeAddr s[0], slen: s.len, owned: s)

proc mapFile*(path: string): PdfSource =
  ## Memory-map `path` for reading. Raises IOError when the file
  ## cannot be mapped (missing file, non-regular file, no permission).
  ## Empty files map to an empty source without touching memfiles.
  var f: File
  if not open(f, path, fmRead):
    raise newException(IOError, "cannot open PDF file: " & path)
  let size = getFileSize(f)
  close(f)
  if size == 0:
    return PdfSource(base: nil, slen: 0)
  var mf =
    try:
      memfiles.open(path, fmRead)
    except CatchableError as e:
      raise newException(IOError,
        "cannot memory-map PDF file " & path & ": " & e.msg)
  if mf.size == 0:
    mf.close()
    return PdfSource(base: nil, slen: 0)
  PdfSource(base: mf.mem, slen: mf.size,
    map: PdfMapHandle(mf: mf))

proc fromFile*(path: string): PdfSource =
  ## `mapFile`, falling back to a heap copy when the file cannot be
  ## mapped (pipes, odd filesystems). Never fails except on missing
  ## or unreadable files.
  try:
    mapFile(path)
  except IOError:
    fromString(readFile(path))

proc isMapped*(src: PdfSource): bool {.inline.} =
  src.map != nil

proc close*(src: var PdfSource) =
  ## Unmap a mapped source. Idempotent; string views need no action.
  if src.map != nil and not src.map.closed:
    src.map.closed = true
    src.map.mf.close()
  src.map = nil
  src.base = nil
