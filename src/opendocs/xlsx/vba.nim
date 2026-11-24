## Copyright (c) 2026 nimbase (MIT, see LICENSE at repo root).
## Portions derived from TalentFormula/msdoc `ole2/reader.go`
## (https://github.com/TalentFormula/msdoc, MIT): Copyright (c) 2024
## TalentFormula. SPDX-License-Identifier: MIT
##
## VBA project integration: `xl/vbaProject.bin` through `opendocs/ole2`.
##
## Read-only by design (plan 19): stream listing and bytes only. VBA
## macro semantics (the MS-OVBA-compressed `dir` stream, module source)
## stay explicitly out of scope.
##
## Divergences from plan 19, all documented and tested:
## - Extension consistency is one-directional: a `.xlsx`/`.xltx` carrying
##   a macro part raises (non-conforming and likely misnamed), but a
##   macro-enabled extension without a part is legal (templates, files
##   saved as `.xlsm` without ever holding macros) and passes silently.
##   Plan 19's "must contain" direction would reject real files.
## - `getVbaProject` on a corrupt part fails loudly instead of the
##   plan's implicit tolerant read; the existing
##   "macro-style package opens" test keeps proving the package reader
##   itself stays tolerant (the part rides along untouched).
## - Sheet `state` is not joined (the reader does not parse it);
##   `codeName` is read but, per plan 19, never joined on.

proc hasVbaProject*(f: XlsxFile): bool =
  ## Whether the package carries `xl/vbaProject.bin` (spill-aware).
  f.hasPart("xl/vbaProject.bin")

type
  VbaProject* = object
    ## Listing result. `entries` carry storage paths (`VBA/dir`);
    ## use `readVbaStream` for bytes.
    present*: bool
    entries*: seq[OleEntry]

proc getVbaProject*(f: XlsxFile): VbaProject =
  ## VBA part listing. Absent part yields `present == false`; a present
  ## but unparsable part raises `XlsxError` (failing loudly beats an
  ## empty listing that looks like "no macros").
  if not f.hasVbaProject(): return VbaProject(present: false)
  let raw =
    try: f.readBytesPart("xl/vbaProject.bin")
    except XlsxError as e:
      raise newException(XlsxError,
        "cannot read vbaProject.bin: " & e.msg)
  var o: OleFile
  try:
    o = openOleBytes(raw)
  except OleError as e:
    raise newException(XlsxError,
      "vbaProject.bin is not a valid compound file: " & e.msg)
  try:
    VbaProject(present: true, entries: o.entries())
  finally:
    o.closeOle()

proc readVbaStream*(f: XlsxFile, name: string): seq[byte] =
  ## VBA stream bytes by storage path (`VBA/dir`), case-insensitive.
  ## Absent part, corrupt container, and unknown stream are three
  ## distinguishable `XlsxError`s.
  if not f.hasVbaProject():
    raise newException(XlsxError, "no vbaProject.bin in package")
  let raw =
    try: f.readBytesPart("xl/vbaProject.bin")
    except XlsxError as e:
      raise newException(XlsxError,
        "cannot read vbaProject.bin: " & e.msg)
  var o: OleFile
  try:
    o = openOleBytes(raw)
  except OleError as e:
    raise newException(XlsxError,
      "vbaProject.bin is not a valid compound file: " & e.msg)
  try:
    try:
      o.readStream(name)
    except OleError as e:
      raise newException(XlsxError, e.msg)
  finally:
    o.closeOle()

proc getSheetCodeName*(f: XlsxFile, sheet: string): string =
  ## VBA object name from the sheet's `<sheetPr codeName>`, "" when
  ## absent. Read, never joined on (plan 19).
  getSheet(f, sheet).codeName

proc checkVbaConsistency*(f: XlsxFile, ext: string) =
  ## Extension gate for macro parts. A strict `.xlsx`/`.xltx` carrying
  ## `vbaProject.bin` is non-conforming (likely misnamed) and raises;
  ## every other combination passes silently, including macro-enabled
  ## extensions without a part (legal: templates, macro-less saves).
  ## `ext` is a bare extension or filename fragment (`".xlsx"`,
  ## `"report.XLSM"`); unrecognized or empty extensions are no-ops.
  var e = ext.toLowerAscii()
  let dot = e.rfind('.')
  if dot >= 0: e = e[dot + 1 .. ^1]
  if (e == "xlsx" or e == "xltx") and f.hasVbaProject():
    raise newException(XlsxError,
      "strict workbook (." & e & ") must not contain vbaProject.bin")
