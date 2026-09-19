## XLSX reader showcase.
## Build: `clue build examples/xlsx_read_example.nim --out:/tmp/xlsx_ex`
## Run: `/tmp/xlsx_ex [file.xlsx]`
## (no args: walks `tests/fixtures/xlsx/`).

import std/[os, strutils]
import opendocs/xlsx

proc showDoc(path: string) =
  echo "=== ", path, " ==="
  let f =
    try: openXlsx(path)
    except XlsxError as e:
      echo "  XlsxError: ", e.msg
      return
  defer: f.closeXlsx()
  echo "  sheets: ", f.getSheetList().join(", ")
  echo "  date1904: ", f.date1904
  for name in f.getSheetList():
    echo "  -- ", name, " --"
    try:
      for r in f.getRows(name):
        echo "  | ", r.join(" | ")
    except XlsxError as e:
      echo "  (not a worksheet: ", e.msg, ")"

when isMainModule:
  let args = commandLineParams()
  if args.len > 0:
    for a in args: showDoc(a)
  else:
    for kind, path in walkDir("tests/fixtures/xlsx"):
      if kind == pcFile and path.endsWith(".xlsx"): showDoc(path)
