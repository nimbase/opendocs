# PDF Fonts and Images

## Font embedding (`pdf/fontembed.nim`, `pdf/shape.nim`)

WinAnsi path:

```nim
import opendocs/pdf
import opendocs/pdf/write
import opendocs/pdf/shape
import opendocs/pdf/fontembed
import std/tables

let prog = readFile("tests/data/fonts/DejaVuSans.ttf")
var sf = openShapedFont(prog)
defer: close(sf)
var use = FontUse(fontBytes: prog, baseName: "DejaVuSans")
var content: string
for i, line in wrapText(sf, "Hello embedded writer", 24.0, 468.0):
  use.noteUse(line)
  content.add(drawTextLine(72.0, 720.0 - float64(i) * 28.0, "F2", 24.0, line) & "\n")
var b = newPdfBuilder()
let fonts = b.finalizeFonts({"F2": use}.toTable)
let cnum = b.addContentStream(content)
discard b.addPage(612.0, 792.0, cnum, fontResources(fonts))
writeFile("embedded.pdf", b.buildPdf())
```

Unicode (CID-keyed Type0) path:

```nim
let prog = readFile("tests/data/fonts/cjk-cff-micro.otf")
var sf = openShapedFont(prog)
defer: close(sf)
var use = CidFontUse(fontBytes: prog, baseName: "NotoSansJP")
let content = drawCidLine(use, sf, 72.0, 720.0, "F3", 24.0, "日本語あAX")
var b = newPdfBuilder()
let fonts = b.finalizeFonts({"F3": use}.toTable)
let cnum = b.addContentStream(content)
discard b.addPage(612.0, 792.0, cnum, fontResources(fonts))
writeFile("cid.pdf", b.buildPdf())
```

- `FontUse(fontBytes, baseName, codes: WinAnsi -> unicode)`, `CidFontUse(fontBytes, baseName, cids: GID->CID, texts: CID->UTF-8)`, `helveticaWidths[256]`.
- WinAnsi: `winAnsiByte`, `noteUse`, `subsetFont`, `measureText`, `builtinMeasure`, `builtinWrapText`, `builtinFontDict` (unembedded Helvetica), `drawTextLine`, `wrapText`, `fontResources`, `embedFont`, `finalizeFonts(Table[FontUse])`.
- CID: `noteCidUse(u, sf, text)`, `drawCidLine(u, sf, x, y, res, size, text): BT...(<hex>Tj|[<hex>]TJ) ET` (TJ kerning), `embedCidFont` (Type0 `Identity-H`, CIDFontType2/0, `/CIDToGIDMap`, compact `/W`, `/ToUnicode`), `finalizeFonts(Table[CidFontUse])`.
- `shape.nim` (harfnim): `ShapedGlyph(glyphId, xAdvance, yAdvance, cluster)`, `ShapedRun`, `ShapedFont(bytes, parsed, shaper, upem)`, `openShapedFont`, `close` (idempotent), `shapeInto`, `shapedWidth` (1000upm), `nominalGlyph`, `glyphAdvance1000`, `headBBox`, `hExtents1000`, `loadFontBytes(fontDict, d)` (`FontFile2/3/1`), `shapeText`, `tablePresent`, `glyphExtents1000`.

## Images (`pdf/images.nim`, `pdf/imgpipe.nim`, `exports.nim`)

```nim
var d = openDoc(readFile("tests/data/pdf/m5_images.pdf"))
for im in d.pageImages(0):
  echo im.name, ": ", im.width, "x", im.height, " ", im.encoding
  im.saveImage("/tmp/" & im.name & ".png")
```

- `ColorKind(ckDeviceGray/ckDeviceRGB/ckDeviceCMYK/ckIndexed/ckICCBased/ckSeparation)`, `PdfRawImage(name, width, height, bpc, ncomp, cs, samples, decode, coded, coding, isMask, mask, smask, ctm, depth)`.
- `parseColorSpace` (Indexed/ICCBased + `/Alternate`/Separation/CalGray/CalRGB; Lab/Pattern fail), `decodeRange`, `unpackSamples` (1/2/4/8/16bpc + `/Decode`), `parseRawImage`, `inlineRawImage` (W/H/BPC/CS abbrevs), `pageRawImages(index)` (incl. Forms, `Do`-CTM + depth).
- `ImageEncoding(ieRGB/ieGray/ieAlpha)`, `PdfImage(name, width, height, encoding, hasAlpha, pixels: RGB8/Gray8/Alpha8 + alpha, ctm, depth)`, `DecodedPixels`.
- `pageImages(d, index): seq[PdfImage]` — DCT via `image` package incl. Adobe CMYK -> RGB; JPX/CCITT/JBIG2 fail; Indexed expand, CMYK-naive, ICC `N`-interpret, Separation via `/Alternate`, SMask/color-key -> alpha.
- Helpers: `dynToPixels`, `grayStr`, `cmykNaive`, `flattenWhiteStr`, `downscaleToWidth`, `jpegSofComps`, `decodeImageBytes`, `encodeJpegStr` (writer compress pass).

Image export helpers live in `opendocs/exports` — see `exports.md`.
