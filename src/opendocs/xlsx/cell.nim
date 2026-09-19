## Copyright (c) 2026 nimbase (MIT, see LICENSE at repo root).
## Portions derived from excelize (https://github.com/qax-os/excelize,
## commit 0434413, 2026-09-18): Copyright (c) 2016-2026 The excelize
## Authors, Copyright (c) 2011-2017 Geoffrey J. Teale, BSD-3-Clause.
## SPDX-License-Identifier: MIT AND BSD-3-Clause
##
## A1 cell references and cell-type mapping (ports of excelize `lib.go`
## `SplitCellName`/`JoinCellName`/`ColumnNameToNumber` and the `cellTypes`
## map in `cell.go`).

func cellTypeOf*(t: string): CellType =
  ## Map a `c/@t` value to `CellType`. Absent/unknown maps to `ctyUnset`
  ## (excelize `CellTypeUnset`); resolution still treats it as numeric.
  case t
  of "b": ctyBool
  of "d": ctyDate
  of "e": ctyError
  of "n": ctyNumber
  of "s": ctySharedString
  of "str": ctyFormula
  of "inlineStr": ctyInlineString
  else: ctyUnset

proc columnNameToNumber*(name: string): int =
  ## `A` -> 1 .. `XFD` -> 16384. Raises XlsxError when out of range.
  if name.len == 0 or name.len > 3:
    raise newException(XlsxError, "bad column name: " & name)
  result = 0
  for ch in name:
    if ch < 'A' or ch > 'Z':
      raise newException(XlsxError, "bad column name: " & name)
    result = result * 26 + (ch.ord - 'A'.ord + 1)
  if result < 1 or result > XlsxMaxCols:
    raise newException(XlsxError, "column out of range: " & name)

proc columnNumberToName*(num: int): string =
  ## 1 -> `A` .. 16384 -> `XFD`. Raises XlsxError when out of range.
  if num < 1 or num > XlsxMaxCols:
    raise newException(XlsxError, "column number out of range: " & $num)
  var n = num
  while n > 0:
    let r = (n - 1) mod 26
    result = char('A'.ord + r) & result
    n = (n - 1) div 26

proc splitCellRef*(cellRef: string): tuple[col, row: int] =
  ## `B12` -> (col: 2, row: 12). Absolute markers (`$B$12`) are accepted
  ## and ignored. Raises XlsxError on malformed or out-of-range refs.
  var letters = ""
  var digits = ""
  var seenDigit = false
  for ch in cellRef:
    if ch == '$': continue
    elif ch >= 'A' and ch <= 'Z':
      if seenDigit:
        raise newException(XlsxError, "bad cell reference: " & cellRef)
      letters.add ch
    elif ch >= '0' and ch <= '9':
      seenDigit = true
      digits.add ch
    else:
      raise newException(XlsxError, "bad cell reference: " & cellRef)
  if letters.len == 0 or digits.len == 0 or
      (digits.len > 1 and digits[0] == '0'):
    raise newException(XlsxError, "bad cell reference: " & cellRef)
  let row =
    try: parseInt(digits)
    except ValueError:
      raise newException(XlsxError, "bad cell reference: " & cellRef)
  if row < 1 or row > XlsxMaxRows:
    raise newException(XlsxError, "row out of range: " & cellRef)
  (columnNameToNumber(letters), row)

proc joinCellName*(col, row: int): string =
  ## (2, 12) -> `B12`. Raises XlsxError when out of range.
  if row < 1 or row > XlsxMaxRows:
    raise newException(XlsxError, "row out of range: " & $row)
  columnNumberToName(col) & $row
