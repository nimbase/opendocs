## Shared helpers for spreadsheet oracle fixtures.
##
## An oracle dump is a checked-in answer key produced by the reference
## implementation. The existing Phase B matrix consumes a coordinate dump of
## the form `fmtId|rowIdx|"value"`; later XLSX plans will consume sheet/cell
## dumps with one oracle column per reference API. This helper validates the
## shape of a dump separately from the product behaviour it checks.

import std/[strutils, tables]

type
  OracleCheck* = object
    ## One expected value. Later dumps use sheet/cell A1 references and
    ## field names such as `GetCellValue`; the legacy matrix dump uses
    ## synthetic `fmtId:rowIdx` addresses and `GetCellValue`.
    sheet*: string
    cell*: string
    field*: string
    want*: string

  OracleDump* = object
    checks*: seq[OracleCheck]
    index*: Table[string, int]

func oracleKey*(sheet, cell, field: string): string =
  ## Opaque lookup key. The separator cannot appear in sheet names produced
  ## by valid tests because it is not valid in an XML text node.
  sheet & "\x1f" & cell & "\x1f" & field

proc addCheck*(dump: var OracleDump, sheet, cell, field, want: string) =
  ## Add one expectation. Duplicates are rejected at load time: silently
  ## overwriting an expected value can turn a regression into a passing run.
  let key = oracleKey(sheet, cell, field)
  if dump.index.hasKey(key):
    raise newException(ValueError, "duplicate oracle check: " & key)
  dump.index[key] = dump.checks.len
  dump.checks.add OracleCheck(sheet: sheet, cell: cell, field: field,
    want: want)

proc valueAt*(dump: OracleDump, sheet, cell, field: string): string =
  ## Expected value. Missing expectations are a fixture error, not an empty
  ## result: returning `""` would turn a malformed dump into passing tests.
  let key = oracleKey(sheet, cell, field)
  if not dump.index.hasKey(key):
    raise newException(ValueError, "missing oracle check: " & key)
  dump.checks[dump.index[key]].want

proc requireCheckCount*(dump: OracleDump, expected: int, what: string) =
  ## Guard against a truncated or expanded dump silently shrinking or
  ## growing an oracle suite.
  if dump.checks.len != expected:
    raise newException(ValueError, "oracle " & what & " has " &
      $dump.checks.len & " checks, want " & $expected)

proc unquoteGo*(s: string): string =
  ## Minimal Go `%q` unquote. The existing dump contains no exotic escapes;
  ## unsupported forms raise instead of silently producing the wrong value.
  if s.len < 2 or s[0] != '"' or s[^1] != '"':
    raise newException(ValueError, "oracle value is not quoted: " & s)
  let body = s[1 .. ^2]
  var i = 0
  while i < body.len:
    if body[i] == '\\' and i + 1 < body.len:
      case body[i + 1]
      of '"': result.add '"'
      of '\\': result.add '\\'
      of 'n': result.add '\n'
      of 'r': result.add '\r'
      of 't': result.add '\t'
      else:
        raise newException(ValueError, "unsupported Go escape: \\" &
          body[i + 1])
      i += 2
    else:
      result.add body[i]
      i += 1

proc loadCoordinateDump*(path, sheet, field: string): OracleDump =
  ## Load the legacy Phase B matrix dump. Blank lines and the leading `bool`
  ## markers are skipped; every other line must have the four-part shape
  ## `fmtId|rowIdx|"value"`.
  var dump: OracleDump
  let lines = readFile(path).splitLines()
  for lineNo, raw in lines.pairs:
    let line = raw.strip()
    if line == "" or line.startsWith("bool"):
      continue
    let first = line.find('|')
    let second = line.find('|', first + 1)
    if first <= 0 or second <= first + 1 or second + 1 >= line.len:
      raise newException(ValueError, "malformed oracle dump at " & path &
        ":" & $(lineNo + 1))
    let fmtId = try: parseInt(line[0 ..< first])
      except ValueError:
        raise newException(ValueError, "bad fmtId at " & path & ":" &
          $(lineNo + 1))
    let rowIdx = try: parseInt(line[first + 1 ..< second])
      except ValueError:
        raise newException(ValueError, "bad rowIdx at " & path & ":" &
          $(lineNo + 1))
    dump.addCheck(sheet, $fmtId & ":" & $rowIdx, field,
      unquoteGo(line[second + 1 .. ^1]))
  result = dump
