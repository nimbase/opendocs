## Optimizer (M18): image downsample/recompress, reflate, space audit.
##
## `optimizePdf` re-emits the file (like `rewritePdf`) with two extra
## passes: Flate image XObjects wider than `maxImageWidth` are
## downscaled, and RGB/gray images are re-encoded as JPEG when
## `jpegQuality` is set. Everything else goes through the reflate path
## (`reflate = true` normalizes decodable streams to FlateDecode;
## DCT/JPX/JBIG2/CCITT bytes pass through untouched).
##
## Skipped images stay byte-identical and are counted, never guessed:
## image masks (/ImageMask, /Mask, /SMask) are left alone (re-encoding
## would break mask alignment), decode failures keep the original
## (same per-stream fallback `rewriteStream` uses), and
## cross-object duplicate sharing is out of scope (it needs a
## reference-remap pass; see below). Deterministic for fixed inputs:
## the pure-Nim JPEG encoder and downscaler carry no randomness.
##
## `spaceAudit` reports live-object bytes by kind (images, content,
## fonts, metadata, other) so callers can see where the bytes go. Kind
## assignment is heuristic and documented per arm below.

import std/algorithm
import std/tables
import ./types
import ./lexer
import ./cos
import ./docmodel
import ./filters
import ./images
import ./imgpipe
import ./write

type
  OptimizeOptions* = object
    maxImageWidth*: int ## downscale wider images (0 keeps pixels)
    jpegQuality*: int ## 0 keeps Flate; 1..100 re-encodes RGB/gray as JPEG
    reflate*: bool ## normalize decodable streams to FlateDecode

  OptimizeStats* = object
    images*: int ## image XObjects seen
    downsized*: int ## images downscaled
    recompressed*: int ## images re-encoded as JPEG
    skipped*: int ## images left byte-identical (masks, decode failures)
    bytesBefore*: int
    bytesAfter*: int

proc defaultOptimizeOptions*(): OptimizeOptions =
  OptimizeOptions(maxImageWidth: 0, jpegQuality: 0, reflate: true)

proc checkOptimizeOptions*(opts: OptimizeOptions) =
  if opts.maxImageWidth < 0:
    pdfFail("max image width must not be negative")
  if opts.jpegQuality < 0 or opts.jpegQuality > 100:
    pdfFail("JPEG quality must be 0..100")

proc isImageStream(o: CosObj): bool =
  o.kind == coStream and o.dictGet("Subtype").kind == coName and
    o.dictGet("Subtype").name == "Image"

proc fontStreamKind(o: CosObj): bool =
  if o.kind != coStream:
    return false
  let st = o.dictGet("Subtype")
  if st.kind != coName:
    return false
  st.name in ["Type1C", "CIDFontType0C", "CIDFontType2", "TrueType",
    "OpenType", "Type1"]

proc spaceAudit*(d: var PdfDoc): seq[tuple[kind: string,
    bytes: int]] =
  ## Live-object bytes by kind. Streams classify by /Subtype (/Image
  ## images; font subtypes fonts; /Type /Metadata metadata; anything
  ## else content); plain objects count their canonical serialization.
  var images, content, fonts, metadata, other = 0
  for num in d.xref.entries.keys:
    if not d.xref.entries[num].live:
      continue
    let e = d.xref.entries[num]
    let o = d.resolve(CosObj(kind: coRef, refNum: num, refGen: e.gen))
    if o.kind == coStream:
      if o.isImageStream():
        images += o.raw.len
      elif o.fontStreamKind():
        fonts += o.raw.len
      elif o.dictGet("Type").kind == coName and
          o.dictGet("Type").name == "Metadata":
        metadata += o.raw.len
      else:
        content += o.raw.len
    else:
      other += writeCos(o).len
  result = @[("images", images), ("content", content),
    ("fonts", fonts), ("metadata", metadata), ("other", other)]
  result.sort(proc(a, b: tuple[kind: string, bytes: int]): int =
    cmp(b.bytes, a.bytes))

proc optimizeImage(d: var PdfDoc, num: int, o: CosObj,
    opts: OptimizeOptions, stats: var OptimizeStats): CosObj =
  ## Rebuilt image stream dict+bytes, or the original object on any
  ## skip path (masks, tiny images, decode failures).
  inc stats.images
  if o.dictGet("ImageMask").kind == coBool and
      o.dictGet("ImageMask").bval:
    inc stats.skipped
    return o
  if o.dictGet("Mask").kind != coNull or
      o.dictGet("SMask").kind != coNull:
    inc stats.skipped
    return o
  var rgb = ""
  var w, h, comps = 0
  try:
    let raw = d.parseRawImage("img", o)
    let img = d.convertRaw(raw)
    if img.encoding != ieRGB and img.encoding != ieGray:
      inc stats.skipped
      return o
    comps = if img.encoding == ieGray: 1 else: 3
    rgb = img.pixels
    w = img.width
    h = img.height
  except PdfError:
    inc stats.skipped
    return o
  var nw, nh = 0
  nw = w
  nh = h
  if opts.maxImageWidth > 0 and w > opts.maxImageWidth:
    let scaled = downscaleToWidth(rgb, w, h, comps,
      opts.maxImageWidth)
    rgb = scaled.px
    nw = scaled.w
    nh = scaled.h
    inc stats.downsized
  var payload = ""
  var filter = "FlateDecode"
  if opts.jpegQuality > 0 and comps in [1, 3]:
    payload = encodeJpegStr(rgb, nw, nh, comps, opts.jpegQuality,
      "img")
    filter = "DCTDecode"
    inc stats.recompressed
  else:
    payload = deflateEncode(rgb)
  let cs = if comps == 1: "DeviceGray" else: "DeviceRGB"
  CosObj(kind: coStream,
    streamDict: @["Type", "Subtype", "Width", "Height", "ColorSpace",
      "BitsPerComponent", "Filter", "Length"],
    streamVals: @[CosObj(kind: coName, name: "XObject"),
      CosObj(kind: coName, name: "Image"),
      CosObj(kind: coInt, ival: nw),
      CosObj(kind: coInt, ival: nh),
      CosObj(kind: coName, name: cs),
      CosObj(kind: coInt, ival: 8),
      CosObj(kind: coName, name: filter),
      CosObj(kind: coInt, ival: payload.len)],
    raw: payload)

proc optimizePdf*(data: string, opts = defaultOptimizeOptions(),
    password = "", limits = defaultPdfLimits()): tuple[pdf: string,
    stats: OptimizeStats] =
  ## Full rewrite with image + reflate passes. Encrypted input
  ## decrypts with `password`; output is always unencrypted (pair with
  ## `rewritePdfEncrypted` when encrypted output is wanted).
  checkOptimizeOptions(opts)
  var doc = openDoc(fromString(data), limits, password)
  let head = data[0 ..< min(data.len, limits.maxScanBytes)]
  let version = parsePdfVersion(head)
  let header = "%PDF-" & (if version.len > 0: version else: "1.7") &
    "\n%\xE2\xE3\xCF\xD3\n"
  var stats = OptimizeStats(bytesBefore: data.len)
  var nums: seq[int] = @[]
  for num in doc.xref.entries.keys:
    if doc.xref.entries[num].live:
      nums.add(num)
  nums.sort()
  var objs: seq[RawObj] = @[]
  for num in nums:
    let e = doc.xref.entries[num]
    let o = doc.resolve(CosObj(kind: coRef, refNum: num, refGen: e.gen))
    if o.isImageStream() and
        (opts.maxImageWidth > 0 or opts.jpegQuality > 0):
      let rep = doc.optimizeImage(num, o, opts, stats)
      if rep.kind == coStream:
        objs.add((num, e.gen, writeCos(rep)))
      else:
        objs.add((num, e.gen, writeCos(o)))
    elif o.kind == coStream:
      objs.add((num, e.gen, rewriteStream(o, opts.reflate)))
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
  result.pdf = emitFile(header, objs, size, doc.xref.root.refNum,
    doc.xref.root.refGen, doc.xref.idFirst, doc.xref.idSecond,
    -1, infoNum, infoGen)
  stats.bytesAfter = result.pdf.len
  result.stats = stats
