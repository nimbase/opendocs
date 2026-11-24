## Page previews via poppler (M19 render harness, phase 0 only).
##
## `renderPagePreview` shells to `pdftoppm` when present and returns PNG
## bytes. poppler renders this, not opendocs: output fidelity is
## poppler's, including how it interprets our modifications. Tool
## absence, non-zero exits and missing output all fail loudly; temp
## files are removed afterwards. The password travels on the command
## line (visible to process listings on multi-user machines).
##
## Divergence from plan 10: the harness shells to pdftoppm instead of
## binding libvips. opendocs has no dependency path to the libvips
## package in this workspace, and linking it would break hermetic
## builds where libvips is absent. The contract is identical (honestly
## named, capability-probed, poppler-backed).

import std/os
import std/osproc
import std/strutils
import std/sysrand
import std/times
import ./types
import ./lexer

proc hasPdftoppm*(): bool =
  findExe("pdftoppm").len > 0

proc tempPdfPath(): string =
  var tag = $toUnix(getTime())
  for b in urandom(8):
    tag.add(toHex(int(b), 2))
  getTempDir() / ("opendocs_preview_" & tag & ".pdf")

proc renderPagePreview*(data: string, page = 0, dpi = 150.0,
    password = ""): string =
  ## PNG bytes of one 0-based page at `dpi`. Needs poppler installed.
  if page < 0:
    pdfFail("preview page must not be negative")
  if dpi <= 0.0 or dpi != dpi or dpi == Inf or dpi == -Inf:
    pdfFail("preview dpi must be positive")
  let exe = findExe("pdftoppm")
  if exe.len == 0:
    pdfFail("poppler pdftoppm not found on PATH (page previews need it)")
  let tmpPath = tempPdfPath()
  writeFile(tmpPath, data)
  let outPrefix = tmpPath & "_out"
  var cmd = exe & " -png -r " & $dpi & " -f " & $(page + 1) &
    " -l " & $(page + 1) & " -singlefile"
  if password.len > 0:
    cmd.add(" -upw " & quoteShell(password))
  cmd.add(" " & quoteShell(tmpPath) & " " & quoteShell(outPrefix))
  let (outp, code) = execCmdEx(cmd)
  let pngPath = outPrefix & ".png"
  var png = ""
  if code == 0 and fileExists(pngPath):
    png = readFile(pngPath)
  try:
    removeFile(tmpPath)
  except OSError:
    discard
  try:
    removeFile(pngPath)
  except OSError:
    discard
  if code != 0:
    pdfFail("pdftoppm failed (" & $code & "): " & outp.strip())
  if png.len == 0:
    pdfFail("pdftoppm produced no output")
  png
