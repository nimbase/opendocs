## Unit tests for the spreadsheet oracle harness itself.
##
## These tests use inline dumps so that the helper is verified independently
## of any checked-in fixture. The Phase B matrix consumes the same helper in
## `tests/t_xlsx.nim`.

import std/[os, strutils, unittest]
import xlsx_oracle

proc tempOracle(name, contents: string): string =
  result = getTempDir() / name
  writeFile(result, contents)

suite "oracle harness":
  test "missing dump is an IO error, not a silent empty suite":
    expect IOError:
      discard loadCoordinateDump(
        getTempDir() / "nimbase-missing-oracle.txt", "Sheet1", "GetCellValue")

  test "duplicate addresses raise":
    let path = tempOracle("nimbase-oracle-duplicate.txt",
      "12|3|\"a\"\n12|3|\"b\"\n")
    defer: removeFile(path)
    expect ValueError:
      discard loadCoordinateDump(path, "Sheet1", "GetCellValue")

  test "malformed lines raise with their location":
    let path = tempOracle("nimbase-oracle-malformed.txt", "12|3\n")
    defer: removeFile(path)
    try:
      discard loadCoordinateDump(path, "Sheet1", "GetCellValue")
      fail()
    except ValueError as e:
      check "nimbase-oracle-malformed.txt:1" in e.msg

  test "bad coordinates raise with their location":
    let path = tempOracle("nimbase-oracle-bad-coordinate.txt",
      "twelfth|3|\"a\"\n")
    defer: removeFile(path)
    try:
      discard loadCoordinateDump(path, "Sheet1", "GetCellValue")
      fail()
    except ValueError as e:
      check "bad fmtId" in e.msg

  test "unsupported Go escapes raise instead of guessing":
    let path = tempOracle("nimbase-oracle-bad-escape.txt",
      "12|3|\"\\q\"\n")
    defer: removeFile(path)
    expect ValueError:
      discard loadCoordinateDump(path, "Sheet1", "GetCellValue")

  test "missing expected values raise instead of returning empty":
    var dump: OracleDump
    dump.addCheck("Sheet1", "A1", "GetCellValue", "x")
    expect ValueError:
      discard dump.valueAt("Sheet1", "A2", "GetCellValue")

  test "check counts are exact in both directions":
    var dump: OracleDump
    dump.addCheck("Sheet1", "A1", "GetCellValue", "x")
    expect ValueError:
      dump.requireCheckCount(2, "sample")
    expect ValueError:
      dump.requireCheckCount(0, "sample")
