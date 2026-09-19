## Shared string table: lazy load of `xl/sharedStrings.xml`.
## Ports of excelize `sharedStringsReader` and `xlsxSI.String()`.
## Excelize is licensed under BSD-3-Clause-1 https://github.com/qax-os/excelize?tab=BSD-3-Clause-1-ov-file

proc siText(si: XmlNode): string =
  ## Plain text of one `si`: direct `t` plus every rich-run `r/t`.
  ## (Phonetic `rPh` runs are pronunciation hints, not cell text.)
  for t in childElemsL(si, "t"): result.add childText(t)
  for r in childElemsL(si, "r"):
    for t in childElemsL(r, "t"): result.add childText(t)

proc sharedStrings*(f: XlsxFile): seq[string] =
  ## All shared strings in index order, loaded once. A missing
  ## `xl/sharedStrings.xml` yields an empty table (not an error).
  if f.sstLoaded: return f.sharedStrings
  f.sstLoaded = true
  let root = readXmlPart(f, "xl/sharedStrings.xml")
  if root == nil: return f.sharedStrings
  if localName(root.tag) != "sst":
    raise newException(XlsxError,
      "xl/sharedStrings.xml root is <" & root.tag & ">, want <sst>")
  for si in childElemsL(root, "si"):
    f.sharedStrings.add siText(si)
  f.sharedStrings

proc sharedString*(f: XlsxFile, idx: int): string =
  ## String by index. Raises XlsxError when out of range (excelize
  ## `ErrInvalidSharedStringIndex` parity).
  let sst = sharedStrings(f)
  if idx < 0 or idx >= sst.len:
    raise newException(XlsxError,
      "shared string index out of range: " & $idx)
  sst[idx]
