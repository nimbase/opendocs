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
## breaks, file-path images with an optional JPEG compress pass.
## All text shaping and embedding goes through harfnim (`CidFontUse`):
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

from pdf/imgpipe import PdfImage, ImageEncoding, pageImages,
  decodeImageBytes, dynToPixels, flattenWhiteStr, downscaleToWidth,
  encodeJpegStr, jpegSofComps
export PdfImage, ImageEncoding, pageImages

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
  formFields, fieldNames, getField, calcOrder, isChecked, fillText,
  setCheck, selectRadio, selectChoice, selectChoices, resetFields,
  flattenFields
export FieldKind, FieldOption, FieldWidget, FormField,
  formFields, fieldNames, getField, calcOrder, isChecked, fillText,
  setCheck, selectRadio, selectChoice, selectChoices, resetFields,
  flattenFields

from pdf/sign import DocSignature, SigDraft, docSignatures,
  verifyByteRangeHash, addSignaturePlaceholder
export DocSignature, SigDraft, docSignatures,
  verifyByteRangeHash, addSignaturePlaceholder

from pdf/catalog import PdfDate, PdfInfo, parsePdfDate, docInfo, xmpField,
  decodeTextString
export PdfDate, PdfInfo, parsePdfDate, docInfo, xmpField,
  decodeTextString

from pdf/names import nameTreePairs, numberTreePairs, pageRefIndex
export nameTreePairs, numberTreePairs, pageRefIndex

from pdf/outline import PdfOutline, docOutlines, destPageIndex
export PdfOutline, docOutlines, destPageIndex

from pdf/labels import PdfPageLabel, pageLabels, labelForPage
export PdfPageLabel, pageLabels, labelForPage

from pdf/annotread import PdfAnnot, readAnnot, pageAnnots, docAnnots
export PdfAnnot, readAnnot, pageAnnots, docAnnots

from pdf/structread import PdfStructElem, structTree
export PdfStructElem, structTree

from pdf/xfdf import exportXfdf, importXfdf
export exportXfdf, importXfdf

from pdf/redact import RedactRect, markRedactions, applyRedactions,
  verifyNoFauxRedaction
export RedactRect, markRedactions, applyRedactions,
  verifyNoFauxRedaction

from pdf/layers import PdfLayer, docLayers, layerOCGs
export PdfLayer, docLayers, layerOCGs

from pdf/organize import setPageRotation, setPageBox, deletePages,
  appendPages, addOutline, setPageLabels, addLink, addInternalLink,
  addTextAnnot, addAnnotsUpdate
export setPageRotation, setPageBox, deletePages, appendPages,
  addOutline, setPageLabels, addLink, addInternalLink, addTextAnnot,
  addAnnotsUpdate

from pdf/draw import PdfColor, PdfColorKind, Path, PathCmd, FillOpts,
  black, white, rgb, gray, cmyk, fillOp, strokeOp, moveTo, lineTo,
  curveTo, close, addRect, pathOps, paintOps, clipOps, ellipsePath,
  lineOps, rectOps, circleOps, ellipseOps
export PdfColor, PdfColorKind, Path, PathCmd, FillOpts,
  black, white, rgb, gray, cmyk, fillOp, strokeOp, moveTo, lineTo,
  curveTo, close, addRect, pathOps, paintOps, clipOps, ellipsePath,
  lineOps, rectOps, circleOps, ellipseOps

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
    compress*: bool = false ## re-encode via JPEG when true
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
    ## `save` or `build`, release shaping state with `close`.
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
    creator, producer, keywords, creationDate, modDate, trapped,
      xmpPacket: string
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
  ## (TrueType/OpenType, shaped and embedded via harfnim). More fonts
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
  ## any name (including `"body"`) to a harfnim-embedded font.
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
  ## loaded under `name`, including the builtin default). harfnim
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

proc setCreator*(doc: var Pdf, creator: string) =
  doc.creator = creator

proc setProducer*(doc: var Pdf, producer: string) =
  doc.producer = producer

proc setKeywords*(doc: var Pdf, keywords: string) =
  doc.keywords = keywords

proc setCreationDate*(doc: var Pdf, d: string) =
  ## Raw PDF date string (malformed reads back as ok=false).
  doc.creationDate = d

proc setModDate*(doc: var Pdf, d: string) =
  doc.modDate = d

proc setTrapped*(doc: var Pdf, trapped: string) =
  if trapped notin ["", "True", "False", "Unknown"]:
    pdfFail("trapped must be True, False or Unknown")
  doc.trapped = trapped

proc setXmpPacket*(doc: var Pdf, packet: string) =
  doc.xmpPacket = packet

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
  ## Flowing paragraph: greedy wrap on shaped widths, automatic page
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

type
  Alignment* = enum
    alignLeft, alignCenter, alignRight

  TextStyle* = object
    color*: PdfColor
    hasColor*: bool
    underline*: bool
    strikeout*: bool
    charSpacing*: float64
    wordSpacing*: float64
    rise*: float64
    renderMode*: int
    horizScale*: float64 ## percent, 100 = normal (Tz)

proc styledPrefix(s: TextStyle): string =
  result = ""
  if s.hasColor:
    result.add(s.color.fillOp() & "\n")
  if s.charSpacing != 0.0:
    result.add($s.charSpacing & " Tc\n")
  if s.wordSpacing != 0.0:
    result.add($s.wordSpacing & " Tw\n")
  if s.rise != 0.0:
    result.add($s.rise & " Ts\n")
  if s.renderMode != 0:
    if s.renderMode < 0 or s.renderMode > 7:
      pdfFail("text render mode must be 0..7")
    result.add($s.renderMode & " Tr\n")
  if s.horizScale != 0.0 and s.horizScale != 100.0:
    if s.horizScale <= 0.0 or s.horizScale > 1000.0:
      pdfFail("horizontal scale must be positive")
    result.add($s.horizScale & " Tz\n")

proc lineWidthOf(doc: var Pdf, text: string, size: float64): float64 =
  for k, v in doc.fonts.mpairs:
    if k == doc.curFont:
      if v.kind == fkBuiltin:
        return builtinMeasure(text, size)
      return measureText(v.sf, text, size)
  pdfFail("unknown font '" & doc.curFont & "' (load it with loadFont)")

proc setFillColor*(doc: var Pdf, c: PdfColor) =
  ## Non-stroking color for following text and filled paths.
  doc.curContent.add(c.fillOp() & "\n")

proc setStrokeColor*(doc: var Pdf, c: PdfColor) =
  ## Stroking color for following stroked paths.
  doc.curContent.add(c.strokeOp() & "\n")

proc setLineWidth*(doc: var Pdf, w: float64) =
  if w != w or w == Inf or w == -Inf or w <= 0.0:
    pdfFail("line width must be positive")
  doc.curContent.add($w & " w\n")

proc textRun*(doc: var Pdf, text: string, style: TextStyle,
    x, y: float64) =
  ## One absolute run with explicit style (no wrap, no cursor motion).
  ## Underline/strikeout are thin filled rects over the measured width;
  ## positions are heuristics documented here, not font metrics.
  let s = doc.curSize
  if s <= 0.0:
    pdfFail("font size must be positive")
  if not doc.fonts.hasKey(doc.curFont):
    pdfFail("unknown font '" & doc.curFont & "' (load it with loadFont)")
  let w = doc.lineWidthOf(text, s)
  var emit = ""
  for k, v in doc.fonts.mpairs:
    if k == doc.curFont:
      if v.kind == fkBuiltin:
        discard builtinMeasure(text, s)
        emit = drawTextLine(x, y, doc.curFont, s, text)
      else:
        emit = drawCidLine(v.use, v.sf, x, y, doc.curFont, s, text)
      break
  doc.curContent.add(styledPrefix(style) & emit & "\n")
  if style.underline:
    let uy = y - 1.5
    doc.curContent.add("q " &
      (if style.hasColor: style.color.fillOp() & " " else: "") &
      $x & " " & $uy & " " & $w & " 0.8 re f Q\n")
  if style.strikeout:
    let sy = y + s * 0.3
    doc.curContent.add("q " &
      (if style.hasColor: style.color.fillOp() & " " else: "") &
      $x & " " & $sy & " " & $w & " 0.8 re f Q\n")

proc paragraphStyled*(doc: var Pdf, text: string, style: TextStyle,
    align = alignLeft) =
  ## Flowing paragraph like `paragraph` with style color and alignment.
  ## Alignment is left/center/right; no justification in v1.
  if text.len == 0:
    doc.cursorY -= doc.curSize * 0.6
    return
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
  doc.curContent.add(styledPrefix(style))
  for line in lines:
    if doc.cursorY < doc.margin + doc.curSize * 0.2:
      doc.flushPage()
      doc.curContent.add(styledPrefix(style))
    let lw = doc.lineWidthOf(line, doc.curSize)
    let x = case align
      of alignLeft: doc.margin
      of alignCenter: doc.margin + (maxW - lw) / 2.0
      of alignRight: doc.margin + (maxW - lw)
    var emit = ""
    for k, v in doc.fonts.mpairs:
      if k == doc.curFont:
        if builtin:
          discard builtinMeasure(line, doc.curSize)
          emit = drawTextLine(x, doc.cursorY, doc.curFont, doc.curSize,
            line)
        else:
          emit = drawCidLine(v.use, v.sf, x, doc.cursorY, doc.curFont,
            doc.curSize, line)
        break
    doc.curContent.add(emit & "\n")
    if style.underline or style.strikeout:
      let uy = if style.underline: doc.cursorY - 1.5
        else: doc.cursorY + doc.curSize * 0.3
      doc.curContent.add("q " &
        (if style.hasColor: style.color.fillOp() & " " else: "") &
        $x & " " & $uy & " " & $lw & " 0.8 re f Q\n")
    doc.cursorY -= doc.curSize * 1.2
  doc.cursorY -= doc.curSize * 0.4

proc line*(doc: var Pdf, x1, y1, x2, y2: float64,
    width = 1.0, c = black()) =
  ## Straight segment on the open page.
  doc.curContent.add(lineOps(x1, y1, x2, y2, width, c) & "\n")

proc rect*(doc: var Pdf, x, y, w, h: float64,
    opts: FillOpts) =
  ## Axis-aligned rectangle with explicit fill/stroke options.
  doc.curContent.add(rectOps(x, y, w, h, opts) & "\n")

proc circle*(doc: var Pdf, cx, cy, r: float64,
    opts: FillOpts) =
  doc.curContent.add(circleOps(cx, cy, r, opts) & "\n")

proc ellipse*(doc: var Pdf, cx, cy, rx, ry: float64,
    opts: FillOpts) =
  doc.curContent.add(ellipseOps(cx, cy, rx, ry, opts) & "\n")

proc stroke*(doc: var Pdf, p: Path, width = 1.0,
    c = black()) =
  doc.curContent.add(p.paintOps(FillOpts(hasFill: false,
    hasStroke: true, stroke: c, lineWidth: width), width) & "\n")

proc fill*(doc: var Pdf, p: Path, c: PdfColor,
    evenOdd = false) =
  doc.curContent.add(p.paintOps(FillOpts(hasFill: true, fill: c,
    hasStroke: false, evenOdd: evenOdd)) & "\n")

type
  BorderLine* = enum
    bdNone, bdSingle, bdDouble

  Border* = object
    line*: BorderLine
    width*: float64
    color*: PdfColor

  Column* = object
    width*: float64
    align*: Alignment

  Row* = object
    cells*: seq[string]
    style*: TextStyle
    height*: float64 ## minimum row height, 0 = auto

  TableStyle* = object
    columns*: seq[Column]
    border*: Border
    headerRows*: int
    cellPadding*: float64

proc wrapCellText(doc: var Pdf, text: string, w, pad: float64): seq[
    string] =
  let avail = max(w - 2.0 * pad, 10.0)
  var builtin = false
  for k, v in doc.fonts.mpairs:
    if k == doc.curFont:
      if v.kind == fkBuiltin:
        builtin = true
      break
  if builtin:
    return builtinWrapText(text, doc.curSize, avail)
  for k, v in doc.fonts.mpairs:
    if k == doc.curFont:
      return wrapText(v.sf, text, doc.curSize, avail)
  pdfFail("unknown font '" & doc.curFont & "' (load it with loadFont)")

proc tableRowHeight(doc: var Pdf, r: Row, style: TableStyle,
    pad: float64): float64 =
  var maxLines = 1
  for i in 0 ..< min(r.cells.len, style.columns.len):
    maxLines = max(maxLines, doc.wrapCellText(r.cells[i],
      style.columns[i].width, pad).len)
  max(r.height, float64(maxLines) * doc.curSize * 1.2 + 2.0 * pad)

proc drawTableRow(doc: var Pdf, r: Row, style: TableStyle, topY,
    totalW, pad: float64) =
  var x = doc.margin
  let h = doc.tableRowHeight(r, style, pad)
  for i in 0 ..< style.columns.len:
    let cw = style.columns[i].width
    let txt = if i < r.cells.len: r.cells[i] else: ""
    let wrapped = doc.wrapCellText(txt, cw, pad)
    for li, ln in wrapped:
      let lw = doc.lineWidthOf(ln, doc.curSize)
      let tx = case style.columns[i].align
        of alignLeft: x + pad
        of alignCenter: x + (cw - lw) / 2.0
        of alignRight: x + cw - pad - lw
      let ty = topY - pad - doc.curSize * (float64(li) * 1.2 + 0.9)
      var emit = ""
      for k, v in doc.fonts.mpairs:
        if k == doc.curFont:
          if v.kind == fkBuiltin:
            discard builtinMeasure(ln, doc.curSize)
            emit = drawTextLine(tx, ty, doc.curFont, doc.curSize, ln)
          else:
            emit = drawCidLine(v.use, v.sf, tx, ty, doc.curFont,
              doc.curSize, ln)
          break
      doc.curContent.add(styledPrefix(r.style) & emit & "\n")
    x += cw
  if style.border.line != bdNone:
    let w = if style.border.width > 0.0: style.border.width else: 0.5
    let y0 = topY - h
    doc.curContent.add(lineOps(doc.margin, topY,
      doc.margin + totalW, topY, w, style.border.color) & "\n")
    doc.curContent.add(lineOps(doc.margin, y0,
      doc.margin + totalW, y0, w, style.border.color) & "\n")
    var vx = doc.margin
    for c in style.columns:
      doc.curContent.add(lineOps(vx, topY, vx, y0, w,
        style.border.color) & "\n")
      vx += c.width
    doc.curContent.add(lineOps(vx, topY, vx, y0, w,
      style.border.color) & "\n")
    if style.border.line == bdDouble:
      let off = w + 1.5
      doc.curContent.add(lineOps(doc.margin, topY - off,
        doc.margin + totalW, topY - off, w * 0.5,
        style.border.color) & "\n")

proc table*(doc: var Pdf, rows: seq[Row], style: TableStyle) =
  ## Simple table writer: explicit column widths, ruling lines, header
  ## repeat on page splits. No cell spanning, no nested tables, no
  ## vertical text (timeboxed, documented here). Cell text uses the
  ## document's current font/size with each row's TextStyle for color.
  if style.columns.len == 0:
    pdfFail("table needs at least one column")
  if rows.len == 0:
    return
  for c in style.columns:
    if c.width <= 0.0:
      pdfFail("table column needs positive width")
  if style.headerRows < 0 or style.headerRows > rows.len:
    pdfFail("table headerRows out of range")
  let pad = if style.cellPadding != 0.0: style.cellPadding else: 4.0
  if pad < 0.0:
    pdfFail("table cellPadding must not be negative")
  var totalW = 0.0
  for c in style.columns:
    totalW += c.width
  if totalW > doc.pageW - 2.0 * doc.margin + 1e-6:
    pdfFail("table wider than the text column")
  var idx = 0
  var needHeader = false
  while idx < rows.len:
    let h = doc.tableRowHeight(rows[idx], style, pad)
    if doc.cursorY - h < doc.margin:
      doc.flushPage()
      needHeader = style.headerRows > 0 and idx >= style.headerRows
    let topY = doc.cursorY
    doc.drawTableRow(rows[idx], style, topY, totalW, pad)
    doc.cursorY = topY - h
    inc idx
    if needHeader:
      needHeader = false
      for hi in 0 ..< style.headerRows:
        let hh = doc.tableRowHeight(rows[hi], style, pad)
        if doc.cursorY - hh < doc.margin:
          doc.flushPage()
        let ht = doc.cursorY
        doc.drawTableRow(rows[hi], style, ht, totalW, pad)
        doc.cursorY = ht - hh

# ---------------------------------------------------------------------------
# Writer: images (file path, optional JPEG compress pass)
# ---------------------------------------------------------------------------

proc imageFromFile*(doc: var Pdf, path: string,
    opts = ImageOpts()) =
  ## Place an image file on the open page.
  ##
  ## Without `compress` (default) JPEG files embed byte-for-byte as
  ## DCTDecode and anything else embeds lossless Flate RGB/gray. With
  ## `compress` the pixels run through the pure-Nim JPEG encoder
  ## (optional downscale to `maxWidthPx`, alpha flattened over white)
  ## and re-encode to JPEG at `jpegQuality`. `widthPt` sets the placed
  ## width (default fits the text column); height follows the aspect
  ## ratio.
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
  let dp = dynToPixels(decodeImageBytes(raw, path))
  if dp.width <= 0 or dp.height <= 0:
    pdfFail("image has non-positive size: " & path)
  let isJpeg = raw.len >= 2 and raw[0] == '\xFF' and raw[1] == '\xD8'
  var objNum = 0
  var doneW = dp.width
  var doneH = dp.height
  # CMYK/YCCK JPEGs (4 SOF components) decode to RGB pixels but the
  # raw bytes are not RGB: never passthrough those.
  if not opts.compress and isJpeg and
      (dp.comps == 1 or dp.comps == 3) and jpegSofComps(raw) != 4:
    objNum = doc.builder.addJpegImage(raw, doneW, doneH, dp.comps)
  elif opts.compress:
    var px = flattenWhiteStr(dp.pixels, dp.width, dp.height, dp.comps)
    var comps = if dp.comps == 1: 1 else: 3
    var w = dp.width
    var h = dp.height
    if opts.maxWidthPx > 0 and w > opts.maxWidthPx:
      let scaled = downscaleToWidth(px, w, h, comps, opts.maxWidthPx)
      px = scaled.px
      w = scaled.w
      h = scaled.h
    let js = encodeJpegStr(px, w, h, comps, opts.jpegQuality, path)
    doneW = w
    doneH = h
    objNum = doc.builder.addJpegImage(js, doneW, doneH, comps)
  else:
    var px = dp.pixels
    var w = dp.width
    var h = dp.height
    var comps = dp.comps
    if opts.maxWidthPx > 0 and w > opts.maxWidthPx:
      let scaled = downscaleToWidth(px, w, h, comps, opts.maxWidthPx)
      px = scaled.px
      w = scaled.w
      h = scaled.h
    px = flattenWhiteStr(px, w, h, comps)
    comps = if comps == 1: 1 else: 3
    doneW = w
    doneH = h
    objNum = doc.builder.addRgbImage(px, doneW, doneH, comps)
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
  b.setInfo(doc.title, doc.author, doc.creator, doc.producer,
    doc.keywords, doc.creationDate, doc.modDate, doc.trapped)
  if doc.xmpPacket.len > 0:
    b.setXmpPacket(doc.xmpPacket)
  b.buildPdf()

proc save*(doc: var Pdf, path: string) =
  ## Write the file bytes to `path`.
  writeFile(path, doc.build())

proc close*(doc: var Pdf) =
  ## Release the shaping contexts. Idempotent; call when the
  ## document is done (shaping after close is invalid).
  for k, v in doc.fonts.mpairs:
    close(v.sf)
