## High-level PDF reader and writer API.
##
## This module is the public entry point. Reader handles (`PdfDoc`,
## `PdfDocument`, text, images, doctext, sheet) are re-exported as a
## curated set; everything else low-level (`lexer`, `cos`, `xref`,
## content ops, crypt internals, CMaps, shaping) stays importable from
## its own submodule for advanced use but is not re-exported here.
##
## The writer is a small document model on top of the low-level
## builder: one font setup, flowing paragraphs with automatic page
## breaks, file-path images with an optional libvips compress pass.
## All text shaping and embedding goes through HarfBuzz (`CidFontUse`):
## supply a TrueType/OpenType program, get full Unicode out.
##
##   var doc = newPdf("DejaVuSans.ttf")
##   doc.paragraph("Hello writer")
##   doc.imageFromFile("photo.jpg")
##   doc.save("hello.pdf")
##   doc.close()

import std/algorithm
import std/os
import std/tables
import libvips/api
import libvips/bindings/vips
import pdf/cos
import pdf/fontembed
import pdf/lexer
import pdf/shape
import pdf/write

# ---------------------------------------------------------------------------
# Curated re-exports: reader (writer lives in this file)
# ---------------------------------------------------------------------------

from pdf/types import PdfError, PdfLimits, PageBox, defaultPdfLimits
export PdfError, PdfLimits, PageBox, defaultPdfLimits

from pdf/source import PdfSource, fromString, fromFile, isMapped
export PdfSource, fromString, fromFile, isMapped

from pdf/docmodel import PdfDoc, openDoc, openMappedDoc, close, pageBoxes,
  pageCount
export PdfDoc, openDoc, openMappedDoc, close, pageBoxes, pageCount

from pdf/document import PdfDocument, openPdf, readPdfBytes, openPdfPassword,
  openPdfPasswordFile, pageCount
export PdfDocument, openPdf, readPdfBytes, openPdfPassword,
  openPdfPasswordFile, pageCount

from pdf/text import TextRun, extractText
export TextRun, extractText

from pdf/vipsimg import PdfImage, ImageEncoding, pageImages, ensureVips
export PdfImage, ImageEncoding, pageImages, ensureVips

from pdf/doctext import TextLine, TextBlock, PageText, DocumentText, TextHit,
  maxExcerptLen, extractDocumentText, searchText, pageCount
export TextLine, TextBlock, PageText, DocumentText, TextHit,
  maxExcerptLen, extractDocumentText, searchText, pageCount

from pdf/sheet import BlockKind, SheetRow, PdfTable, SheetPage, Sheet,
  extractSheet, pageCount
export BlockKind, SheetRow, PdfTable, SheetPage, Sheet,
  extractSheet, pageCount

from pdf/merge import PageRef, pageRefs, copyPage, extractPages, mergePdfs
export PageRef, pageRefs, copyPage, extractPages, mergePdfs

from pdf/attach import FileAttachment, guessMime, embeddedFiles, embedFile,
  embedFileUpdate
export FileAttachment, guessMime, embeddedFiles, embedFile,
  embedFileUpdate

from pdf/forms import FieldKind, FieldOption, FieldWidget, FormField,
  formFields, fieldNames, getField, isChecked, fillText, setCheck,
  selectRadio, selectChoice, selectChoices, resetFields, flattenFields
export FieldKind, FieldOption, FieldWidget, FormField,
  formFields, fieldNames, getField, isChecked, fillText, setCheck,
  selectRadio, selectChoice, selectChoices, resetFields, flattenFields

from pdf/sign import DocSignature, SigDraft, docSignatures,
  verifyByteRangeHash, addSignaturePlaceholder
export DocSignature, SigDraft, docSignatures,
  verifyByteRangeHash, addSignaturePlaceholder

from exports import ExportError, ImageFormat, ExportOptions, ExportPixels,
  encodeImage, saveImage, formatForPath, formatForExt
export ExportError, ImageFormat, ExportOptions, ExportPixels,
  encodeImage, saveImage, formatForPath, formatForExt

# ---------------------------------------------------------------------------
# Writer: page sizes
# ---------------------------------------------------------------------------

type
  PageSize* = enum
    psA5, psA4, psA3, psLetter, psLegal, psCustom

proc pageDims*(s: PageSize, customW = 0.0,
    customH = 0.0): tuple[w, h: float64] =
  ## MediaBox size in points. `psCustom` reads `customW`/`customH`;
  ## anything else ignores them. Default page size is `psA4`.
  case s
  of psA5: (419.53, 595.28)
  of psA4: (595.28, 841.89)
  of psA3: (841.89, 1190.55)
  of psLetter: (612.0, 792.0)
  of psLegal: (612.0, 1008.0)
  of psCustom:
    if customW <= 0.0 or customH <= 0.0:
      pdfFail("custom page size needs positive width and height")
    (customW, customH)

# ---------------------------------------------------------------------------
# Writer: document model
# ---------------------------------------------------------------------------

type
  ImageOpts* = object
    compress*: bool = false ## re-encode via libvips (JPEG) when true
    jpegQuality*: range[0..100] = 85 ## quality for the compress pass
    maxWidthPx*: int = 0 ## downscale to this pixel width (0 keeps pixels)
    widthPt*: float64 = 0.0 ##placed width in points (0 fits the column)

  FontKind = enum
    fkBuiltin, fkEmbedded

  FontSlot = object
    kind: FontKind
    fontBytes: string
    baseName: string
    use: CidFontUse
    sf: ShapedFont

  PlacedImage = object
    name: string
    num: int

  LogicalPage = object
    content: string
    images: seq[PlacedImage]
    w, h: float64

  Pdf* = object
    ## Opaque document handle. Build with `newPdf`, fill with
    ## `paragraph`/`heading`/`textAt`/`imageFromFile`, finish with
    ## `save` or `build`, release HarfBuzz state with `close`.
    builder: PdfBuilder
    pages: seq[LogicalPage]
    curContent: string
    curImages: seq[PlacedImage]
    pageW, pageH: float64
    margin: float64
    cursorY: float64
    fonts: Table[string, FontSlot]
    fontOrder: seq[string]
    curFont: string
    curSize: float64
    title, author: string
    nextImage: int

const defaultMarginPt = 56.7 ## 20 mm working margin

proc validResName(name: string): bool =
  if name.len == 0:
    return false
  for c in name:
    if c notin {'A'..'Z', 'a'..'z', '0'..'9', '_', '-', '.'}:
      return false
  true

proc topY(doc: Pdf): float64 =
  doc.pageH - doc.margin - doc.curSize

proc flushPage(doc: var Pdf) =
  doc.pages.add(LogicalPage(content: doc.curContent,
    images: doc.curImages, w: doc.pageW, h: doc.pageH))
  doc.curContent = ""
  doc.curImages = @[]
  doc.cursorY = doc.topY()

proc addFontBytes(doc: var Pdf, name, fontBytes, baseName: string) =
  if not validResName(name):
    pdfFail("font name '" & name &
      "' must be non-empty ASCII letters, digits, _, - or .")
  if fontBytes.len == 0:
    pdfFail("cannot shape text with empty font program")
  var sf = openShapedFont(fontBytes)
  if doc.fonts.hasKey(name):
    # Replacing (for example upgrading the default body): release the
    # old shaping context when it owns one.
    for k, v in doc.fonts.mpairs:
      if k == name:
        if v.kind == fkEmbedded:
          close(v.sf)
        v = FontSlot(kind: fkEmbedded, fontBytes: fontBytes,
          baseName: baseName,
          use: CidFontUse(fontBytes: fontBytes, baseName: baseName),
          sf: sf)
        return
  doc.fonts[name] = FontSlot(kind: fkEmbedded, fontBytes: fontBytes,
    baseName: baseName,
    use: CidFontUse(fontBytes: fontBytes, baseName: baseName), sf: sf)
  doc.fontOrder.add(name)

proc newPdf*(fontPath: string, size = psA4, customW = 0.0,
    customH = 0.0, margin = defaultMarginPt): Pdf =
  ## Open a document with one font loaded from `fontPath`
  ## (TrueType/OpenType, shaped and embedded via HarfBuzz). More fonts
  ## arrive later with `loadFont`/`setFont`.
  let fontBytes =
    try: readFile(fontPath)
    except IOError as e:
      pdfFail("cannot read font file '" & fontPath & "' (" & e.msg & ")")
  let (w, h) = pageDims(size, customW, customH)
  if margin <= 0.0 or 2.0 * margin >= min(w, h):
    pdfFail("margin must be positive and smaller than half the page")
  result = Pdf(builder: newPdfBuilder(), pages: @[], curContent: "",
    curImages: @[], pageW: w, pageH: h, margin: margin,
    cursorY: 0.0, fonts: initTable[string, FontSlot](),
    fontOrder: @[], curFont: "body", curSize: 12.0,
    title: "", author: "", nextImage: 0)
  result.cursorY = result.topY()
  let base = splitFile(fontPath).name
  result.addFontBytes("body", fontBytes,
    if base.len > 0: base else: "Embedded")

proc newPdf*(size = psA4, customW = 0.0,
    customH = 0.0, margin = defaultMarginPt): Pdf =
  ## Open a document with the builtin Helvetica body: no font file
  ## needed, nothing embedded, WinAnsi text only. `loadFont` upgrades
  ## any name (including `"body"`) to a HarfBuzz-embedded font.
  let (w, h) = pageDims(size, customW, customH)
  if margin <= 0.0 or 2.0 * margin >= min(w, h):
    pdfFail("margin must be positive and smaller than half the page")
  result = Pdf(builder: newPdfBuilder(), pages: @[], curContent: "",
    curImages: @[], pageW: w, pageH: h, margin: margin,
    cursorY: 0.0, fonts: initTable[string, FontSlot](),
    fontOrder: @[], curFont: "body", curSize: 12.0,
    title: "", author: "", nextImage: 0)
  result.cursorY = result.topY()
  result.fonts["body"] = FontSlot(kind: fkBuiltin)
  result.fontOrder.add("body")

proc newPdf*(fontBytes, baseName: string, size = psA4, customW = 0.0,
    customH = 0.0, margin = defaultMarginPt): Pdf =
  ## `newPdf` from in-memory font bytes with an explicit PostScript
  ## base name (for example `"DejaVuSans"`).
  if baseName.len == 0:
    pdfFail("font base name must not be empty")
  let (w, h) = pageDims(size, customW, customH)
  if margin <= 0.0 or 2.0 * margin >= min(w, h):
    pdfFail("margin must be positive and smaller than half the page")
  result = Pdf(builder: newPdfBuilder(), pages: @[], curContent: "",
    curImages: @[], pageW: w, pageH: h, margin: margin,
    cursorY: 0.0, fonts: initTable[string, FontSlot](),
    fontOrder: @[], curFont: "body", curSize: 12.0,
    title: "", author: "", nextImage: 0)
  result.cursorY = result.topY()
  result.addFontBytes("body", fontBytes, baseName)

proc loadFont*(doc: var Pdf, name, path: string) =
  ## Load a font program for `setFont` (replacing any face already
  ## loaded under `name`, including the builtin default). HarfBuzz
  ## shapes it, the writer embeds a subset on `save`/`build`.
  let fontBytes =
    try: readFile(path)
    except IOError as e:
      pdfFail("cannot read font file '" & path & "' (" & e.msg & ")")
  let base = splitFile(path).name
  doc.addFontBytes(name, fontBytes,
    if base.len > 0: base else: name)

proc setFont*(doc: var Pdf, name: string, size: float64) =
  ## Switch the current font and size for later text.
  if not doc.fonts.hasKey(name):
    pdfFail("unknown font '" & name & "' (load it with loadFont)")
  if size <= 0.0:
    pdfFail("font size must be positive")
  doc.curFont = name
  doc.curSize = size

proc fontNames*(doc: Pdf): seq[string] =
  ## Loaded font names in load order.
  doc.fontOrder

proc setPageSize*(doc: var Pdf, size: PageSize, customW = 0.0,
    customH = 0.0) =
  ## Page size for later pages. Flushes the open page when it holds
  ## content so finished pages keep their size.
  let (w, h) = pageDims(size, customW, customH)
  if doc.curContent.len > 0 or doc.curImages.len > 0:
    doc.flushPage()
  doc.pageW = w
  doc.pageH = h
  doc.cursorY = doc.topY()

proc setMargin*(doc: var Pdf, margin: float64) =
  ## Working margin in points for later pages.
  if margin <= 0.0 or 2.0 * margin >= min(doc.pageW, doc.pageH):
    pdfFail("margin must be positive and smaller than half the page")
  doc.margin = margin
  if doc.curContent.len == 0 and doc.curImages.len == 0:
    doc.cursorY = doc.topY()

proc setTitle*(doc: var Pdf, title: string) =
  ## Document title for the trailer /Info dict.
  doc.title = title

proc setAuthor*(doc: var Pdf, author: string) =
  ## Document author for the trailer /Info dict.
  doc.author = author

proc newPage*(doc: var Pdf) =
  ## Finish the open page and start a fresh one.
  doc.flushPage()

proc pageCount*(doc: Pdf): int =
  ## Finished pages plus the open one when it holds content.
  doc.pages.len +
    (if doc.curContent.len > 0 or doc.curImages.len > 0: 1 else: 0)

proc emitWrapped(doc: var Pdf, text: string) =
  if not doc.fonts.hasKey(doc.curFont):
    pdfFail("unknown font '" & doc.curFont & "' (load it with loadFont)")
  let maxW = doc.pageW - 2.0 * doc.margin
  var lines: seq[string] = @[]
  var builtin = false
  for k, v in doc.fonts.mpairs:
    if k == doc.curFont:
      if v.kind == fkBuiltin:
        builtin = true
        lines = builtinWrapText(text, doc.curSize, maxW)
      else:
        lines = wrapText(v.sf, text, doc.curSize, maxW)
      break
  for line in lines:
    if doc.cursorY < doc.margin + doc.curSize * 0.2:
      doc.flushPage()
    var emit = ""
    for k, v in doc.fonts.mpairs:
      if k == doc.curFont:
        if builtin:
          # Validates WinAnsi coverage loudly; wrap only measured
          # words and spaces, never the joined line.
          discard builtinMeasure(line, doc.curSize)
          emit = drawTextLine(doc.margin, doc.cursorY, doc.curFont,
            doc.curSize, line)
        else:
          emit = drawCidLine(v.use, v.sf, doc.margin, doc.cursorY,
            doc.curFont, doc.curSize, line)
        break
    doc.curContent.add(emit & "\n")
    doc.cursorY -= doc.curSize * 1.2

proc paragraph*(doc: var Pdf, text: string) =
  ## Flowing paragraph: greedy wrap on HarfBuzz widths, automatic page
  ## breaks. No hyphenation or justification in v1.
  if text.len == 0:
    doc.cursorY -= doc.curSize * 0.6
    return
  doc.emitWrapped(text)
  doc.cursorY -= doc.curSize * 0.4

proc heading*(doc: var Pdf, text: string, size = 18.0) =
  ## One wrapped heading at `size` with space before and after. Uses
  ## the current font; restores the body size afterwards.
  if size <= 0.0:
    pdfFail("heading size must be positive")
  doc.cursorY -= size * 0.4
  let saved = doc.curSize
  doc.curSize = size
  doc.emitWrapped(text)
  doc.curSize = saved
  doc.cursorY -= size * 0.5

proc textAt*(doc: var Pdf, text: string, x, y: float64,
    size = -1.0) =
  ## One absolute line at `(x, y)` without wrapping or cursor motion.
  ## Defaults to the current size.
  let s = if size > 0.0: size else: doc.curSize
  if s <= 0.0:
    pdfFail("font size must be positive")
  if not doc.fonts.hasKey(doc.curFont):
    pdfFail("unknown font '" & doc.curFont & "' (load it with loadFont)")
  var emit = ""
  for k, v in doc.fonts.mpairs:
    if k == doc.curFont:
      if v.kind == fkBuiltin:
        discard builtinMeasure(text, s)
        emit = drawTextLine(x, y, doc.curFont, s, text)
      else:
        emit = drawCidLine(v.use, v.sf, x, y, doc.curFont, s, text)
      break
  doc.curContent.add(emit & "\n")

# ---------------------------------------------------------------------------
# Writer: images (file path, optional libvips compress pass)
# ---------------------------------------------------------------------------

proc vipsFail(path, what, msg: string) =
  pdfFail("cannot " & what & " image '" & path & "' (" & msg & ")")

proc vipsPixels(work: Image, path: string): tuple[pixels: string,
    w, h, comps: int] =
  var img = work
  try:
    if img.hasAlpha:
      img = img.flatten(@[255.0, 255.0, 255.0])
    if img.bands == 1:
      img = img.castUchar()
    elif img.bands == 3:
      img = img.toSRGB().castUchar()
    elif img.bands == 4:
      img = img.toSRGB().castUchar()
    else:
      pdfFail("unsupported band count (" & $img.bands & ") in image '" &
        path & "'")
  except VipsError as e:
    vipsFail(path, "convert", e.msg)
  let w = img.width
  let h = img.height
  var n: csize_t = 0
  let p = vips_image_write_to_memory(img.v, addr n)
  if p == nil:
    pdfFail("libvips write_to_memory failed on image '" & path & "'")
  var px = newString(n)
  if n > 0:
    copyMem(addr px[0], p, n)
  g_free(p)
  let comps = if img.bands == 1: 1 else: 3
  if px.len != w * h * comps:
    pdfFail("sample size mismatch on image '" & path & "'")
  (px, w, h, comps)

proc imageFromFile*(doc: var Pdf, path: string,
    opts = ImageOpts()) =
  ## Place an image file on the open page.
  ##
  ## Without `compress` (default) JPEG files embed byte-for-byte as
  ## DCTDecode and anything else embeds lossless Flate RGB/gray. With
  ## `compress` the pixels run through libvips (optional downscale to
  ## `maxWidthPx`, alpha flattened over white) and re-encode to JPEG
  ## at `jpegQuality`. `widthPt` sets the placed width (default fits
  ## the text column); height follows the aspect ratio.
  if opts.maxWidthPx < 0:
    pdfFail("maxWidthPx must not be negative")
  if opts.widthPt < 0.0:
    pdfFail("widthPt must not be negative")
  let raw =
    try: readFile(path)
    except IOError as e:
      pdfFail("cannot read image file '" & path & "' (" & e.msg & ")")
  if raw.len == 0:
    pdfFail("image file is empty: " & path)
  var buf = newSeq[uint8](raw.len)
  copyMem(addr buf[0], unsafeAddr raw[0], raw.len)
  ensureVips()
  var img: Image
  try:
    img = openBuffer(buf)
  except VipsError as e:
    vipsFail(path, "decode", e.msg)
  if img.width <= 0 or img.height <= 0:
    pdfFail("image has non-positive size: " & path)
  let isJpeg = raw.len >= 2 and raw[0] == '\xFF' and raw[1] == '\xD8'
  var objNum = 0
  var doneW = img.width
  var doneH = img.height
  if not opts.compress and isJpeg and
      (img.bands == 1 or img.bands == 3) and not img.hasAlpha:
    objNum = doc.builder.addJpegImage(raw, doneW, doneH, img.bands)
  elif opts.compress:
    var enc = img
    if opts.maxWidthPx > 0 and enc.width > opts.maxWidthPx:
      try:
        enc = enc.resize(opts.maxWidthPx)
      except VipsError as e:
        vipsFail(path, "resize", e.msg)
    try:
      if enc.hasAlpha:
        enc = enc.flatten(@[255.0, 255.0, 255.0])
      if enc.bands == 4:
        enc = enc.toSRGB()
      elif enc.bands != 1 and enc.bands != 3:
        pdfFail("unsupported band count (" & $enc.bands &
          ") in image '" & path & "'")
      enc = enc.castUchar()
    except VipsError as e:
      vipsFail(path, "convert", e.msg)
    let comps = if enc.bands == 1: 1 else: 3
    var encBytes: seq[uint8]
    try:
      encBytes = saveJPEG(enc, opts.jpegQuality)
    except VipsError as e:
      vipsFail(path, "encode", e.msg)
    var js = newString(encBytes.len)
    if encBytes.len > 0:
      copyMem(addr js[0], unsafeAddr encBytes[0], encBytes.len)
    doneW = enc.width
    doneH = enc.height
    objNum = doc.builder.addJpegImage(js, doneW, doneH, comps)
  else:
    var work = img
    if opts.maxWidthPx > 0 and work.width > opts.maxWidthPx:
      try:
        work = work.resize(opts.maxWidthPx)
      except VipsError as e:
        vipsFail(path, "resize", e.msg)
    let (px, pw, ph, comps) = vipsPixels(work, path)
    doneW = pw
    doneH = ph
    objNum = doc.builder.addRgbImage(px, pw, ph, comps)
  let avail = doc.pageW - 2.0 * doc.margin
  var wPt = if opts.widthPt > 0.0: opts.widthPt else: avail
  if wPt > avail:
    wPt = avail
  let hPt = wPt * float64(doneH) / float64(doneW)
  if doc.cursorY - hPt < doc.margin:
    doc.flushPage()
  inc doc.nextImage
  let name = "Im" & $doc.nextImage
  let x = doc.margin
  let y = doc.cursorY - hPt
  doc.curContent.add("q " & $wPt & " 0 0 " & $hPt & " " & $x & " " &
    $y & " cm /" & name & " Do Q\n")
  doc.curImages.add(PlacedImage(name: name, num: objNum))
  doc.cursorY = y - doc.curSize * 0.6

# ---------------------------------------------------------------------------
# Writer: finish
# ---------------------------------------------------------------------------

proc build*(doc: var Pdf): string =
  ## Assemble the file bytes. Repeatable and deterministic for the
  ## same content; the document stays usable afterwards.
  if doc.curContent.len > 0 or doc.curImages.len > 0 or
      doc.pages.len == 0:
    doc.flushPage()
  var uses = initTable[string, CidFontUse]()
  for k, v in doc.fonts.pairs:
    if v.kind == fkEmbedded and v.use.cids.len > 0:
      uses[k] = v.use
  var b = doc.builder
  var fnums = initTable[string, int]()
  if uses.len > 0:
    fnums = b.finalizeFonts(uses)
  for k, v in doc.fonts.pairs:
    if v.kind == fkBuiltin:
      # Indirect dicts, like embedded fonts: some readers warn on
      # direct font dicts inside /Resources.
      fnums[k] = b.addValue(builtinFontDict())
  var names: seq[string] = @[]
  for k in fnums.keys:
    names.add(k)
  names.sort()
  for pg in doc.pages:
    let cnum = b.addContentStream(pg.content)
    var fkeys: seq[string] = @[]
    var fvals: seq[CosObj] = @[]
    for n in names:
      fkeys.add(n)
      fvals.add(CosObj(kind: coRef, refNum: fnums[n], refGen: 0))
    var rkeys = @["Font"]
    var rvals = @[CosObj(kind: coDict, keys: fkeys, vals: fvals)]
    if pg.images.len > 0:
      var xkeys: seq[string] = @[]
      var xvals: seq[CosObj] = @[]
      for im in pg.images:
        xkeys.add(im.name)
        xvals.add(CosObj(kind: coRef, refNum: im.num, refGen: 0))
      rkeys.add("XObject")
      rvals.add(CosObj(kind: coDict, keys: xkeys, vals: xvals))
    discard b.addPage(pg.w, pg.h, cnum,
      CosObj(kind: coDict, keys: rkeys, vals: rvals))
  b.setInfo(doc.title, doc.author)
  b.buildPdf()

proc save*(doc: var Pdf, path: string) =
  ## Write the file bytes to `path`.
  writeFile(path, doc.build())

proc close*(doc: var Pdf) =
  ## Release the HarfBuzz shaping contexts. Idempotent; call when the
  ## document is done (shaping after close is invalid).
  for k, v in doc.fonts.mpairs:
    close(v.sf)
