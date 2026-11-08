# Roadmap and Limits

From `README.md:309-327`:

Done:

- ZIP package layer (stored/deflated, writer, spill-to-disk)
- DOCX reader (runs, tables, numbering, styles, images, headers/footers, notes, comments, textboxes, SDT)
- DOCX writer (full package assembly, model-identical round-trips, LibreOffice PDF acceptance)
- DOCX typed fields (complex + simple, all instruction kinds)
- DOCX tracked changes (run/body wrappers, marks, changes, ranges, rsids, accept-view text)
- PDF read/write (parse, build, rewrite, incremental update)
- Encryption RC4, AES-128, AES-256 (R2-R6)
- Signatures: list fields, check ByteRange digests, append unsigned placeholder shells
- Form filling/flattening, merge/split, attachments, text extraction with position, font embedding with subsetting, images, incremental saves
- XLSX Phase A (lazy sheets, shared strings, raw values, A1 utils; xlsx/xlsm/xltx/xltm/xlam open flow)
- XLSX Phase B (eager styles, builtin formats, dates, 576-cell excelize oracle parity)
- DOCX high-level builder, accept/reject revisions API

Todo:

- Legacy DOC read + write (binary Word format)
- ODT read + write
- RTF read + write
- TXT read + write
- XLSX Phase C (rich text done, hyperlinks, merges, dimensions, docProps remaining)
- XLSX Phase D (read-only OLE for `vbaProject.bin`)
- XLSX writer
- PPTX read + write

## Limits and errors

- `PdfLimits(maxPages, maxScanBytes, maxObjects, maxWalkDepth, maxContentOps, maxImagePixels, maxNestedXObject)` — `defaultPdfLimits()`, `checkCount()`. Violations raise `PdfError`.
- ZIP `DefaultMaxEntryBytes = 64MB` caps inflation per entry. DOCX `DefaultSpillThresholdBytes = 64 MiB`, `DefaultSpillCapBytes = 512 MiB`. XLSX `DefaultXlsxSpillThresholdBytes = 64MB`, `DefaultXlsxSpillCapBytes = 512MB`.
- `XlsxMaxRows = 1048576`, `XlsxMaxCols = 16384`.
- Strict XML: mismatched tags -> `DocxError`/`XlsxError`. Corrupt packages name the offending part.
- Encrypted PDFs need password; merge/write/forms/attach/sign reject encrypted inputs. Encrypted XLSX OLE rejected safely.
- JPX/CCITT/JBIG2 images fail decode (reported, not guessed). Lab/Pattern color spaces fail. `R5` encryption and non-`Standard` filters rejected.
- Unmapped CJK codes stay U+FFFD, never guessed.
