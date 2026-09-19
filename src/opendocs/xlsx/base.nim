## Copyright (c) 2026 nimbase (MIT, see LICENSE at repo root).
## Portions derived from excelize (https://github.com/qax-os/excelize,
## commit 0434413, 2026-09-18): Copyright (c) 2016-2026 The excelize
## Authors, Copyright (c) 2011-2017 Geoffrey J. Teale, BSD-3-Clause.
## SPDX-License-Identifier: MIT AND BSD-3-Clause
##
## Shared XML/part helpers for the spreadsheet reader.
##
## XML via `openparser/xml` DOM (`fromXml`), always with `xpStrict`.
## Packages via `opendocs/zip`. Included right after `xlsx/types` so
## every part reader can use these.

const
  MaxXlsxXmlDepth = 64 ## nesting cap against hostile documents

let strictXlsxXmlOpts = XmlOptions(policy: xpStrict)

# ------------------------------------------------------------------ xml utils

func localName(tag: string): string =
  ## Local part of a possibly prefixed tag (`x:row` -> `row`). Sheet XML
  ## from Excel is usually unprefixed, but prefixed producers exist.
  let i = tag.rfind(':')
  if i < 0: tag else: tag[i + 1 .. ^1]

func childElemsL(n: XmlNode, local: string): seq[XmlNode] =
  if n != nil and n.kind == xnElement:
    for c in n.children:
      if c.kind == xnElement and localName(c.tag) == local:
        result.add c

func firstChildL(n: XmlNode, local: string): XmlNode =
  for c in childElemsL(n, local): return c
  nil

func optAttr(n: XmlNode, name: string): string =
  ## Nil-safe attribute read; falls back to the unprefixed spelling
  ## (`r:id` readable as `id`) for namespace-variant producers.
  if n == nil or n.kind != xnElement: return ""
  result = n.getAttr(name)
  if result == "":
    let i = name.rfind(':')
    if i >= 0: result = n.getAttr(name[i + 1 .. ^1])

func childText(n: XmlNode): string =
  ## Concatenated direct text/cdata children.
  if n != nil and n.kind == xnElement:
    for c in n.children:
      if c.kind == xnText: result.add c.text
      elif c.kind == xnCdata: result.add c.cdata

func intAttr(n: XmlNode, name: string, dflt: int): int =
  if n == nil or n.kind != xnElement: return dflt
  let v = optAttr(n, name)
  if v == "": return dflt
  try: parseInt(v)
  except ValueError: dflt

func floatAttr(n: XmlNode, name: string, dflt: float): float =
  if n == nil or n.kind != xnElement: return dflt
  let v = optAttr(n, name)
  if v == "": return dflt
  try: parseFloat(v)
  except ValueError: dflt

func boolAttr(n: XmlNode, name: string): bool =
  ## OOXML boolean attribute: "1"/"true"/"on" (Excel writes "1").
  optAttr(n, name) in ["1", "true", "on"]

proc parsePartXml(data: seq[byte], partName: string): XmlNode =
  ## Strict-parse one package part in place. Raises XlsxError on failure.
  if data.len == 0:
    raise newException(XlsxError, "empty XML part: " & partName)
  try:
    fromXml(cast[pointer](unsafeAddr data[0]), data.len, strictXlsxXmlOpts)
  except OpenParserXmlError as e:
    raise newException(XlsxError, "bad XML in " & partName & ": " & e.msg)

# ------------------------------------------------------------------ part io

func spillName(name: string): string =
  ## Temp-file name for a part. The zip-slip guard already vetted `name`
  ## (relative, no `..`), so flattening `/` is sufficient.
  name.replace("/", "__")

proc findPartIdx(f: XlsxFile, name: string): int =
  ## Exact match, else a backslash-variant fallback (some producers
  ## write `xl\worksheets\sheet1.xml`-style names).
  result = f.archive.findEntry(name)
  if result < 0 and "/" in name:
    result = f.archive.findEntry(name.replace("/", "\\"))

proc hasPart(f: XlsxFile, name: string): bool =
  if f.spillDir == "":
    findPartIdx(f, name) >= 0
  else:
    fileExists(f.spillDir / spillName(name))

proc readBytesPart(f: XlsxFile, name: string): seq[byte] =
  ## Owned part bytes. Raises XlsxError when missing or unreadable.
  if f.spillDir == "":
    let idx = findPartIdx(f, name)
    if idx < 0:
      raise newException(XlsxError, "missing package part: " & name)
    try:
      result = f.archive.readEntryByIndex(idx)
    except ZipError as e:
      raise newException(XlsxError, "cannot extract " & name & ": " & e.msg)
  else:
    let path = f.spillDir / spillName(name)
    var fh: File
    if not open(fh, path, fmRead):
      raise newException(XlsxError, "cannot read spilled part: " & name)
    defer: close(fh)
    let size = getFileSize(fh).int
    result = newSeq[byte](size)
    if size > 0 and readBytes(fh, result, 0, size) != size:
      raise newException(XlsxError, "short read: " & name)

proc readXmlPart(f: XlsxFile, name: string): XmlNode =
  ## Strict-parse a part, nil when absent. Raises XlsxError on failure.
  if not hasPart(f, name): return nil
  parsePartXml(readBytesPart(f, name), name)

proc `=destroy`(o: var XlsxFileObj) =
  ## Spill-dir safety net for callers that skip `closeXlsx`. Declared
  ## here (before any construction site) so hook binding succeeds.
  if o.spillDir != "":
    try: removeDir(o.spillDir)
    except OSError: discard
