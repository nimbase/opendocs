# ZIP Package Layer

Module: `src/opendocs/zip.nim`. Used by DOCX and XLSX for package IO, spill-to-disk, zip-bomb guards.

```nim
import opendocs/zip

var w = newZipWriter()
w.addFile("word/document.xml", "<w:document/>")
w.addFile("stored.bin", data, zmStored)
writeFile("out.zip", w.toBytes())

let a = openZip("out.zip")
let b = openZipBytes(bytes)
echo filenames(a)
let idx = a.findEntry("word/document.xml")
echo a.readEntryByIndex(idx).len
echo a.readEntry("word/document.xml").len
a.extractEntryToFile(idx, "/tmp/out.xml")
```

## Types

- `ZipError = object of IOError`.
- `ZipMethod(zmStored = 0, zmDeflated = 8)`.
- `ZipEntry(name, compressMethod, compressedSize, uncompressedSize, crc, dataOffset)`.
- `ZipArchive(data, entries)`.
- `ZipWriter(files: seq[(name, meth, data)])` — opaque.
- `DefaultMaxEntryBytes = 64MB`.

## API

- `deflateRaw(data, level = 6): seq[byte]`, `inflateRawInto(data, dest, maxSize)`, `inflateRaw(data, maxSize): seq[byte]`.
- `openZipBytes(data): ZipArchive`, `openZip(path): ZipArchive`.
- `filenames(a): seq[string]`, `findEntry(a, name): int` + overload `findEntry(w: ZipWriter, name): int`.
- `readEntryInto(a, idx, dest, maxSize)`, `readEntryByIndex(a, idx, maxSize): seq[byte]`, `extractEntryToFile(a, idx, path, maxSize)`, `readEntry(a, name, maxSize): seq[byte]`.
- `newZipWriter(): ZipWriter`, `addFile(w, name, data: seq[byte]|string, meth = zmDeflated)`, `toBytes(w): seq[byte]`, `writeZip(w, path)`.

Guards: `maxSize` caps inflation per entry. DOCX/XLSX spill thresholds build on this for large workbooks/documents.

Tests: `tests/t_zip.nim`. Perf: `examples/docx_perf.nim` uses `newZipWriter` for synthetic docs.
