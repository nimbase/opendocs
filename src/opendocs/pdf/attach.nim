## Embedded files: read and write (M10).
##
## `embeddedFiles` walks the catalog /Names /EmbeddedFiles name tree
## (flat /Names arrays and /Kids intermediate nodes) down to /FileSpec
## dicts and returns each /EF stream decoded. `embedFile` stores a new
## attachment in a `PdfBuilder` (surfaced in the catalog /Names on
## `buildPdf`); `embedFileUpdate` appends one to an existing file via
## `PdfUpdate`, keeping old specs by reference and merging the name
## array sorted. Encrypted inputs are rejected loudly, like M6 rewrite.

import std/algorithm
import std/strutils
import ./types
import ./cos
import ./docmodel
import ./filters
import ./write

type
  FileAttachment* = object
    name*: string ## sort key from the /EmbeddedFiles name array
    fileName*: string ## /UF display name, else /F, else the key
    desc*: string ## /Desc ("" when absent)
    mime*: string ## /Subtype of the embedded stream ("" when absent)
    data*: string ## decoded file bytes

proc guessMime*(name: string): string =
  ## MIME type from the file extension, for the /Subtype entry.
  let dot = name.rfind('.')
  let ext = if dot < 0: "" else: name[dot + 1 .. ^1].toLowerAscii()
  case ext
  of "pdf": "application/pdf"
  of "txt": "text/plain"
  of "xml": "text/xml"
  of "html", "htm": "text/html"
  of "json": "application/json"
  of "png": "image/png"
  of "jpg", "jpeg": "image/jpeg"
  of "zip": "application/zip"
  else: "application/octet-stream"

proc flattenTree(d: var PdfDoc, node: CosObj,
    pairs: var seq[tuple[name: string, spec: CosObj]], depth: int) =
  if depth > d.limits.maxWalkDepth:
    pdfFail("embedded-files name tree too deep (possible cycle)")
  let resolved = d.resolve(node)
  if resolved.kind != coDict:
    pdfFail("embedded-files name tree node is not a dictionary")
  let names = resolved.dictGet("Names")
  if names.kind == coArray:
    if names.items.len mod 2 != 0:
      pdfFail("embedded-files /Names array must hold name/spec pairs")
    d.limits.checkCount(names.items.len, "embedded file")
    var i = 0
    while i < names.items.len:
      if names.items[i].kind != coStr:
        pdfFail("embedded-files name must be a string")
      pairs.add((names.items[i].sval, names.items[i + 1]))
      i += 2
  let kids = resolved.dictGet("Kids")
  if kids.kind == coArray:
    for k in kids.items:
      d.flattenTree(k, pairs, depth + 1)

proc embeddedFiles*(d: var PdfDoc): seq[FileAttachment] =
  ## Every file attachment in catalog /Names /EmbeddedFiles, in name
  ## order. Empty when the document carries no embedded files.
  result = @[]
  let cat = d.catalog()
  let namesRef = cat.dictGet("Names")
  if namesRef.kind == coNull:
    return
  let names = d.resolve(namesRef)
  if names.kind != coDict:
    pdfFail("catalog /Names is not a dictionary")
  let efRef = names.dictGet("EmbeddedFiles")
  if efRef.kind == coNull:
    return
  var pairs: seq[tuple[name: string, spec: CosObj]] = @[]
  d.flattenTree(efRef, pairs, 0)
  for (key, specRef) in pairs:
    let spec = d.resolve(specRef)
    if spec.kind != coDict:
      pdfFail("embedded file '" & key & "' spec is not a dictionary")
    let efDict = d.resolve(spec.dictGet("EF"))
    if efDict.kind != coDict:
      pdfFail("embedded file '" & key & "' has no /EF dictionary")
    var streamRef = efDict.dictGet("F")
    if streamRef.kind == coNull:
      streamRef = efDict.dictGet("UF")
    let stm = d.resolve(streamRef)
    if stm.kind != coStream:
      pdfFail("embedded file '" & key & "' has no file stream")
    var fileName = key
    let uf = spec.dictGet("UF")
    if uf.kind == coStr:
      fileName = uf.sval
    else:
      let f = spec.dictGet("F")
      if f.kind == coStr:
        fileName = f.sval
    var desc = ""
    if spec.dictGet("Desc").kind == coStr:
      desc = spec.dictGet("Desc").sval
    var mime = ""
    if stm.dictGet("Subtype").kind == coName:
      mime = stm.dictGet("Subtype").name
    result.add(FileAttachment(name: key, fileName: fileName, desc: desc,
      mime: mime, data: decodeCosStream(stm)))

proc specDict(name, desc, mime: string, efNum: int): CosObj =
  var keys = @["Type", "F", "UF"]
  var vals = @[CosObj(kind: coName, name: "Filespec"),
    CosObj(kind: coStr, sval: name),
    CosObj(kind: coStr, sval: name)]
  if desc.len > 0:
    keys.add("Desc")
    vals.add(CosObj(kind: coStr, sval: desc))
  keys.add("EF")
  vals.add(CosObj(kind: coDict, keys: @["F"],
    vals: @[CosObj(kind: coRef, refNum: efNum, refGen: 0)]))
  CosObj(kind: coDict, keys: keys, vals: vals)

proc efDict(mime: string, size: int): CosObj =
  CosObj(kind: coDict,
    keys: @["Type", "Subtype", "Params"],
    vals: @[CosObj(kind: coName, name: "EmbeddedFile"),
      CosObj(kind: coName, name: mime),
      CosObj(kind: coDict, keys: @["Size"],
        vals: @[CosObj(kind: coInt, ival: size)])])

proc embedFile*(b: var PdfBuilder, name, data: string, desc = "",
    mime = ""): int =
  ## Store an attachment; returns the /FileSpec object number. The
  ## spec surfaces in the catalog /Names on `buildPdf`.
  if name.len == 0:
    pdfFail("attachment name must not be empty")
  let mt = if mime.len > 0: mime else: guessMime(name)
  let efNum = b.addStream(efDict(mt, data.len), data)
  result = b.addValue(specDict(name, desc, mt, efNum))
  b.attachSpecs.add((name, result))

proc namesDict(pairs: seq[tuple[name: string, spec: CosObj]]): CosObj =
  ## Merged, byte-sorted /EmbeddedFiles name tree as one flat array.
  var ordered = pairs
  ordered.sort(proc(a, b: tuple[name: string,
      spec: CosObj]): int = cmp(a.name, b.name))
  var items: seq[CosObj] = @[]
  for p in ordered:
    items.add(CosObj(kind: coStr, sval: p.name))
    items.add(p.spec)
  let files = CosObj(kind: coDict, keys: @["Names"],
    vals: @[CosObj(kind: coArray, items: items)])
  CosObj(kind: coDict, keys: @["EmbeddedFiles"], vals: @[files])

proc embedFileUpdate*(u: var PdfUpdate, donor: var PdfDoc, name,
    data: string, desc = "", mime = "") =
  ## Append an attachment to the file under update. Old specs stay by
  ## reference (still live past /Prev); the merged name array sorts
  ## old and new keys together. `donor` must read the same base bytes.
  if name.len == 0:
    pdfFail("attachment name must not be empty")
  if donor.crypt.present:
    pdfFail("attachment update supports unencrypted documents only " &
      "(file has /Encrypt)")
  let mt = if mime.len > 0: mime else: guessMime(name)
  let ef = efDict(mt, data.len)
  var ekeys = ef.keys
  var evals = ef.vals
  ekeys.add("Length")
  evals.add(CosObj(kind: coInt, ival: data.len))
  let efNum = u.addObject(writeCos(CosObj(kind: coStream,
    streamDict: ekeys, streamVals: evals, raw: data)))
  let specNum = u.addObject(writeCos(
    specDict(name, desc, mt, efNum)))
  var pairs: seq[tuple[name: string, spec: CosObj]] = @[]
  let cat = donor.catalog()
  let namesRef = cat.dictGet("Names")
  if namesRef.kind != coNull:
    let names = donor.resolve(namesRef)
    if names.kind == coDict:
      let efRef = names.dictGet("EmbeddedFiles")
      if efRef.kind != coNull:
        donor.flattenTree(efRef, pairs, 0)
  pairs.add((name, CosObj(kind: coRef, refNum: specNum, refGen: 0)))
  let namesNum = u.addObject(writeCos(namesDict(pairs)))
  var ckeys: seq[string] = @[]
  var cvals: seq[CosObj] = @[]
  for i, k in cat.keys:
    if k == "Names":
      continue
    ckeys.add(k)
    cvals.add(cat.vals[i])
  ckeys.add("Names")
  cvals.add(CosObj(kind: coRef, refNum: namesNum, refGen: 0))
  discard u.updateObject(u.rootNum,
    writeCos(CosObj(kind: coDict, keys: ckeys, vals: cvals)))
