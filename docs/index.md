# opendocs

Document readers and writers for Nim: DOCX, PDF, XLSX, plus a shared ZIP package layer and image export helpers.

- Read and write DOCX programmatically (`opendocs/docx`)
- Read and write PDF: parse, build, rewrite, incremental update (`opendocs/pdf`)
- Read XLSX, XLSM, XLTX, XLTM, XLAM (`opendocs/xlsx`)
- ZIP stored/deflated, writer, spill-to-disk (`opendocs/zip`)
- Image export via `image` package (`opendocs/exports`)

Package: `opendocs 0.1.0`, `srcDir = src`, license MIT.
Requires Nim >= 2.0.0.

```nim
import opendocs/docx
import opendocs/pdf
import opendocs/xlsx
```

Note: `src/opendocs.nim` raises a compile error on direct import. Import the specific parser you need.

See `installation.md`, `quickstart.md`, and per-module pages.
