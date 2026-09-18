## Perf harness for the DOCX reader: wall time + peak RSS baselines.
##
## Run from the package root:
##   clue build examples/docx_perf.nim --out:/tmp/docx_perf && /tmp/docx_perf
##
## Compares runs against committed baselines only loosely (CI machines
## vary); the point is before/after comparison on the same machine.

import std/[monotimes, os, strutils, tempfiles, times]
import opendocs/docx
import opendocs/zip

when defined(macosx):
  import std/posix
  proc peakRssMB(): float =
    var u: Rusage
    discard getrusage(RUSAGE_SELF, addr u)
    u.ru_maxrss.float / (1024.0 * 1024.0) # bytes on macOS
else:
  import std/posix
  proc peakRssMB(): float =
    var u: Rusage
    discard getrusage(RUSAGE_SELF, addr u)
    u.ru_maxrss.float / 1024.0 # kilobytes on Linux

proc bench(name: string, reps: int, body: proc(): int) =
  let t0 = getMonoTime()
  var totalBlocks = 0
  for _ in 1 .. reps:
    totalBlocks += body()
  let dt = (getMonoTime() - t0).inMilliseconds.float / 1000.0
  echo name, ": reps=", reps, " time=", dt.formatFloat(ffDecimal, 3), "s",
    " per-parse=", (dt * 1000 / reps.float).formatFloat(ffDecimal, 1), "ms",
    " blocks=", totalBlocks div reps, " peakRSS=", peakRssMB().formatFloat(ffDecimal, 1), "MB"

proc makeBigDocx(path: string, paras: int) =
  var body = ""
  for i in 1 .. paras:
    body.add "<w:p><w:pPr><w:pStyle w:val=\"Normal\"/></w:pPr><w:r><w:rPr><w:b/><w:sz w:val=\"24\"/></w:rPr><w:t xml:space=\"preserve\">Paragraph number " &
      $i & " with some body text to inflate the document size. </w:t></w:r></w:p>"
  let docXml = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>""" &
    body & """<w:sectPr><w:pgSz w:w="11906" w:h="16838"/></w:sectPr></w:body></w:document>"""
  var w = newZipWriter()
  w.addFile("word/document.xml", docXml)
  w.writeZip(path)
  echo "synthetic: ", path, " docxBytes=", getFileSize(path),
    " xmlBytes=", docXml.len

proc main() =
  let fixDir = currentSourcePath().parentDir() / ".." / "tests" /
    "fixtures" / "docx"
  bench("hello.docx", 20, proc(): int =
    readDocx(fixDir / "hello.docx").blocks.len)
  bench("comment.docx", 20, proc(): int =
    readDocx(fixDir / "comment.docx").blocks.len)
  let dir = createTempDir("opendocs_", "_perf")
  defer: removeDir(dir)
  let big = dir / "big.docx"
  makeBigDocx(big, 20000) # ~5MB XML
  bench("synthetic-5MB", 3, proc(): int =
    readDocx(big).blocks.len)
  bench("repeat-50x-hello", 1, proc(): int =
    var n = 0
    for _ in 1 .. 50:
      n += readDocx(fixDir / "hello.docx").blocks.len
    n)

when isMainModule:
  main()
