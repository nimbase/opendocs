## PDF writer (M6 + M16e): COS serializer, document builder, rewrite,
## incremental update, encryption writer.
##
## `writeCos` serializes any parsed value back to canonical bytes, so
## rewrite preserves semantics while normalizing layout. The builder
## creates fresh documents (catalog 1, pages 2, content from 3 up);
## `rewritePdf` re-emits every live object with fresh offsets
## (decrypting encrypted input when the password is supplied);
## `beginUpdate`/`finishUpdate` appends an incremental section whose
## trailer carries /Prev. Incremental update of encrypted files still
## fails loudly: encrypting via incremental sections cannot retroactively
## protect base bytes, so use `rewritePdfEncrypted` (full rewrite).
## `rewritePdfEncrypted`/`buildPdfEncrypted` emit R4/AESV2 or R6/AESV3
## (R2/R3 never written). `finishUpdateEncrypted` finishes the pending
## update then does a full encrypted rewrite; it is not incremental when
## signatures are present — do not use it on signed files.

import std/algorithm
import std/strutils
import std/tables
import ./types
import ./source
import ./lexer
import ./cos
import ./xref
import ./docmodel
import ./filters
import ./crypt

const pdfMagic* = "%PDF-1.7\n%\xE2\xE3\xCF\xD3\n"

type
  RawObj* = tuple[num, gen: int, body: string]

# ---------------------------------------------------------------------------
# COS serializer
# ---------------------------------------------------------------------------

proc writeFloat(v: float64): string =
  if v != v or v == Inf or v == -Inf:
    pdfFail("cannot serialize non-finite PDF number")
  let s = $v
  if 'e' notin s and 'E' notin s:
    return s
  result = formatFloat(v, ffDecimal, precision = 10)
  while result.len > 0 and result[^1] == '0':
    result.setLen(result.len - 1)
  if result.len > 0 and result[^1] == '.':
    result.setLen(result.len - 1)
  if result.len == 0 or result == "-":
    result = "0"

proc writeName(name: string): string =
  result = "/"
  for c in name:
    if c == '#' or isWs(c) or c in {'(', ')', '<', '>', '[', ']', '{',
        '}', '/', '%'}:
      result.add('#')
      result.add(toHex(ord(c), 2))
    else:
      result.add(c)

proc writeStr*(s: string): string =
  ## Serialize a PDF literal string with escaping, for content-stream
  ## text and anywhere else a `(string)` is needed.
  result = "("
  for c in s:
    case c
    of '\\': result.add("\\\\")
    of '(': result.add("\\(")
    of ')': result.add("\\)")
    of '\x0A': result.add("\\n")
    of '\x0D': result.add("\\r")
    of '\x09': result.add("\\t")
    of '\x08': result.add("\\b")
    of '\x0C': result.add("\\f")
    else:
      if ord(c) < 32 or ord(c) > 126:
        result.add('\\')
        let o = toOct(ord(c), 3)
        result.add(o[^3 .. ^1])
      else:
        result.add(c)
  result.add(')')

proc writeCos*(o: CosObj): string =
  ## Canonical serialization of a COS value. Dictionaries keep key
  ## order; streams use `stream<EOL>...<EOL>endstream` framing.
  case o.kind
  of coNull: result = "null"
  of coBool:
    result = if o.bval: "true" else: "false"
  of coInt: result = $o.ival
  of coFloat: result = writeFloat(o.fval)
  of coName: result = writeName(o.name)
  of coStr: result = writeStr(o.sval)
  of coRef: result = $o.refNum & " " & $o.refGen & " R"
  of coArray:
    result = "["
    for i, item in o.items:
      if i > 0:
        result.add(' ')
      result.add(writeCos(item))
    result.add(']')
  of coDict:
    result = "<<"
    for i, k in o.keys:
      result.add(' ')
      result.add(writeName(k))
      result.add(' ')
      result.add(writeCos(o.vals[i]))
    result.add(" >>")
  of coStream:
    result = "<<"
    for i, k in o.streamDict:
      result.add(' ')
      result.add(writeName(k))
      result.add(' ')
      result.add(writeCos(o.streamVals[i]))
    result.add(" >>\nstream\n")
    result.add(o.raw)
    result.add("\nendstream")

proc writeIndirect*(num, gen: int, body: string): string =
  $num & " " & $gen & " obj\n" & body & "\nendobj\n"

# ---------------------------------------------------------------------------
# File assembly
# ---------------------------------------------------------------------------

proc padNum(v, width: int): string =
  result = $v
  while result.len < width:
    result = "0" & result

proc emitFile*(header: string, objs: seq[RawObj], size: int,
    rootNum, rootGen: int, idFirst, idSecond: string,
    prev = -1, infoNum = 0, infoGen = 0, encryptNum = 0,
    encryptGen = 0): string =
  ## Full file: header, indirect objects with a fresh xref table,
  ## trailer, startxref. Object numbers are preserved; offsets are new.
  var sorted = objs
  sorted.sort(proc(a, b: RawObj): int = cmp(a.num, b.num))
  result = header
  var offsets = initTable[int, int]()
  var gens = initTable[int, int]()
  var maxNum = 0
  for o in sorted:
    if o.num <= 0:
      pdfFail("PDF object number must be positive, got " & $o.num)
    if offsets.hasKey(o.num):
      pdfFail("duplicate PDF object number " & $o.num)
    offsets[o.num] = result.len
    gens[o.num] = o.gen
    maxNum = max(maxNum, o.num)
    result.add(writeIndirect(o.num, o.gen, o.body))
  let xrefPos = result.len
  result.add("xref\n0 " & $(maxNum + 1) & "\n")
  for n in 0 .. maxNum:
    if offsets.hasKey(n):
      result.add(padNum(offsets[n], 10) & " " & padNum(gens[n], 5) &
        " n \n")
    else:
      result.add("0000000000 65535 f \n")
  result.add("trailer\n<< /Size " & $size & " /Root " & $rootNum & " " &
    $rootGen & " R")
  if idFirst.len > 0:
    result.add(" /ID [" & writeStr(idFirst) & " " &
      writeStr(if idSecond.len > 0: idSecond else: idFirst) & "]")
  if infoNum > 0:
    result.add(" /Info " & $infoNum & " " & $infoGen & " R")
  if encryptNum > 0:
    result.add(" /Encrypt " & $encryptNum & " " & $encryptGen & " R")
  if prev >= 0:
    result.add(" /Prev " & $prev)
  result.add(" >>\nstartxref\n" & $xrefPos & "\n%%EOF\n")

# ---------------------------------------------------------------------------
# Builder: fresh documents
# ---------------------------------------------------------------------------

const
  catalogNum* = 1
  pagesNum* = 2
  firstContentNum* = 3

type
  PdfBuilder* = object
    objs*: seq[RawObj]
    kids*: seq[int]
    nextNum*: int
    infoTitle*: string
    infoAuthor*: string
    infoCreator*: string
    infoProducer*: string
    infoKeywords*: string
    infoCreationDate*: string
    infoModDate*: string
    infoTrapped*: string
    xmpPacket*: string
    attachSpecs*: seq[tuple[name: string, specNum: int]] ## (name, /FileSpec) pairs for the catalog /Names
    pageDicts*: Table[int, CosObj] ## page obj num -> /Page dict (pre-/Annots)
    outlineDrafts*: seq[tuple[title: string, targetPage: int,
      parent: int]] ## addOutline drafts, parent is draft index (-1 top)
    labelDrafts*: seq[tuple[style, prefix: string, start, first: int]]
    annotDrafts*: seq[tuple[page: int, body: string]] ## serialized annot dicts

proc newPdfBuilder*(): PdfBuilder =
  ## Catalog is 1, page tree is 2, caller objects start at 3.
  PdfBuilder(objs: @[], kids: @[], nextNum: firstContentNum,
    infoTitle: "", infoAuthor: "", infoCreator: "", infoProducer: "",
    infoKeywords: "", infoCreationDate: "", infoModDate: "",
    infoTrapped: "", xmpPacket: "", attachSpecs: @[],
    pageDicts: initTable[int, CosObj](), outlineDrafts: @[],
    labelDrafts: @[], annotDrafts: @[])

proc setInfo*(b: var PdfBuilder, title = "", author = "",
    creator = "", producer = "", keywords = "", creationDate = "",
    modDate = "", trapped = "") =
  ## Document metadata for the trailer /Info dict. Empty strings are
  ## omitted; call before `buildPdf`. Dates are raw PDF date strings
  ## (malformed dates read back as ok=false, never corrected here).
  ## `trapped` must be "", "True", "False" or "Unknown".
  if trapped notin ["", "True", "False", "Unknown"]:
    pdfFail("trapped must be True, False or Unknown")
  b.infoTitle = title
  b.infoAuthor = author
  b.infoCreator = creator
  b.infoProducer = producer
  b.infoKeywords = keywords
  b.infoCreationDate = creationDate
  b.infoModDate = modDate
  b.infoTrapped = trapped

proc setXmpPacket*(b: var PdfBuilder, packet: string) =
  ## Raw XMP packet for the catalog /Metadata stream. Empty clears.
  b.xmpPacket = packet

proc addObject*(b: var PdfBuilder, body: string, gen = 0): int =
  ## Store a pre-serialized object body; returns its number.
  result = b.nextNum
  inc b.nextNum
  b.objs.add((result, gen, body))

proc addValue*(b: var PdfBuilder, val: CosObj, gen = 0): int =
  b.addObject(writeCos(val), gen)

proc addStream*(b: var PdfBuilder, dict: CosObj, raw: string,
    gen = 0): int =
  ## Store a stream; /Length is always normalized to `raw.len`.
  if dict.kind != coDict:
    pdfFail("addStream needs a dictionary object")
  var keys: seq[string] = @[]
  var vals: seq[CosObj] = @[]
  for i, k in dict.keys:
    if k != "Length":
      keys.add(k)
      vals.add(dict.vals[i])
  keys.add("Length")
  vals.add(CosObj(kind: coInt, ival: raw.len))
  let body = writeCos(CosObj(kind: coStream, streamDict: keys,
    streamVals: vals, raw: raw))
  b.addObject(body, gen)

proc addContentStream*(b: var PdfBuilder, raw: string,
    flate = true): int =
  ## Content-stream object, Flate-compressed by default.
  if flate:
    let dict = CosObj(kind: coDict, keys: @["Filter"],
      vals: @[CosObj(kind: coName, name: "FlateDecode")])
    b.addStream(dict, deflateEncode(raw))
  else:
    b.addStream(CosObj(kind: coDict, keys: @[], vals: @[]), raw)

proc addPage*(b: var PdfBuilder, width, height: float64, contentNum: int,
    resources: CosObj): int =
  ## Page dictionary pointing at an existing content stream and a
  ## caller-supplied /Resources dict. Returns the page object number.
  if resources.kind != coDict:
    pdfFail("addPage needs a /Resources dictionary object")
  let page = CosObj(kind: coDict,
    keys: @["Type", "Parent", "MediaBox", "Resources", "Contents"],
    vals: @[CosObj(kind: coName, name: "Page"),
      CosObj(kind: coRef, refNum: pagesNum, refGen: 0),
      CosObj(kind: coArray, items: @[CosObj(kind: coInt, ival: 0),
        CosObj(kind: coInt, ival: 0),
        CosObj(kind: coFloat, fval: width),
        CosObj(kind: coFloat, fval: height)]),
      resources,
      CosObj(kind: coRef, refNum: contentNum, refGen: 0)])
  result = b.addValue(page)
  b.kids.add(result)
  b.pageDicts[result] = page

proc adoptPage*(b: var PdfBuilder, page: CosObj): int =
  ## Register a caller-built /Page dictionary (for merge transplant:
  ## the dict must carry its own /Parent reference). Returns the new
  ## page object number.
  if page.kind != coDict:
    pdfFail("adoptPage needs a /Page dictionary")
  result = b.addValue(page)
  b.kids.add(result)
  b.pageDicts[result] = page

proc addJpegImage*(b: var PdfBuilder, jpegBytes: string, width,
    height: int, components = 3): int =
  ## Image XObject from JPEG bytes (DCTDecode passthrough). `components`
  ## selects the colorspace: 1 DeviceGray, 3 DeviceRGB (default).
  if jpegBytes.len == 0:
    pdfFail("cannot embed empty JPEG image")
  if width <= 0 or height <= 0:
    pdfFail("image has non-positive size")
  let cs = if components == 1: "DeviceGray" else: "DeviceRGB"
  let dict = CosObj(kind: coDict,
    keys: @["Type", "Subtype", "Width", "Height", "ColorSpace",
      "BitsPerComponent", "Filter"],
    vals: @[CosObj(kind: coName, name: "XObject"),
      CosObj(kind: coName, name: "Image"),
      CosObj(kind: coInt, ival: width),
      CosObj(kind: coInt, ival: height),
      CosObj(kind: coName, name: cs),
      CosObj(kind: coInt, ival: 8),
      CosObj(kind: coName, name: "DCTDecode")])
  b.addStream(dict, jpegBytes)

proc addRgbImage*(b: var PdfBuilder, pixels: string, width,
    height: int, components = 3): int =
  ## Image XObject from raw 8-bit samples, Flate-compressed on write.
  ## `pixels` must hold width*height*components bytes (1 gray, 3 rgb).
  if width <= 0 or height <= 0:
    pdfFail("image has non-positive size")
  if components != 1 and components != 3:
    pdfFail("image components must be 1 (gray) or 3 (rgb)")
  if pixels.len != width * height * components:
    pdfFail("pixel size mismatch embedding image")
  let cs = if components == 1: "DeviceGray" else: "DeviceRGB"
  let dict = CosObj(kind: coDict,
    keys: @["Type", "Subtype", "Width", "Height", "ColorSpace",
      "BitsPerComponent", "Filter"],
    vals: @[CosObj(kind: coName, name: "XObject"),
      CosObj(kind: coName, name: "Image"),
      CosObj(kind: coInt, ival: width),
      CosObj(kind: coInt, ival: height),
      CosObj(kind: coName, name: cs),
      CosObj(kind: coInt, ival: 8),
      CosObj(kind: coName, name: "FlateDecode")])
  b.addStream(dict, deflateEncode(pixels))

proc buildPdf*(b: PdfBuilder): string =
  ## Assemble catalog, page tree and caller objects into one file.
  ## Emits /Outlines, /PageLabels and page /Annots when the M16
  ## drafts are present; validates indexes and fails loudly.
  var next = b.nextNum
  var extra: seq[RawObj] = @[]
  var annotRefs = initTable[int, seq[int]]() # page idx -> annot obj nums
  for i, a in b.annotDrafts:
    if a.page < 0 or a.page >= b.kids.len:
      pdfFail("annotation draft " & $i & " targets missing page " &
        $a.page)
    let num = next
    inc next
    extra.add((num, 0, a.body))
    if not annotRefs.hasKey(a.page):
      annotRefs[a.page] = @[]
    annotRefs[a.page].add(num)
  # Patched page bodies (originals live in b.objs).
  var pagePatch = initTable[int, string]()
  for pageIdx, nums in annotRefs.pairs:
    let pageNum = b.kids[pageIdx]
    if not b.pageDicts.hasKey(pageNum):
      pdfFail("builder page " & $pageNum & " has no recorded dictionary")
    let orig = b.pageDicts[pageNum]
    if orig.kind != coDict:
      pdfFail("builder page " & $pageNum & " is not a dictionary")
    var refs: seq[CosObj] = @[]
    for n in nums:
      refs.add(CosObj(kind: coRef, refNum: n, refGen: 0))
    var keys = orig.keys
    var vals = orig.vals
    var replaced = false
    for i, k in keys:
      if k == "Annots":
        vals[i] = CosObj(kind: coArray, items: refs)
        replaced = true
        break
    if not replaced:
      keys.add("Annots")
      vals.add(CosObj(kind: coArray, items: refs))
    pagePatch[pageNum] = writeCos(CosObj(kind: coDict, keys: keys,
      vals: vals))
  # Outlines.
  var outlineRoot = 0
  if b.outlineDrafts.len > 0:
    for i, o in b.outlineDrafts:
      if o.targetPage < 0 or o.targetPage >= b.kids.len:
        pdfFail("outline draft " & $i & " targets missing page " &
          $o.targetPage)
      if o.parent < -1 or o.parent >= b.outlineDrafts.len or
          o.parent == i:
        pdfFail("outline draft " & $i & " has bad parent " & $o.parent)
    # Cycle check via parent chains.
    for i in 0 ..< b.outlineDrafts.len:
      var seen = initTable[int, bool]()
      var p = b.outlineDrafts[i].parent
      while p != -1:
        if seen.hasKey(p):
          pdfFail("outline drafts contain a parent cycle at " & $i)
        seen[p] = true
        p = b.outlineDrafts[p].parent
    var itemNums = newSeq[int](b.outlineDrafts.len)
    for i in 0 ..< b.outlineDrafts.len:
      itemNums[i] = next
      inc next
    outlineRoot = next
    inc next
    var children = newSeq[seq[int]](b.outlineDrafts.len)
    for i in 0 ..< b.outlineDrafts.len:
      children[i] = @[]
    var top: seq[int] = @[]
    for i, o in b.outlineDrafts:
      if o.parent == -1:
        top.add(i)
      else:
        children[o.parent].add(i)
    for i in 0 ..< b.outlineDrafts.len:
      let o = b.outlineDrafts[i]
      let parentRef = if o.parent == -1: outlineRoot
        else: itemNums[o.parent]
      var sibs: seq[int]
      if o.parent == -1:
        sibs = top
      else:
        sibs = children[o.parent]
      var at = 0
      for j, s in sibs:
        if s == i:
          at = j
          break
      var keys = @["Title", "Parent", "Dest"]
      var vals = @[CosObj(kind: coStr, sval: o.title),
        CosObj(kind: coRef, refNum: parentRef, refGen: 0),
        CosObj(kind: coArray, items: @[
          CosObj(kind: coRef, refNum: b.kids[o.targetPage], refGen: 0),
          CosObj(kind: coName, name: "Fit")])]
      if at > 0:
        keys.add("Prev")
        vals.add(CosObj(kind: coRef, refNum: itemNums[sibs[at - 1]],
          refGen: 0))
      if at + 1 < sibs.len:
        keys.add("Next")
        vals.add(CosObj(kind: coRef, refNum: itemNums[sibs[at + 1]],
          refGen: 0))
      if children[i].len > 0:
        keys.add("First")
        vals.add(CosObj(kind: coRef, refNum: itemNums[children[i][0]],
          refGen: 0))
        keys.add("Last")
        vals.add(CosObj(kind: coRef,
          refNum: itemNums[children[i][^1]], refGen: 0))
        keys.add("Count")
        vals.add(CosObj(kind: coInt, ival: children[i].len))
      extra.add((itemNums[i], 0,
        writeCos(CosObj(kind: coDict, keys: keys, vals: vals))))
    var rkeys = @["First", "Last", "Count"]
    var rvals = @[CosObj(kind: coRef, refNum: itemNums[top[0]], refGen: 0),
      CosObj(kind: coRef, refNum: itemNums[top[^1]], refGen: 0),
      CosObj(kind: coInt, ival: top.len)]
    extra.add((outlineRoot, 0,
      writeCos(CosObj(kind: coDict, keys: rkeys, vals: rvals))))
  # Page labels: single flat /Nums tree.
  var labelRoot = 0
  if b.labelDrafts.len > 0:
    var order = newSeq[int](b.labelDrafts.len)
    for i in 0 ..< order.len:
      order[i] = i
    order.sort(proc(a, c: int): int =
      cmp(b.labelDrafts[a].start, b.labelDrafts[c].start))
    var prevStart = -1
    for idx in order:
      let l = b.labelDrafts[idx]
      if l.start < 0 or l.start >= b.kids.len:
        pdfFail("page label start " & $l.start & " out of range")
      if l.start == prevStart:
        pdfFail("duplicate page label start " & $l.start)
      prevStart = l.start
      if l.style notin ["", "D", "R", "r", "A", "a"]:
        pdfFail("unknown page label style '" & l.style & "'")
      if l.first < 1:
        pdfFail("page label /St must be >= 1")
    var items: seq[CosObj] = @[]
    for idx in order:
      let l = b.labelDrafts[idx]
      items.add(CosObj(kind: coInt, ival: l.start))
      var dk: seq[string] = @[]
      var dv: seq[CosObj] = @[]
      if l.style.len > 0:
        dk.add("S")
        dv.add(CosObj(kind: coName, name: l.style))
      if l.prefix.len > 0:
        dk.add("P")
        dv.add(CosObj(kind: coStr, sval: l.prefix))
      if l.first != 1:
        dk.add("St")
        dv.add(CosObj(kind: coInt, ival: l.first))
      items.add(CosObj(kind: coDict, keys: dk, vals: dv))
    labelRoot = next
    inc next
    extra.add((labelRoot, 0, writeCos(CosObj(kind: coDict,
      keys: @["Nums"], vals: @[CosObj(kind: coArray, items: items)]))))
  var kids: seq[CosObj] = @[]
  for k in b.kids:
    kids.add(CosObj(kind: coRef, refNum: k, refGen: 0))
  var catKeys = @["Type", "Pages"]
  var catVals = @[CosObj(kind: coName, name: "Catalog"),
    CosObj(kind: coRef, refNum: pagesNum, refGen: 0)]
  if outlineRoot > 0:
    catKeys.add("Outlines")
    catVals.add(CosObj(kind: coRef, refNum: outlineRoot, refGen: 0))
  if labelRoot > 0:
    catKeys.add("PageLabels")
    catVals.add(CosObj(kind: coRef, refNum: labelRoot, refGen: 0))
  if b.attachSpecs.len > 0:
    # Byte-sorted /EmbeddedFiles name tree, nested directly.
    var ordered = b.attachSpecs
    ordered.sort(proc(a, b: tuple[name: string,
        specNum: int]): int = cmp(a.name, b.name))
    var items: seq[CosObj] = @[]
    for a in ordered:
      items.add(CosObj(kind: coStr, sval: a.name))
      items.add(CosObj(kind: coRef, refNum: a.specNum, refGen: 0))
    let files = CosObj(kind: coDict, keys: @["Names"],
      vals: @[CosObj(kind: coArray, items: items)])
    catKeys.add("Names")
    catVals.add(CosObj(kind: coDict, keys: @["EmbeddedFiles"],
      vals: @[files]))
  if b.xmpPacket.len > 0:
    let metaNum = next
    inc next
    let metaDict = CosObj(kind: coDict,
      keys: @["Type", "Subtype"],
      vals: @[CosObj(kind: coName, name: "Metadata"),
        CosObj(kind: coName, name: "XML")])
    var mkeys: seq[string] = @[]
    var mvals: seq[CosObj] = @[]
    for i, k in metaDict.keys:
      mkeys.add(k)
      mvals.add(metaDict.vals[i])
    mkeys.add("Length")
    mvals.add(CosObj(kind: coInt, ival: b.xmpPacket.len))
    extra.add((metaNum, 0, writeCos(CosObj(kind: coStream,
      streamDict: mkeys, streamVals: mvals, raw: b.xmpPacket))))
    catKeys.add("Metadata")
    catVals.add(CosObj(kind: coRef, refNum: metaNum, refGen: 0))
  let catalog = writeCos(CosObj(kind: coDict, keys: catKeys,
    vals: catVals))
  let pages = writeCos(CosObj(kind: coDict,
    keys: @["Type", "Kids", "Count"],
    vals: @[CosObj(kind: coName, name: "Pages"),
      CosObj(kind: coArray, items: kids),
      CosObj(kind: coInt, ival: b.kids.len)]))
  var objs = @[(catalogNum, 0, catalog), (pagesNum, 0, pages)]
  for o in b.objs:
    if pagePatch.hasKey(o.num):
      objs.add((o.num, o.gen, pagePatch[o.num]))
    else:
      objs.add(o)
  for o in extra:
    objs.add(o)
  var infoNum = 0
  var size = max(next, firstContentNum)
  if b.infoTitle.len > 0 or b.infoAuthor.len > 0 or
      b.infoCreator.len > 0 or b.infoProducer.len > 0 or
      b.infoKeywords.len > 0 or b.infoCreationDate.len > 0 or
      b.infoModDate.len > 0 or b.infoTrapped.len > 0:
    var keys: seq[string] = @[]
    var vals: seq[CosObj] = @[]
    if b.infoTitle.len > 0:
      keys.add("Title")
      vals.add(CosObj(kind: coStr, sval: b.infoTitle))
    if b.infoAuthor.len > 0:
      keys.add("Author")
      vals.add(CosObj(kind: coStr, sval: b.infoAuthor))
    if b.infoCreator.len > 0:
      keys.add("Creator")
      vals.add(CosObj(kind: coStr, sval: b.infoCreator))
    if b.infoProducer.len > 0:
      keys.add("Producer")
      vals.add(CosObj(kind: coStr, sval: b.infoProducer))
    if b.infoKeywords.len > 0:
      keys.add("Keywords")
      vals.add(CosObj(kind: coStr, sval: b.infoKeywords))
    if b.infoCreationDate.len > 0:
      keys.add("CreationDate")
      vals.add(CosObj(kind: coStr, sval: b.infoCreationDate))
    if b.infoModDate.len > 0:
      keys.add("ModDate")
      vals.add(CosObj(kind: coStr, sval: b.infoModDate))
    if b.infoTrapped.len > 0:
      keys.add("Trapped")
      vals.add(CosObj(kind: coName, name: b.infoTrapped))
    infoNum = next
    inc next
    size = max(next, firstContentNum)
    objs.add((infoNum, 0, writeCos(CosObj(kind: coDict, keys: keys,
      vals: vals))))
  emitFile(pdfMagic, objs, size, catalogNum, 0, "", "", -1, infoNum, 0)

# ---------------------------------------------------------------------------
# Rewrite: re-emit every live object with fresh offsets
# ---------------------------------------------------------------------------

proc hasBinaryFilter(s: CosObj): bool =
  for i, k in s.streamDict:
    if k != "Filter":
      continue
    let f = s.streamVals[i]
    var names: seq[string] = @[]
    case f.kind
    of coName: names.add(f.name)
    of coArray:
      for item in f.items:
        if item.kind == coName:
          names.add(item.name)
    else: return true
    for n in names:
      if isPassthrough(canonFilterName(n)):
        return true
  false

proc rewriteStream*(o: CosObj, reflate: bool): string =
  var keys: seq[string] = @[]
  var vals: seq[CosObj] = @[]
  var raw = o.raw
  var useFlate = false
  if reflate and not hasBinaryFilter(o):
    try:
      let decoded = decodeCosStream(o)
      raw = deflateEncode(decoded)
      useFlate = true
    except PdfError:
      raw = o.raw
  for i, k in o.streamDict:
    if k == "Length":
      continue
    if useFlate and (k == "Filter" or k == "DecodeParms" or k == "DL"):
      continue
    keys.add(k)
    vals.add(o.streamVals[i])
  if useFlate:
    keys.add("Filter")
    vals.add(CosObj(kind: coName, name: "FlateDecode"))
  keys.add("Length")
  vals.add(CosObj(kind: coInt, ival: raw.len))
  writeCos(CosObj(kind: coStream, streamDict: keys, streamVals: vals,
    raw: raw))

proc rewritePdf*(src: PdfSource, reflate = false,
    limits = defaultPdfLimits(), password = ""): string =
  ## Read every live object and write a fresh, defragmented file.
  ## Object numbers are preserved, so references stay valid. With
  ## `reflate`, decodable streams are normalized to a single
  ## FlateDecode (DCT/JPX/JBIG2/CCITT bytes pass through untouched).
  ## Encrypted input decrypts when `password` opens it; output is
  ## always unencrypted (use `rewritePdfEncrypted` for encrypted output).
  var doc = openDoc(src, limits, password)
  let head = src.slice(0, min(src.len, limits.maxScanBytes))
  let version = parsePdfVersion(head)
  let header = "%PDF-" & (if version.len > 0: version else: "1.7") &
    "\n%\xE2\xE3\xCF\xD3\n"
  var nums: seq[int] = @[]
  for num in doc.xref.entries.keys:
    if doc.xref.entries[num].live:
      nums.add(num)
  nums.sort()
  var objs: seq[RawObj] = @[]
  for num in nums:
    let e = doc.xref.entries[num]
    let o = doc.resolve(CosObj(kind: coRef, refNum: num, refGen: e.gen))
    if o.kind == coStream:
      objs.add((num, e.gen, rewriteStream(o, reflate)))
    else:
      objs.add((num, e.gen, writeCos(o)))
  if doc.xref.root.kind != coRef:
    pdfFail("PDF trailer missing /Root reference")
  let size = max(doc.xref.size, if nums.len > 0: nums[^1] + 1 else: 1)
  var infoNum = 0
  var infoGen = 0
  if doc.xref.info.kind == coRef:
    infoNum = doc.xref.info.refNum
    infoGen = doc.xref.info.refGen
  emitFile(header, objs, size, doc.xref.root.refNum,
    doc.xref.root.refGen, doc.xref.idFirst, doc.xref.idSecond,
    -1, infoNum, infoGen)

proc rewritePdf*(data: string, reflate = false,
    limits = defaultPdfLimits(), password = ""): string =
  rewritePdf(fromString(data), reflate, limits, password)

proc isMetaStream(o: CosObj): bool =
  if o.kind != coStream:
    return false
  for i, k in o.streamDict:
    if k == "Type" and o.streamVals[i].kind == coName and
        o.streamVals[i].name == "Metadata":
      return true
  false

proc rewritePdfEncryptedImpl*(src: PdfSource, opts: EncryptOptions,
    password = "", limits = defaultPdfLimits(), fileKeyOverride = "",
    idFirstOverride = "", fixedIv = ""): string =
  ## Full-encrypting rewrite: decrypt input with `password`, derive or
  ## reuse the file key, encrypt every string and stream (except the new
  ## /Encrypt dict, and /Metadata when `encryptMetadata` is false).
  ## `fileKeyOverride`/`idFirstOverride`/`fixedIv` are test hooks for
  ## determinism; production passes "" and gets fresh randomness.
  checkEncryptOptions(opts)
  var doc = openDoc(src, limits, password)
  let head = src.slice(0, min(src.len, limits.maxScanBytes))
  let version = parsePdfVersion(head)
  let header = "%PDF-" & (if version.len > 0: version else: "1.7") &
    "\n%\xE2\xE3\xCF\xD3\n"
  var idFirst =
    if idFirstOverride.len > 0: idFirstOverride
    elif doc.xref.idFirst.len > 0: doc.xref.idFirst
    else: randomStr(16)
  let idSecond =
    if doc.xref.idSecond.len > 0: doc.xref.idSecond
    else: idFirst
  let (encDict, fileKey) = buildEncryptObjects(opts, idFirst,
    fileKeyOverride, "")
  let (stmCls, strCls, keyLen) =
    if opts.revision == 4: (ccAESV2, ccAESV2, 16)
    else: (ccAESV3, ccAESV3, 32)
  proc ivFor(): string =
    if fixedIv.len == 16: fixedIv else: randomStr(16)
  var nums: seq[int] = @[]
  for num in doc.xref.entries.keys:
    if doc.xref.entries[num].live:
      nums.add(num)
  nums.sort()
  let oldEnc = doc.crypt.encryptObjNum
  var oldInfo = -1
  if doc.xref.info.kind == coRef:
    oldInfo = doc.xref.info.refNum
  var size = doc.xref.size
  if size <= (if nums.len > 0: nums[^1] else: 0):
    size = (if nums.len > 0: nums[^1] + 1 else: 1)
  let encNum = size
  inc size
  var infoNum = 0
  var infoGen = 0
  var hasInfo = false
  var infoObj = CosObj(kind: coNull)
  if doc.xref.info.kind != coNull:
    var inf = doc.xref.info
    if inf.kind == coRef:
      inf = doc.resolve(inf)
    if inf.kind == coDict:
      hasInfo = true
      infoObj = inf
  if hasInfo:
    infoNum = size
    inc size
  var objs: seq[RawObj] = @[]
  for num in nums:
    if num == oldEnc or num == oldInfo:
      continue
    let e = doc.xref.entries[num]
    let o = doc.resolve(CosObj(kind: coRef, refNum: num, refGen: e.gen))
    if o.kind == coStream:
      if o.isMetaStream() and not opts.encryptMetadata:
        var keys: seq[string] = @[]
        var vals: seq[CosObj] = @[]
        for i, k in o.streamDict:
          if k == "Length":
            continue
          keys.add(k)
          vals.add(o.streamVals[i])
        keys.add("Length")
        vals.add(CosObj(kind: coInt, ival: o.raw.len))
        objs.add((num, e.gen, writeCos(CosObj(kind: coStream,
          streamDict: keys, streamVals: vals, raw: o.raw))))
      else:
        let iv = ivFor()
        var keys: seq[string] = @[]
        var vals: seq[CosObj] = @[]
        for i, k in o.streamDict:
          if k == "Length":
            continue
          keys.add(k)
          vals.add(encryptValueWithIv(fileKey, num, e.gen,
            o.streamVals[i], strCls, keyLen, iv))
        let encRaw = encryptDataWithIv(fileKey, num, e.gen, o.raw,
          stmCls, keyLen, iv)
        keys.add("Length")
        vals.add(CosObj(kind: coInt, ival: encRaw.len))
        objs.add((num, e.gen, writeCos(CosObj(kind: coStream,
          streamDict: keys, streamVals: vals, raw: encRaw))))
    else:
      let iv = ivFor()
      objs.add((num, e.gen, writeCos(encryptValueWithIv(fileKey, num,
        e.gen, o, strCls, keyLen, iv))))
  objs.add((encNum, 0, writeCos(encDict)))
  if hasInfo:
    let iv = ivFor()
    objs.add((infoNum, 0, writeCos(encryptValueWithIv(fileKey, infoNum,
      0, infoObj, strCls, keyLen, iv))))
  if doc.xref.root.kind != coRef:
    pdfFail("PDF trailer missing /Root reference")
  emitFile(header, objs, size, doc.xref.root.refNum,
    doc.xref.root.refGen, idFirst, idSecond, -1, infoNum, infoGen,
    encNum, 0)

proc rewritePdfEncrypted*(data: string, opts: EncryptOptions,
    password = "", limits = defaultPdfLimits()): string =
  rewritePdfEncryptedImpl(fromString(data), opts, password, limits)

proc rewritePdfEncrypted*(src: PdfSource, opts: EncryptOptions,
    password = "", limits = defaultPdfLimits()): string =
  rewritePdfEncryptedImpl(src, opts, password, limits)

proc buildPdfEncrypted*(b: PdfBuilder, opts: EncryptOptions): string =
  ## Fresh builder output, encrypted. Implemented as build-then-rewrite;
  ## outline/label/annot drafts flow through the unencrypted build first.
  rewritePdfEncryptedImpl(fromString(b.buildPdf()), opts)

# ---------------------------------------------------------------------------
# Incremental update: append objects plus an xref section with /Prev
# ---------------------------------------------------------------------------

type
  PdfUpdate* = object
    base*: string
    added*: seq[RawObj]
    nextNum*: int
    rootNum*, rootGen*: int
    idFirst*, idSecond*: string
    prevStart*: int
    baseSize*: int
    limits*: PdfLimits

proc beginUpdate*(base: string,
    limits = defaultPdfLimits()): PdfUpdate =
  ## Prepare an incremental update of `base`. New objects take numbers
  ## from the old /Size up; `finishUpdate` appends them with an xref
  ## section pointing back via /Prev.
  let src = fromString(base)
  let xr = parseXRef(src, limits)
  if xr.encrypt.kind != coNull:
    pdfFail("M6 incremental update supports unencrypted documents " &
      "only (file has /Encrypt)")
  if xr.root.kind != coRef:
    pdfFail("PDF trailer missing /Root reference")
  PdfUpdate(base: base, added: @[], nextNum: xr.size,
    rootNum: xr.root.refNum, rootGen: xr.root.refGen,
    idFirst: xr.idFirst, idSecond: xr.idSecond,
    prevStart: parseStartxref(src, limits), baseSize: xr.size,
    limits: limits)

proc addObject*(u: var PdfUpdate, body: string, gen = 0): int =
  ## Store a pre-serialized body under a fresh number; returns it.
  result = u.nextNum
  inc u.nextNum
  u.added.add((result, gen, body))

proc addObject*(u: var PdfUpdate, num, gen: int, body: string) =
  ## Store a body under an explicit number (for new generations of
  ## existing objects).
  if num <= 0:
    pdfFail("PDF object number must be positive, got " & $num)
  u.added.add((num, gen, body))
  if num >= u.nextNum:
    u.nextNum = num + 1

proc updateObject*(u: var PdfUpdate, num: int, body: string): int =
  ## New revision of an existing object: the generation stays as in
  ## the base entry (or 0 when the base has no live entry), so every
  ## pre-existing "N G R" reference keeps resolving. The appended
  ## entry supersedes via /Prev ordering. Returns the generation used.
  let src = fromString(u.base)
  let xr = parseXRef(src, u.limits)
  result = 0
  if xr.entries.hasKey(num) and xr.entries[num].live:
    result = xr.entries[num].gen
  u.addObject(num, result, body)

proc finishUpdate*(u: PdfUpdate): string =
  ## Append new objects, an xref section covering only them, and a
  ## trailer with /Prev pointing at the previous startxref.
  if u.added.len == 0:
    pdfFail("incremental update has no new objects")
  var sorted = u.added
  sorted.sort(proc(a, b: RawObj): int = cmp(a.num, b.num))
  var seen = initTable[int, bool]()
  for o in sorted:
    if seen.hasKey(o.num):
      pdfFail("duplicate PDF object number " & $o.num & " in update")
    seen[o.num] = true
  result = u.base
  var offsets = initTable[int, int]()
  var gens = initTable[int, int]()
  var maxNum = 0
  for o in sorted:
    offsets[o.num] = result.len
    gens[o.num] = o.gen
    maxNum = max(maxNum, o.num)
    result.add(writeIndirect(o.num, o.gen, o.body))
  let size = max(u.baseSize, maxNum + 1)
  let xrefPos = result.len
  # One subsection per run of contiguous numbers.
  var runFirst = sorted[0].num
  var runPrev = sorted[0].num
  var runs: seq[tuple[first, count: int]] = @[]
  for o in sorted[1 .. ^1]:
    if o.num == runPrev + 1:
      runPrev = o.num
    else:
      runs.add((runFirst, runPrev - runFirst + 1))
      runFirst = o.num
      runPrev = o.num
  runs.add((runFirst, runPrev - runFirst + 1))
  result.add("xref\n")
  for r in runs:
    result.add($r.first & " " & $r.count & "\n")
    for n in r.first ..< r.first + r.count:
      result.add(padNum(offsets[n], 10) & " " & padNum(gens[n], 5) &
        " n \n")
  result.add("trailer\n<< /Size " & $size & " /Root " & $u.rootNum &
    " " & $u.rootGen & " R")
  if u.idFirst.len > 0:
    result.add(" /ID [" & writeStr(u.idFirst) & " " &
      writeStr(if u.idSecond.len > 0: u.idSecond else: u.idFirst) & "]")
  result.add(" /Prev " & $u.prevStart & " >>\nstartxref\n" & $xrefPos &
    "\n%%EOF\n")

proc finishUpdateEncrypted*(u: PdfUpdate, opts: EncryptOptions): string =
  ## Finish the pending update, then full-encrypting rewrite. This is
  ## not incremental: encryption cannot retroactively protect base bytes,
  ## so base + appended sections are re-emitted under the new /Encrypt.
  ## Do not use on signed files (rewriting invalidates /ByteRange).
  rewritePdfEncryptedImpl(fromString(u.finishUpdate()), opts)
