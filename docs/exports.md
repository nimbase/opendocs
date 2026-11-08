# Image Export

Module: `src/opendocs/exports.nim`. Re-exported via `opendocs/pdf` as `ExportError, ImageFormat, ExportOptions, ExportPixels, encodeImage, saveImage, formatForPath, formatForExt`. Backed by `image` package (`buffer/color/dynamic` + `jpeg/png/webp/tiff/bmp` codecs).

```nim
import opendocs/pdf # gives pageImages + saveImage

var d = openDoc(readFile("m5_images.pdf"))
for im in d.pageImages(0):
  im.saveImage("/tmp/" & im.name & ".png")
  im.saveImage("/tmp/" & im.name & ".jpg")
```

Direct:

```nim
import opendocs/exports

let px = toExportPixels(img)
let jpg = encodeImage(px, fmtJpeg, ExportOptions(jpegQuality: 80))
saveImage(px, "/tmp/out.webp")
echo formatForPath("/tmp/out.png") # fmtPng
echo formatForExt(".jpg")          # fmtJpeg
```

## Types

- `ExportError = object of CatchableError`.
- `ImageFormat(fmtJpeg/fmtPng/fmtWebP/fmtTiff/fmtGif/fmtHeif/fmtAvif/fmtJxl/fmtBmp)`.
- `ExportOptions(jpegQuality 0..100 = 90, pngCompression 0..9 = 6, webpQuality 0..100 = 90)`.
- `ExportPixels(width, height, bands (1/2/3/4), data: string)`.

## API

- `formatForExt(ext): ImageFormat`, `formatForPath(path): ImageFormat`.
- `toExportPixels(img: PdfImage): ExportPixels`.
- `encodeImage(px: ExportPixels, format, opts): string` + overload `(img: PdfImage, ...)`.
- `saveImage(px: ExportPixels, path, opts)` + overload `(img: PdfImage, ...)` — dispatches by extension; GIF/HEIF/AVIF/JXL raise `ExportError`.
